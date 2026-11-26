-- Salvager: the Ledger window. A window of its own (move it, resize it), with three views:
--   Purchases: every item bought, and under it what it was disenchanted into.
--   Sales:     every material sale, with its profit against what the materials cost you.
--   Odds:      per item level band, what your disenchants gave against the table, the buy limit and its risk.
local _, ns = ...

local Ledger, Data, Model, W = ns.Ledger, ns.Data, ns.Model, ns.Widgets

local Window = { view = "sales" }
ns.LedgerWindow = Window

local GREY, GOLD, GREEN, RED = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040"
local INDENT = 22
local QUALITY_NAME = { [2] = "Uncommon", [3] = "Rare", [4] = "Epic" }
local QUALITY_COLOR = { [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee" }   -- the game's quality colors

local COLUMNS = {
    purchases = { { "Item", 220 }, { "Bought", 82 }, { "Paid", 84, "RIGHT" }, { "Expected", 84, "RIGHT" },
        { "Got", 96, "RIGHT" }, { "Result", 84, "RIGHT" } },
    -- The Sales view is two tables: your auctions, and the sales already paid.
    listed = { { "Material", 170 }, { "Status", 132 }, { "Each", 64, "RIGHT" }, { "Price", 76, "RIGHT" },
        { "You get", 76, "RIGHT" }, { "Cost", 84, "RIGHT" }, { "Profit", 76, "RIGHT" } },
    paid = { { "Material", 170 }, { "Sold", 132 }, { "Each", 64, "RIGHT" }, { "Price", 76, "RIGHT" },
        { "You get", 76, "RIGHT" }, { "Cost", 84, "RIGHT" }, { "Profit", 76, "RIGHT" } },
}

local f, list, summary, tabs = nil, nil, nil, {}
local newOddsView
local checkButton, cancelButton
local oddsView          -- the Odds view in the ledger window: its filters and one table per band
local oddsFrame, oddsOut -- the odds in a window of their own
local salesParts = {}   -- title, table, title, table of the Sales view

--- Which bands the Odds view shows: { quality = { [2], [3], [4] }, type = { a, w } }, kept with the window.
local function oddsFilter()
    local saved = ns.db.windows.ledger or {}
    ns.db.windows.ledger = saved
    saved.oddsQuality = saved.oddsQuality or { [2] = true, [3] = true, [4] = true }
    saved.oddsType = saved.oddsType or { a = true, w = true }
    return saved.oddsQuality, saved.oddsType, saved
end

local function when(t) return (t and t > 0) and date("%m-%d %H:%M", t) or "-" end
local function money(c) return c and ns.Money(c) or "-" end
local function signed(c)
    if not c then return "" end
    return (c >= 0 and GREEN or RED) .. ns.Money(c) .. "|r"
end
local function itemName(itemID, link)
    return link or (ns.GetItemInfo(itemID)) or ("item " .. tostring(itemID))
end
local function note(text) return { cells = { GREY .. text .. "|r" } } end

------------------------------------------------------------------ rows

--- Purchases: one row per item, its materials indented under it.
function Window.PurchaseRows()
    local rows = {}
    for _, e in ipairs(Ledger.History(ns.db.ledger)) do
        local name = itemName(e.itemID, e.link) .. (e.salvager and "  |cff9370db[Salvager]|r" or "")
        rows[#rows + 1] = {
            itemID = e.itemID, link = e.link, group = #(e.mats or {}) > 0,
            cells = {
                name, when(e.boughtAt or (not e.done and e.t) or nil),
                e.paid and ns.Money(e.paid) or (GREY .. "not recorded|r"), money(e.expected),
                e.done and money(e.got)
                    or (GREY .. (ns.NoDisenchant(e.itemID) and "cannot be disenchanted" or "not disenchanted") .. "|r"),
                signed(e.result),
            },
        }
        for _, m in ipairs(e.mats or {}) do
            local value = m.value
            if not value then
                local p = ns.PriceOf(m.id)
                value = p and math.floor(p * m.qty * (1 - ns.Cut()) + 0.5) or nil
            end
            rows[#rows + 1] = {
                itemID = m.id, indent = INDENT,
                cells = { m.qty .. "x " .. ns.MaterialName(m.id), "", m.share and ns.Money(m.share) or "", "", money(value), "" },
            }
        end
    end
    if #rows == 0 then
        rows[1] = note("Nothing yet. Buy from the Deals tab, or take your \"Auction won\" mail, then disenchant.")
    end
    return rows
end

local function duration(seconds)
    if not seconds then return "?" end
    if seconds < 3600 then return math.max(1, math.floor(seconds / 60 + 0.5)) .. " min" end
    return string.format("%.0f h", seconds / 3600)
end

--- Your auctions as last read: what is listed, what is sold and waiting for its money.
function Window.ListingRows()
    local rows = {}
    local l = ns.db.listings
    local mine = l.rows or {}
    if #mine == 0 then
        rows[1] = note(l.t and "Nothing listed." or "Not read yet: open the auction house.")
        return rows
    end
    for _, r in ipairs(mine) do
        local gross = r.qty * r.each
        local net = math.floor(gross * (1 - ns.Cut()) + 0.5)
        local avg = Ledger.AvgCost(ns.db.ledger, r.itemID)
        local cost = avg and math.floor(avg * r.qty + 0.5) or nil
        local left = ns.Listings.TimeLeft(r)
        local status
        if r.sold then
            status = GOLD .. "sold|r, money in " .. duration(left)
        else
            local under, lowest = ns.Listings.Undercut(r), ns.Listings.Lowest(r)
            if under then
                status = RED .. "undercut by " .. ns.Money(under) .. "|r"
            elseif lowest == false then
                status = GREEN .. "only yours|r, " .. duration(left) .. " left"
            elseif lowest then
                status = GREEN .. "lowest|r, " .. duration(left) .. " left"
            else
                status = "listed, " .. duration(left) .. " left"
            end
        end
        rows[#rows + 1] = {
            itemID = r.itemID, link = r.link,
            cells = { r.qty .. "x " .. ((r.link and r.link:match("%[(.-)%]")) or ns.MaterialName(r.itemID)), status,
                ns.Money(r.each), ns.Money(gross), ns.Money(net), cost and ns.Money(cost) or (GREY .. "not known|r"),
                cost and signed(net - cost) or "" },
        }
    end
    return rows
end

--- Every sale, newest first. Profit = what you get after the cut - what those materials cost you.
--- A sale is booked when its listing is seen as sold; "money due" = its mail is not taken yet.
function Window.PaidRows()
    local rows = {}
    local sales = ns.db.ledger.sales
    for i = #sales, 1, -1 do
        local s = sales[i]
        local tracked = s.count - (s.untracked or 0)
        local cost, profit
        if tracked <= 0 then
            cost, profit = GREY .. "not known|r", GREY .. "not known|r"
        else
            cost = ns.Money(s.cost) .. ((s.untracked or 0) > 0 and (GREY .. " +" .. s.untracked .. "?|r") or "")
            profit = signed(s.profit)
        end
        rows[#rows + 1] = {
            itemID = s.id,
            cells = { s.count .. "x " .. ns.MaterialName(s.id),
                when(s.t) .. ((s.unpaid or 0) > 0 and (GOLD .. "  money due|r") or ""),
                ns.Money(math.floor(s.gross / s.count + 0.5)),
                ns.Money(s.gross), ns.Money(s.net), cost, profit },
        }
    end
    if #sales == 0 then
        rows[1] = note("No sales yet. A sale is recorded when the addon sees it sold on the auction house, or when "
            .. "you take its mail.")
    end
    return rows
end

--- Both tables of the Sales view, one after the other (your auctions, then the paid sales).
function Window.SaleRows()
    local rows = Window.ListingRows()
    for _, r in ipairs(Window.PaidRows()) do rows[#rows + 1] = r end
    return rows
end

local function bandRange(quality, up)
    local bands = quality == 2 and Data.GREEN or quality == 3 and Data.BLUE or Data.PURPLE
    local lo = 1
    for _, row in ipairs(bands) do
        if row.up == up then break end
        lo = row.up + 1
    end
    return lo .. (up >= 999 and "+" or ("-" .. up))
end

--- "75% · 1-2": how often a material comes and how many.
local function oddsText(chance, min, max)
    return string.format("%d%% · %s", math.floor(chance * 100 + 0.5), min == max and tostring(min) or (min .. "-" .. max))
end

--- Odds: every item level band of every quality and gear type that the filters show, with the table
--- the addon uses and, where you have disenchanted, what you got.
--- @return table  bands { head = the band's row, rows = its material rows }, in the flat list's cell order
function Window.OddsBands()
    local bands = {}
    local by = Ledger.Report(ns.db.ledger)
    local s = ns.db.settings
    local opts = { salvager = ns.SalvagerForBuy(), salvagerChance = s.salvagerChance, cut = s.cut }
    local showQuality, showType, saved = oddsFilter()
    for _, q in ipairs({ { 2, Data.GREEN }, { 3, Data.BLUE }, { 4, Data.PURPLE } }) do
        for _, c in ipairs({ { Data.CLASS_ARMOR, "a", " armor" }, { Data.CLASS_WEAPON, "w", " weapons" } }) do
            for _, band in ipairs((showQuality[q[1]] and showType[c[2]]) and q[2] or {}) do
                local quality, classID, up = q[1], c[1], band.up
                local outcomes = Model.Outcomes(quality, classID, up)
                local mine = by[string.format("%d:%s:%d", quality, c[2], up)]
                local n = mine and mine.n or 0
                if n > 0 or not saved.oddsDataOnly then
                    local v = Model.Value(outcomes, ns.PriceOf, opts)
                    local limit = ns.BuyLimit(quality, classID, up, ns.LimitBasis(v))
                    local entry = { rows = {}, head = {
                        group = true,
                        cells = { QUALITY_COLOR[quality] .. QUALITY_NAME[quality] .. c[3] .. "|r" .. GOLD .. ", item level "
                            .. bandRange(quality, up) .. "|r",
                            n > 0 and tostring(n) or (GREY .. "0|r"), "", "",
                            ns.Money(v.net) .. (#v.missing > 0 and (GREY .. "?|r") or ""),
                            ns.Money(limit),
                            limit > 0 and ns.LoseText(Model.LossChance(outcomes, ns.PriceOf, opts, limit)) or (GREY .. "-|r"),
                            n > 0 and ns.Money(mine.value / n) or (GREY .. "-|r") },
                    } }
                    local inTable = {}
                    for _, r in ipairs(outcomes.results) do
                        inTable[r.id] = true
                        local m = mine and mine.mats[r.id]
                        local price = ns.PriceOf(r.id)
                        entry.rows[#entry.rows + 1] = {
                            itemID = r.id, indent = INDENT,
                            cells = { ns.MaterialName(r.id), m and tostring(m.hits) or (GREY .. "0|r"),
                                oddsText(r.chance, r.min, r.max),
                                n > 0 and string.format("%d%%%s", math.floor((m and m.hits or 0) / n * 100 + 0.5),
                                    m and string.format(" · %.2f", m.qty / m.hits) or "") or (GREY .. "-|r"),
                                price and (ns.Money(price) .. " each") or (GREY .. "no price|r"), "", "", "" },
                        }
                    end
                    -- What came that the table does not have for this band.
                    for id, m in pairs(mine and mine.mats or {}) do
                        if not inTable[id] then
                            entry.rows[#entry.rows + 1] = {
                                itemID = id, indent = INDENT,
                                cells = { ns.MaterialName(id), tostring(m.hits), RED .. "not expected|r",
                                    string.format("%d%% · %.2f", math.floor(m.hits / n * 100 + 0.5), m.qty / m.hits),
                                    "", "", "", "" },
                            }
                        end
                    end
                    bands[#bands + 1] = entry
                end
            end
        end
    end
    return bands
end

local function oddsNote()
    local _, _, saved = oddsFilter()
    return saved.oddsDataOnly and "No disenchants yet in the selected bands. Untick \"Only bands with my data\" "
        .. "to see the tables." or "Nothing selected: pick a quality and a gear type above."
end

--- The same as one flat list: each band's row, then its material rows.
function Window.OddsRows()
    local rows = {}
    for _, band in ipairs(Window.OddsBands()) do
        rows[#rows + 1] = band.head
        for _, r in ipairs(band.rows) do rows[#rows + 1] = r end
    end
    if #rows == 0 then rows[1] = note(oddsNote()) end
    return rows
end

-- The Odds view shows each band as a table of its own.
local ODDS_COLUMNS = {
    { "Material", 150 },
    { "Drops", 50, "CENTER", help = { "Drops", "How many of your own disenchants in this band gave this material." } },
    { "Expected", 90, "CENTER", help = { "Expected", "How often this material comes from one disenchant in this band, "
        .. "and how many, by the odds table the addon uses (Classic's table; not confirmed for Forever)." } },
    { "You got", 96, "CENTER", help = { "You got", "How often it came in your own disenchants in this band, and how "
        .. "many on average." } },
    { "Price now", 110, "RIGHT", help = { "Price now", "What one of this material costs on the auction house now, "
        .. "from your last material scan. Value now is worked out from these prices." } },
}
local BAND_HELP = { "This band", "Disenchants: how many of yours are in this band.\n\n"
    .. "Value now: what ONE disenchant is worth on average over many, at today's material prices, after the 5% cut. "
    .. "It is not the buy limit.\n\n"
    .. "Buy below: the most the addon lets you pay: Value now minus your minimum profit, or the limit you set in the "
    .. "Limits tab.\n\n"
    .. "Lose: the chance that one disenchant is worth less than Buy below, so the risk when you pay the full limit.\n\n"
    .. "Your average: what your own disenchants gave on average, at the prices of the moment. Compare it with Value now." }

--- One card per band for the Odds view.
function Window.OddsCards()
    local cards = {}
    local function fact(label, value) return GREY .. label .. "|r " .. value end
    for _, band in ipairs(Window.OddsBands()) do
        local c = band.head.cells
        cards[#cards + 1] = {
            title = c[1],
            facts = table.concat({ fact("Disenchants", c[2]), fact("Value now", c[5]), fact("Buy below", c[6]),
                fact("Lose", c[7]), fact("Your average", c[8]) }, "     "),
            factsHelp = BAND_HELP, rows = band.rows,
        }
    end
    if #cards == 0 then cards[1] = { title = GREY .. oddsNote() .. "|r", rows = {} } end
    return cards
end

--- The two lines above the list.
function Window.Summary()
    local bought, spent, done, got, waiting, waitingCost = 0, 0, 0, 0, 0, 0
    local waitingBy = {}
    for _, e in ipairs(Ledger.History(ns.db.ledger)) do
        if e.paid then bought, spent = bought + 1, spent + e.paid end
        if e.done then
            done, got = done + 1, got + (e.got or 0)
        else
            waiting, waitingCost = waiting + 1, waitingCost + (e.paid or 0)
            if e.itemID then waitingBy[e.itemID] = (waitingBy[e.itemID] or 0) + 1 end
        end
    end
    local t = ns.Report.Totals()
    local line1 = string.format("%sBought|r %d items for %s    %sDisenchanted|r %d, materials worth %s after the cut",
        GOLD, bought, ns.Money(spent), GOLD, done, ns.Money(got))
    if waiting > 0 then
        -- Where those items are: counted in the bags and the bank; the rest is taken to be in the mail.
        local bags, bank = 0, 0
        for id, n in pairs(waitingBy) do
            local okA, inBags = pcall(ns.GetItemCount, id)
            local okB, withBank = pcall(ns.GetItemCount, id, true)
            inBags = math.min(n, okA and tonumber(inBags) or 0)
            bags = bags + inBags
            bank = bank + math.min(n - inBags, math.max(0, (okB and tonumber(withBank) or 0) - inBags))
        end
        local where = {}
        if bags > 0 then where[#where + 1] = bags .. " in bags" end
        if bank > 0 then where[#where + 1] = bank .. " in bank" end
        if waiting - bags - bank > 0 then where[#where + 1] = (waiting - bags - bank) .. " in mail or gone" end
        line1 = line1 .. string.format("    %sBought, not disenchanted yet|r %d (%s): %s", GOLD, waiting,
            ns.Money(waitingCost), table.concat(where, ", "))
    end
    local line2 = string.format("%sSold|r %d materials for %s after the cut    %sProfit on sales|r %s",
        GOLD, t.sold, ns.Money(t.soldNet), GOLD, signed(t.soldProfit))
    return line1, line2
end

local SOURCES = { purchases = Window.PurchaseRows, sales = Window.SaleRows, odds = Window.OddsRows }

------------------------------------------------------------------ the window

--- The Odds view: the three filters and the stack of tables, one per band. The caller anchors its parts.
--- The ledger window has one, and the popped-out odds window has one.
function newOddsView(parent)
    local view = {}
    local function changed()
        view.stack.offset = 0
        Window.Refresh()
    end
    view.typeFilter = W.CheckDropdown(parent, 150, { { "a", "Armor" }, { "w", "Weapons" } },
        function(k) return select(2, oddsFilter())[k] end,
        function(k, on)
            select(2, oddsFilter())[k] = on
            changed()
        end, "Which gear types the odds list.", "Gear type")
    view.qualityFilter = W.CheckDropdown(parent, 170, {
        { 2, "|cff1eff00Uncommon|r" }, { 3, "|cff0070ddRare|r" }, { 4, "|cffa335eeEpic|r" },
    }, function(q) return (oddsFilter())[q] end, function(q, on)
        (oddsFilter())[q] = on
        changed()
    end, "Which qualities the odds list.", "Quality")
    view.dataOnly = W.Check(parent, "Only bands with my data",
        "Lists only the item level bands you have disenchanted in. Untick it to see the table of every band.",
        function(on)
            select(3, oddsFilter()).oddsDataOnly = on
            changed()
        end)
    view.stack = W.CardList(parent)
    view.stack:SetColumns(ODDS_COLUMNS)
    function view:SetShown(on)
        self.typeFilter:SetShown(on)
        self.qualityFilter:SetShown(on)
        self.dataOnly:SetShown(on)
        self.stack:SetShown(on)
    end
    function view:Refresh()
        self.dataOnly:SetChecked(select(3, oddsFilter()).oddsDataOnly and true or false)
        self.qualityFilter:Update()
        self.typeFilter:Update()
        self.stack:SetCards(Window.OddsCards())
        self.stack:Refresh()
    end
    return view
end

function Window.Refresh()
    if oddsFrame and oddsFrame:IsShown() then oddsOut:Refresh() end
    if not f or not f:IsShown() then return end
    -- While the odds are in their own window, the ledger shows another view.
    if Window.view == "odds" and Window.OddsPoppedOut() then Window.view = "sales" end
    -- Sales is two tables, each in its own panel; the other views are one.
    local split = Window.view == "sales"
    local odds = Window.view == "odds"
    list:SetShown(not split and not odds)
    oddsView:SetShown(odds)
    for _, part in ipairs(salesParts) do part:SetShown(split) end
    if split then
        local l = ns.db.listings
        salesParts[1]:SetText(GOLD .. "On the auction house|r" .. (l.t and (GREY .. "  as of " .. date("%H:%M", l.t) .. "|r") or ""))
        salesParts[3]:SetText(GOLD .. "Sold|r" .. GREY .. "  every sale, newest first; \"money due\" = its mail is not taken yet|r")
        -- The upper table takes a little under half of the room.
        local room = (f:GetHeight() or 0) - 98 - 14 - 2 * 20
        salesParts[2]:SetHeight(math.max(66, math.floor(room * 0.45)))
        local listed, paid = Window.ListingRows(), Window.PaidRows()
        salesParts[2]:SetSource(#listed, function(i) return listed[i] end)
        salesParts[2]:Refresh()
        salesParts[4]:SetSource(#paid, function(i) return paid[i] end)
        salesParts[4]:Refresh()
    elseif odds then
        oddsView:Refresh()
    else
        local rows = SOURCES[Window.view]()
        list:SetColumns(COLUMNS[Window.view])
        list:SetSource(#rows, function(i) return rows[i] end)
        list:Refresh()
    end
    local a, b = Window.Summary()
    summary[1]:SetText(a)
    summary[2]:SetText(b)
    for name, button in pairs(tabs) do
        if name == Window.view then button:LockHighlight() else button:UnlockHighlight() end
    end
    -- The two listing buttons belong to the Sales view.
    local sales = Window.view == "sales"
    checkButton:SetShown(sales)
    cancelButton:SetShown(sales)
    if sales then
        local c, n = ns.Listings.checking, ns.Listings.CountUndercut()
        -- Only what is still for sale can be undercut: sold auctions are not checked.
        local unsold = ns.Listings.CountUnsold()
        checkButton:SetText(c and string.format("Checking %d/%d", c.done, c.total)
            or string.format("Check undercuts (%d)", unsold))
        checkButton:SetEnabled(ns.Queue.open and not c and unsold > 0)
        cancelButton:SetText(ns.Listings.Cancelling() and "Cancelling..." or string.format("Cancel undercut (%d)", n))
        cancelButton:SetEnabled(ns.Queue.open and n > 0 and not ns.Listings.Cancelling())
    end
end

local function build()
    f = W.Window("SalvagerLedgerFrame", "Salvager ledger", "ledger", 860, 480, 800, 260)
    summary = {}
    for i = 1, 2 do
        local l = W.Label(f, "", "GameFontHighlightSmall")
        l:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -14 - i * 16)
        l:SetPoint("RIGHT", f, "RIGHT", -14, 0)
        l:SetJustifyH("LEFT")
        l:SetWordWrap(false)
        summary[i] = l
    end
    local x = 12
    for _, t in ipairs({ { "sales", "Sales" }, { "purchases", "Purchases" }, { "odds", "Odds" } }) do
        local b = W.Button(f, t[2], 96, function()
            -- The Odds tab, while the odds are in their own window: put them back here.
            if t[1] == "odds" then Window.OddsPutBack() end
            Window.view = t[1]
            f.saved.view = t[1]
            list.offset = 0
            oddsView.stack.offset = 0
            Window.Refresh()
        end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -68)
        tabs[t[1]] = b
        x = x + 100
    end
    W.Tooltip(tabs.purchases, "Purchases", "Every item you bought, newest first. Under each one: what it was disenchanted "
        .. "into, the part of its price given to each material, and what each was worth then.")
    W.Tooltip(tabs.sales, "Sales", "Your auctions: what is listed, and what is sold with its money on the way. Below "
        .. "them, every sale already paid. Profit = what you get after the cut, minus what those materials cost you.")
    W.Tooltip(tabs.odds, "Odds", "Every item level band of every quality and gear type. Expected = how often each "
        .. "material comes and how many (the table the addon uses). You got = what your own disenchants gave. Value "
        .. "now = what one disenchant is worth on average at today's prices, after the cut. Buy below = the buy "
        .. "limit; Lose % = the chance one disenchant is worth less than it. Point at a column title for more.")
    local clear = W.Button(f, "Clear history", 110, function() StaticPopup_Show("SALVAGER_CLEAR_LEDGER") end,
        "Removes the list of purchases, disenchants and sales, and with them the Odds. Your material stock and its "
        .. "costs stay, and so do purchases you have not disenchanted yet. It asks first.")
    clear:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -68)
    cancelButton = W.Button(f, "Cancel undercut (0)", 150, function() ns.Listings.CancelNext() end,
        "Cancels one undercut listing per click (the game wants a click for each). The materials come back by mail, "
        .. "and the auction house keeps its deposit. Needs the auction house open, and a check first.")
    cancelButton:SetPoint("RIGHT", clear, "LEFT", -6, 0)
    checkButton = W.Button(f, "Check undercuts (0)", 150, function() ns.Listings.Check() end,
        "Searches each material you still have for sale and compares your price with the lowest listing that is not "
        .. "yours. Auctions that are sold are not checked. The number is how many listings are still for sale. "
        .. "About one second per material. Needs the auction house open.")
    checkButton:SetPoint("RIGHT", cancelButton, "LEFT", -6, 0)
    oddsView = newOddsView(f)
    oddsView.typeFilter:SetPoint("RIGHT", clear, "LEFT", -6, 0)
    oddsView.qualityFilter:SetPoint("RIGHT", oddsView.typeFilter, "LEFT", -6, 0)
    oddsView.dataOnly:SetPoint("TOPRIGHT", f, "TOPRIGHT", -190, -38)
    oddsView.stack:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -98)
    oddsView.stack:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    -- Right next to the Odds tab: the odds in a window of their own, and back.
    local popOut = W.IconButton(f, 22, function()
        if Window.OddsPoppedOut() then Window.OddsPutBack() else Window.OddsPopOut() end
    end)
    popOut:SetPoint("LEFT", tabs.odds, "RIGHT", 0, 0)
    popOut:SetPopOutGlyph()
    popOut:SetScript("OnEnter", function(self)
        local out = Window.OddsPoppedOut()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(out and "Put the odds back" or "Pop out the odds", 1, 1, 1)
        GameTooltip:AddLine(out and "Closes their window and shows them in the Odds tab again."
            or "Moves the odds to a window of their own. Click again, or close that window, to put them back.",
            1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    popOut:SetScript("OnLeave", function() GameTooltip:Hide() end)
    list = W.List(f, { rowHeight = 22 })
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -98)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    -- The Sales view: a title and a table for your auctions, a title and a table for the paid sales.
    local titleA = W.Label(f, "", "GameFontNormal")
    titleA:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -100)
    local listA = W.List(f, { rowHeight = 22 })
    listA:SetColumns(COLUMNS.listed)
    listA:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -118)
    listA:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -118)
    listA:SetHeight(120)
    local titleB = W.Label(f, "", "GameFontNormal")
    titleB:SetPoint("TOPLEFT", listA, "BOTTOMLEFT", 2, -6)
    local listB = W.List(f, { rowHeight = 22 })
    listB:SetColumns(COLUMNS.paid)
    listB:SetPoint("TOPLEFT", listA, "BOTTOMLEFT", 0, -24)
    listB:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    salesParts = { titleA, listA, titleB, listB }
    if SOURCES[f.saved.view] then Window.view = f.saved.view end
    f.onResize = Window.Refresh
    f:SetScript("OnShow", Window.Refresh)
end

StaticPopupDialogs["SALVAGER_CLEAR_LEDGER"] = {
    text = "Clear the Salvager ledger history?\n\nThis removes the list of purchases, disenchants and sales, and the Odds "
        .. "learned from them. Your material stock and its costs stay, and so do purchases you have not disenchanted yet.",
    button1 = "Clear history",
    button2 = "Cancel",
    OnAccept = function()
        local n = Ledger.ClearHistory(ns.db.ledger, ns.NoDisenchant)
        ns.Print("ledger history cleared (%d entries)", n)
        ns.Log("ledger history cleared (%d entries)", n)
        ns.Fire("SALVAGER_LEDGER")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function buildOdds()
    oddsFrame = W.Window("SalvagerOddsFrame", "Salvager odds", "odds", 760, 520, 640, 240)
    oddsOut = newOddsView(oddsFrame)
    oddsOut.dataOnly:SetPoint("TOPLEFT", oddsFrame, "TOPLEFT", 12, -29)
    oddsOut.typeFilter:SetPoint("TOPRIGHT", oddsFrame, "TOPRIGHT", -12, -30)
    oddsOut.qualityFilter:SetPoint("RIGHT", oddsOut.typeFilter, "LEFT", -6, 0)
    oddsOut.stack:SetPoint("TOPLEFT", oddsFrame, "TOPLEFT", 12, -60)
    oddsOut.stack:SetPoint("BOTTOMRIGHT", oddsFrame, "BOTTOMRIGHT", -12, 14)
    oddsFrame.onResize = Window.Refresh
    oddsFrame:SetScript("OnShow", Window.Refresh)
    oddsFrame:SetScript("OnHide", Window.Refresh)
end

function Window.OddsPoppedOut()
    return oddsFrame ~= nil and oddsFrame:IsShown()
end

--- Moves the odds to their own window.
function Window.OddsPopOut()
    if not oddsFrame then buildOdds() end
    oddsFrame.UserShow()
    ns.Log("odds popped out")
end

--- Puts the odds back in the ledger window's tab.
function Window.OddsPutBack()
    if Window.OddsPoppedOut() then
        oddsFrame.UserHide()
        ns.Log("odds put back")
    end
end

function Window.Toggle()
    if not f then build() end
    f.UserToggle()
end

function Window.Show()
    if not f then build() end
    f.UserShow()
end

--- Opens the window again if it was open the last time (the auction house opened).
function Window.Restore()
    local saved = ns.db.windows.ledger
    if saved and saved.open then
        if not f then build() end
        f:Show()
    end
    local odds = ns.db.windows.odds
    if odds and odds.open then
        if not oddsFrame then buildOdds() end
        oddsFrame:Show()
    end
end

for _, e in ipairs({ "SALVAGER_LEDGER", "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS", "SALVAGER_LISTINGS",
    "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do
    ns.On(e, function() Window.Refresh() end)
end

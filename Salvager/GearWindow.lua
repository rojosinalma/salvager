-- Salvager: the Gear details window. A click on an auction's row in the main window's Gear tab shows that auction
-- as a report: the gear, the deal, how its Expected value is built, your history with this gear and its band, and the
-- other auctions of the same gear in the list. Buy at the bottom right (the row's own buy path), Close last.
local _, ns = ...

local Ledger, Model, Data, W = ns.Ledger, ns.Model, ns.Data, ns.Widgets

local Gear = {}
ns.GearWindow = Gear

local GREY, GOLD, GREEN, RED = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040"
local WIDTH, HEIGHT, MIN_H = 620, 700, 620
local TOP, ROW_H, FEW, SUB = 78, 22, 20, 14
local f, icon, nameText, nameArea, facts, buyButton, closeButton
local parts = {}   -- per section: { title = label, list = Widgets.List }

local function grey(t) return GREY .. t .. "|r" end
local function money(c) return c and ns.MoneyColumn(math.floor(c + 0.5)) or grey("-") end
-- Every amount with its sign, green when it gains, red when it loses, forecasts too (UI.md Tables 7).
local function real(c)
    c = math.floor((c or 0) + 0.5)
    if c == 0 then return ns.MoneyColumn(0) end
    return (c > 0 and (GREEN .. "+") or (RED .. "-")) .. ns.MoneyColumn(math.abs(c)) .. "|r"
end
local function est(c) return real(c) end
local function pct(part, whole)
    if not whole or whole == 0 then return grey("-") end
    local p = math.floor(part / whole * 100 + 0.5)
    return p == 0 and "+0%" or string.format("%s%+d%%|r", p > 0 and GREEN or RED, p)
end
local function count(n) return n < FEW and grey(tostring(n)) or tostring(n) end

--- The gear's name for the window: its link where the auction has one.
local function nameOf(d)
    return d.link or (ns.GetItemInfo(d.itemID)) or ("gear " .. tostring(d.itemID))
end
local function plainName(d)
    return (d.link and d.link:match("%[(.-)%]")) or (ns.GetItemInfo(d.itemID)) or ("gear " .. tostring(d.itemID))
end

--- The auction shown, as the Gear list has it now (a scan makes new rows for the same auction); nil when it left the
--- list. The window keeps showing what it had (UI.md Actions 4).
local function live()
    local id = Gear.deal and Gear.deal.auctionID
    for _, d in ipairs(ns.Scanner.deals) do
        if d.auctionID == id then return d end
    end
    return nil
end

--- The band of the auction's gear and its buy limit: { band, limit, setBy }.
function Gear.Limit(d)
    local s = ns.db.settings
    for _, row in ipairs(ns.Limits(true)) do
        if row.quality == d.quality and (d.ilvl or 0) >= row.lo and (d.ilvl or 0) <= row.up then
            local x = d.classID == Data.CLASS_WEAPON and row.weapon or row.armor
            if not x then return nil end
            local limit, setBy = x.limit, x.manual and "You (Limits)" or (x.rule == "return" and "Min return" or "Min profit")
            if s.maxPrice > 0 and s.maxPrice < limit then limit, setBy = s.maxPrice, "Max price" end
            return { band = x.band, limit = limit, setBy = setBy }
        end
    end
    return nil
end

------------------------------------------------------------------ the sections

local SECTIONS = {
    -- The deal, as a statement (UI.md Statements): + comes in, - goes out; the total is the sum of the lines.
    deal = { title = "The deal: one disenchant, on average", columns = { { "What", 260 },
        { "Amount", 90, "RIGHT", help = { "Amount", "Gold, silver and copper; + comes in, - goes out. Grey: a "
            .. "forecast at today's prices, not gold you have." } }, statement = true } },
    measures = { title = "Return and risk", columns = {
        { "Return", 50, "RIGHT", help = { "Return", "Expected profit as a share of the buyout." } },
        { "Loss chance", 60, "RIGHT", help = { "Loss chance", "The chance that ONE disenchant is worth less than "
            .. "the buyout, after the cut." } },
        { "Buy limit", 80, "RIGHT", help = { "Buy limit", "The most the scan pays for one piece of gear of this band." } },
        { "Limit set by", 80, "LEFT", help = { "Limit set by", "What sets the buy limit: your Min profit, your Min "
            .. "return (when that asks for more), a limit you typed in the Limits window, or your Max price." } },
        { "Time to sell", 90, "RIGHT", help = { "Time to sell", "How long its materials take to sell, from the post "
            .. "to the sale, by their part of the value (counted as 1 day at least)." } },
        { "Return per day", 80, "RIGHT", help = { "Return per day", "Return divided by the days until the materials "
            .. "sell (at least 1)." } } } },
    build = { title = "How the Expected value is built", columns = { { "Material", 170 },
        { "Rate used", 60, "RIGHT", help = { "Rate used", "How often one disenchant of this band gives it: the "
            .. "table blended with your own results of the band." } },
        { "Quantity used", 76, "RIGHT", help = { "Quantity used", "How many come on average when it comes, by the "
            .. "same blend (the Salvager bonus in it when buying counts it)." } },
        { "Value each", 80, "RIGHT", help = { "Value each", "What one unit is worth to the forecast: its price times "
            .. "its sell price ratio, after the auction house cut, less the deposits lost per unit sold." } },
        { "Part of the value", 90, "RIGHT", help = { "Part of the value", "Rate used × Quantity used × Value each. "
            .. "The parts add up to the Expected value." } } } },
    history = { title = "Your history with this gear and its band", columns = { { "Gear or band", 200 },
        { "Disenchanted", 70, "RIGHT", help = { "Disenchanted", "Pieces you bought and disenchanted, with a recorded "
            .. "price. Grey: fewer than 20, too few to trust." } },
        { "Paid", 80, "RIGHT" },
        { "Sold value", 80, "RIGHT", help = { "Sold value", "Their materials at what one unit really sold for on "
            .. "average, after the cut (at their disenchant value while a material has not sold yet)." } },
        { "Profit", 80, "RIGHT", help = { "Profit", "Sold value minus Paid." } },
        { "Return", 50, "RIGHT", help = { "Return", "Profit as a share of Paid." } } } },
    others = { title = "Other auctions of this gear in the list", columns = { { "Buyout", 90, "RIGHT" },
        { "Expected profit", 90, "RIGHT" },
        { "Under the limit by", 100, "RIGHT", help = { "Under the limit by", "The buy limit minus the buyout: how much "
            .. "dearer it could be and still be a deal. A - sign: over the limit." } },
        { "State", 90, "LEFT" } } },
}
local ORDER = { "deal", "measures", "build", "history", "others" }

function Gear.DealRows(d)
    return {
        { cells = { "Expected value of one disenchant", est(d.value) }, indent = SUB, tip = { "Expected value",
            "What one disenchant of this gear is worth on average over many, after the cut: the table below." } },
        { cells = { "Buyout", "-" .. ns.MoneyColumn(d.buyout) }, indent = SUB, tip = { "Buyout",
            "What this auction costs: it goes out." } },
        { cells = { "Expected profit", est(d.profit) }, rule = "final", bold = true, tip = { "Expected profit",
            "Expected value minus the buyout. An average over many disenchants, not what one gives." } },
    }
end

function Gear.MeasureRows(d)
    local lim = Gear.Limit(d)
    local perDay = ns.Scanner.ReturnPerDay(d)
    local few = d.daysFew and " (few sales)" or ""
    return { { cells = { grey(string.format("%+d%%", math.floor(ns.Scanner.Return(d) * 100 + 0.5))), ns.LoseText(d.lose),
        lim and ns.MoneyColumn(lim.limit) or grey("-"), lim and lim.setBy or grey("-"),
        d.days and ((d.daysFew and GREY or "") .. ns.DurationText(d.sellSeconds) .. few .. (d.daysFew and "|r" or ""))
            or grey("not known yet"),
        perDay and grey(string.format("%+.1f%%", perDay * 100)) or grey("not known yet") } } }
end

--- The rows of the Expected value's build, and the facts for its title (how many of your results the rates rest on).
function Gear.BuildRows(d)
    local opts = ns.ValueOptions()
    local outcomes = ns.Outcomes(d.quality, d.classID, d.ilvl, opts.salvager)
    if not outcomes then return { { cells = { grey("Not known: this gear's band has no disenchant table."), "" } } }, "" end
    local b = Model.ValueBuild(outcomes, ns.PriceOf, opts)
    local rows = {}
    for _, r in ipairs(b.rows) do
        rows[#rows + 1] = { itemID = r.id, cells = { ns.MaterialName(r.id),
            string.format("%d%%", math.floor(r.chance * 100 + 0.5)), string.format("%.2f", r.qty),
            r.unit and money(r.unit) or grey("no price"), r.part and money(r.part) or grey("-") } }
    end
    -- The totals row is the last one (UI.md Tables 13); what is the same for every row is in the title (Tables 3).
    rows[#rows + 1] = { rule = "total", bold = true, cells = { "Expected value, now", "", "", "", money(b.total) } }
    local from = string.format("rates from the table and %d of your disenchants of this band%s, %s", outcomes.n,
        outcomes.few and " (few results)" or "", outcomes.salvager and "with the Salvager" or "without the Salvager")
    if math.abs(math.floor(b.total + 0.5) - (d.value or 0)) >= 1 then
        from = from .. "; prices moved since the scan (it showed " .. ns.Money(d.value) .. ")"
    end
    return rows, from
end

function Gear.HistoryRows(d)
    local p = Ledger.Profits(ns.db.ledger)
    local lim = Gear.Limit(d)
    local band = lim and lim.band
    local item, ofBand
    for _, it in ipairs(p.items) do if it.itemID == d.itemID then item = it end end
    for _, g in ipairs(p.groups) do
        for _, b in ipairs(g.bands) do
            if b.quality == d.quality and b.classID == d.classID and b.band == band then ofBand = b end
        end
    end
    local function row(label, x)
        if not x or x.n == 0 then return { cells = { label, grey("0"), grey("-"), grey("-"), grey("-"), grey("-") } } end
        local profit = math.floor(x.sold + 0.5) - x.paid
        return { cells = { label, count(x.n), money(x.paid), money(x.sold), real(profit), pct(profit, x.paid) } }
    end
    return { row(plainName(d), item),
        row("Its band: " .. (band and ns.BandShort(d.quality, d.classID, band) or "?"), ofBand) }
end

function Gear.OtherRows(d)
    local lim = Gear.Limit(d)
    local name, list = plainName(d), {}
    for _, x in ipairs(ns.Scanner.deals) do
        if x.auctionID ~= d.auctionID and plainName(x) == name then list[#list + 1] = x end
    end
    table.sort(list, function(a, b) return a.buyout < b.buyout end)
    local rows = {}
    for _, x in ipairs(list) do
        local room = lim and (lim.limit - x.buyout)
        rows[#rows + 1] = { cells = { ns.MoneyColumn(x.buyout), est(x.profit),
            room and ((room < 0 and "-" or "") .. ns.MoneyColumn(math.abs(room))) or grey("-"),
            x.pending and "being bought" or "" } }
    end
    if #rows == 0 then rows[1] = { cells = { grey("None: this is the only auction of this gear in the list."), "", "", "" } } end
    return rows
end

------------------------------------------------------------------ the window

--- Why Buy cannot buy now, or nil. `d` = the auction as the list has it now.
function Gear.BuyReason(d)
    if not d then return "This auction is no longer in the Gear list: it sold, or the last scan did not find it." end
    if d.pending then return "This auction is being bought." end
    if d.wait == "search" then
        return "Searching this gear again first (a scan browse came after its search): Buy now comes in a moment."
    end
    if d.wait then return "Waiting for the auction house: Buy now comes the moment it is ready." end
    if not ns.Queue.open then return "Open the auction house first." end
    if (GetMoney() or 0) < d.buyout then return "Not enough gold for it (" .. ns.Money(d.buyout) .. ")." end
    return nil
end

local function show(part, rows)
    part.list:SetSource(#rows, function(i) return rows[i] end)
    part.list:Refresh()
end

function Gear.Refresh()
    if not f or not f:IsShown() or not Gear.deal then return end
    local now = live()
    if now then Gear.deal = now end
    local d = Gear.deal
    icon:SetTexture(W.IconOf(d.itemID))
    nameText:SetText(nameOf(d))
    nameArea.link = d.link or ("item:" .. d.itemID)
    local lim = Gear.Limit(d)
    facts:SetText(table.concat({ ns.QualityText(d.quality), ns.CLASS_LABEL[d.classID] or "?",
        "Item level " .. tostring(d.ilvl or "?"),
        "Band " .. (lim and ns.BandRange(d.quality, lim.band) or "?") }, GREY .. "  ·  |r")
        .. GREY .. "  ·  this auction, as of the last scan|r")
    local buildRows, from = Gear.BuildRows(d)
    local rows = { deal = Gear.DealRows(d), measures = Gear.MeasureRows(d), build = buildRows,
        history = Gear.HistoryRows(d), others = Gear.OtherRows(d) }
    -- Top to bottom; each table as tall as its rows, the last one takes the rest and scrolls.
    local y = TOP
    for i, key in ipairs(ORDER) do
        local part = parts[key]
        part.title:ClearAllPoints()
        part.title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -y)
        part.title:SetPoint("RIGHT", f, "RIGHT", -14, 0)
        part.title:SetJustifyH("LEFT")
        part.title:SetText(GOLD .. SECTIONS[key].title .. "|r" .. (key == "build" and (GREY .. "  " .. from .. "|r") or ""))
        -- A long title wraps and pushes its table down (UI.md Layout 6).
        y = y + math.max(18, math.ceil(tonumber((part.title:GetStringHeight())) or 12) + 6)
        part.list:ClearAllPoints()
        part.list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -y)
        if i < #ORDER then
            local h = (#rows[key] + 1) * ROW_H + 4
            part.list:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -y)
            part.list:SetHeight(h)
            y = y + h + 6
        else
            part.list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 40)
        end
        show(part, rows[key])
    end
    -- As wide as its tables' columns need, up to the screen (SDD 107).
    local lists = {}
    for _, key in ipairs(ORDER) do lists[#lists + 1] = parts[key].list end
    if W.FitTables(f, WIDTH, lists) then for _, l in ipairs(lists) do l:Refresh() end end
    local why = Gear.BuyReason(now)
    buyButton:SetEnabled(why == nil)
    buyButton.reason = why
    -- (As the Gear list's Buy: "Buy now", lit, when the auction house is ready for a click that waited, SDD 105.)
    local buyNow = now and now.buyNow and not why
    buyButton:SetText(buyNow and "Buy now" or (now and (now.pending or now.wait)) and "..." or "Buy")
    if buyNow then buyButton:LockHighlight() else buyButton:UnlockHighlight() end
end

local function build()
    -- As wide as its tables; the height is the player's (the last table scrolls).
    f = W.Window("SalvagerGearFrame", "Salvager Gear Details", "gear", WIDTH, HEIGHT, WIDTH, MIN_H, "vertical")
    -- The heading (UI.md Statements 1): what it is, the gear with its icon; its name shows the game's tooltip.
    icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(32, 32)
    icon:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    nameText = W.Label(f, "", "GameFontNormalLarge")
    nameText:SetPoint("TOPLEFT", icon, "TOPRIGHT", 8, -1)
    nameArea = CreateFrame("Frame", nil, f)
    nameArea:SetAllPoints(nameText)
    nameArea:EnableMouse(true)
    nameArea:SetScript("OnEnter", function(self)
        if not self.link then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetHyperlink(self.link)
        GameTooltip:Show()
    end)
    nameArea:SetScript("OnLeave", function() GameTooltip:Hide() end)
    facts = W.Label(f, "", "GameFontHighlightSmall")
    facts:SetPoint("TOPLEFT", nameText, "BOTTOMLEFT", 0, -5)
    facts:SetPoint("RIGHT", f, "RIGHT", -14, 0)
    facts:SetJustifyH("LEFT")
    facts:SetWordWrap(false)
    for _, key in ipairs(ORDER) do
        local title = W.Label(f, "", "GameFontNormal")
        local list = W.List(f, { rowHeight = ROW_H })
        list:SetColumns(SECTIONS[key].columns)
        parts[key] = { title = title, list = list }
    end
    -- The footer: Buy, the main action, at the right; Close last (UI.md Actions 5).
    local footer = W.Bar(f, "footer"):PlaceBottom(8, 12, 24)
    closeButton = W.Button(footer, "Close", 70, function() f.UserHide() end, "Closes this window.")
    footer:AddRight(closeButton, 70)
    buyButton = W.Button(footer, "Buy", 80, function()
        local d = live()
        if d and not Gear.BuyReason(d) then ns.Scanner.Buy(d) end
    end)
    buyButton:SetMotionScriptsWhileDisabled(true)
    buyButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Buy", 1, 1, 1)
        if self.reason then
            GameTooltip:AddLine(self.reason, 1, 0.3, 0.3, true)
        else
            GameTooltip:AddLine("Buys this auction for " .. ns.Money(Gear.deal.buyout) .. ", as its Buy in the Gear tab "
                .. "does.", 1, 0.82, 0, true)
        end
        GameTooltip:Show()
    end)
    -- (The mouse anywhere over this window holds the scan: UI's `aimedAt`.)
    buyButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    footer:AddRight(buyButton, 80)
    Gear.footer, Gear.parts, Gear.buyButton, Gear.nameArea = footer, parts, buyButton, nameArea   -- (the specs read them)
    f.onResize = Gear.Refresh
    f:SetScript("OnShow", Gear.Refresh)
end

--- Opens the window for an auction of the Gear list; a click on another row replaces it.
function Gear.Open(d)
    if not d then return end
    if not f then build() end
    Gear.deal = d
    f.UserShow()
    if f.Raise then f:Raise() end
    Gear.Refresh()
end

function Gear.Frame() return f end

for _, e in ipairs({ "SALVAGER_DEALS", "SALVAGER_LEDGER", "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS", "PLAYER_MONEY",
    "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do
    ns.On(e, function() Gear.Refresh() end)
end

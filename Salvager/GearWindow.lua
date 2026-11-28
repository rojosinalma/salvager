-- Salvager: the Gear details window. A click on an auction's row in the main window's Gear tab shows that auction
-- as a report: the gear, the deal, every outcome of one disenchant, your history with this gear and its band, and the
-- other auctions of the same gear in the list. Buy at the bottom right (the row's own buy path), Close last.
local _, ns = ...

local Ledger, Data, W = ns.Ledger, ns.Data, ns.Widgets

local Gear = {}
ns.GearWindow = Gear

local GREY, GOLD, GREEN, RED = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040"
local WIDTH, HEIGHT, MIN_H = 620, 780, 620   -- the size it opens with (Widgets.FitTables sets the width)
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
            if x.fromLow and not x.manual then setBy = setBy .. " (low value)" end
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
        { "Avg return", 56, "RIGHT", help = { "Avg return", "The average profit as a share of the buyout (over many "
            .. "pieces)." } },
        { "Loss chance", 60, "RIGHT", help = { "Loss chance", "The chance that ONE disenchant is worth less than "
            .. "the buyout, after the cut." } },
        { "Buy limit", 80, "RIGHT", help = { "Buy limit", "The most the scan pays for one piece of gear of this band." } },
        { "Limit set by", 80, "LEFT", help = { "Limit set by", "What sets the buy limit: your Min profit, your Min "
            .. "return (when that asks for more), a limit you typed in the Limits window, or your Max price. \"(low "
            .. "value)\": the band's rule is not measured on Forever, so the limit rests on its pessimistic value, "
            .. "not the average." } },
        { "Time to sell", 90, "RIGHT", help = { "Time to sell", "How long its materials take to sell, from the post "
            .. "to the sale, by their part of the value (counted as 1 day at least). Grey with * = few sales: it leans "
            .. "on all your sales together." } },
        { "Avg return per day", 80, "RIGHT", help = { "Avg return per day", "The average return divided by the days "
            .. "until the materials sell (at least 1)." } } } },
    build = { title = "What one disenchant gives", columns = {
        { "Outcome", 170, help = { "Outcome", "One disenchant gives whole units of one material: each line is one "
            .. "outcome, the lowest value first; the pessimistic and the optimistic one say so. The last row is the "
            .. "average over many pieces, which no single disenchant gives." } },
        { "Chance", 50, "RIGHT", help = { "Chance", "How often one disenchant of this band gives exactly this: the "
            .. "table blended with your own results of the band (the Salvager bonus in it when buying counts it)." } },
        { "Value", 80, "RIGHT", help = { "Value", "What it is worth to the forecast: its units at the price times the "
            .. "sell price ratio, after the auction house cut, less the deposits lost per unit sold." } },
        { "Profit", 80, "RIGHT", help = { "Profit", "Value minus the buyout of this auction: green a gain, red a "
            .. "loss." } } } },
    history = { title = "Your history with this gear and its band", columns = { { "Gear or band", 200 },
        { "Disenchanted", 70, "RIGHT", help = { "Disenchanted", "Pieces you bought and disenchanted, with a recorded "
            .. "price. Grey: fewer than 20, too few to trust." } },
        { "Paid", 80, "RIGHT" },
        { "Sold value", 80, "RIGHT", help = { "Sold value", "Their materials at what one unit really sold for on "
            .. "average, after the cut (at their disenchant value while a material has not sold yet)." } },
        { "Profit", 80, "RIGHT", help = { "Profit", "Sold value minus Paid." } },
        { "Return", 50, "RIGHT", help = { "Return", "Profit as a share of Paid." } } } },
    others = { title = "Other auctions of this gear in the list", columns = { { "Buyout", 90, "RIGHT" },
        { "Avg profit", 90, "RIGHT", help = { "Avg profit", "The average value minus its buyout, over many pieces." } },
        { "Under the limit by", 100, "RIGHT", help = { "Under the limit by", "The buy limit minus the buyout: how much "
            .. "dearer it could be and still be a deal. A - sign: over the limit." } },
        { "State", 90, "LEFT" } } },
}
local ORDER = { "deal", "measures", "build", "history", "others" }

function Gear.DealRows(d)
    return {
        { cells = { "Average value of one disenchant", est(d.value) }, indent = SUB, tip = { "Average value",
            "What one disenchant of this gear is worth on average over many pieces, after the cut. One disenchant "
            .. "gives one of the outcomes below, not this." } },
        { cells = { "Buyout", "-" .. ns.MoneyColumn(d.buyout) }, indent = SUB, tip = { "Buyout",
            "What this auction costs: it goes out." } },
        { cells = { "Average profit", est(d.profit) }, rule = "final", bold = true, tip = { "Average profit",
            "The average value minus the buyout: the average over many pieces, not what one gives." } },
    }
end

function Gear.MeasureRows(d)
    local lim = Gear.Limit(d)
    local perDay = ns.Scanner.ReturnPerDay(d)
    local few = d.daysFew and "*" or ""
    return { { notes = d.daysFew and { ns.FEW_SALES_NOTE } or nil,
        cells = { grey(string.format("%+d%%", math.floor(ns.Scanner.Return(d) * 100 + 0.5))), ns.LoseText(d.lose),
        lim and ns.MoneyColumn(lim.limit) or grey("-"), lim and lim.setBy or grey("-"),
        d.days and ((d.daysFew and GREY or "") .. ns.DurationText(d.sellSeconds) .. few .. (d.daysFew and "|r" or ""))
            or grey("not known yet"),
        perDay and grey(string.format("%+.1f%%", perDay * 100)) or grey("not known yet") } } }
end

--- Every outcome of one disenchant (SDD 116): one row per whole-unit outcome, lowest value first, with its chance,
--- value and profit against the buyout, the pessimistic and the optimistic one marked on their rows; the average last
--- (the total of chance × value). The facts for the title: what the rates rest on and the rule's evidence.
function Gear.BuildRows(d)
    local opts = ns.ValueOptions()
    local outcomes = ns.Outcomes(d.quality, d.classID, d.ilvl, opts.salvager)
    if not outcomes then return { { cells = { grey("Not known: this gear's band has no disenchant table."), "", "", "" } } }, "" end
    local sp = ns.Spread(outcomes)
    local rows = {}
    -- (The pessimistic and optimistic outcomes are marked on their own rows: real outcomes, UI.md Tables 5.)
    for _, x in ipairs(sp.list) do
        local mark = (x == sp.low and x == sp.high) and "pessimistic and optimistic"
            or x == sp.low and "pessimistic: 9 in 10 get this or more"
            or x == sp.high and ("optimistic: 1 in 10 gets this or more" .. (sp.unproven and (", " .. ns.NOT_PROVEN) or ""))
            or nil
        rows[#rows + 1] = { itemID = x.id, cells = { ns.OutcomeWhat(x) .. (mark and grey("  " .. mark) or ""),
            string.format("%d%%", math.floor(x.chance * 100 + 0.5)), x.missing and grey("no price") or money(x.value),
            real(x.value - d.buyout) }, mark = mark and true or nil }
    end
    -- The totals row is the last one (UI.md Tables 13); what is the same for every row is in the title (Tables 3).
    rows[#rows + 1] = { rule = "total", bold = true, cells = { "Average (over many pieces), now", "",
        money(sp.average), real(sp.average - d.buyout) }, tip = { "Average", "The average over many pieces: the sum "
            .. "of each outcome's chance × its value. One disenchant gives one of the outcomes above, not this." } }
    local from = string.format("rates from the table and %s of this band, %s; rule %s",
        ns.WeightedResultsText(outcomes.n, outcomes.few), outcomes.salvager and "with the Salvager" or "without the Salvager",
        ns.EVIDENCE_TEXT[sp.evidence])
    if math.abs(math.floor(sp.average + 0.5) - (d.value or 0)) >= 1 then
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
        return "Searching this gear again first (a scan browse came after its search): Buy comes back in a moment."
    end
    if not ns.Queue.open then return "Open the auction house first." end
    if not ns.Scanner.Ready() then
        return "The auction house is answering a request (your last purchase or the scan): Buy comes back in a moment "
            .. "by itself."
    end
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
    -- Top to bottom; each table as tall as its rows, the last one takes the rest and scrolls. Where the window is too
    -- low for that, the upper tables give way in proportion, each down to TABLE_MIN (or its rows), so the last one
    -- keeps TABLE_MIN and nothing overlaps (SDD 113).
    local titleH, want, sum, least = {}, {}, 0, 0
    for i, key in ipairs(ORDER) do
        local part = parts[key]
        part.title:ClearAllPoints()
        part.title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -TOP)
        part.title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -TOP)   -- (top and sides only: its height is its lines)
        part.title:SetJustifyH("LEFT")
        part.title:SetText(GOLD .. SECTIONS[key].title .. "|r" .. (key == "build" and (GREY .. "  " .. from .. "|r") or ""))
        -- A long title wraps and pushes its table down (UI.md Layout 6).
        titleH[i] = math.max(18, math.ceil(tonumber((part.title:GetStringHeight())) or 12) + 6)
        if i < #ORDER then
            want[i] = (#rows[key] + 1) * ROW_H + 4
            sum, least = sum + want[i], least + math.min(want[i], W.TABLE_MIN)
        end
    end
    local room = (tonumber((f:GetHeight())) or HEIGHT) - TOP - 40 - 6 * (#ORDER - 1)
    for i = 1, #ORDER do room = room - titleH[i] end
    local spare = room - W.TABLE_MIN   -- (what the upper tables may take)
    local y = TOP
    for i, key in ipairs(ORDER) do
        local part = parts[key]
        part.title:ClearAllPoints()
        part.title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -y)
        part.title:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -y)
        y = y + titleH[i]
        part.list:ClearAllPoints()
        part.list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -y)
        if i < #ORDER then
            local h = want[i]
            if sum > spare then
                -- Each keeps its least height; what is left goes in proportion to what each wants more.
                local m = math.min(want[i], W.TABLE_MIN)
                h = m + math.floor((want[i] - m) * math.max(0, spare - least) / math.max(1, sum - least))
            end
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
    -- (A new width wraps the titles again: laid out once more in it, so no title is cut, 0.4.0.)
        if W.FitTables(f, lists, d.auctionID) and not Gear.relaying then
        Gear.relaying = true
        Gear.Refresh()
        Gear.relaying = false
        return
    end
    W.CheckLayout(f, lists, d.auctionID)   -- (after the last layout: f.checkLater)
    local why = Gear.BuyReason(now)
    buyButton:SetEnabled(why == nil)
    buyButton.reason = why
    -- (As the Gear list's Buy: on means one click buys; off while the auction house answers, 0.4.0.)
    buyButton:SetText((now and (now.pending or now.wait)) and "..." or "Buy")
    buyButton:UnlockHighlight()
end

local function build()
    -- As wide as its tables; the height is the player's (the last table scrolls).
    f = W.Window("SalvagerGearFrame", "Salvager Gear Details", "gear", WIDTH, HEIGHT, WIDTH, MIN_H, "vertical")
    f.layoutName = "gear"
    f.checkLater = true   -- (Gear.Refresh runs the self-check after its last layout)
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
    -- The heading (the name, its facts line) is content too (SDD 120); the tables' titles wrap.
    f.extraNeed = function()
        local function sw(fs) return tonumber((fs:GetStringWidth())) or 0 end
        return math.ceil(14 + 32 + 8 + math.max(sw(nameText), sw(facts)) + 14)
    end
    for _, key in ipairs(ORDER) do
        local title = W.Label(f, "", "GameFontNormal")
        local list = W.List(f, { rowHeight = ROW_H })
        list:SetColumns(SECTIONS[key].columns)
        list.sortId = "gear." .. key   -- (a click on a title sorts it, Widgets.SortRows)
        list.onColumnsChanged = function() Gear.Refresh() end
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
            W.AddHelp(GameTooltip, nil, "Buys this auction for " .. ns.Money(Gear.deal.buyout) .. ", as its Buy in the Gear tab "
                .. "does.")
        end
        GameTooltip:Show()
    end)
    -- (The mouse over this window searches a stale deal again, UI's `dealUnderMouse`; it holds no scan.)
    buyButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    footer:AddRight(buyButton, 80)
    Gear.footer, Gear.parts, Gear.buyButton, Gear.nameArea = footer, parts, buyButton, nameArea   -- (the specs read them)
    f.onResize = Gear.Refresh
    f:HookScript("OnShow", Gear.Refresh)
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

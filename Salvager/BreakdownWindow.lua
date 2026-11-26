-- Salvager: the Breakdown window. Click a material anywhere in the addon to see where it came
-- from: which gear and which item level bands gave it, what it cost from each, and whether
-- that source pays. A window of its own.
local _, ns = ...

local Ledger, Data, W = ns.Ledger, ns.Data, ns.Widgets

local Breakdown = {}
ns.Breakdown = Breakdown

local GREY, GOLD, GREEN, RED = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040"

local function help(title, text) return { title, text } end
local SHARED = {
    { "Disenchants", 70, "CENTER", help = help("Disenchants", "How many of its disenchants gave this material, out of all "
        .. "its disenchants. 20 of 21 = one of them gave something else.") },
    { "Units", 50, "CENTER", help = help("Units", "How many of this material came from it.") },
    { "Cost each", 84, "RIGHT", help = help("Cost each", "What one unit cost you from this source: the part of the "
        .. "purchase prices that went to this material, divided by the units. Only disenchants with a recorded purchase count.") },
    { "Price each", 84, "RIGHT", help = help("Price each", "What one unit brings if you sell it at the price of your last "
        .. "material scan, after the 5% cut.") },
    { "Profit each", 84, "RIGHT", help = help("Profit each", "Price each minus Cost each. Red = each unit from this source "
        .. "costs you more than it sells for now.") },
    { "Source profit", 120, "RIGHT", help = help("Source profit", "The source with everything it gave, not only this material: "
        .. "the value of all its materials at the time of each disenchant, after the cut, minus what you paid. "
        .. "Red = this gear or band has not paid so far. In brackets: how many disenchants it rests on.") },
}
local function columns(first)
    local cols = { { first, 190 } }
    for _, c in ipairs(SHARED) do cols[#cols + 1] = c end
    return cols
end

local f, parts, summary, icon, name = nil, {}, {}, nil, nil

local function signed(c)
    if not c then return GREY .. "not known|r" end
    c = math.floor(c + 0.5)
    return (c >= 0 and GREEN or RED) .. ns.Money(c) .. "|r"
end

--- Is this something the Breakdown window can show? (A disenchanting material.)
function Breakdown.Is(itemID)
    return itemID ~= nil and Data.MATERIAL_BY_ID[itemID] ~= nil
end

--- The rows of one table: sources sorted with the worst per-unit result first.
--- @param sources table  Ledger.Breakdown(...).items or .bands
--- @param label function(source) -> text, itemID or nil
function Breakdown.Rows(sources, matID, label)
    local price = ns.PriceOf(matID)
    local nowEach = price and math.floor(price * (1 - ns.Cut()) + 0.5) or nil
    local list = {}
    for _, s in ipairs(sources) do
        local costEach = s.knownUnits > 0 and (s.cost / s.knownUnits) or nil
        list[#list + 1] = { s = s, costEach = costEach, perUnit = (nowEach and costEach) and (nowEach - costEach) or nil }
    end
    table.sort(list, function(a, b)
        if (a.perUnit == nil) ~= (b.perUnit == nil) then return a.perUnit ~= nil end
        if a.perUnit and a.perUnit ~= b.perUnit then return a.perUnit < b.perUnit end
        return a.s.units > b.s.units
    end)
    local rows = {}
    for _, x in ipairs(list) do
        local s = x.s
        local text, itemID, link = label(s)
        rows[#rows + 1] = {
            itemID = itemID, link = link,
            cells = { text, s.gave .. " of " .. s.all, tostring(s.units),
                x.costEach and ns.Money(x.costEach) or (GREY .. "not known|r"),
                nowEach and ns.Money(nowEach) or (GREY .. "no price|r"),
                signed(x.perUnit),
                s.known > 0 and (signed(s.got - s.paid) .. GREY .. " (" .. s.known .. ")|r") or (GREY .. "not known|r") },
        }
    end
    if #rows == 0 then rows[1] = { cells = { GREY .. "No disenchant gave this material yet.|r" } } end
    return rows
end

local function itemLabel(s)
    local text = s.link or (s.itemID and (ns.GetItemInfo(s.itemID))) or ("gear " .. tostring(s.itemID))
    return text, s.itemID, s.link
end

local function bandLabel(s)
    return ns.BandName(s.quality, s.classID, s.band)
end

--- The two lines above the tables.
function Breakdown.Summary(matID)
    local l = ns.db.ledger
    local b = Ledger.Breakdown(l, matID)
    local line1 = string.format("%sFrom your disenchants|r %d units", GOLD, b.units)
    if b.knownUnits > 0 then
        line1 = line1 .. string.format("    %sCost|r %s each on average (over %d units with a recorded purchase)", GOLD,
            ns.Money(b.cost / b.knownUnits), b.knownUnits)
    end
    local price = ns.PriceOf(matID)
    local sold, net = 0, 0
    for _, s in ipairs(l.sales) do
        if s.id == matID and not s.lost then sold, net = sold + s.count, net + s.net end
    end
    local line2 = string.format("%sPrice now|r %s", GOLD, price and (ns.Money(price) .. " each, "
        .. ns.Money(math.floor(price * (1 - ns.Cut()) + 0.5)) .. " after the cut") or "not scanned")
    if sold > 0 then
        line2 = line2 .. string.format("    %sSold|r %d for %s each after the cut", GOLD, sold, ns.Money(net / sold))
    end
    return line1, line2
end

--- The band table's rows: grouped the one way (gear type, quality, then each band by its range), with headings that
--- open and close (remembered).
function Breakdown.BandRows(matID)
    local b = Ledger.Breakdown(ns.db.ledger, matID)
    local byBand = {}
    for _, s in ipairs(b.bands) do
        local r = Breakdown.Rows({ s }, matID, bandLabel)[1]
        byBand[#byBand + 1] = { quality = s.quality, classID = s.classID, band = s.band, row = r }
    end
    return #byBand > 0 and ns.GroupedRows(byBand, function(e) return e.row end,
        function(_, label) return { group = true, cells = { label } } end, nil,
        { collapsed = ns.GroupState("breakdown.bands"), changed = function() Breakdown.Refresh() end })
        or Breakdown.Rows(b.bands, matID, bandLabel)
end

function Breakdown.Refresh()
    if not f or not f:IsShown() or not Breakdown.matID then return end
    local matID = Breakdown.matID
    local b = Ledger.Breakdown(ns.db.ledger, matID)
    icon:SetTexture(W.IconOf(matID))
    name:SetText(ns.MaterialName(matID))
    local a, c = Breakdown.Summary(matID)
    summary[1]:SetText(a)
    summary[2]:SetText(c)
    parts[1]:SetText(GOLD .. "By gear|r" .. GREY .. "  the worst first|r")
    parts[3]:SetText(GOLD .. "By item level band|r")
    -- The upper table takes a little over half of the room.
    local room = (f:GetHeight() or 0) - 104 - 14 - 2 * 20
    parts[2]:SetHeight(math.max(66, math.floor(room * 0.55)))
    local items = Breakdown.Rows(b.items, matID, itemLabel)
    parts[2]:SetSource(#items, function(i) return items[i] end)
    parts[2]:Refresh()
    local bands = Breakdown.BandRows(matID)
    parts[4]:SetSource(#bands, function(i) return bands[i] end)
    parts[4]:Refresh()
end

local function build()
    f = W.Window("SalvagerBreakdownFrame", "Salvager Breakdown", "breakdown", 800, 480, 720, 320)
    icon = f:CreateTexture(nil, "ARTWORK")
    icon:SetSize(26, 26)
    icon:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -30)
    name = W.Label(f, "", "GameFontNormalLarge")
    name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    for i = 1, 2 do
        local l = W.Label(f, "", "GameFontHighlightSmall")
        l:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -46 - i * 16)
        l:SetPoint("RIGHT", f, "RIGHT", -14, 0)
        l:SetJustifyH("LEFT")
        l:SetWordWrap(false)
        summary[i] = l
    end
    local titleA = W.Label(f, "", "GameFontNormal")
    titleA:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -104)
    local listA = W.List(f, { rowHeight = 22 })
    listA:SetColumns(columns("Gear"), "breakdown.item")
    listA:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -122)
    listA:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -122)
    listA:SetHeight(140)
    local titleB = W.Label(f, "", "GameFontNormal")
    titleB:SetPoint("TOPLEFT", listA, "BOTTOMLEFT", 2, -6)
    local listB = W.List(f, { rowHeight = 22 })
    listB:SetColumns(columns("Band"), "breakdown.band")
    listB:SetPoint("TOPLEFT", listA, "BOTTOMLEFT", 0, -24)
    listB:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    parts = { titleA, listA, titleB, listB }
    f.onResize = Breakdown.Refresh
    f:SetScript("OnShow", Breakdown.Refresh)
end

--- Opens the window for a material.
function Breakdown.Open(matID)
    if not Breakdown.Is(matID) then return end
    if not f then build() end
    Breakdown.matID = matID
    f:Show()
    if f.Raise then f:Raise() end
    Breakdown.Refresh()
end

--- A row anywhere in the addon was clicked: a material opens its breakdown.
function ns.RowClick(data)
    if data and Breakdown.Is(data.itemID) then Breakdown.Open(data.itemID) end
end

--- The line added to a row's tooltip when a click does something.
function ns.RowHint(data)
    if data and data.onClick then return nil end
    if data and Breakdown.Is(data.itemID) then return "Click: where this material came from, and what pays" end
end

for _, e in ipairs({ "SALVAGER_LEDGER", "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS" }) do
    ns.On(e, function() Breakdown.Refresh() end)
end

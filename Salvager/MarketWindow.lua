-- Salvager: the Market window. The price of a material over time, from the addon's own scans:
-- its price, the lowest listing, your break-even, and how many units were listed.
local _, ns = ...

local History, Ledger, Data, W = ns.History, ns.Ledger, ns.Data, ns.Widgets

local Market = { range = "day" }
ns.Market = Market

local GREY, GOLD, GREEN, RED = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040"
local RANGES = { { "hours", "6 hours", 6 * 3600 }, { "day", "24 hours", 24 * 3600 }, { "week", "7 days", 7 * 86400 },
    { "all", "All" } }
local f, list, chart, title, facts, rangeButtons = nil, nil, nil, nil, nil, {}

local function since()
    for _, r in ipairs(RANGES) do
        if r[1] == Market.range then return r[3] and (time() - r[3]) or nil end
    end
end

--- The left list: every material that has history, with its price now and its change in the range.
function Market.Rows()
    local rows = {}
    local from = since()
    for _, m in ipairs(Data.MATERIALS) do
        local points = History.Points(ns.db.history, m.id, from)
        if #(ns.db.history[m.id] or {}) > 0 then
            local change = History.Change(points)
            local price = ns.PriceOf(m.id)
            local pct = change and math.floor(change * 100 + 0.5)
            rows[#rows + 1] = {
                itemID = m.id, group = m.id == Market.matID,
                onClick = function() Market.Select(m.id) end,
                cells = { ns.MaterialName(m.id), price and ns.Money(price) or (GREY .. "-|r"),
                    not pct and (GREY .. "-|r") or pct == 0 and (GREY .. "0%|r")
                        or ((pct > 0 and GREEN .. "+" or RED) .. pct .. "%|r") },
            }
        end
    end
    if #rows == 0 then
        rows[1] = { cells = { GREY .. "No price history yet: scan the materials.|r", "", "" } }
    end
    return rows
end

--- What the chart shows for a material.
function Market.ChartData(matID)
    local from = since()
    local points = History.Points(ns.db.history, matID, from)
    local price, lowest, units = {}, {}, {}
    for _, pt in ipairs(points) do
        price[#price + 1] = { pt.t, pt.p }
        lowest[#lowest + 1] = { pt.t, pt.lo }
        units[#units + 1] = { pt.t, pt.n or 0 }
    end
    local data = {
        from = points[1] and (from and math.max(from, points[1].t) or points[1].t), to = time(),
        lines = { { points = lowest, color = { 0.6, 0.6, 0.6 }, label = "Lowest listing" },
            { points = price, color = { 1, 0.82, 0 }, label = "Price" } },
        levels = {}, bars = { points = units, label = "Units listed" },
        empty = "No scans of this material in this time. Scan the materials, or pick a longer time.",
    }
    -- One scan only: give the chart some width.
    if data.from and data.to - data.from < 600 then data.from = data.to - 600 end
    local even = Ledger.BreakEven(ns.db.ledger, matID, ns.Cut())
    if even then data.levels[1] = { value = even, color = { 1, 0.3, 0.3 }, label = "Your break-even" } end
    return data, points
end

--- The line above the chart.
function Market.Facts(points)
    local change, first, last = History.Change(points)
    if not change then return GREY .. "No price in this time.|r" end
    local lo, hi
    for _, pt in ipairs(points) do
        if pt.p then
            lo = (not lo or pt.p < lo) and pt.p or lo
            hi = (not hi or pt.p > hi) and pt.p or hi
        end
    end
    local pct = math.floor(change * 100 + 0.5)
    return string.format("%sNow|r %s    %sFrom|r %s (%s%d%%|r)    %sLowest|r %s    %sHighest|r %s    %sScans|r %d", GOLD,
        ns.Money(last), GOLD, ns.Money(first), pct > 0 and (GREEN .. "+") or pct < 0 and RED or GREY, pct, GOLD,
        ns.Money(lo), GOLD, ns.Money(hi), GOLD, #points)
end

function Market.Select(matID)
    Market.matID = matID
    if f then f.saved.matID = matID end
    Market.Refresh()
end

function Market.Refresh()
    if not f or not f:IsShown() then return end
    -- The first material with history, when none is picked.
    if not (Market.matID and #(ns.db.history[Market.matID] or {}) > 0) then
        Market.matID = nil
        for _, m in ipairs(Data.MATERIALS) do
            if #(ns.db.history[m.id] or {}) > 0 then Market.matID = m.id break end
        end
    end
    local rows = Market.Rows()
    list:SetSource(#rows, function(i) return rows[i] end)
    list:Refresh()
    for key, b in pairs(rangeButtons) do
        if key == Market.range then b:LockHighlight() else b:UnlockHighlight() end
    end
    if Market.matID then
        local data, points = Market.ChartData(Market.matID)
        title:SetText(ns.MaterialName(Market.matID))
        facts:SetText(Market.Facts(points))
        chart:SetData(data)
    else
        title:SetText("")
        facts:SetText("")
        chart:SetData({ empty = "No price history yet. Every material scan adds a point: the charts fill as you play." })
    end
    chart:Refresh()
end

local function build()
    f = W.Window("SalvagerMarketFrame", "Salvager market", "market", 860, 460, 700, 320)
    if f.saved.matID then Market.matID = f.saved.matID end
    for _, r in ipairs(RANGES) do if r[1] == f.saved.range then Market.range = r[1] end end
    list = W.List(f, { rowHeight = 22 })
    list:SetColumns({ { "Material", 150 }, { "Now", 70, "RIGHT" },
        { "Change", 54, "RIGHT", help = { "Change", "How much the price moved over the time picked on the right." } } })
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -30)
    list:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 14)
    list:SetWidth(330)
    title = W.Label(f, "", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", list, "TOPRIGHT", 12, -2)
    local x = -12
    for i = #RANGES, 1, -1 do
        local r = RANGES[i]
        local b = W.Button(f, r[2], 70, function()
            Market.range = r[1]
            f.saved.range = r[1]
            Market.Refresh()
        end)
        b:SetPoint("TOPRIGHT", f, "TOPRIGHT", x, -30)
        rangeButtons[r[1]] = b
        x = x - 74
    end
    facts = W.Label(f, "", "GameFontHighlightSmall")
    facts:SetPoint("TOPLEFT", list, "TOPRIGHT", 12, -30)
    facts:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    facts:SetJustifyH("LEFT")
    facts:SetWordWrap(false)
    chart = W.Chart(f)
    chart:SetPoint("TOPLEFT", list, "TOPRIGHT", 10, -50)
    chart:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    f.onResize = Market.Refresh
    f:SetScript("OnShow", Market.Refresh)
end

function Market.Toggle()
    if not f then build() end
    f.UserToggle()
end

--- Opens the window again if it was open the last time (the auction house opened).
function Market.Restore()
    local saved = ns.db.windows.market
    if not (saved and saved.open) then return end
    if not f then build() end
    f:Show()
end

for _, e in ipairs({ "SALVAGER_PRICES_DONE", "SALVAGER_LEDGER", "SALVAGER_SETTINGS" }) do
    ns.On(e, function() Market.Refresh() end)
end

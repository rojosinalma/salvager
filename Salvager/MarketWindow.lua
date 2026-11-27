-- Salvager: the Market window. Charts from the addon's own data:
--   Materials        the price of a material over time, its lowest listing, your break-even, units listed
--   Disenchant value what one disenchant of an item level band was worth over time, against its buy limit
--   Profit           the profit of your sales, added up over time, and per day
--   Essences         three lesser against one greater, per essence: when converting pays
--   By hour          the average price of a material per hour of the day
local _, ns = ...

local History, Ledger, Model, Data, W = ns.History, ns.Ledger, ns.Model, ns.Data, ns.Widgets

local Market = { range = "24h", view = "material", pick = {}, sort = {} }
ns.Market = Market

local GREY, GOLD, GREEN, RED = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040"
local MIN, HOUR, DAY = 60, 3600, 86400
local RANGES = {
    { "1m", "1 minute", MIN }, { "5m", "5 minutes", 5 * MIN }, { "10m", "10 minutes", 10 * MIN },
    { "30m", "30 minutes", 30 * MIN }, { "1h", "1 hour", HOUR }, { "6h", "6 hours", 6 * HOUR },
    { "12h", "12 hours", 12 * HOUR }, { "24h", "24 hours", DAY }, { "3d", "3 days", 3 * DAY }, { "5d", "5 days", 5 * DAY },
    { "7d", "7 days", 7 * DAY }, { "10d", "10 days", 10 * DAY }, { "14d", "14 days", 14 * DAY },
    { "30d", "30 days", 30 * DAY }, { "60d", "60 days", 60 * DAY }, { "90d", "90 days", 90 * DAY }, { "all", "All" },
}
local f, list, chart, title, facts, rangeDrop, tabs = nil, nil, nil, nil, nil, nil, {}
local searchBox, searchParts, timeLabel = nil, {}, nil   -- the filter row's search, and the Time label after it

local function since()
    for _, r in ipairs(RANGES) do
        if r[1] == Market.range then return r[3] and (time() - r[3]) or nil end
    end
end

local function percent(change)
    if not change then return GREY .. "-|r" end
    local pct = math.floor(change * 100 + 0.5)
    if pct == 0 then return GREY .. "0%|r" end
    return (pct > 0 and GREEN .. "+" or RED) .. pct .. "%|r"
end

local function hasHistory(id) return #(ns.db.history[id] or {}) > 0 end

-- The search of each view (UI.md Controls 6), remembered per view. Profit has none: its rows are days, and the Time
-- filter picks them.
Market.search = {}
local NO_SEARCH = { profit = true }
function Market.SearchText() return not NO_SEARCH[Market.view] and Market.search[Market.view] or "" end
local function matches(...)
    local text = Market.SearchText()
    if text == "" then return true end
    for i = 1, select("#", ...) do if W.Matches(select(i, ...), text) then return true end end
    return false
end

--- Gives a chart some width when everything in it is from one moment.
local function widen(data)
    if data.from and data.to and data.to - data.from < 30 then data.from = data.to - 60 end
    return data
end

--- A row the player can pick; the picked one of the view shows with a band.
local function pickRow(key, cells, itemID)
    return { itemID = itemID, group = Market.pick[Market.view] == key, cells = cells,
        onClick = function() Market.Select(key) end }
end

------------------------------------------------------------------ Materials

local Material = { title = "Materials", columns = { { "Material", 150 }, { "Now", 70, "RIGHT" },
    { "Change", 54, "RIGHT", help = { "Change", "How much the price moved over the time picked on the right." } } } }

function Material.Rows()
    local rows, from = {}, since()
    for _, m in ipairs(Data.MATERIALS) do
        if hasHistory(m.id) and matches(ns.MaterialName(m.id)) then
            local price = ns.PriceOf(m.id)
            rows[#rows + 1] = pickRow(m.id, { ns.MaterialName(m.id), price and ns.Money(price) or (GREY .. "-|r"),
                percent((History.Change(History.Points(ns.db.history, m.id, from)))) }, m.id)
            rows[#rows].key = m.id
            -- (The Material column sorts in the materials' order, as every material list: Data.MaterialRank.)
            rows[#rows].sort = { Data.MaterialRank(m.id), price or -1,
                (History.Change(History.Points(ns.db.history, m.id, from))) or -math.huge }
        end
    end
    return rows
end

function Material.Chart(matID)
    local from = since()
    local points = History.Points(ns.db.history, matID, from)
    local price, lowest, units = {}, {}, {}
    for _, pt in ipairs(points) do
        price[#price + 1] = { pt.t, pt.p }
        lowest[#lowest + 1] = { pt.t, pt.lo }
        units[#units + 1] = { pt.t, pt.n or 0 }
    end
    local data = widen({
        from = points[1] and (from and math.max(from, points[1].t) or points[1].t), to = time(),
        lines = { { points = lowest, color = { 0.6, 0.6, 0.6 }, label = "Lowest listing" },
            { points = price, color = { 1, 0.82, 0 }, label = "Price" } },
        levels = {}, bars = { points = units, label = "Units listed" },
        empty = "No price seen for this material in this time. Pick a longer time.",
    })
    local even = Ledger.BreakEven(ns.db.ledger, matID, ns.Cut())
    if even then data.levels[1] = { value = even, color = { 1, 0.3, 0.3 }, label = "Your break-even" } end
    return data, ns.MaterialName(matID), Market.Facts(points)
end

--- "Now, From (change), Lowest, Highest, Points" of a list of points with a price `p`.
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
    return string.format("%sNow|r %s    %sFrom|r %s (%s)    %sLowest|r %s    %sHighest|r %s    %sPoints|r %d", GOLD,
        ns.Money(last), GOLD, ns.Money(first), percent(change), GOLD, ns.Money(lo), GOLD, ns.Money(hi), GOLD, #points)
end

------------------------------------------------------------------ Disenchant value

local Value = { title = "Disenchant value", columns = { { "Band", 190 }, { "Value now", 76, "RIGHT" },
    { "Change", 54, "RIGHT", help = { "Change", "How much the value of one disenchant moved over the time picked." } } } }

local function valueOptions()
    return ns.ValueOptions()
end

--- What one disenchant of a band was worth at each moment a price of one of its materials was seen.
--- @return table  { { t = time, p = value }, ... }  (the shape of price points)
function Market.ValueSeries(quality, classID, up, from)
    local opts, out = valueOptions(), {}
    local outcomes = ns.Outcomes(quality, classID, up, opts.salvager)
    if not outcomes then return {} end
    local ids = {}
    for _, r in ipairs(outcomes.results) do ids[#ids + 1] = r.id end
    for _, t in ipairs(History.Times(ns.db.history, ids, from)) do
        local v = Model.Value(outcomes, function(id) return History.At(ns.db.history, id, t) end, opts)
        if #v.missing == 0 then out[#out + 1] = { t = t, p = v.net } end
    end
    return out
end

--- By gear type, quality under it, and each band by its range (ns.GroupedRows).
function Value.Rows()
    local entries, from = {}, since()
    local opts = valueOptions()
    for _, q in ipairs({ { 2, Data.GREEN }, { 3, Data.BLUE }, { 4, Data.PURPLE } }) do
        for _, classID in ipairs({ Data.CLASS_ARMOR, Data.CLASS_WEAPON }) do
            for _, band in ipairs(q[2]) do
                local series = matches(ns.BandShort(q[1], classID, band.up))
                    and Market.ValueSeries(q[1], classID, band.up, from) or {}
                if #series > 0 then
                    local v = Model.Value(ns.Outcomes(q[1], classID, band.up, opts.salvager), ns.PriceOf, opts)
                    entries[#entries + 1] = { quality = q[1], classID = classID, band = band.up, net = v.net,
                        change = (History.Change(series)) }
                end
            end
        end
    end
    return ns.GroupedRows(entries, function(e)
        local key = Ledger.BandKey(e.quality, e.classID, e.band)
        local r = pickRow(key, { "", ns.Money(e.net), percent(e.change) })
        r.key = key
        r.sort = { e.band, e.net, e.change or -math.huge }
        return r
    end, function(_, label) return { cells = { label, "", "" } } end, nil,
        { collapsed = ns.GroupState("market.value"), changed = function() Market.Refresh() end })
end

function Value.Chart(key)
    local quality, classID, up = Ledger.BandOf(key)
    local from = since()
    local series = Market.ValueSeries(quality, classID, up, from)
    local line = {}
    for _, pt in ipairs(series) do line[#line + 1] = { pt.t, pt.p } end
    local opts = valueOptions()
    local v = Model.Value(ns.Outcomes(quality, classID, up, opts.salvager), ns.PriceOf, opts)
    local limit = ns.BuyLimit(quality, classID, up, ns.LimitBasis(v))
    return widen({
        from = series[1] and series[1].t, to = time(),
        lines = { { points = line, color = { 1, 0.82, 0 }, label = "Value of one disenchant (average, after the cut)" } },
        levels = limit > 0 and { { value = limit, color = { 0.3, 1, 0.3 }, label = "Buy limit now" } } or {},
        empty = "No value in this time: a material of this band has no price yet. Pick a longer time.",
    }), ns.BandShort(quality, classID, up), Market.Facts(series)
end

------------------------------------------------------------------ Profit

local Profit = { title = "Profit", columns = { { "Day", 110, help = ns.TimeHelp("Day", "The day of the sales.") },
    { "Sales", 50, "CENTER" }, { "Profit", 90, "RIGHT" } } }

--- The sales with a known cost, and the deposits lost, from `from` on, oldest first. A sale's profit
--- counts only its units with a known cost.
local function sales(from)
    local out = {}
    for _, s in ipairs(ns.db.ledger.sales) do
        if (s.lost or (s.count - (s.untracked or 0)) > 0) and s.t and (not from or s.t >= from) then out[#out + 1] = s end
    end
    table.sort(out, function(a, b) return a.t < b.t end)
    return out
end

function Profit.Rows()
    local days, order = {}, {}
    for _, s in ipairs(sales(since())) do
        local day = ns.Date("%Y-%m-%d", s.t)
        if not days[day] then
            days[day] = { n = 0, profit = 0 }
            order[#order + 1] = day
        end
        days[day].n, days[day].profit = days[day].n + 1, days[day].profit + s.profit
    end
    local rows = {}
    for i = #order, 1, -1 do
        local d = days[order[i]]
        rows[#rows + 1] = { sort = { order[i], d.n, d.profit },
            cells = { order[i], tostring(d.n), (d.profit >= 0 and GREEN or RED) .. ns.Money(d.profit) .. "|r" } }
    end
    return rows
end

function Profit.Chart()
    local list_, line, total = sales(since()), {}, 0
    for _, s in ipairs(list_) do
        total = total + s.profit
        line[#line + 1] = { s.t, total }
    end
    if list_[1] then table.insert(line, 1, { list_[1].t - 1, 0 }) end
    return widen({
        from = list_[1] and list_[1].t - 1, to = time(), negative = true,
        lines = { { points = line, color = total >= 0 and { 0.3, 1, 0.3 } or { 1, 0.3, 0.3 },
            label = "Profit of your sales, added up" } },
        levels = { { value = 0, color = { 0.6, 0.6, 0.6 }, label = "Zero" } },
        empty = "No sale with a known cost in this time.",
    }), "Profit of your sales", string.format(
        "%sSales|r %d    %sProfit|r %s    %s(units with no recorded cost are left out; deposits lost count)|r", GOLD, #list_,
        GOLD, (total >= 0 and GREEN or RED) .. ns.Money(total) .. "|r", GREY)
end

------------------------------------------------------------------ Essences

local Essence = { title = "Essences", columns = { { "Essence", 90 }, { "3 lesser", 70, "RIGHT" }, { "1 greater", 70, "RIGHT" },
    { "Greater", 56, "RIGHT", help = { "Greater", "How much more (or less) one greater sells for than three lesser, now. "
        .. "Plus: combining pays. Minus: splitting pays." } } } }

local function essencePairs()
    local out = {}
    for _, m in ipairs(Data.MATERIALS) do
        local pair = Data.ESSENCE_PAIR[m.id]
        if pair and pair.factor < 1 then out[#out + 1] = { lesser = m.id, greater = pair.other } end
    end
    return out
end

function Essence.Rows()
    local rows = {}
    for _, e in ipairs(essencePairs()) do
        if (hasHistory(e.lesser) or hasHistory(e.greater)) and matches(ns.MaterialName(e.lesser), ns.MaterialName(e.greater)) then
            local l, g = ns.db.prices[e.lesser], ns.db.prices[e.greater]
            local three, one = l and l.p and l.p * 3, g and g.p
            rows[#rows + 1] = pickRow(e.lesser, { (ns.MaterialName(e.greater):gsub("^Greater ", ""):gsub(" Essence$", "")),
                three and ns.Money(three) or (GREY .. "-|r"), one and ns.Money(one) or (GREY .. "-|r"),
                percent(three and one and (one - three) / three) }, e.greater)
            rows[#rows].key = e.lesser
            rows[#rows].sort = { Data.MaterialRank(e.greater), three or -1, one or -1,
                three and one and (one - three) / three or -math.huge }
        end
    end
    return rows
end

function Essence.Chart(lesser)
    local greater = Data.ESSENCE_PAIR[lesser].other
    local from = since()
    local a, b, first = {}, {}, nil
    for _, pt in ipairs(History.Points(ns.db.history, lesser, from)) do
        if pt.p then a[#a + 1] = { pt.t, pt.p * 3 } first = math.min(first or pt.t, pt.t) end
    end
    for _, pt in ipairs(History.Points(ns.db.history, greater, from)) do
        if pt.p then b[#b + 1] = { pt.t, pt.p } first = math.min(first or pt.t, pt.t) end
    end
    local now3, now1 = a[#a] and a[#a][2], b[#b] and b[#b][2]
    local text = GREY .. "No price in this time.|r"
    if now3 and now1 then
        text = string.format("%s3 lesser|r %s    %s1 greater|r %s    %s", GOLD, ns.Money(now3), GOLD, ns.Money(now1),
            now1 > now3 and (GREEN .. "Combining pays " .. percent((now1 - now3) / now3))
            or now3 > now1 and (GREEN .. "Splitting pays " .. percent((now3 - now1) / now1)) or "The same")
    end
    return widen({
        from = first, to = time(),
        lines = { { points = a, color = { 0.4, 0.7, 1 }, label = "3 x " .. ns.MaterialName(lesser) },
            { points = b, color = { 1, 0.82, 0 }, label = "1 x " .. ns.MaterialName(greater) } },
        empty = "No price seen for this essence in this time. Pick a longer time.",
    }), ns.MaterialName(greater) .. " and " .. ns.MaterialName(lesser), text
end

------------------------------------------------------------------ By hour

local Hour = { title = "Time of day", columns = Material.columns }
Hour.Rows = Material.Rows

function Hour.Chart(matID)
    local points = History.Points(ns.db.history, matID, since())
    local byHour = History.ByHour(points, function(t) return tonumber(ns.Date("%H", t)) end)
    local low, high
    for _, p in ipairs(byHour) do
        if not low or p[2] < low[2] then low = p end
        if not high or p[2] > high[2] then high = p end
    end
    local text = #byHour < 2 and (GREY .. "Prices from one hour of the day only so far. This chart needs scans at "
        .. "different hours, best over several days.|r")
        or string.format("%sCheapest at|r %02d:00 (%s)    %sDearest at|r %02d:00 (%s)    %sHours with a price|r %d of 24",
            GOLD, low[1], ns.Money(low[2]), GOLD, high[1], ns.Money(high[2]), GOLD, #byHour)
    return {
        from = 0, to = 23, xFormat = function(h) return string.format("%02d:00", h) end,
        -- A mark at every hour, labelled every 3 hours, so each point reads as a time of day.
        xTicks = (function()
            local ticks = {}
            for h = 0, 23 do ticks[#ticks + 1] = { h, h % 3 == 0 and string.format("%02d:00", h) or nil } end
            return ticks
        end)(),
        lines = { { points = byHour, color = { 1, 0.82, 0 }, label = "Average price at each hour of the day" } },
        empty = "No price seen for this material in this time.",
    }, ns.MaterialName(matID) .. ": average price by time of day", text
end

------------------------------------------------------------------ the window

local MIN_W, LIST_W = 900, 370   -- the window's smallest width; the list's, where its columns need no more

local VIEWS = { material = Material, value = Value, profit = Profit, essence = Essence, hour = Hour }
local ORDER = { "material", "value", "profit", "essence", "hour" }
Market.VIEWS = VIEWS

-- A list of materials starts in the materials' order (the Materials window's, Data.SortMaterials); the bands start
-- by their change, the biggest rise first. (Profit keeps its days in order.)
local DEFAULT_SORT = { value = 3 }
local function sortOf(view)
    local sort = Market.sort[view]
    if sort then return sort end
    return DEFAULT_SORT[view] and { col = DEFAULT_SORT[view], desc = true } or nil
end

function Market.Select(key)
    Market.pick[Market.view] = key
    if f then
        f.saved.pick = f.saved.pick or {}
        f.saved.pick[Market.view] = key
    end
    Market.Refresh()
end

--- The rows of the view, and the key of the picked row (the first one when the picked one is not there).
function Market.Rows()
    local view = VIEWS[Market.view]
    local rows = view.Rows()
    -- Sorted by the column whose title was clicked; without one, in the view's own order.
    local sort = sortOf(Market.view)
    if sort then
        for i, row in ipairs(rows) do row.index = i end
        table.sort(rows, function(a, b)
            -- Grouped rows (ns.GroupedRows) are sorted inside their group, under its heading.
            if (a.section or 0) ~= (b.section or 0) then return (a.section or 0) < (b.section or 0) end
            if a.head or b.head then
                if a.head and b.head then return a.index < b.index end
                return a.head == true
            end
            local x, y = a.sort and a.sort[sort.col], b.sort and b.sort[sort.col]
            if x == y or x == nil or y == nil or type(x) ~= type(y) then return a.index < b.index end
            if sort.desc then return x > y end
            return x < y
        end)
    end
    local picked
    for _, row in ipairs(rows) do
        if row.key ~= nil and row.key == Market.pick[Market.view] then picked = row.key end
    end
    if picked == nil then
        -- The first row that can be picked (headings cannot).
        for _, row in ipairs(rows) do
            if row.key ~= nil then
                picked = row.key
                Market.pick[Market.view] = picked
                break
            end
        end
        for _, row in ipairs(rows) do if row.key ~= nil then row.group = row.key == picked end end
    end
    if #rows == 0 then
        local n = #view.columns
        local search = Market.SearchText()
        local cells = { GREY .. (search ~= "" and W.NoMatch(search) or Market.view == "profit" and "No sale with a known "
            .. "cost in this time." or "The addon has not seen a price for this yet.") .. "|r" }
        for i = 2, n do cells[i] = "" end
        rows[1] = { cells = cells }
    end
    return rows, picked
end

function Market.Refresh()
    if not f or not f:IsShown() then return end
    local view = VIEWS[Market.view]
    local rows, picked = Market.Rows()
    -- The sorted column shows an arrow in its title.
    local sort, cols = sortOf(Market.view), {}
    for i, col in ipairs(view.columns) do
        cols[i] = { col[1], col[2], col[3], help = col.help, key = col[1] }
        if sort and sort.col == i then
            cols[i][1] = col[1] .. (sort.desc and " |TInterface\\Buttons\\Arrow-Down-Up:10|t"
                or " |TInterface\\Buttons\\Arrow-Up-Up:10|t")
        end
    end
    list:SetColumns(cols, "market." .. Market.view)
    list:SetSource(#rows, function(i) return rows[i] end)
    list:Refresh()
    -- The list is as wide as its columns need (at least LIST_W), the window wider by as much, up to the screen
    -- (SDD 107); the chart keeps the rest.
    local need = rawget(list, "fitWidth")
    local lw = math.max(LIST_W, type(need) == "number" and need or 0)
    lw = math.min(lw, math.floor(W.ScreenWidth()) - (MIN_W - LIST_W))
    if math.abs((list:GetWidth() or 0) - lw) >= 1 then
        list:SetWidth(lw)
        f.FitWidth(MIN_W + lw - LIST_W)
        list:Refresh()
    end
    rangeDrop:Update()
    -- The search first, where the view has one; the Time filter first where it has none.
    local searchable = not NO_SEARCH[Market.view]
    for _, x in ipairs(searchParts) do x:SetShown(searchable) end
    if searchable then searchBox:Update() end
    timeLabel:ClearAllPoints()
    if searchable then timeLabel:SetPoint("LEFT", searchBox, "RIGHT", 16, 0)
    else timeLabel:SetPoint("LEFT", Market.bars.filters, "LEFT", 2, 0) end
    for key, b in pairs(tabs) do b:SetSelected(key == Market.view) end
    if picked ~= nil or Market.view == "profit" then
        local data, name, text = view.Chart(picked)
        title:SetText(name or "")
        facts:SetText(text or "")
        chart:SetData(data)
    else
        title:SetText("")
        facts:SetText("")
        chart:SetData({ empty = "The addon has not seen a price for this yet." })
    end
    -- The chart starts under the facts, which take as many lines as they need.
    local lines = math.max(12, math.ceil(tonumber((facts:GetStringHeight())) or 12))
    chart:SetPoint("TOPLEFT", list, "TOPRIGHT", 10, -(26 + lines + 8))
    chart:Refresh()
end

local function build()
    f = W.Window("SalvagerMarketFrame", "Salvager Market", "market", MIN_W, 480, MIN_W, 320)
    if VIEWS[f.saved.view] then Market.view = f.saved.view end
    for key, value in pairs(f.saved.pick or {}) do Market.pick[key] = value end
    for _, r in ipairs(RANGES) do if r[1] == f.saved.range then Market.range = r[1] end end
    -- 0.3.145: the lists of materials start in the materials' order once (a sort picked before is dropped).
    if not f.saved.materialOrder then
        f.saved.materialOrder = true
        if type(f.saved.sort) == "table" then
            f.saved.sort.material, f.saved.sort.hour, f.saved.sort.essence = nil, nil, nil
        end
    end
    for key, value in pairs(f.saved.sort or {}) do Market.sort[key] = value end
    -- From the top: the tabs, the filter row (Time), then the list and the chart (UI.md Controls 1).
    local tabBar = W.Bar(f, "tabs"):Place(24, 12, 12)
    local filters = W.Bar(f, "filters"):Place(58, 12, 12)
    Market.bars = { tabs = tabBar, filters = filters }   -- (the specs read them)
    local help = {
        material = "The price of one material over time, its lowest listing, your break-even, and how many units were listed.",
        value = "What one disenchant of an item level band was worth over time, against its buy limit: is gear worth buying now?",
        profit = "The profit of your sales (units with a known cost, less deposits lost), added up over time, and per day.",
        essence = "Three lesser against one greater, per essence: when combining or splitting pays.",
        hour = "The average price of a material at each time of day, over the time picked: when to post, and when to buy.",
    }
    for _, key in ipairs(ORDER) do
        local b = W.Tab(tabBar, VIEWS[key].title, function()
            Market.view = key
            f.saved.view = key
            list.offset = 0
            Market.Refresh()
        end, help[key])
        tabBar:Add(b, key == "value" and 124 or 90)
        tabs[key] = b
    end
    -- The search first (UI.md Controls 6), then the time the charts cover.
    if type(f.saved.search) == "table" then Market.search = f.saved.search end
    f.saved.search = Market.search
    local SEARCH_HELP = "Shows the rows whose name has this text, in any case: the material's (Materials, Time of day), "
        .. "the band's (Disenchant value, \"Uncommon Armor 26-30\"), the essence's (Essences). Each view keeps its own."
    searchBox = W.Search(filters, 110, function() return Market.SearchText() end, function(text)
        if NO_SEARCH[Market.view] then return end
        Market.search[Market.view] = text ~= "" and text or nil
        list.offset = 0
        Market.Refresh()
    end, SEARCH_HELP)
    local searchLabel, searchArea = filters:AddFilter("Search", searchBox, 110, SEARCH_HELP)
    searchParts = { searchLabel, searchArea, searchBox }
    Market.searchBox = searchBox   -- (the specs type in it)
    -- The time the charts cover: one choice.
    local options = {}
    for _, r in ipairs(RANGES) do options[#options + 1] = { r[1], r[2] } end
    rangeDrop = W.Dropdown(filters, 120, options, function(key) return key == Market.range end, function(key)
        Market.range = key
        f.saved.range = key
        rangeDrop:Close()
        Market.Refresh()
    end, "How far back the charts and the Change column go.", "Time")
    timeLabel = filters:AddFilter("Time", rangeDrop, 120, "How far back the charts and the Change column go.")
    list = W.List(f, { rowHeight = 22 })
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -88)
    list:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 14)
    list:SetWidth(LIST_W)
    -- A click on a column title sorts by it; a second click turns the order around.
    list.onSort = function(col)
        local sort = sortOf(Market.view)
        if not sort or sort.col ~= col then
            Market.sort[Market.view] = { col = col, desc = col > 1 }   -- numbers start with the highest
        else
            Market.sort[Market.view] = { col = col, desc = not sort.desc }
        end
        f.saved.sort = Market.sort
        Market.Refresh()
    end
    title = W.Label(f, "", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", list, "TOPRIGHT", 12, -2)
    facts = W.Label(f, "", "GameFontHighlightSmall")
    facts:SetPoint("TOPLEFT", list, "TOPRIGHT", 12, -26)
    facts:SetPoint("RIGHT", f, "RIGHT", -12, 0)
    facts:SetJustifyH("LEFT")
    -- The facts wrap and push the chart down (UI.md Layout 6): see placeChart.
    chart = W.Chart(f)
    chart:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    f.onResize = Market.Refresh
    f:HookScript("OnShow", Market.Refresh)
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

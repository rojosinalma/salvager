-- Salvager: what the client really draws, for the developer. At logout (and /reload) every Salvager window that
-- exists is walked and written to SalvagerDB.layout, replaced each time; read it from the saved variables (SDD 94).
local _, ns = ...

local Layout = {}
ns.Layout = Layout

local MAX_DEPTH, MAX_ENTRIES, TEXT_MAX, MAX_BYTES = 8, 2000, 80, 300 * 1024
-- name in the dump -> the window's global frame name
local WINDOWS = {
    main = "SalvagerFrame", ledger = "SalvagerLedgerFrame", odds = "SalvagerOddsFrame", log = "SalvagerLogFrame",
    materials = "SalvagerMaterialsFrame", reports = "SalvagerReportsFrame", market = "SalvagerMarketFrame",
    stand = "SalvagerStandFrame", breakdown = "SalvagerBreakdownFrame", post = "SalvagerPostFrame",
    options = "SalvagerOptionsFrame",
}

-- A method's results, or nothing where the client does not have it or it fails.
local function call(obj, method, ...)
    local fn = obj[method]
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, obj, ...)
    if ok then return a, b, c, d end
    return nil
end

local function num(v)
    if type(v) ~= "number" then return "?" end
    return (string.format("%.1f", v):gsub("%.0$", ""))
end

local function rect(obj)
    local l, b, w, h = call(obj, "GetRect")
    if not l then return "-" end
    return num(l) .. "," .. num(b) .. "," .. num(w) .. "," .. num(h)
end

local function cut(text)
    if type(text) ~= "string" then return "" end
    return #text > TEXT_MAX and text:sub(1, TEXT_MAX) or text
end

-- A list made by Widgets.List: its columns as set, its cells per row, and each title as drawn.
local function isList(obj)
    return type(rawget(obj, "headers")) == "table" and type(rawget(obj, "rows")) == "table"
        and type(rawget(obj, "columns")) == "table"
end

local function listInfo(list)
    local info = { w = num(call(list, "GetWidth")), needed = num(rawget(list, "neededWidth")), columns = {}, headers = {} }
    for i, col in ipairs(list.columns) do info.columns[i] = tostring(col[1]) .. "\t" .. num(col[2]) end
    local first = list.rows[1]
    info.cells = first and type(first.cells) == "table" and #first.cells or 0
    local shownRows = 0
    for _, row in ipairs(list.rows) do if call(row, "IsShown") then shownRows = shownRows + 1 end end
    info.rowsShown = shownRows
    for i, h in ipairs(list.headers) do
        info.headers[i] = cut(call(h, "GetText")) .. "\t" .. (call(h, "IsShown") and "S" or "-") .. "\t"
            .. num(call(h, "GetWidth")) .. "\t" .. (call(h, "IsTruncated") and "T" or "-")
    end
    -- The first row on show, cell by cell: shown, width, text.
    if first and call(first, "IsShown") then
        info.row1 = {}
        for i, fs in ipairs(first.cells) do
            info.row1[i] = (call(fs, "IsShown") and "S" or "-") .. "\t" .. num(call(fs, "GetWidth")) .. "\t"
                .. cut(call(fs, "GetText"))
        end
    end
    return info
end

-- One line per region: key, type, flags (S shown, V visible, T text cut), left,bottom,width,height, text.
local function walk(obj, key, depth, out)
    if out.n >= MAX_ENTRIES then out.full = true return end
    local kind = call(obj, "GetObjectType") or "?"
    local shown = call(obj, "IsShown")
    local flags = (shown and "S" or "") .. (call(obj, "IsVisible") and "V" or "")
        .. (kind == "FontString" and call(obj, "IsTruncated") and "T" or "")
    local text = (kind == "FontString" or kind == "Button" or kind == "EditBox") and cut(call(obj, "GetText")) or ""
    out.n = out.n + 1
    out.regions[#out.regions + 1] = table.concat({ key, kind, flags == "" and "-" or flags, rect(obj), text }, "\t")
    if isList(obj) then
        out.lists[key] = listInfo(obj)
        return   -- (its rows are in the list's own record: 60 rows of 12 cells would fill the budget)
    end
    -- Hidden frames are not opened: nothing under them is on screen.
    if depth >= MAX_DEPTH or not shown or kind == "FontString" or kind == "Texture" then return end
    local names = {}
    for k, v in pairs(obj) do
        if type(k) == "string" and type(v) == "table" then names[v] = k end
    end
    local function nameOf(child, prefix, i)
        return call(child, "GetName") or (type(rawget(child, "key")) == "string" and child.key) or names[child]
            or (prefix .. i)
    end
    local ok, kids = pcall(function() return { obj:GetChildren() } end)
    if ok then
        for i, child in ipairs(kids) do walk(child, key .. "." .. nameOf(child, "c", i), depth + 1, out) end
    end
    local okR, regions = pcall(function() return { obj:GetRegions() } end)
    if okR then
        for i, region in ipairs(regions) do walk(region, key .. "." .. nameOf(region, "r", i), depth + 1, out) end
    end
end

local function views()
    return { main = ns.UI and rawget(ns.UI, "view"), ledger = ns.LedgerWindow and rawget(ns.LedgerWindow, "view") }
end

--- Walks every window that exists into a fresh dump. Called at logout; returns it.
function Layout.Save()
    if type(SalvagerDB) ~= "table" then return nil end
    local dump = { version = ns.VERSION, time = time(), windows = {} }
    local out = { n = 0, regions = nil, lists = nil }
    local view = views()
    -- Windows on show first: they get the budget before the hidden ones.
    local order = {}
    for name, global in pairs(WINDOWS) do
        local f = _G[global]
        if type(f) == "table" then order[#order + 1] = { name = name, f = f, shown = call(f, "IsShown") and true or false } end
    end
    table.sort(order, function(a, b)
        if a.shown ~= b.shown then return a.shown end
        return a.name < b.name
    end)
    for _, w in ipairs(order) do
        local ok, rec = pcall(function()
            local f = w.f
            local r = { shown = w.shown, w = num(call(f, "GetWidth")), h = num(call(f, "GetHeight")),
                x = num(call(f, "GetLeft")), y = num(call(f, "GetTop")), view = view[w.name], regions = {}, lists = {} }
            local saved = rawget(f, "saved")
            if not r.view and type(saved) == "table" then r.view = saved.view or saved.tab end
            out.regions, out.lists = r.regions, r.lists
            walk(f, w.name, 0, out)
            return r
        end)
        dump.windows[w.name] = ok and rec or { error = tostring(rec) }
    end
    dump.entries, dump.full = out.n, out.full or nil
    -- Bounded in the saved file: past MAX_BYTES the regions go, from the last window (hidden ones are last);
    -- the lists stay, they are the smallest and most useful part.
    dump.size = ns.Util.SavedSize(dump)
    for i = #order, 1, -1 do
        if dump.size <= MAX_BYTES then break end
        local rec = dump.windows[order[i].name]
        if rec.regions then
            rec.regions, rec.dropped = nil, true
            dump.size = ns.Util.SavedSize(dump)
        end
    end
    SalvagerDB.layout = dump
    return dump
end

ns.On("PLAYER_LOGOUT", function() Layout.Save() end)

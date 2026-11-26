-- Salvager: what the client really draws, for the developer. At logout (and /reload) every Salvager window that
-- exists is walked and written to SalvagerDB.layout, replaced each time; read it from the saved variables, or draw
-- it with `make layout` (SDD 94). Hidden columns (SDD 95): per list `set` and `hidden`, and `hidden[set]` for every
-- column set.
local _, ns = ...

local Layout = {}
ns.Layout = Layout

-- TEXT_MAX: hidden regions only; what is on show is written in full. MAX_BYTES bounds the dump in the saved file.
local MAX_DEPTH, MAX_ENTRIES, TEXT_MAX, MAX_BYTES = 8, 3000, 80, 600 * 1024
Layout.MAX_BYTES = MAX_BYTES
-- name in the dump -> the window's global frame name
local WINDOWS = {
    main = "SalvagerFrame", ledger = "SalvagerLedgerFrame", odds = "SalvagerOddsFrame", log = "SalvagerLogFrame",
    materials = "SalvagerMaterialsFrame", reports = "SalvagerReportsFrame", market = "SalvagerMarketFrame",
    stand = "SalvagerStandFrame", breakdown = "SalvagerBreakdownFrame", post = "SalvagerPostFrame",
    options = "SalvagerOptionsFrame", limits = "SalvagerLimitsFrame", gear = "SalvagerGearFrame",
    mini = "SalvagerMiniFrame",
}
local LAYERS = { BACKGROUND = "BG", BORDER = "BD", ARTWORK = "A", OVERLAY = "O", HIGHLIGHT = "H" }
local CONTROLS = { Button = true, CheckButton = true, EditBox = true, Slider = true }

-- A method's results, or nothing where the client does not have it or it fails.
local function call(obj, method, ...)
    local fn = obj[method]
    if type(fn) ~= "function" then return nil end
    local ok, a, b, c, d = pcall(fn, obj, ...)
    if ok then return a, b, c, d end
    return nil
end

-- The client has no getter for a color texture's color: it is kept here as it is set (weak keys, so a texture
-- the game frees goes too). Every texture shares one method table; hooked once, without taint.
local colorOf = setmetatable({}, { __mode = "k" })
do
    local ok, probe = pcall(function() return CreateFrame("Frame"):CreateTexture() end)
    local meta = ok and type(probe) == "table" and getmetatable(probe)
    local methods = type(meta) == "table" and meta.__index
    if type(methods) == "table" and type(methods.SetColorTexture) == "function" and hooksecurefunc then
        hooksecurefunc(methods, "SetColorTexture", function(tex, r, g, b, a) colorOf[tex] = { r, g, b, a } end)
    end
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

-- "rrggbbaa", or nil where the client gave no color.
local function hex(r, g, b, a)
    if type(r) ~= "number" or type(g) ~= "number" or type(b) ~= "number" then return nil end
    local function byte(v) return math.max(0, math.min(255, math.floor(v * 255 + 0.5))) end
    return string.format("%02x%02x%02x%02x", byte(r), byte(g), byte(b), byte(type(a) == "number" and a or 1))
end

-- The drawing facts of a region or frame, as "k=v" fields: f font size, j justification (L C R), c text or
-- vertex color, sw the text's own width, d draw layer, ct color texture color, tex texture or atlas, a alpha,
-- fl frame level, bg and bd backdrop and border color, k the widget kind (`uiKind`: tab, subtab, dropdown, button,
-- check, edit, tabrow, subtabrow, filterrow, footer, settings; UI.md Controls; `make layout` checks it).
local function extras(obj, kind, text)
    local out = {}
    local alpha = call(obj, "GetAlpha")
    if type(alpha) == "number" and alpha < 0.99 then out[#out + 1] = "a=" .. num(alpha) end
    if kind == "FontString" or kind == "Texture" then
        local layer = LAYERS[call(obj, "GetDrawLayer") or ""]
        if layer then out[#out + 1] = "d=" .. layer end
    end
    if kind == "FontString" then
        local _, size = call(obj, "GetFont")
        if type(size) == "number" then out[#out + 1] = "f=" .. num(size) end
        local justify = call(obj, "GetJustifyH")
        if type(justify) == "string" and justify ~= "" then out[#out + 1] = "j=" .. justify:sub(1, 1) end
        local color = hex(call(obj, "GetTextColor"))
        if color and color ~= "ffffffff" then out[#out + 1] = "c=" .. color end
        if text ~= "" then
            local sw = call(obj, "GetUnboundedStringWidth") or call(obj, "GetStringWidth")
            if type(sw) == "number" then out[#out + 1] = "sw=" .. num(sw) end
        end
    elseif kind == "Texture" then
        local fill = colorOf[obj]
        if fill then out[#out + 1] = "ct=" .. (hex(fill[1], fill[2], fill[3], fill[4]) or "?") end
        local color = hex(call(obj, "GetVertexColor"))
        if color and color ~= "ffffffff" then out[#out + 1] = "c=" .. color end
        local tex = call(obj, "GetAtlas") or call(obj, "GetTexture")
        if type(tex) == "number" then tex = tostring(tex) end
        if type(tex) == "string" and tex ~= "" then
            out[#out + 1] = "tex=" .. (tex:match("([^\\/]+)$") or tex):sub(1, 40)
        end
    else
        local uiKind = rawget(obj, "uiKind")
        if type(uiKind) == "string" then out[#out + 1] = "k=" .. uiKind end
        local level = call(obj, "GetFrameLevel")
        if type(level) == "number" then out[#out + 1] = "fl=" .. num(level) end
        if type(call(obj, "GetBackdrop")) == "table" then
            local bg, bd = hex(call(obj, "GetBackdropColor")), hex(call(obj, "GetBackdropBorderColor"))
            if bg then out[#out + 1] = "bg=" .. bg end
            if bd then out[#out + 1] = "bd=" .. bd end
        end
    end
    return out
end

-- S shown, V visible, T text cut, D disabled (a control), C checked, K clips its children (they show only inside it).
local function flagsOf(obj, kind)
    local flags = (call(obj, "IsShown") and "S" or "") .. (call(obj, "IsVisible") and "V" or "")
        .. (kind == "FontString" and call(obj, "IsTruncated") and "T" or "")
        .. ((kind == "ScrollFrame" or call(obj, "DoesClipChildren")) and "K" or "")
    if CONTROLS[kind] then
        if call(obj, "IsEnabled") == false then flags = flags .. "D" end
        if kind == "CheckButton" and call(obj, "GetChecked") then flags = flags .. "C" end
    end
    return flags == "" and "-" or flags
end

-- The text of a region: in full while it is on show, else its first TEXT_MAX characters.
local function textOf(obj, kind, visible)
    if kind ~= "FontString" and kind ~= "Button" and kind ~= "EditBox" and kind ~= "CheckButton" then return "" end
    local text = call(obj, "GetText")
    if type(text) ~= "string" then return "" end
    return visible and text or cut(text)
end

-- One line: key, type, flags, left,bottom,width,height, text, then the "k=v" fields.
local function regionLine(obj, key)
    local kind = call(obj, "GetObjectType") or "?"
    local flags = flagsOf(obj, kind)
    local text = textOf(obj, kind, flags:find("V", 1, true) ~= nil)
    local fields = { key, kind, flags, rect(obj), text }
    for _, x in ipairs(extras(obj, kind, text)) do fields[#fields + 1] = x end
    return table.concat(fields, "\t"), kind, flags:find("S", 1, true) ~= nil
end

-- A cell of a list row: flags, width, text, then left,bottom,width,height and the "k=v" fields.
local function cellLine(fs)
    local flags = flagsOf(fs, "FontString")
    local shown = flags:find("S", 1, true) ~= nil
    local text = shown and textOf(fs, "FontString", true) or ""
    local fields = { flags, num(call(fs, "GetWidth")), text }
    if shown then
        fields[4] = rect(fs)
        for _, x in ipairs(extras(fs, "FontString", text)) do fields[#fields + 1] = x end
    end
    return table.concat(fields, "\t")
end

-- A list made by Widgets.List: its columns as set, its cells per row, and each title as drawn.
local function isList(obj)
    return type(rawget(obj, "headers")) == "table" and type(rawget(obj, "rows")) == "table"
        and type(rawget(obj, "columns")) == "table"
end

-- Every row on screen (hidden rows and rows scrolled away are not), cell by cell; the row's icon, open sign,
-- button and warning sign as region lines.
local function listRows(list)
    local rows, offset = {}, tonumber(rawget(list, "offset")) or 0
    local ncols = math.min(#list.columns, 12)
    for r, row in ipairs(list.rows) do
        if call(row, "IsVisible") then
            local rec = { n = offset + r, rect = rect(row), cells = {}, parts = {} }
            local cells = type(rawget(row, "cells")) == "table" and row.cells or {}
            for i = 1, ncols do
                if cells[i] then rec.cells[i] = cellLine(cells[i]) end
            end
            for _, part in ipairs({ "toggle", "icon", "warn", "action" }) do
                local obj = rawget(row, part)
                if type(obj) == "table" and call(obj, "IsShown") then rec.parts[#rec.parts + 1] = (regionLine(obj, part)) end
            end
            if #rec.parts == 0 then rec.parts = nil end
            rows[#rows + 1] = rec
        end
    end
    return rows
end

local function listInfo(list)
    local info = { w = num(call(list, "GetWidth")), needed = num(rawget(list, "neededWidth")), columns = {}, headers = {},
        offset = tonumber(rawget(list, "offset")), count = tonumber(rawget(list, "count")) }
    for i, col in ipairs(list.columns) do info.columns[i] = tostring(col[1]) .. "\t" .. num(col[2]) end
    -- Its column set, and the titles hidden there with the chooser (by choice, not for want of room).
    local set = rawget(list, "columnSet")
    info.set = type(set) == "string" and set or nil
    -- "statement": a statement (UI.md Statements), whose amounts end flush with the panel's right edge.
    info.kind = list.columns.statement and "statement" or nil
    info.hidden = {}
    for i, col in ipairs(list.columns) do
        local key = ns.Widgets.ColumnKey(col)
        if i > 1 and not ns.Widgets.ColumnShown(info.set, key) then info.hidden[#info.hidden + 1] = cut(tostring(key)) end
    end
    local first = list.rows[1]
    info.cells = first and type(first.cells) == "table" and #first.cells or 0
    local shownRows = 0
    for _, row in ipairs(list.rows) do if call(row, "IsShown") then shownRows = shownRows + 1 end end
    info.rowsShown = shownRows
    for i, h in ipairs(list.headers) do
        local shown = call(h, "IsShown")
        info.headers[i] = (shown and call(h, "GetText") or cut(call(h, "GetText"))) .. "\t" .. (shown and "S" or "-")
            .. "\t" .. num(call(h, "GetWidth")) .. "\t" .. (call(h, "IsTruncated") and "T" or "-")
    end
    if call(list, "IsVisible") then info.rows = listRows(list) end
    return info
end

-- One line per region (regionLine); lists also get their own record (listInfo) and their rows are not walked.
local function walk(obj, key, depth, out)
    if out.n >= MAX_ENTRIES then out.full = true return end
    local line, kind, shown = regionLine(obj, key)
    out.n = out.n + 1
    out.regions[#out.regions + 1] = line
    -- The rows of a list (60 rows of 12 cells) and its title areas are in the list's own record.
    local skip
    if isList(obj) then
        out.lists[key] = listInfo(obj)
        skip = {}
        for _, row in ipairs(obj.rows) do skip[row] = true end
        for _, area in ipairs(type(rawget(obj, "helps")) == "table" and obj.helps or {}) do skip[area] = true end
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
        for i, child in ipairs(kids) do
            if not (skip and skip[child]) then walk(child, key .. "." .. nameOf(child, "c", i), depth + 1, out) end
        end
    end
    local okR, regions = pcall(function() return { obj:GetRegions() } end)
    if okR then
        for i, region in ipairs(regions) do walk(region, key .. "." .. nameOf(region, "r", i), depth + 1, out) end
    end
end

local function views()
    return { main = ns.UI and rawget(ns.UI, "view"), ledger = ns.LedgerWindow and rawget(ns.LedgerWindow, "view") }
end

local function screen()
    local s = {}
    if type(GetScreenWidth) == "function" then s.w, s.h = num(GetScreenWidth()), num(GetScreenHeight()) end
    if type(UIParent) == "table" then
        s.scale, s.eff = num(call(UIParent, "GetScale")), num(call(UIParent, "GetEffectiveScale"))
    end
    return s
end

--- Walks every window that exists into a fresh dump. Called at logout; returns it.
function Layout.Save()
    if type(SalvagerDB) ~= "table" then return nil end
    local dump = { version = ns.VERSION, time = time(), screen = screen(), windows = {} }
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
                x = num(call(f, "GetLeft")), y = num(call(f, "GetTop")), scale = num(call(f, "GetScale")),
                eff = num(call(f, "GetEffectiveScale")), view = view[w.name], regions = {}, lists = {} }
            local saved = rawget(f, "saved")
            if not r.view and type(saved) == "table" then r.view = saved.view or saved.tab end
            out.regions, out.lists = r.regions, r.lists
            walk(f, w.name, 0, out)
            return r
        end)
        dump.windows[w.name] = ok and rec or { error = tostring(rec) }
    end
    dump.entries, dump.full = out.n, out.full or nil
    -- Every table's hidden columns by column set (the main window's tables and the Odds cards are not lists).
    dump.hidden = {}
    if type(SalvagerDB.columns) == "table" then
        for set, titles in pairs(SalvagerDB.columns) do
            local names = {}
            if type(titles) == "table" then
                for title, on in pairs(titles) do if on == false then names[#names + 1] = cut(tostring(title)) end end
            end
            table.sort(names)
            dump.hidden[tostring(set)] = table.concat(names, "\t")
        end
    end
    -- Bounded in the saved file: past MAX_BYTES the regions go, from the last window (hidden ones are last), then
    -- the lists' rows, from the last window too; the list records stay, they are the smallest part.
    dump.size = ns.Util.SavedSize(dump)
    for i = #order, 1, -1 do
        if dump.size <= MAX_BYTES then break end
        local rec = dump.windows[order[i].name]
        if rec.regions then
            rec.regions, rec.dropped = nil, true
            dump.size = ns.Util.SavedSize(dump)
        end
    end
    for i = #order, 1, -1 do
        if dump.size <= MAX_BYTES then break end
        local rec = dump.windows[order[i].name]
        for _, info in pairs(rec.lists or {}) do
            if info.rows then info.rows, rec.rowsDropped = nil, true end
        end
        dump.size = ns.Util.SavedSize(dump)
    end
    SalvagerDB.layout = dump
    return dump
end

ns.On("PLAYER_LOGOUT", function() Layout.Save() end)

-- The layout checks the specs share (fit_spec, tight_spec): what the stand-in draws (spec/wow.lua, layout mode),
-- measured from the rects and the texts, independent of the addon's own width code (SDD 106, 120).
--   M.problems(win, where, out, atDefault, ns): cut texts, overlaps in a row, regions outside the window, tables too
--     low or overlapping, columns left out, last columns before the right edge (fit_spec's rules).
--   M.measure(win, ns): the window's content rows (tables, rows of controls, the settings, free texts), each with
--     its slack (the px it could lose), the gaps between the columns of each table, the window's slack (the least).
local wow = require("spec.wow")
local M = {}

local ROWS = { tabrow = true, subtabrow = true, filterrow = true, footer = true }
local POPUP = { DIALOG = true, TOOLTIP = true, FULLSCREEN_DIALOG = true }
local EPS = 0.5
local ns_   -- (the addon: set by each call)

local function rect(r)
    local l, b, w, h = wow.rectOf(r)
    if not l then return nil end
    return { l = l, b = b, r = l + w, t = b + h, w = w, h = h }
end

local function inside(a, box) return a.l >= box.l - EPS and a.r <= box.r + EPS and a.b >= box.b - EPS and a.t <= box.t + EPS end
local function apart(a, box) return a.r <= box.l + EPS or a.l >= box.r - EPS or a.t <= box.b + EPS or a.b >= box.t - EPS end
local function clipTo(a, box)
    if not box then return a end
    return { l = math.max(a.l, box.l), r = math.min(a.r, box.r), b = math.max(a.b, box.b), t = math.min(a.t, box.t) }
end

-- The field that holds `r` in its parent or its parent's parent ("cells", "footer2"), to say which one it is.
local function key(r)
    for _, p in ipairs({ rawget(r, "parent"), rawget(r, "parent") and rawget(r.parent, "parent") }) do
        if type(p) == "table" then
            for k, v in pairs(p) do
                if v == r and type(k) == "string" then return k end
                if type(v) == "table" and type(k) == "string" and k ~= "_children" and k ~= "_regions" then
                    for _, x in ipairs(v) do if x == r then return k end end
                end
            end
        end
    end
end

local function name(r)
    local text = rawget(r, "text")
    local what = (rawget(r, "uiKind") or r.kind) .. (key(r) and ("." .. key(r)) or "")
    return what .. (type(text) == "string" and text ~= "" and (" \"" .. text:sub(1, 60) .. "\"") or "")
end

local function isList(obj)
    return type(rawget(obj, "headers")) == "table" and type(rawget(obj, "rows")) == "table"
        and type(rawget(obj, "columns")) == "table"
end

-- The problems of one window as it is drawn now; `where` names the window, the view and the size.
local function tableName(obj)
    if isList(obj) then return tostring(obj.columns[1] and obj.columns[1][1]) end
    return "of cards"
end

function M.problems(win, where, out, atDefault, ns)
    ns_ = ns or ns_
    local box = rect(win)
    local tables = {}
    local function add(msg) out[#out + 1] = where .. ": " .. msg end
    local function visit(obj, clip, list)
        if not obj:IsShown() then return end
        if POPUP[rawget(obj, "_strata") or ""] then return end
        local r = rect(obj)
        if r and r.w > 0 and r.h > 0 then
            local seen = clipTo(r, clip)
            local hidden = clip and (seen.l >= seen.r - EPS or seen.b >= seen.t - EPS)
            if hidden then return end   -- (scrolled away)
            if not clip and not inside(r, box) and obj.kind ~= "Texture" then
                add(string.format("%s outside the window (%.0f..%.0f of %.0f..%.0f wide, %.0f..%.0f of %.0f..%.0f high)",
                    name(obj), r.l, r.r, box.l, box.r, r.b, r.t, box.b, box.t))
            end
        end
        if obj.kind == "FontString" then
            if rawget(obj, "buttonText") then
                local b = rect(obj.parent)
                local tw = wow.textWidth(obj.text, obj:GetFont() and select(2, obj:GetFont()))
                if b and tw > b.w - 4 + EPS and (obj.text or "") ~= "" then
                    add(string.format("%s: text %.0f px in a button of %.0f", name(obj.parent), tw, b.w))
                end
            elseif wow.isCut(obj) and not rawget(obj, "canCut") then
                add(string.format("%s cut: %.0f px of text in %.0f%s", name(obj), obj:GetStringWidth(), r and r.w or -1,
                    list and (" (table " .. tostring(list.columns[1] and list.columns[1][1]) .. ")") or ""))
            end
            return
        end
        if obj.kind == "Texture" then return end
        local inner = clip
        if obj:DoesClipChildren() and r then inner = clip and clipTo(r, clip) or r end
        if ROWS[rawget(obj, "uiKind") or ""] then
            -- The controls and texts of a row: none overlaps another, all inside the row's ends.
            local items = {}
            local function collect(x)
                if not x:IsShown() or rawget(x, "uiKind") == "help" then return end   -- (a help area lies over its label)
                local xr = rect(x)
                if not xr or xr.w <= 0 then return end
                if x.kind == "FontString" and (x.text or "") == "" then return end
                -- A check box with its label is one item.
                local label = rawget(x, "label")
                if type(label) == "table" and label:IsShown() and (label.text or "") ~= "" then
                    local lr = rect(label)
                    if lr then xr = { l = math.min(xr.l, lr.l), r = math.max(xr.r, lr.r), b = math.min(xr.b, lr.b),
                        t = math.max(xr.t, lr.t) } end
                end
                items[#items + 1] = { x = x, r = xr }
            end
            for _, c in ipairs(obj._children) do if not POPUP[rawget(c, "_strata") or ""] then collect(c) end end
            for _, t in ipairs(obj._regions) do if t.kind == "FontString" then collect(t) end end
            for i = 1, #items do
                local a = items[i]
                if r and (a.r.l < r.l - EPS or a.r.r > r.r + EPS) then
                    add(string.format("%s beyond its %s's ends (%.0f..%.0f of %.0f..%.0f)", name(a.x), obj.uiKind,
                        a.r.l, a.r.r, r.l, r.r))
                end
                for j = i + 1, #items do
                    local b = items[j]
                    if not apart(a.r, b.r) then
                        add(string.format("%s overlaps %s in the %s (%.0f..%.0f and %.0f..%.0f)", name(a.x), name(b.x),
                            obj.uiKind, a.r.l, a.r.r, b.r.l, b.r.r))
                    end
                end
            end
        end
        if atDefault and isList(obj) and r then
            local right, n = nil, 0
            for i, h in ipairs(obj.headers) do
                if h:IsShown() and obj.columns[i] then
                    n = n + 1
                    local hr = rect(h)
                    if hr and (not right or hr.r > right) then right = hr.r end
                end
            end
            -- (Left at the right: the scroll bar and its gaps, 22 px; 32 where the rows' buttons are the last column.)
            local action = rawget(obj, "actionTitle")
            if action and action:IsShown() then local ar = rect(action) if ar then right = math.max(right or 0, ar.r) end end
            if n >= 2 and right and r.r - right > 34 then
                add(string.format("table %s: its last column ends %.0f px before its right edge", tostring(obj.columns[1][1]),
                    r.r - right))
            end
        end
        -- The main window's own table (the Gear and Materials tabs): its last column, the buttons', ends at the list's
        -- right edge too (the first column takes the spare width).
        if atDefault and ns_ and obj == ns_.UI.list and r then
            local right
            for _, h in ipairs(ns_.UI.headers) do
                if h:IsShown() and (h.text or "") ~= "" then local hr = rect(h) if hr then right = math.max(right or 0, hr.r) end end
            end
            for _, row in ipairs(ns_.UI.rows) do
                if row:IsShown() and row.buy:IsShown() then local br = rect(row.buy) if br then right = math.max(right or 0, br.r) end end
            end
            -- (The buttons' title is the last column too: a table with no rows shows it.)
            local ah = ns_.UI.actionHeader
            if ah and ah:IsShown() and (rawget(ah, "text") or "") ~= "" then
                local ar = rect(ah)
                if ar then right = math.max(right or 0, ar.r) end
            end
            if os.getenv("FIT_DEBUG") then print("main table", where, r.r, right) end
            if right and r.r - right > 12 then
                add(string.format("the main window's table: its last column ends %.0f px before its right edge", r.r - right))
            end
        end
        if atDefault and rawget(obj, "cards") and rawget(obj, "widths") and r then
            -- A stack of cards (the Odds): in each card, the last column ends at the card's right edge.
            for _, card in ipairs(obj.cards) do
                if card:IsShown() and card.heads:IsShown() then
                    local cr, right = rect(card), nil
                    for i, h in ipairs(card.headTexts) do
                        if h:IsShown() and i > 1 then local hr = rect(h) if hr then right = math.max(right or 0, hr.r) end end
                    end
                    if cr and right and inside(cr, clip or box) and cr.r - right > 34 then
                        add(string.format("cards %s: the last column ends %.0f px before the card's right edge",
                            tostring(card.title.text), cr.r - right))
                    end
                end
            end
        end
        -- A table leaves no column out at the default size (on a 1920 wide screen): the window fits its columns
        -- (SDD 107). At the smallest size a column may be left out, and then the table's note says so. FIT_DEBUG=1
        -- lists them.
        if isList(obj) then
            local W, dropped = ns_.Widgets, {}
            for i, col in ipairs(obj.columns) do
                local wanted = W.ColumnShown(rawget(obj, "columnSet"), W.ColumnKey(col))
                if i > 1 and wanted and not obj.headers[i]:IsShown() then dropped[#dropped + 1] = tostring(col[1]) end
            end
            if #dropped > 0 then
                local text = "table " .. tostring(obj.columns[1][1]) .. " leaves out " .. table.concat(dropped, ", ")
                if atDefault then add(text) end
                local note = rawget(obj, "leftOutNote")
                if rawget(obj, "headers")[1]:IsShown() and not (note and note:IsShown()) then
                    add(text .. " without its note")
                end
                if os.getenv("FIT_DEBUG") then print(where .. ": " .. text) end
            end
        end
        -- The tables of the window (lists and stacks of cards), for the check that none overlaps another.
        if r and not clip and (isList(obj) or rawget(obj, "cards")) then tables[#tables + 1] = { obj = obj, r = r } end
        local within = list
        if isList(obj) then within = obj end
        for _, c in ipairs(obj._children) do visit(c, inner, within) end
        for _, t in ipairs(obj._regions) do visit(t, inner, within) end
    end
    visit(win, nil)
    -- No table overlaps another, and each is at least as tall as its titles and two rows (SDD 113).
    for i, a in ipairs(tables) do
        local least = 3 * 22
        if isList(a.obj) then
            local rowH = rawget(a.obj.rows[1], "_h") or 22
            -- (A table of one row may be as tall as that row.)
            least = ((a.obj.headers[1]:IsShown() and 1 or 0) + math.min(2, math.max(1, rawget(a.obj, "count") or 2))) * rowH
        end
        if a.r.h < least - EPS then
            add(string.format("table %s: %.0f px high, less than its titles and two rows (%.0f)", tableName(a.obj), a.r.h, least))
        end
        for j = i + 1, #tables do
            local b = tables[j]
            if not apart(a.r, b.r) then
                add(string.format("table %s overlaps table %s (%.0f..%.0f and %.0f..%.0f high)", tableName(a.obj),
                    tableName(b.obj), a.r.b, a.r.t, b.r.b, b.r.t))
            end
        end
    end
end


M.rect, M.inside, M.apart, M.isList = rect, inside, apart, isList

------------------------------------------------------------------ tightness (SDD 120)

-- The normal gap between the texts of two columns next to each other (UI.md Tables 2), and its tolerance in the specs.
M.NORMAL, M.TOL, M.SLACK, M.SEP = 16, 2, 8, 12

local function shown(x) return x and x:IsVisible() end

-- Where a text's letters are in its box: left and right, by its justification.
local function textSpan(fs)
    local r = rect(fs)
    if not r then return nil end
    local tw = math.min(fs:GetStringWidth(), r.w)
    local j = fs:GetJustifyH()
    if j == "RIGHT" then return r.r - tw, r.r end
    if j == "CENTER" then return (r.l + r.r - tw) / 2, (r.l + r.r + tw) / 2 end
    return r.l, r.l + tw
end
M.textSpan = textSpan

local function hasText(fs) return shown(fs) and (rawget(fs, "text") or "") ~= "" end

-- One table as drawn: its columns left to right, each { title, l, r, sep, box }, and the right end its last column
-- may reach (`right`), or nil where it shows no titles.
local function spansOf(columns, right)
    local out = {}
    for _, c in ipairs(columns) do
        local lo, hi
        local function add(fs)
            if hasText(fs) then
                local a, b = textSpan(fs)
                if a then lo, hi = math.min(lo or a, a), math.max(hi or b, b) end
            end
        end
        add(c.header)
        for _, fs in ipairs(c.cells) do add(fs) end
        -- The rows of the data not on screen (scrolled away): their texts in the column's box.
        local hr = c.header and rect(c.header)
        for _, x in ipairs(c.texts or {}) do
            if hr and x.w > 0 then
                local j = c.header:GetJustifyH()
                local a, b
                if j == "RIGHT" then a, b = hr.r - x.w, hr.r
                elseif j == "CENTER" then a, b = (hr.l + hr.r - x.w) / 2, (hr.l + hr.r + x.w) / 2
                else a, b = hr.l, hr.l + x.w end
                lo, hi = math.min(lo or a, a), math.max(hi or b, b)
            end
        end
        for _, x in ipairs(c.controls or {}) do
            local xr = shown(x) and rect(x)
            if xr then lo, hi = math.min(lo or xr.l, xr.l), math.max(hi or xr.r, xr.r) end
        end
        if lo then out[#out + 1] = { title = tostring(rawget(c.header, "text") or "?"):sub(1, 24), l = lo, r = hi,
            sep = c.sep, action = c.action, live = c.live } end
    end
    return { cols = out, right = right }
end

-- The controls in a row of a table, in column box `cr` (Limits: the money boxes).
local function controlsIn(row, cr)
    local out = {}
    for _, c in ipairs(row._children) do
        local r = shown(c) and rect(c)
        if r and rawget(c, "uiKind") == "edit" and r.l >= cr.l - EPS and r.l < cr.r then out[#out + 1] = c end
    end
    return out
end

-- Every table of the window: Widgets.List, the main window's own table, the cards of a Widgets.CardList.
local function tablesOf(win, ns)
    local out = {}
    local function visit(obj)
        if not obj:IsVisible() then return end
        if isList(obj) and obj.headers[1]:IsShown() then
            local cols, lr = {}, rect(obj)
            for i, h in ipairs(obj.headers) do
                if h:IsShown() and obj.columns[i] then
                    local cells, controls, hr = {}, {}, rect(h)
                    for _, row in ipairs(obj.rows) do
                        if row:IsVisible() and not (rawget(row, "data") and row.data.span) then
                            cells[#cells + 1] = row.cells[i]
                            for _, c in ipairs(hr and controlsIn(row, hr) or {}) do controls[#controls + 1] = c end
                        end
                    end
                    -- Every row of the data (up to 400, as the table measures them), the first column's on screen only.
                    local texts = {}
                    local getRow, count = rawget(obj, "getRow"), rawget(obj, "count") or 0
                    if getRow then
                        local short = ns and ns.Widgets.CellText or function(t) return t end
                        for r = 1, math.min(count, 400) do
                            local d = getRow(r)
                            if d and not d.span and d.cells and d.cells[i] and d.cells[i] ~= "" then
                                -- (The first column's text sits after the row's indent, open sign and icon.)
                                local extra = i == 1 and ((d.indent or 0) + (d.itemID and 22 or 0)
                                    + (d.open ~= nil and 22 or 0)) or 0
                                texts[#texts + 1] = { w = wow.textWidth(short(d.cells[i]), d.bold and 12 or 10) + extra }
                            end
                        end
                    end
                    cols[#cols + 1] = { header = h, cells = cells, controls = controls, texts = texts,
                        live = obj.columns[i].sample ~= nil }
                end
            end
            local action = rawget(obj, "actionTitle")
            if shown(action) then
                local buttons = {}
                for _, row in ipairs(obj.rows) do if row:IsVisible() and shown(row.action) then buttons[#buttons + 1] = row.action end end
                cols[#cols + 1] = { header = action, cells = {}, controls = buttons, action = true }
            end
            local t = spansOf(cols, lr and (lr.r - 18 - 4))
            t.name, t.obj = tostring(obj.columns[1] and obj.columns[1][1]), obj
            -- An empty table's note (a row that spans it) is a row of content too.
            for _, row in ipairs(obj.rows) do
                if row:IsVisible() and rawget(row, "data") and row.data.span and hasText(row.cells[1]) then
                    local _, b = textSpan(row.cells[1])
                    t.notes = t.notes or {}
                    t.notes[#t.notes + 1] = b
                end
            end
            out[#out + 1] = t
            return
        end
        if ns and ns.UI and obj == ns.UI.list then
            local cols = {}
            for i, h in ipairs(ns.UI.headers) do
                if h:IsShown() and hasText(h) then
                    local cells = {}
                    for _, row in ipairs(ns.UI.rows) do if row:IsVisible() then cells[#cells + 1] = row.cells[i] end end
                    -- (The Materials tab's live column, Age: its sample's width.)
                    local mc = ns.UI.view == "materials" and ns.Materials.COLUMNS[i]
                    cols[#cols + 1] = { header = h, cells = cells, live = mc and mc.sample ~= nil or nil }
                end
            end
            local buttons = {}
            for _, row in ipairs(ns.UI.rows) do if row:IsVisible() and shown(row.buy) then buttons[#buttons + 1] = row.buy end end
            if hasText(ns.UI.actionHeader) then
                cols[#cols + 1] = { header = ns.UI.actionHeader, cells = {}, controls = buttons, action = true }
            end
            local lr = rect(obj)
            local t = spansOf(cols, lr and (lr.r - 4))
            t.name = "main " .. tostring(ns.UI.view)
            out[#out + 1] = t
        end
        if rawget(obj, "cards") and rawget(obj, "widths") then
            -- The cards of one place in the row (same left edge and width) line up (UI.md Tables 17): their columns
            -- are measured over all of them, on the first one's titles.
            local groups, order = {}, {}
            for _, card in ipairs(obj.cards) do
                local cr = card:IsVisible() and card.heads:IsShown() and rect(card)
                if cr then
                    local k = string.format("%.0f:%.0f", cr.l, cr.w)
                    if not groups[k] then groups[k] = { first = card, cards = {}, r = cr.r } order[#order + 1] = k end
                    table.insert(groups[k].cards, card)
                end
            end
            for _, k in ipairs(order) do
                local g, cols = groups[k], {}
                for i, h in ipairs(g.first.headTexts) do
                    if h:IsShown() then
                        local cells = {}
                        for _, card in ipairs(g.cards) do
                            for _, row in ipairs(card.rows) do if row:IsVisible() then cells[#cells + 1] = row.cells[i] end end
                        end
                        cols[#cols + 1] = { header = h, cells = cells, sep = obj.columns[i] and obj.columns[i].sep }
                    end
                end
                local t = spansOf(cols, g.r - 8)
                t.name = "cards at " .. k
                out[#out + 1] = t
            end
        end
        for _, c in ipairs(obj._children) do visit(c) end
    end
    visit(win)
    return out
end
M.tablesOf = tablesOf

-- A row of controls (or the settings block, one line per row of it): what it could lose. Its regions placed from the
-- left (anchored by a left point) end at L, those from the right start at R; `gap` between the two parts.
local BARS = { tabrow = 12, subtabrow = 12, filterrow = 12, footer = 12, settings = 24 }
local function sideOf(x)
    local p = rawget(x, "points") and x.points[1]
    return p and type(p[1]) == "string" and p[1]:find("RIGHT") and "R" or "L"
end
local function barRows(bar, gap)
    local br = rect(bar)
    if not br then return {} end
    local items = {}
    local function add(x)
        if not shown(x) or rawget(x, "uiKind") == "help" then return end
        local r = rect(x)
        if not r or r.w <= 0 then return end
        local side = sideOf(x)
        if x.kind == "FontString" then
            if (rawget(x, "text") or "") == "" then return end
            local a, b = textSpan(x)
            -- (A text that may be cut holds the row at 120 px at most.)
            if rawget(x, "canCut") then b = math.min(b, a + 120) a = math.max(a, b - 120) end
            r = { l = a, r = b, b = r.b, t = r.t }
        end
        local label = rawget(x, "label")
        if type(label) == "table" and hasText(label) then
            local la, lb = textSpan(label)
            if la then r = { l = math.min(r.l, la), r = math.max(r.r, lb), b = r.b, t = r.t } end
        end
        items[#items + 1] = { side = side, r = r }
    end
    for _, c in ipairs(bar._children) do add(c) end
    for _, t in ipairs(bar._regions) do if t.kind == "FontString" then add(t) end end
    -- One line per vertical place (the settings block has three).
    local lines = {}
    for _, it in ipairs(items) do
        local y = (it.r.b + it.r.t) / 2
        local line
        for _, l in ipairs(lines) do if math.abs(l.y - y) < 8 then line = l end end
        if not line then line = { y = y, L = nil, R = nil } lines[#lines + 1] = line end
        if it.side == "L" then line.L = math.max(line.L or -1e9, it.r.r) else line.R = math.min(line.R or 1e9, it.r.l) end
    end
    local out = {}
    for _, l in ipairs(lines) do
        local slack
        if l.L and l.R then slack = l.R - l.L - gap
        elseif l.L then slack = br.r - l.L - 2
        else slack = l.R - br.l - 2 end
        out[#out + 1] = slack
    end
    return out
end

--- The window's rows of content with their slack, its tables' gaps, and the window's slack (the least of its rows).
function M.measure(win, ns)
    local wr = rect(win)
    local rows, tables = {}, tablesOf(win, ns)
    for _, t in ipairs(tables) do
        local c, excess = t.cols, 0
        t.gaps = {}
        for i = 2, #c do
            local g = c[i].l - c[i - 1].r
            t.gaps[i - 1] = { from = c[i - 1].title, to = c[i].title, gap = g, sep = c[i].sep, action = c[i].action,
                first = i == 2, live = c[i].live or c[i - 1].live }
            local allowed = M.NORMAL + M.TOL + (c[i].sep and M.SEP or 0) + (c[i].action and 50 or 0)
            excess = excess + math.max(0, g - allowed)
        end
        local tail = (#c > 0 and t.right) and math.max(0, t.right - c[#c].r - 4) or 0
        rows[#rows + 1] = { kind = "table", name = t.name, slack = excess + tail }
        for _, b in ipairs(t.notes or {}) do rows[#rows + 1] = { kind = "note", name = t.name, slack = t.right - b } end
    end
    local function visit(obj)
        if not obj:IsVisible() then return end
        local gap = BARS[rawget(obj, "uiKind") or ""]
        if gap then
            for _, s in ipairs(barRows(obj, gap)) do rows[#rows + 1] = { kind = obj.uiKind, slack = s } end
        end
        for _, c in ipairs(obj._children) do if not isList(c) then visit(c) end end
    end
    visit(win)
    -- Texts of the window itself (a heading, a table's title): content that may not be cut.
    for _, t in ipairs(win._regions) do
        if t.kind == "FontString" and hasText(t) and not rawget(t, "canCut") and t ~= rawget(win, "TitleText")
            and t ~= rawget(win, "versionText") and t:GetStringHeight() <= 16 then
            local _, b = textSpan(t)
            if b and wr then rows[#rows + 1] = { kind = "text", name = rawget(t, "text"):sub(1, 30), slack = wr.r - 12 - b } end
        end
    end
    local least
    for _, r in ipairs(rows) do if not least or r.slack < least then least = r.slack end end
    return { slack = least or 0, rows = rows, tables = tables, width = wr and wr.w or 0 }
end

--- The gaps of the window's tables outside the normal one: every gap at least NORMAL - TOL; every gap but the first
--- (which takes what a window forced wider gives the first column) at most NORMAL + TOL (a line before it: + SEP;
--- the buttons' column, a button under a centred title: not checked).
function M.badGaps(m)
    local out, most = {}, 0
    for _, t in ipairs(m.tables) do
        for _, g in ipairs(t.gaps or {}) do
            -- (A live column keeps its widest possible value's width, UI.md Tables 2: the gaps at its sides wider.)
            if not g.action and not g.live then
                local normal = M.NORMAL + (g.sep and M.SEP or 0)
                most = math.max(most, g.gap)
                if g.gap < normal - M.TOL - EPS or (not g.first and g.gap > normal + M.TOL + EPS) then
                    out[#out + 1] = string.format("%s: %s > %s %.0f px", t.name, g.from, g.to, g.gap)
                end
            end
        end
    end
    return out, most
end

return M

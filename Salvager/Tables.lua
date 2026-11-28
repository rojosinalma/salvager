-- Salvager: the tables. Widgets.List is one scrolling table; Widgets.CardList is a scrolling stack
-- of small tables, one per card. Both have the same look: a sunken panel, a title band, striped rows.
local _, ns = ...

local Widgets = ns.Widgets

-- Why a column of the chooser cannot be hidden (its row is ticked and greyed).
local FIRST_REASON = "The first column names the row: it always shows."
local ACTION_REASON = "This column holds the rows' buttons: it always shows."
Widgets.FIRST_COLUMN_REASON, Widgets.ACTION_COLUMN_REASON = FIRST_REASON, ACTION_REASON
-- Why a column is unticked that the player did not hide: no room for it (the only sign of a column left out).
Widgets.LEFT_OUT_REASON = "Left out: the window is as wide as the screen, and this column has no room. Hide another "
    .. "column to make room for it."

--- The column's name in the chooser and in the saved choice: its title without a sort arrow (`col.key`).
function Widgets.ColumnKey(col) return col.key or col[1] end

--- Which columns a table shows, saved per column set: SalvagerDB.columns[setId][title] = false (hidden).
--- Titles that are not in the table are ignored.
function Widgets.ColumnShown(setId, title)
    local all = setId and ns.db and rawget(ns.db, "columns")
    local set = type(all) == "table" and all[setId]
    return not (type(set) == "table" and set[title] == false)
end

function Widgets.SetColumnShown(setId, title, on)
    if not (setId and ns.db) then return end
    if type(ns.db.columns) ~= "table" then ns.db.columns = {} end
    local set = ns.db.columns[setId] or {}
    if on then set[title] = nil else set[title] = false end
    ns.db.columns[setId] = next(set) ~= nil and set or nil
end

function Widgets.ShowAllColumns(setId)
    if setId and ns.db and type(ns.db.columns) == "table" then ns.db.columns[setId] = nil end
end

------------------------------------------------------------------ sorting (UI.md Tables 10)
-- One implementation for every table (Widgets.List, Widgets.CardList, the main window's): a click on a title sorts by
-- that column, again turns it round; the arrow is on the sorted title only (and counts in its width, Tables 2); the
-- choice is saved per table (SalvagerDB.sorts[id] = { key = column key, desc }). A row sorts by `row.sort[i]` where it
-- gives one, else by its cell's full text (Util.SortValue: money in copper, percents and numbers as numbers, times in
-- order); unknown ("-", "") last both ways; ties keep the previous order. Headings (row.head, row.group), totals
-- (row.rule, row.bold) and notes (row.span) stay in place: the rows sort inside each group, each row with the rows
-- indented under it. A column with `sort = false` (a statement's, the buttons') is not clickable and has no arrow.
Widgets.SORT_DOWN = " |TInterface\\Buttons\\Arrow-Down-Up:10|t"
Widgets.SORT_UP = " |TInterface\\Buttons\\Arrow-Up-Up:10|t"
Widgets.SORT_HINT = "Click: sort by this column; again: the other way round."

--- The saved order of table `id` ({ key, desc } or nil); `create`: make it.
function Widgets.SortState(id, create)
    if not (id and ns.db) then return nil end
    if type(ns.db.sorts) ~= "table" then
        if not create then return nil end
        ns.db.sorts = {}
    end
    local s = ns.db.sorts[id]
    if type(s) ~= "table" and create then s = {} ns.db.sorts[id] = s end
    return type(s) == "table" and s or nil
end

--- The column index a sort state names in `cols` (by its key, else its index `col`), or nil.
function Widgets.SortColumn(cols, state)
    if not (state and cols) then return nil end
    if state.key ~= nil then
        for i, col in ipairs(cols) do if Widgets.ColumnKey(col) == state.key then return i end end
        return nil
    end
    local i = tonumber(state.col)
    return i and cols[i] and i or nil
end

--- Can the table's column i be sorted? (Not a statement's, not a column of controls, not one with sort = false.)
function Widgets.ColumnSortable(cols, i)
    local col = cols and cols[i]
    if not col or cols.statement or col.sort == false or col.least then return false end
    return true
end

--- The title of column i with the arrow where the table is sorted by it.
function Widgets.SortTitle(title, i, sortedBy, desc)
    if i ~= sortedBy then return title end
    return tostring(title) .. (desc and Widgets.SORT_DOWN or Widgets.SORT_UP)
end

local function fixedRow(d) return d.head or d.group or d.rule or d.bold or d.span or d.fixed end
local function sortValue(d, i)
    local v = type(d.sort) == "table" and d.sort[i] or nil
    if v ~= nil then return v, type(v) == "number" and "number" or "text" end
    return ns.Util.SortValue(d.cells and d.cells[i])
end

--- Rows sorted by column i (desc: highest first), groups kept (see above). Returns a new array.
function Widgets.SortRows(rows, i, desc)
    local n = #rows
    if n < 2 then return rows end
    -- The column's kind: numbers where any row has one (a text in a number column then counts as unknown).
    local values, numeric = {}, false
    for r = 1, n do
        local v, kind = sortValue(rows[r], i)
        values[r] = { v = v, kind = kind }
        if kind == "number" then numeric = true end
    end
    for r = 1, n do
        local x = values[r]
        if numeric and x.kind ~= "number" then x.v = nil end
        if not numeric and x.v ~= nil then x.v = tostring(x.v) end
    end
    -- The tree by indent: each row with the rows indented deeper right under it.
    local function indentOf(r) return rows[r].indent or 0 end
    local out = {}
    local function emit(r, last)   -- row r and its subtree (rows r+1..last), its children sorted
        out[#out + 1] = rows[r]
        local kids, k = {}, r + 1
        while k <= last do
            local e = k + 1
            while e <= last and indentOf(e) > indentOf(k) do e = e + 1 end
            kids[#kids + 1] = { first = k, last = e - 1 }
            k = e
        end
        -- Runs of children between fixed ones (headings, totals, notes) sort; the fixed ones keep their place.
        local s = 1
        while s <= #kids do
            if fixedRow(rows[kids[s].first]) then
                s = s + 1
            else
                local e = s
                while e + 1 <= #kids and not fixedRow(rows[kids[e + 1].first]) do e = e + 1 end
                local run = {}
                for x = s, e do run[#run + 1] = kids[x] end
                table.sort(run, function(a, b)
                    local va, vb = values[a.first].v, values[b.first].v
                    if va == vb or (va == nil and vb == nil) then return a.first < b.first end
                    if va == nil then return false end
                    if vb == nil then return true end
                    if desc then return va > vb end
                    return va < vb
                end)
                for x = s, e do kids[x] = run[x - s + 1] end
                s = e + 1
            end
        end
        for _, kid in ipairs(kids) do emit(kid.first, kid.last) end
    end
    -- A virtual root over every row.
    local root = { indent = -1, cells = {} }
    table.insert(rows, 1, root)
    table.insert(values, 1, { v = nil })
    emit(1, n + 1)
    table.remove(rows, 1)
    table.remove(values, 1)
    table.remove(out, 1)
    return out
end

--- A click on title i of a table whose order is `state` (made with Widgets.SortState(id, true)): sorts by it, highest
--- first for numbers and A to Z for text; a second click turns it round. `cols`, `rows` tell the column's kind.
function Widgets.SortClick(state, cols, i, rows)
    local key = Widgets.ColumnKey(cols[i])
    if state.key == key or (state.key == nil and tonumber(state.col) == i) then
        state.desc = not state.desc
    else
        local numeric = false
        for _, d in ipairs(rows or {}) do
            if not fixedRow(d) then
                local _, kind = sortValue(d, i)
                if kind == "number" then numeric = true break end
            end
        end
        state.desc = numeric
    end
    state.key, state.col = key, nil
end

--- The column chooser of a table: a small button with three stacked dots (the game fonts have no vertical
--- ellipsis). A click opens a menu under it: one check row per column (ticked = shown), and "Show all".
--- A click on a row shows or hides that column at once; the menu stays open. It closes on a click outside,
--- on Escape, or on the button again.
---   getColumns() -> setId, { { key = title, locked = reason or nil }, ... }; changed() runs after each change.
function Widgets.ColumnChooser(parent, getColumns, changed)
    local b = Widgets.IconButton(parent, 16)
    b.icon:Hide()
    for i = 1, 3 do
        local dot = b:CreateTexture(nil, "OVERLAY")
        dot:SetColorTexture(1, 0.82, 0, 1)
        dot:SetSize(2, 2)
        dot:SetPoint("CENTER", b, "CENTER", 0, 8 - i * 4)
    end
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Columns", 1, 1, 1)
        Widgets.AddHelp(GameTooltip, nil, "Choose the columns this table shows.")
        local _, cols = getColumns()
        local out = {}
        for _, col in ipairs(cols or {}) do if col.leftOut then out[#out + 1] = col.key end end
        if #out > 0 then
            GameTooltip:AddLine("Left out, the window is as wide as the screen: " .. table.concat(out, ", ") .. ".",
                1, 0.3, 0.3, true)
        end
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- (On UIParent: the tables clip what is inside them.)
    local menu = CreateFrame("Frame", nil, UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    menu:SetFrameStrata("DIALOG")
    menu:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, -2)
    if menu.SetBackdrop then
        -- The look of the drop-downs (Widgets.CheckDropdown): the game's tooltip, near-black fill, grey border.
        menu:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        menu:SetBackdropColor(0, 0, 0, 0.92)
        menu:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    else
        local bg = menu:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.92)
    end
    menu:EnableMouse(true)
    menu:Hide()
    local checks = {}
    b.checks = checks   -- (the specs read them)
    local showAll
    local function newCheck(i)
        local c = Widgets.Check(menu, "", nil, function(on)
            local id = getColumns()
            local key = rawget(checks[i], "key")
            Widgets.SetColumnShown(id, key, on)
            b.Update()
            changed()
        end)
        c:SetPoint("TOPLEFT", menu, "TOPLEFT", 8, -6 - (i - 1) * 22)
        c:SetMotionScriptsWhileDisabled(true)
        c:SetScript("OnEnter", function(self)
            local why = rawget(self, "reason")
            if not why then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(rawget(self, "key"), 1, 1, 1)
            Widgets.AddHelp(GameTooltip, nil, why)
            GameTooltip:Show()
        end)
        c:SetScript("OnLeave", function() GameTooltip:Hide() end)
        checks[i] = c
        return c
    end
    showAll = Widgets.Button(menu, "Show all", 100, function()
        Widgets.ShowAllColumns((getColumns()))
        b.Update()
        changed()
    end)
    showAll:SetMotionScriptsWhileDisabled(true)
    showAll:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Show all", 1, 1, 1)
        Widgets.AddHelp(GameTooltip, nil, self:IsEnabled() and "Shows every column of this table again."
            or "Every column shows already.")
        GameTooltip:Show()
    end)
    showAll:HookScript("OnLeave", function() GameTooltip:Hide() end)

    --- Fills the menu from the table's columns now.
    function b.Update()
        local id, cols = getColumns()
        local widest, any = Widgets.TextWidth("Show all") or 60, false
        for i, col in ipairs(cols) do
            local c = checks[i] or newCheck(i)
            c.key, c.reason = col.key, col.locked or col.leftOut
            c.label:SetText(col.key)
            -- (A column left out for want of room shows unticked, the reason on hover: the only sign of it.)
            local on = col.locked ~= nil or (Widgets.ColumnShown(id, col.key) and not col.leftOut)
            if not on and not col.leftOut then any = true end
            c:SetChecked(on)
            c:SetEnabled(col.locked == nil)
            if col.locked then c.label:SetTextColor(0.5, 0.5, 0.5) else c.label:SetTextColor(1, 1, 1) end
            c:Show()
            widest = math.max(widest, Widgets.TextWidth(col.key) or 120)
        end
        for i = #cols + 1, #checks do checks[i]:Hide() end
        local w = math.max(140, math.ceil(widest) + 46)
        showAll:ClearAllPoints()
        showAll:SetPoint("TOPLEFT", menu, "TOPLEFT", 10, -8 - #cols * 22)
        showAll:SetWidth(w - 20)
        showAll:SetEnabled(any)
        menu:SetSize(w, #cols * 22 + 40)
    end
    function b.Close() menu:Hide() end
    b:SetScript("OnClick", function()
        if menu:IsShown() then menu:Hide() return end
        b.Update()
        menu:Show()
    end)
    b:SetScript("OnHide", function() menu:Hide() end)
    -- Escape closes the menu (and only the menu); every other key goes on to the game. The keyboard is not
    -- taken in combat, where the client does not let an addon pass keys on.
    local function combat() return InCombatLockdown and InCombatLockdown() end
    menu:SetScript("OnKeyDown", function(self, key)
        if combat() then return end
        if key == "ESCAPE" then
            self:SetPropagateKeyboardInput(false)
            self:Hide()
        else
            self:SetPropagateKeyboardInput(true)
        end
    end)
    -- A click anywhere else closes the menu. The click still does what it was aimed at.
    local watching = pcall(menu.RegisterEvent, menu, "GLOBAL_MOUSE_DOWN")
    if watching then menu:UnregisterEvent("GLOBAL_MOUSE_DOWN") end
    menu:SetScript("OnShow", function(self)
        if watching then self:RegisterEvent("GLOBAL_MOUSE_DOWN") end
        if not combat() then
            self:EnableKeyboard(true)
            self:SetPropagateKeyboardInput(true)
        end
    end)
    menu:SetScript("OnHide", function(self)
        if watching then self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end
        if not combat() then self:EnableKeyboard(false) end
    end)
    if watching then
        menu:SetScript("OnEvent", function(self)
            if not self:IsMouseOver() and not b:IsMouseOver() then self:Hide() end
        end)
    else
        -- A client without that event: an invisible sheet behind the menu takes the click.
        local sheet = CreateFrame("Button", nil, menu)
        sheet:SetAllPoints(UIParent)
        sheet:SetFrameLevel(math.max(0, menu:GetFrameLevel() - 1))
        sheet:SetScript("OnClick", function() menu:Hide() end)
    end
    b.menu, b.checks, b.showAll = menu, checks, showAll
    return b
end

-- A title's help text: a string, or a function that gives it when the help shows (ns.TimeHelp: which clock).
local function helpLine(text)
    if type(text) == "function" then return text() end
    return text
end

--- A scrolling table. The caller anchors the returned frame.
---   list:SetColumns({ { title, width, justify, help = { title, text or function() -> text }, sample = text, key = title }, ... }, setId)
---                                                         the first column takes the spare width; help shows
---                                                         on the column title; sample = the widest text the
---                                                         column can hold ("00:00:00"), so it keeps its width;
---                                                         key = the title without a sort arrow. setId names the
---                                                         column set: the columns hidden with the chooser (the
---                                                         button at the right end of the titles) are saved under
---                                                         it; a list without one has no chooser.
---   cols.statement = true                                 a statement (label and amounts): its totals' rules; it
---                                                         does not sort (its lines are in their order)
---                                                         (every table spans its window: its first column takes
---                                                         the free width, so the last column ends at the right
---                                                         edge, UI.md Tables 2, SDD 127)
---   col.sort = false                                      the column does not sort (Widgets.SortRows)
---   list.onColumnsChanged = fn                            runs after a change in the chooser (else list:Refresh),
---                                                         and after a sort click (list.onSortChanged first)
---   list.sortId = id                                      where the order is saved (else the column set's id)
---   list:SetSource(count, getRow)                         getRow(i) -> row, only called for rows on screen
---   list:Refresh()
--- row = { cells = { text, ... }, itemID = icon and tooltip, link = tooltip, indent = pixels,
---         tip = { title, line, ... } (hover help of the row, instead of an item tooltip),
---         rule = "total" (a line over the amounts: a subtotal) or "final" (that line and a double one under),
---         bold = true (a total: its texts in the larger font, BOLD_FONT),
---         span = true (a note, an empty table's why: its first cell spans the row; it sets no column's width) }
--- row.group = true marks the first row of a group (an item with its materials under it): it gets a band.
--- opts = { rowHeight = 22, header = true, plain = false }
--- Unless `plain`, the list is drawn as a sunken table: dark panel, title band, every second row shaded.
-- The fonts a table draws in, and measures in (Widgets.TextWidth): titles, cells, a total's texts (12 pt).
local TITLE_FONT, CELL_FONT, BOLD_FONT = Widgets.TITLE_FONT, Widgets.CELL_FONT, Widgets.BOLD_FONT
function Widgets.List(parent, opts)
    opts = opts or {}
    local ROW_H = opts.rowHeight or 22
    local TOGGLE = math.min(ROW_H, 18)   -- the open / close sign
    local HEAD_H = opts.header == false and 0 or ROW_H
    -- MAX_COLS: the cells made per row; a table with more columns is refused (SetColumns), not cut.
    local MAX_ROWS, MAX_COLS, BAR_W = 60, 12, 18
    local MIN_FIRST = 90       -- the first column never gets narrower than this
    -- The buttons' column (opts.actionWidth set): the warning sign (22) and the button (64), right after the last
    -- column, then 4 px. Its width is the button's: a true constant.
    local ACTION_W = opts.actionWidth and (22 + 64 + 4) or 0
    local list = CreateFrame("Frame", nil, parent)
    if list.SetClipsChildren then list:SetClipsChildren(true) end
    list.offset, list.count, list.columns = 0, 0, {}
    local headers, helps, helpText, rows = {}, {}, {}, {}
    list.headers, list.helps, list.rows = headers, helps, rows
    local SKIN = not opts.plain
    if SKIN then
        Widgets.Skin(list, 0, 0, 0, 0.5)
        if HEAD_H > 0 then
            local band = list:CreateTexture(nil, "BACKGROUND", nil, 1)
            band:SetPoint("TOPLEFT", list, "TOPLEFT", 1, -1)
            band:SetPoint("TOPRIGHT", list, "TOPRIGHT", -1, -1)
            band:SetHeight(HEAD_H)
            band:SetColorTexture(1, 1, 1, 0.07)
        end
    end

    if ACTION_W > 0 and HEAD_H > 0 and opts.actionTitle then
        -- The title over the rows' buttons.
        local t = list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t:SetHeight(ROW_H)
        t:SetWidth(64)
        t:SetJustifyH("CENTER")
        t:SetPoint("TOPRIGHT", list, "TOPRIGHT", -BAR_W - 4, 0)
        t:SetText(opts.actionTitle)
        list.actionTitle = t
    end
    for i = 1, MAX_COLS do
        local h = list:CreateFontString(nil, "OVERLAY", TITLE_FONT)
        h:SetHeight(ROW_H)
        h.measureFont = TITLE_FONT
        headers[i] = h
        -- An invisible area over the title, for its help text.
        local area = CreateFrame("Frame", nil, list)
        area:SetAllPoints(h)
        area:EnableMouse(true)
        area:SetScript("OnEnter", function(self)
            local help = helpText[i]
            local sortable = list.columns[i] and list:Sortable(i)
            if not help and not sortable then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            local lines = {}
            for n = 2, #(help or {}) do lines[#lines + 1] = helpLine(help[n]) end
            Widgets.AddHelp(GameTooltip, help and help[1] or tostring(Widgets.ColumnKey(list.columns[i])), lines)
            if sortable then Widgets.AddHelp(GameTooltip, nil, Widgets.SORT_HINT, 0.5, 0.8, 1) end
            GameTooltip:Show()
        end)
        area:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- A click on a title sorts by that column (Widgets.SortClick); again, the other way round.
        area:SetScript("OnMouseUp", function()
            if list.columns[i] and list:Sortable(i) then list:SortBy(i) end
        end)
        area:Hide()
        helps[i] = area
    end
    -- The column chooser, at the right end of the title band, over the scroll bar: the titles end before it.
    if HEAD_H > 0 then
        local chooser = Widgets.ColumnChooser(list, function()
            local entries = {}
            local out = {}
            for _, k in ipairs(rawget(list, "leftOut") or {}) do out[k] = true end
            for i, col in ipairs(list.columns) do
                local key = Widgets.ColumnKey(col)
                entries[i] = { key = key, locked = i == 1 and FIRST_REASON or nil,
                    leftOut = out[tostring(key)] and Widgets.LEFT_OUT_REASON or nil }
            end
            if rawget(list, "actionTitle") then entries[#entries + 1] = { key = opts.actionTitle, locked = ACTION_REASON } end
            return rawget(list, "columnSet"), entries
        end, function()
            local fn = rawget(list, "onColumnsChanged")
            if fn then fn() else list:Refresh() end
        end)
        chooser:SetPoint("TOPRIGHT", list, "TOPRIGHT", -2, -math.floor((HEAD_H - 16) / 2))
        chooser:Hide()
        list.chooser = chooser
    end
    for r = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -HEAD_H - (r - 1) * ROW_H)
        row:SetPoint("RIGHT", list, "RIGHT", -BAR_W, 0)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        if SKIN then
            if r % 2 == 0 then
                local stripe = row:CreateTexture(nil, "BACKGROUND")
                stripe:SetAllPoints()
                stripe:SetColorTexture(1, 1, 1, 0.035)
            end
            row.groupBand = row:CreateTexture(nil, "BACKGROUND", nil, 1)
            row.groupBand:SetAllPoints()
            row.groupBand:SetColorTexture(1, 0.82, 0, 0.07)
            row.groupBand:Hide()
        end
        -- The rules of a total line, over the amount columns: one above, and a double one under the final total.
        row.rules = {}
        for i = 1, 3 do
            local t = row:CreateTexture(nil, "ARTWORK")
            t:SetHeight(1)
            t:SetColorTexture(1, 0.82, 0, 0.6)
            t:Hide()
            row.rules[i] = t
        end
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(ROW_H - 4, ROW_H - 4)
        -- The open / close sign of a row that opens (data.open ~= nil), first on the row, before the icon.
        row.toggle = row:CreateTexture(nil, "ARTWORK")
        row.toggle:SetSize(TOGGLE, TOGGLE)
        row.toggle:Hide()
        row.cells = {}
        for i = 1, MAX_COLS do
            local fs = row:CreateFontString(nil, "OVERLAY", CELL_FONT)
            fs:SetHeight(ROW_H)
            fs:SetWordWrap(false)
            row.cells[i] = fs
        end
        -- Only the first column may be cut ("...", in full on hover; UI.md Tables 2): the others are as wide as
        -- their widest text. (`canCut`: the fit spec allows the cut.)
        row.cells[1].canCut = true
        row:SetScript("OnEnter", function(self)
            local data = self.data
            -- The amounts a cell shows short (gold and silver), in full; a cell's note ("*": few sales).
            local function exact() Widgets.AddExactLines(GameTooltip, list.columns, data) end
            -- A row's own help: what the line is and how it is computed.
            local tip = data and data.tip
            if tip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                local lines = {}
                for i = 2, #tip do lines[#lines + 1] = tip[i] end
                Widgets.AddHelp(GameTooltip, tip[1], lines)
                exact()
                GameTooltip:Show()
                return
            end
            local link = data and (data.link or (data.itemID and ("item:" .. data.itemID)))
            if not link then
                -- A cut first cell shows in full on hover (UI.md Tables 2).
                local first = self.cells[1]
                local cut = data and first:IsShown() and first:IsTruncated()
                if cut or Widgets.HasExactLines(list.columns, data) then
                    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                    GameTooltip:SetText(cut and first:GetText() or Widgets.CellText(data.cells[1]) or "", 1, 1, 1, 1, true)
                    exact()
                    GameTooltip:Show()
                end
                return
            end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(link)
            local hint = ns.RowHint and ns.RowHint(data)
            if hint then GameTooltip:AddLine(hint, 0.5, 0.8, 1) end
            exact()
            GameTooltip:Show()
        end)
        row:SetScript("OnClick", function(self)
            if self.data and self.data.onClick then self.data.onClick(self.data) return end
            if self.data and ns.RowClick then ns.RowClick(self.data) end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        if ACTION_W > 0 then
            row.action = Widgets.Button(row, "", 64, function()
                local a = row.data and row.data.action
                if a and a.onClick then a.onClick() end
            end)
            row.action:SetPoint("RIGHT", row, "RIGHT", -4, 0)
            row.action:Hide()
            row.warn = CreateFrame("Frame", nil, row)
            row.warn:SetSize(18, 18)
            row.warn:SetPoint("RIGHT", row.action, "LEFT", -4, 0)
            local sign = row.warn:CreateTexture(nil, "ARTWORK")
            sign:SetAllPoints()
            sign:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
            row.warn:EnableMouse(true)
            row.warn:SetScript("OnEnter", function(self)
                local w = row.data and row.data.warn
                if not w then return end
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(w.title, 1, 0.3, 0.3)
                Widgets.AddHelp(GameTooltip, nil, w.text)
                GameTooltip:Show()
            end)
            row.warn:SetScript("OnLeave", function() GameTooltip:Hide() end)
            row.warn:Hide()
        end
        row:Hide()
        rows[r] = row
    end

    local bar = Widgets.ScrollBar(list, function(value)
        if value ~= list.offset then
            list.offset = value
            list:Refresh()
        end
    end)
    bar:SetPoint("TOPRIGHT", list, "TOPRIGHT", SKIN and -3 or 0, -HEAD_H - (SKIN and 3 or 0))
    bar:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", SKIN and -3 or 0, SKIN and 3 or 0)
    local function wheel(_, delta)
        list.offset = math.max(0, list.offset - delta * 3)
        list:Refresh()
    end
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", wheel)
    bar:EnableMouseWheel(true)
    bar:SetScript("OnMouseWheel", wheel)

    function list:SetColumns(cols, setId)
        assert(#cols <= MAX_COLS, "Widgets.List: " .. #cols .. " columns, at most " .. MAX_COLS)
        local chooser = rawget(self, "chooser")
        if chooser and setId ~= rawget(self, "columnSet") then chooser.Close() end
        self.columns, self.columnSet = cols, setId
        self.sortDirty = true
    end

    function list:SetSource(count, getRow)
        self.rawCount, self.rawGet = count, getRow
        self.count, self.getRow = count, getRow
        self.sortDirty = true
    end

    -- Sorting (Widgets.SortRows). The order is saved under `list.sortId` (else the column set's id); a list with
    -- neither, without titles, or a statement has none. `list.sortState(create)`: the owner keeps the order itself.
    function list:SortState(create)
        local own = rawget(self, "sortState")
        if own then return own(create) end
        return Widgets.SortState(rawget(self, "sortId") or rawget(self, "columnSet"), create)
    end
    function list:Sortable(i)
        if opts.sort == false or HEAD_H == 0 then return false end
        if not (rawget(self, "sortState") or rawget(self, "sortId") or rawget(self, "columnSet")) then return false end
        return Widgets.ColumnSortable(self.columns, i)
    end
    function list:ApplySort()
        self.sortDirty = nil
        local count, getRow = self.rawCount or 0, self.rawGet
        local st = self:SortState(false)
        local i = st and Widgets.SortColumn(self.columns, st)
        self.sortedBy, self.sortDesc = nil, nil
        if not (i and getRow and self:Sortable(i)) then
            self.count, self.getRow = count, getRow
            return
        end
        self.sortedBy, self.sortDesc = i, st.desc and true or false
        -- (`list.presorted`: the owner's rows come in this order already, by values of its own: the Purchases' groups.)
        if count < 2 or rawget(self, "presorted") then return end
        local all = {}
        for r = 1, count do all[#all + 1] = getRow(r) end
        local sorted = Widgets.SortRows(all, i, st.desc)
        self.count, self.getRow = #sorted, function(r) return sorted[r] end
    end
    function list:SortBy(i)
        local all = {}
        for r = 1, math.min(self.rawCount or 0, 400) do all[#all + 1] = self.rawGet(r) end
        Widgets.SortClick(self:SortState(true), self.columns, i, all)
        self.sortDirty, self.offset = true, 0
        local fn = rawget(self, "onSortChanged") or rawget(self, "onColumnsChanged")
        if fn then fn() else self:Refresh() end
    end

    function list:Refresh()
        local cols = self.columns
        -- A table shown before it has columns (a window drawing its views) has nothing to draw yet.
        if not cols or #cols == 0 then return end
        if self.sortDirty then self:ApplySort() end
        local sortedBy, sortDesc = rawget(self, "sortedBy"), rawget(self, "sortDesc")
        -- The columns hidden with the chooser take no room; the first one always shows.
        local setId, shown = rawget(self, "columnSet"), {}
        for i, col in ipairs(cols) do shown[i] = i == 1 or Widgets.ColumnShown(setId, Widgets.ColumnKey(col)) end
        local chooser = rawget(self, "chooser")
        if chooser then chooser:SetShown(setId ~= nil) end
        local fit = math.max(1, math.min(MAX_ROWS, math.floor(((self:GetHeight() or 0) - HEAD_H) / ROW_H)))
        self.offset = math.max(0, math.min(self.offset, self.count - fit))
        self.atBottom = self.offset >= self.count - fit   -- (a log follows its last line while this is true)
        bar:Update(self.offset, self.count - fit)
        -- Column positions. The first column takes what is left of the width and shrinks with the
        -- window; a column that still does not fit is left out, from the right.
        local avail = (self:GetWidth() or 0) - BAR_W - 8 - ACTION_W
        local spanW = avail - 4   -- (a note's width: the whole row up to the scroll bar)
        -- Every column but the first is as wide as its widest text (title or cell), and no wider; the first
        -- takes the room that is left. Where the client cannot measure text, the widths given are used.
        local titles, samples = {}, {}
        for i, col in ipairs(cols) do titles[i], samples[i] = Widgets.SortTitle(col[1], i, sortedBy, sortDesc), col.sample end
        local need, textNeed
        if opts.fit ~= false then
            need, textNeed = Widgets.FitColumns(titles, self.count, function(r)
                local data = self.getRow(r)
                if not data or data.span then return nil end
                -- (A total's texts are in its larger font, measured in that font.)
                return data.cells, (data.indent or 0) + (data.itemID and ROW_H or 0) + (data.open ~= nil and TOGGLE + 4 or 0),
                    data.bold and BOLD_FONT or CELL_FONT
            end, nil, samples)
        end
        -- A column that holds a control (`least`: the control's width, a true constant) is at least that wide.
        if need then
            for i, col in ipairs(cols) do if col.least then need[i] = math.max(need[i], col.least) end end
        end
        -- (What the self-check places in each column's box: the widest text of the data, on show or not.)
        self.textNeed = textNeed
        -- The space before each column: its text NORMAL_GAP from the one before, whatever their justification.
        local gapBefore, prev = {}, 1
        for i = 2, #cols do
            if shown[i] then
                -- (A centred title over cells of another justification: its pads are the title's.)
                gapBefore[i] = Widgets.ColumnGap(cols[prev].titleJustify or cols[prev][3] or "LEFT",
                    cols[i].titleJustify or cols[i][3] or "LEFT")
                prev = i
            end
        end
        local fixed = 0
        for i = 2, #cols do if shown[i] then fixed = fixed + (need and need[i] or cols[i][2]) + gapBefore[i] end end
        local allFixed = fixed
        -- Where text is measured: the first column keeps room for its text (up to MIN_FIRST); a column that would
        -- leave it less is left out, from the right, and the first column takes its room too.
        local fits = {}
        for i = 1, #cols do fits[i] = shown[i] end
        -- A column left out shows unticked in the column chooser, the reason on hover (UI.md Tables 2): no note.
        local leftOut = {}
        if need then
            local least = math.min(need[1], MIN_FIRST)
            for i = #cols, 2, -1 do
                if avail - fixed >= least then break end
                if fits[i] then
                    fits[i], fixed = false, fixed - need[i] - gapBefore[i]
                    table.insert(leftOut, 1, tostring(Widgets.ColumnKey(cols[i])))
                end
            end
        end
        self.leftOut = leftOut
        local first = math.max(MIN_FIRST, avail - fixed)
        -- The first column (the row's label) takes all the free width, so the other columns end at the right edge
        -- (UI.md Tables 2): in a statement and in every other table alike.
        if need then first = math.max(math.min(40, need[1]), avail - fixed) end
        local xs, ws, x = {}, {}, 4
        for i, col in ipairs(cols) do
            if i > 1 and ((need and fits[i]) or (not need and shown[i])) then x = x + gapBefore[i] end
            xs[i], ws[i] = x, (i == 1 and first or (need and need[i] or col[2]))
            if not need then fits[i] = shown[i] and (i == 1 or (x + ws[i] <= avail + 4)) end
            if (need and fits[i]) or (not need and shown[i]) then x = x + ws[i] end
        end
        -- Where no other column fits (or none shows), the first one takes the width.
        local second
        for i = 2, #cols do if shown[i] then second = i break end end
        if not (second and fits[second]) then ws[1] = math.max(10, avail - 4) end
        -- The buttons' column is a column like the others: right after the last one, as wide as its warning
        -- sign and its button. (Where text cannot be measured, it stays at the right edge.)
        local actionX = need and ACTION_W > 0 and math.min(x, avail + 4) or nil
        -- Where the amounts are: from the second column shown to the right end of the last one (the rules).
        local ruleL, ruleR
        for i = 2, #cols do
            if fits[i] then
                ruleL = ruleL or xs[i]
                ruleR = xs[i] + ws[i]
            end
        end
        self.amountsRight = ruleR
        -- The width the columns need, the buttons' column and the scroll bar included (a window that fits
        -- its list reads it), with the first column at its full width even where this one cut it. nil where
        -- text cannot be measured.
        local full = need and (4 + need[1] + allFixed) or nil
        -- An empty table's note (a row with `span`) is shown in full (UI.md Tables 6): it is content too.
        local noteNeed = 0
        if need then
            for r = 1, math.min(self.count, 400) do
                local data = self.getRow(r)
                if data and data.span then
                    noteNeed = math.max(noteNeed, math.ceil(Widgets.TextWidth(data.cells[1]) or 0) + BAR_W + 12)
                end
            end
        end
        self.neededWidth = need and math.max(full + ACTION_W + BAR_W + 4, noteNeed) or nil
        self.columnsWidth = need and (full + ACTION_W + BAR_W + 4) or nil   -- (the same without the note: the self-check)
        self.noteWidth = need and noteNeed or nil   -- (a window keeps it at its smallest width too)
        -- What the first column was given over its text (a window forced wider by its controls): the self-check
        -- allows that much more after it (Widgets.CheckLayout).
        self.spare = need and fits[1] and math.max(0, ws[1] - need[1]) or 0
        -- The narrowest width that leaves no column out: the first one with room for its text up to MIN_FIRST
        -- (a window that fits its tables reads it, Widgets.FitTables).
        self.fitWidth = need and math.max(noteNeed, math.ceil(4 + math.min(need[1], MIN_FIRST) + allFixed + BAR_W + 4
            + ACTION_W)) or nil
        if actionX and rawget(list, "actionTitle") then
            list.actionTitle:ClearAllPoints()
            list.actionTitle:SetPoint("TOPLEFT", self, "TOPLEFT", actionX + 22, 0)
        end
        for i = 1, MAX_COLS do
            local h, col = headers[i], cols[i]
            local on = col and fits[i] and HEAD_H > 0
            if on then
                h:ClearAllPoints()
                h:SetPoint("TOPLEFT", self, "TOPLEFT", xs[i], 0)
                -- (`titleJustify`: a title centred over cells of another justification, the Limits' pairs.)
                h:SetWidth(ws[i]) h:SetJustifyH(col.titleJustify or col[3] or "LEFT") h:SetText(titles[i]) h:Show()
            else
                h:Hide()
            end
            helpText[i] = on and col.help or nil
            helps[i]:SetShown(on and (helpText[i] ~= nil or self:Sortable(i)) or false)
        end
        for r = 1, MAX_ROWS do
            local row = rows[r]
            local data = r <= fit and (r + self.offset) <= self.count and self.getRow(r + self.offset) or nil
            row.data = data
            if SKIN then row.groupBand:SetShown(data ~= nil and data.group == true) end
            if ACTION_W > 0 then
                local a = data and data.action
                row.action:SetShown(a ~= nil)
                if a then
                    row.action:SetText(a.text)
                    row.action:SetEnabled(a.enabled and true or false)
                end
                row.warn:SetShown(data ~= nil and data.warn ~= nil)
                if actionX then
                    row.warn:ClearAllPoints()
                    row.warn:SetPoint("LEFT", row, "LEFT", actionX, 0)
                    row.action:ClearAllPoints()
                    row.action:SetPoint("LEFT", row, "LEFT", actionX + 22, 0)
                end
            end
            local rule = data and ruleL and data.rule
            for i, t in ipairs(row.rules) do
                local on = rule == "final" or (rule == "total" and i == 1)
                if on then
                    t:ClearAllPoints()
                    t:SetPoint("TOPLEFT", row, i == 1 and "TOPLEFT" or "BOTTOMLEFT", ruleL, i == 1 and -1 or (i == 2 and 4 or 2))
                    t:SetWidth(ruleR - ruleL)
                end
                t:SetShown(on and true or false)
            end
            if not data then
                row:Hide()
            else
                local indent = data.indent or 0
                if data.open ~= nil then
                    Widgets.GroupArrow(row.toggle, data.open)
                    row.toggle:ClearAllPoints()
                    row.toggle:SetPoint("LEFT", row, "LEFT", 4 + indent, 0)
                    row.toggle:Show()
                    indent = indent + TOGGLE + 4
                else
                    row.toggle:Hide()
                end
                local icon = data.itemID and Widgets.IconOf(data.itemID)
                local textIndent = indent + (icon and ROW_H or 0)
                if icon then
                    row.icon:ClearAllPoints()
                    row.icon:SetPoint("LEFT", row, "LEFT", 4 + indent, 0)
                    row.icon:SetTexture(icon)
                    row.icon:Show()
                else
                    row.icon:Hide()
                end
                for i = 1, MAX_COLS do
                    local fs, col = row.cells[i], cols[i]
                    if col and fits[i] and not (data.span and i > 1) then
                        local extra = i == 1 and textIndent or 0
                        fs:ClearAllPoints()
                        fs:SetPoint("LEFT", row, "LEFT", xs[i] + extra, 0)
                        fs:SetWidth(math.max(10, (data.span and spanW or ws[i]) - extra))
                        -- (A first cell may end with "...", its text on hover; a note must fit: the fit spec checks.)
                        if i == 1 then fs.canCut = not data.span end
                        fs:SetJustifyH(col[3] or "LEFT")
                        fs.measureFont = data.bold and BOLD_FONT or CELL_FONT
                        fs:SetFontObject(fs.measureFont)
                        fs:SetText(Widgets.CellText(data.cells[i]))
                        fs:Show()
                    else
                        fs:Hide()
                    end
                end
                row:Show()
            end
        end
    end

    --- Draws again only the live cells of the rows on screen (row.live = { [column] = function() -> text, seconds
    --- left }: a countdown), in the widths they have (a live column keeps its `sample`'s width). Returns true when one
    --- reached its end: the caller draws the table again.
    function list.RefreshLive()
        local ended = false
        for _, row in ipairs(rows) do
            local data = row:IsShown() and row.data
            if data and data.live then
                for i, fn in pairs(data.live) do
                    local fs = row.cells[i]
                    if fs and fs:IsShown() then
                        local text, left = fn()
                        if left and left <= 0 then ended = true end
                        fs:SetText(Widgets.CellText(text))
                    end
                end
            end
        end
        return ended
    end

    list:SetScript("OnSizeChanged", function() list:Refresh() end)
    return list
end

--- A scrolling stack of small tables ("cards"), each in its own sunken panel with a title band.
--- The caller anchors the returned frame.
---   stack:SetColumns({ { title, width, justify, help = { title, text }, key = title, sep = true }, ... }, setId)
---                                                         the first column takes the spare width; setId as in
---                                                         Widgets.List (the chooser sits at the top right, over the
---                                                         scroll bar); `sep`: a vertical line before the column
---                                                         (two groups of columns, the Odds' table and yours)
---   stack:SetCards({ { title = text, facts = text or { { text, help = { title, text } }, ... },
---                      factsHelp = { title, text }, more = { title, line, ... } or function() -> that,
---                      pair = true, rows = { { cells, itemID } } }, ... })
---                                                         facts as parts: each with its own help on hover; `more`:
---                                                         a "?" at the card's top right shows the lines on hover;
---                                                         `pair`: cards next to each other share a row, two per row
---                                                         where both fit (else one), the same width each
---   stack:Refresh()
--- stack.fitWidth: the width two cards per row need (one where there are no pairs); stack.leastWidth: one per row;
--- stack.perRow: the cards per row now. stack.widthOf = function() -> the stack's width, from its window's (a constant
--- margin): read instead of the stack's own width, which lags its window's for a frame while the window is sized.
function Widgets.CardList(parent)
    -- (The title band has two lines: the title, and under it the card's facts.)
    local TITLE_H, HEAD_H, ROW_H, GAP, BAR_W, STEP, MAX_COLS = 40, 18, 22, 8, 18, 22, 10
    local HEADING_H, TOGGLE, SEP, MORE = 26, 18, 12, 18   -- a heading card; the open / close sign; a separator; "?"
    -- The group headings over the column titles (`col.group` on a group's first column: "Game rates"), one line.
    local GROUP_H = 16
    -- A card may be a heading (data.heading: its title only), may open and close (data.open ~= nil: the sign
    -- before its title, a click on its title band calls data.onClick), and may sit in (data.indent).
    local stack = CreateFrame("Frame", nil, parent)
    stack.offset, stack.cards, stack.data, stack.columns, stack.perRow = 0, {}, {}, {}, 1
    local scroll = CreateFrame("ScrollFrame", nil, stack)
    scroll:SetPoint("TOPLEFT", stack, "TOPLEFT", 0, 0)
    scroll:SetPoint("BOTTOMRIGHT", stack, "BOTTOMRIGHT", -BAR_W, 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(10, 10)
    scroll:SetScrollChild(content)
    local bar = Widgets.ScrollBar(stack, function(value)
        if value ~= stack.offset then
            stack.offset = value
            stack:Refresh()
        end
    end)
    -- The column chooser, in the corner over the scroll bar (one for every card: they share their columns).
    local chooser = Widgets.ColumnChooser(stack, function()
        local entries = {}
        for i, col in ipairs(stack.columns) do
            entries[i] = { key = Widgets.ColumnKey(col), locked = i == 1 and FIRST_REASON or nil }
        end
        return rawget(stack, "columnSet"), entries
    end, function()
        local fn = rawget(stack, "onColumnsChanged")
        if fn then fn() else stack:Refresh() end
    end)
    chooser:SetPoint("TOPRIGHT", stack, "TOPRIGHT", -1, -2)
    chooser:Hide()
    stack.chooser = chooser
    bar:SetPoint("TOPRIGHT", stack, "TOPRIGHT", 0, -20)
    bar:SetPoint("BOTTOMRIGHT", stack, "BOTTOMRIGHT", 0, 0)
    local function wheel(_, delta)
        stack.offset = math.max(0, stack.offset - delta * 3)
        stack:Refresh()
    end
    stack:EnableMouseWheel(true)
    stack:SetScript("OnMouseWheel", wheel)
    bar:EnableMouseWheel(true)
    bar:SetScript("OnMouseWheel", wheel)

    -- Where each column sits: packed from the left, each as wide as stack.widths says (see Refresh); a column
    -- hidden with the chooser takes no room; a column with `sep` starts SEP px later, after its line.
    -- The first column (the row's label) takes the card's spare width (`extra`), so the other columns end at the
    -- card's right edge and line up over cards of any indent.
    -- The space after column c: the next shown column's text NORMAL_GAP from its own (Widgets.ColumnGap); 0 at the end.
    local function gapAfter(c)
        local cols, shown = stack.columns, stack.colShown
        for n = c + 1, #cols do
            if shown[n] then return Widgets.ColumnGap(cols[c][3] or "LEFT", cols[n][3] or "LEFT") end
        end
        return 0
    end
    local function columnX(i, extra)
        local cols, ws, shown = stack.columns, stack.widths, stack.colShown
        local x = 30
        for c = 1, i - 1 do
            if shown[c] then x = x + ws[c] + (c == 1 and extra or 0) + gapAfter(c) + (cols[c].sep and SEP or 0) end
        end
        -- (Every line before it moves it on, its own too: the columns after a line overlapped it by 4 px, 0.3.151.)
        if cols[i] and cols[i].sep then x = x + SEP end
        return x
    end
    local function place(region, card, i, forTitle, extra)
        local cols, ws = stack.columns, stack.widths
        extra = extra or 0
        region:ClearAllPoints()
        if i == 1 and forTitle then
            region:SetPoint("LEFT", card, "LEFT", 8, 0)
            region:SetWidth(ws[1] + extra + 22)
        else
            region:SetPoint("LEFT", card, "LEFT", columnX(i, extra), 0)
            region:SetWidth(ws[i] + (i == 1 and extra or 0))
        end
        region:SetJustifyH(cols[i][3] or "LEFT")
    end

    local function tip(self, help)
        if not help then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        local lines = {}
        for n = 2, #help do lines[#lines + 1] = helpLine(help[n]) end
        Widgets.AddHelp(GameTooltip, help[1], lines)
        GameTooltip:Show()
    end

    local function newCard()
        local card = Widgets.Panel(content, 0, 0, 0, 0.5)
        local band = card:CreateTexture(nil, "BACKGROUND", nil, 1)
        band:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -1)
        band:SetPoint("TOPRIGHT", card, "TOPRIGHT", -1, -1)
        band:SetHeight(TITLE_H)
        band:SetColorTexture(1, 0.82, 0, 0.09)
        card.band = band
        card.toggle = card:CreateTexture(nil, "OVERLAY")
        card.toggle:SetSize(TOGGLE, TOGGLE)
        card.toggle:Hide()
        card.click = CreateFrame("Button", nil, card)
        card.click:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
        card.click:SetPoint("TOPRIGHT", card, "TOPRIGHT", -200, 0)   -- (the facts' help stays reachable on the right)
        local clickHl = card.click:CreateTexture(nil, "HIGHLIGHT")   -- (a heading that opens and closes lights up)
        clickHl:SetAllPoints()
        clickHl:SetColorTexture(1, 1, 1, 0.08)
        card.click:SetScript("OnClick", function()
            if card.data and card.data.onClick then card.data.onClick(card.data) end
        end)
        -- A heading's help (data.help), on its whole band.
        card.click:SetScript("OnEnter", function(self) tip(self, card.data and card.data.help) end)
        card.click:SetScript("OnLeave", function() GameTooltip:Hide() end)
        card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        card.title:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -5)
        -- A heading's summary (data.summary: what the cards under it add up to), after its title.
        card.summary = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.summary:SetWordWrap(false)
        card.facts = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.facts:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -23)
        card.facts:SetJustifyH("LEFT")
        card.factsHelp = CreateFrame("Frame", nil, card)
        card.factsHelp:SetAllPoints(card.facts)
        card.factsHelp:EnableMouse(true)
        card.factsHelp:SetScript("OnEnter", function(self) tip(self, card.data and card.data.factsHelp) end)
        card.factsHelp:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- The facts as parts, each with its own help (made as needed).
        card.parts, card.partHelps = {}, {}
        -- The "?" at the top right: the card's other facts on hover.
        card.more = Widgets.Button(card, "?", MORE)
        card.more:SetHeight(MORE)
        card.more:SetPoint("TOPRIGHT", card, "TOPRIGHT", -5, -4)
        card.more:SetScript("OnEnter", function(self)
            local more = card.data and card.data.more
            if type(more) == "function" then more = more() end
            tip(self, more)
        end)
        card.more:SetScript("OnLeave", function() GameTooltip:Hide() end)
        card.more:Hide()
        -- The column titles, in a strip under the title band.
        card.heads = CreateFrame("Frame", nil, card)
        card.heads:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -TITLE_H - 1)
        card.heads:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, -TITLE_H - 1)
        card.heads:SetHeight(HEAD_H)
        card.headTexts, card.headHelps, card.seps, card.groupTexts = {}, {}, {}, {}
        for i = 1, MAX_COLS do
            local h = card.heads:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            h:SetHeight(HEAD_H)
            card.headTexts[i] = h
            local area = CreateFrame("Frame", nil, card.heads)
            area:SetAllPoints(h)
            area:EnableMouse(true)
            area:SetScript("OnEnter", function(self)
                local col = stack.columns[i]
                local help = col and col.help
                if col and stack:Sortable(i) then
                    help = { help and help[1] or tostring(Widgets.ColumnKey(col)) }
                    for n = 2, #(col.help or {}) do help[#help + 1] = col.help[n] end
                    help[#help + 1] = Widgets.SORT_HINT
                end
                tip(self, help)
            end)
            area:SetScript("OnLeave", function() GameTooltip:Hide() end)
            area:SetScript("OnMouseUp", function()
                if stack.columns[i] and stack:Sortable(i) then stack:SortBy(i) end
            end)
            card.headHelps[i] = area
        end
        card.rows = {}
        return card
    end

    -- A separator before column i: a thin line from the column titles to the card's bottom.
    local function separator(card, n, x)
        local t = card.seps[n]
        if not t then
            t = card:CreateTexture(nil, "ARTWORK")
            t:SetWidth(1)
            t:SetColorTexture(1, 0.82, 0, 0.45)
            card.seps[n] = t
        end
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", card, "TOPLEFT", x, -(TITLE_H + 3))
        t:SetPoint("BOTTOMLEFT", card, "BOTTOMLEFT", x, 3)
        t:Show()
    end

    -- The facts of a card as parts, left to right, each with its help area; each as wide as its text in its font.
    local function factWidth(text)
        return math.ceil(Widgets.TextWidth(text, CELL_FONT) or Widgets.EstimateWidth(text)) + 2
    end
    -- What a card's title band needs: its facts in a row, 16 px apart, after the title's indent, and the "?".
    local function titleWidth(text)
        return math.ceil(Widgets.TextWidth(text or "", "GameFontNormal") or Widgets.EstimateWidth(text or "")) + 2
    end
    local function factsNeed(data)
        local parts = type(data.facts) == "table" and data.facts or {}
        local tx = data.open ~= nil and (6 + TOGGLE + 4) or 8   -- (as drawCard places them)
        if data.summary then return tx + titleWidth(data.title) + 12 + factWidth(data.summary) + 8 end
        if #parts == 0 then return 0 end
        local w = tx
        for n, part in ipairs(parts) do w = w + factWidth(part[1]) + (n > 1 and 16 or 0) end
        return w + (data.more and (MORE + 5 + 8) or 8)
    end
    local function factParts(card, parts, x)
        for n, part in ipairs(parts) do
            local fs = card.parts[n]
            if not fs then
                fs = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                fs:SetJustifyH("LEFT")
                fs:SetWordWrap(false)
                card.parts[n] = fs
                local area = CreateFrame("Frame", nil, card)
                area:SetAllPoints(fs)
                area:EnableMouse(true)
                area.uiKind = "help"
                area:SetScript("OnEnter", function(self) tip(self, rawget(self, "help")) end)
                area:SetScript("OnLeave", function() GameTooltip:Hide() end)
                card.partHelps[n] = area
            end
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", card, "TOPLEFT", x, -23)
            fs:SetText(part[1])
            local w = factWidth(part[1])
            fs:SetWidth(w)
            fs:Show()
            card.partHelps[n].help = part.help
            card.partHelps[n]:SetShown(part.help ~= nil)
            x = x + w + 16
        end
        for n = #parts + 1, #card.parts do card.parts[n]:Hide() card.partHelps[n]:Hide() end
    end

    local function newRow(card, r)
        local row = CreateFrame("Button", nil, card)
        row:SetHeight(ROW_H)
        row.index = r   -- (placed under the titles by drawCard: the titles' height depends on the group headings)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        if r % 2 == 0 then
            local stripe = row:CreateTexture(nil, "BACKGROUND")
            stripe:SetAllPoints()
            stripe:SetColorTexture(1, 1, 1, 0.035)
        end
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(ROW_H - 4, ROW_H - 4)
        row.icon:SetPoint("LEFT", row, "LEFT", 6, 0)
        row.cells = {}
        for i = 1, MAX_COLS do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetHeight(ROW_H)
            fs:SetWordWrap(false)
            row.cells[i] = fs
        end
        row:SetScript("OnEnter", function(self)
            local id = self.data and self.data.itemID
            if not id then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink("item:" .. id)
            -- The row's own lines (the Odds: how many of your disenchants gave it).
            for _, line in ipairs(self.data.lines or {}) do Widgets.AddHelp(GameTooltip, nil, line) end
            local hint = ns.RowHint and ns.RowHint(self.data)
            if hint then GameTooltip:AddLine(hint, 0.5, 0.8, 1) end
            GameTooltip:Show()
        end)
        row:SetScript("OnClick", function(self)
            if self.data and self.data.onClick then self.data.onClick(self.data) return end
            if self.data and ns.RowClick then ns.RowClick(self.data) end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        return row
    end

    function stack:SetColumns(cols, setId)
        assert(#cols <= MAX_COLS, "Widgets.CardList: " .. #cols .. " columns, at most " .. MAX_COLS)
        if setId ~= rawget(self, "columnSet") then chooser.Close() end
        self.columns, self.columnSet = cols, setId
    end
    function stack:SetCards(cards) self.data = cards end
    -- Sorting (Widgets.SortRows): the rows inside each card, by one order for every card of the stack, saved under
    -- `stack.sortId` (else the column set's id).
    function stack:SortState(create) return Widgets.SortState(rawget(self, "sortId") or rawget(self, "columnSet"), create) end
    function stack:Sortable(i)
        return (rawget(self, "sortId") or rawget(self, "columnSet")) ~= nil and Widgets.ColumnSortable(self.columns, i)
    end
    function stack:SortBy(i)
        local all = {}
        for _, data in ipairs(self.data) do for _, r in ipairs(data.rows or {}) do all[#all + 1] = r end end
        Widgets.SortClick(self:SortState(true), self.columns, i, all)
        local fn = rawget(self, "onSortChanged") or rawget(self, "onColumnsChanged")
        if fn then fn() else self:Refresh() end
    end

    -- The group headings (col.group on a group's first column): each group from its first column to the column
    -- before the next group (or the last), only the columns on show.
    local function groupsOf()
        local cols, shown, out = stack.columns, stack.colShown, {}
        for i = 1, #cols do
            if cols[i].group then out[#out + 1] = { text = cols[i].group, cols = {} } end
            local g = out[#out]
            if g and shown[i] then table.insert(g.cols, i) end
        end
        local kept = {}
        for _, g in ipairs(out) do if #g.cols > 0 then kept[#kept + 1] = g end end
        return kept
    end

    -- Draws one card at (x, -y) in the content, `width` wide; returns its height.
    local function drawCard(card, data, x, y, width, used, measured, rows)
        card.data = data
        local cols = stack.columns
        local titleH = data.heading and HEADING_H or TITLE_H
        local groups = stack.groups or {}
        local headH = HEAD_H + (#groups > 0 and GROUP_H or 0)
        local height = titleH + 2 + (#rows > 0 and (headH + #rows * ROW_H + 2) or 0)
        card:ClearAllPoints()
        card:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
        card:SetSize(width, height)
        card.band:SetHeight(titleH)
        card.click:SetHeight(titleH)
        -- A heading card has no facts: the whole title band is the click target.
        card.click:ClearAllPoints()
        card.click:SetPoint("TOPLEFT", card, "TOPLEFT", 0, 0)
        card.click:SetPoint("TOPRIGHT", card, "TOPRIGHT", data.heading and 0 or -200, 0)
        card.click:SetShown(data.onClick ~= nil)
        local tx = 8
        if data.open ~= nil then
            Widgets.GroupArrow(card.toggle, data.open)
            card.toggle:ClearAllPoints()
            card.toggle:SetPoint("TOPLEFT", card, "TOPLEFT", 6, -(data.heading and 4 or 3))
            card.toggle:Show()
            tx = 6 + TOGGLE + 4
        else
            card.toggle:Hide()
        end
        card.title:ClearAllPoints()
        card.title:SetPoint("TOPLEFT", card, "TOPLEFT", tx, data.heading and -6 or -5)
        card.title:SetText(data.title or "")
        if data.summary then
            card.summary:ClearAllPoints()
            card.summary:SetPoint("LEFT", card.title, "LEFT", titleWidth(data.title) + 12, 0)
            card.summary:SetWidth(factWidth(data.summary))
            card.summary:SetText(data.summary)
            card.summary:Show()
        else
            card.summary:Hide()
        end
        local parts = type(data.facts) == "table" and data.facts or {}
        card.facts:ClearAllPoints()
        card.facts:SetPoint("TOPLEFT", card, "TOPLEFT", tx, -23)
        card.facts:SetText(type(data.facts) == "string" and data.facts or "")
        card.facts:SetShown(type(data.facts) == "string")
        card.factsHelp:SetShown(type(data.facts) == "string" and data.factsHelp ~= nil)
        factParts(card, parts, tx)
        card.more:SetShown(data.more ~= nil)
        -- The room the columns leave in this card: the first column takes it.
        local extra = measured and math.max(0, math.floor(width - used)) or 0
        card.heads:SetShown(#rows > 0)
        card.heads:ClearAllPoints()
        card.heads:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -titleH - 1)
        card.heads:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, -titleH - 1)
        card.heads:SetHeight(headH)
        local nSep = 0
        for i = 1, MAX_COLS do
            local h, col = card.headTexts[i], cols[i]
            if col and stack.colShown[i] and #rows > 0 then
                place(h, card.heads, i, i == 1, extra)
                -- (Under the group headings, on the strip's lower line.)
                local _, _, _, px = h:GetPoint(1)
                h:ClearAllPoints()
                h:SetPoint("BOTTOMLEFT", card.heads, "BOTTOMLEFT", px or 0, 0)
                h:SetText(stack.titles[i])
                h:Show()
                if col.sep then
                    nSep = nSep + 1
                    separator(card, nSep, columnX(i, extra) - SEP / 2 - 4)
                end
            else
                h:Hide()
            end
            card.headHelps[i]:SetShown(col ~= nil and stack.colShown[i] and #rows > 0
                and (col.help ~= nil or stack:Sortable(i)))
        end
        for n = nSep + 1, #card.seps do card.seps[n]:Hide() end
        -- The group headings: each centred over its columns, as wide as they are (they were made wide enough for it).
        for n, g in ipairs(groups) do
            local fs = card.groupTexts[n]
            if not fs then
                fs = card.heads:CreateFontString(nil, "OVERLAY", TITLE_FONT)
                fs:SetHeight(GROUP_H)
                fs:SetJustifyH("CENTER")
                fs:SetWordWrap(false)
                fs.measureFont = TITLE_FONT
                card.groupTexts[n] = fs
            end
            local first, last = g.cols[1], g.cols[#g.cols]
            local l, r = columnX(first, extra), columnX(last, extra) + stack.widths[last]
            fs:ClearAllPoints()
            fs:SetPoint("TOPLEFT", card.heads, "TOPLEFT", l, 0)
            fs:SetWidth(math.max(1, r - l))
            fs:SetText(g.text)
            fs:SetShown(#rows > 0)
        end
        for n = #groups + 1, #card.groupTexts do card.groupTexts[n]:Hide() end
        for r = 1, math.max(#rows, #card.rows) do
            local row, rowData = card.rows[r], rows[r]
            if rowData and not row then
                row = newRow(card, r)
                card.rows[r] = row
            end
            if row then
                row.data = rowData
                row:SetShown(rowData ~= nil)
                if rowData then
                    local top = -titleH - headH - 1 - (r - 1) * ROW_H
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", card, "TOPLEFT", 1, top)
                    row:SetPoint("TOPRIGHT", card, "TOPRIGHT", -1, top)
                    local icon = rowData.itemID and Widgets.IconOf(rowData.itemID)
                    if icon then row.icon:SetTexture(icon) row.icon:Show() else row.icon:Hide() end
                    for i = 1, MAX_COLS do
                        local fs = row.cells[i]
                        if cols[i] and stack.colShown[i] then
                            place(fs, row, i, nil, extra)
                            fs:SetText(rowData.cells[i] or "")
                            fs.measureFont = CELL_FONT
                            fs:Show()
                        else
                            fs:Hide()
                        end
                    end
                end
            end
        end
        card:Show()
        return height
    end

    function stack:Refresh()
        local cols = self.columns
        if not cols or #cols == 0 then return end
        -- The order of the rows in each card (a click on a title), the arrow on its title.
        local st = self:SortState(false)
        local sortedBy = st and Widgets.SortColumn(cols, st)
        if sortedBy and not self:Sortable(sortedBy) then sortedBy = nil end
        self.sortedBy = sortedBy
        -- Every column is as wide as its widest text over all cards, and no wider, so the cards line up.
        -- Where the client cannot measure text, the widths given are used.
        local titles, samples, all = {}, {}, {}
        for i, col in ipairs(cols) do
            titles[i], samples[i] = Widgets.SortTitle(col[1], i, sortedBy, st and st.desc), col.sample
        end
        self.titles = titles
        local rowsOf = {}
        for n, data in ipairs(self.data) do
            local rows = data.rows or {}
            if sortedBy and #rows > 1 then rows = Widgets.SortRows(rows, sortedBy, st.desc) end
            rowsOf[n] = rows
            for _, row in ipairs(rows) do all[#all + 1] = row.cells end
        end
        local need = Widgets.FitColumns(titles, #all, function(r) return all[r] end, nil, samples)
        self.widths, self.colShown = {}, {}
        local setId = rawget(self, "columnSet")
        for i, col in ipairs(cols) do
            self.widths[i] = need and need[i] or col[2]
            self.colShown[i] = i == 1 or Widgets.ColumnShown(setId, Widgets.ColumnKey(col))
        end
        -- A group heading is never wider than its group can hold: a group too narrow for its heading widens, the room
        -- shared by its columns (`groupWide`: their gaps may be wider than 16 px, the self-check allows it).
        self.groups, self.groupWide = groupsOf(), {}
        if need then
            for _, g in ipairs(self.groups) do
                local w = Widgets.TextWidth(g.text, TITLE_FONT)
                local span = 0
                for k, i in ipairs(g.cols) do
                    span = span + self.widths[i] + (k < #g.cols and gapAfter(i) or 0)
                end
                local short = w and math.ceil(w + Widgets.CELL_PAD - span) or 0
                if short > 0 then
                    local each = math.ceil(short / #g.cols)
                    for _, i in ipairs(g.cols) do
                        self.widths[i] = self.widths[i] + each
                        self.groupWide[i] = true
                    end
                end
            end
        end
        chooser:SetShown(setId ~= nil)
        local widthOf = rawget(self, "widthOf")
        local room = widthOf and (tonumber((widthOf())) or 0) - BAR_W or tonumber((scroll:GetWidth())) or 0
        content:SetWidth(math.max(10, room))
        -- What one card's columns take (the icon, the gaps, the separators), and the widest indent.
        -- (The icon's 30 px, the columns their gaps apart, 8 px after the last one.)
        local used, indent, pairs_ = 30 + 8, 0, false
        for i = 1, #cols do
            if self.colShown[i] then used = used + self.widths[i] + gapAfter(i) + (cols[i].sep and SEP or 0) end
        end
        -- A card is at least as wide as its facts in a row (they are never cut): the first column takes the rest.
        local least = used
        for _, data in ipairs(self.data) do
            indent = math.max(indent, data.indent or 0)
            if data.pair then pairs_ = true end
            if need then least = math.max(least, factsNeed(data)) end
        end
        -- Two cards per row where both fit next to each other (UI.md Tables 17), else one. (1 px of slack: a window at
        -- the width two need may be a fraction short of it at the game's UI scale, and then showed one per row.)
        local perRow = (pairs_ and room - indent >= 2 * least + GAP - 1) and 2 or 1
        self.perRow = perRow
        local y, n, rowH, col = 0, 0, 0, 0
        for k, data in ipairs(self.data) do
            n = n + 1
            local card = self.cards[n]
            if not card then
                card = newCard()
                self.cards[n] = card
            end
            local x = data.indent or 0
            local width = room - x
            if data.pair and perRow == 2 then
                width = math.floor((room - x - GAP) / 2)
                if col == 1 then x = x + width + GAP end
            elseif col > 0 then
                -- (A card that is not a pair after a half row: the row ends.)
                y, rowH, col = y + rowH + GAP, 0, 0
            end
            local h = drawCard(card, data, x, y, width, used, need ~= nil, rowsOf[k])
            if data.pair and perRow == 2 and col == 0 then
                col, rowH = 1, h
            else
                rowH = math.max(rowH, h)
                y, rowH, col = y + rowH + GAP, 0, 0
            end
        end
        if col > 0 then y = y + rowH + GAP end
        for k = n + 1, #self.cards do self.cards[k]:Hide() end
        -- The width the cards need (a window that fits its tables reads it): two per row where there are pairs, one.
        if need then
            self.leastWidth = math.ceil(least + indent + BAR_W)
            self.fitWidth = math.ceil((pairs_ and (2 * least + GAP) or least) + indent + BAR_W)
        end
        content:SetHeight(math.max(10, y))
        self.contentHeight = math.max(0, y - GAP)   -- what the cards need, for a window that fits them
        -- Scrolling goes in steps of one row.
        local max = math.max(0, math.ceil((y - GAP - (scroll:GetHeight() or 0)) / STEP))
        self.offset = math.max(0, math.min(self.offset, max))
        scroll:SetVerticalScroll(self.offset * STEP)
        bar:Update(self.offset, max)
    end

    stack:SetScript("OnSizeChanged", function() stack:Refresh() end)
    return stack
end

-- Salvager: the tables. Widgets.List is one scrolling table; Widgets.CardList is a scrolling stack
-- of small tables, one per card. Both have the same look: a sunken panel, a title band, striped rows.
local _, ns = ...

local Widgets = ns.Widgets

-- Why a column of the chooser cannot be hidden (its row is ticked and greyed).
local FIRST_REASON = "The first column names the row: it always shows."
local ACTION_REASON = "This column holds the rows' buttons: it always shows."
Widgets.FIRST_COLUMN_REASON, Widgets.ACTION_COLUMN_REASON = FIRST_REASON, ACTION_REASON

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
    Widgets.Tooltip(b, "Columns", "Choose the columns this table shows.")
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
            GameTooltip:AddLine(why, 1, 0.82, 0, true)
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
        GameTooltip:AddLine(self:IsEnabled() and "Shows every column of this table again."
            or "Every column shows already.", 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    showAll:HookScript("OnLeave", function() GameTooltip:Hide() end)

    --- Fills the menu from the table's columns now.
    function b.Update()
        local id, cols = getColumns()
        local widest, any = Widgets.TextWidth("Show all") or 60, false
        for i, col in ipairs(cols) do
            local c = checks[i] or newCheck(i)
            c.key, c.reason = col.key, col.locked
            c.label:SetText(col.key)
            local on = col.locked ~= nil or Widgets.ColumnShown(id, col.key)
            if not on then any = true end
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

--- A scrolling table. The caller anchors the returned frame.
---   list:SetColumns({ { title, width, justify, help = { title, text }, sample = text, key = title }, ... }, setId)
---                                                         the first column takes the spare width; help shows
---                                                         on the column title; sample = the widest text the
---                                                         column can hold ("00:00:00"), so it keeps its width;
---                                                         key = the title without a sort arrow. setId names the
---                                                         column set: the columns hidden with the chooser (the
---                                                         button at the right end of the titles) are saved under
---                                                         it; a list without one has no chooser.
---   cols.statement = true                                 a statement (label and amounts): the first column takes
---                                                         all the free width, so the amounts end at the table's
---                                                         right edge (UI.md Tables 8)
---   list.onColumnsChanged = fn                            runs after a change in the chooser (else list:Refresh)
---   list:SetSource(count, getRow)                         getRow(i) -> row, only called for rows on screen
---   list:Refresh()
--- row = { cells = { text, ... }, itemID = icon and tooltip, link = tooltip, indent = pixels,
---         tip = { title, line, ... } (hover help of the row, instead of an item tooltip),
---         rule = "total" (a line over the amounts: a subtotal) or "final" (that line and a double one under),
---         bold = true (a total: its texts in the larger font, BOLD_FONT) }
--- row.group = true marks the first row of a group (an item with its materials under it): it gets a band.
--- opts = { rowHeight = 22, header = true, plain = false }
--- Unless `plain`, the list is drawn as a sunken table: dark panel, title band, every second row shaded.
local BOLD_FONT, BOLD_SCALE = "GameFontHighlight", 12 / 10   -- a total's texts: 12 pt against the rows' 10 pt
function Widgets.List(parent, opts)
    opts = opts or {}
    local ROW_H = opts.rowHeight or 22
    local TOGGLE = math.min(ROW_H, 18)   -- the open / close sign
    local HEAD_H = opts.header == false and 0 or ROW_H
    -- MAX_COLS: the cells made per row; a table with more columns is refused (SetColumns), not cut.
    local MAX_ROWS, MAX_COLS, GAP, BAR_W = 60, 12, 6, 18
    local MIN_FIRST = 90       -- the first column never gets narrower than this
    local ACTION_W = opts.actionWidth or 0   -- room on the right for a row's button and warning sign
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
        local h = list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetHeight(ROW_H)
        headers[i] = h
        -- An invisible area over the title, for its help text.
        local area = CreateFrame("Frame", nil, list)
        area:SetAllPoints(h)
        area:EnableMouse(true)
        area:SetScript("OnEnter", function(self)
            local help = helpText[i]
            if not help then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(help[1], 1, 1, 1)
            GameTooltip:AddLine(help[2], 1, 0.82, 0, true)
            GameTooltip:Show()
        end)
        area:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- A click on a title sorts by that column, where the list's owner asked for it (list.onSort).
        area:SetScript("OnMouseUp", function()
            local onSort = rawget(list, "onSort")
            if onSort and list.columns[i] then onSort(i) end
        end)
        area:Hide()
        helps[i] = area
    end
    -- The column chooser, at the right end of the title band, over the scroll bar: the titles end before it.
    if HEAD_H > 0 then
        local chooser = Widgets.ColumnChooser(list, function()
            local entries = {}
            for i, col in ipairs(list.columns) do
                entries[i] = { key = Widgets.ColumnKey(col), locked = i == 1 and FIRST_REASON or nil }
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
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetHeight(ROW_H)
            fs:SetWordWrap(false)
            row.cells[i] = fs
        end
        row:SetScript("OnEnter", function(self)
            local data = self.data
            -- A row's own help: what the line is and how it is computed.
            local tip = data and data.tip
            if tip then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(tip[1], 1, 1, 1)
                for i = 2, #tip do GameTooltip:AddLine(tip[i], 1, 0.82, 0, true) end
                GameTooltip:Show()
                return
            end
            local link = data and (data.link or (data.itemID and ("item:" .. data.itemID)))
            if not link then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(link)
            local hint = ns.RowHint and ns.RowHint(data)
            if hint then GameTooltip:AddLine(hint, 0.5, 0.8, 1) end
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
                GameTooltip:AddLine(w.text, 1, 0.82, 0, true)
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
    end

    function list:SetSource(count, getRow)
        self.count, self.getRow = count, getRow
    end

    function list:Refresh()
        local cols = self.columns
        -- A table shown before it has columns (a window drawing its views) has nothing to draw yet.
        if not cols or #cols == 0 then return end
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
        -- Every column is as wide as its widest text (title or cell), and no wider; the room that is left
        -- stays empty at the right. Where the client cannot measure text, the widths given are used and
        -- the first column takes the room that is left.
        local titles, samples = {}, {}
        for i, col in ipairs(cols) do titles[i], samples[i] = col[1], col.sample end
        local need = opts.fit ~= false and Widgets.FitColumns(titles, self.count, function(r)
            local data = self.getRow(r)
            if not data then return nil end
            return data.cells, (data.indent or 0) + (data.itemID and ROW_H or 0) + (data.open ~= nil and TOGGLE + 4 or 0)
        end, nil, samples) or nil
        -- A total's texts are in the larger font: measured in the small one, then scaled.
        if need then
            for r = 1, math.min(self.count, 400) do
                local data = self.getRow(r)
                if data and data.bold then
                    for i = 1, #cols do
                        local w = Widgets.TextWidth(data.cells[i])
                        if i == 1 then w = w and (w + (data.indent or 0) / BOLD_SCALE) end
                        if w then need[i] = math.max(need[i], math.ceil(w * BOLD_SCALE) + 10) end
                    end
                end
            end
        end
        local fixed = 0
        for i = 2, #cols do if shown[i] then fixed = fixed + (need and need[i] or cols[i][2]) + GAP end end
        local first = math.max(MIN_FIRST, avail - fixed)
        -- A statement's label column takes all the free width, so its amounts end at the right edge.
        if need then first = math.max(40, cols.statement and (avail - fixed) or math.min(need[1], first)) end
        local xs, ws, fits, x = {}, {}, {}, 4
        for i, col in ipairs(cols) do
            xs[i], ws[i] = x, (i == 1 and first or (need and need[i] or col[2]))
            fits[i] = shown[i] and (i == 1 or (x + ws[i] <= avail + 4))
            if shown[i] then x = x + ws[i] + GAP end
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
        local full = need and (x + need[1] - first) or nil
        self.neededWidth = need and (actionX and (full + 22 + 64 + 6) or full) + BAR_W + 8 or nil
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
                h:SetWidth(ws[i]) h:SetJustifyH(col[3] or "LEFT") h:SetText(col[1]) h:Show()
            else
                h:Hide()
            end
            helpText[i] = on and col.help or nil
            helps[i]:SetShown(on and (helpText[i] ~= nil or rawget(list, "onSort") ~= nil) or false)
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
                    row.toggle:SetTexture(data.open and "Interface\\Buttons\\UI-MinusButton-Up"
                        or "Interface\\Buttons\\UI-PlusButton-Up")
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
                    if col and fits[i] then
                        local extra = i == 1 and textIndent or 0
                        fs:ClearAllPoints()
                        fs:SetPoint("LEFT", row, "LEFT", xs[i] + extra, 0)
                        fs:SetWidth(math.max(10, ws[i] - extra))
                        fs:SetJustifyH(col[3] or "LEFT")
                        fs:SetFontObject(data.bold and BOLD_FONT or "GameFontHighlightSmall")
                        fs:SetText(data.cells[i] or "")
                        fs:Show()
                    else
                        fs:Hide()
                    end
                end
                row:Show()
            end
        end
    end

    list:SetScript("OnSizeChanged", function() list:Refresh() end)
    return list
end

--- A scrolling stack of small tables ("cards"), each in its own sunken panel with a title band.
--- The caller anchors the returned frame.
---   stack:SetColumns({ { title, width, justify, help = { title, text } }, ... }, setId)   the first column takes the
---                                                         spare width; setId as in Widgets.List (the chooser sits
---                                                         at the top right, over the scroll bar)
---   stack:SetCards({ { title = text, facts = text, factsHelp = { title, text }, rows = { { cells, itemID } } }, ... })
---   stack:Refresh()
function Widgets.CardList(parent)
    -- (The title band has two lines: the title, and under it the card's facts.)
    local TITLE_H, HEAD_H, ROW_H, GAP, BAR_W, STEP, MAX_COLS = 40, 18, 22, 8, 18, 22, 10
    local HEADING_H, TOGGLE = 26, 18   -- a heading card (title only); the open / close sign
    -- A card may be a heading (data.heading: its title only), may open and close (data.open ~= nil: the sign
    -- before its title, a click on its title band calls data.onClick), and may sit in (data.indent).
    local stack = CreateFrame("Frame", nil, parent)
    stack.offset, stack.cards, stack.data, stack.columns = 0, {}, {}, {}
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

    --- Where each column sits: the first from the left (after the icon), the others from the right edge.
    -- Where each column sits: packed from the left, each as wide as stack.widths says (see Refresh); a column
    -- hidden with the chooser takes no room.
    local function place(region, card, i, forTitle)
        local cols, ws, shown = stack.columns, stack.widths, stack.shown
        local x = 30
        for c = 1, i - 1 do if shown[c] then x = x + ws[c] + 8 end end
        region:ClearAllPoints()
        if i == 1 and forTitle then
            region:SetPoint("LEFT", card, "LEFT", 8, 0)
            region:SetWidth(ws[1] + 22)
        else
            region:SetPoint("LEFT", card, "LEFT", x, 0)
            region:SetWidth(ws[i])
        end
        region:SetJustifyH(cols[i][3] or "LEFT")
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
        card.click:SetScript("OnClick", function()
            if card.data and card.data.onClick then card.data.onClick(card.data) end
        end)
        card.title = card:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        card.title:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -5)
        card.facts = card:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        card.facts:SetPoint("TOPLEFT", card, "TOPLEFT", 8, -23)
        card.facts:SetJustifyH("LEFT")
        card.factsHelp = CreateFrame("Frame", nil, card)
        card.factsHelp:SetAllPoints(card.facts)
        card.factsHelp:EnableMouse(true)
        card.factsHelp:SetScript("OnEnter", function(self)
            local help = card.data and card.data.factsHelp
            if not help then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(help[1], 1, 1, 1)
            GameTooltip:AddLine(help[2], 1, 0.82, 0, true)
            GameTooltip:Show()
        end)
        card.factsHelp:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- The column titles, in a strip under the title band.
        card.heads = CreateFrame("Frame", nil, card)
        card.heads:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -TITLE_H - 1)
        card.heads:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, -TITLE_H - 1)
        card.heads:SetHeight(HEAD_H)
        card.headTexts, card.headHelps = {}, {}
        for i = 1, MAX_COLS do
            local h = card.heads:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            h:SetHeight(HEAD_H)
            card.headTexts[i] = h
            local area = CreateFrame("Frame", nil, card.heads)
            area:SetAllPoints(h)
            area:EnableMouse(true)
            area:SetScript("OnEnter", function(self)
                local col = stack.columns[i]
                if not (col and col.help) then return end
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                GameTooltip:SetText(col.help[1], 1, 1, 1)
                GameTooltip:AddLine(col.help[2], 1, 0.82, 0, true)
                GameTooltip:Show()
            end)
            area:SetScript("OnLeave", function() GameTooltip:Hide() end)
            card.headHelps[i] = area
        end
        card.rows = {}
        return card
    end

    local function newRow(card, r)
        local row = CreateFrame("Button", nil, card)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", card, "TOPLEFT", 1, -TITLE_H - HEAD_H - 1 - (r - 1) * ROW_H)
        row:SetPoint("TOPRIGHT", card, "TOPRIGHT", -1, -TITLE_H - HEAD_H - 1 - (r - 1) * ROW_H)
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

    function stack:Refresh()
        local cols = self.columns
        if not cols or #cols == 0 then return end
        -- Every column is as wide as its widest text over all cards, and no wider, so the cards line up.
        -- Where the client cannot measure text, the widths given are used.
        local titles, samples, all = {}, {}, {}
        for i, col in ipairs(cols) do titles[i], samples[i] = col[1], col.sample end
        for _, data in ipairs(self.data) do
            for _, row in ipairs(data.rows or {}) do all[#all + 1] = row.cells end
        end
        local need = Widgets.FitColumns(titles, #all, function(r) return all[r] end, nil, samples)
        self.widths, self.shown = {}, {}
        local setId = rawget(self, "columnSet")
        for i, col in ipairs(cols) do
            self.widths[i] = need and need[i] or col[2]
            self.shown[i] = i == 1 or Widgets.ColumnShown(setId, Widgets.ColumnKey(col))
        end
        chooser:SetShown(setId ~= nil)
        content:SetWidth(math.max(10, (scroll:GetWidth() or 0)))
        local y = 0
        for n, data in ipairs(self.data) do
            local card = self.cards[n]
            if not card then
                card = newCard()
                self.cards[n] = card
            end
            card.data = data
            local rows = data.rows or {}
            local titleH = data.heading and HEADING_H or TITLE_H
            local height = titleH + 2 + (#rows > 0 and (HEAD_H + #rows * ROW_H + 2) or 0)
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", content, "TOPLEFT", data.indent or 0, -y)
            card:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
            card:SetHeight(height)
            card.band:SetHeight(titleH)
            card.click:SetHeight(titleH)
            card.click:SetShown(data.onClick ~= nil)
            local tx = 8
            if data.open ~= nil then
                card.toggle:SetTexture(data.open and "Interface\\Buttons\\UI-MinusButton-Up"
                    or "Interface\\Buttons\\UI-PlusButton-Up")
                card.toggle:ClearAllPoints()
                card.toggle:SetPoint("TOPLEFT", card, "TOPLEFT", 6, -(data.heading and 4 or 3))
                card.toggle:Show()
                tx = 6 + TOGGLE + 4
            else
                card.toggle:Hide()
            end
            card.title:ClearAllPoints()
            card.title:SetPoint("TOPLEFT", card, "TOPLEFT", tx, data.heading and -6 or -5)
            card.facts:ClearAllPoints()
            card.facts:SetPoint("TOPLEFT", card, "TOPLEFT", tx, -23)
            card.title:SetText(data.title or "")
            card.facts:SetText(data.facts or "")
            card.factsHelp:SetShown(data.factsHelp ~= nil)
            card.heads:SetShown(#rows > 0)
            card.heads:ClearAllPoints()
            card.heads:SetPoint("TOPLEFT", card, "TOPLEFT", 0, -titleH - 1)
            card.heads:SetPoint("TOPRIGHT", card, "TOPRIGHT", 0, -titleH - 1)
            for i = 1, MAX_COLS do
                local h, col = card.headTexts[i], cols[i]
                if col and self.shown[i] then
                    place(h, card.heads, i, i == 1)
                    h:SetText(col[1])
                    h:Show()
                else
                    h:Hide()
                end
                card.headHelps[i]:SetShown(col ~= nil and self.shown[i] and col.help ~= nil)
            end
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
                        local icon = rowData.itemID and Widgets.IconOf(rowData.itemID)
                        if icon then row.icon:SetTexture(icon) row.icon:Show() else row.icon:Hide() end
                        for i = 1, MAX_COLS do
                            local fs = row.cells[i]
                            if cols[i] and self.shown[i] then
                                place(fs, row, i)
                                fs:SetText(rowData.cells[i] or "")
                                fs:Show()
                            else
                                fs:Hide()
                            end
                        end
                    end
                end
            end
            card:Show()
            y = y + height + GAP
        end
        for n = #self.data + 1, #self.cards do self.cards[n]:Hide() end
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

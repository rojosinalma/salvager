-- Salvager: the tables. Widgets.List is one scrolling table; Widgets.CardList is a scrolling stack
-- of small tables, one per card. Both have the same look: a sunken panel, a title band, striped rows.
local _, ns = ...

local Widgets = ns.Widgets

--- A scrolling table. The caller anchors the returned frame.
---   list:SetColumns({ { title, width, justify, help = { title, text }, sample = text }, ... })
---                                                         the first column takes the spare width; help shows
---                                                         on the column title; sample = the widest text the
---                                                         column can hold ("00:00:00"), so it keeps its width
---   list:SetSource(count, getRow)                         getRow(i) -> row, only called for rows on screen
---   list:Refresh()
--- row = { cells = { text, ... }, itemID = icon and tooltip, link = tooltip, indent = pixels }
--- row.group = true marks the first row of a group (an item with its materials under it): it gets a band.
--- opts = { rowHeight = 22, header = true, plain = false }
--- Unless `plain`, the list is drawn as a sunken table: dark panel, title band, every second row shaded.
function Widgets.List(parent, opts)
    opts = opts or {}
    local ROW_H = opts.rowHeight or 22
    local HEAD_H = opts.header == false and 0 or ROW_H
    local MAX_ROWS, MAX_COLS, GAP, BAR_W = 60, 10, 6, 18
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
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(ROW_H - 4, ROW_H - 4)
        row.cells = {}
        for i = 1, MAX_COLS do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetHeight(ROW_H)
            fs:SetWordWrap(false)
            row.cells[i] = fs
        end
        row:SetScript("OnEnter", function(self)
            local data = self.data
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

    function list:SetColumns(cols) self.columns = cols end

    function list:SetSource(count, getRow)
        self.count, self.getRow = count, getRow
    end

    function list:Refresh()
        local cols = self.columns
        -- A table shown before it has columns (a window drawing its views) has nothing to draw yet.
        if not cols or #cols == 0 then return end
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
            return data.cells, (data.indent or 0) + (data.itemID and ROW_H or 0)
        end, nil, samples) or nil
        local fixed = 0
        for i = 2, #cols do fixed = fixed + (need and need[i] or cols[i][2]) + GAP end
        local first = math.max(MIN_FIRST, avail - fixed)
        if need then first = math.max(40, math.min(need[1], first)) end
        local xs, ws, fits, x = {}, {}, {}, 4
        for i, col in ipairs(cols) do
            xs[i], ws[i] = x, (i == 1 and first or (need and need[i] or col[2]))
            fits[i] = i == 1 or (x + ws[i] <= avail + 4)
            x = x + ws[i] + GAP
        end
        if not fits[2] and cols[1] then ws[1] = math.max(10, avail - 4) end
        -- The buttons' column is a column like the others: right after the last one, as wide as its warning
        -- sign and its button. (Where text cannot be measured, it stays at the right edge.)
        local actionX = need and ACTION_W > 0 and math.min(x, avail + 4) or nil
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
            if not data then
                row:Hide()
            else
                local indent = data.indent or 0
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
---   stack:SetColumns({ { title, width, justify, help = { title, text } }, ... })   the first column takes the spare width
---   stack:SetCards({ { title = text, facts = text, factsHelp = { title, text }, rows = { { cells, itemID } } }, ... })
---   stack:Refresh()
function Widgets.CardList(parent)
    -- (The title band has two lines: the title, and under it the card's facts.)
    local TITLE_H, HEAD_H, ROW_H, GAP, BAR_W, STEP, MAX_COLS = 40, 18, 22, 8, 18, 22, 8
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
    bar:SetPoint("TOPRIGHT", stack, "TOPRIGHT", 0, 0)
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
    -- Where each column sits: packed from the left, each as wide as stack.widths says (see Refresh).
    local function place(region, card, i, forTitle)
        local cols, ws = stack.columns, stack.widths
        local x = 30
        for c = 1, i - 1 do x = x + ws[c] + 8 end
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

    function stack:SetColumns(cols) self.columns = cols end
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
        self.widths = {}
        for i, col in ipairs(cols) do self.widths[i] = need and need[i] or col[2] end
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
            local height = TITLE_H + 2 + (#rows > 0 and (HEAD_H + #rows * ROW_H + 2) or 0)
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -y)
            card:SetPoint("TOPRIGHT", content, "TOPRIGHT", 0, -y)
            card:SetHeight(height)
            card.title:SetText(data.title or "")
            card.facts:SetText(data.facts or "")
            card.factsHelp:SetShown(data.factsHelp ~= nil)
            card.heads:SetShown(#rows > 0)
            for i = 1, MAX_COLS do
                local h, col = card.headTexts[i], cols[i]
                if col then
                    place(h, card.heads, i, i == 1)
                    h:SetText(col[1])
                    h:Show()
                else
                    h:Hide()
                end
                card.headHelps[i]:SetShown(col ~= nil and col.help ~= nil)
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
                            if cols[i] then
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

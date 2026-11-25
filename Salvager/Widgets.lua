-- Salvager: small UI building blocks shared by the window and the options panel.
local _, ns = ...

local Util = ns.Util

local Widgets = {}
ns.Widgets = Widgets

function Widgets.Button(parent, text, width, onClick, tooltip)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    if tooltip then Widgets.Tooltip(b, text, tooltip) end
    return b
end

--- A small square button with an icon. :SetIcon(path) or :SetSquare(r, g, b) changes it.
function Widgets.IconButton(parent, size, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(size, size)
    b:SetText("")
    local icon = b:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.icon = icon
    function b.SetIcon(_, path, w, h)
        icon:SetSize(w or size - 8, h or size - 8)
        icon:SetTexCoord(0, 1, 0, 1)
        icon:SetTexture(path)
        icon:SetVertexColor(1, 1, 1)
    end
    -- A media "stop" glyph in the same gold as the play arrow: a small square with a dark outline,
    -- greyed while the button is disabled.
    local outline
    function b.SetStopGlyph()
        if not outline then
            outline = b:CreateTexture(nil, "ARTWORK")
            outline:SetPoint("CENTER", b, "CENTER", 0, 0)
            outline:SetSize(12, 12)
            outline:SetColorTexture(0, 0, 0, 0.85)
        end
        icon:SetSize(10, 10)
        icon:SetColorTexture(1, 1, 1, 1)
        b:UpdateGlyph()
    end
    function b.UpdateGlyph()
        if not outline then return end
        if b:IsEnabled() then icon:SetVertexColor(1, 0.82, 0) else icon:SetVertexColor(0.45, 0.45, 0.45) end
    end
    b:SetScript("OnClick", onClick)
    return b
end

--- Shows a title and text when the mouse is over `frame`.
function Widgets.Tooltip(frame, title, text)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(title, 1, 1, 1)
        GameTooltip:AddLine(text, 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    frame:HookScript("OnLeave", function() GameTooltip:Hide() end)
end

function Widgets.Check(parent, label, tooltip, onClick)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(24, 24)
    local text = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", c, "RIGHT", 2, 0)
    text:SetText(label)
    c.label = text
    c:SetScript("OnClick", function(self) if onClick then onClick(self:GetChecked() and true or false) end end)
    if tooltip then Widgets.Tooltip(c, label, tooltip) end
    return c
end

--- A row of check buttons where exactly one is on. options = { {value, label}, ... }
function Widgets.Choice(parent, options, onChange, tooltip)
    local group = { buttons = {}, value = nil }
    local prev
    for _, o in ipairs(options) do
        local c = Widgets.Check(parent, o[2], tooltip)
        if prev then c:SetPoint("LEFT", prev.label, "RIGHT", 12, 0) end
        c:SetScript("OnClick", function()
            group:Set(o[1])
            if onChange then onChange(o[1]) end
        end)
        group.buttons[#group.buttons + 1] = { button = c, value = o[1] }
        prev = c
    end
    function group:Set(v)
        self.value = v
        for _, b in ipairs(self.buttons) do b.button:SetChecked(b.value == v) end
    end
    function group:SetPoint(...) self.buttons[1].button:SetPoint(...) end
    return group
end

function Widgets.Edit(parent, width, numeric)
    local e = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    if numeric then e:SetNumeric(true) end
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

--- Three boxes (gold, silver, copper) in one frame. onChange(copper) runs when a box loses focus.
function Widgets.Money(parent, onChange)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(170, 20)
    local m = { boxes = {}, frame = frame }
    local prev
    for i, coin in ipairs({ ns.Util.COIN.g, ns.Util.COIN.s, ns.Util.COIN.c }) do
        local e = Widgets.Edit(frame, i == 1 and 48 or 30, true)
        e:SetMaxLetters(i == 1 and 6 or 2)
        e:SetJustifyH("RIGHT")
        -- The template's border reaches about 5 px past the box on each side: keep the digits inside it.
        e:SetTextInsets(2, 4, 0, 0)
        if prev then e:SetPoint("LEFT", prev, "RIGHT", 26, 0) else e:SetPoint("LEFT", frame, "LEFT", 8, 0) end
        local l = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l:SetPoint("LEFT", e, "RIGHT", 7, 0)
        l:SetText(coin)
        e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        e:SetScript("OnTabPressed", function()
            local nextBox = m.boxes[i % 3 + 1]
            if nextBox then nextBox:SetFocus() end
        end)
        e:SetScript("OnEditFocusLost", function()
            if m.silent then return end
            if onChange then onChange(m:Get()) end
        end)
        e:SetScript("OnTextChanged", function(_, user)
            if user and not m.silent and m.onTyping then m.onTyping(m:Get()) end
        end)
        m.boxes[i] = e
        prev = e
    end
    function m:Get()
        local g = tonumber(self.boxes[1]:GetText()) or 0
        local s = math.min(99, tonumber(self.boxes[2]:GetText()) or 0)
        local c = math.min(99, tonumber(self.boxes[3]:GetText()) or 0)
        return g * 10000 + s * 100 + c
    end
    function m:HasFocus()
        return self.boxes[1]:HasFocus() or self.boxes[2]:HasFocus() or self.boxes[3]:HasFocus()
    end
    function m:Set(copper)
        if self:HasFocus() then return end
        self.silent = true
        copper = math.max(0, math.floor(copper or 0))
        self.boxes[1]:SetText(tostring(math.floor(copper / 10000)))
        self.boxes[2]:SetText(tostring(math.floor(copper % 10000 / 100)))
        self.boxes[3]:SetText(tostring(copper % 100))
        self.silent = false
    end
    function m:SetTextColor(r, g, b) for _, e in ipairs(self.boxes) do e:SetTextColor(r, g, b) end end
    function m:SetPoint(...) self.frame:SetPoint(...) end
    function m:ClearAllPoints() self.frame:ClearAllPoints() end
    function m:Show() self.frame:Show() end
    function m:Hide() self.frame:Hide() end
    function m:Right() return self.frame end
    return m
end

--- A rotating ring. :Start() / :Stop().
function Widgets.Spinner(parent, size)
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(size, size)
    local ring = f:CreateTexture(nil, "ARTWORK")
    ring:SetAllPoints()
    ring:SetTexture("Interface\\COMMON\\StreamCircle")
    ring:SetVertexColor(0.58, 0.44, 0.86)
    local spark = f:CreateTexture(nil, "OVERLAY")
    spark:SetAllPoints()
    spark:SetTexture("Interface\\COMMON\\StreamSpark")
    local ag = spark:CreateAnimationGroup()
    local rot = ag:CreateAnimation("Rotation")
    rot:SetDegrees(-360)
    rot:SetDuration(1)
    ag:SetLooping("REPEAT")
    function f:Start() self:Show() ag:Play() end
    function f:Stop() ag:Stop() self:Hide() end
    f:Hide()
    return f
end

--- A button that opens a small list of check boxes.
--- options = { {value, label}, ... }; get(value) -> bool; set(value, bool). Returns the button.
function Widgets.CheckDropdown(parent, width, options, get, set, tooltip, title)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    local list = CreateFrame("Frame", nil, b, BackdropTemplateMixin and "BackdropTemplate" or nil)
    list:SetFrameStrata("DIALOG")
    list:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2)
    list:SetSize(width, #options * 22 + 12)
    if list.SetBackdrop then
        -- The game's tooltip look: near-black fill, grey border.
        list:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        list:SetBackdropColor(0, 0, 0, 0.92)
        list:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    else
        local bg = list:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.92)
    end
    list:EnableMouse(true)
    list:Hide()
    local checks = {}
    function b:Update()
        local names = {}
        for i, o in ipairs(options) do
            local on = get(o[1]) and true or false
            checks[i]:SetChecked(on)
            if on then names[#names + 1] = o[2] end
        end
        self:SetText((#names > 0 and table.concat(names, ", ") or "none") .. " |TInterface\\Buttons\\Arrow-Down-Up:12:12|t")
    end
    for i, o in ipairs(options) do
        local c = Widgets.Check(list, o[2], nil, function(on)
            set(o[1], on)
            b:Update()
        end)
        c:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -6 - (i - 1) * 22)
        checks[i] = c
    end
    b:SetScript("OnClick", function() list:SetShown(not list:IsShown()) end)
    b:SetScript("OnHide", function() list:Hide() end)
    if tooltip then Widgets.Tooltip(b, title or "Choose", tooltip) end
    b.list = list
    b.checks = checks
    return b
end

--- A vertical scroll bar for a list drawn by offset. onScroll(offset) runs when the player moves it.
--- :Update(offset, max) sets it from the list; it hides itself when everything fits (max = 0).
function Widgets.ScrollBar(parent, onScroll)
    local bar = CreateFrame("Slider", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(14)
    local track = bar:CreateTexture(nil, "BACKGROUND")
    track:SetAllPoints()
    track:SetColorTexture(0, 0, 0, 0.35)
    bar:SetThumbTexture("Interface\\Buttons\\UI-ScrollBar-Knob")
    bar:SetValueStep(1)
    bar:SetObeyStepOnDrag(true)
    bar:SetMinMaxValues(0, 0)
    bar:SetValue(0)
    local setting = false
    bar:SetScript("OnValueChanged", function(_, value)
        if setting then return end
        onScroll(math.floor((value or 0) + 0.5))
    end)
    function bar.Update(_, offset, max)
        setting = true
        bar:SetMinMaxValues(0, math.max(0, max))
        bar:SetValue(offset)
        setting = false
        bar:SetShown(max > 0)
    end
    return bar
end

--- A window of its own: movable, resizable from the bottom right corner, closed with Escape.
--- Its place and size are kept in SalvagerDB.windows[key]. f.onResize runs when the size changes.
function Widgets.Window(globalName, title, key, w, h, minW, minH)
    local f = CreateFrame("Frame", globalName, UIParent, "BasicFrameTemplateWithInset")
    local saved = ns.db.windows[key] or {}
    ns.db.windows[key] = saved
    f:SetSize(math.max(minW, saved.w or w), math.max(minH, saved.h or h))
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    if saved.x and saved.y then
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", saved.x, saved.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", saved.dx or 0, saved.dy or 0)
    end
    -- Pinned by its top left corner, so sizing moves only the bottom right one.
    local function pin()
        local left, top = f:GetLeft(), f:GetTop()
        if not (left and top) then return end
        f:ClearAllPoints()
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
        saved.x, saved.y = left, top
    end
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        pin()
    end)
    local text = f.TitleText
    if type(text) ~= "table" then
        text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        text:SetPoint("TOP", f, "TOP", 0, -5)
    end
    text:SetText(title)
    tinsert(UISpecialFrames, globalName)

    f:SetResizable(true)
    local maxW, maxH = UIParent:GetWidth(), UIParent:GetHeight()
    if f.SetResizeBounds then
        f:SetResizeBounds(minW, minH, maxW, maxH)
    elseif f.SetMinResize then
        f:SetMinResize(minW, minH)
    end
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        pin()
        f:StartSizing("BOTTOMRIGHT", true)
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        saved.w, saved.h = math.floor(f:GetWidth()), math.floor(f:GetHeight())
        pin()
        if f.onResize then f.onResize() end
    end)
    f:SetScript("OnSizeChanged", function() if f.onResize then f.onResize() end end)
    f:Hide()
    return f
end

--- A scrolling table. The caller anchors the returned frame.
---   list:SetColumns({ { title, width, justify }, ... })   the first column takes the spare width
---   list:SetSource(count, getRow)                         getRow(i) -> row, only called for rows on screen
---   list:Refresh()
--- row = { cells = { text, ... }, itemID = icon and tooltip, link = tooltip, indent = pixels }
--- opts = { rowHeight = 22, header = true }
function Widgets.List(parent, opts)
    opts = opts or {}
    local ROW_H = opts.rowHeight or 22
    local HEAD_H = opts.header == false and 0 or ROW_H
    local MAX_ROWS, MAX_COLS, GAP, BAR_W = 60, 8, 6, 18
    local MIN_FIRST = 90       -- the first column never gets narrower than this
    local list = CreateFrame("Frame", nil, parent)
    if list.SetClipsChildren then list:SetClipsChildren(true) end
    list.offset, list.count, list.columns = 0, 0, {}
    local headers, rows = {}, {}
    list.headers, list.rows = headers, rows

    for i = 1, MAX_COLS do
        local h = list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetHeight(ROW_H)
        headers[i] = h
    end
    for r = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -HEAD_H - (r - 1) * ROW_H)
        row:SetPoint("RIGHT", list, "RIGHT", -BAR_W, 0)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
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
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row:Hide()
        rows[r] = row
    end

    local bar = Widgets.ScrollBar(list, function(value)
        if value ~= list.offset then
            list.offset = value
            list:Refresh()
        end
    end)
    bar:SetPoint("TOPRIGHT", list, "TOPRIGHT", 0, -HEAD_H)
    bar:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 0)
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
        local fit = math.max(1, math.min(MAX_ROWS, math.floor(((self:GetHeight() or 0) - HEAD_H) / ROW_H)))
        self.offset = math.max(0, math.min(self.offset, self.count - fit))
        bar:Update(self.offset, self.count - fit)
        -- Column positions. The first column takes what is left of the width and shrinks with the
        -- window; a column that still does not fit is left out, from the right.
        local avail = (self:GetWidth() or 0) - BAR_W - 8
        local fixed = 0
        for i = 2, #cols do fixed = fixed + cols[i][2] + GAP end
        local first = math.max(MIN_FIRST, avail - fixed)
        local xs, ws, fits, x = {}, {}, {}, 4
        for i, col in ipairs(cols) do
            xs[i], ws[i] = x, (i == 1 and first or col[2])
            fits[i] = i == 1 or (x + ws[i] <= avail + 4)
            x = x + ws[i] + GAP
        end
        if not fits[2] and cols[1] then ws[1] = math.max(10, avail - 4) end
        for i = 1, MAX_COLS do
            local h, col = headers[i], cols[i]
            if col and fits[i] and HEAD_H > 0 then
                h:ClearAllPoints()
                h:SetPoint("TOPLEFT", self, "TOPLEFT", xs[i], 0)
                h:SetWidth(ws[i]) h:SetJustifyH(col[3] or "LEFT") h:SetText(col[1]) h:Show()
            else
                h:Hide()
            end
        end
        for r = 1, MAX_ROWS do
            local row = rows[r]
            local data = r <= fit and (r + self.offset) <= self.count and self.getRow(r + self.offset) or nil
            row.data = data
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

function Widgets.Label(parent, text, template)
    local l = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
    l:SetText(text)
    return l
end

--- Item icon texture file for an item ID.
function Widgets.IconOf(itemID)
    if not itemID then return nil end
    if C_Item and C_Item.GetItemIconByID then
        local ok, icon = pcall(C_Item.GetItemIconByID, itemID)
        if ok and icon then return icon end
    end
    local _, _, _, _, icon = ns.GetItemInfoInstant(itemID)
    return icon
end

Widgets.FormatMoney = Util.FormatMoney

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

--- A small "?" button. A click shows `getLines()` (a title, then one line per explanation) in a
--- panel under it; a second click, or a click anywhere else, closes it.
function Widgets.HelpButton(parent, title, getLines)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(22, 22)
    b:SetText("?")
    local WIDTH = 470
    local panel = CreateFrame("Frame", nil, b, BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetFrameStrata("DIALOG")
    panel:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, -2)
    panel:SetWidth(WIDTH)
    if panel.SetBackdrop then
        panel:SetBackdrop({
            bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            tile = true, tileSize = 16, edgeSize = 16,
            insets = { left = 4, right = 4, top = 4, bottom = 4 },
        })
        panel:SetBackdropColor(0, 0, 0, 0.95)
        panel:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    else
        Widgets.Skin(panel, 0, 0, 0, 0.95)
    end
    panel:EnableMouse(true)
    local head = panel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    head:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, -10)
    local body = panel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    body:SetPoint("TOPLEFT", head, "BOTTOMLEFT", 0, -8)
    body:SetWidth(WIDTH - 24)
    body:SetJustifyH("LEFT")
    body:SetSpacing(4)
    panel:Hide()
    b.panel, b.body = panel, body
    local function fill()
        local lines = getLines()
        head:SetText(type(title) == "function" and title() or title)
        body:SetText(table.concat(lines, "\n"))
        panel:SetHeight((tonumber(body:GetStringHeight()) or (#lines * 16)) + 44)
    end
    b:SetScript("OnClick", function()
        if panel:IsShown() then panel:Hide() return end
        fill()
        panel:Show()
    end)
    b:SetScript("OnHide", function() panel:Hide() end)
    Widgets.Tooltip(b, "Help", "Click to see what the columns and marks in this list mean.")
    if pcall(panel.RegisterEvent, panel, "GLOBAL_MOUSE_DOWN") then
        panel:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        panel:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
        panel:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
        panel:SetScript("OnEvent", function(self)
            if not self:IsMouseOver() and not b:IsMouseOver() then self:Hide() end
        end)
    end
    return b
end

--- A flat panel: a filled background with a thin border. Used to set a list or a group of
--- controls apart from the window behind it. Returns the frame (anchor it yourself).
--- Draws the panel look (filled background, thin border) on an existing frame.
function Widgets.Skin(p, r, g, b, a)
    local bg = p:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(r or 0, g or 0, b or 0, a or 0.4)
    local function edge(point1, point2, horizontal)
        local t = p:CreateTexture(nil, "BORDER")
        t:SetColorTexture(0.45, 0.42, 0.35, 0.9)
        t:SetPoint(point1, p, point1, 0, 0)
        t:SetPoint(point2, p, point2, 0, 0)
        if horizontal then t:SetHeight(1) else t:SetWidth(1) end
    end
    edge("TOPLEFT", "TOPRIGHT", true)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", true)
    edge("TOPLEFT", "BOTTOMLEFT", false)
    edge("TOPRIGHT", "BOTTOMRIGHT", false)
    return p
end

function Widgets.Panel(parent, r, g, b, a)
    return Widgets.Skin(CreateFrame("Frame", nil, parent), r, g, b, a)
end

--- Help text for a label: an invisible area over `region` that shows a tooltip.
function Widgets.HelpArea(parent, region, title, text)
    local area = CreateFrame("Frame", nil, parent)
    area:SetAllPoints(region)
    area:EnableMouse(true)
    Widgets.Tooltip(area, title, text)
    return area
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
    -- A "window of its own" glyph: a square with a second one behind it, up and to the right.
    function b.SetPopOutGlyph()
        icon:Hide()
        local box = CreateFrame("Frame", nil, b)
        box:SetSize(14, 14)
        box:SetPoint("CENTER", b, "CENTER", 0, 0)
        local function line(x, y, w, h)
            local t = box:CreateTexture(nil, "OVERLAY")
            t:SetColorTexture(1, 0.82, 0, 1)
            t:SetPoint("BOTTOMLEFT", box, "BOTTOMLEFT", x, y)
            t:SetSize(w, h)
        end
        line(0, 0, 10, 2) line(0, 8, 10, 2) line(0, 0, 2, 10) line(8, 0, 2, 10)   -- the front square
        line(4, 12, 10, 2) line(12, 4, 2, 10)                                     -- the one behind it
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
    -- Layout: [box] coin  [box] coin  [box] coin. Each coin sits right after its own box, and the
    -- frame is as wide as all of it, so whatever comes next starts after the last coin.
    local BOX_W, SMALL_W, COIN, COIN_GAP, NEXT_GAP, LEFT_PAD = 48, 30, 13, 3, 11, 6
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(LEFT_PAD + BOX_W + 2 * SMALL_W + 3 * (COIN_GAP + COIN) + 2 * NEXT_GAP + 2, 20)
    local m = { boxes = {}, frame = frame }
    local prevCoin
    for i, icon in ipairs({ "UI-GoldIcon", "UI-SilverIcon", "UI-CopperIcon" }) do
        local e = Widgets.Edit(frame, i == 1 and BOX_W or SMALL_W, true)
        e:SetMaxLetters(i == 1 and 6 or 2)
        e:SetJustifyH("RIGHT")
        -- The template's border is drawn around the box: keep the digits inside it.
        e:SetTextInsets(2, 4, 0, 0)
        if prevCoin then
            e:SetPoint("LEFT", prevCoin, "RIGHT", NEXT_GAP, 0)
        else
            e:SetPoint("LEFT", frame, "LEFT", LEFT_PAD, 0)
        end
        local coin = frame:CreateTexture(nil, "ARTWORK")
        coin:SetSize(COIN, COIN)
        coin:SetTexture("Interface\\MoneyFrame\\" .. icon)
        coin:SetPoint("LEFT", e, "RIGHT", COIN_GAP, 0)
        prevCoin = coin
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
--- `summary(names, total)` (optional) gives the button's text from the ticked names.
function Widgets.CheckDropdown(parent, width, options, get, set, tooltip, title, summary)
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
        self:SetText(summary and summary(names, #options) or (#names > 0 and table.concat(names, ", ") or "none"))
        -- As wide as its text needs, never wider than the width asked for.
        local label = self.GetFontString and self:GetFontString()
        if type(label) == "table" then
            label:SetWidth(0)   -- (measure the whole text, not the cut one)
            local measure = label.GetUnboundedStringWidth or label.GetStringWidth
            local textWidth = tonumber(measure(label))
            if textWidth then
                local w = math.max(64, math.min(width, math.ceil(textWidth) + 36))
                self:SetWidth(w)
                label:SetWidth(w - 32)
            end
        end
    end
    -- The names on the left, the arrow at the right edge.
    local label = b.GetFontString and b:GetFontString()
    if type(label) == "table" then
        label:ClearAllPoints()
        label:SetPoint("LEFT", b, "LEFT", 10, 0)
        label:SetJustifyH("LEFT")
        label:SetWordWrap(false)
    end
    local arrow = b:CreateTexture(nil, "OVERLAY")
    arrow:SetSize(12, 12)
    arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
    arrow:SetPoint("RIGHT", b, "RIGHT", -7, -2)
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
    -- A click anywhere else closes the list. The click still does what it was aimed at.
    local watching = pcall(list.RegisterEvent, list, "GLOBAL_MOUSE_DOWN")
    if watching then
        list:UnregisterEvent("GLOBAL_MOUSE_DOWN")
        list:SetScript("OnShow", function(self) self:RegisterEvent("GLOBAL_MOUSE_DOWN") end)
        list:SetScript("OnHide", function(self) self:UnregisterEvent("GLOBAL_MOUSE_DOWN") end)
        list:SetScript("OnEvent", function(self)
            if not self:IsMouseOver() and not b:IsMouseOver() then self:Hide() end
        end)
    else
        -- A client without that event: an invisible sheet behind the list takes the click.
        local sheet = CreateFrame("Button", nil, list)
        sheet:SetAllPoints(UIParent)
        sheet:SetFrameLevel(math.max(0, list:GetFrameLevel() - 1))
        sheet:SetScript("OnClick", function() list:Hide() end)
    end
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

--- A window of its own: movable, resizable from the bottom right corner (unless `fixed`), closed with Escape.
--- Its place and size are kept in SalvagerDB.windows[key]. f.onResize runs when the size changes.
function Widgets.Window(globalName, title, key, w, h, minW, minH, fixed)
    local f = CreateFrame("Frame", globalName, UIParent, "BasicFrameTemplateWithInset")
    local saved = ns.db.windows[key] or {}
    ns.db.windows[key] = saved
    f.saved = saved
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
    -- "Open" is remembered from what the player does on purpose: the addon's own buttons and
    -- commands, and the window's X. Escape and the auction house closing hide every window at
    -- once; that is not a choice about this one, so it does not change what is remembered.
    function f.UserShow()
        saved.open = true
        f:Show()
    end
    function f.UserHide()
        saved.open = false
        f:Hide()
    end
    function f.UserToggle()
        if f:IsShown() then f.UserHide() else f.UserShow() end
    end
    if type(f.CloseButton) == "table" then
        f.CloseButton:HookScript("OnClick", function() saved.open = false end)
    end
    if fixed then
        f:SetSize(w, h)
        f:Hide()
        return f
    end

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

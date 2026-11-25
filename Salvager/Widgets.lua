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
    frame:SetSize(150, 20)
    local m = { boxes = {}, frame = frame }
    local prev
    for i, coin in ipairs({ ns.Util.COIN.g, ns.Util.COIN.s, ns.Util.COIN.c }) do
        local e = Widgets.Edit(frame, i == 1 and 44 or 28, true)
        e:SetMaxLetters(i == 1 and 6 or 2)
        e:SetJustifyH("RIGHT")
        if prev then e:SetPoint("LEFT", prev, "RIGHT", 18, 0) else e:SetPoint("LEFT", frame, "LEFT", 6, 0) end
        local l = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        l:SetPoint("LEFT", e, "RIGHT", 3, 0)
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
function Widgets.CheckDropdown(parent, width, options, get, set, tooltip)
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
    if tooltip then Widgets.Tooltip(b, "Quality", tooltip) end
    b.list = list
    b.checks = checks
    return b
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

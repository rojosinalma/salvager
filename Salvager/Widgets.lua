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
    b.uiKind = "button"
    return b
end

--- A small "?" button. A click shows `getLines()` (a title, then one line per explanation) in a
--- panel under it; a second click, or a click anywhere else, closes it.
--- `opts.glyph` = "chart": a bar chart in place of the "?"; `opts.tooltip` = { title, text }; `opts.left`: it opens
--- to the right; `opts.up`: it opens over the button.
function Widgets.HelpButton(parent, title, getLines, opts)
    opts = opts or {}
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(22, 22)
    b.uiKind = "button"
    b:SetText(opts.glyph and "" or "?")
    if opts.glyph == "chart" then
        -- Three gold bars of rising height on a base line.
        local function bar(x, h, w)
            local t = b:CreateTexture(nil, "OVERLAY")
            t:SetColorTexture(1, 0.82, 0, 1)
            t:SetPoint("BOTTOMLEFT", b, "BOTTOMLEFT", x, 5)
            t:SetSize(w or 3, h)
        end
        bar(6, 5) bar(10, 8) bar(14, 11)
        bar(5, 1, 13)
    end
    local WIDTH = 470
    local panel = CreateFrame("Frame", nil, b, BackdropTemplateMixin and "BackdropTemplate" or nil)
    panel:SetFrameStrata("DIALOG")
    -- Under the button, opening to the left; with `opts.left` (a button at a left edge), to the right.
    -- (`opts.up`: over the button, for a button in a footer.)
    if opts.up then
        panel:SetPoint(opts.left and "BOTTOMLEFT" or "BOTTOMRIGHT", b, opts.left and "TOPLEFT" or "TOPRIGHT", 0, 2)
    elseif opts.left then panel:SetPoint("TOPLEFT", b, "BOTTOMLEFT", 0, -2) else panel:SetPoint("TOPRIGHT", b, "BOTTOMRIGHT", 0, -2) end
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
    local tip = opts.tooltip or { "Help", "Click to see what the columns and marks in this list mean." }
    Widgets.Tooltip(b, tip[1], tip[2])
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
    area.uiKind = "help"   -- (no look of its own: the label it lies over)
    area:SetAllPoints(region)
    area:EnableMouse(true)
    Widgets.Tooltip(area, title, text)
    return area
end

--- A small square button with an icon. :SetIcon(path) or :SetSquare(r, g, b) changes it.
function Widgets.IconButton(parent, size, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(size, size)
    b.uiKind = "button"
    b:SetText("")
    local icon = b:CreateTexture(nil, "OVERLAY")
    icon:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.icon = icon
    local outline
    function b.SetIcon(_, path, w, h)
        if outline then outline:Hide() end
        b.glyph = nil
        icon:SetSize(w or size - 8, h or size - 8)
        icon:SetTexCoord(0, 1, 0, 1)
        icon:SetTexture(path)
        icon:SetVertexColor(1, 1, 1)
    end
    -- A media "stop" glyph in the same gold as the play arrow: a small square with a dark outline,
    -- greyed while the button is disabled. (SetIcon turns the button back to an icon: a toggle uses both.)
    function b.SetStopGlyph()
        if not outline then
            outline = b:CreateTexture(nil, "ARTWORK")
            outline:SetPoint("CENTER", b, "CENTER", 0, 0)
            outline:SetSize(12, 12)
            outline:SetColorTexture(0, 0, 0, 0.85)
        end
        outline:Show()
        b.glyph = "stop"
        icon:SetSize(10, 10)
        icon:SetTexCoord(0, 1, 0, 1)
        icon:SetColorTexture(1, 1, 1, 1)
        b:UpdateGlyph()
    end
    function b.UpdateGlyph()
        if b.glyph ~= "stop" then return end
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

--- A control that is off says why (UI.md Actions 3): `b.reason` (set it with the state) goes under its tooltip in
--- red, also while it is disabled. Call after Widgets.Tooltip (or the button's own OnEnter).
function Widgets.ReasonTip(b)
    b:SetMotionScriptsWhileDisabled(true)
    b:HookScript("OnEnter", function(self)
        if not self.reason then return end
        if not GameTooltip:IsOwned(self) then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(self:GetText() or "", 1, 1, 1)
        end
        GameTooltip:AddLine(self.reason, 1, 0.3, 0.3, true)
        GameTooltip:Show()
    end)
    b:HookScript("OnLeave", function() GameTooltip:Hide() end)
    return b
end

--- The reason a control that needs the auction house is off, or nil when it is open.
Widgets.AH_CLOSED = "Open the auction house first."

--- One button for play and stop (a media toggle): the play arrow while it is off, the stop square while it runs.
--- `onClick()` decides what the click does; b:SetRunning(on) sets the look. The tooltip is the caller's (it says
--- what the click does now).
function Widgets.PlayToggle(parent, size, onClick)
    local b = Widgets.IconButton(parent, size, onClick)
    b.uiKind = "button"
    function b.SetRunning(_, on)
        if on then b:SetStopGlyph() else b:SetIcon("Interface\\ChatFrame\\ChatFrameExpandArrow", 14, 14) end
        b.running = on and true or false
    end
    b:SetRunning(false)
    return b
end

function Widgets.Check(parent, label, tooltip, onClick)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c.uiKind = "check"
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
    e.uiKind = "edit"
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    if numeric then e:SetNumeric(true) end
    e:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return e
end

--- A search box (UI.md Controls 6: first on a filter row): a text box with an X at its right end that clears it in
--- one click; Escape clears it too. `set(text)` runs at each change (live); `get()` gives the text to show.
--- box:Update() shows the text of `get()` again (another view's search).
function Widgets.Search(parent, width, get, set, tooltip)
    local e = Widgets.Edit(parent, width)
    e.isSearch = true
    if e.SetTextInsets then e:SetTextInsets(0, 16, 0, 0) end   -- (the text stops before the X)
    local clear = CreateFrame("Button", nil, e)
    clear:SetSize(14, 14)
    clear:SetPoint("RIGHT", e, "RIGHT", -3, 0)
    clear:SetNormalTexture("Interface\\FriendsFrame\\ClearBroadcastIcon")
    clear:SetHighlightTexture("Interface\\FriendsFrame\\ClearBroadcastIcon")
    clear.uiKind = "clear"
    Widgets.Tooltip(clear, "Clear the search", "Shows every row again. Escape in the box does the same.")
    e.clear = clear
    local quiet = false
    local function shown()
        local text = e:GetText() or ""
        clear:SetShown(text ~= "")
        return text
    end
    function e.Update(self)
        local want = get() or ""
        if (self:GetText() or "") ~= want then
            quiet = true
            self:SetText(want)
            quiet = false
        end
        shown()
    end
    e:SetScript("OnTextChanged", function()
        local text = shown()
        if quiet then return end
        if text ~= (get() or "") then set(text) end
    end)
    local function wipeText()
        e:SetText("")
        if (get() or "") ~= "" then set("") end
        shown()
    end
    clear:SetScript("OnClick", function()
        wipeText()
        e:ClearFocus()
    end)
    e:SetScript("OnEscapePressed", function(self)
        wipeText()
        self:ClearFocus()
    end)
    e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    if tooltip then
        e:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText("Search", 1, 1, 1)
            GameTooltip:AddLine(tooltip, 1, 0.82, 0, true)
            GameTooltip:Show()
        end)
        e:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    e:Update()
    return e
end

--- Does `name` (a link or a text, color codes and all) hold `search` (any case)? An empty search holds everything.
function Widgets.Matches(name, search)
    if not search or search == "" then return true end
    local plain = tostring(name or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
        :gsub("|T.-|t", "")
    return plain:lower():find(search:lower(), 1, true) ~= nil
end

--- The empty state of a search that matches no row (UI.md Tables 6).
function Widgets.NoMatch(search)
    return "Nothing matches \"" .. tostring(search) .. "\". Clear the search (the X in the box, or Escape) to see every row."
end

--- Three boxes (gold, silver, copper) in one frame. onChange(copper) runs when a box loses focus.
function Widgets.Money(parent, onChange)
    -- Layout: [box] coin  [box] coin  [box] coin. Each coin sits right after its own box, and the
    -- frame is as wide as all of it, so whatever comes next starts after the last coin.
    -- (The gold box holds three digits: up to 999 gold.)
    local BOX_W, SMALL_W, COIN, COIN_GAP, NEXT_GAP, LEFT_PAD = 36, 30, 13, 3, 11, 6
    local frame = CreateFrame("Frame", nil, parent)
    frame.uiKind = "edit"
    frame:SetSize(LEFT_PAD + BOX_W + 2 * SMALL_W + 3 * (COIN_GAP + COIN) + 2 * NEXT_GAP + 2, 20)
    local m = { boxes = {}, frame = frame }
    local prevCoin
    for i, icon in ipairs({ "UI-GoldIcon", "UI-SilverIcon", "UI-CopperIcon" }) do
        local e = Widgets.Edit(frame, i == 1 and BOX_W or SMALL_W, true)
        e:SetMaxLetters(i == 1 and 3 or 2)
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
        copper = math.min(9999999, math.max(0, math.floor(copper or 0)))
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

--- How wide a text is in the small font; an estimate (5.5 px a letter, color codes left out) where the client cannot
--- measure. For laying out rows before the client has drawn them, and for the specs.
local function textWidth(text)
    text = tostring(text or "")
    local w = Widgets.TextWidth and Widgets.TextWidth(text)
    if w then return w end
    return #(text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) * 5.5
end
Widgets.EstimateWidth = textWidth

-- Creates a frame from one of the game's templates, or nil where the client does not have it or the frame lacks
-- the parts the look needs (`need`: field names); the fallback then draws its own look. Each template is tried
-- once, on a frame of its own, so a failed try leaves nothing in the window.
local templateOK = {}
local function fromTemplate(kind, parent, template, need)
    if templateOK[template] == nil then
        local ok, probe = pcall(CreateFrame, kind, nil, nil, template)
        local good = ok and type(probe) == "table"
        for _, key in ipairs(need) do if good and rawget(probe, key) == nil then good = false end end
        if ok and type(probe) == "table" then probe:Hide() end
        templateOK[template] = good
    end
    if not templateOK[template] then return nil end
    local ok, f = pcall(CreateFrame, kind, nil, parent, template)
    return ok and f or nil
end

-- A 1 px frame drawn around `f`: four textures in its BORDER layer. Returns them, to color them later.
local function edges(f, r, g, b, a, skipBottom)
    local out = {}
    local function edge(p1, p2, horizontal)
        local t = f:CreateTexture(nil, "BORDER")
        t:SetColorTexture(r, g, b, a)
        t:SetPoint(p1, f, p1, 0, 0)
        t:SetPoint(p2, f, p2, 0, 0)
        if horizontal then t:SetHeight(1) else t:SetWidth(1) end
        out[#out + 1] = t
        return t
    end
    edge("TOPLEFT", "TOPRIGHT", true)
    edge("TOPLEFT", "BOTTOMLEFT", false)
    edge("TOPRIGHT", "BOTTOMRIGHT", false)
    if not skipBottom then out.bottom = edge("BOTTOMLEFT", "BOTTOMRIGHT", true) end
    return out
end

------------------------------------------------------------------ tabs, subtabs, dropdowns (UI.md Controls)
-- Each kind of control has one look, made here and nowhere else, and carries `uiKind` ("tab", "subtab",
-- "dropdown", "button", "check", "edit"); the layout dump writes it (k=) and `make layout` checks it.
-- Rows of controls are made with Widgets.Bar ("tabrow", "subtabrow", "filterrow", "footer").

local TAB_H, SUBTAB_H, FIELD_H = 26, 20, 22

--- A main tab: the game's top tab (`PanelTopTabButtonTemplate`) where the client has it, else a flat tab drawn
--- here (the selected one brighter, with a gold edge, joined to the content under it; the others dim).
--- tab:SetSelected(on) shows the choice; tab:SetText(text) sets the title (the tab fits it). Put tabs in a
--- Widgets.Bar(parent, "tabs") with bar:Add(tab).
function Widgets.Tab(parent, text, onClick, tooltip)
    local b = PanelTemplates_SelectTab and PanelTemplates_DeselectTab and PanelTemplates_TabResize
        and fromTemplate("Button", parent, "PanelTopTabButtonTemplate", { "Left", "LeftActive", "Text" }) or nil
    if b then
        b.template = true
        function b.SetSelected(self, on)
            self.selected = on and true or false
            if on then PanelTemplates_SelectTab(self) else PanelTemplates_DeselectTab(self) end
        end
        local setText = b.SetText
        function b.SetText(self, t)
            setText(self, t)
            pcall(PanelTemplates_TabResize, self, 0)
        end
    else
        b = CreateFrame("Button", nil, parent)
        b:SetHeight(TAB_H)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        local frame = edges(b, 0.4, 0.4, 0.4, 1, true)
        b:SetNormalFontObject("GameFontNormalSmall")
        b:SetHighlightFontObject("GameFontHighlightSmall")
        function b.SetSelected(self, on)
            self.selected = on and true or false
            -- Selected: a lighter fill and gold edges, white text, and 1 px lower, over the row's line, so it
            -- joins the content under it. The others: a dark fill, grey edges, gold text.
            bg:SetColorTexture(on and 0.24 or 0.07, on and 0.21 or 0.07, on and 0.15 or 0.07, on and 1 or 0.9)
            bg:ClearAllPoints()
            bg:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
            bg:SetPoint("BOTTOMRIGHT", self, "BOTTOMRIGHT", 0, on and 0 or 1)   -- (the others leave the line)
            for _, t in ipairs(frame) do
                if on then t:SetColorTexture(0.85, 0.68, 0.3, 1) else t:SetColorTexture(0.4, 0.4, 0.4, 1) end
            end
            self:SetNormalFontObject(on and "GameFontHighlightSmall" or "GameFontNormalSmall")
        end
        local setText = b.SetText
        function b.SetText(self, t)
            setText(self, t)
            self:SetWidth(math.max(64, math.ceil(textWidth(t)) + 28))
        end
    end
    b.uiKind = "tab"
    b:SetText(text)
    b:SetSelected(false)
    b:SetScript("OnClick", onClick)
    if tooltip then Widgets.Tooltip(b, text, tooltip) end
    return b
end

--- A subtab: a second level under a tab, drawn as one segment of a segmented control: a small box with an edge,
--- so it reads as something to click, but flatter and smaller than a tab and never red like an action button.
--- Unselected: dark fill, grey edge, gold text; under the pointer: lighter fill, white text; selected: gold fill
--- and edge, white text. subtab:SetSelected(on), subtab:SetText(text). Put subtabs in a Widgets.Bar(parent,
--- "subtabs").
function Widgets.Subtab(parent, text, onClick, tooltip)
    local b = CreateFrame("Button", nil, parent)
    b.uiKind = "subtab"
    b:SetHeight(SUBTAB_H)
    local fill = b:CreateTexture(nil, "BACKGROUND")
    fill:SetAllPoints()
    local sides = {}
    for _, side in ipairs({ "TOP", "BOTTOM", "LEFT", "RIGHT" }) do
        local e = b:CreateTexture(nil, "BORDER")
        if side == "TOP" or side == "BOTTOM" then
            e:SetPoint(side .. "LEFT", b, side .. "LEFT", 0, 0)
            e:SetPoint(side .. "RIGHT", b, side .. "RIGHT", 0, 0)
            e:SetHeight(1)
        else
            e:SetPoint("TOP" .. side, b, "TOP" .. side, 0, 0)
            e:SetPoint("BOTTOM" .. side, b, "BOTTOM" .. side, 0, 0)
            e:SetWidth(1)
        end
        sides[#sides + 1] = e
    end
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetPoint("TOPLEFT", b, "TOPLEFT", 1, -1)
    hl:SetPoint("BOTTOMRIGHT", b, "BOTTOMRIGHT", -1, 1)
    hl:SetColorTexture(1, 1, 1, 0.10)
    b:SetNormalFontObject("GameFontNormalSmall")
    b:SetHighlightFontObject("GameFontHighlightSmall")
    function b.SetSelected(self, on)
        self.selected = on and true or false
        if on then
            fill:SetColorTexture(0.85, 0.68, 0.3, 0.35)
            for _, e in ipairs(sides) do e:SetColorTexture(1, 0.82, 0, 0.9) end
        else
            fill:SetColorTexture(0.12, 0.12, 0.14, 0.9)
            for _, e in ipairs(sides) do e:SetColorTexture(0.45, 0.45, 0.48, 0.9) end
        end
        self:SetNormalFontObject(on and "GameFontHighlightSmall" or "GameFontNormalSmall")
    end
    local setText = b.SetText
    function b.SetText(self, t)
        setText(self, t)
        self:SetWidth(math.ceil(textWidth(t)) + 20)
    end
    b:SetText(text)
    b:SetSelected(false)
    b:SetScript("OnClick", onClick)
    if tooltip then Widgets.Tooltip(b, text, tooltip) end
    return b
end

--- A dropdown: a field that shows its value, with a down arrow at its right end; a click opens a list of check
--- boxes under it. The game's dropdown look (`WowStyle1DropdownTemplate`) where the client has it, else a dark
--- field with a grey edge and the game's dropdown arrow. Never a red button.
--- options = { {value, label}, ... }; get(value) -> bool; set(value, bool). `summary(names, total)` (optional)
--- gives the field's text from the ticked names. `tooltip`, `title`: the help on hover.
--- d:Update() shows the values again (call it on refresh); d:Close() closes the list;
--- d:SetOptions(options, menuWidth) changes the choices (the list may be wider than the field);
--- d.list, d.checks: the list and its check boxes. One choice only: call d:Close() in `set`.
function Widgets.Dropdown(parent, width, options, get, set, tooltip, title, summary)
    local b = fromTemplate("DropdownButton", parent, "WowStyle1DropdownTemplate", { "Text", "Arrow" })
    local label
    if b then
        b.template = true
        label = b.Text
        b:SetHeight(FIELD_H + 3)
    else
        b = CreateFrame("Button", nil, parent)
        b:SetHeight(FIELD_H)
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.75)
        edges(b, 0.55, 0.55, 0.55, 1)
        local hl = b:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.06)
        b:SetNormalFontObject("GameFontHighlightSmall")
        b:SetText(" ")
        label = b.GetFontString and b:GetFontString()
        local arrow = b:CreateTexture(nil, "OVERLAY")
        arrow:SetSize(18, 18)
        arrow:SetTexture("Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up")
        arrow:SetPoint("RIGHT", b, "RIGHT", -2, 0)
        b.Arrow = arrow
        if type(label) == "table" then
            label:ClearAllPoints()
            label:SetPoint("LEFT", b, "LEFT", 7, 0)
            label:SetJustifyH("LEFT")
            label:SetWordWrap(false)
        end
    end
    b.uiKind, b.maxWidth = "dropdown", width
    b:SetWidth(width)
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
    function b.Update(self)
        local names = {}
        for i, o in ipairs(options) do
            local on = get(o[1]) and true or false
            checks[i]:SetChecked(on)
            if on then names[#names + 1] = o[2] end
        end
        local text = summary and summary(names, #options) or (#names > 0 and table.concat(names, ", ") or "none")
        self:SetText(text)
        -- As wide as its text needs (and the arrow), never wider than the width asked for.
        local measured
        if type(label) == "table" then
            label:SetWidth(0)   -- (measure the whole text, not the cut one)
            local measure = label.GetUnboundedStringWidth or label.GetStringWidth
            measured = tonumber((measure(label)))
        end
        local w = math.max(64, math.min(width, math.ceil(measured or textWidth(text)) + 34))
        self:SetWidth(w)
        if type(label) == "table" then label:SetWidth(w - 32) end
    end
    function b.SetOptions(_, opts, menuWidth)
        options = opts
        list:SetSize(menuWidth or width, #options * 22 + 12)
        for i, o in ipairs(options) do
            local c = checks[i]
            if not c then
                c = Widgets.Check(list, o[2], nil, function(on)
                    set(options[i][1], on)
                    b:Update()
                end)
                c:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -6 - (i - 1) * 22)
                checks[i] = c
            end
            c.label:SetText(o[2])
            c:Show()
        end
        for i = #options + 1, #checks do checks[i]:Hide() end
    end
    b:SetOptions(options)
    b:SetScript("OnClick", function() list:SetShown(not list:IsShown()) end)
    b:HookScript("OnHide", function() list:Hide() end)
    function b.Close() list:Hide() end
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
-- (The old name, for code not moved yet.)
Widgets.CheckDropdown = Widgets.Dropdown

--- A row of controls of one kind, left to right (and right to left from its right end), as UI.md Controls 1 orders
--- them: kind = "tabs" (tabs only, on a line that the selected tab joins), "subtabs" (subtabs only), "filters"
--- (a label at the left of each filter; the table's actions at the right end), "footer" (status at the left,
--- the window's actions at the right). bar:Place(top) puts it `top` px under the window's top edge,
--- bar:PlaceBottom(bottom) above its bottom edge; bar:Add(region, width, gap) adds at the left, bar:AddRight(region,
--- width, gap) at the right; bar:AddFilter(text, control, width, help) adds a filter with its label (returns the
--- label and its help area);
--- bar:AddCheck(check) a check box with its label on its right. bar.used = the width it needs (the specs keep it
--- within the window's smallest width). Hide the bar to hide its row.
local BAR_H = { tabs = 30, subtabs = 24, filters = 26, footer = 28 }
Widgets.BAR_H = BAR_H
function Widgets.Bar(parent, kind, height)
    local bar = CreateFrame("Frame", nil, parent)
    bar.uiKind = kind == "footer" and "footer" or (kind:gsub("s$", "") .. "row")
    bar.kind = kind
    bar:SetHeight(height or BAR_H[kind] or 24)
    bar.used, bar.items = 0, {}
    local last, lastRight
    local bottom = kind == "tabs"   -- (tabs stand on the row's line)
    if bottom then
        local base = bar:CreateTexture(nil, "BACKGROUND")
        base:SetPoint("BOTTOMLEFT", bar, "BOTTOMLEFT", 0, 0)
        base:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", 0, 0)
        base:SetHeight(1)
        base:SetColorTexture(0.85, 0.68, 0.3, 0.7)
    end
    function bar.Place(self, top, left, right)
        self:ClearAllPoints()
        self:SetPoint("TOPLEFT", parent, "TOPLEFT", left or 10, -top)
        self:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -(right or 10), -top)
        self.top = top
        return self
    end
    function bar.PlaceBottom(self, y, left, right)
        self:ClearAllPoints()
        self:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", left or 10, y)
        self:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -(right or 10), y)
        self.bottom = y
        return self
    end
    function bar.Add(self, region, width, gap)
        gap = gap or (kind == "tabs" and 2 or kind == "subtabs" and 6 or 8)
        region:ClearAllPoints()
        if bottom then
            if last then region:SetPoint("BOTTOMLEFT", last, "BOTTOMRIGHT", gap, 0)
            else region:SetPoint("BOTTOMLEFT", self, "BOTTOMLEFT", 4, 0) end
        else
            if last then region:SetPoint("LEFT", last, "RIGHT", gap, 0)
            else region:SetPoint("LEFT", self, "LEFT", 2, 0) end
        end
        self.used = self.used + (last and gap or 2) + (width or tonumber(region:GetWidth()) or 0)
        last = region
        self.items[#self.items + 1] = region
        return region
    end
    function bar.AddRight(self, region, width, gap)
        gap = gap or 6
        region:ClearAllPoints()
        if lastRight then region:SetPoint("RIGHT", lastRight, "LEFT", -gap, 0)
        else region:SetPoint("RIGHT", self, "RIGHT", -2, 0) end
        -- (+ 12: the least gap between the left and the right parts)
        self.used = self.used + (lastRight and gap or 2) + (width or tonumber(region:GetWidth()) or 0) + (lastRight and 0 or 12)
        lastRight = region
        self.items[#self.items + 1] = region
        return region
    end
    function bar.AddLabel(self, text, gap)
        local l = Widgets.Label(self, text, "GameFontHighlightSmall")
        return self:Add(l, textWidth(text), gap)
    end
    function bar.AddFilter(self, text, control, width, help)
        local l = self:AddLabel(text, last and 16 or nil)
        self:Add(control, width, 6)
        return l, help and Widgets.HelpArea(self, l, text, help) or nil
    end
    function bar.AddCheck(self, check, gap)
        self:Add(check, 24 + 2 + textWidth(check.label and check.label:GetText()), gap or (last and 14 or nil))
        last = check.label or check
        return check
    end
    return bar
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

--- The addon's version at the left end of a window's title bar, small and dim, centered on the bar's height.
--- It is left out where it would come near the centered title at the window's smallest width (`minW`).
function Widgets.TitleVersion(f, title, minW)
    local v = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    v:SetText("v" .. ns.VERSION)
    local bar = f.TitleBg
    if type(bar) == "table" then
        v:SetPoint("LEFT", bar, "LEFT", 6, 0)
    else
        v:SetPoint("LEFT", f, "TOPLEFT", 8, -12)   -- (the bar of the frame template: 3 px down, 18 high)
    end
    -- Each measured in its own font (the title's is larger); where the client cannot measure, it stays.
    local function width(fs)
        local measure = fs.GetUnboundedStringWidth or fs.GetStringWidth
        return tonumber((measure(fs)))
    end
    local own, other = width(v), width(title)
    if own and other and 8 + own + 12 > (minW - other) / 2 then v:Hide() end
    f.versionText = v
    return v
end

-- A window can be dragged partly off the screen, until only this much of its title bar is left on it (SDD 98).
Widgets.ON_SCREEN, Widgets.TITLE_H = 40, 24

--- The clamp rect of a window: the client keeps it on the screen. Its left edge is ON_SCREEN px left of the
--- window's right edge and its right edge ON_SCREEN px right of the window's left edge (the rect is turned
--- inside out), so the window goes off the left or the right side until ON_SCREEN px are left. The top stays on
--- the screen, and the window goes down until only its title bar is left. Call it again when the size changes.
function Widgets.ClampToTitle(f)
    local w, h = tonumber(f:GetWidth()) or 0, tonumber(f:GetHeight()) or 0
    local side = math.max(0, math.floor(w - Widgets.ON_SCREEN))
    f:SetClampRectInsets(side, -side, 0, math.max(0, math.floor(h - Widgets.TITLE_H)))
end

-- Every movable window, for `/salv windows reset`: { frame, reset = function() puts it at its default place }.
Widgets.windows = {}

--- Brings every Salvager window back to its default place, fully on the screen (built or not).
function Widgets.ResetWindows()
    for _, w in ipairs(Widgets.windows) do w.reset() end
    -- Windows not built yet open at their default place too. (The "Salvager" button on the auction house is
    -- not a window: it keeps its place.)
    for key, saved in pairs(ns.db.windows) do
        if type(saved) == "table" and key ~= "ahButton" then saved.x, saved.y, saved.dx, saved.dy = nil, nil, nil, nil end
    end
    local main = ns.db.window   -- (the main window's place)
    if type(main) == "table" then main.point, main.rel, main.x, main.y = nil, nil, nil, nil end
end

--- A window of its own: movable, resizable from the bottom right corner (unless `fixed`), closed with Escape.
--- Its place and size are kept in SalvagerDB.windows[key]. f.onResize runs when the size changes.
function Widgets.Window(globalName, title, key, w, h, minW, minH, fixed)
    local f = CreateFrame("Frame", globalName, UIParent, "BasicFrameTemplateWithInset")
    local saved = ns.db.windows[key] or {}
    ns.db.windows[key] = saved
    f.saved = saved
    -- fixed = "vertical": the width is always `w` (it fits the content); only the height can change.
    local vertical = fixed == "vertical"
    if vertical then fixed = false end
    f.minWidth = (fixed or vertical) and w or minW   -- (the narrowest it gets: its rows must fit it, UI.md Layout 6)
    f:SetSize(vertical and w or math.max(minW, saved.w or w), math.max(minH, saved.h or h))
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    Widgets.ClampToTitle(f)
    f:SetMovable(true)
    f:EnableMouse(true)
    if saved.x and saved.y then
        f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", saved.x, saved.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", saved.dx or 0, saved.dy or 0)
    end
    Widgets.windows[#Widgets.windows + 1] = { frame = f, reset = function()
        saved.x, saved.y, saved.dx, saved.dy = nil, nil, nil, nil
        f:ClearAllPoints()
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end }
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
    Widgets.TitleVersion(f, text, (fixed or vertical) and w or minW)
    tinsert(UISpecialFrames, globalName)
    -- Who opened it (UI.md Layout 5): "main" = shown while the main window is (it closes with it and comes back
    -- with it), "panel" = opened from the mini panel or with the main window closed (it stays on its own).
    -- `Widgets.Opener()` (set by the main window) tells which; the owner is cleared when the window hides.
    f:HookScript("OnShow", function()
        if rawget(f, "owner") == nil then f.owner = Widgets.Opener and Widgets.Opener() or "main" end
    end)
    f:HookScript("OnHide", function() f.owner = nil end)
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
        Widgets.ClampToTitle(f)
        f:SetScript("OnSizeChanged", function()
            Widgets.ClampToTitle(f)
            if f.onResize then f.onResize() end
        end)
        -- A fixed window that fits its tables: exactly that wide.
        function f.FitWidth(width) f:SetWidth(width) end
        f:Hide()
        return f
    end

    f:SetResizable(true)
    local maxW, maxH = UIParent:GetWidth(), UIParent:GetHeight()
    if vertical then minW, maxW = w, w end
    if f.SetResizeBounds then
        f:SetResizeBounds(minW, minH, maxW, maxH)
    elseif f.SetMinResize then
        f:SetMinResize(minW, minH)
        if vertical and f.SetMaxResize then f:SetMaxResize(maxW, maxH) end
    end
    -- A window whose width fits its content: the content sets it (and the player still sizes the height).
    -- The bounds first: the client keeps a frame inside its resize bounds, SetWidth included (SDD 91).
    -- A window sized both ways: `width` is its smallest width from now on (the player can make it wider), and
    -- it widens to it when narrower.
    function f.FitWidth(width)
        if vertical then
            if f.SetResizeBounds then
                f:SetResizeBounds(width, minH, width, maxH)
            elseif f.SetMaxResize then
                f:SetMinResize(width, minH)
                f:SetMaxResize(width, maxH)
            end
            f:SetWidth(width)
            return
        end
        if f.SetResizeBounds then
            f:SetResizeBounds(width, minH, math.max(width, maxW), maxH)
        elseif f.SetMinResize then
            f:SetMinResize(width, minH)
        end
        f.minWidth = width
        if (f:GetWidth() or 0) < width then f:SetWidth(width) end
    end
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        pin()
        f:StartSizing(vertical and "BOTTOM" or "BOTTOMRIGHT", true)
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        saved.w, saved.h = math.floor(f:GetWidth()), math.floor(f:GetHeight())
        pin()
        if f.onResize then f.onResize() end
    end)
    f:SetScript("OnSizeChanged", function()
        Widgets.ClampToTitle(f)
        if f.onResize then f.onResize() end
    end)
    f:Hide()
    return f
end

--- The screen's width in the UI's units: no window fits its tables wider than this (SDD 91, 107).
function Widgets.ScreenWidth()
    return tonumber((UIParent:GetWidth())) or tonumber((GetScreenWidth and GetScreenWidth())) or 1024
end

--- A window that fits its tables (SDD 107, UI.md Tables 2): at least `base` wide, and as wide as each of `lists`
--- needs to leave no column out (`list.fitWidth`, plus the room around the list in the window), at most the
--- screen. Only where the screen is too narrow does a table leave columns out, and its note says so.
--- @return boolean changed  the width changed: refresh the lists again
function Widgets.FitTables(f, base, lists)
    local w = base
    local fw = tonumber((f:GetWidth())) or 0
    for _, l in ipairs(lists) do
        local n, lw = rawget(l, "fitWidth"), tonumber((l:GetWidth()))
        if type(n) == "number" and lw and lw > 0 then w = math.max(w, math.ceil(n + fw - lw)) end
    end
    w = math.min(w, math.floor(Widgets.ScreenWidth()))
    local before = fw
    f.FitWidth(w)
    return math.abs((tonumber((f:GetWidth())) or 0) - before) >= 1
end

function Widgets.Label(parent, text, template)
    local l = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
    l:SetText(text)
    return l
end

--- The arrow of a group heading that opens and closes (UI.md Tables 15), one look in every table: the game's gold
--- arrow, pointing right while the heading is closed and down while it is open. `t` = a texture; t.open keeps it.
local GROUP_ARROW = "Interface\\ChatFrame\\ChatFrameExpandArrow"
function Widgets.GroupArrow(t, open)
    t:SetTexture(GROUP_ARROW)
    -- Down: the right arrow turned a quarter clockwise (the corners' texture points: UL, LL, UR, LR).
    if open then t:SetTexCoord(0, 1, 1, 1, 0, 0, 1, 0) else t:SetTexCoord(0, 1, 0, 1) end
    t.open = open and true or false
end

--- How wide a text is on screen (small font), in pixels; nil where the client cannot tell.
--- Tables use it so a column is as wide as its widest text, and no wider.
local meter, widthOf, cached = nil, {}, 0
function Widgets.TextWidth(text)
    if text == nil or text == "" then return 0 end
    local w = widthOf[text]
    if w ~= nil then return w or nil end
    if not meter then
        meter = UIParent:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        meter:Hide()
    end
    meter:SetText(text)
    local measure = meter.GetUnboundedStringWidth or meter.GetStringWidth
    w = tonumber((measure(meter)))
    if cached > 4000 then widthOf, cached = {}, 0 end
    widthOf[text], cached = w or false, cached + 1
    return w
end

--- A sample text with every digit made the widest digit of the font: "00:00:00" -> the widest countdown.
--- @return string|nil  nil when the client cannot measure text
function Widgets.WidestDigits(sample)
    local digit, most = nil, -1
    for d = 0, 9 do
        local w = Widgets.TextWidth(tostring(d))
        if not w then return nil end
        if w > most then digit, most = tostring(d), w end
    end
    return (sample:gsub("%d", digit))
end

--- The widths a table's columns need: the widest of the title and the texts of each column, plus `pad`.
--- @param titles table  the column titles
--- @param count number, cellsOf function(i) -> cells, extra (pixels before the first column's text)
--- @param samples table|nil  per column, the widest text it can hold (digits count as the widest digit),
---                           so a column whose values change (a countdown) keeps its width
--- @return table|nil  widths per column; nil when the client cannot measure text
function Widgets.FitColumns(titles, count, cellsOf, pad, samples)
    local need = {}
    for i, title in ipairs(titles) do
        local w = Widgets.TextWidth(title)
        if not w then return nil end
        local sample = samples and samples[i] and Widgets.WidestDigits(samples[i])
        local s = sample and Widgets.TextWidth(sample) or 0
        if not s then return nil end
        need[i] = math.max(w, s)
    end
    for r = 1, math.min(count, 400) do
        local cells, extra = cellsOf(r)
        for i = 1, #titles do
            local w = cells and Widgets.TextWidth(cells[i]) or 0
            if not w then return nil end
            if i == 1 then w = w + (extra or 0) end
            if w > need[i] then need[i] = w end
        end
    end
    for i = 1, #titles do need[i] = math.ceil(need[i]) + (pad or 10) end
    return need
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

-- Salvager: small UI building blocks shared by the window and the options panel.
local _, ns = ...

local Util = ns.Util

local Widgets = {}
ns.Widgets = Widgets

--- An action button; `name`: its global name (a macro's /click finds it: Buy Top, SDD 127).
function Widgets.Button(parent, text, width, onClick, tooltip, name)
    local b = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
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
        -- (Each explanation on its own line, one empty line between: Widgets.Explanations, UI.md Words 4.)
        local lines = Widgets.Explanations(getLines())
        head:SetText(type(title) == "function" and title() or title)
        body:SetText(table.concat(lines, "\n\n"))
        panel:SetHeight((tonumber(body:GetStringHeight()) or (#lines * 32)) + 44)
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

--- A help's explanations (UI.md Words 4, the user 2026-11-28: "every explanation on its own line, one empty line
--- between"): each argument a text or a list of texts (a function gives one when the help shows); each text is cut
--- into its paragraphs ("\n") and its sentences (". " before a capital letter), one explanation each, the words kept.
function Widgets.Explanations(...)
    local out = {}
    local function add(text)
        if type(text) == "function" then text = text() end
        if type(text) == "table" then for _, t in ipairs(text) do add(t) end return end
        if text == nil then return end
        text = tostring(text)
        for para in (text .. "\n"):gmatch("(.-)\n") do
            -- (". " then a capital letter starts the next explanation; a sentence keeps its full stop.)
            local s = para:gsub("([%.!?])%s+(%u)", "%1\0%2")
            for part in (s .. "\0"):gmatch("(.-)%z") do
                part = part:gsub("^%s+", ""):gsub("%s+$", "")
                if part ~= "" then out[#out + 1] = part end
            end
        end
    end
    for i = 1, select("#", ...) do add((select(i, ...))) end
    return out
end

--- Fills `tip` (GameTooltip) with a help: its title in white, then each explanation on its own line (wrapped), one
--- empty line between them, none after the last. `r, g, b`: the explanations' color (gold by default). The one help
--- builder of every hover help: Widgets.Tooltip, HelpArea, the tables' titles and rows, the cards, the "?" buttons.
function Widgets.AddHelp(tip, title, text, r, g, b)
    if title ~= nil then tip:SetText(tostring(title), 1, 1, 1) end
    for i, line in ipairs(Widgets.Explanations(text)) do
        -- (Added to a help on show: a blank line after its lines, not right under its title.)
        if i > 1 or (title == nil and tip.NumLines and (tip:NumLines() or 0) > 1) then tip:AddLine(" ") end
        tip:AddLine(line, r or 1, g or 0.82, b or 0, true)
    end
end

--- Shows a title and text when the mouse is over `frame`.
function Widgets.Tooltip(frame, title, text)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        Widgets.AddHelp(GameTooltip, title, text)
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

-- (Widgets.Choice, a row of check boxes where exactly one is on, went in 0.4.0: one of several values is a one-choice
-- dropdown, Widgets.Dropdown with `single`; a check box is an on/off setting only, UI.md Controls 2.)

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
            Widgets.AddHelp(GameTooltip, nil, tooltip)
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
-- (The gold box holds three digits: up to 999 gold.)
local BOX_W, SMALL_W, COIN, COIN_GAP, NEXT_GAP, LEFT_PAD = 36, 30, 13, 3, 11, 6
--- The width of Widgets.Money's frame (a control: a true constant; a table column that holds one is that wide).
Widgets.MONEY_W = LEFT_PAD + BOX_W + 2 * SMALL_W + 3 * (COIN_GAP + COIN) + 2 * NEXT_GAP + 2
function Widgets.Money(parent, onChange)
    -- Layout: [box] coin  [box] coin  [box] coin. Each coin sits right after its own box, and the
    -- frame is as wide as all of it, so whatever comes next starts after the last coin.
    local frame = CreateFrame("Frame", nil, parent)
    frame.uiKind = "edit"
    frame:SetSize(Widgets.MONEY_W, 20)
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
--- d.list, d.checks: the list and its check boxes (its rows). `single` (UI.md Controls 2): one choice: the list is
--- plain rows, no check boxes, the current value tinted with a marker; a click picks it and closes the list. Check
--- boxes are for a dropdown of many choices only (and a lone on/off setting is one check box, not a dropdown).
function Widgets.Dropdown(parent, width, options, get, set, tooltip, title, summary, single)
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
        b.uiKind, b.maxWidth, b.title, b.summary = "dropdown", width, title, summary   -- (the fit spec reads them)
    b.single = single and true or nil
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
        if single then names = { names[1] } end
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
        -- A row of a one-choice list: the whole width is the click target, the current one tinted with a gold marker.
    local function optionRow(i)
        local r = CreateFrame("Button", nil, list)
        r.uiKind = "option"
        r:SetHeight(20)
        r:SetPoint("TOPLEFT", list, "TOPLEFT", 6, -6 - (i - 1) * 22)
        r:SetPoint("TOPRIGHT", list, "TOPRIGHT", -6, -6 - (i - 1) * 22)
        local hl = r:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.10)
        local tint = r:CreateTexture(nil, "BACKGROUND")
        tint:SetAllPoints()
        tint:SetColorTexture(1, 0.82, 0, 0.16)
        local mark = r:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        mark:SetPoint("LEFT", r, "LEFT", 4, 0)
        mark:SetText("|cffffd100>|r")
        r.label = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        r.label:SetPoint("LEFT", r, "LEFT", 16, 0)
        r.label:SetJustifyH("LEFT")
        r.label:SetWordWrap(false)
        function r.SetChecked(_, on)
            r.selected = on and true or false
            tint:SetShown(r.selected)
            mark:SetShown(r.selected)
        end
        function r.GetChecked() return r.selected end
        r:SetChecked(false)
        r:SetScript("OnClick", function()
            set(options[i][1], true)
            list:Hide()
            b:Update()
        end)
        return r
    end
    function b.SetOptions(_, opts, menuWidth)
        options = opts
        b.options = opts
        -- (The list as wide as its widest option: never a cut label, UI.md Tables 2.)
        local widest = 0
        for _, o in ipairs(options) do widest = math.max(widest, Widgets.TextWidth(o[2], "GameFontHighlightSmall") or 0) end
        list:SetSize(math.max(menuWidth or width, math.ceil(widest) + (single and 16 + 12 or 8 + 26 + 12)),
            #options * 22 + 12)
        for i, o in ipairs(options) do
            local c = checks[i]
            if not c then
                if single then
                    c = optionRow(i)
                else
                    c = Widgets.Check(list, o[2], nil, function(on)
                        set(options[i][1], on)
                        b:Update()
                    end)
                    c:SetPoint("TOPLEFT", list, "TOPLEFT", 8, -6 - (i - 1) * 22)
                end
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
local CUT_MIN = 120   -- the room a text that may be cut keeps in a row of controls (bar:Need)
Widgets.BAR_H = BAR_H
function Widgets.Bar(parent, kind, height)
    local bar = CreateFrame("Frame", nil, parent)
    bar.uiKind = kind == "footer" and "footer" or (kind:gsub("s$", "") .. "row")
    bar.kind = kind
    bar:SetHeight(height or BAR_H[kind] or 24)
    bar.used, bar.items, bar.parts = 0, {}, {}
    local last, lastRight
    -- Every region of the row and its side ("L": placed from the left end, "R": from the right end), for bar:Need.
    function bar.Track(self, region, side)
        self.parts[#self.parts + 1] = { region = region, side = side or "L" }
        return region
    end
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
        self.top, self.inset = top, (left or 10) + (right or 10)
        return self
    end
    function bar.PlaceBottom(self, y, left, right)
        self:ClearAllPoints()
        self:SetPoint("BOTTOMLEFT", parent, "BOTTOMLEFT", left or 10, y)
        self:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -(right or 10), y)
        self.bottom, self.inset = y, (left or 10) + (right or 10)
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
        self:Track(region, "L")
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
        self:Track(region, "R")
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
        if check.label then self:Track(check.label, "L") end
        last = check.label or check
        return check
    end
    --- The width the row needs now (the width authority, Widgets.ContentWidth): measured from what it shows, the
    --- regions placed from the left to the right end of the last one shown, those placed from the right likewise,
    --- 12 px between the two parts. Where the client has not placed them yet: `used` (every region, shown or not).
    function bar.Need(self)
        local l, r = self:GetLeft(), self:GetRight()
        if not (l and r) then return self.used end
        local left, right = 0, 0
        for _, part in ipairs(self.parts) do
            local x = part.region
            if x:IsShown() and (tonumber((x:GetWidth())) or 0) > 0 then
                -- (A text counts as wide as it is, not its box: a status line may be stretched to the row's end.)
                local text = x.GetObjectType and x:GetObjectType() == "FontString"
                    and tonumber(((x.GetUnboundedStringWidth or x.GetStringWidth)(x))) or nil
                -- (A text that may be cut, "..." at the next control, holds the row at CUT_MIN at most.)
                if text and rawget(x, "canCut") then text = math.min(text, CUT_MIN) end
                if part.side == "L" then
                    local xl, xr = x:GetLeft(), x:GetRight()
                    if text and xl then xr = xl + text end
                    if xr then left = math.max(left, xr - l) end
                else
                    local xl, xr = x:GetLeft(), x:GetRight()
                    if text and xr then xl = xr - text end
                    if xl then right = math.max(right, r - xl) end
                end
            end
        end
        return math.ceil(left + right + ((left > 0 and right > 0) and 12 or 0) + (left > 0 and right == 0 and 2 or 0))
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
-- The room a window's title needs on each side of its text: the close button and its margins.
local TITLE_ROOM = 36
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
    f.versionText, f.titleText = v, title
    f.titleNeed = other and math.ceil(other + 2 * TITLE_ROOM) or nil
    return v
end

--- The version shows where it stays 12 px clear of the title at the window's width now (a window that fits its
--- content changes width with the view).
function Widgets.FitVersion(f, w)
    local v, title = rawget(f, "versionText"), rawget(f, "titleText")
    if not (v and title) then return end
    local own = tonumber(((v.GetUnboundedStringWidth or v.GetStringWidth)(v)))
    local other = tonumber(((title.GetUnboundedStringWidth or title.GetStringWidth)(title)))
    if own and other then v:SetShown(8 + own + 12 <= (w - other) / 2) end
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
    f.titleText = text   -- (the specs read it)
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
        function f.FitWidth(width)
            f:SetWidth(width)
            f.fitNeed, f.minWidth = width, width
            Widgets.FitVersion(f, width)
        end
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
    -- `view`: the view on show (a tab, a subtab, the material shown); a new one is a view change (SDD 113).
    -- A window sized both ways (SDD 113): `width` (what the view's tables need) is its widest width, and its width
    -- after a view change; the player can make it narrower, down to its smallest width (`minW`), until the next view
    -- change. With `f.fitGrows` (a window with a chart: Market), `width` is its smallest width instead (the player can
    -- make it wider, and that width stays); a width it only had from the fit shrinks back on a view change.
    local function bounds(lo, hi)
        if f.SetResizeBounds then
            f:SetResizeBounds(lo, minH, hi, maxH)
        elseif f.SetMinResize then
            f:SetMinResize(lo, minH)
            if f.SetMaxResize then f:SetMaxResize(hi, maxH) end
        end
    end
    -- `least`: the narrowest the view's tables allow (a stack of cards: one per row), when more than `minW`.
    function f.FitWidth(width, view, least)
        if vertical then
            bounds(width, width)
            f:SetWidth(width)
            f.fitNeed, f.minWidth = width, width
            Widgets.FitVersion(f, width)
            return
        end
        local changed = view ~= rawget(f, "fitView")
        f.fitView = view
        local now = tonumber((f:GetWidth())) or 0
        local lo, hi, want
        if rawget(f, "fitGrows") then
            lo, hi = width, math.max(width, maxW)
            if changed and not rawget(f, "userW") then want = width else want = math.max(now, width) end
        else
            -- (The smallest width is the content's measured one, `least`: no constant holds it wider.)
            lo = least or minW
            hi = math.max(lo, width)
            if changed then f.userW = nil end
            want = math.max(lo, math.min(hi, rawget(f, "userW") or hi))
        end
        bounds(lo, hi)
        f.minWidth, f.fitNeed = lo, (not rawget(f, "fitGrows")) and hi or nil
        Widgets.FitVersion(f, want)
        -- (While the player drags the corner, only the bounds change: the drag sets the width.)
        if not rawget(f, "sizing") and math.abs(now - want) >= 1 then f:SetWidth(want) end
    end
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    local startW
    grip:SetScript("OnMouseDown", function()
        pin()
        startW = tonumber((f:GetWidth()))
        f.sizing = true
        f:StartSizing(vertical and "BOTTOM" or "BOTTOMRIGHT", true)
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        f.sizing = nil
        saved.w, saved.h = math.floor(f:GetWidth()), math.floor(f:GetHeight())
        -- The width the player chose (SDD 113): kept until the next view change (with `fitGrows`, kept).
        if not vertical and startW and math.abs(startW - (tonumber((f:GetWidth())) or 0)) >= 1 then f.userW = saved.w end
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

------------------------------------------------------------------ the width authority (UI.md Tables 2, SDD 120)
-- Every table's column widths and every window's width come from here, from what they show now, measured:
--   a column = its widest text now (title with its sort arrow, the rows on show and in the data) + CELL_PAD;
--   columns are COL_GAP apart, so the texts of two columns next to each other are NORMAL_GAP (± 2) apart;
--   a window = its widest row of content now: a table's columns, a row of controls (bar:Need), its title, a block
--   (f.extraNeed); never a constant. A window wider than that by more than SLACK, or a gap wider than NORMAL_GAP +
--   GAP_TOL (beyond what the first column takes where controls force the width), is a bug: Widgets.CheckLayout logs it.
Widgets.CELL_PAD, Widgets.COL_GAP = 2, 14
Widgets.NORMAL_GAP = Widgets.CELL_PAD + Widgets.COL_GAP

--- The space between the boxes of two columns next to each other (justified `a`, then `b`), so that their texts
--- are NORMAL_GAP apart whatever their justification: a box's CELL_PAD is at the side its text does not touch
--- (a left-justified text's right, a right-justified text's left, half each side of a centred one).
local function padRight(j) return (j == "RIGHT") and 0 or (j == "CENTER" and Widgets.CELL_PAD / 2 or Widgets.CELL_PAD) end
local function padLeft(j) return (j == "RIGHT") and Widgets.CELL_PAD or (j == "CENTER" and Widgets.CELL_PAD / 2 or 0) end
function Widgets.ColumnGap(a, b) return Widgets.NORMAL_GAP - padRight(a or "LEFT") - padLeft(b or "LEFT") end
Widgets.SLACK, Widgets.GAP_TOL = 8, 4

--- The text a table cell shows: money of 1 gold or more as gold and silver (Util.ShortMoneyText; the full amount is
--- on the row's hover, Widgets.AddExactLines). Measured and drawn alike.
local shortOf, shortN = {}, 0
function Widgets.CellText(text)
    if type(text) ~= "string" then return text == nil and "" or tostring(text) end
    local hit = shortOf[text]
    if hit then return hit end
    local short = Util.ShortMoneyText(text)
    if shortN > 4000 then shortOf, shortN = {}, 0 end
    shortOf[text], shortN = short, shortN + 1
    return short
end

local function exactCells(cols, data)
    local out = {}
    if type(data) ~= "table" or type(data.cells) ~= "table" then return out end
    for i, text in ipairs(data.cells) do
        if type(text) == "string" and Widgets.CellText(text) ~= text then
            local col = cols and cols[i]
            local title = col and (type(col) == "table" and Widgets.ColumnKey(col) or col) or ""
            out[#out + 1] = { tostring(title), text }
        end
    end
    return out
end
--- Has the row a cell shown short, or a note?
function Widgets.HasExactLines(cols, data)
    return #exactCells(cols, data) > 0 or (type(data) == "table" and type(data.notes) == "table" and #data.notes > 0)
end
--- Adds to a tooltip the full amounts of the row's cells shown short, and its notes (data.notes: lines, the
--- explanation of a "*" in a cell).
function Widgets.AddExactLines(tip, cols, data)
    for _, x in ipairs(exactCells(cols, data)) do tip:AddDoubleLine(x[1], x[2], 1, 0.82, 0, 1, 1, 1) end
    if type(data) == "table" and type(data.notes) == "table" then
        for _, line in ipairs(data.notes) do tip:AddLine(line, 0.5, 0.5, 0.5, true) end
    end
end

--- What the window's controls need now: each row of controls on show (bar:Need and its insets), its title with
--- the close button, and f.extraNeed() (a block that is not a row: the main window's settings).
function Widgets.ControlsWidth(f)
    local w = rawget(f, "titleNeed") or 0
    for _, c in ipairs({ f:GetChildren() }) do
        if type(rawget(c, "parts")) == "table" and rawget(c, "inset") and c:IsShown() then
            w = math.max(w, c:Need() + c.inset)
        end
    end
    local extra = rawget(f, "extraNeed")
    if extra then w = math.max(w, tonumber((extra())) or 0) end
    return math.ceil(w)
end

--- A window that fits its content (SDD 107, 113, 120, UI.md Tables 2): as wide as its widest row of content needs
--- now: each of `lists` with all its columns, the first in full (`list.neededWidth`, plus the room around it:
--- `list.margin`, 24), its controls (Widgets.ControlsWidth), and `extra` (a width computed by the window from
--- measured parts: the Market's chart). At most the screen. Its smallest width is its controls' (and one card per row
--- for a stack of cards); narrower, a table leaves columns out with its note. `view` names the view on show: after a
--- change the window takes the new view's width (narrower too). Then the self-check (Widgets.CheckLayout).
--- @return boolean changed  the width changed (the lists are laid out again already)
function Widgets.FitTables(f, lists, view, extra)
    local controls = Widgets.ControlsWidth(f)
    local w, least = math.max(controls, extra or 0), controls
    for _, l in ipairs(lists) do
        local margin = rawget(l, "margin") or 24
        local n = rawget(l, "neededWidth") or rawget(l, "fitWidth")
        if type(n) == "number" then w = math.max(w, math.ceil(n + margin)) end
        local lw = rawget(l, "leastWidth")
        if type(lw) == "number" then least = math.max(least, math.ceil(lw + margin)) end
        -- (An empty table's note is never cut, UI.md Tables 6: not at the smallest width either.)
        local note = rawget(l, "noteWidth")
        if type(note) == "number" and note > 0 then least = math.max(least, math.ceil(note + margin)) end
    end
    w = math.min(w, math.floor(Widgets.ScreenWidth()))
    local before = tonumber((f:GetWidth())) or 0
    f.contentNeed, f.fitLists = w, lists
    f.FitWidth(w, view, math.min(least, w))
    local changed = math.abs((tonumber((f:GetWidth())) or 0) - before) >= 1
    local trimmed = Widgets.TrimTables(f, lists)
    -- (A new width lays the tables out again here, so the check reads them as drawn.)
    for _, l in ipairs(lists) do if changed or trimmed[l] then l:Refresh() end end
    -- (`f.checkLater`: the window draws more after the fit, its chart: it runs the self-check itself, at the end.)
    if not rawget(f, "checkLater") then Widgets.CheckLayout(f, lists, view) end
    return changed
end

--- Moves the right edge of `l` (its anchors with a right point) `px` in from where its window put it. A window that
--- anchors the table again (its layout) puts it back to its full width: the offsets set last tell which.
--- @return boolean moved
function Widgets.TrimRight(l, px)
    if not (l.GetNumPoints and l.GetPoint) then return false end
    px = math.max(0, math.floor(px or 0))
    local set, old = rawget(l, "trimSet") or {}, rawget(l, "trim") or 0
    local points, moved, now = {}, false, {}
    for i = 1, tonumber((l:GetNumPoints())) or 0 do
        local point, rel, relPoint, x, y = l:GetPoint(i)
        if type(point) == "string" and point:find("RIGHT") then
            local base = (set[point] ~= nil and math.abs(set[point] - (x or 0)) < 0.01) and (x + old) or (x or 0)
            if math.abs(base - px - (x or 0)) >= 0.5 then moved = true end
            x = base - px
            now[point] = x
        end
        points[#points + 1] = { point, rel, relPoint, x or 0, y or 0 }
    end
    l.trim, l.trimSet = px, now
    if not moved then return false end
    l:ClearAllPoints()
    for _, p in ipairs(points) do l:SetPoint(p[1], p[2], p[3], p[4], p[5]) end
    return true
end

--- Every table spans its window (UI.md Tables 2, SDD 127, the user 2026-11-28: "No inset table should be shorter than
--- the total size of the window where it is"): two or more tables in a view are each as wide as the window's content,
--- the narrower one's first column (its row label) takes its spare room. (Until then, SDD 123, each was as wide as it
--- needed, at the left: this puts back the right edges an older saved layout moved in.)
--- @return table  the lists moved, as keys
function Widgets.TrimTables(_, lists)
    local out = {}
    for _, l in ipairs(lists or {}) do
        if Widgets.TrimRight(l, 0) then out[l] = true end
    end
    return out
end

--- The texts of a table's columns on screen, left to right: { { title, l, r }, ... } (each column's widest text: its
--- title, its cells on show, and `need`, the widest text of the data the width authority measured, on show or not,
--- placed in the column's box by its justification). `columns` = { { header = fs, cells = { fs, ... }, need = px,
--- title = text, box = true (a column of controls: the whole box) }, ... }.
local function drawnWidth(fs) return tonumber(((fs.GetUnboundedStringWidth or fs.GetStringWidth)(fs))) or 0 end
local function placed(fs, tw, justify)
    local l, r = fs:GetLeft(), fs:GetRight()
    if not (l and r) then return nil end
    tw = math.min(tw, r - l)
    local j = justify or fs:GetJustifyH()
    if j == "RIGHT" then return r - tw, r end
    if j == "CENTER" then return (l + r - tw) / 2, (l + r + tw) / 2 end
    return l, l + tw
end
local function textSpan(fs) return placed(fs, drawnWidth(fs)) end
function Widgets.ColumnSpans(columns)
    local out = {}
    for _, col in ipairs(columns) do
        local lo, hi
        local function add(a, b) if a then lo, hi = math.min(lo or a, a), math.max(hi or b, b) end end
        for _, fs in ipairs(col.cells or {}) do
            if fs:IsShown() and (fs:GetText() or "") ~= "" then add(textSpan(fs)) end
        end
        local h = col.header
        if h and h:IsShown() then
            if col.box then add(h:GetLeft(), h:GetRight()) end
            if (h:GetText() or "") ~= "" then add(textSpan(h)) end
            -- (The data's widest text sits as the cells do: a column's justification, not its title's.)
            if type(col.need) == "number" and col.need > 0 then add(placed(h, col.need, col.justify)) end
        end
        if lo then out[#out + 1] = { title = col.title or (h and h:GetText()) or "", l = lo, r = hi } end
    end
    return out
end

--- Measured against drawn (SDD 123): each text on show (titles and cells) measured as the width authority measures it
--- (Widgets.TextWidth in the font it drew it in, `fs.measureFont`) against what the client drew. The worst case over
--- 1 px, or nil: { title, text, measured, drawn }.
function Widgets.MeasureDrift(columns)
    local worst, most = nil, 1
    for _, col in ipairs(columns) do
        local function try(fs)
            local font = rawget(fs, "measureFont")
            local text = font and fs:IsShown() and fs:GetText()
            if not text or text == "" then return end
            local m = Widgets.TextWidth(text, font)
            if not m then return end
            local d = drawnWidth(fs)
            if math.abs(m - d) > most then
                most, worst = math.abs(m - d), { title = col.title or "", text = text, measured = m, drawn = d }
            end
        end
        if col.header then try(col.header) end
        for _, fs in ipairs(col.cells or {}) do try(fs) end
    end
    return worst
end

--- The columns of a Widgets.List on screen (its titles and the cells of the rows shown, and the widest text of each
--- column in the data, `list.textNeed`), for Widgets.ColumnSpans.
function Widgets.ListColumns(list)
    local cols = {}
    local headers, rows = rawget(list, "headers"), rawget(list, "rows")
    if not (headers and rows and list.columns) then return cols end
    local need = rawget(list, "textNeed") or {}
    for i, col in ipairs(list.columns) do
        if headers[i] and headers[i]:IsShown() then
            local cells = {}
            for _, row in ipairs(rows) do
                if row:IsShown() and row.data and not row.data.span then cells[#cells + 1] = row.cells[i] end
            end
            -- (A column of controls, `least`: its content is the whole box.)
            cols[#cols + 1] = { title = tostring(Widgets.ColumnKey(col)), header = headers[i], cells = cells,
                box = col.least ~= nil, need = need[i], justify = col[3] or "LEFT" }
        end
    end
    return cols
end

--- The layout problems of a table from its columns' spans: the gaps wider than NORMAL_GAP + GAP_TOL (the first
--- one may be `spare` wider: the room a window forced wider by its controls gives the first column).
--- @return number most  the largest gap over the normal one; table text  "Gear>Item level 53"
function Widgets.WideGaps(spans, spare)
    local most, parts = 0, {}
    for i = 2, #spans do
        local gap = spans[i].l - spans[i - 1].r
        local over = gap - Widgets.NORMAL_GAP - (i == 2 and (spare or 0) or 0)
        if over > Widgets.GAP_TOL then
            parts[#parts + 1] = string.format("%s>%s %d", spans[i - 1].title, spans[i].title, math.floor(gap + 0.5))
        end
        most = math.max(most, over)
    end
    return most, parts
end

--- The self-check (always on, cheap: after a window's fit, the titles and the rows on screen, with the widest text of
--- each column in the data): the window no wider than its content needs + SLACK; every column gap normal (the rows
--- not on show count as the width authority measured them; the first column may take what the controls give a table
--- alone in its view, never what another table gives it: two or more tables are each as wide as they need, UI.md
--- Tables 2); every text on show measured as drawn (Widgets.MeasureDrift, 1 px). One Log line per window and view per
--- session: "layout: <window>/<view> wider than its content by N px", "column gaps over 16 px: <title>><title> <px>",
--- "measured N px, drawn M px: <title> "<text>"". `f.layoutName` names the window (its key).
local logged, cutChecked = {}, {}
Widgets.layoutLogged, Widgets.cutChecked = logged, cutChecked

--- Every text of a window on show that the client cuts (SDD 127, the user 2026-11-28: "check that no text is
--- truncated"): each FontString of the window and of every frame in it, shown and with text, that IsTruncated() says
--- is cut, or that is one line and drawn wider than its box (by more than 1 px), or that lies outside the window. Only a
--- table cell with its full text on hover may end with "..." (`canCut`: a table's first cells). @return table  texts
function Widgets.CutTexts(f)
    local out = {}
    local fl, fr = f:GetLeft(), f:GetRight()
    local function check(fs, clip)
        if not (fs:IsVisible() and not rawget(fs, "canCut")) then return end
        local text = fs:GetText()
        if not text or text == "" then return end
        local l, r = fs:GetLeft(), fs:GetRight()
        -- (Scrolled away, under a frame that clips: not on screen, not checked.)
        if clip and l and r then
            local b, t = fs:GetBottom(), fs:GetTop()
            if r <= clip.l or l >= clip.r or (b and t and (t <= clip.b or b >= clip.t)) then return end
        end
        -- One line (no wrap, or one line of a wrapping text): cut where it is drawn wider than its box. More lines:
        -- where they need more height than its box has. A text with no box of its own (auto-sized): where the client
        -- says so. (Measured, not IsTruncated where a box is there: the sim says yes for texts that fit, the tabs'.)
        local lines = fs.GetNumLines and tonumber((fs:GetNumLines())) or 1
        local wraps = fs.GetWordWrap and fs:GetWordWrap()
        local cut
        if l and r and (r - l) > 1 and (not wraps or lines <= 1) then
            cut = drawnWidth(fs) > (r - l) + 1
        elseif l and r and (r - l) > 1 then
            local h = tonumber((fs:GetHeight())) or 0
            cut = h > 1 and (tonumber((fs:GetStringHeight())) or 0) > h + 1
        else
            cut = fs.IsTruncated and fs:IsTruncated() or false
        end
        if not cut and not clip and l and r and fl and fr and (l < fl - 1 or r > fr + 1) then
            -- (Its letters, not its box: a text placed by its justification.)
            local a, b = textSpan(fs)
            cut = a ~= nil and (a < fl - 1 or b > fr + 1)
        end
        if cut then out[#out + 1] = text end
    end
    local function walk(x, clip)
        if not x:IsVisible() then return end
        local clips = (x.GetObjectType and x:GetObjectType() == "ScrollFrame") or (x.DoesClipChildren and x:DoesClipChildren())
        if clips then
            local l, r, b, t = x:GetLeft(), x:GetRight(), x:GetBottom(), x:GetTop()
            if l and r and b and t then
                clip = clip and { l = math.max(l, clip.l), r = math.min(r, clip.r), b = math.max(b, clip.b),
                    t = math.min(t, clip.t) } or { l = l, r = r, b = b, t = t }
            end
        end
        for _, region in ipairs({ x:GetRegions() }) do
            if region.GetObjectType and region:GetObjectType() == "FontString" then check(region, clip) end
        end
        for _, child in ipairs({ x:GetChildren() }) do walk(child, clip) end
    end
    walk(f)
    return out
end
local function plainText(text)
    return (tostring(text):gsub("|T.-|t", "#"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", "")
        :gsub("|h", ""))
end

function Widgets.CheckLayout(f, lists, view)
    local name = (rawget(f, "layoutName") or "window") .. "/" .. tostring(view or "-")
    if logged[name] then return end
    local w, need = tonumber((f:GetWidth())) or 0, rawget(f, "contentNeed")
    local problems = {}
    local over = need and math.floor(w - need + 0.5) or 0
    if need and over > Widgets.SLACK and not rawget(f, "userW") and not rawget(f, "fitGrows") then
        problems[#problems + 1] = string.format("wider than its content by %d px", over)
    end
    local controls = Widgets.ControlsWidth(f)
    local drift
    for _, l in ipairs(lists or {}) do
        local spansOf, columnsOf = rawget(l, "spansOf"), rawget(l, "columnsOf")
        if l:IsShown() and (spansOf or columnsOf or rawget(l, "headers")) then
            local columns = columnsOf and columnsOf() or (not spansOf and Widgets.ListColumns(l)) or nil
            local spans = columns and Widgets.ColumnSpans(columns) or spansOf()
            local function field(k)
                local v = rawget(l, k)
                if v == nil then v = l[k] end
                return type(v) == "number" and v or nil
            end
            -- (The room the first column may take over its text: what the table's note (an empty table's why) needs
            -- over its columns, what the controls give the window, and in a view of two or more tables what the
            -- widest of them needs: every table spans the window, SDD 127. Any other gap is a hole.)
            local margin = field("margin") or 24
            local cols = field("columnsWidth") or field("neededWidth") or 0
            local own = math.max(cols, field("neededWidth") or 0) + margin
            local room = math.max(controls, need or 0, own)
            local spare = math.max(0, room - cols - margin)
            -- (A table too narrow for its columns leaves some out, and its first column takes what is left of them.)
            local out = rawget(l, "leftOut")
            if type(out) == "table" and #out > 0 then spare = math.max(spare, field("spare") or 0) end
            local most, parts = Widgets.WideGaps(spans, spare)
            if most > Widgets.GAP_TOL then
                problems[#problems + 1] = "column gaps over " .. Widgets.NORMAL_GAP .. " px: " .. table.concat(parts, ", ")
            end
            local d = columns and Widgets.MeasureDrift(columns)
            if d and (not drift or math.abs(d.measured - d.drawn) > math.abs(drift.measured - drift.drawn)) then drift = d end
        end
    end
    if drift then
        problems[#problems + 1] = string.format("measured %.1f px, drawn %.1f px: %s \"%s\"", drift.measured, drift.drawn,
            drift.title, plainText(drift.text):sub(1, 40))
    end
        -- Every text of the window, not only the tables' (a status line was cut in the client, 0.4.0). (At most once a
    -- second per window and view: it walks every text, and a scan refreshes often.)
    local now = GetTime and GetTime() or 0
    if not cutChecked[name] or now - cutChecked[name] >= 1 then
        cutChecked[name] = now
        for _, text in ipairs(Widgets.CutTexts(f)) do
            problems[#problems + 1] = "cut text: " .. plainText(text):sub(1, 40)
        end
    end
    if #problems > 0 then
        logged[name] = true
        if ns.Log then ns.Log("layout: %s %s", name, table.concat(problems, "; ")) end
    end
    return problems
end

function Widgets.Label(parent, text, template)
    local l = parent:CreateFontString(nil, "OVERLAY", template or "GameFontNormalSmall")
    l:SetText(text)
    return l
end

-- The least height of a table (its titles and two rows, SDD 113), and the share of a split's upper table.
Widgets.TABLE_MIN, Widgets.SPLIT_LO, Widgets.SPLIT_HI = 66, 0.1, 0.9

--- The upper table's height when two tables share `room` px at `share` (0.1 to 0.9): each keeps `least` (TABLE_MIN).
function Widgets.SplitHeight(room, share, least)
    least = least or Widgets.TABLE_MIN
    share = math.max(Widgets.SPLIT_LO, math.min(Widgets.SPLIT_HI, share))
    return math.max(least, math.min(room - least, math.floor(room * share)))
end

--- The bar between two stacked tables (SDD 52, 113): the player drags it up or down to make one table taller and
--- the other shorter; a right-click puts it back. It lies under `upper` (over the lower table's title). `room()` =
--- the height both tables share; `set(share)` keeps the upper table's share (nil = the default) and lays out again.
function Widgets.SplitBar(parent, upper, room, set)
    local bar = CreateFrame("Button", nil, parent)
    bar:SetPoint("TOPLEFT", upper, "BOTTOMLEFT", 0, -1)
    bar:SetPoint("TOPRIGHT", upper, "BOTTOMRIGHT", 0, -1)
    bar:SetHeight(22)
    local handle = bar:CreateTexture(nil, "ARTWORK")
    handle:SetSize(60, 3)
    handle:SetPoint("TOP", bar, "TOP", 0, -2)
    handle:SetColorTexture(1, 0.82, 0, 0.45)
    local glow = bar:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAllPoints()
    glow:SetColorTexture(1, 1, 1, 0.08)
    Widgets.Tooltip(bar, "Resize", "Drag up or down to make one table taller and the other shorter. Right-click: back to "
        .. "the default.")
    bar:RegisterForClicks("RightButtonUp")
    bar:SetScript("OnClick", function() set(nil) end)
    -- The border follows the pointer from where the bar was grabbed (the grab itself moves nothing: it jumped by the
    -- pointer's place in the bar, 0.3.151), and only a move of the pointer lays the tables out again.
    local function cursorY()
        local _, y = GetCursorPosition()
        if type(y) ~= "number" then return nil end
        return y / (parent:GetEffectiveScale() or 1)
    end
    bar:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        local y0, h0, r0 = cursorY(), upper:GetHeight(), room()
        if not (y0 and type(h0) == "number" and r0 > 0) then return end
        local last
        self:SetScript("OnUpdate", function()
            local y, r = cursorY(), room()
            if not y or r <= 0 or y == last then return end
            last = y
            set(math.max(Widgets.SPLIT_LO, math.min(Widgets.SPLIT_HI, (h0 + (y0 - y)) / r)))
        end)
    end)
    bar:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil) end)
    bar:SetScript("OnHide", function(self) self:SetScript("OnUpdate", nil) end)
    return bar
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

--- How wide a text is on screen in the font object `font` (default the titles' small font), in pixels; nil where the
--- client cannot tell. Measured by a font string of that very font object (one per font, on UIParent: every window
--- has its scale), so what the width authority measures is what the cell of that font draws (SDD 123): a table's
--- titles in TITLE_FONT, its cells in CELL_FONT, a total's in BOLD_FONT.
Widgets.TITLE_FONT, Widgets.CELL_FONT, Widgets.BOLD_FONT = "GameFontNormalSmall", "GameFontHighlightSmall", "GameFontHighlight"
local meters, widthOf, cached = {}, {}, 0
function Widgets.TextWidth(text, font)
    if text == nil or text == "" then return 0 end
    font = font or Widgets.TITLE_FONT
    local of = widthOf[font]
    if not of then of = {} widthOf[font] = of end
    local w = of[text]
    if w ~= nil then return w or nil end
    local meter = meters[font]
    if not meter then
        meter = UIParent:CreateFontString(nil, "OVERLAY", font)
        meter:Hide()
        meters[font] = meter
    end
    meter:SetText(text)
    local measure = meter.GetUnboundedStringWidth or meter.GetStringWidth
    w = tonumber((measure(meter)))
    if cached > 6000 then widthOf, cached = {}, 0 of = {} widthOf[font] = of end
    of[text], cached = w or false, cached + 1
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
--- @param titles table  the column titles (measured in TITLE_FONT)
--- @param count number, cellsOf function(r) -> cells, extra (pixels before the first column's text), font (the font
---                     object the row's cells are drawn in: CELL_FONT where nil, BOLD_FONT for a total)
--- @param samples table|nil  per column, the widest text it can hold (digits count as the widest digit),
---                           so a column whose values change (a countdown) keeps its width
--- @return table|nil  widths per column; nil when the client cannot measure text
--- @return table  per column the widest text measured, in px (the self-check places it in the column's box)
function Widgets.FitColumns(titles, count, cellsOf, pad, samples)
    local need = {}
    -- (A live column keeps its sample's width while it has rows; an empty table is as wide as its titles.)
    local any = false
    for r = 1, math.min(count, 400) do if cellsOf(r) then any = true break end end
    if not any then samples = nil end
    for i, title in ipairs(titles) do
        local w = Widgets.TextWidth(title, Widgets.TITLE_FONT)
        if not w then return nil end
        local sample = samples and samples[i] and Widgets.WidestDigits(samples[i])
        local s = sample and Widgets.TextWidth(sample, Widgets.CELL_FONT) or 0
        if not s then return nil end
        need[i] = math.max(w, s)
    end
    for r = 1, math.min(count, 400) do
        local cells, extra, font = cellsOf(r)
        font = font or Widgets.CELL_FONT
        for i = 1, #titles do
            local w = cells and Widgets.TextWidth(Widgets.CellText(cells[i]), font) or 0
            if not w then return nil end
            if i == 1 then w = w + (extra or 0) end
            if w > need[i] then need[i] = w end
        end
    end
    local text = {}
    for i = 1, #titles do text[i] = need[i] need[i] = math.ceil(need[i]) + (pad or Widgets.CELL_PAD) end
    return need, text
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

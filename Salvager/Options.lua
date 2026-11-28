-- Salvager: the options. The same controls are shown in two places:
--   a window of its own (the Options button, the minimap button's right-click, /salv config), which
--   opens without closing anything; and
--   the game's AddOns settings (Esc > Options > AddOns > Salvager). The game closes other windows
--   when its settings open, so the addon's own buttons do not go there.
local _, ns = ...

local W = ns.Widgets

local Options = {}
ns.Options = Options

local gamePanel, ownWindow, category
local controls   -- the controls of the panel being filled (see populate)

local function changed(what, value)
    ns.Log("option %s = %s", what, tostring(value))
    ns.Fire("SALVAGER_SETTINGS")
end

local function numberBox(parent, label, width, get, set, help)
    local l = W.Label(parent, label, "GameFontHighlightSmall")
    local e = W.Edit(parent, width, false)
    e:SetPoint("LEFT", l, "RIGHT", 10, 0)
    e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    e:SetScript("OnEditFocusLost", function(self)
        local n = tonumber(self:GetText())
        if n then set(n) end
        self:SetText(tostring(get()))
    end)
    if help then W.Tooltip(e, label, help) end
    e.refresh = function() if not e:HasFocus() then e:SetText(tostring(get())) end end
    controls[#controls + 1] = e
    return l, e
end

--- Fills `panel` with the option controls. `standalone` = the addon's own window (it has a title bar).
local function populate(panel, standalone)
    local s = ns.db.settings
    controls = {}
    panel.controls = controls
    local y = standalone and -32 or -16
    local function at(region, x, gap)
        y = y - (gap or 0)
        region:SetPoint("TOPLEFT", panel, "TOPLEFT", x or 16, y)
        y = y - 26
    end
    local function heading(text)
        local h = W.Label(panel, text, "GameFontNormal")
        at(h, 16, 10)
    end

    if not standalone then
        local title = W.Label(panel, "Salvager", "GameFontNormalLarge")
        at(title)
    end
    local sub = W.Label(panel, "Disenchant trading: what gear to buy, and what your materials cost you.",
        "GameFontHighlightSmall")
    at(sub, 16, -8)

    -- (What the main window sets is not here: gear, quality, min profit, max price, the Arcane Salvager bonus,
    -- cautious pricing, item levels, Show top (the gear each scan searches).)
    heading("Scanning")
    local minL, minE = numberBox(panel, "Required level from", 36,
        function() return s.minLevel end, function(n) s.minLevel = math.max(0, math.floor(n)) changed("minLevel", n) end,
        "0 and 0 = all levels. The auction house filters by required level.")
    at(minL, 24)
    local toL = numberBox(panel, "to", 36,
        function() return s.maxLevel end, function(n) s.maxLevel = math.max(0, math.floor(n)) changed("maxLevel", n) end)
    toL:SetPoint("LEFT", minE, "RIGHT", 12, 0)

    local liveL = numberBox(panel, "Play, Live: rest between rounds (seconds)", 36,
        function() return s.liveInterval end,
        function(n) s.liveInterval = math.max(3, math.floor(n)) changed("liveInterval", s.liveInterval) end,
        "Play's Live scan: how long it waits after a round before the next one. The auction house is free for your Buy "
            .. "clicks while it waits. 3 or more.")
    at(liveL, 24)
    local intL = numberBox(panel, "Play, full rounds: scan the gear every (seconds)", 36,
        function() return s.autoInterval end,
        function(n) s.autoInterval = math.max(5, math.floor(n)) changed("autoInterval", s.autoInterval) end,
        "When the auction house does not sort the listings by price, Play reads every page instead: this often. "
            .. "5 or more.")
    at(intL, 24)

    local rescanL = numberBox(panel, "Play: scan material prices again after (minutes, 0 = never)", 36,
        function() return s.priceRescan end,
        function(n) s.priceRescan = math.max(0, math.floor(n)) changed("priceRescan", s.priceRescan) end,
        "While Play runs, the material prices are scanned again before a gear scan when they are older than this. "
            .. "A material scan takes about 20 seconds. 10 minutes suits prices that move a few percent per hour.")
    at(rescanL, 24)

    -- (The bonus in the buy prices is the main window's "Arcane Salvager" box since 0.4.0: a setting of the scan.)
    heading("Arcane Salvager")
    local chL = numberBox(panel, "Starting chance of one extra dust or essence (%)", 36,
        function() return math.floor(s.salvagerChance * 100 + 0.5) end,
        function(n) s.salvagerChance = math.min(100, math.max(0, n)) / 100 changed("salvagerChance", s.salvagerChance) end,
        "Where your results with the Salvager are few, the forecast starts from this chance (community data: 50%). "
            .. "Your own results take over as they grow. " .. ns.LEARNING_LINES[1] .. " " .. ns.LEARNING_LINES[2])
    at(chL, 24)

    -- Which bought gear the Disenchant panel offers (SDD 112b): it never offers gear you did not buy.
    heading("Disenchant panel")
    local dx = s.disenchantFilter
    local function dChanged(what) changed("disenchantFilter." .. what, true) if ns.DisenchantPanel then
        ns.DisenchantPanel.Refresh() end end
    -- At least one stays ticked (as in every filter).
    local function lastOne(set, v)
        for k, on in pairs(set) do if on and k ~= v then return false end end
        return true
    end
    local dqL = W.Label(panel, "Quality", "GameFontHighlightSmall")
    at(dqL, 24)
    local dq = W.Dropdown(panel, 200, { { 2, "|cff1eff00Uncommon|r" }, { 3, "|cff0070ddRare|r" }, { 4, "|cffa335eeEpic|r" } },
        function(v) return dx.qualities[v] and true or false end,
        function(v, on)
            if not on and lastOne(dx.qualities, v) then return end
            dx.qualities[v] = on or false
            dChanged("qualities")
        end, "Which qualities of the gear you bought the Disenchant panel offers.", "Quality")
    dq:SetPoint("LEFT", dqL, "RIGHT", 12, 0)
    local dgL = W.Label(panel, "Gear", "GameFontHighlightSmall")
    dgL:SetPoint("LEFT", dq, "RIGHT", 20, 0)
    local dg = W.Dropdown(panel, 140, { { 4, "Armor" }, { 2, "Weapons" } },
        function(v) return dx.classes[v] and true or false end,
        function(v, on)
            if not on and lastOne(dx.classes, v) then return end
            dx.classes[v] = on or false
            dChanged("classes")
        end, "Which gear types the Disenchant panel offers.", "Gear")
    dg:SetPoint("LEFT", dgL, "RIGHT", 12, 0)
    local dMinL, dMinE = numberBox(panel, "Item level from", 36,
        function() return dx.minIlvl end,
        function(n) dx.minIlvl = math.max(0, math.floor(n)) dChanged("minIlvl") end,
        "The lowest item level the Disenchant panel offers. 0 = no limit.")
    at(dMinL, 24)
    local dToL = numberBox(panel, "to", 36,
        function() return dx.maxIlvl end,
        function(n) dx.maxIlvl = math.max(0, math.floor(n)) dChanged("maxIlvl") end,
        "The highest item level the Disenchant panel offers. 0 = no limit.")
    dToL:SetPoint("LEFT", dMinE, "RIGHT", 12, 0)
    local dHint = W.Label(panel, "0 = no limit. The panel only ever offers gear you bought.", "GameFontDisableSmall")
    at(dHint, 24, -6)
    controls[#controls + 1] = { refresh = function() dq:Update() dg:Update() end }

    heading("Prices and window")
    local unL = numberBox(panel, "Material price = average of the cheapest units", 36,
        function() return s.priceUnits end,
        function(n) s.priceUnits = math.max(1, math.floor(n)) changed("priceUnits", s.priceUnits) end,
        "More units = a price that one cheap listing moves less.")
    at(unL, 24)
    local hiL = numberBox(panel, "Highlight returns from (%)", 36,
        function() return s.highlightReturn end,
        function(n) s.highlightReturn = math.max(0, math.floor(n)) changed("highlightReturn", s.highlightReturn) end,
        "The Gear list marks a deal whose average return is this or more (orange, with \"!\" after its buyout): "
            .. "check it before you buy. 0 = off.")
    at(hiL, 24)
    -- The clock of every time shown (SDD 110): one choice.
    local TIMES_HELP = "Local time: your computer's clock. Server time: the realm's clock, read at login and every "
        .. "hour. Every time and day in the windows, the log and the chat follows it; what is saved does not change."
    local timesL = W.Label(panel, "Times shown in", "GameFontHighlightSmall")
    at(timesL, 24)
    local times
    times = W.Dropdown(panel, 220, { { "local", "Local time (your computer)" }, { "server", "Server time (the realm)" } },
        function(v) return s.timeZone == v end,
        function(v)
            times:Close()
            if s.timeZone == v then times:Update() return end
            s.timeZone = v
            changed("timeZone", v)
                end, TIMES_HELP, "Times shown in", nil, true)
    times:SetPoint("LEFT", timesL, "RIGHT", 12, 0)
    panel.timesDrop = times
    controls[#controls + 1] = { refresh = function() times:Update() end }
    local autoOpen = W.Check(panel, "Open the window with the auction house", nil,
        function(on) s.autoOpen = on changed("autoOpen", on) end)
    at(autoOpen, 20)
    local restore = W.Check(panel, "and reopen the windows that were open last time",
        "Open is remembered from the buttons, the commands and a window's X. Escape and leaving the auction house "
            .. "close everything at once and do not change it.",
        function(on) s.restoreWindows = on changed("restoreWindows", on) end)
    at(restore, 36)
    local mini = W.Check(panel, "Show the minimap button", nil,
        function(on) s.minimap.hide = not on changed("minimap", on) end)
    at(mini, 20)
    controls[#controls + 1] = { refresh = function()
        autoOpen:SetChecked(s.autoOpen) restore:SetChecked(s.restoreWindows) mini:SetChecked(not s.minimap.hide)
    end }
    -- The two macros (SDD 127): made once at the first login; this makes a deleted one again.
    local macros = W.Button(panel, "Create the macros again", 170, function() ns.Macros.Create(true) end,
        "Makes the macros Salvager Buy (clicks Buy Top) and Salvager DE (clicks the Disenchant button) where one is "
            .. "missing, as account macros. One you changed is left as it is. Drag them from /macro to your bars, or "
            .. "bind them to keys.\n\nIn combat the game keeps the Disenchant button as it was: the macro casts on the "
            .. "piece it aimed at before the fight, or does nothing.")
    macros:SetPoint("LEFT", mini.label, "RIGHT", 24, 0)

    heading("Data")
    -- How much the addon keeps on disk, and the history with its backups.
    local size = W.Label(panel, "", "GameFontHighlightSmall")
    size:SetWidth(520)
    size:SetJustifyH("LEFT")
    size:SetWordWrap(false)
    at(size, 20)
    local clear = W.Button(panel, "Clear history", 110, function() StaticPopup_Show("SALVAGER_CLEAR_LEDGER") end,
        "Deletes every purchase, disenchant and sale record. Your stock and its costs stay, and so do purchases not "
            .. "disenchanted yet. It asks first, and keeps a copy you can restore.")
    at(clear, 28)
    local restoreButton = W.Button(panel, "Restore backup", 120, function() ns.Backup.AskRestore() end,
        "Puts the last copy of the ledger back (one is made before each clear). It asks first.")
    restoreButton:SetPoint("LEFT", clear, "RIGHT", 8, 0)
    restoreButton:SetMotionScriptsWhileDisabled(true)
    local last = W.Label(panel, "", "GameFontDisableSmall")
    last:SetPoint("LEFT", restoreButton, "RIGHT", 8, 0)
    -- (The size walks the whole saved data: on show only, not on every settings change.)
    controls[#controls + 1] = { onShow = true, refresh = function()
        local data, backups = ns.Backup.Sizes()
        size:SetText(string.format("Saved data: about %s (log %d lines, gold journal %d changes). Backups: %s.",
            ns.Util.FormatBytes(data), #ns.db.log, #(ns.db.money.entries or {}), ns.Util.FormatBytes(backups)))
        local b = ns.Backup.Last()
        restoreButton:SetEnabled(b ~= nil)
        last:SetText(b and ("last copy: " .. ns.Date("%m-%d %H:%M", b.t)) or "no backup yet")
    end }

    if not standalone then
        local open = W.Button(panel, "Open Salvager", 120, function() ns.UI.Show() end)
        at(open, 24, 8)
    end

    local version = W.Label(panel, "Version " .. ns.VERSION, "GameFontDisableSmall")
    version:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 16)
    panel.contentHeight = -y
    panel:SetScript("OnShow", function() Options.Refresh(true) end)
end

local function refresh(panel, shown)
    if not panel or not panel:IsShown() then return end
    for _, c in ipairs(panel.controls) do
        if c.refresh and (shown or not c.onShow) then c.refresh() end
    end
end

--- Draws the options on show. `shown`: the panel has just opened (the saved data size is measured then too).
function Options.Refresh(shown)
    refresh(gamePanel, shown)
    refresh(ownWindow, shown)
end

--- Opens the addon's own options window. Nothing else closes.
function Options.Open()
    if not ownWindow then
        ownWindow = W.Window("SalvagerOptionsFrame", "Salvager Options", "options", 560, 706, 560, 706, true)
        populate(ownWindow, true)
        ownWindow:SetHeight(ownWindow.contentHeight + 44)   -- as tall as its content, plus the version line
    end
    ownWindow:SetShown(not ownWindow:IsShown())
    if ownWindow:IsShown() and ownWindow.Raise then ownWindow:Raise() end
end

ns.On("SALVAGER_READY", function()
    gamePanel = CreateFrame("Frame", "SalvagerOptionsPanel")
    gamePanel.name = "Salvager"
    populate(gamePanel, false)
    if Settings and Settings.RegisterCanvasLayoutCategory then
        category = Settings.RegisterCanvasLayoutCategory(gamePanel, "Salvager")
        Settings.RegisterAddOnCategory(category)
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(gamePanel)
    end
end)
ns.On("SALVAGER_SETTINGS", function() Options.Refresh() end)

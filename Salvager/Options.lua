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

    heading("Buying")
    local mpLabel = W.Label(panel, "Minimum profit per item", "GameFontHighlightSmall")
    at(mpLabel, 24)
    local money = W.Money(panel, function(c) s.minProfit = c changed("minProfit", c) end)
    money:SetPoint("LEFT", mpLabel, "RIGHT", 12, 0)
    controls[#controls + 1] = { refresh = function() money:Set(s.minProfit) end }

    local capLabel = W.Label(panel, "Maximum price per item (0 = no limit)", "GameFontHighlightSmall")
    at(capLabel, 24)
    local cap = W.Money(panel, function(c) s.maxPrice = c changed("maxPrice", c) end)
    cap:SetPoint("LEFT", capLabel, "RIGHT", 12, 0)
    controls[#controls + 1] = { refresh = function() cap:Set(s.maxPrice) end }

    local careful = W.Check(panel, "Cautious pricing: buy limits count every material at its lowest amount",
        "The buy limit uses 1 dust where the average is 1.5, and no Arcane Salvager bonus. Fewer deals, and they "
            .. "lose less often. Value and Profit still show the average.",
        function(on) s.cautious = on changed("cautious", on) end)
    at(careful, 20)
    controls[#controls + 1] = { refresh = function() careful:SetChecked(s.cautious) end }

    local gearLabel = W.Label(panel, "Gear to scan", "GameFontHighlightSmall")
    at(gearLabel, 24)
    local gear = W.CheckDropdown(panel, 150, { { "weapons", "Weapons" }, { "armor", "Armor" } },
        ns.GearTypeOn, ns.SetGearType, "Armor gives mostly dust, weapons mostly essence.", "Gear")
    gear:SetPoint("LEFT", gearLabel, "RIGHT", 12, 0)
    controls[#controls + 1] = { refresh = function() gear:Update() end }

    local qLabel = W.Label(panel, "Quality", "GameFontHighlightSmall")
    at(qLabel, 24)
    local green = W.Check(panel, "|cff1eff00Uncommon|r", "Uncommon gear: dust, essences and a small shard chance.",
        function(on) s.qualities[2] = on changed("uncommon", on) end)
    -- (The main window has the same choice as a drop-down.)
    green:SetPoint("LEFT", qLabel, "RIGHT", 12, 0)
    local blue = W.Check(panel, "|cff0070ddRare|r", "Rare gear: always one shard.",
        function(on) s.qualities[3] = on changed("rare", on) end)
    blue:SetPoint("LEFT", green.label, "RIGHT", 16, 0)
    local purple = W.Check(panel, "|cffa335eeEpic|r", "Epic gear: 2-4 shards, or Nexus Crystals at the top levels.",
        function(on) s.qualities[4] = on changed("epic", on) end)
    purple:SetPoint("LEFT", blue.label, "RIGHT", 16, 0)
    controls[#controls + 1] = { refresh = function()
        green:SetChecked(s.qualities[2]) blue:SetChecked(s.qualities[3]) purple:SetChecked(s.qualities[4])
    end }

    local minL, minE = numberBox(panel, "Required level from", 36,
        function() return s.minLevel end, function(n) s.minLevel = math.max(0, math.floor(n)) changed("minLevel", n) end,
        "0 and 0 = all levels. The auction house filters by required level.")
    at(minL, 24)
    local toL = numberBox(panel, "to", 36,
        function() return s.maxLevel end, function(n) s.maxLevel = math.max(0, math.floor(n)) changed("maxLevel", n) end)
    toL:SetPoint("LEFT", minE, "RIGHT", 12, 0)

    local intL = numberBox(panel, "Play: scan the gear every (seconds)", 36,
        function() return s.autoInterval end,
        function(n) s.autoInterval = math.max(5, math.floor(n)) changed("autoInterval", s.autoInterval) end,
        "How often Play scans the gear again. 5 or more.")
    at(intL, 24)
    local rescanL = numberBox(panel, "Play: scan material prices again after (minutes, 0 = never)", 36,
        function() return s.priceRescan end,
        function(n) s.priceRescan = math.max(0, math.floor(n)) changed("priceRescan", s.priceRescan) end,
        "While Play runs, the material prices are scanned again before a gear scan when they are older than this. "
            .. "A material scan takes about 20 seconds. 10 minutes suits prices that move a few percent per hour.")
    at(rescanL, 24)
    local chkL = numberBox(panel, "Item checks per scan", 36,
        function() return s.maxChecks end,
        function(n) s.maxChecks = math.max(1, math.floor(n)) changed("maxChecks", s.maxChecks) end,
        "Each item check is one auction house search (about 0.7 s). The best candidates go first.")
    at(chkL, 24)

    heading("Arcane Salvager")
    local salvLabel = W.Label(panel, "Bonus in buy prices", "GameFontHighlightSmall")
    at(salvLabel, 24)
    local salv = W.Choice(panel, { { "auto", "Auto" }, { "on", "On" }, { "off", "Off" } },
        function(v) s.salvager = v changed("salvager", v) end,
        "Auto: on when you know the recipe or have an Arcane Salvager in your bags.")
    salv:SetPoint("LEFT", salvLabel, "RIGHT", 12, 0)
    controls[#controls + 1] = { refresh = function() salv:Set(s.salvager) end }
    local chL = numberBox(panel, "Chance of one extra dust or essence (%)", 36,
        function() return math.floor(s.salvagerChance * 100 + 0.5) end,
        function(n) s.salvagerChance = math.min(100, math.max(0, n)) / 100 changed("salvagerChance", s.salvagerChance) end,
        "Community data says 50%. The Ledger window (Odds) shows your own results.")
    at(chL, 24)

    heading("Prices and window")
    local unL = numberBox(panel, "Material price = average of the cheapest units", 36,
        function() return s.priceUnits end,
        function(n) s.priceUnits = math.max(1, math.floor(n)) changed("priceUnits", s.priceUnits) end,
        "More units = a price that one cheap listing moves less.")
    at(unL, 24)
    local autoOpen = W.Check(panel, "Open the window with the auction house", nil,
        function(on) s.autoOpen = on changed("autoOpen", on) end)
    at(autoOpen, 20)
    local restore = W.Check(panel, "and reopen the Ledger, Log and Materials windows that were open last time",
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

    if not standalone then
        local open = W.Button(panel, "Open Salvager", 120, function() ns.UI.Show() end)
        at(open, 24, 8)
    end

    local version = W.Label(panel, "Version " .. ns.VERSION, "GameFontDisableSmall")
    version:SetPoint("BOTTOMLEFT", panel, "BOTTOMLEFT", 16, 16)
    panel.contentHeight = -y
    panel:SetScript("OnShow", function() Options.Refresh() end)
end

local function refresh(panel)
    if not panel or not panel:IsShown() then return end
    for _, c in ipairs(panel.controls) do if c.refresh then c.refresh() end end
end

function Options.Refresh()
    refresh(gamePanel)
    refresh(ownWindow)
end

--- Opens the addon's own options window. Nothing else closes.
function Options.Open()
    if not ownWindow then
        ownWindow = W.Window("SalvagerOptionsFrame", "Salvager options", "options", 560, 680, 560, 680, true)
        populate(ownWindow, true)
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

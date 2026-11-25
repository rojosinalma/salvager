-- Salvager: minimap button. Left-click: window. Right-click: options. Drag: move around the minimap.
local _, ns = ...

local Minimap_ = _G.Minimap
local MinimapButton = {}
ns.MinimapButton = MinimapButton

local b

local function place()
    local angle = math.rad(ns.db.settings.minimap.angle or 215)
    local radius = (Minimap_:GetWidth() / 2) + 5
    b:ClearAllPoints()
    b:SetPoint("CENTER", Minimap_, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

local function onDragUpdate()
    local mx, my = Minimap_:GetCenter()
    local scale = Minimap_:GetEffectiveScale()
    local cx, cy = GetCursorPosition()
    cx, cy = cx / scale, cy / scale
    ns.db.settings.minimap.angle = math.deg(math.atan2(cy - my, cx - mx)) % 360
    place()
end

local function build()
    b = CreateFrame("Button", "SalvagerMinimapButton", Minimap_)
    b:SetSize(31, 31)
    b:SetFrameStrata("MEDIUM")
    b:SetFrameLevel(8)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b:RegisterForDrag("LeftButton")
    b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
    local icon = b:CreateTexture(nil, "BACKGROUND")
    icon:SetSize(20, 20)
    icon:SetPoint("CENTER", b, "CENTER", 0, 1)
    icon:SetTexture("Interface\\Icons\\inv_enchant_disenchant")
    local border = b:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", b, "TOPLEFT")
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    b:SetScript("OnClick", function(_, button)
        if button == "RightButton" then ns.Options.Open() else ns.UI.Toggle() end
    end)
    b:SetScript("OnDragStart", function(self) self:SetScript("OnUpdate", onDragUpdate) end)
    b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    b:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Salvager", 1, 1, 1)
        GameTooltip:AddLine("Left-click: open or close the window", 1, 0.82, 0)
        GameTooltip:AddLine("Right-click: options", 1, 0.82, 0)
        GameTooltip:AddLine("Drag: move this button", 1, 0.82, 0)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    place()
end

function MinimapButton.Update()
    if not Minimap_ then return end
    if ns.db.settings.minimap.hide then
        if b then b:Hide() end
        return
    end
    if not b then build() end
    b:Show()
    place()
end

ns.On("SALVAGER_READY", function() MinimapButton.Update() end)
ns.On("SALVAGER_SETTINGS", function() MinimapButton.Update() end)

-- Salvager: the Log window. A window of its own with the activity log, newest first:
-- what the addon did and any error, for debugging. It updates while it is open.
local _, ns = ...

local W = ns.Widgets

local Window = {}
ns.LogWindow = Window

local REFRESH_GAP = 0.5    -- seconds between redraws while the log grows

local f, list, count
local lastRefresh = 0

function Window.Refresh()
    if not f or not f:IsShown() then return end
    local log = ns.db.log
    local n = #log
    list:SetSource(math.max(1, n), function(i)
        local line = log[n - i + 1]
        if not line then return { cells = { "|cff808080nothing logged yet|r" } } end
        if line:find("ERROR", 1, true) then line = "|cffff4040" .. line .. "|r" end
        return { cells = { line } }
    end)
    list:Refresh()
    count:SetText(string.format("%d lines, newest first. Saved to disk on /reload or logout.", n))
    ns.logChanged = false
    lastRefresh = GetTime()
end

local function build()
    f = W.Window("SalvagerLogFrame", "Salvager log", "log", 640, 360, 360, 160)
    local clear = W.Button(f, "Clear", 80, function()
        wipe(ns.db.log)
        list.offset = 0
        Window.Refresh()
    end)
    clear:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -30)
    count = W.Label(f, "", "GameFontDisableSmall")
    count:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -36)
    list = W.List(f, { rowHeight = 15, header = false })
    list:SetColumns({ { "", 300 } })
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -58)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    f.onResize = Window.Refresh
    f:SetScript("OnShow", Window.Refresh)
end

function Window.Toggle()
    if not f then build() end
    f:SetShown(not f:IsShown())
end

function Window.Show()
    if not f then build() end
    f:Show()
end

-- New lines show up while the window is open, at most twice a second.
ns.OnTick(function()
    if f and f:IsShown() and ns.logChanged and GetTime() - lastRefresh >= REFRESH_GAP then Window.Refresh() end
end)

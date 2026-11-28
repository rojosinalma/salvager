-- Salvager: the Log window. A window of its own with the activity log (SDD 129), newest at the bottom: what the
-- addon did and any error, for debugging. Its table and filters are LogView.lua. It updates while it is open.
local _, ns = ...

local W = ns.Widgets

local Window = {}
ns.LogWindow = Window

local REFRESH_GAP = 0.5    -- seconds between redraws while the log grows

local View = ns.LogView

local f, list, count, controls
local lastRefresh = 0

function Window.Refresh()
    if not f or not f:IsShown() then return end
    local records = ns.LogBook.Records()
    local flt = View.Filter()
    local shown, n = View.Shown(records, flt)
    local room = View.MessageRoom(list)
    -- Oldest first, newest at the bottom. The view follows the last line unless you scrolled up.
    list:SetSource(math.max(1, #shown), function(i)
        local e = shown[i]
        if not e then return { cells = { View.Empty(#records, flt) }, span = true } end
        return View.Entry(e, room)
    end)
    if list.atBottom ~= false then list.offset = math.huge end
    list:Refresh()
    controls.search:Update()
    controls.level:Update()
    controls.category:Update()
    count:SetText(string.format("%d of %d lines", n, #records))
    ns.logChanged = false
    lastRefresh = GetTime()
end

local function build()
    f = W.Window("SalvagerLogFrame", "Salvager Log", "log", 640, 360, 560, 160)
    -- The filter row under the title bar; the footer: the count at the left, Clear at the right (UI.md Controls 1).
    local filters = W.Bar(f, "filters"):Place(28, 12, 12)
    controls = View.BuildFilters(filters, function()
        list.offset, list.atBottom = math.huge, nil
        Window.Refresh()
    end)
    Window.controls = controls   -- (the specs set them)
    local footer = W.Bar(f, "footer"):PlaceBottom(8, 12, 24)
    local clear = W.Button(footer, "Clear", 80, function()
        wipe(ns.db.log)
        list.offset = 0
        list.atBottom = nil
        Window.Refresh()
    end, "Empties the log. The game saves the log to disk on /reload or logout.")
    footer:AddRight(clear, 80)
    count = W.Label(footer, "", "GameFontDisableSmall")
    footer:Add(count, 120)
    count:SetWordWrap(false)
    Window.countLabel = count   -- (the specs read it)
    count:SetPoint("RIGHT", clear, "LEFT", -12, 0)
    W.HelpArea(footer, count, "Log", "Newest at the bottom. Hover a line for the whole line and its data. The game "
        .. "saves the log to disk on /reload or logout; /salv log export writes it as text for the developer.")
    Window.bars = { filters = filters, footer = footer }   -- (the specs read them)
    list = W.List(f, { rowHeight = 15 })
    list:SetColumns(View.COLUMNS, "log")
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -58)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 40)
    Window.list = list
    f.onResize = Window.Refresh
    f:HookScript("OnShow", Window.Refresh)
end

function Window.Toggle()
    if not f then build() end
    f.UserToggle()
end

function Window.Show()
    if not f then build() end
    f.UserShow()
end

--- Opens the window again if it was open the last time (the auction house opened).
function Window.Restore()
    local saved = ns.db.windows.log
    if not (saved and saved.open) then return end
    if not f then build() end
    f:Show()
end

-- New lines show up while the window is open, at most twice a second.
ns.OnTick(function()
    if f and f:IsShown() and ns.logChanged and GetTime() - lastRefresh >= REFRESH_GAP then Window.Refresh() end
end)

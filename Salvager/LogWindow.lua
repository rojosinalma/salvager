-- Salvager: the Log window. A window of its own with the activity log, newest at the bottom:
-- what the addon did and any error, for debugging. It updates while it is open.
local _, ns = ...

local W = ns.Widgets

local Window = {}
ns.LogWindow = Window

local REFRESH_GAP = 0.5    -- seconds between redraws while the log grows

local f, list, count, filterButton
local lastRefresh = 0

--- An item the game knows, as a link; a material by its name. nil when the game has no name yet.
local function linkOf(id)
    local _, link = ns.GetItemInfo(id)
    if link then return link end
    if ns.Data.MATERIAL_BY_ID[id] then return "|cffffffff[" .. ns.MaterialName(id) .. "]|r" end
    return nil
end

--- One log line as a row: items are shown by name, and the row's tooltip is the item.
--- The log keeps item IDs ("commodity 11083", "item 7048:29:0"); a purchase keeps the full link.
function Window.Row(line)
    local link = line:match("|Hitem:[^|]+|h")
    local id = link and tonumber(link:match("item:(%d+)"))
    local text = line
    if not id then
        local name, matID = line:match("price (.-) %((%d+)%):")
        if matID then
            id = tonumber(matID)
            local shown = linkOf(id)
            if shown then text = line:gsub("price " .. name:gsub("%p", "%%%0") .. " %(%d+%)", "price " .. shown:gsub("%%", "%%%%"), 1) end
        else
            local found = line:match("commodity (%d+)") or line:match("item (%d+)")
            id = tonumber(found)
            local shown = id and linkOf(id)
            if shown then
                shown = shown:gsub("%%", "%%%%")
                text = line:gsub("commodity " .. found, shown, 1):gsub("item " .. found .. ":(%d+):%d+", shown .. " (level %1)", 1)
                    :gsub("item " .. found, shown, 1)
            end
        end
    end
    if line:find("ERROR", 1, true) then text = "|cffff4040" .. text .. "|r"
    elseif line:find("^== ") then text = "|cffffd100" .. text .. "|r" end
    return { cells = { text }, link = id and ("item:" .. id) or nil }
end

-- The Lines filter: every line, or only trades and gold, or only errors. Day lines always show.
local FILTERS = {
    { "all", "All lines" },
    { "trades", "Trades and gold", { "bought ", "sold ", "posted ", "post sent", "mail:", "gold:", "cancelling", "session:", "disenchant:",
        "could not buy", "purchase of" } },
    { "errors", "Errors", { "ERROR" } },
}

function Window.Matches(line, filter)
    local words = filter and filter[3]
    if not words or line:find("^== ") then return true end
    for _, w in ipairs(words) do if line:find(w, 1, true) then return true end end
    return false
end

local function currentFilter()
    local key = ns.db.windows.log and ns.db.windows.log.filter
    for _, x in ipairs(FILTERS) do if x[1] == key then return x end end
    return FILTERS[1]
end

function Window.Refresh()
    if not f or not f:IsShown() then return end
    local log = ns.db.log
    local filter = currentFilter()
    local shown = {}
    for i = 1, #log do
        if Window.Matches(log[i], filter) then shown[#shown + 1] = log[i] end
    end
    local n = #shown
    -- Oldest first, newest at the bottom. The view follows the last line unless you scrolled up.
    list:SetSource(math.max(1, n), function(i)
        local line = shown[i]
        if not line then return { cells = { "|cff808080nothing logged yet|r" } } end
        return Window.Row(line)
    end)
    if list.atBottom ~= false then list.offset = math.huge end
    list:Refresh()
    filterButton:Update()
    count:SetText(string.format("%d of %d lines", n, #log))
    ns.logChanged = false
    lastRefresh = GetTime()
end

local function build()
    f = W.Window("SalvagerLogFrame", "Salvager log", "log", 640, 360, 360, 160)
    -- The filter row under the title bar; the footer: the count at the left, Clear at the right (UI.md Controls 1).
    local filters = W.Bar(f, "filters"):Place(28, 12, 12)
    local options = {}
    for _, x in ipairs(FILTERS) do options[#options + 1] = { x[1], x[2] } end
    filterButton = W.Dropdown(filters, 140, options, function(key) return currentFilter()[1] == key end,
        function(key)
            local saved = ns.db.windows.log or {}
            ns.db.windows.log = saved
            saved.filter = key
            filterButton:Close()
            list.offset, list.atBottom = math.huge, nil
            Window.Refresh()
        end, "All lines, only trades and gold, or only errors.", "Lines shown")
    filters:AddFilter("Lines", filterButton, 140, "All lines, only trades and gold, or only errors.")
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
    count:SetPoint("RIGHT", clear, "LEFT", -12, 0)
    W.HelpArea(footer, count, "Log", "Newest at the bottom. Hover a line to see its item. The game saves the log to disk "
        .. "on /reload or logout.")
    Window.bars = { filters = filters, footer = footer }   -- (the specs read them)
    list = W.List(f, { rowHeight = 15, header = false, plain = true, fit = false })
    list:SetColumns({ { "", 300 } })
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -58)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 40)
    f.onResize = Window.Refresh
    f:SetScript("OnShow", Window.Refresh)
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

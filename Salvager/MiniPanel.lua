-- Salvager: the mini panel (UI.md Layout 5). A small window with one row of buttons, one per Salvager window:
-- Salvager (the main window), Ledger, Reports, Market, Log. The main window's Minimize shows it, and so does the
-- minimap button away from the auction house. The windows it opens stay on their own: closing the main window does
-- not close them. It closes with its own X, with the minimap button, and when the main window shows (Minimize brings
-- it back). Escape leaves it: it is a launcher, like the minimap button.
local _, ns = ...

local W = ns.Widgets

local MiniPanel = {}
ns.MiniPanel = MiniPanel

local f

-- The buttons: label, width, what a click does, the window it opens (its owner is "panel"), and the help.
local BUTTONS = {
    { "Salvager", 74, function() ns.UI.Show() end, nil, "Opens the main window: at the auction house the Gear and "
        .. "Materials tabs with the scans; elsewhere what it can show (the lists of the last scan, your settings)." },
    { "Ledger", 64, function() ns.LedgerWindow.Toggle() end, "SalvagerLedgerFrame", "Opens or closes the ledger: "
        .. "your purchases, sales, competition, accuracy and odds." },
    { "Reports", 70, function() ns.Reports.Toggle() end, "SalvagerReportsFrame", "Opens or closes the reports: your "
        .. "gold, the profit of your gear, your materials and your competitors." },
    { "Market", 64, function() ns.Market.Toggle() end, "SalvagerMarketFrame", "Opens or closes the market charts: "
        .. "the price of each material over time, from your scans." },
    { "Log", 48, function() ns.LogWindow.Toggle() end, "SalvagerLogFrame", "Opens or closes the log: what the addon "
        .. "did, and any error." },
}
local PAD, GAP = 12, 4

local function build()
    local w = PAD * 2 + 4   -- (the bar starts its first button 2 px in, and keeps 2 px at its end)
    for i, b in ipairs(BUTTONS) do w = w + b[2] + (i > 1 and GAP or 0) end
    f = W.Window("SalvagerMiniFrame", "Salvager", "mini", w, 66, w, 66, true)
    f.launcher = true   -- (not a window the main window opens or closes)
    for i = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[i] == "SalvagerMiniFrame" then table.remove(UISpecialFrames, i) end
    end
    local bar = W.Bar(f, "footer"):PlaceBottom(8, PAD, PAD)
    MiniPanel.bar, MiniPanel.buttons = bar, {}
    for i, b in ipairs(BUTTONS) do
        local button = W.Button(bar, b[1], b[2], function()
            -- The windows opened from here stay on their own (owner "panel").
            W.opening = "panel"
            local ok, err = pcall(b[3])
            W.opening = nil
            local win = b[4] and _G[b[4]]
            if win and win:IsShown() then win.owner = "panel" end
            if not ok then ns.Log("ERROR in the mini panel's %s button: %s", b[1], tostring(err)) end
        end, b[5])
        bar:Add(button, b[2], i > 1 and GAP or nil)
        MiniPanel.buttons[b[1]] = button
    end
end

function MiniPanel.Show()
    if not f then build() end
    f.UserShow()
end

function MiniPanel.Hide()
    if f and f:IsShown() then f:Hide() end
end

function MiniPanel.Toggle()
    if not f then build() end
    f.UserToggle()
end

function MiniPanel.Frame() return f end

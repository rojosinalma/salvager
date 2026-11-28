-- Salvager: the mini panel (UI.md Layout 5, Controls 13). A small window of buttons, one per Salvager window, in two
-- columns: Salvager, Ledger, Materials, Limits at the left; Reports, Charts, Log, Options at the right; Disenchant
-- across both under them (SDD 108d, 114, 127). It is where the other windows open from (the main window's footer has
-- no window buttons since 0.4.0): always on, at the auction house and away from it, with the main window or without,
-- shown or hidden as the player left it (its X, Shift + left click on the minimap button), remembered across
-- sessions. The windows it opens stay on their own: closing the main window does not close them. Escape leaves it:
-- it is a launcher, like the minimap button.
local _, ns = ...

local W = ns.Widgets

local MiniPanel = {}
ns.MiniPanel = MiniPanel

local f

local function materials()
    if ns.Materials.IsPoppedOut() then ns.Materials.PutBack() else ns.Materials.PopOut() end
end

-- The buttons: label, what a click does, the window it opens (its owner is "panel"), and the help. In rows of two
-- (left, right); a row of one is as wide as both.
local ROWS = {
    { { "Salvager", function() ns.UI.Show() end, nil, "Opens the main window: at the auction house the Gear and "
        .. "Materials tabs with the scans; elsewhere what it can show (the lists of the last scan, your settings)." },
      { "Reports", function() ns.Reports.Toggle() end, "SalvagerReportsFrame", "Opens or closes the reports: your "
        .. "gold, the profit of your gear, your materials, your competitors and the odds (on the tab you saw last)." } },
    { { "Ledger", function() ns.LedgerWindow.Toggle() end, "SalvagerLedgerFrame", "Opens or closes the ledger: your "
        .. "sales, purchases and competition, and the accuracy of the forecasts." },
      { "Charts", function() ns.Market.Toggle() end, "SalvagerMarketFrame", "Opens or closes the charts: the price of "
        .. "each material over time, from your scans, your profit by day, the bands and the time of day." } },
    { { "Materials", materials, "SalvagerMaterialsFrame", "Opens or closes the materials list in a window of its own: "
        .. "price, stock, average cost, break-even, and Post." },
      { "Log", function() ns.LogWindow.Toggle() end, "SalvagerLogFrame", "Opens or closes the log: what the addon "
        .. "did, and any error." } },
    { { "Limits", function() ns.LimitsWindow.Toggle() end, "SalvagerLimitsFrame", "Opens or closes the buy limits: "
        .. "the most the addon lets you pay per item level band, for armor and for weapons. You can set your own." },
      { "Options", function() ns.Options.Open() end, nil, "Opens the addon's options." } },
    { { "Disenchant", function() ns.DisenchantPanel.Toggle() end, "SalvagerDisenchantFrame", "Opens or closes the "
        .. "Disenchant panel: the gear of your purchases in your bags, and a button that disenchants the next piece." } },
}
local PAD, GAP, BUTTON_W, ROW_GAP = 12, 4, 92, 4
local TOP = 28   -- under the title bar

local function build()
    local w = PAD * 2 + 4 + 2 * BUTTON_W + GAP   -- (a bar starts its first button 2 px in, and keeps 2 px at its end)
    local h = TOP + #ROWS * (W.BAR_H.footer + ROW_GAP) + 6
    f = W.Window("SalvagerMiniFrame", "Salvager", "mini", w, h, w, h, true)
    f.launcher = true   -- (not a window the main window opens or closes)
    for i = #UISpecialFrames, 1, -1 do
        if UISpecialFrames[i] == "SalvagerMiniFrame" then table.remove(UISpecialFrames, i) end
    end
    MiniPanel.bars, MiniPanel.buttons = {}, {}
    for r, row in ipairs(ROWS) do
        local bar = W.Bar(f, "footer"):Place(TOP + (r - 1) * (W.BAR_H.footer + ROW_GAP), PAD, PAD)
        MiniPanel.bars[r] = bar
        local width = #row == 1 and (2 * BUTTON_W + GAP) or BUTTON_W
        for i, b in ipairs(row) do
            local button = W.Button(bar, b[1], width, function()
                -- The windows opened from here stay on their own (owner "panel").
                W.opening = "panel"
                local ok, err = pcall(b[2])
                W.opening = nil
                local win = b[3] and _G[b[3]]
                if win and win:IsShown() then win.owner = "panel" end
                if not ok then ns.Log("ERROR in the mini panel's %s button: %s", b[1], tostring(err)) end
            end, b[4])
            bar:Add(button, width, i > 1 and GAP or nil)
            MiniPanel.buttons[b[1]] = button
        end
    end
    MiniPanel.bar = MiniPanel.bars[#MiniPanel.bars]
end

function MiniPanel.Show()
    if not f then build() end
    f.UserShow()
end

--- Hides it and remembers that (its X does the same).
function MiniPanel.Hide()
    if f and f:IsShown() then f.UserHide() end
end

function MiniPanel.Toggle()
    if not f then build() end
    f.UserToggle()
    ns.Log("mini panel %s", f:IsShown() and "shown" or "hidden")
end

--- At login: shown unless the player hid it (windows.mini.open == false).
function MiniPanel.Restore()
    local saved = ns.db.windows.mini
    if saved and saved.open == false then return end
    if not f then build() end
    f:Show()
end

ns.On("SALVAGER_READY", function() MiniPanel.Restore() end)

function MiniPanel.Frame() return f end

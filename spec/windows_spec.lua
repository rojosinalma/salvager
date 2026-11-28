-- The windows of 0.3.137 (the user, 2026-11-27): the Play/Stop toggle, the main window that closes what it opened,
-- Minimize and the mini panel, the minimap button away from the auction house, every window away from it, and the
-- repeated undercut check in the Ledger's Sales footer.
local wow = require("spec.wow")

describe("Salvager windows (0.3.137)", function()
    local env, ns
    local DUST = 11083

    local function answer(n)
        for _ = 1, n or 20 do
            wow.tick(ns, 0.2)
            local c = ns.Queue.current
            if c and c.commodity then wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", c.commodity) end
        end
    end
    local function errors()
        local out = {}
        for _, m in ipairs(env.chat) do if m:lower():find("error", 1, true) then out[#out + 1] = m end end
        for _, l in ipairs(ns.db.log) do if l:find("ERROR", 1, true) then out[#out + 1] = l end end
        return table.concat(out, "\n")
    end
    -- Escape, as the client does it: every frame named in UISpecialFrames that shows is hidden.
    local function escape()
        for _, name in ipairs(UISpecialFrames) do
            local fr = _G[name]
            if fr and fr:IsShown() then fr:Hide() end
        end
    end

    setup(function()
        env = wow.install()
        env.items[DUST] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        env.ah.commodities[DUST] = { { unitPrice = 430, quantity = 50, numOwnerItems = 0 },
            { unitPrice = 500, quantity = 20, numOwnerItems = 20 } }
        env.ah.owned = { { auctionID = 1, itemKey = { itemID = DUST }, status = 0, quantity = 20, timeLeftSeconds = 40000,
            buyoutAmount = 500 } }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
    end)

    it("works away from the auction house: every window, tab and subtab, and what needs it is off with the reason", function()
        -- The minimap button opens the mini panel there, not the main window.
        local mm = _G.SalvagerMinimapButton
        mm.scripts.OnClick(mm, "LeftButton")
        local panel = ns.MiniPanel.Frame()
        assert.is_true(panel:IsShown())
        assert.is_falsy(_G.SalvagerFrame and _G.SalvagerFrame:IsShown())
        for _, name in ipairs({ "Ledger", "Reports", "Market", "Materials", "Log", "Salvager" }) do
            ns.MiniPanel.buttons[name]:Click()
        end
        for _, global in ipairs({ "SalvagerLedgerFrame", "SalvagerReportsFrame", "SalvagerMarketFrame", "SalvagerMaterialsFrame",
            "SalvagerLogFrame" }) do
            local win = _G[global]
            assert.is_true(win:IsShown(), global)
            assert.are.equal("panel", rawget(win, "owner"), global)
            -- Every tab and subtab draws.
            local function walk(x)
                for _, c in ipairs(x._children) do
                    if (rawget(c, "uiKind") == "tab" or rawget(c, "uiKind") == "subtab") and c:IsVisible() then c:Click() end
                    walk(c)
                end
            end
            walk(win)
            walk(win)
        end
        assert.are.equal("", errors())
        -- The main window shows what it can; its scans are off, each with the reason.
        assert.is_true(_G.SalvagerFrame:IsShown())
        assert.is_false(panel:IsShown())                         -- the main window leads again
        local play = ns.UI.playButton
        assert.is_false(play:IsEnabled())
        assert.are.equal(ns.Widgets.AH_CLOSED, play.reason)
        for _, b in ipairs(ns.UI.scanButtons) do
            assert.is_false(b:IsEnabled())
            assert.are.equal(ns.Widgets.AH_CLOSED, b.reason)
        end
        -- The Ledger's Sales actions too.
        ns.LedgerWindow.tabs.sales:Click()
        ns.LedgerWindow.salesTabs.open:Click()
        for _, b in ipairs({ ns.LedgerWindow.checkButton, ns.LedgerWindow.cancelButton, ns.LedgerWindow.autoButton }) do
            assert.is_false(b:IsEnabled())
            assert.are.equal(ns.Widgets.AH_CLOSED, b.reason)
        end
        -- Windows opened from the mini panel stay when the main window closes.
        _G.SalvagerFrame:Hide()
        assert.is_true(_G.SalvagerLedgerFrame:IsShown())
        assert.is_true(_G.SalvagerReportsFrame:IsShown())
        for _, global in ipairs({ "SalvagerLedgerFrame", "SalvagerReportsFrame", "SalvagerMarketFrame", "SalvagerLogFrame" }) do
            _G[global]:Hide()
        end
    end)

    it("keeps its width on a tab change even when the list's width lags its new anchors (no full-screen window)",
        function()
        local realWidth = ns.Widgets.TextWidth
        ns.Widgets.TextWidth = function(t)
            if not t then return 0 end
            local plain = t:gsub("|T.-|t", "\1\1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            return #plain * 6
        end
        ns.UI.Show()
        local f = _G.SalvagerFrame
        local width = 940
        f.GetWidth = function() return width end
        f.SetWidth = function(_, w) width = w end
        ns.UI.list.GetWidth = function() return 0 end            -- the client has not laid the list out again yet
        ns.UI.view = "materials"
        ns.UI.Refresh()
        assert.is_true(width < 1920, tostring(width))
        assert.are.equal(math.max(ns.UI.leastWidth, math.ceil(ns.UI.tableNeed + 4 + 42)), width)
        assert.is_true(ns.UI.leastWidth > 0)   -- (measured from its rows of controls, SDD 120)
        ns.UI.view = "deals"
        ns.UI.Refresh()
        ns.Widgets.TextWidth = realWidth
        ns.UI.list.GetWidth, f.GetWidth, f.SetWidth = nil, nil, nil
        f:Hide()
    end)

    it("has one Play/Stop toggle: play while no scan runs, stop while one does", function()
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        wow.tick(ns, 0.5)
        local play = ns.UI.playButton
        assert.is_true(play:IsEnabled())
        assert.is_nil(rawget(play, "reason"))
        assert.is_false(play.running)
        play:Click()
        assert.is_true(ns.Scanner.auto)
        ns.UI.Refresh()
        assert.is_true(play.running)                             -- the stop square
        play.scripts.OnEnter(play)
        play:Click()
        assert.is_false(ns.Scanner.auto)
        ns.UI.Refresh()
        assert.is_false(play.running)
        for _, b in ipairs(ns.UI.scanButtons) do assert.is_true(b:IsEnabled()) end
    end)

    it("closes every window it opened with X or Escape, and brings them back with it", function()
        ns.LedgerWindow.Show()
        ns.LogWindow.Show()
        assert.are.equal("main", rawget(_G.SalvagerLedgerFrame, "owner"))
        escape()
        assert.is_false(_G.SalvagerFrame:IsShown())
        assert.is_false(_G.SalvagerLedgerFrame:IsShown())
        assert.is_false(_G.SalvagerLogFrame:IsShown())
        ns.UI.Show()
        assert.is_true(_G.SalvagerLedgerFrame:IsShown())
        assert.is_true(_G.SalvagerLogFrame:IsShown())
        _G.SalvagerFrame:Hide()                                  -- the X
        assert.is_false(_G.SalvagerLedgerFrame:IsShown())
        assert.is_false(_G.SalvagerLogFrame:IsShown())
        assert.is_true(ns.db.windows.ledger.open)                -- still remembered
        ns.UI.Show()
    end)

    it("minimizes to the mini panel: the other windows stay, the panel stays until its X or the main window", function()
        assert.is_true(_G.SalvagerLedgerFrame:IsShown())
        ns.UI.minimizeButton:Click()
        assert.is_false(_G.SalvagerFrame:IsShown())
        assert.is_true(_G.SalvagerLedgerFrame:IsShown())
        local panel = ns.MiniPanel.Frame()
        assert.is_true(panel:IsShown())
        escape()                                                 -- Escape leaves the launcher
        assert.is_true(panel:IsShown())
        -- At the auction house the minimap button opens the main window, as before.
        local mm = _G.SalvagerMinimapButton
        mm.scripts.OnClick(mm, "LeftButton")
        assert.is_true(_G.SalvagerFrame:IsShown())
        assert.is_false(panel:IsShown())
    end)

    it("checks undercuts again and again while it is on, waits while you buy, and is off when the auction house closes",
        function()
        ns.LedgerWindow.Show()
        ns.LedgerWindow.tabs.sales:Click()
        local auto = ns.LedgerWindow.autoButton
        assert.is_true(auto:IsEnabled())
        auto:Click()
        assert.is_true(ns.Listings.auto)
        answer(10)
        assert.is_nil(ns.Listings.checking)
        assert.are.equal(70, ns.Listings.Undercut(ns.db.listings.rows[1]))
        local said
        ns.LedgerWindow.Refresh()
        assert.is_true(auto.running)
        -- Not again before the interval.
        local sent = #env.ah.sent
        wow.tick(ns, ns.Listings.AUTO_INTERVAL - 2)
        assert.is_nil(ns.Listings.checking)
        -- Not while a purchase is on its way.
        local done = wow.buying(ns)
        wow.tick(ns, 2.5)                                        -- past the interval
        assert.is_nil(ns.Listings.checking)
        done()
        said = #env.chat                                         -- (its answer: "could not buy")
        wow.tick(ns, 1.2)
        assert.is_table(ns.Listings.checking)
        answer(10)
        assert.is_nil(ns.Listings.checking)
        assert.is_true(#env.ah.sent > sent)
        assert.are.equal(said, #env.chat)                        -- the same count: a repeated check says nothing
        wow.fire(ns, "AUCTION_HOUSE_CLOSED")
        assert.is_false(ns.Listings.auto)
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        assert.is_false(ns.Listings.auto)                        -- not remembered for the next visit
    end)
end)

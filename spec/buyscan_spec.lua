local wow = require("spec.wow")

-- Purchases during a scan (SDD 105): the game needs a click for every purchase and loses one sent while the auction
-- house is busy or after a browse made its search stale. Nothing may be lost in silence.
describe("Buying during a scan", function()
    local env, ns
    local BOOTS = 5001
    local BOOTS_LINK = "|cnIQ2:|Hitem:5001::::::::30:::::|h[Test Boots]|h|r"
    local KEY = { itemID = BOOTS, itemLevel = 28, itemSuffix = 0 }

    local function count(kind)
        local n = 0
        for _, s in ipairs(env.ah.sent) do if s.kind == kind then n = n + 1 end end
        return n
    end
    local function said(text)
        for _, m in ipairs(env.chat) do if m:find(text, 1, true) then return true end end
        return false
    end
    local function logged(text)
        for _, m in ipairs(ns.db.log) do if m:find(text, 1, true) then return m end end
        return nil
    end
    local function click(b) b.scripts.OnClick(b) end

    -- A whole scan that finds the boots at 100 (auction 10): the Gear list then holds that deal.
    local function scanOnce()
        ns.Scanner.Stop()
        env.ah.fullBrowse = true
        env.ah.browse = { { itemKey = KEY, minPrice = 100, totalQuantity = 1 } }
        env.ah.itemResults[BOOTS] = { { auctionID = 10, buyoutAmount = 100, itemLink = BOOTS_LINK } }
        ns.Scanner.Scan(true)
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        for _ = 1, 60 do
            local task = ns.Queue.current
            if task and task.itemKey then wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", task.itemKey) end
            wow.tick(ns, 0.2)
            if ns.Scanner.state == "idle" then break end
        end
        ns.Scanner.Stop()
        wow.tick(ns, 1.2)
        assert.are.equal(1, #ns.Scanner.deals)
        return ns.Scanner.deals[1]
    end

    setup(function()
        env = wow.install()
        env.items[BOOTS] = { name = "Test Boots", quality = 2, ilvl = 28, req = 23, classID = 4 }
        for _, m in ipairs({ { 11083, "Soul Dust" }, { 11082, "Greater Astral Essence" }, { 11084, "Large Glimmering Shard" } }) do
            env.items[m[1]] = { name = m[2], quality = 1, ilvl = 1, classID = 7 }
        end
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        ns.db.settings.minProfit = 0
        ns.db.settings.minReturn = 0
        ns.db.settings.gearClasses = "armor"
        ns.db.settings.priceRescan = 0
        for _, id in ipairs({ 11083, 11082, 11084 }) do ns.db.prices[id] = { p = 433, units = 20, t = env.clock } end
        ns.db.buyResendBlocked = true   -- the game refuses a purchase without a click (SDD 74c)
        ns.UI.Show()
        ns.UI.view = "deals"
        ns.UI.Refresh()
    end)

    after_each(function()
        ns.UI.listArea.mouseOver = nil
        env.ah.ready = true
        wow.tick(ns, 1.2)
    end)

    it("searches a deal again first when a browse came after its search, then offers Buy now; that click buys", function()
        local deal = scanOnce()
        -- The next round's browse is on its way: the deal's search is stale now.
        env.ah.fullBrowse = false
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")           -- page 1; page 2 is asked for
        local pages = count("more")
        local bids = #env.ah.bids
        ns.Scanner.Buy(deal)
        assert.are.equal(bids, #env.ah.bids)                           -- not sent into the void
        assert.are.equal("search", deal.wait)
        assert.is_true(said("searching it again first"))
        assert.is_truthy(logged("a browse came after its search"))
        wow.tick(ns, 0.2)
        local task = ns.Queue.current
        assert.is_table(task)                                          -- its search goes, past the browse and the hold
        assert.are.equal(BOOTS, task.itemKey.itemID)
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", {})         -- a late page: the next is not asked for
        wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", KEY)
        assert.is_true(deal.buyNow)
        assert.is_true(said("auction house ready: click Buy now for"))
        ns.UI.Refresh()
        assert.are.equal("Buy now", ns.UI.buyTop:GetText())           -- Buy Top is for it, lit
        assert.is_true(ns.UI.buyTop:IsEnabled())
        assert.are.equal(pages, count("more"))                         -- the browse held meanwhile
        click(ns.UI.buyTop)
        assert.are.same({ id = 10, amount = 100 }, env.ah.bids[#env.ah.bids])
        assert.is_true(deal.pending)
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 10)
        ns.Scanner.Stop()
    end)

    it("searches a stale deal again as soon as the mouse is on Buy Top, so the click buys at once", function()
        local deal = scanOnce()
        env.ah.fullBrowse = false
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")           -- a browse after the deal's search: stale
        assert.is_true(deal.epoch < ns.Scanner.browseEpoch)
        ns.UI.Refresh()
        ns.UI.buyTop.mouseOver = true                                  -- the mouse comes to Buy Top
        wow.tick(ns, 0.2)
        assert.is_truthy(logged("the mouse is on its Buy and a browse came after its search"))
        local task = ns.Queue.current
        assert.is_table(task)                                          -- its search goes first, past the hold
        assert.are.equal(BOOTS, task.itemKey.itemID)
        wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", KEY)
        ns.UI.Refresh()
        local fresh = ns.Scanner.deals[1]
        assert.is_true(fresh.epoch >= ns.Scanner.browseEpoch)          -- current again
        local bids = #env.ah.bids
        click(ns.UI.buyTop)                                            -- one click: it buys
        assert.are.equal(bids + 1, #env.ah.bids)
        assert.are.equal(10, env.ah.bids[#env.ah.bids].id)
        ns.UI.buyTop.mouseOver = nil
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 10)
        ns.Scanner.Stop()
    end)

    it("waits for a busy auction house instead of losing the click, then offers Buy now", function()
        local deal = scanOnce()
        env.ah.ready = false                                           -- a request of a scan is in flight
        local bids = #env.ah.bids
        ns.Scanner.Buy(deal)
        assert.are.equal(bids, #env.ah.bids)
        assert.are.equal("ready", deal.wait)
        assert.is_true(said("auction house busy"))
        assert.is_truthy(logged("auction house busy"))
        assert.is_truthy(logged("in flight: scan idle"))
        ns.UI.Refresh()
        assert.is_false(ns.UI.buyTop:IsEnabled())                      -- "...", with the reason in its tooltip
        assert.is_truthy(rawget(ns.UI.buyTop, "reason"):find("Waiting for the auction house", 1, true))
        ns.Queue.Add({ commodity = 11083, onResult = function() end, onFail = function() end })
        wow.tick(ns, 2)
        assert.is_nil(ns.Queue.current)                                -- everything else holds
        env.ah.ready = true
        wow.fire(ns, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
        assert.is_true(deal.buyNow)
        assert.is_true(said("auction house ready: click Buy now for"))
        ns.Scanner.Buy(deal)                                           -- the click on Buy now
        assert.are.same({ id = 10, amount = 100 }, env.ah.bids[#env.ah.bids])
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 10)
        ns.Queue.Clear()
    end)

    it("says a purchase with no answer after 3 s, and still books it when the answer comes later", function()
        local deal = scanOnce()
        ns.Scanner.Buy(deal)
        assert.are.equal(10, env.ah.bids[#env.ah.bids].id)
        wow.tick(ns, 2.5)
        assert.is_false(said("no answer yet"))
        wow.tick(ns, 0.7)
        assert.is_true(said("no answer yet for"))
        assert.is_false(deal.pending)                                  -- Buy is free again
        local before = #(ns.db.ledger.purchases[BOOTS] or {})
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 10)
        assert.are.equal(before + 1, #ns.db.ledger.purchases[BOOTS])
    end)

    it("holds the next browse page and the next search while the mouse is over the Gear list", function()
        scanOnce()
        env.ah.fullBrowse = false
        ns.Scanner.Scan()
        ns.UI.listArea.mouseOver = true
        wow.tick(ns, 0.2)
        local pages = count("more")
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        wow.tick(ns, 6)                                                -- not even the stall watcher asks
        assert.are.equal(pages, count("more"))
        ns.UI.listArea.mouseOver = nil
        wow.tick(ns, 0.5)
        assert.are.equal(pages, count("more"))                         -- a second after the mouse left
        wow.tick(ns, 1)
        assert.are.equal(pages + 1, count("more"))
        ns.Scanner.Stop()
        -- A search waits too.
        ns.UI.listArea.mouseOver = true
        wow.tick(ns, 0.2)
        ns.Queue.Add({ commodity = 11083, onResult = function() end, onFail = function() end })
        wow.tick(ns, 3)
        assert.is_nil(ns.Queue.current)
        ns.UI.listArea.mouseOver = nil
        wow.tick(ns, 1.5)
        assert.is_table(ns.Queue.current)
        ns.Queue.Clear()
    end)

    it("does not start a new pass while the mouse is over the Gear list", function()
        scanOnce()
        ns.db.settings.gearClasses = "both"
        env.ah.fullBrowse = false
        ns.Scanner.Scan()
        assert.are.equal("Uncommon Armor", ns.Scanner.passName)
        ns.UI.listArea.mouseOver = true
        wow.tick(ns, 0.2)
        local browses = count("browse")
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_FAILURE")                   -- the pass ends: the next one waits
        wow.tick(ns, 3)
        assert.are.equal("Uncommon Armor", ns.Scanner.passName)
        assert.are.equal(browses, count("browse"))
        ns.UI.listArea.mouseOver = nil
        wow.tick(ns, 1.5)
        assert.are.equal("Uncommon Weapons", ns.Scanner.passName)
        ns.Scanner.Stop()
        ns.db.settings.gearClasses = "armor"
    end)

    it("shows the gold and the bag space left of the Play/Stop toggle, live, and the footer fits the smallest width", function()
        local bar = ns.UI.footerBar
        local at = {}
        for i, r in ipairs(bar.items) do at[r] = i end
        local play = bar.items[at[ns.UI.bags] - 1]
        assert.are.equal(at[ns.UI.buyTop] + 1, at[play])              -- Buy Top, then the Play/Stop toggle, from the right
        assert.are.equal(ns.UI.playButton, play)
        assert.are.equal(at[ns.UI.bags] + 1, at[ns.UI.gold])          -- then the bag space, then the gold
        assert.are.same({ "RIGHT", play, "LEFT", -12, 0 }, rawget(ns.UI.bags, "points")[1])
        assert.are.same({ "RIGHT", ns.UI.bags, "LEFT", -10, 0 }, rawget(ns.UI.gold, "points")[1])
        local frame = bar:GetParent()
        assert.is_true(bar.used <= rawget(frame, "minWidth") - 20)
        env.money = 123456
        wow.fire(ns, "PLAYER_MONEY")
        wow.tick(ns, 0.3)
        assert.are.equal(ns.Money(123456), ns.UI.gold:GetText())
        env.bagFree[0] = 1
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        wow.tick(ns, 0.3)
        assert.is_truthy(ns.UI.bags:GetText():find("1/4", 1, true))
        assert.are.equal(ns.LedgerWindow.BagText(), ns.UI.bags:GetText())
        env.bagFree[0] = nil
    end)
end)

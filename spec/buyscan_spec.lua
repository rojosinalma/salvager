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

    -- A whole scan that finds `n` boots (default 1) at 100, 101, ... (auctions 10, 11, ...): the Gear list then holds
    -- those deals.
    local function scanMany(n)
        n = n or 1
        ns.Scanner.Stop()
        env.ah.fullBrowse = true
        env.ah.browse = { { itemKey = KEY, minPrice = 100, totalQuantity = n } }
        local results = {}
        for i = 1, n do
            results[i] = { auctionID = 9 + i, buyoutAmount = 99 + i, itemLink = BOOTS_LINK }
        end
        env.ah.itemResults[BOOTS] = results
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
        assert.are.equal(n, #ns.Scanner.deals)
        return ns.Scanner.deals[1]
    end
    local function scanOnce() return scanMany(1) end
    -- The chat lines since line `from` that hold `text`.
    local function saidSince(from, text)
        local n = 0
        for i = from + 1, #env.chat do if env.chat[i]:find(text, 1, true) then n = n + 1 end end
        return n
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
        for _, row in ipairs(ns.UI.rows) do row.mouseOver, row.buy.mouseOver = nil, nil end
        ns.UI.buyTop.mouseOver = nil
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

    -- A whole scan as the auction house answers it: every browse request and every search is answered at the next
    -- tick, `pages` pages per pass. Returns the ticks (0.1 s each) from Scan until the scan is idle again, and the log
    -- line of its holds.
    local function timedScan(pages)
        ns.Scanner.Stop()
        ns.Queue.Clear()
        wow.tick(ns, 1.2)
        env.ah.fullBrowse = false
        env.ah.browse = { { itemKey = KEY, minPrice = 100, totalQuantity = 1 } }
        env.ah.itemResults[BOOTS] = { { auctionID = 10, buyoutAmount = 100, itemLink = BOOTS_LINK } }
        local seen, inPass = #env.ah.sent, 0
        ns.Scanner.Scan(true)
        local ticks = 0
        while ticks < 1200 do
            for i = seen + 1, #env.ah.sent do
                local kind = env.ah.sent[i].kind
                if kind == "browse" then inPass = 0 end
                if kind == "browse" or kind == "more" then
                    inPass = inPass + 1
                    env.ah.fullBrowse = inPass >= pages
                    wow.fire(ns, kind == "browse" and "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED"
                        or "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", {})
                end
            end
            seen = #env.ah.sent
            local task = ns.Queue.current
            if task and task.itemKey then wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", task.itemKey) end
            if ns.Scanner.state == "idle" then break end
            wow.tick(ns, 0.1)
            ticks = ticks + 1
        end
        assert.are.equal("idle", ns.Scanner.state)
        local held
        for i = #ns.db.log, 1, -1 do
            if ns.db.log[i]:find("scan held for purchases", 1, true) then held = ns.db.log[i] break end
        end
        return ticks, held
    end

    it("scans as fast with the mouse over the list, a row or its Buy as with the mouse elsewhere", function()
        scanOnce()
        ns.UI.Refresh()
        timedScan(5)                                                   -- (the first one starts at another tick phase)
        local elsewhere, held = timedScan(5)
        assert.is_truthy(held:find("not at all", 1, true))             -- the end of the scan says its holds
        ns.UI.listArea.mouseOver = true                                -- reading the list
        local overList = timedScan(5)
        ns.UI.Refresh()
        local row = ns.UI.rows[1]
        assert.is_true(row:IsShown() and row.buy:IsShown())
        row.mouseOver, row.buy.mouseOver = true, true                  -- on a row's Buy
        local onBuy, heldOnBuy = timedScan(5)
        row.mouseOver, row.buy.mouseOver = nil, nil
        ns.UI.buyTop.mouseOver = true                                  -- on Buy Top
        local onTop = timedScan(5)
        assert.is_true(overList <= elsewhere)
        assert.is_true(onBuy <= elsewhere)
        assert.is_true(onTop <= elsewhere)
        assert.is_truthy(heldOnBuy:find("not at all", 1, true))
        ns.Scanner.Stop()
    end)

    it("asks for the next page at once with the mouse on a Buy, and a click during the browse still buys", function()
        scanOnce()
        ns.UI.Refresh()
        env.ah.fullBrowse = false
        ns.Scanner.Scan()
        ns.UI.rows[1].buy.mouseOver = true
        wow.tick(ns, 0.2)
        assert.is_false(ns.Scanner.Buying())
        local pages = count("more")
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        assert.are.equal(pages + 1, count("more"))                     -- no hold under the mouse
        -- The click (on a deal a browse made stale) still buys, through its search: the page waits for it.
        ns.Queue.Clear()
        local deal = ns.Scanner.deals[1]
        local bids = #env.ah.bids
        ns.Scanner.Buy(deal)
        if deal.wait == "search" then
            wow.tick(ns, 0.2)
            wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", KEY)
            assert.is_true(deal.buyNow)
            ns.Scanner.Buy(deal)
        end
        assert.are.equal(bids + 1, #env.ah.bids)
        assert.are.equal(10, env.ah.bids[#env.ah.bids].id)
        pages = count("more")
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", {})
        wow.tick(ns, 0.5)
        assert.are.equal(pages, count("more"))                         -- the purchase on its way holds the page
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 10)
        wow.tick(ns, 1.5)
        assert.are.equal(pages + 1, count("more"))                     -- answered: the browse goes on
        ns.Scanner.Stop()
        ns.Queue.Clear()
    end)

    it("does not send a Buy now click made while the auction house is busy again: it stays Buy now", function()
        local deal = scanOnce()
        env.ah.ready = false
        ns.Scanner.Buy(deal)                                           -- a row's Buy: it waits
        assert.are.equal("ready", deal.wait)
        env.ah.ready = true
        wow.fire(ns, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
        assert.is_true(deal.buyNow)
        env.ah.ready = false                                           -- busy again before the click
        local bids = #env.ah.bids
        ns.Scanner.Buy(deal)                                           -- the click on Buy now
        assert.are.equal(bids, #env.ah.bids)                           -- not sent into the void
        assert.is_true(deal.buyNow)
        assert.is_falsy(deal.pending)
        ns.UI.Refresh()
        assert.are.equal("Buy now", ns.UI.rows[1].buy:GetText())
        env.ah.ready = true
        ns.Scanner.Buy(deal)                                           -- ready: this click buys
        assert.are.same({ id = 10, amount = 100 }, env.ah.bids[#env.ah.bids])
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 10)
        ns.Queue.Clear()
    end)

    it("calls no purchase lost when three are answered in order, a second apart", function()
        scanMany(3)
        local list = { unpack(ns.Scanner.deals) }
        local chat = #env.chat
        local before = #(ns.db.ledger.purchases[BOOTS] or {})
        for _, d in ipairs(list) do ns.Scanner.Buy(d) end
        local bids = #env.ah.bids
        assert.are.same({ 10, 11, 12 }, { env.ah.bids[bids - 2].id, env.ah.bids[bids - 1].id, env.ah.bids[bids].id })
        wow.tick(ns, 2.5)
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", list[1].auctionID)
        wow.tick(ns, 1)                                                -- 3.5 s after its click, 1 s after the one before
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", list[2].auctionID)
        wow.tick(ns, 1)                                                -- 4.5 s after its click
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", list[3].auctionID)
        assert.are.equal(0, saidSince(chat, "no answer yet"))
        assert.are.equal(before + 3, #ns.db.ledger.purchases[BOOTS])
        ns.Queue.Clear()
    end)

    it("buys one auction per answered purchase when Buy Top is clicked fast, nothing lost, no chat flood", function()
        scanMany(10)
        ns.UI.Refresh()
        local chat, bids = #env.chat, #env.ah.bids
        local log = #ns.db.log
        local before = #(ns.db.ledger.purchases[BOOTS] or {})
        local bought = {}
        for i = 1, 10 do
            wow.tick(ns, 0.2)
            assert.are.equal("Buy Top", ns.UI.buyTop:GetText())
            assert.is_true(ns.UI.buyTop:IsEnabled())
            click(ns.UI.buyTop)                                        -- ready: it buys the next best one at once
            assert.are.equal(bids + i, #env.ah.bids)
            local id = env.ah.bids[#env.ah.bids].id
            assert.is_nil(bought[id])
            bought[id] = true
            env.ah.ready = false                                       -- the auction house answers the purchase
            wow.tick(ns, 0.2)
            assert.is_false(ns.UI.buyTop:IsEnabled())
            if i < 10 then                                             -- (after the last one, nothing is left)
                assert.are.equal("...", ns.UI.buyTop:GetText())
                assert.is_truthy(rawget(ns.UI.buyTop, "reason"):find("still answering your last purchase", 1, true))
            end
            for _ = 1, 3 do click(ns.UI.buyTop) wow.tick(ns, 0.3) end   -- fast clicks meanwhile: nothing
            assert.are.equal(bids + i, #env.ah.bids)
            -- The answer: the auction is gone from the list, and the auction house is ready again.
            for k, r in ipairs(env.ah.itemResults[BOOTS]) do
                if r.auctionID == id then table.remove(env.ah.itemResults[BOOTS], k) break end
            end
            wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", id)
            env.ah.ready = true
            wow.fire(ns, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
        end
        assert.are.equal(10, #env.ah.bids - bids)
        assert.are.equal(before + 10, #ns.db.ledger.purchases[BOOTS])  -- every one booked, none lost
        assert.are.equal(10, #env.chat - chat)                         -- one line per purchase: "bought ..."
        assert.are.equal(10, saidSince(chat, "bought "))
        for _, d in pairs(ns.Scanner.deals) do assert.is_falsy(d.wait or d.buyNow) end
        local busyLines = 0
        for i = log + 1, #ns.db.log do
            if ns.db.log[i]:find("Buy Top click on", 1, true) then busyLines = busyLines + 1 end
        end
        assert.is_true(busyLines <= 10)                                -- one per busy spell, not one per click
        ns.Queue.Clear()
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

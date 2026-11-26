local wow = require("spec.wow")
local helper = require("spec.helper")

describe("Buy path safety", function()
    local env, ns
    local BOOTS, ODD = 5001, 5002
    local BOOTS_LINK = "|cnIQ2:|Hitem:5001::::::::30:::::|h[Test Boots]|h|r"

    local function fresh()
        for _, id in ipairs({ 11083, 11082, 11084 }) do ns.db.prices[id] = { p = 433, units = 20, t = env.clock } end
    end

    -- One scan of `rows` (browse rows) with `results` [itemID] = auctions; returns the deals listed.
    local function scan(browse, results)
        env.ah.fullBrowse = true
        env.ah.browse = browse
        for id, list in pairs(results) do env.ah.itemResults[id] = list end
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        for _ = 1, 40 do
            local task = ns.Queue.current
            if task and task.itemKey then wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", task.itemKey) end
            wow.tick(ns, 0.2)
            if ns.Scanner.state == "idle" then break end
        end
        return ns.Scanner.deals
    end

    local function row(id, price)
        return { itemKey = { itemID = id, itemLevel = 28, itemSuffix = 0 }, minPrice = price, totalQuantity = 1 }
    end

    setup(function()
        env = wow.install()
        env.items[BOOTS] = { name = "Test Boots", quality = 2, ilvl = 28, req = 23, classID = 4 }
        env.items[ODD] = { name = "Odd Boots", ilvl = 28, req = 23, classID = 4 }   -- the game has no quality for it yet
        for _, m in ipairs({ { 11083, "Soul Dust" }, { 11082, "Greater Astral Essence" }, { 11084, "Large Glimmering Shard" } }) do
            env.items[m[1]] = { name = m[2], quality = 1, ilvl = 1, classID = 7 }
        end
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        ns.db.settings.minProfit = 0
        ns.db.settings.gearClasses = "armor"
        ns.db.settings.priceRescan = 0
        fresh()
    end)

    it("reads the quality from the link: Forever's code or the quality color", function()
        assert.are.equal(2, ns.LinkQuality(BOOTS_LINK))
        assert.are.equal(3, ns.LinkQuality("|cff0070dd|Hitem:1|h[x]|h|r"))
        assert.is_nil(ns.LinkQuality("|Hitem:1|h[x]|h"))
    end)

    it("never lists an auction whose own item does not tell its quality", function()
        local deals = scan({ row(BOOTS, 100), row(ODD, 100) }, {
            [BOOTS] = { { auctionID = 10, buyoutAmount = 100, itemLink = BOOTS_LINK } },
            [ODD] = { { auctionID = 11, buyoutAmount = 100, itemLink = "|Hitem:5002::::::::30:::::|h[Odd Boots]|h" } },
        })
        assert.are.equal(1, #deals)
        assert.are.equal(10, deals[1].auctionID)
    end)

    it("does not add a second row for an auction that is being bought", function()
        local deal = ns.Scanner.deals[1]
        ns.Scanner.Buy(deal)
        local deals = scan({ row(BOOTS, 100) }, { [BOOTS] = { { auctionID = 10, buyoutAmount = 100, itemLink = BOOTS_LINK } } })
        assert.are.equal(1, #deals)
        assert.is_true(deals[1].pending)
    end)

    it("leaves a purchase on its way alone when the error answers a post", function()
        ns.NoteRequest("post")
        wow.fire(ns, "AUCTION_HOUSE_SHOW_ERROR")
        assert.is_true(ns.Scanner.deals[1].pending)
        ns.NoteRequest("buy")
        wow.fire(ns, "AUCTION_HOUSE_SHOW_ERROR")
        assert.are.equal(0, #ns.Scanner.deals)
    end)

    it("still books a purchase that completes after it was given up", function()
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 10)
        assert.are.equal(1, #ns.db.ledger.purchases[BOOTS])
    end)

    it("starts a gear scan clicked during a material scan by itself when that scan is done", function()
        ns.Scanner.Stop()
        ns.Prices.scanning = true
        ns.Scanner.Scan(true)
        assert.are.equal("idle", ns.Scanner.state)
        ns.Prices.scanning = false
        wow.tick(ns, 0.2)
        assert.are.equal("browsing", ns.Scanner.state)
        ns.Scanner.Stop()
    end)

    it("asks for the min profit and the min return together: the stricter one sets the limit", function()
        local M = helper.load().Model
        assert.are.same({ 900, "profit" }, { M.MaxBuy(1000, 100) })
        assert.are.same({ 900, "profit" }, { M.MaxBuy(1000, 100, 0) })                -- 0 = off
        assert.are.same({ 869, "return" }, { M.MaxBuy(1000, 100, 15) })               -- 1000 / 1.15
        assert.are.same({ 9000, "profit" }, { M.MaxBuy(10000, 1000, 5) })             -- dear items: the profit
        SlashCmdList.SALVAGER("minreturn 15")
        assert.are.equal(15, ns.db.settings.minReturn)
        local band = ns.Limits()[4].armor
        assert.are.equal(select(2, M.MaxBuy(band.value, ns.db.settings.minProfit, 15)), band.rule)
        SlashCmdList.SALVAGER("minreturn 0")
        assert.are.equal(0, ns.db.settings.minReturn)
    end)

    it("lists the deals by Expected profit or by Return, as the player clicks", function()
        ns.Scanner.deals = {
            { auctionID = 1, itemID = BOOTS, buyout = 10000, profit = 1000, value = 11000, classID = 4 },   -- +10%
            { auctionID = 2, itemID = BOOTS, buyout = 1000, profit = 400, value = 1400, classID = 4 },      -- +40%
        }
        ns.db.settings.dealSort = "profit"
        ns.Scanner.Sort()
        assert.are.equal(1, ns.Scanner.deals[1].auctionID)
        ns.db.settings.dealSort = "return"
        ns.Scanner.Sort()
        assert.are.equal(2, ns.Scanner.deals[1].auctionID)
        assert.are.equal(0.4, ns.Scanner.Return(ns.Scanner.deals[1]))
        ns.db.settings.dealSort = "profit"
        -- A click on the Return title orders the list by it.
        ns.UI.Toggle()
        ns.UI.view = "deals"
        ns.UI.Refresh()
        local title
        for _, fr in ipairs(env.frames) do if rawget(fr, "sortKey") == "return" then title = fr end end
        assert.is_table(title)
        title.scripts.OnMouseUp(title)
        assert.are.equal("return", ns.db.settings.dealSort)
        assert.are.equal(2, ns.Scanner.deals[1].auctionID)
        ns.db.settings.dealSort = "profit"
        ns.Scanner.deals = {}
    end)

    it("takes a dropped request to be the search when one was just sent, not the purchase", function()
        ns.db.buyResendBlocked = true
        local deal = { auctionID = 900, itemID = BOOTS, link = BOOTS_LINK, buyout = 100, value = 500, profit = 400,
            quality = 2, classID = 4, ilvl = 28 }
        ns.Scanner.deals = { deal }
        ns.Scanner.Buy(deal)
        ns.Queue.current = { sentAt = GetTime(), itemKey = { itemID = BOOTS } }
        wow.fire(ns, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
        assert.is_true(deal.pending)                               -- the purchase stays on its way
        ns.Queue.current = nil
        wow.fire(ns, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
        assert.is_false(deal.pending)                              -- no search: it was the purchase
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 900)
        ns.db.buyResendBlocked = nil
        ns.Scanner.deals = {}
    end)

    it("knows a disenchant had the Salvager by its effect, by a result over the table, or by the setting", function()
        local outcomes = ns.Model.Outcomes(2, 4, 28)
        local dust = outcomes.results[1]
        local was = ns.db.settings.salvager
        ns.db.settings.salvager = "auto"
        assert.are.same({ true, "aura" }, { ns.Disenchant.HadSalvager(true, outcomes, { [dust.id] = 1 }) })
        assert.are.same({ true, "result" }, { ns.Disenchant.HadSalvager(false, outcomes, { [dust.id] = dust.max + 1 }) })
        assert.is_false(ns.Disenchant.HadSalvager(false, outcomes, { [dust.id] = dust.max }))
        ns.db.settings.salvager = "on"
        assert.are.same({ true, "setting" }, { ns.Disenchant.HadSalvager(false, outcomes, { [dust.id] = 1 }) })
        ns.db.settings.salvager = was
        -- The buff itself: Boosted Disenchanting, by its spell ID, with its stacks.
        env.auras = { { name = "Warchief's Blessing", spellId = 16609 },
            { name = "Something else", spellId = 1283701, applications = 3 } }
        assert.are.same({ true, 3 }, { ns.Disenchant.SalvagerActive() })
        env.auras = { { name = "Boosted Disenchanting", spellId = 1 } }
        assert.is_true((ns.Disenchant.SalvagerActive()))
        env.auras = { { name = "Warchief's Blessing", spellId = 16609 } }
        assert.is_false((ns.Disenchant.SalvagerActive()))
        env.auras = {}
    end)

    it("never lets a buy limit set by hand go over the value", function()
        assert.is_false(select(2, ns.BuyLimit(2, 4, 30, 1000)))
        ns.db.settings.limitOverride[ns.BandKey(2, 4, 30)] = 5000
        local limit, manual = ns.BuyLimit(2, 4, 30, 1000)
        assert.are.same({ 1000, true }, { limit, manual })
        ns.db.settings.limitOverride = {}
    end)

    it("uses the last price seen for a day at most", function()
        ns.db.prices[11083] = { units = 0, t = env.clock, last = 433, lastT = env.clock - 3600 }
        assert.are.equal(433, ns.PriceOf(11083))
        ns.db.prices[11083].lastT = env.clock - 25 * 3600
        assert.is_nil(ns.PriceOf(11083))
        fresh()
    end)

    it("caps a price that one thin listing pushed far over its recent prices", function()
        local H = helper.load().History
        local h = {}
        for i = 1, 5 do H.Add(h, 1, i * 120, 400 + i, nil, 50) end
        assert.are.equal(math.floor(403 * 1.25 + 0.5), H.Ceiling(h, 1, 700, 20))
        assert.are.equal(403, H.Ceiling(h, 1, 700, 1))           -- 1 unit listed: the median at most
        assert.is_nil(H.Ceiling({ [1] = { { t = 600, p = 400 } } }, 1, 700, 1))   -- too little history to say
        ns.db.prices[11083] = { p = 20000, units = 1, t = env.clock, cap = 450 }
        assert.are.equal(450, ns.PriceOf(11083))
        fresh()
    end)
end)

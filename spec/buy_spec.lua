local wow = require("spec.wow")
local helper = require("spec.helper")

describe("Bought materials in the books (Ledger, pure)", function()
    local Ledger
    local VD = 11137

    setup(function() Ledger = helper.load().Ledger end)

    it("puts a material bought into stock at its cost, outside the pools, and the books' check counts it", function()
        local L = Ledger.Init({})
        Ledger.BuyMaterial(L, VD, 8, 7600, 1000)
        assert.are.equal(8, L.stock[VD].qty)
        assert.are.equal(7600, L.stock[VD].cost)
        assert.are.equal(950, Ledger.AvgCost(L, VD))
        assert.is_nil(next(L.pools))
        assert.are.equal(1, #L.matBuys)
        local b = Ledger.Books(L)
        assert.are.equal(7600, b.bought)
        assert.are.equal(0, b.off)
        -- Sold: the sale takes its cost, the books still hold.
        local rec = Ledger.Sell(L, VD, 3, 3600, 180, 2000)
        assert.are.equal(2850, rec.cost)
        assert.are.equal(0, Ledger.Books(L).off)
    end)

    it("keeps the cost of records older than 30 days, so the books still hold", function()
        local L = Ledger.Init({})
        Ledger.BuyMaterial(L, VD, 2, 1800, 1000)
        Ledger.BuyMaterial(L, VD, 1, 1000, 1000 + 31 * 86400)
        assert.are.equal(1, #L.matBuys)
        assert.are.equal(1800, L.matBuysOld)
        assert.are.equal(2800, Ledger.MaterialsBought(L))
        assert.are.equal(0, Ledger.Books(L).off)
    end)

    it("keeps the books through Clear history and a recost", function()
        local L = Ledger.Init({})
        Ledger.BuyMaterial(L, VD, 4, 4000, 1000)
        Ledger.Sell(L, VD, 1, 1500, 75, 2000)
        Ledger.ClearHistory(L)
        assert.are.equal(0, Ledger.Books(L).off)
        Ledger.Recost(L)
        assert.are.equal(3000, L.stock[VD].cost)
        assert.are.equal(0, Ledger.Books(L).off)
    end)
end)

describe("Buying from a price list (Buy)", function()
    local env, ns
    local VD, SALV, BLUEPRINT, ROD = 11137, 279985, 273103, 11130

    local function chatHas(text)
        for _, m in ipairs(env.chat) do if m:find(text, 1, true) then return true end end
        return false
    end
    local function logHas(text)
        for _, m in ipairs(ns.db.log) do if m:find(text, 1, true) then return true end end
        return false
    end
    local function last() return env.ah.commodityBuys[#env.ah.commodityBuys] end
    local function answerSearches(times)
        for _ = 1, times do
            wow.tick(ns, 0.2)
            local c = ns.Queue.current
            if c and c.commodity then wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", c.commodity) end
            if c and c.itemKey then wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", c.itemKey) end
        end
    end

    setup(function()
        env = wow.install()
        env.items[VD] = { name = "Vision Dust", quality = 1, ilvl = 40, classID = 7, commodity = true }
        env.items[SALV] = { name = "Arcane Salvager", quality = 1, ilvl = 28, classID = 15 }
        env.items[BLUEPRINT] = { name = "Blueprint: Arcane Salvager", quality = 2, ilvl = 25, classID = 9,
            commodity = false }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        env.ah.commodities[VD] = { { unitPrice = 900, quantity = 5, numOwnerItems = 0 },
            { unitPrice = 1000, quantity = 10, numOwnerItems = 0 } }
    end)

    before_each(function() env.chat = {} end)

    it("plans the cheapest units of a commodity from the last search", function()
        local plan = ns.Buy.Plan(VD, 8)
        assert.is_true(plan.commodity)
        assert.are.equal(8, plan.qty)
        assert.are.equal(5 * 900 + 3 * 1000, plan.total)
        assert.are.equal(1000, plan.top)
        assert.are.equal(938, plan.each)
        assert.is_true(ns.Buy.Plan(VD, 40).short)
        local ok, why = ns.Buy.Can(VD, 40)
        assert.is_false(ok)
        assert.matches("Only 15", why)
    end)

    it("buys a commodity: started in the click, confirmed on a quote in time and under the ceiling, into stock", function()
        local gold = env.money
        assert.is_true(ns.Buy.Click(VD, 8))
        assert.are.same({ kind = "start", itemID = VD, quantity = 8 }, last())
        assert.is_true(ns.Scanner.Buying())   -- everything else waits for it
        assert.are.equal("purchase", ns.Scanner.HoldReason())
        assert.is_false((ns.Buy.Can(VD, 1)))
        -- A search asked for now waits.
        local sent = #env.ah.sent
        ns.Queue.Add({ commodity = 11174 })
        wow.tick(ns, 0.5)
        assert.are.equal(sent, #env.ah.sent)
        wow.fire(ns, "COMMODITY_PRICE_UPDATED", 950, 7600)
        assert.are.same({ kind = "confirm", itemID = VD, quantity = 8 }, last())
        assert.are.equal("confirm", ns.Buy.Pending().state)
        env.money = gold - 7600
        wow.fire(ns, "COMMODITY_PURCHASE_SUCCEEDED")
        assert.is_false(ns.Buy.Busy())
        assert.are.equal(8, ns.db.ledger.stock[VD].qty)
        assert.are.equal(7600, ns.db.ledger.stock[VD].cost)
        assert.are.equal(7600, ns.Ledger.Books(ns.db.ledger).bought)
        assert.are.equal(0, ns.Ledger.Books(ns.db.ledger).off)
        assert.is_true(chatHas("bought 8x Vision Dust"))
        assert.is_true(logHas("into stock as bought materials"))
        ns.Queue.Clear()
    end)

    it("cancels when the quote is over the expected total + the tolerance", function()
        assert.are.equal(7875, ns.Buy.Ceiling(7500))
        assert.is_true(ns.Buy.Click(VD, 8))
        wow.fire(ns, "COMMODITY_PRICE_UPDATED", 1000, 7876)
        assert.are.equal("cancel", last().kind)
        assert.is_false(ns.Buy.Busy())
        assert.is_true(chatHas("cancelled"))
        assert.are.equal(8, ns.db.ledger.stock[VD].qty)   -- nothing booked
    end)

    it("cancels when the quote does not come within 2 s, and ignores it when it comes later", function()
        assert.is_true(ns.Buy.Click(VD, 2))
        wow.tick(ns, 2.3)
        assert.are.equal("cancel", last().kind)
        assert.is_false(ns.Buy.Busy())
        local n = #env.ah.commodityBuys
        wow.fire(ns, "COMMODITY_PRICE_UPDATED", 900, 1800)
        assert.are.equal(n, #env.ah.commodityBuys)   -- no confirm
        -- A quote that comes 2.5 s after the click is cancelled too.
        assert.is_true(ns.Buy.Click(VD, 2))
        env.now = env.now + 2.5
        wow.fire(ns, "COMMODITY_PRICE_UPDATED", 900, 1800)
        assert.are.equal("cancel", last().kind)
        assert.is_false(ns.Buy.Busy())
    end)

    it("ends a purchase that fails, or that has no price", function()
        assert.is_true(ns.Buy.Click(VD, 2))
        wow.fire(ns, "COMMODITY_PRICE_UNAVAILABLE")
        assert.is_false(ns.Buy.Busy())
        assert.is_true(ns.Buy.Click(VD, 2))
        wow.fire(ns, "COMMODITY_PRICE_UPDATED", 900, 1800)
        wow.fire(ns, "COMMODITY_PURCHASE_FAILED")
        assert.is_false(ns.Buy.Busy())
        assert.are.equal(8, ns.db.ledger.stock[VD].qty)
    end)

    it("never buys while a gear purchase is on its way, nor while the auction house is busy", function()
        local done = wow.buying(ns)
        local ok, why = ns.Buy.Can(VD, 1)
        assert.is_false(ok)
        assert.matches("on its way", why)
        local n = #env.ah.commodityBuys
        assert.is_false((ns.Buy.Click(VD, 1)))
        assert.are.equal(n, #env.ah.commodityBuys)
        done()
        wow.tick(ns, 1.2)
        env.ah.ready = false
        ok, why = ns.Buy.Can(VD, 1)
        assert.is_false(ok)
        assert.matches("answering a request", why)
        env.ah.ready = true
        assert.is_true((ns.Buy.Can(VD, 1)))
    end)

    it("buys the cheapest auction of a non-commodity from a current search, with one click once searched", function()
        env.ah.itemResults[BLUEPRINT] = {
            { auctionID = 56, buyoutAmount = 70000, quantity = 1 },
            { auctionID = 55, buyoutAmount = 60000, quantity = 1 },
            { auctionID = 57, buyoutAmount = 1000, quantity = 1, containsOwnerItem = true },
        }
        assert.is_false(ns.Prices.IsCommodity(BLUEPRINT))
        local plan = ns.Buy.Plan(BLUEPRINT, 1)
        assert.are.equal(55, plan.auctionID)
        assert.are.equal(60000, plan.total)
        -- Never searched in this session: the click searches first (past every hold), then Buy is on.
        local bids = #env.ah.bids
        local sent, why = ns.Buy.Click(BLUEPRINT, 1)
        assert.is_false(sent)
        assert.are.equal("searching", why)
        assert.are.equal(bids, #env.ah.bids)
        assert.is_false((ns.Buy.Can(BLUEPRINT, 1)))
        answerSearches(3)
        assert.is_true(ns.Buy.Current(BLUEPRINT))
        assert.is_true((ns.Buy.Can(BLUEPRINT, 1)))
        assert.is_true(ns.Buy.Click(BLUEPRINT, 1))
        assert.are.same({ id = 55, amount = 60000 }, env.ah.bids[#env.ah.bids])
        assert.is_true(ns.Scanner.Buying())
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 55)
        assert.is_false(ns.Buy.Busy())
        assert.is_nil(ns.db.ledger.stock[BLUEPRINT])   -- not a material: not in stock
        assert.is_true(chatHas("bought 1x Blueprint: Arcane Salvager"))
        assert.is_false(ns.Buy.Current(BLUEPRINT))      -- the next click searches again
    end)

    it("searches a non-commodity again after a browse made its search stale", function()
        ns.Buy.Prefetch(BLUEPRINT)
        answerSearches(3)
        assert.is_true(ns.Buy.Current(BLUEPRINT))
        C_AuctionHouse.SendBrowseQuery({})
        assert.is_false(ns.Buy.Current(BLUEPRINT))
        wow.tick(ns, 1.2)
        ns.Queue.Clear()
    end)

    it("says a non-commodity purchase with no answer in 3 s, and frees Buy", function()
        ns.Buy.Prefetch(BLUEPRINT)
        answerSearches(3)
        assert.is_true(ns.Buy.Click(BLUEPRINT, 1))
        wow.tick(ns, 3.2)
        assert.is_false(ns.Buy.Busy())
        assert.is_true(chatHas("no answer yet for Blueprint: Arcane Salvager"))
    end)

    it("never offers the Runed Golden Rod (it binds when picked up)", function()
        local ok, why = ns.Buy.Can(ROD, 1)
        assert.is_false(ok)
        assert.matches("binds when picked up", why)
    end)

    it("scans the Blueprint and the Arcane Salvager with the materials, each its own way", function()
        env.ah.commodities[SALV] = { { unitPrice = 9400, quantity = 30, numOwnerItems = 0 } }
        env.ah.itemResults[BLUEPRINT] = { { auctionID = 60, buyoutAmount = 65000, quantity = 1 } }
        ns.Prices.Scan()
        assert.are.equal(#ns.Data.MATERIALS + 2, ns.Prices.total)
        answerSearches(80)
        assert.is_false(ns.Prices.scanning)
        assert.are.equal(9400, ns.db.prices[SALV].p)
        assert.are.equal(65000, ns.db.prices[BLUEPRINT].p)
        assert.is_nil(ns.db.prices[ROD])
        assert.are.equal(65000, ns.db.history[BLUEPRINT][#ns.db.history[BLUEPRINT]].p)
        -- The tab's own Scan: its items only.
        ns.Prices.ScanSalvager()
        assert.are.equal(4, ns.Prices.total)
        answerSearches(30)
        assert.is_false(ns.Prices.scanning)
    end)

    it("gives the tab's statement from the prices and the stock", function()
        ns.db.prices[11174] = { p = 3000, units = 20, t = env.clock }
        local s = ns.Prices.Salvager()
        assert.is_false(s.known)
        assert.are.equal("mixed", s.cost.source)   -- Vision Dust from the stock bought, the essence at its price
        assert.are.equal(2 * 950 + 3000, s.cost.total)
        assert.are.equal(9400, s.buy)
        assert.are.equal(65000, s.blueprint)
        assert.is_number(s.payback)
        local was = _G.IsPlayerSpell
        _G.IsPlayerSpell = function(id) return id == 1263056 end
        assert.is_true(ns.Prices.Salvager().known)
        _G.IsPlayerSpell = was
        local r = ns.Prices.BestTime(VD, "high")
        assert.are.equal("few", r.status)
    end)
end)

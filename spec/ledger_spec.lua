local helper = require("spec.helper")

describe("Ledger", function()
    local ns, Ledger, state
    before_each(function()
        ns = helper.load()
        Ledger = ns.Ledger
        state = Ledger.Init({})
    end)

    it("splits an item's cost by material value", function()
        -- Pay 30s, get dust worth 10s and an essence worth 30s.
        local prices = { [1] = 1000, [2] = 3000 }
        local out = Ledger.Allocate(3000, { [1] = 1, [2] = 1 }, function(id) return prices[id] end)
        assert.are.equal(750, out[1])
        assert.are.equal(2250, out[2])
    end)

    it("splits by quantity when nothing has a price", function()
        local out = Ledger.Allocate(900, { [1] = 2, [2] = 1 }, function() return nil end)
        assert.are.equal(600, out[1])
        assert.are.equal(300, out[2])
    end)

    it("never loses a copper when splitting", function()
        local out = Ledger.Allocate(1001, { [1] = 1, [2] = 1, [3] = 1 }, function() return 100 end)
        assert.are.equal(1001, out[1] + out[2] + out[3])
    end)

    it("keeps an average cost and a break-even price", function()
        Ledger.AddStock(state, 5, 2, 1000)
        Ledger.AddStock(state, 5, 2, 2000)
        assert.are.equal(750, Ledger.AvgCost(state, 5))
        assert.are.equal(790, Ledger.BreakEven(state, 5, 0.05))  -- ceil(750 / 0.95)
    end)

    it("books a sale at average cost", function()
        Ledger.AddStock(state, 5, 4, 3000)
        local rec = Ledger.Sell(state, 5, 2, 2000, 100, 0)
        assert.are.equal(1500, rec.cost)
        assert.are.equal(1900, rec.net)
        assert.are.equal(400, rec.profit)
        assert.are.equal(2, state.stock[5].qty)
        assert.are.equal(1500, state.stock[5].cost)
    end)

    it("keeps units with no known cost out of the average", function()
        Ledger.AddStock(state, 5, 3, nil)
        assert.is_nil(Ledger.AvgCost(state, 5))
        Ledger.AddStock(state, 5, 2, 1000)
        assert.are.equal(500, Ledger.AvgCost(state, 5))
        assert.are.equal(5, state.stock[5].qty)
        local rec = Ledger.Sell(state, 5, 3, 3000, 150, 0)
        assert.are.equal(1, rec.untracked)
        assert.are.equal(1000, rec.cost)
        assert.are.equal(2, state.stock[5].qty)
        assert.are.equal(2, state.stock[5].unknown)
    end)

    it("does not count a purchase twice (auction house, then mail)", function()
        Ledger.AuctionPurchase(state, 77, 1200, 1500, 1)
        assert.is_false(Ledger.MailPurchase(state, 77, 1, 1200, 1500, 2))
        assert.is_true(Ledger.MailPurchase(state, 77, 1, 1200, 1500, 3))
        assert.are.equal(2, #state.purchases[77])
    end)

    it("marks old zero-cost stock as unknown", function()
        local old = Ledger.Init({ stock = { [5] = { qty = 4, cost = 0 } } })
        assert.are.equal(4, old.stock[5].unknown)
        assert.is_nil(Ledger.AvgCost(old, 5))
    end)

    it("counts units sold beyond the tracked stock at zero cost", function()
        Ledger.AddStock(state, 5, 1, 500)
        local rec = Ledger.Sell(state, 5, 3, 3000, 150, 0)
        assert.are.equal(2, rec.untracked)
        assert.are.equal(500, rec.cost)
        assert.is_nil(state.stock[5])
    end)

    it("takes purchases oldest first", function()
        Ledger.AddPurchase(state, 77, 1, 1000, 1500, 1)
        Ledger.AddPurchase(state, 77, 2, 3000, 1500, 2)
        assert.are.equal(1000, Ledger.TakePurchase(state, 77).each)
        assert.are.equal(1500, Ledger.TakePurchase(state, 77).each)
        assert.are.equal(1500, Ledger.TakePurchase(state, 77).each)
        assert.is_nil(Ledger.TakePurchase(state, 77))
    end)

    it("moves a purchase's cost into stock on disenchant", function()
        Ledger.AddPurchase(state, 77, 1, 3000, 3500, 1)
        local prices = { [1] = 1000, [2] = 3000 }
        local priceOf = function(id) return prices[id] end
        local rec = Ledger.Disenchant(state, { t = 2, itemID = 77, got = { [1] = 1, [2] = 1 } },
            Ledger.TakePurchase(state, 77), priceOf, 0.05)
        assert.is_true(rec.costKnown)
        assert.are.equal(3000, rec.cost)
        assert.are.equal(3500, rec.evAtBuy)
        assert.are.equal(math.floor(4000 * 0.95), rec.value)
        assert.are.equal(750, state.stock[1].cost)
        assert.are.equal(2250, state.stock[2].cost)
    end)

    it("lists purchases newest first, each with what it gave", function()
        local prices = { [1] = 1000, [2] = 3000 }
        local priceOf = function(id) return prices[id] end
        Ledger.AddPurchase(state, 77, 1, 3000, 3500, 10, "link77")
        Ledger.AddPurchase(state, 88, 1, 500, 900, 20, "link88")
        Ledger.Disenchant(state, { t = 30, itemID = 77, link = "link77", got = { [1] = 1, [2] = 1 } },
            Ledger.TakePurchase(state, 77), priceOf, 0.05)
        Ledger.Disenchant(state, { t = 5, itemID = 99, got = { [1] = 2 } }, nil, priceOf, 0.05)
        local h = Ledger.History(state)
        assert.are.equal(3, #h)
        -- newest first: the disenchant of 77, the waiting purchase of 88, the disenchant with no purchase
        assert.are.equal(77, h[1].itemID)
        assert.is_true(h[1].done)
        assert.are.equal(3000, h[1].paid)
        assert.are.equal(10, h[1].boughtAt)
        assert.are.equal(3800, h[1].got)
        assert.are.equal(800, h[1].result)
        assert.are.equal(2, h[1].mats[1].id)              -- the more valuable material first
        assert.are.equal(2250, h[1].mats[1].share)
        assert.are.equal(2850, h[1].mats[1].value)
        assert.are.equal(88, h[2].itemID)
        assert.is_false(h[2].done)
        assert.are.equal(500, h[2].paid)
        assert.are.equal(99, h[3].itemID)
        assert.is_nil(h[3].paid)
        assert.is_nil(h[3].result)
    end)

    it("books a sale when it is seen sold, and does not book it again when its mail is taken", function()
        Ledger.AddStock(state, 5, 36, 36 * 300)
        -- A listing of 36 sells in four parts; they share the listing's auction ID.
        local rows = {
            { auctionID = 9, qty = 10, due = 4000 }, { auctionID = 9, qty = 3, due = 4026 },
            { auctionID = 9, qty = 15, due = 4033 }, { auctionID = 9, qty = 8, due = 4035 },
        }
        local fresh = Ledger.NewSold(state, rows, 1000)
        assert.are.equal(4, #fresh)
        for _, r in ipairs(fresh) do Ledger.SaleSeen(state, 5, r.qty, 470, 0.05, 1000) end
        assert.are.equal(4, #state.sales)
        assert.is_nil(state.stock[5])                               -- all 36 left the stock
        assert.are.equal(0, #Ledger.NewSold(state, rows, 1100))     -- read again: nothing new
        -- Two more parts of the same size, seconds apart: both are new, and stay apart.
        local more = { { auctionID = 9, qty = 8, due = 4035 }, { auctionID = 9, qty = 8, due = 5000 },
            { auctionID = 9, qty = 8, due = 5003 } }
        assert.are.equal(2, #Ledger.NewSold(state, more, 1200))
        assert.are.equal(0, #Ledger.NewSold(state, more, 1300))
        -- One mail pays all 36: nothing new is booked, and the four sales are marked paid.
        local rec, matched = Ledger.SalePaid(state, 5, 36, 36 * 470, 846, 5000)
        assert.is_nil(rec)
        assert.are.equal(36, matched)
        assert.are.equal(4, #state.sales)
        for _, s in ipairs(state.sales) do assert.are.equal(0, s.unpaid) end
        -- A mail for a sale that was never seen is booked from the mail, as before.
        Ledger.AddStock(state, 5, 4, 1200)
        local late = Ledger.SalePaid(state, 5, 4, 4 * 500, 100, 6000)
        assert.are.equal(4, late.count)
        assert.are.equal(1900 - 1200, late.profit)
        -- A mail that covers a seen part and an unseen one: only the unseen units are booked.
        Ledger.AddStock(state, 5, 10, 3000)
        Ledger.SaleSeen(state, 5, 6, 480, 0.05, 7000)
        local rest, already = Ledger.SalePaid(state, 5, 10, 10 * 480, 240, 8000)
        assert.are.equal(6, already)
        assert.are.equal(4, rest.count)
        assert.are.equal(4 * 480, rest.gross)
    end)

    it("breaks a material down by the items and bands it came from", function()
        local prices = { [1] = 400, [2] = 1600 }
        local priceOf = function(id) return prices[id] end
        local function de(itemID, band, paid, got)
            Ledger.AddPurchase(state, itemID, 1, paid, nil, 1)
            Ledger.Disenchant(state, { t = 2, itemID = itemID, quality = 2, classID = 4, band = band, got = got },
                Ledger.TakePurchase(state, itemID), priceOf, 0.05)
        end
        de(77, 30, 1000, { [1] = 2 })          -- hood: 2 dust for 10s
        de(77, 30, 1000, { [1] = 1 })          -- hood: 1 dust for 10s
        de(77, 30, 1000, { [2] = 1 })          -- hood: an essence
        de(88, 35, 300, { [1] = 3 })           -- another item, another band: 3 dust for 3s
        Ledger.Disenchant(state, { t = 3, itemID = 99, quality = 2, classID = 4, band = 30, got = { [1] = 5 } },
            nil, priceOf, 0.05)                -- no recorded purchase
        local b = Ledger.Breakdown(state, 1)
        assert.are.equal(11, b.units)
        assert.are.equal(6, b.knownUnits)
        assert.are.equal(2300, b.cost)
        assert.are.equal(3, #b.items)
        local hood
        for _, s in ipairs(b.items) do if s.itemID == 77 then hood = s end end
        assert.are.equal(2, hood.gave)          -- two of its three disenchants gave dust
        assert.are.equal(3, hood.all)
        assert.are.equal(3, hood.units)
        assert.are.equal(2000, hood.cost)       -- the dust took the whole price of those two hoods
        assert.are.equal(3000, hood.paid)       -- the item as a whole: three hoods
        assert.are.equal(math.floor(800 * 0.95) + math.floor(400 * 0.95) + math.floor(1600 * 0.95), hood.got)
        assert.are.equal(2, #b.bands)
        local band30
        for _, s in ipairs(b.bands) do if s.band == 30 then band30 = s end end
        assert.are.equal(8, band30.units)       -- the hoods' 3 and the 5 with no purchase
        assert.are.equal(3, band30.knownUnits)
        assert.are.equal(4, band30.all)
        assert.are.equal(0, #Ledger.Breakdown(state, 12345).items)
    end)

    it("summarises disenchants by band", function()
        local priceOf = function() return 100 end
        Ledger.Disenchant(state, { t = 1, quality = 2, classID = 4, band = 30, planned = 90, got = { [11083] = 2 } }, nil, priceOf)
        Ledger.Disenchant(state, { t = 2, quality = 2, classID = 4, band = 30, planned = 90, salvager = true,
            got = { [11082] = 1 } }, nil, priceOf)
        local r = Ledger.Report(state)["2:a:30"]
        assert.are.equal(2, r.n)
        assert.are.equal(1, r.salvager)
        assert.are.equal(1, r.mats[11083].hits)
        assert.are.equal(2, r.mats[11083].qty)
    end)
end)

local helper = require("spec.helper")

describe("Ledger", function()
    local ns, Ledger, state
    before_each(function()
        ns = helper.load()
        Ledger = ns.Ledger
        state = Ledger.Init({})
    end)

    it("sums the profit by quality and gear type, by band, by item and by material, for a time", function()
        local prices = { [11083] = 400, [11084] = 5000 }
        local function priceOf(id) return prices[id] end
        local function de(t, itemID, cost, got, quality, band, salvager)
            Ledger.Disenchant(state, { t = t, itemID = itemID, link = "[" .. itemID .. "]", quality = quality,
                classID = 4, band = band, got = got, salvager = salvager }, cost and { each = cost } or nil, priceOf, 0.05)
        end
        de(100, 7048, 1000, { [11083] = 3 }, 2, 30, true)
        de(200, 7048, 1000, { [11084] = 1 }, 2, 30, false)
        de(300, 9433, 18000, { [11178] = 1 }, 3, 50, false)
        de(400, 3835, nil, { [11083] = 1 }, 2, 35, false)               -- no price known: only in the materials
        de(10, 7048, 1000, { [11083] = 1 }, 2, 30, false)                -- before the time asked for
        Ledger.Sell(state, 11083, 2, 1000, 50, 500)                      -- 2 dust sold: 475 each after the cut
        local p = Ledger.Profits(state, 50)
        assert.are.equal(3, p.total.n)
        assert.are.equal(20000, p.total.paid)
        local green = p.groups[1]
        assert.are.same({ 2, 4, 2, 1 }, { green.quality, green.classID, green.n, green.salvager })
        assert.are.equal(30, green.bands[1].band)
        -- The dust at what one sold for (475), the shard at its disenchant value (no shard sold yet).
        assert.are.equal(3 * 475 + math.floor(5000 * 0.95 + 0.5), math.floor(green.sold + 0.5))
        assert.are.equal(3, p.groups[2].quality)
        assert.are.equal(2, p.items[1].n)                                -- the hoods paid best
        local dust
        for _, m in ipairs(p.mats) do if m.id == 11083 then dust = m end end
        assert.are.same({ 4, 2, 950 }, { dust.got, dust.sold, dust.net })
        assert.are.equal(4, Ledger.Profits(state).total.n)               -- all of it
        local rare = Ledger.Profits(state, nil, function(r) return r.quality == 3 end)
        assert.are.same({ 1, 18000 }, { rare.total.n, rare.total.paid })
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

    it("lists the auction house purchases whose mail is not taken, oldest first", function()
        Ledger.AuctionPurchase(state, 78, 900, 1000, 20, "L78", { ilvl = 31 })
        Ledger.AuctionPurchase(state, 77, 1200, 1500, 10, "L77")
        Ledger.AuctionPurchase(state, 77, 1300, 1500, 30)
        local list = Ledger.NotPickedUp(state)
        assert.are.same({ 77, 78, 77 }, { list[1].itemID, list[2].itemID, list[3].itemID })
        assert.are.equal("L77", list[1].link)
        assert.are.equal(31, list[2].j.ilvl)
        assert.are.equal(1000, list[2].ev)
        assert.is_false(Ledger.MailPurchase(state, 77, 1, 1200, 1500, 40))   -- its mail is taken
        list = Ledger.NotPickedUp(state)
        assert.are.equal(2, #list)
        assert.are.same({ 900, 1300 }, { list[1].each, list[2].each })
    end)

    it("marks old zero-cost stock as unknown", function()
        local old = Ledger.Init({ stock = { [5] = { qty = 4, cost = 0 } } })
        assert.are.equal(4, old.stock[5].unknown)
        assert.is_nil(Ledger.AvgCost(old, 5))
    end)

    it("counts the profit of the units with a known cost only", function()
        Ledger.AddStock(state, 5, 1, 500)
        local rec = Ledger.Sell(state, 5, 3, 3000, 150, 0)
        assert.are.equal(2, rec.untracked)
        assert.are.equal(500, rec.cost)
        assert.are.equal(950 - 500, rec.profit)          -- one known unit: a third of the net, minus its cost
        assert.are.equal(1900, rec.netUntracked)
        assert.is_nil(state.stock[5])
        -- Sales of older versions are split on load.
        local old = Ledger.Init({ sales = { { id = 5, count = 2, untracked = 1, net = 2000, cost = 300, profit = 1700 } } })
        assert.are.equal(700, old.sales[1].profit)
        assert.are.equal(1000, old.sales[1].netUntracked)
    end)

    it("starts a new ledger with nothing to repair, and keeps what is seen sold on a reset", function()
        assert.are.equal(Ledger.DOUBLES_REPAIR, state.doubleSalesFixed)
        state.seenSold[1] = { auctionID = 9, qty = 1, due = 4000 }
        state.sales[1] = { id = 5, count = 1, unpaid = 1, each = 100, net = 95, cost = 0 }
        local fresh = Ledger.Reset(state)
        assert.are.equal(0, #fresh.sales)
        assert.are.equal(1, #fresh.seenSold)
        assert.are.equal(Ledger.DOUBLES_REPAIR, fresh.doubleSalesFixed)
        assert.are.equal(0, Ledger.DropDoubleSales(fresh))
        assert.are.equal(0, #Ledger.NewSold(fresh, { { auctionID = 9, qty = 1, due = 4010 } }, 3000))
        assert.is_nil(Ledger.Init({ sales = {} }).doubleSalesFixed)   -- an old ledger is still repaired once
    end)

    it("writes the real cut back when the mail pays a sale booked when seen", function()
        Ledger.AddStock(state, 5, 10, 3000)
        local rec = Ledger.SaleSeen(state, 5, 10, 500, 0.05, 1000)
        assert.are.equal(250, rec.cut)                        -- estimated: 5%
        Ledger.SalePaid(state, 5, 4, 2000, 80, 2000)          -- two mails, the real cut is 4%
        assert.are.equal(250, rec.cut)                        -- not all paid yet: still the estimate
        Ledger.SalePaid(state, 5, 6, 3000, 120, 2100)
        assert.are.equal(200, rec.cut)
        assert.are.equal(4800, rec.net)
        assert.are.equal(4800 - 3000, rec.profit)
        assert.are.equal(2100, rec.paidAt)
    end)

    it("keeps unknown cost unknown in proportion when essences change form", function()
        Ledger.AddStock(state, 5, 3, 900)
        Ledger.AddStock(state, 5, 3, nil)                     -- 6 lesser, 3 with a known cost
        local cost, unknown = Ledger.Convert(state, 5, 6, 6, 2)
        assert.are.equal(900, cost)
        assert.are.equal(3, unknown)
        assert.are.equal(2, state.stock[6].qty)
        assert.are.equal(1, state.stock[6].unknown)           -- one greater known, one not
        assert.are.equal(900, Ledger.AvgCost(state, 6))
    end)

    it("drops records that waited more than 30 days", function()
        local now = 100 * 86400
        local old, recent = now - 31 * 86400, now - 86400
        state.bought = { { itemID = 1, each = 5, t = old }, { itemID = 1, each = 5, t = old, mail = true },
            { itemID = 2, each = 5, t = recent } }
        state.purchases = { [1] = { { each = 5, t = old }, { each = 5, t = recent } }, [3] = { { each = 1, t = old } } }
        state.sales = { { id = 5, count = 1, unpaid = 1, t = old }, { id = 5, count = 1, unpaid = 1, t = recent } }
        local b, p, s, m = Ledger.Expire(state, now)
        assert.are.same({ 1, 2, 1, 1 }, { b, p, s, m })   -- (the record whose mail came goes too)
        assert.are.equal(1, #state.bought)
        assert.are.equal(1, #state.purchases[1])
        assert.is_nil(state.purchases[3])
        assert.are.equal(0, state.sales[1].unpaid)
        assert.are.equal(1, state.sales[2].unpaid)
    end)

    it("books a lost deposit as a loss that the totals count and Accuracy leaves out", function()
        local rec = Ledger.DepositLost(state, 5, 20, 60, "expired", 1000)
        assert.are.equal(-60, rec.profit)
        assert.are.equal(0, rec.count)
        assert.are.equal(0, #Ledger.Accuracy(state).mats)
    end)

    it("makes and reads one band key", function()
        local key = Ledger.BandKey(3, 2, 45)
        assert.are.equal("3:w:45", key)
        assert.are.same({ 3, 2, 45 }, { Ledger.BandOf(key) })
        assert.are.same({ 2, 4, 30 }, { Ledger.BandOf(Ledger.BandKey(2, 4, 30)) })
        assert.is_nil(Ledger.BandOf("2:4:30"))
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

    it("knows a sold part again when its due time moves by minutes, and repairs the doubles of 0.3.79-0.3.84", function()
        local rows = { { auctionID = 7, qty = 2, due = 5000 }, { auctionID = 8, qty = 2, due = 5010 } }
        assert.are.equal(2, #Ledger.NewSold(state, rows, 1400))
        rows[1].due, rows[2].due = 5150, 5160                       -- the read after a post: 150 s later
        assert.are.equal(0, #Ledger.NewSold(state, rows, 1600))
        -- What those versions left: each part known twice, and its sale booked twice (two materials, one size).
        state.seenSold = { { auctionID = 7, qty = 2, due = 5000 }, { auctionID = 8, qty = 2, due = 5010 },
            { auctionID = 7, qty = 2, due = 5150 }, { auctionID = 8, qty = 2, due = 5160 } }
        Ledger.AddStock(state, 5, 3, 300)
        for _, x in ipairs({ { 5, 1400, 5000 }, { 6, 1400, 5010 }, { 5, 1600, 5150 }, { 6, 1600, 5160 } }) do
            Ledger.SaleSeen(state, x[1], 2, 100, 0.05, x[2]).due = x[3]
        end
        assert.is_nil(state.stock[5])                               -- the double took the unit that is still there
        state.doubleSalesFixed = true                               -- (the repair of 0.3.40 has run)
        assert.are.equal(2, Ledger.DropDoubleSales(state))
        assert.are.equal(2, #state.sales)
        assert.are.same({ 5, 6 }, { state.sales[1].id, state.sales[2].id })
        assert.are.equal(1, state.stock[5].qty)                     -- given back
        assert.are.equal(2, #state.seenSold)
        assert.are.equal(0, Ledger.DropDoubleSales(state))
    end)

    it("does not book a sold part again when its due time moves, and repairs the old double sales", function()
        Ledger.AddStock(state, 5, 1, 18000)
        local fresh = Ledger.NewSold(state, { { auctionID = 9, qty = 1, due = 4000 } }, 1000)
        Ledger.SaleSeen(state, 5, fresh[1].qty, 19699, 0.05, 1000)
        assert.are.equal(0, #Ledger.NewSold(state, { { auctionID = 9, qty = 1, due = 4036 } }, 1600))
        assert.are.equal(0, #Ledger.NewSold(state, { { auctionID = 9, qty = 1, due = 4100 } }, 4000))  -- still on screen
        -- The same size again, minutes later: another part of the listing.
        assert.are.equal(1, #Ledger.NewSold(state, { { auctionID = 9, qty = 1, due = 4100 },
            { auctionID = 9, qty = 1, due = 4400 } }, 4050))
        table.remove(state.seenSold)
        assert.are.equal(0, #Ledger.NewSold(state, {}, 4600))                  -- gone, but its money was due a moment ago
        assert.are.equal(1, #state.seenSold)
        assert.are.equal(0, #Ledger.NewSold(state, {}, 6000))                  -- long gone: forgotten
        assert.are.equal(0, #state.seenSold)
        -- What 0.3.39 and before left behind: the same part seen twice, and booked twice.
        state.seenSold = { { auctionID = 9, qty = 1, due = 4000 }, { auctionID = 9, qty = 1, due = 4036 } }
        state.doubleSalesFixed = nil                                           -- (a ledger of those versions)
        Ledger.SaleSeen(state, 5, 1, 19699, 0.05, 1600)
        assert.are.equal(2, #state.sales)
        assert.are.equal(1, Ledger.DropDoubleSales(state))
        assert.are.equal(1, #state.sales)
        assert.are.equal(18000, state.sales[1].cost)
        assert.are.equal(1, #state.seenSold)
        assert.are.equal(0, Ledger.DropDoubleSales(state))                     -- once
    end)

    it("keeps a price history: one point per time slot, capped, with the change over a range", function()
        local History = ns.History
        local h = {}
        History.Add(h, 5, 1000, 400, 390, 50)
        History.Add(h, 5, 1040, 410, 400, 60)                       -- the same slot: the later scan stays
        assert.are.equal(1, #h[5])
        assert.are.equal(410, h[5][1].p)
        History.Add(h, 5, 2000, 500, 480, 70)
        History.Add(h, 5, 3000, nil, nil, 0)                        -- none listed
        History.Add(h, 5, 4000, 451, 440, 80)
        assert.are.equal(4, #h[5])
        assert.are.equal(3, #History.Points(h, 5, 1500))
        local change, first, last = History.Change(History.Points(h, 5))
        assert.are.equal(410, first)
        assert.are.equal(451, last)
        assert.are.equal(0.1, change)
        assert.is_nil(History.Change({}))
        -- Older observations are merged in, in time order.
        History.Merge(h, { { id = 5, t = 200, p = 380 }, { id = 5, t = 2600, p = 470 }, { id = 7, t = 50, p = 9 } })
        assert.are.equal(380, h[5][1].p)
        assert.are.equal(6, #h[5])
        assert.are.equal(1, #h[7])
        for i = 1, History.MAX_POINTS + 20 do History.Add(h, 6, i * 1000, i, i, 1) end
        assert.is_true(#h[6] <= History.MAX_POINTS)
        assert.are.equal(1, h[6][1].p)                              -- the oldest stay, thinner: every second one
        assert.are.equal(3, h[6][2].p)
        assert.are.equal(History.MAX_POINTS + 20, h[6][#h[6]].p)
    end)

    it("compares what was promised with what the disenchants gave and what the sales brought", function()
        local prices = { [1] = 400, [2] = 1600 }
        local priceOf = function(id) return prices[id] end
        local function de(itemID, band, paid, ev, got)
            Ledger.AddPurchase(state, itemID, 1, paid, ev, 1)
            Ledger.Disenchant(state, { t = 2, itemID = itemID, quality = 2, classID = 4, band = band, got = got },
                Ledger.TakePurchase(state, itemID), priceOf, 0.05)
        end
        de(77, 30, 1000, 1200, { [1] = 2 })                         -- promised 12s, gave 2 dust: 7s 60c
        de(77, 30, 1000, 1200, { [2] = 1 })                         -- promised 12s, gave an essence: 15s 20c
        de(88, 35, 500, 600, { [1] = 1 })
        Ledger.Disenchant(state, { t = 3, itemID = 99, quality = 2, classID = 4, band = 30, got = { [1] = 5 } },
            nil, priceOf, 0.05)                                     -- no recorded purchase: not counted
        Ledger.Sell(state, 1, 2, 600, 30, 5)                        -- dust really sold for 2s 85c each after the cut
        local acc = Ledger.Accuracy(state)
        assert.are.equal(2, #acc.bands)
        local b = acc.bands[1]
        assert.are.equal(30, b.band)
        assert.are.equal(2, b.n)
        assert.are.equal(2000, b.paid)
        assert.are.equal(2400, b.promised)
        assert.are.equal(760 + 1520, b.got)
        assert.are.equal(2 * 285 + 1520, b.sold)                    -- dust at its real price, the essence as valued
        assert.are.equal(3, b.units)
        assert.are.equal(2, b.soldUnits)
        assert.are.equal(3, acc.total.n)
        assert.are.equal(2500, acc.total.paid)
        local dust
        for _, m in ipairs(acc.mats) do if m.id == 1 then dust = m end end
        assert.are.equal(3, dust.units)
        assert.are.equal(760 + 380, dust.valued)
        assert.are.equal(2, dust.soldUnits)
        assert.are.equal(570, dust.soldNet)
    end)

    it("keeps what later mails need when the history is cleared", function()
        Ledger.AuctionPurchase(state, 77, 1000, 1200, 1)            -- its "Auction won" mail has not come
        Ledger.AuctionPurchase(state, 78, 500, 600, 2)
        assert.is_false(Ledger.MailPurchase(state, 78, 1, 500, 600, 3))
        Ledger.AddStock(state, 5, 10, 3000)
        Ledger.SaleSeen(state, 5, 4, 480, 0.05, 4)                  -- money still due
        Ledger.Sell(state, 5, 2, 900, 45, 5)                        -- paid
        Ledger.ClearHistory(state)
        assert.are.equal(1, #state.sales)
        assert.are.equal(4, state.sales[1].unpaid)
        assert.are.equal(1, #state.bought)
        -- The mails that come later book nothing twice.
        assert.is_false(Ledger.MailPurchase(state, 77, 1, 1000, 1200, 6))
        assert.are.equal(1, #state.purchases[77])
        assert.is_nil((Ledger.SalePaid(state, 5, 4, 4 * 480, 96, 7)))
        assert.are.equal(1, #state.sales)
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
        -- Band 30 paid 3000 for dust worth 760 + 380 and an essence worth 1520: the dust's part is 3000 * 1140 / 2660;
        -- band 35's 300 is all on its dust.
        assert.are.equal(math.floor(3000 * 1140 / 2660 + 300 + 0.5), b.cost)
        assert.are.equal(3, #b.items)
        local hood
        for _, s in ipairs(b.items) do if s.itemID == 77 then hood = s end end
        assert.are.equal(2, hood.gave)          -- two of its three disenchants gave dust
        assert.are.equal(3, hood.all)
        assert.are.equal(3, hood.units)
        assert.are.equal(math.floor(3000 * 1140 / 2660 + 0.5), hood.cost)   -- its part of the band's cost (SDD 4)
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
    describe("the current batch (SDD 107)", function()
        local DUST, ESSENCE = 11083, 11082
        local function priceOf() return 100 end
        local function disenchant(t, itemID, got)
            return Ledger.Disenchant(state, { t = t, itemID = itemID, quality = 2, classID = 4, band = 30, got = got },
                Ledger.TakePurchase(state, itemID), priceOf, 0.05)
        end

        it("lists what is picked up, and apart what waits in the mail", function()
            Ledger.AuctionPurchase(state, 7001, 500, 900, 10, "[A]")       -- bought with Buy: its mail not taken
            Ledger.MailPurchase(state, 7002, 1, 400, 700, 20, "[B]")       -- known from its mail: picked up
            local b = Ledger.Batch(state, {})
            assert.are.same({ 7002 }, { b.waiting[1].itemID, b.waiting[2] and b.waiting[2].itemID })
            assert.are.same({ 400, 700 }, { b.waiting[1].each, b.waiting[1].ev })
            assert.are.same({ 1, 7001, 500, 900 }, { #b.mail, b.mail[1].itemID, b.mail[1].each, b.mail[1].ev })   -- apart
            assert.is_false(Ledger.MailPurchase(state, 7001, 1, 500, 900, 30))   -- its mail taken: waiting now
            b = Ledger.Batch(state, {})
            assert.are.equal(0, #b.mail)
            assert.are.same({ 7002, 7001 }, { b.waiting[1].itemID, b.waiting[2].itemID })   -- newest bought first
            -- What you hold caps it: a piece sold or thrown away is not in the batch any more.
            b = Ledger.Batch(state, {}, function(id) return id == 7002 and 0 or 1 end)
            assert.are.same({ 1, 7001 }, { #b.waiting, b.waiting[1].itemID })
        end)

        it("keeps a disenchant until all its materials are posted, first in, first out", function()
            Ledger.MailPurchase(state, 7001, 2, 1000, 900, 10, "[A]")
            local first = disenchant(100, 7001, { [DUST] = 3, [ESSENCE] = 1 })
            local b = Ledger.Batch(state, {})
            assert.are.equal(1, #b.waiting)                                 -- the second piece still waits
            assert.are.same({ first, 4, 3 }, { b.done[1].rec, b.done[1].units, b.done[1].left[DUST] })
            local second = disenchant(200, 7001, { [DUST] = 2 })
            assert.are.equal(0, #Ledger.Batch(state, {}).waiting)
            local posted = { { itemID = DUST, qty = 5, t = 50 } }           -- before both disenchants: not theirs
            b = Ledger.Batch(state, posted)
            assert.are.same({ second, first }, { b.done[1].rec, b.done[2].rec })
            assert.are.same({ 3, 2 }, { b.done[2].left[DUST], b.done[1].left[DUST] })
            posted[2] = { itemID = DUST, qty = 4, t = 300 }                 -- the first disenchant's 3, then 1 of the second
            b = Ledger.Batch(state, posted)
            assert.are.same({ 0, 1, 1 }, { b.done[2].left[DUST], b.done[2].left[ESSENCE], b.done[1].left[DUST] })
            assert.are.equal(2, #b.done)                                    -- the first still has its essence
            posted[3] = { itemID = ESSENCE, qty = 1, t = 310 }
            b = Ledger.Batch(state, posted)
            assert.are.same({ 1, second, 1 }, { #b.done, b.done[1].rec, b.done[1].units })   -- partly posted: stays
            -- A sale of units posted another way (no post of Salvager) takes them at the sale.
            Ledger.Sell(state, DUST, 1, 300, 15, 400)
            assert.are.equal(0, #Ledger.Batch(state, posted).done)          -- all posted or sold: it leaves
        end)

        it("counts a sale of a Salvager post once, and caps the units by what you hold", function()
            Ledger.MailPurchase(state, 7001, 1, 500, 900, 10, "[A]")
            disenchant(100, 7001, { [DUST] = 4 })
            local posted = { { itemID = DUST, qty = 2, each = 150, t = 200 } }
            local sale = Ledger.Sell(state, DUST, 2, 300, 15, 300)
            sale.postedAt = 200                                             -- from that post: not counted again
            local b = Ledger.Batch(state, posted)
            assert.are.equal(2, b.done[1].left[DUST])
            -- Converted or mailed away: 1 dust left in the bags.
            b = Ledger.Batch(state, posted, function(id) return id == DUST and 1 or nil end)
            assert.are.equal(1, b.done[1].left[DUST])
        end)
    end)
end)

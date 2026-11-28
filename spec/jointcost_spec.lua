local helper = require("spec.helper")

-- The cost of disenchanted gear, shared per band (SDD 4).
describe("Ledger joint cost per band", function()
    local ns, Ledger, state
    local DUST, SHARD, ESS = 1, 2, 3
    local prices
    local function priceOf(id) return prices[id] end
    local paid, written

    -- One item bought for `cost` and disenchanted into `got`, in item level band `band` (uncommon armor).
    local function de(cost, got, band, t)
        Ledger.AddPurchase(state, 77, 1, cost, nil, t or 1)
        paid = paid + cost
        return Ledger.Disenchant(state, { t = t or 2, itemID = 77, quality = 2, classID = 4, band = band or 30,
            got = got }, Ledger.TakePurchase(state, 77), priceOf, 0)
    end

    -- Everything paid is in a booked sale or on a unit not sold yet, to the copper; and each pool's parts add
    -- up to its cost.
    local function conserved()
        local booked, held = 0, 0
        for _, s in ipairs(state.sales) do booked = booked + (s.cost or 0) end
        for _, s in pairs(state.stock) do held = held + s.cost end
        assert.are.equal(paid + written, booked + held)
        for _, p in pairs(state.pools) do
            local sum = 0
            for _, m in pairs(p.mats) do
                assert.is_true(m.qty > 0)
                sum = sum + m.cost
            end
            assert.are.equal(p.cost, sum)
        end
    end

    local function pooled(key, id)
        local p = state.pools[key]
        return p and p.mats[id]
    end

    before_each(function()
        ns = helper.load()
        Ledger = ns.Ledger
        state = Ledger.Init({})
        prices = { [DUST] = 100, [SHARD] = 1000, [ESS] = 400 }
        paid, written = 0, 0
    end)

    it("gives every material of a band the same cost for its value", function()
        de(1100, { [DUST] = 3 })      -- 11s: three dust worth 3s
        de(1100, { [SHARD] = 1 })     -- 11s: a shard worth 10s
        -- 22s over 13s of value: dust 2200 * 300 / 1300, shard 2200 * 1000 / 1300, rounded to add up.
        assert.are.equal(508, state.stock[DUST].cost)
        assert.are.equal(1692, state.stock[SHARD].cost)
        assert.is_true(math.abs(state.stock[DUST].cost / 300 - state.stock[SHARD].cost / 1000) < 0.005)
        -- The dust's break-even is near its price, not near the 11s its item cost.
        assert.are.equal(math.ceil(508 / 3 / 0.95), Ledger.BreakEven(state, DUST, 0.05))
        assert.is_true(Ledger.BreakEven(state, DUST, 0.05) < 2 * prices[DUST])
        conserved()
    end)

    it("shares the band's cost again when a new disenchant comes", function()
        de(1100, { [DUST] = 3 })
        assert.are.equal(1100, state.stock[DUST].cost)     -- alone in its band: all of it
        de(1100, { [SHARD] = 1 })
        assert.are.equal(508, state.stock[DUST].cost)      -- now it shares with the shard
        de(900, { [DUST] = 2, [ESS] = 1 }, 35)             -- another band: the first one is not touched
        assert.are.equal(508, pooled("2:a:30", DUST).cost)
        assert.are.equal(900 * 200 / 600, pooled("2:a:35", DUST).cost)
        assert.are.equal(508 + 300, state.stock[DUST].cost)
        conserved()
    end)

    it("averages a material over the bands it came from, and sells from each in proportion", function()
        de(1000, { [DUST] = 2 })
        de(1000, { [SHARD] = 1 })                           -- band 30: 20s over 2s of dust and a 10s shard
        de(300, { [DUST] = 3 }, 35)                         -- band 35: 3s over three dust
        local a, b = pooled("2:a:30", DUST).cost, pooled("2:a:35", DUST).cost
        assert.are.same({ 333, 300 }, { a, b })
        assert.are.equal((a + b) / 5, Ledger.AvgCost(state, DUST))
        local rec = Ledger.Sell(state, DUST, 2, 400, 20, 3)
        assert.are.equal(math.floor((a + b) * 2 / 5 + 0.5), rec.cost)   -- two at the average of this moment
        -- Each band gave up its share of the units (2 of 5: 0.8 and 1.2, rounded) and of its cost.
        assert.are.same({ 1, 2 }, { pooled("2:a:30", DUST).qty, pooled("2:a:35", DUST).qty })
        assert.are.equal(a + b - rec.cost, state.stock[DUST].cost)
        -- The shard keeps its part: band 30 lost dust value and cost in the same ratio.
        assert.is_true(math.abs(state.stock[SHARD].cost - 1667) <= 1)
        -- A booked sale never changes afterwards.
        de(5000, { [DUST] = 1 }, 35)
        assert.are.equal(math.floor((a + b) * 2 / 5 + 0.5), rec.cost)
        conserved()
    end)

    it("loses no copper and invents none over a long run", function()
        local seed = 7
        local function rnd(n)
            seed = (seed * 1103515245 + 12345) % 2147483648
            return seed % n + 1
        end
        for step = 1, 400 do
            local roll = rnd(10)
            if roll <= 5 then
                local got = {}
                got[rnd(3)] = rnd(4)
                if rnd(3) == 1 then got[rnd(3)] = rnd(2) end
                de(rnd(3000) + 13, got, 25 + 5 * rnd(3), step)
            elseif roll <= 6 then
                Ledger.Disenchant(state, { t = step, quality = 2, classID = 4, band = 30, got = { [rnd(3)] = rnd(3) } },
                    nil, priceOf, 0)                        -- no recorded purchase: unknown cost
            elseif roll <= 9 then
                local id = rnd(3)
                local s = state.stock[id]
                if s then Ledger.Sell(state, id, rnd(s.qty + 1), 1000, 50, step) end
            else
                prices[rnd(3)] = rnd(2000)                  -- the market moves
            end
            conserved()
        end
        assert.is_true(#state.sales > 50)
    end)

    it("keeps units of unknown cost out of the average and the pools", function()
        de(1100, { [DUST] = 2 })
        Ledger.Disenchant(state, { t = 3, quality = 2, classID = 4, band = 30, got = { [DUST] = 3 } }, nil, priceOf, 0)
        assert.are.same({ 5, 3 }, { state.stock[DUST].qty, state.stock[DUST].unknown })
        assert.are.equal(2, pooled("2:a:30", DUST).qty)
        assert.are.equal(550, Ledger.AvgCost(state, DUST))
        local rec = Ledger.Sell(state, DUST, 4, 400, 20, 4)      -- the two known first, then two unknown
        assert.are.same({ 1100, 2 }, { rec.cost, rec.untracked })
        assert.is_nil(state.pools["2:a:30"])
        assert.are.same({ 1, 1 }, { state.stock[DUST].qty, state.stock[DUST].unknown })
        conserved()
    end)

    it("takes the cost out of the pools when essences change form or stock is set by hand", function()
        local lesser, greater = ESS, 4
        de(1200, { [lesser] = 3 })
        de(1200, { [SHARD] = 1 })
        local before = state.stock[lesser].cost
        local cost = Ledger.Convert(state, lesser, 3, greater, 1)
        assert.are.equal(before, cost)
        assert.are.equal(before, state.stock[greater].cost)
        assert.is_nil(pooled("2:a:30", lesser))
        assert.are.equal(2400 - before, state.stock[SHARD].cost)   -- the shard keeps its own part
        conserved()
        -- Opening stock replaces what the pools held of a material: its part of the cost goes with it.
        de(1000, { [DUST] = 2 })
        local dustPart = state.stock[DUST].cost
        Ledger.SetStock(state, DUST, 10, 50)
        assert.is_nil(pooled("2:a:30", DUST))
        assert.are.equal(500, state.stock[DUST].cost)
        written = 500 - dustPart
        conserved()
    end)

    it("shares old records once at load: sales booked again, the rest kept", function()
        -- A ledger from before 0.3.120: each item's price split over its own disenchant.
        local old = Ledger.Init({
            disenchants = {
                { t = 1, itemID = 77, quality = 2, classID = 4, band = 30, cost = 1100, costKnown = true,
                    got = { [DUST] = 3 }, vals = { [DUST] = 300 }, shares = { [DUST] = 1100 } },
                { t = 2, itemID = 77, quality = 2, classID = 4, band = 30, cost = 1100, costKnown = true,
                    got = { [SHARD] = 1 }, vals = { [SHARD] = 1000 }, shares = { [SHARD] = 1100 } },
                { t = 4, itemID = 88, quality = 2, classID = 4, band = 30, cost = 0, costKnown = false,
                    got = { [DUST] = 2 }, vals = { [DUST] = 200 } },
            },
            sales = {
                { t = 3, id = DUST, count = 2, gross = 1000, cut = 50, net = 950, cost = 733, untracked = 0, profit = 217 },
                { t = 5, id = DUST, count = 0, qty = 4, gross = 0, cut = 0, net = -30, cost = 0, untracked = 0,
                    netUntracked = 0, profit = -30, lost = "expired" },
            },
            -- One dust left of the three (367), five set by hand at 50 each, two of unknown cost; the shard.
            stock = { [DUST] = { qty = 8, cost = 367 + 250, unknown = 2 }, [SHARD] = { qty = 1, cost = 1100, unknown = 0 } },
        })
        assert.is_true(Ledger.NeedsRecost(old))
        local n, sold = Ledger.Recost(old)
        assert.are.same({ 2, 1 }, { n, sold })
        assert.is_false(Ledger.NeedsRecost(old))
        -- The sale: two of the three dust at the band's share (508 for three).
        assert.are.equal(339, old.sales[1].cost)
        assert.are.equal(950 - 339, old.sales[1].profit)
        assert.are.equal(-30, old.sales[2].profit)               -- a lost deposit stays as it was
        -- Stock: the counts stay; the one dust in the pool, the five others at what the books held beyond the pools:
        -- the 250 they were set to by hand (SDD 125; the old average, 514, made 264 copper from nothing).
        assert.are.same({ 8, 2 }, { old.stock[DUST].qty, old.stock[DUST].unknown })
        assert.are.equal(1, old.pools["2:a:30"].mats[DUST].qty)
        assert.are.equal(169 + 250, old.stock[DUST].cost)
        assert.are.equal(733 + 617 + 1100, Ledger.Booked(old))   -- the books as before, to the copper
        assert.are.equal(1692, old.stock[SHARD].cost)
        -- What the two disenchants cost is all in the sale and the pool, to the copper.
        assert.are.equal(2200, old.sales[1].cost + old.pools["2:a:30"].cost)
        assert.is_nil(old.disenchants[1].shares)
        -- A new ledger needs none of this.
        assert.is_false(Ledger.NeedsRecost(Ledger.Init({})))
    end)
end)

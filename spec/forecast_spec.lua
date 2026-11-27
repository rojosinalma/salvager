local helper = require("spec.helper")

-- The forecast learns from your own sales (SDD 3, 96): the sell price ratio and the deposits lost per unit sold.
describe("Forecast from your own sales", function()
    local ns, Model, Ledger, Data
    local NOW = 2000000000
    local DUST, ESS, SHARD = 11083, 11082, 11084
    before_each(function()
        ns = helper.load()
        Model, Ledger, Data = ns.Model, ns.Ledger, ns.Data
    end)

    local function ledger(sales)
        local state = Ledger.Init({})
        state.sales = sales
        return state
    end
    -- A sale of `count` units at `each`, posted when the value was `val`, `ago` seconds before NOW.
    local function sale(id, count, each, val, ago)
        return { id = id, count = count, gross = count * each, each = each, net = count * each, val = val,
            t = NOW - (ago or 60) }
    end

    describe("weighted median and blend", function()
        it("takes the value where half the units lie, the middle at an exact half", function()
            assert.are.equal(2, Model.WeightedMedian({ { r = 1, w = 1 }, { r = 2, w = 1 }, { r = 9, w = 1 } }))
            assert.are.equal(9, Model.WeightedMedian({ { r = 1, w = 1 }, { r = 2, w = 1 }, { r = 9, w = 5 } }))
            assert.are.equal(1.5, Model.WeightedMedian({ { r = 1, w = 2 }, { r = 2, w = 2 } }))
            assert.is_nil(Model.WeightedMedian({}))
        end)

        it("pulls a value on few samples toward the prior, in proportion", function()
            assert.are.equal(0.8, Model.Blend(0.8, 5, 1, 5))
            assert.are.equal(0.8, Model.Blend(0.8, 50, 1, 5))
            assert.is_true(math.abs(Model.Blend(0.8, 2, 1, 5) - 0.92) < 1e-9)   -- (2 x 0.8 + 3 x 1) / 5
            assert.are.equal(1, Model.Blend(nil, 0, 1, 5))
        end)
    end)

    describe("sell price ratio", function()
        it("is 1 with no sales", function()
            local r = Ledger.SellRatios(ledger({}), nil, NOW)
            assert.are.equal(1, r.all.ratio)
            assert.is_nil(r[DUST])
        end)

        it("is the median of a material's sales against its value when posted, by units", function()
            local sales = {}
            for i, each in ipairs({ 380, 390, 400, 410, 900 }) do sales[i] = sale(DUST, 10, each, 400) end
            local r = Ledger.SellRatios(ledger(sales), nil, NOW)
            assert.are.equal(1, r[DUST].ratio)            -- 400 / 400: the one silly sale does not move it
            assert.are.equal(5, r[DUST].n)
            assert.are.equal(50, r[DUST].units)
            assert.is_false(r[DUST].few)
        end)

        it("leans on all materials while a material has few sales, and that on 1", function()
            local sales = {}
            for i = 1, 6 do sales[i] = sale(DUST, 1, 360, 400) end      -- dust: 0.9 on 6 sales
            sales[7] = sale(SHARD, 1, 1600, 2000)                          -- shard: 0.8 on one sale
            local r = Ledger.SellRatios(ledger(sales), nil, NOW)
            assert.are.equal(0.9, r.all.ratio)                             -- 7 sales: enough
            assert.is_true(math.abs(r[SHARD].ratio - (0.8 + 4 * 0.9) / 5) < 1e-9)
            assert.is_true(r[SHARD].few)
            -- With two sales in all, the overall ratio itself leans on 1.
            local two = Ledger.SellRatios(ledger({ sale(DUST, 1, 360, 400), sale(DUST, 1, 360, 400) }), nil, NOW)
            assert.is_true(math.abs(two.all.ratio - (2 * 0.9 + 3) / 5) < 1e-9)
        end)

        it("asks for the value when a sale has none, leaves out lost deposits and weighs old sales by age", function()
            local old = sale(DUST, 10, 100, 400, 31 * 86400)
            local lost = { id = DUST, count = 0, qty = 5, gross = 0, net = -10, lost = "expired", t = NOW - 60 }
            local plain = sale(DUST, 2, 360, nil)
            local asked = 0
            local r = Ledger.SellRatios(ledger({ old, lost, plain }), function(s)
                asked = asked + 1
                assert.are.equal(plain, s)
                return 400
            end, NOW)
            assert.are.equal(1, asked)
            -- The sale of 31 days ago weighs 0.5^(31/30) (SDD 118): it counts, less than today's.
            assert.are.equal(2, r[DUST].count)
            assert.is_true(math.abs(r[DUST].n - (1 + 0.5 ^ (31 / 30))) < 1e-9)
            -- Its 10 units at about half weight (4.9) still outweigh today's 2 units: the median is its ratio.
            assert.are.equal(0.25, r[DUST].measured)
            -- Without it, today's sale alone.
            local fresh = Ledger.SellRatios(ledger({ lost, plain }), function() return 400 end, NOW)
            assert.are.equal(0.9, fresh[DUST].measured)
        end)
    end)

    describe("deposits lost", function()
        local function unit(id) return ({ [DUST] = 2, [ESS] = 10 })[id] end

        it("counts one post's deposit per unit sold with no data", function()
            local d = Ledger.DepositRates(ledger({}), unit, NOW)
            assert.are.equal(1, d.all.k)
        end)

        it("is the deposits lost per unit sold, as a share of one post's deposit", function()
            local sales = {}
            for i = 1, 5 do sales[i] = sale(DUST, 20, 400, 400) end       -- 100 dust sold
            sales[6] = { id = DUST, count = 0, qty = 20, gross = 0, net = -40, lost = "cancelled", t = NOW - 60 }
            local d = Ledger.DepositRates(ledger(sales), unit, NOW)
            assert.are.equal(0.2, d[DUST].k)                               -- 40 / (100 x 2)
            assert.are.equal(0.4, d[DUST].perUnit)                         -- copper per unit sold
            assert.is_false(d[DUST].few)
            assert.are.equal(0.2, d.all.k)
        end)

        it("leans on all materials while a material has few sales", function()
            local sales = {}
            for i = 1, 5 do sales[i] = sale(DUST, 20, 400, 400) end
            sales[6] = { id = DUST, count = 0, qty = 20, gross = 0, net = -40, lost = "cancelled", t = NOW - 60 }
            sales[7] = sale(ESS, 1, 2000, 2000)                            -- one essence sold, nothing lost
            local d = Ledger.DepositRates(ledger(sales), unit, NOW)
            local all = 40 / (100 * 2 + 1 * 10)                             -- 6 sales: the overall rate leans on 1
            local prior = (6 * all + 0) / 6
            assert.is_true(math.abs(d.all.k - prior) < 1e-9)
            assert.is_true(math.abs(d[ESS].k - (0 + 4 * prior) / 5) < 1e-9)
            assert.is_true(math.abs(d[ESS].perUnit - d[ESS].k * 10) < 1e-9)
        end)
    end)

    describe("in the value and the buy limit", function()
        local prices = { [DUST] = 400, [ESS] = 2000, [SHARD] = 6000 }
        local function priceOf(id) return prices[id] end
        local outcomes
        before_each(function() outcomes = Model.Outcomes(2, Data.CLASS_ARMOR, 28) end)

        it("is the same as before with a ratio of 1 and no deposits", function()
            local a = Model.Value(outcomes, priceOf, { cut = 0.05 })
            local b = Model.Value(outcomes, priceOf, { cut = 0.05, ratio = function() return 1 end,
                deposit = function() return 0 end })
            assert.are.same({ a.net, a.low }, { b.net, b.low })
        end)

        it("values each unit at price x ratio after the cut, less the deposits lost", function()
            local plain = Model.Value(outcomes, priceOf, { cut = 0.05 })
            local v = Model.Value(outcomes, priceOf, { cut = 0.05, ratio = function() return 0.9 end,
                deposit = function() return 3 end })
            -- Units per disenchant in this band: 0.75 x 1.5 + 0.2 x 1.5 + 0.05 x 1 = 1.475.
            local units = 0
            for _, r in ipairs(outcomes.results) do units = units + r.chance * (r.min + r.max) / 2 end
            assert.are.equal(math.floor(plain.gross * 0.9 * 0.95 - 3 * units + 0.5), v.net)
            assert.is_true(math.abs(v.deposits - 3 * units) < 1e-9)
            assert.is_true(v.low < plain.low)
            -- The buy limit follows: lower by the same amount.
            local limit = Model.MaxBuy(v.net, 100)
            assert.are.equal(Model.MaxBuy(plain.net, 100) - (plain.net - v.net), limit)
        end)

        it("raises the chance to lose when units sell below their value", function()
            local opts = { cut = 0.05 }
            local paid = 600
            local base = Model.LossChance(outcomes, priceOf, opts, paid)
            local low = Model.LossChance(outcomes, priceOf, { cut = 0.05, ratio = function() return 0.7 end }, paid)
            assert.is_true(low > base)
        end)
    end)
end)

local helper = require("spec.helper")

describe("Arcane Salvager recipe in money (Craft, pure)", function()
    local ns, Craft, Ledger, Data
    local VD, LNE = 11137, 11174

    setup(function()
        ns = helper.load()
        Craft, Ledger, Data = ns.Craft, ns.Ledger, ns.Data
    end)

    local function prices(t) return function(id) return t[id] end end

    it("knows the recipe: 2 Vision Dust and 1 Lesser Nether Essence make one Arcane Salvager, the rod not used up", function()
        local r = Data.SALVAGER_RECIPE
        assert.are.equal(1263056, r.spell)
        assert.are.equal(279985, r.result)
        assert.are.equal(11130, r.tool)
        assert.are.equal(20, r.stack)
        assert.are.same({ { id = VD, qty = 2 }, { id = LNE, qty = 1 } }, r.reagents)
        assert.are.equal(273103, Data.SALVAGER_BLUEPRINT)
        assert.is_false(Data.SALVAGER_ITEM_BY_ID[11130].auction)   -- binds when picked up
        assert.is_false(Data.SALVAGER_ITEM_BY_ID[273103].commodity)
        assert.is_true(Data.SALVAGER_ITEM_BY_ID[279985].commodity)
    end)

    it("costs a craft at the price now when you hold no reagent", function()
        local c = Craft.Cost({ priceOf = prices({ [VD] = 900, [LNE] = 3000 }) })
        assert.are.equal(4800, c.total)
        assert.are.equal("price", c.source)
        assert.are.equal("price", c.parts[1].source)
        assert.are.equal(900, c.parts[1].each)
    end)

    it("costs a reagent at the stock's average cost when you hold enough of it, and says which", function()
        local L = Ledger.Init({})
        Ledger.BuyMaterial(L, VD, 4, 2800, 1000)   -- 700 each
        local opts = {
            priceOf = prices({ [VD] = 900, [LNE] = 3000 }),
            avgCostOf = function(id) return Ledger.AvgCost(L, id) end,
            knownOf = function(id) return Ledger.KnownQty(L, id) end,
        }
        local c = Craft.Cost(opts)
        assert.are.equal(2 * 700 + 3000, c.total)
        assert.are.equal("mixed", c.source)
        assert.are.equal("stock", c.parts[1].source)
        assert.are.equal("price", c.parts[2].source)
        -- One unit held is not enough for a craft of two: the price now.
        local one = Ledger.Init({})
        Ledger.BuyMaterial(one, VD, 1, 700, 1000)
        opts.avgCostOf = function(id) return Ledger.AvgCost(one, id) end
        opts.knownOf = function(id) return Ledger.KnownQty(one, id) end
        assert.are.equal("price", Craft.Cost(opts).parts[1].source)
    end)

    it("has no cost when a reagent has neither a stock cost nor a price", function()
        local c = Craft.Cost({ priceOf = prices({ [VD] = 900 }) })
        assert.is_nil(c.total)
        assert.are.same({ LNE }, c.missing)
        assert.are.equal("price", c.source)
    end)

    it("says craft or buy, and by how much", function()
        assert.are.same({ "craft", 200 }, { Craft.Cheaper(4800, 5000) })
        assert.are.same({ "buy", 300 }, { Craft.Cheaper(5300, 5000) })
        assert.are.same({ "same", 0 }, { Craft.Cheaper(5000, 5000) })
        assert.is_nil(Craft.Cheaper(nil, 5000))
        assert.is_nil(Craft.Cheaper(4800, nil))
    end)

    it("works out the profit per craft after the cut, per stack of 20, and the Blueprint's payback", function()
        assert.are.equal(8930 - 4800, Craft.Profit(9400, 4800, 0.05))
        assert.are.equal(15, Craft.Payback(60000, 4130))   -- 14.5 crafts: the 15th pays it back
        assert.are.equal(1, Craft.Payback(100, 4130))
        assert.is_nil(Craft.Payback(60000, 0))              -- no profit: never paid back
        assert.is_nil(Craft.Payback(60000, -50))
        assert.is_nil(Craft.Payback(nil, 4130))
        local s = Craft.Summary({ priceOf = prices({ [VD] = 900, [LNE] = 3000, [279985] = 9400, [273103] = 60000 }),
            cut = 0.05, known = false })
        assert.is_false(s.known)
        assert.are.equal(4800, s.cost.total)
        assert.are.equal(9400, s.buy)
        assert.are.equal("craft", s.cheaper)
        assert.are.equal(4600, s.by)
        assert.are.equal(8930, s.sale)
        assert.are.equal(4130, s.profit)
        assert.are.equal(4130 * 20, s.profitStack)
        assert.are.equal(60000, s.blueprint)
        assert.are.equal(15, s.payback)
    end)

    it("leaves what it cannot know empty", function()
        local s = Craft.Summary({ priceOf = prices({}), known = true })
        assert.is_true(s.known)
        assert.is_nil(s.cost.total)
        assert.is_nil(s.buy)
        assert.is_nil(s.cheaper)
        assert.is_nil(s.profit)
        assert.is_nil(s.profitStack)
        assert.is_nil(s.payback)
    end)
end)

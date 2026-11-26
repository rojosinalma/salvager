local helper = require("spec.helper")

describe("Model", function()
    local ns, Model, Data, price
    before_each(function()
        ns = helper.load()
        Model, Data = ns.Model, ns.Data
        price = helper.sheetPrices(ns)
    end)

    local function sheetValue(ilvl)
        local o = Model.Outcomes(2, Data.CLASS_ARMOR, ilvl)
        return Model.Value(o, price, { salvager = true, salvagerChance = 0.5 }).net
    end

    -- Expected values after AH cut from the community spreadsheet (silver).
    it("reproduces the spreadsheet for uncommon armor with the Salvager", function()
        assert.are.equal(1563, sheetValue(28))   -- ilvl 26-30: 15.63s
        assert.are.equal(2137, sheetValue(38))   -- ilvl 36-40: 21.37s
        assert.are.equal(12328, sheetValue(48))  -- ilvl 46-50: 123.28s
        assert.are.equal(25616, sheetValue(63))  -- ilvl 61-65: 256.16s
    end)

    it("is lower without the Salvager", function()
        local o = Model.Outcomes(2, Data.CLASS_ARMOR, 28)
        local without = Model.Value(o, price, { salvager = false }).net
        assert.is_true(without < 1563)
        -- 0.75*1.5*433 + 0.2*1.5*1766 + 0.05*5780 = 1305.925c, x0.95
        assert.are.equal(math.floor(1305.925 * 0.95 + 0.5), without)
    end)

    it("swaps dust and essence chances for weapons", function()
        local o = Model.Outcomes(2, Data.CLASS_WEAPON, 38)
        assert.are.equal(Data.DUST.vision, o.results[1].id)
        assert.are.equal(0.20, o.results[1].chance)
        assert.are.equal(0.75, o.results[2].chance)
    end)

    it("gives Greater Magic Essence for weapons of item level 21-30", function()
        local o = Model.Outcomes(2, Data.CLASS_WEAPON, 24)
        assert.are.equal(Data.ESS.gmagic, o.results[2].id)
        local a = Model.Outcomes(2, Data.CLASS_ARMOR, 24)
        assert.are.equal(Data.ESS.lastral, a.results[2].id)
    end)

    it("gives no shard at item level 15 and below", function()
        local o = Model.Outcomes(2, Data.CLASS_ARMOR, 12)
        assert.are.equal(2, #o.results)
    end)

    it("gives one shard for rare items and no Salvager bonus", function()
        local o = Model.Outcomes(3, Data.CLASS_ARMOR, 48)
        assert.are.equal(Data.SHARD.lrad, o.results[1].id)
        local v1 = Model.Value(o, price, { salvager = true }).net
        local v2 = Model.Value(o, price, { salvager = false }).net
        assert.are.equal(v1, v2)
    end)

    it("knows gear the game will not disenchant", function()
        assert.is_true(ns.NoDisenchant(11287))   -- Lesser Magic Wand
        assert.is_false(ns.NoDisenchant(6423))
    end)

    it("works out the chance that one disenchant is worth less than the price", function()
        -- An item level 29 hood at 11s 46c: dust 4s 30c, essence 16s 88c, shard 66s 60c.
        local p = { [Data.DUST.soul] = 430, [Data.ESS.gastral] = 1688, [Data.SHARD.lglim] = 6660 }
        local priceOf = function(id) return p[id] end
        local o = Model.Outcomes(2, Data.CLASS_ARMOR, 29)
        assert.is_true(math.abs(Model.LossChance(o, priceOf, {}, 1146) - 0.75) < 1e-9)   -- every dust result loses
        assert.is_true(math.abs(Model.LossChance(o, priceOf, {}, 500) - 0.375) < 1e-9)   -- only a single dust loses
        assert.are.equal(0, Model.LossChance(o, priceOf, {}, 100))
        -- With the Salvager, one dust becomes two half of the time.
        local with = Model.LossChance(o, priceOf, { salvager = true, salvagerChance = 0.5 }, 500)
        assert.is_true(math.abs(with - 0.1875) < 1e-9)
    end)

    it("also gives the value with every material at its lowest amount", function()
        local p = { [Data.DUST.soul] = 400, [Data.ESS.gastral] = 1600, [Data.SHARD.lglim] = 6000 }
        local priceOf = function(id) return p[id] end
        local o = Model.Outcomes(2, Data.CLASS_ARMOR, 29)
        local v = Model.Value(o, priceOf, { salvager = true, salvagerChance = 0.5 })
        -- lowest amounts, no bonus: 0.75 x 1 x 4s + 0.2 x 1 x 16s + 0.05 x 60s = 9s 20c, x 0.95
        assert.are.equal(math.floor(920 * 0.95 + 0.5), v.low)
        assert.is_true(v.low < v.net)
    end)

    it("refuses non-gear and common items", function()
        assert.is_nil(Model.Outcomes(2, 15, 30))
        assert.is_nil(Model.Outcomes(1, Data.CLASS_ARMOR, 30))
    end)

    it("reports materials without a price", function()
        local o = Model.Outcomes(2, Data.CLASS_ARMOR, 33)  -- lesser mystic: not in sheet
        local v = Model.Value(o, price, {})
        assert.are.same({ Data.ESS.lmystic }, v.missing)
    end)

    it("fills a missing essence price from the other form", function()
        local raw = function(id) if id == Data.ESS.gmystic then return 2100 end end
        local p, derived = Model.PairPrice(Data.ESS.lmystic, raw)
        assert.are.equal(700, p)
        assert.is_true(derived)
    end)
end)

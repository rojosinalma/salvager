local helper = require("spec.helper")

-- The self-adjusting model (SDD 118): results weigh by their age, the Salvager shape is learned per material kind
-- from every band, and each band's blend starts from it.
describe("The self-adjusting model", function()
    local ns, Model, Ledger, Data
    local DAY = 86400
    local NOW = 2000000000
    local SOUL, ASTRAL, STRANGE = 11083, 11082, 10940

    before_each(function()
        ns = helper.load()
        Model, Ledger, Data = ns.Model, ns.Ledger, ns.Data
    end)

    local function kindOf(id) return Data.MATERIAL_BY_ID[id] and Data.MATERIAL_BY_ID[id].kind end
    local function byId(b, id)
        for _, r in ipairs(b.results) do if r.id == id then return r end end
    end
    local function sum(t)
        local s = 0
        for _, p in pairs(t) do s = s + p end
        return s
    end
    -- A ledger of disenchants: each { got = { [id] = qty }, band, salvager, ago (days) }.
    local function ledger(list)
        local state = Ledger.Init({})
        for _, x in ipairs(list) do
            state.disenchants[#state.disenchants + 1] = { t = NOW - (x.ago or 0) * DAY, quality = 2, classID = 4,
                band = x.band or 30, got = x.got, salvager = x.salvager }
        end
        return state
    end
    local function many(n, id, qty, band, salvager, ago, into)
        into = into or {}
        for _ = 1, n do into[#into + 1] = { got = { [id] = qty }, band = band, salvager = salvager, ago = ago } end
        return into
    end
    local function blended(state, quality, ilvl, salvager)
        local o = Model.Outcomes(quality, Data.CLASS_ARMOR, ilvl)
        local key = Ledger.BandKey(quality, Data.CLASS_ARMOR, o.band)
        local seen = Ledger.Results(state, NOW)[key]
        local shapes = Ledger.Shapes(state, NOW).on
        return Model.Blended(o, seen and seen[salvager and "on" or "off"], { salvager = salvager, salvagerChance = 0.5,
            shapeOf = function(r) return (Model.ShapeDist(r, shapes, kindOf, 0.5)) end })
    end

    it("weighs a result by its age in whole days: today 1, a month 0.5, two months 0.25", function()
        assert.are.equal(1, Model.Decay(0))
        assert.are.equal(1, Model.Decay(DAY - 1))
        assert.are.equal(0.5, Model.Decay(30 * DAY))
        assert.are.equal(0.25, Model.Decay(60 * DAY))
        assert.are.equal(1, Model.Decay(-5))                     -- a clock behind the record: never more than 1
    end)

    it("is the community rule with no data: one more half of the time on dust and essence, never on shards", function()
        local s = Model.LearnedShape(nil, 2, 0.5)
        assert.are.same({ [0] = 0.25, [1] = 0.5, [2] = 0.25 }, s.dist)
        assert.are.equal(0, s.n)
        assert.is_true(s.few)
        assert.are.same({ [0] = 1, [1] = 0 }, Model.LearnedShape(nil, 1, 0).dist)
        -- The band's blend with no results at all is the 0.3 model to the last digit.
        local state = ledger({})
        local o = Model.Outcomes(2, Data.CLASS_ARMOR, 28)
        local old = Model.Blended(o, nil, { salvager = true, salvagerChance = 0.5 })
        local new = blended(state, 2, 28, true)
        for _, r in ipairs(old.results) do
            local n = byId(new, r.id)
            assert.is_true(math.abs(n.chance - r.chance) < 1e-12)
            for q, p in pairs(r.dist) do assert.is_true(math.abs((n.dist[q] or 0) - p) < 1e-12, q) end
            assert.are.equal(sum(r.dist) > 0, sum(n.dist) > 0)
        end
    end)

    it("keeps every chance adding up to 1: shapes at each width, quantities, results and outcomes", function()
        local list = many(40, SOUL, 2, 30, true)
        many(30, SOUL, 3, 30, true, 10, list)
        many(9, SOUL, 4, 35, true, 50, list)                     -- Soul Dust 2-5: a band of four values
        many(12, ASTRAL, 3, 30, true, 2, list)
        many(6, 11084, 1, 30, true, 0, list)                     -- shards: never more
        local state = ledger(list)
        local shapes = Ledger.Shapes(state, NOW).on
        for _, kind in ipairs({ "dust", "essence", "shard" }) do
            for m = 1, 4 do
                assert.is_true(math.abs(sum(Model.LearnedShape(shapes[kind], m, kind == "shard" and 0 or 0.5).dist) - 1)
                    < 1e-9, kind .. m)
            end
        end
        for _, ilvl in ipairs({ 28, 33, 15 }) do
            local b = blended(state, 2, ilvl, true)
            local total = 0
            for _, r in ipairs(b.results) do
                assert.is_true(math.abs(sum(r.dist) - 1) < 1e-9)
                total = total + r.chance
            end
            assert.is_true(math.abs(total - 1) < 1e-9)
            local outcomes = Model.Results(b, function() return 100 end, { cut = 0 })
            local s = 0
            for _, x in ipairs(outcomes) do s = s + x.chance end
            assert.is_true(math.abs(s - 1) < 1e-9)
        end
        -- Shards stay at one unit with the Salvager: 6 results at 1 and the rule's "never".
        assert.are.same({ [1] = 1 }, byId(blended(state, 2, 28, true), 11084).dist)
    end)

    it("reproduces the measured Soul Dust shape of Uncommon Armor 26-30 (149 / 117 / 139 with the Salvager)", function()
        local list = many(149, SOUL, 1, 30, true)
        many(117, SOUL, 2, 30, true, 0, list)
        many(139, SOUL, 3, 30, true, 0, list)
        local state = ledger(list)
        local shape = Model.LearnedShape(Ledger.Shapes(state, NOW).on.dust, 2, 0.5)
        assert.are.equal(405, shape.n)
        for j, c in pairs({ [0] = 149, [1] = 117, [2] = 139 }) do
            assert.is_true(math.abs(shape.dist[j] - c / 405) < 0.03, j)
        end
        -- One more at the top about a third of the time, not the rule's quarter.
        assert.is_true(shape.top > 0.32)
        local dust = byId(blended(state, 2, 28, true), SOUL)
        for q, c in pairs({ [1] = 149, [2] = 117, [3] = 139 }) do
            assert.is_true(math.abs(dust.dist[q] - c / 405) < 0.02, q)
        end
    end)

    it("takes the shape learned in many bands to a band with 5 results of its own", function()
        -- Soul Dust 1-2 in 26-30 and Vision Dust 1-2 in 36-40: a third at each of 1, 2, 3.
        local list = {}
        for _, x in ipairs({ { 30, SOUL }, { 40, 11137 } }) do
            for q = 1, 3 do many(100, x[2], q, x[1], true, 0, list) end
        end
        many(5, STRANGE, 1, 15, true, 0, list)                   -- Uncommon Armor 5-15: Strange Dust 1-2, 5 results
        local state = ledger(list)
        local pooled = byId(blended(state, 2, 12, true), STRANGE).dist
        -- Without the pool (the 0.3 model): 25% at 3.
        local o = Model.Outcomes(2, Data.CLASS_ARMOR, 12)
        local seen = Ledger.Results(state, NOW)[Ledger.BandKey(2, Data.CLASS_ARMOR, o.band)].on
        local plain = byId(Model.Blended(o, seen, { salvager = true, salvagerChance = 0.5 }), STRANGE).dist
        assert.is_true(pooled[3] > 0.28)
        assert.is_true(pooled[3] > plain[3] + 0.05)
        assert.is_true(pooled[2] < plain[2] - 0.1)               -- the middle is no longer half
        -- A band of four values (Soul Dust 2-5) reads the same shape stretched: about a fifth at each of 2..6.
        local wide = Model.LearnedShape(Ledger.Shapes(state, NOW).on.dust, 4, 0.5)
        for k = 0, 4 do assert.is_true(math.abs(wide.dist[k] - 0.2) < 0.03, k) end
    end)

    it("follows a change of the true rate within about 30 days", function()
        -- 180 days at 20% essence, then the game changes it to 40%: ten disenchants a day without the Salvager.
        local function history(daysNew)
            local list = {}
            for day = 0, 180 + daysNew - 1 do
                local ago = 180 + daysNew - 1 - day
                local ess = day < 180 and 2 or 4
                for i = 1, 10 do
                    list[#list + 1] = { got = i <= ess and { [ASTRAL] = 1 } or { [SOUL] = 1 }, band = 30, ago = ago }
                end
            end
            return ledger(list)
        end
        local function rate(state, now)
            local o = Model.Outcomes(2, Data.CLASS_ARMOR, 28)
            local seen = Ledger.Results(state, now)[Ledger.BandKey(2, Data.CLASS_ARMOR, 30)].off
            return byId(Model.Blended(o, seen, { salvager = false }), ASTRAL).chance
        end
        local s30 = history(30)
        local flat = rate(s30, 0)                                -- every result at weight 1: the 0.3 model
        local now30 = rate(s30, NOW)
        assert.is_true(flat < 0.24)                              -- 2100 results: it barely moves
        assert.is_true(now30 > 0.28)                             -- about half way from 20% to 40% after a month
        assert.is_true(rate(history(90), NOW) > 0.35)            -- and most of the way after three (flat: 0.27)
        -- Nothing is deleted: every disenchant still counts.
        assert.are.equal(2100, Ledger.Results(s30, NOW)["2:a:30"].off.count)
    end)
end)

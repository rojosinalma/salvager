local helper = require("spec.helper")

-- Result rates from your own disenchants, blended with the table (SDD 99), and the time to sell (SDD 100).
describe("Result rates blended with the table", function()
    local ns, Model, Ledger, Data
    local o
    local function price(id) return ({ [11083] = 400, [11082] = 1700, [11084] = 5800 })[id] end

    before_each(function()
        ns = helper.load()
        Model, Ledger, Data = ns.Model, ns.Ledger, ns.Data
        o = Model.Outcomes(2, Data.CLASS_ARMOR, 28)   -- Soul Dust 1-2 75%, Greater Astral 1-2 20%, Large Glimmering 5%
    end)

    -- `n` disenchants that each gave `qty` of `id`.
    local function seen(list)
        local s = { n = 0, mats = {} }
        for _, x in ipairs(list) do
            local m = s.mats[x[1]] or { hits = 0, qty = {} }
            s.mats[x[1]] = m
            m.hits = m.hits + x[3]
            m.qty[x[2]] = (m.qty[x[2]] or 0) + x[3]
            s.n = s.n + x[3]
        end
        return s
    end

    local function byId(b, id)
        for _, r in ipairs(b.results) do if r.id == id then return r end end
    end

    it("is the table when you have no results: same value and loss chance, with or without the Salvager", function()
        for _, salvager in ipairs({ false, true }) do
            local opts = { salvager = salvager, salvagerChance = 0.5, cut = 0.05 }
            local b = Model.Blended(o, nil, opts)
            assert.are.equal(0, b.n)
            assert.is_true(b.few)
            assert.are.equal(Model.Value(o, price, opts).net, Model.Value(b, price, opts).net)
            for _, paid in ipairs({ 300, 500, 1000, 2000, 6000 }) do
                assert.is_true(math.abs(Model.LossChance(o, price, opts, paid) - Model.LossChance(b, price, opts, paid)) < 1e-9)
            end
        end
    end)

    it("moves from the table toward your rates as your results grow", function()
        -- You get the essence 40% of the time, not 20%.
        local function essence(n)
            local b = Model.Blended(o, seen({ { 11083, 1, n * 0.6 }, { 11082, 1, n * 0.4 } }), { salvager = false })
            return byId(b, 11082).chance, b
        end
        local c10 = essence(10)
        local c50, b50 = essence(50)
        local c500 = essence(500)
        -- (K × 20% + hits) ÷ (K + n): 10 of yours = (10 + 4) / 60, 50 = (10 + 20) / 100.
        assert.is_true(math.abs(c10 - 14 / 60) < 1e-9)
        assert.is_true(math.abs(c50 - 0.3) < 1e-9)
        assert.is_true(c500 > 0.38 and c500 < 0.4)
        assert.is_false(b50.few)                         -- 50 of yours: no longer few
        -- The chances still add up to one.
        local sum = 0
        for _, r in ipairs(b50.results) do sum = sum + r.chance end
        assert.is_true(math.abs(sum - 1) < 1e-9)
        -- The shard you never got keeps its table weight, shrinking: 50 × 5% ÷ 100.
        assert.is_true(math.abs(byId(b50, 11084).chance - 0.025) < 1e-9)
    end)

    it("blends the quantities too, the Salvager bonus in the table's side, and values with them", function()
        -- With the Salvager, the table says dust 1, 2, 3 at 25%, 50%, 25% (mean 2). You always got 3.
        local opts = { salvager = true, salvagerChance = 0.5, cut = 0 }
        local b = Model.Blended(o, seen({ { 11083, 3, 150 } }), opts)
        local dust = byId(b, 11083)
        -- weights: 1 → 50 × 0.75 × 0.25, 2 → × 0.5, 3 → × 0.25 + 150.
        local w1, w2, w3 = 9.375, 18.75, 9.375 + 150
        local total = w1 + w2 + w3
        assert.is_true(math.abs(dust.dist[3] - w3 / total) < 1e-9)
        assert.is_true(math.abs(dust.mean - (w1 + 2 * w2 + 3 * w3) / total) < 1e-9)
        assert.are.same({ 1, 2 }, { dust.min, dust.max })     -- the table's range stays for cautious pricing
        -- Value: chance × mean × price, no second bonus on top.
        local v = Model.Value(b, price, opts)
        local want = 0
        for _, r in ipairs(b.results) do want = want + r.chance * r.mean * price(r.id) end
        assert.is_true(math.abs(v.gross - want) < 1e-6)
        -- Loss chance at 3 dust: only the 1 and 2 dust results (and nothing else) lose at 1100.
        local lose = Model.LossChance(b, price, opts, 1100)
        assert.is_true(math.abs(lose - dust.chance * (dust.dist[1] + dust.dist[2])) < 1e-9)
    end)

    it("takes in a material the table does not have, from your hits only", function()
        local b = Model.Blended(o, seen({ { 11083, 1, 9 }, { 10940, 2, 1 } }), {})
        local odd = byId(b, 10940)
        assert.is_true(odd.unexpected)
        assert.are.equal(0, odd.tableChance)
        assert.is_true(math.abs(odd.chance - 1 / 60) < 1e-9)
        assert.are.same({ 2, 2, 2 }, { odd.min, odd.max, odd.mean })
    end)

    it("counts your results per band, with and without the Salvager", function()
        local state = Ledger.Init({})
        local function de(got, salvager, band)
            Ledger.Disenchant(state, { t = 1, quality = 2, classID = 4, band = band or 30, got = got, salvager = salvager },
                nil, price, 0)
        end
        de({ [11083] = 3 }, true)
        de({ [11083] = 3 }, true)
        de({ [11082] = 1 }, false)
        de({ [11083] = 2 }, false, 35)
        local r = Ledger.Results(state)
        assert.are.same({ 2, 2, 2 }, { r["2:a:30"].on.n, r["2:a:30"].on.mats[11083].hits, r["2:a:30"].on.mats[11083].qty[3] })
        assert.are.same({ 1, 1 }, { r["2:a:30"].off.n, r["2:a:30"].off.mats[11082].qty[1] })
        assert.are.equal(1, r["2:a:35"].off.n)
    end)
end)

describe("Time to sell", function()
    local ns, Ledger, Model, state, posted
    local DUST, ESS = 11083, 11082
    local H = 3600

    before_each(function()
        ns = helper.load()
        Ledger, Model = ns.Ledger, ns.Model
        state = Ledger.Init({})
        posted = {}
    end)

    local function post(id, each, t) posted[#posted + 1] = { itemID = id, each = each, qty = 20, t = t } end

    it("measures from the post to the sale: the sale at its money's due time less the mail delay", function()
        post(DUST, 400, 1000)
        post(DUST, 401, 1000)
        -- Seen sold at 1000 + 2 h, money due an hour after it sold at 1000 + 30 min: 30 min to sell.
        local s = Ledger.SaleSeen(state, DUST, 5, 400, 0.05, 1000 + 2 * H)
        s.due = 1000 + 30 * 60 + Ledger.MAIL_DELAY
        -- From its mail only: at the time it was booked, 3 h after the post.
        Ledger.SalePaid(state, DUST, 1, 401, 20, 1000 + 3 * H)
        local t = Ledger.TimesToSell(state, posted, 1000 + 4 * H)
        assert.are.equal(2, t[DUST].n)
        assert.are.equal(30 * 60, t[DUST].measured)                 -- the median by units: 5 of 6 at 30 min
        assert.is_true(t[DUST].few)
        -- A sale of a post it knows (postedAt) takes that post, whatever the price.
        local x = Ledger.SaleSeen(state, ESS, 1, 999, 0.05, 1000 + 5 * H)
        x.postedAt = 1000 + 4 * H
        t = Ledger.TimesToSell(state, posted, 1000 + 6 * H)
        assert.are.equal(H, t[ESS].measured)
        -- A sale with no post found does not count.
        Ledger.SaleSeen(state, ESS, 1, 123, 0.05, 1000 + 5 * H)
        assert.are.equal(1, Ledger.TimesToSell(state, posted, 1000 + 6 * H)[ESS].n)
    end)

    it("pulls a material with few sales toward all materials; ignores lost deposits and old sales", function()
        for i = 1, 5 do
            post(DUST, 400 + i, i * 10 * H)
            Ledger.SaleSeen(state, DUST, 1, 400 + i, 0.05, i * 10 * H + 10 * 60)   -- 10 min each
        end
        post(ESS, 1700, 100 * H)
        Ledger.SaleSeen(state, ESS, 1, 1700, 0.05, 100 * H + 70 * 60)             -- 70 min, one sale
        Ledger.DepositLost(state, ESS, 3, 30, "expired", 101 * H)
        local t = Ledger.TimesToSell(state, posted, 102 * H)
        -- Five sales two to four days old: they weigh a little under 5 (SDD 118), so still "few".
        assert.are.same({ 600, 5, true }, { t[DUST].seconds, t[DUST].count, t[DUST].few })
        assert.is_true(t[DUST].n > 4.7 and t[DUST].n < 5)
        -- All: median of six sales (five at 10 min) = 10 min; the essence: (1 × 70 + 4 × 10) / 5 = 22 min.
        assert.are.equal(600, t.all.seconds)
        assert.are.equal((70 * 60 + 4 * 600) / 5, t[ESS].seconds)
        assert.are.equal(1, t[ESS].n)
        -- A month later the same sales count at about half their weight; nothing is left out.
        local later = Ledger.TimesToSell(state, posted, 102 * H + 30 * 86400)
        assert.are.equal(600, later.all.seconds)
        assert.is_true(math.abs(later[ESS].n - 0.5) < 1e-9)
    end)

    it("turns the time to sell of a band's materials into Return per day", function()
        local times = { [DUST] = { 2 * 86400, false }, [ESS] = { 6 * 86400, true } }
        local function timeOf(id) local x = times[id] if x then return x[1], x[2] end end
        -- Dust is 3/4 of the value, the essence 1/4: 3 days.
        local days, few, secs = Model.DaysToSell({ { id = DUST, value = 300 }, { id = ESS, value = 100 } }, timeOf)
        assert.are.same({ 3, true, 3 * 86400 }, { days, few, secs })
        assert.is_true(math.abs(Model.ReturnPerDay(300, 1000, days) - 0.1) < 1e-12)
        -- Minutes count as one day: Return per day is the Return.
        times[DUST], times[ESS] = { 120, false }, { 60, false }
        days, few, secs = Model.DaysToSell({ { id = DUST, value = 300 }, { id = ESS, value = 100 } }, timeOf)
        assert.are.same({ 1, false, 105 }, { days, few, secs })
        assert.are.equal(0.3, Model.ReturnPerDay(300, 1000, days))
        -- No time known: nothing.
        assert.is_nil(Model.DaysToSell({ { id = 1, value = 5 } }, timeOf))
        assert.is_nil(Model.ReturnPerDay(300, 1000, nil))
    end)
end)

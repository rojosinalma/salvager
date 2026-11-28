local helper = require("spec.helper")
local wow = require("spec.wow")

-- The archive (SDD 126): records older than 30 days rolled up per day, band, Salvager state and item, every total the
-- reports read kept to the copper, the learning within rounding, the Current batch's part in the head; and the books'
-- check (SDD 125) on data shaped like the user's.

local DUST, SHARD, ESS, VISION = 11083, 11082, 11134, 11137
local prices = { [DUST] = 430, [SHARD] = 1300, [ESS] = 600, [VISION] = 840 }
local function priceOf(id) return prices[id] end
local DAY = 86400
local T0 = 1800000000 - 1800000000 % DAY   -- a day's start (UTC)

-- `days` of trading: each day disenchants of two items in two bands, with and without the Salvager, part of them
-- with no known cost; posts and sales of what they gave, some sold another way, deposits lost, sales while away.
local function trade(Ledger, state, posted, days, perDay)
    for day = 0, days - 1 do
        local base = T0 + day * DAY
        for i = 1, perDay do
            local t = base + i * 600
            local item = 4000 + i % 2
            local band = i % 2 == 0 and 30 or 35
            local got = i % 3 == 0 and { [SHARD] = 1, [DUST] = 1 + i % 2 } or { [DUST] = 1 + i % 3 }
            if i % 5 == 0 then got = { [ESS] = 1 + day % 2 } end
            local known = i % 4 ~= 0
            if known then Ledger.AddPurchase(state, item, 1, 1000 + i * 13 + day, 1400 + i, t - 300, "[Gear " .. item .. "]") end
            Ledger.Disenchant(state, { t = t, link = "[Gear " .. item .. "]", itemID = item, ilvl = band - 2, quality = 2,
                classID = i % 3 == 0 and 2 or 4, band = band, salvager = i % 2 == 1, got = got, planned = 1500 + i },
                known and Ledger.TakePurchase(state, item) or nil, priceOf, 0.05)
        end
        for k, id in ipairs({ DUST, SHARD, ESS }) do
            local t = base + 40000 + k * 60
            posted[#posted + 1] = { auctionID = day * 10 + k, itemID = id, qty = 3, each = prices[id], t = t,
                deposit = 12, val = prices[id] * (1 + k / 100) }
            local s = Ledger.SaleSeen(state, id, 2, prices[id] + day % 3, 0.05, t + 600 + k * 37 + day)
            s.val = prices[id]
            Ledger.SalePaid(state, id, 2, 2 * (prices[id] + day % 3), math.floor(2 * (prices[id] + day % 3) * 0.05 + 0.5),
                t + 4000, k == 1 and 25 or nil)
        end
        local away = Ledger.Sell(state, VISION, 1, 900, 45, base + 50000)   -- (no stock: untracked)
        away.away, away.paidAt = true, base + 50000
        Ledger.DepositLost(state, DUST, 5, 30 + day, "expired", base + 60000)
    end
end

local function valueAt(s) return s.val or prices[s.id] end

-- Everything the reports read, as numbers (Profits with and without a time, Accuracy, Report, Breakdown, the totals).
local function totals(ns, state, from)
    local Ledger = ns.Ledger
    local out = {}
    local function put(prefix, t)
        for k, v in pairs(t) do
            -- (Sold values are averages: their sums to a millionth of a copper, whatever the order they were added.)
            if type(v) == "number" then out[prefix .. "." .. k] = math.floor(v * 1e6 + 0.5) / 1e6 end
        end
    end
    for _, range in ipairs({ { "all" }, { "from", from }, { "to", nil, from - 1 } }) do
        local p = Ledger.Profits(state, range[2], nil, range[3])
        put(range[1] .. ".total", p.total)
        for _, g in ipairs(p.groups) do
            put(range[1] .. ".g" .. g.quality .. g.classID, g)
            for _, b in ipairs(g.bands) do put(range[1] .. ".b" .. g.quality .. g.classID .. b.band, b) end
        end
        for _, it in ipairs(p.items) do put(range[1] .. ".i" .. tostring(it.itemID), it) end
        for _, m in ipairs(p.mats) do put(range[1] .. ".m" .. m.id, m) end
    end
    local salv = Ledger.Profits(state, nil, function(r) return r.salvager end)
    put("salvager", salv.total)
    local acc = Ledger.Accuracy(state)
    put("acc", acc.total)
    for _, b in ipairs(acc.bands) do put("accb" .. b.classID .. b.band, b) end
    for _, m in ipairs(acc.mats) do put("accm" .. m.id, m) end
    for key, b in pairs(Ledger.Report(state)) do
        put("rep" .. key, b)
        for id, m in pairs(b.mats) do put("rep" .. key .. "m" .. id, m) end
    end
    for key, b in pairs(Ledger.Report(state, from)) do put("repfrom" .. key, b) end
    for _, id in ipairs({ DUST, SHARD, ESS }) do
        local bd = Ledger.Breakdown(state, id)
        put("bd" .. id, bd)
        for _, s in ipairs(bd.items) do put("bd" .. id .. "i" .. tostring(s.itemID), s) end
        for _, s in ipairs(bd.bands) do put("bd" .. id .. "b" .. s.classID .. s.band, s) end
    end
    put("books", Ledger.Books(state))
    local n, paid = 0, 0
    for _, e in ipairs(Ledger.HistoryTotals(state)) do
        if e.done then n, paid = n + (e.n or 1), paid + (e.paid or 0) end
    end
    out["history.n"], out["history.paid"] = n, paid
    return out
end

-- The learning, as numbers.
local function learned(ns, state, posted, now)
    local Ledger = ns.Ledger
    local out = {}
    for key, b in pairs(Ledger.Results(state, now)) do
        for _, side in ipairs({ "on", "off" }) do
            out[key .. side .. ".n"], out[key .. side .. ".count"] = b[side].n, b[side].count
            for id, m in pairs(b[side].mats) do
                out[key .. side .. id .. ".hits"] = m.hits
                for q, w in pairs(m.qty) do out[key .. side .. id .. ".q" .. q] = w end
            end
        end
    end
    for _, side in ipairs({ "on", "off" }) do
        for kind, k in pairs(Ledger.Shapes(state, now)[side]) do
            out["shape" .. side .. kind .. ".n"], out["shape" .. side .. kind .. ".count"] = k.n, k.count
        end
    end
    for id, x in pairs(Ledger.SellRatios(state, valueAt, now)) do
        out["ratio" .. id], out["ratio" .. id .. ".n"], out["ratio" .. id .. ".count"] = x.ratio, x.n, x.count
    end
    for id, x in pairs(Ledger.DepositRates(state, function() return 4 end, now)) do
        out["dep" .. id], out["dep" .. id .. ".n"] = x.k, x.n
    end
    for id, x in pairs(Ledger.TimesToSell(state, posted, now)) do
        out["time" .. id], out["time" .. id .. ".n"], out["time" .. id .. ".count"] = x.seconds, x.n, x.count
    end
    return out
end

describe("The archive", function()
    local ns, Ledger
    before_each(function()
        ns = helper.load()
        Ledger = ns.Ledger
    end)

    it("keeps every total the reports read to the copper, rolled up per day, then per 30 days and band", function()
        local state, posted = Ledger.Init({}), {}
        trade(Ledger, state, posted, 50, 24)
        local now = T0 + 50 * DAY
        local from = T0 + 10 * DAY   -- (a day's start: the rolled-up days are on one side of it)
        local before = totals(ns, state, from)
        local r = Ledger.Archive(state, now, { posted = posted, valueAt = valueAt })
        assert.are.same({ 20 * 24, 20 * 5 }, { r.disenchants, r.sales })
        assert.are.equal(20 * 3, r.posts)
        assert.are.equal(30 * 24, #state.disenchants)
        assert.is_true(#state.archive.d < r.disenchants / 2)
        assert.are.same(before, totals(ns, state, from))
        assert.are.equal(0, Ledger.Books(state).off)
        -- 40 days later the first days go per 30 days and band (`from` is then inside a period: the all-time ones).
        local r2 = Ledger.Archive(state, now + 60 * DAY, { posted = posted, valueAt = valueAt })
        assert.is_true(r2.merged > 0)
        local after = totals(ns, state, from)
        for k, v in pairs(before) do
            if k:match("^all%.[tgbm]") or k:match("^acc") or k:match("^rep[^f]") or k:match("^bd%d+%.") or k:match("^books")
                or k:match("^history") or k:match("^salvager") then
                assert.are.equal(v, after[k], k)
            end
        end
    end)

    it("keeps the learning within rounding: weights within 1.2 %, ratios to 0.001, times to their step", function()
        local state, posted = Ledger.Init({}), {}
        trade(Ledger, state, posted, 50, 24)
        local now = T0 + 50 * DAY + 3600
        local before = learned(ns, state, posted, now)
        Ledger.Archive(state, now, { posted = posted, valueAt = valueAt })
        local after = learned(ns, state, posted, now)
        for k, v in pairs(before) do
            local w = after[k]
            assert.is_number(w, k)
            if k:match("%.count$") then
                assert.are.equal(v, w, k)
            elseif k:match("^ratio%d+$") then
                assert.is_true(math.abs(v - w) <= 0.001, k .. " " .. v .. " " .. w)
            elseif k:match("^time%d+$") then
                assert.is_true(math.abs(v - w) <= 5, k .. " " .. v .. " " .. w)   -- (10 s steps from 10 minutes)
            else
                assert.is_true(math.abs(v - w) <= 0.012 * math.abs(v) + 1e-9, k .. " " .. v .. " " .. w)
            end
        end
        -- Merged per 30 days and band, the weights stay as close.
        local later = now + 70 * DAY
        local b1 = learned(ns, state, posted, later)
        Ledger.Archive(state, later, { posted = posted, valueAt = valueAt })
        local b2 = learned(ns, state, posted, later)
        for k, v in pairs(b1) do
            if k:match("%.n$") or k:match("%.hits$") then
                assert.is_true(math.abs(v - b2[k]) <= 0.012 * math.abs(v) + 1e-9, k)
            end
        end
    end)

    it("frees posted units in the Current batch with thousands of posts, and keeps the batch when it rolls up early",
        function()
        local state, posted = Ledger.Init({}), {}
        -- 1500 disenchants, each one's dust posted an hour later: nothing left in the batch.
        for i = 1, 1500 do
            local t = T0 + i * 60
            Ledger.AddPurchase(state, 4000, 1, 1000, 1400, t - 30)
            Ledger.Disenchant(state, { t = t, itemID = 4000, quality = 2, classID = 4, band = 30, got = { [DUST] = 2 } },
                Ledger.TakePurchase(state, 4000), priceOf, 0.05)
            posted[#posted + 1] = { itemID = DUST, qty = 2, each = 430, t = t + 3600 }
        end
        assert.are.equal(1500, #posted)
        assert.are.equal(0, #Ledger.Batch(state, posted).done)
        -- 100 more not posted yet, then a roll-up of all but the newest 1000 records of each kind: the same batch.
        for i = 1501, 1600 do
            Ledger.Disenchant(state, { t = T0 + 1500 * 60 + 7200 + i, itemID = 4000, quality = 2, classID = 4, band = 30,
                got = { [DUST] = 1 } }, nil, priceOf, 0.05)
        end
        posted[#posted + 1] = { itemID = DUST, qty = 30, each = 430, t = T0 + 1500 * 60 + 9000 }
        local function batch()
            local out = {}
            for _, d in ipairs(Ledger.Batch(state, posted).done) do out[d.rec.t] = d.units end
            return out
        end
        local before = batch()
        Ledger.MAX_FULL = 1000
        local r = Ledger.Archive(state, T0 + 2 * DAY, { posted = posted, valueAt = valueAt })
        assert.is_true(r.early)
        assert.is_true(r.disenchants > 0 and r.posts > 0)
        assert.are.same(before, batch())
        assert.is_true(#posted <= 1000)
    end)

    it("stays bounded: the same day after day keeps the same size once a year has passed", function()
        Ledger.FULL_DAYS, Ledger.DAY_DAYS, Ledger.PERIOD_KEEP = 5, 10, 60
        local state, posted = Ledger.Init({}), {}
        local sizes = {}
        for day = 0, 130 do
            local base = T0 + day * DAY
            for i = 1, 6 do
                Ledger.Disenchant(state, { t = base + i * 600, itemID = 4000 + i % 3, link = "[Gear]", quality = 2,
                    classID = 4, band = 30 + 5 * (i % 2), salvager = i % 2 == 0, got = { [DUST] = 1 + i % 2 } }, nil,
                    priceOf, 0.05)
            end
            posted[#posted + 1] = { itemID = DUST, qty = 6, each = 430, t = base + 40000 }
            Ledger.Sell(state, DUST, 6, 2580, 129, base + 50000)
            Ledger.Archive(state, base + DAY, { posted = posted, valueAt = valueAt })
            sizes[day] = ns.Util.SavedSize(state) + ns.Util.SavedSize(posted)
        end
        assert.is_true(sizes[130] <= sizes[100] * 1.02, sizes[100] .. " " .. sizes[130])
        assert.is_true(#state.disenchants <= 6 * 6 and #posted <= 6)
    end)

    it("rolls up at load and drops the old posts with a Log line", function()
        local env = wow.install()
        local ns0 = helper.load()
        local state, posted = ns0.Ledger.Init({}), {}
        local saved = { T0 = T0 }
        T0 = env.clock - 45 * DAY
        trade(ns0.Ledger, state, posted, 3, 4)
        T0 = saved.T0
        _G.SalvagerDB = { ledger = state, posted = posted }
        local ns1 = wow.loadAddon()
        wow.fire(ns1, "ADDON_LOADED", "Salvager")
        assert.are.equal(0, #ns1.db.ledger.disenchants)
        assert.are.equal(0, #ns1.db.posted)
        local found
        for _, line in ipairs(ns1.LogLines()) do
            if line:find("rolled up 12 disenchants and 15 sales", 1, true) then found = line end
        end
        assert.is_truthy(found)
        assert.is_truthy(found:find("9 posts from then dropped", 1, true))
        assert.are.equal(0, ns1.Ledger.Books(ns1.db.ledger).off)
    end)
end)

describe("The books' check", function()
    local ns, Ledger
    before_each(function()
        ns = helper.load()
        Ledger = ns.Ledger
    end)

    it("holds to the copper through every flow of the user's data: opening stock, the 0.3.120 replay, conversions, "
        .. "untracked sales, the purchases restored, Clear history and the archive", function()
        -- A ledger from before 0.3.120 (each item's price split over its own disenchant), with units of known cost
        -- that no record explains: 4 Vision Dust from before the records, 5 dust set by hand.
        local old = Ledger.Init({
            disenchants = {
                { t = T0 + 1, itemID = 77, quality = 2, classID = 4, band = 30, cost = 1100, costKnown = true,
                    got = { [DUST] = 3 }, vals = { [DUST] = 1290 }, shares = { [DUST] = 1100 } },
                { t = T0 + 2, itemID = 77, quality = 2, classID = 4, band = 30, cost = 1300, costKnown = true,
                    got = { [VISION] = 2 }, vals = { [VISION] = 1680 }, shares = { [VISION] = 1300 } },
            },
            sales = {
                -- 6 Vision Dust sold: 2 from the disenchant, 4 from before the records (at their old cost, 650 each).
                { t = T0 + 3, id = VISION, count = 6, gross = 5040, cut = 252, net = 4788, cost = 3900, untracked = 0,
                    profit = 888 },
                -- 2 more of no known cost at all.
                { t = T0 + 4, id = VISION, count = 2, gross = 1680, cut = 84, net = 1596, cost = 0, untracked = 2,
                    profit = 0, netUntracked = 1596 },
            },
            stock = { [DUST] = { qty = 8, cost = 1100 + 250, unknown = 0 } },
        })
        local before = Ledger.Booked(old)
        local _, _, unplaced = Ledger.Recost(old)
        assert.are.same({ 0, before }, { unplaced, Ledger.Booked(old) })   -- the replay keeps the books
        -- What no record explains carries what it carried: the 4 Vision Dust's 2600 and the dust's 250.
        local opened = Ledger.OpenBooks(old)
        assert.are.equal(2600 + 250, opened)
        assert.is_nil(Ledger.OpenBooks(old))
        local function check() assert.are.equal(0, Ledger.Books(old).off) end
        check()
        -- Opening stock by hand, a conversion, an untracked sale, a lost deposit.
        Ledger.SetStock(old, ESS, 6, 210)
        check()
        Ledger.Convert(old, ESS, 3, ESS + 1, 1)
        check()
        Ledger.Sell(old, VISION, 1, 900, 45, T0 + 5)
        Ledger.DepositLost(old, DUST, 2, 20, "expired", T0 + 6)
        Ledger.Sell(old, DUST, 5, 2150, 108, T0 + 7)
        check()
        -- New trading and the purchases the old bound dropped, restored.
        local posted = {}
        trade(Ledger, old, posted, 3, 12)
        check()
        for i = 1, 60 do Ledger.AuctionPurchase(old, 4251, 1100, 1500, T0 + 5 * DAY + i, "[Hillman's]") end
        while #old.purchases[4251] > 50 do table.remove(old.purchases[4251], 1) end
        for i = 1, 60 do
            Ledger.Disenchant(old, { t = T0 + 5 * DAY + 100 + i, itemID = 4251, quality = 2, classID = 4, band = 25,
                got = { [DUST] = 2 } }, Ledger.TakePurchase(old, 4251), priceOf, 0.05)
        end
        Ledger.Sell(old, DUST, 150, 150 * 430, 3225, T0 + 5 * DAY + 500)
        check()
        assert.are.equal(10, Ledger.RestorePurchases(old, T0 + 5 * DAY + 1000).restored)
        check()
        -- The archive, then Clear history.
        Ledger.Archive(old, T0 + 40 * DAY, { posted = posted, valueAt = valueAt })
        assert.is_true(#old.archive.d > 0)
        check()
        Ledger.ClearHistory(old)
        check()
        assert.are.equal(Ledger.Booked(old), old.other)
    end)

    it("repairs once what the 0.3.120 replay booked on units no record explains, from the backup before it", function()
        local backup = {
            disenchants = { { t = 1, itemID = 77, quality = 2, classID = 4, band = 30, cost = 1300, costKnown = true,
                got = { [VISION] = 2 }, vals = { [VISION] = 1680 }, shares = { [VISION] = 1300 } } },
            sales = { { t = 3, id = VISION, count = 6, gross = 5040, cut = 252, net = 4788, cost = 3900, untracked = 0,
                profit = 888 } },
            stock = {},
        }
        -- The sale's 6 units cost 4200 before the replay: 2 from the disenchant, 4 from before the records (2900).
        backup.sales[1].cost = 4200
        -- What 0.3.120 made of it: the 2 from the pool (1300), the 4 at the sale's old average (4200 * 4 / 6 = 2800):
        -- 100 copper lost from the books.
        local live = Ledger.Init(ns.Util.Copy(backup))
        live.jointCost = Ledger.JOINT_COST
        live.sales[1].cost = 1300 + 2800
        local n, moved, missed = Ledger.FixRecost(live, backup)
        assert.are.same({ 1, 100, 0 }, { n, moved, missed })
        assert.are.equal(4200, live.sales[1].cost)                  -- the books as before the replay
        -- Once: the second time the sale no longer looks as that replay left it.
        assert.are.same({ 0, 0, 1 }, { Ledger.FixRecost(live, backup) })
    end)
end)

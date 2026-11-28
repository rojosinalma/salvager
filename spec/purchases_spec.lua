local helper = require("spec.helper")
local wow = require("spec.wow")

-- Purchases: no bound drops one without a word, and the purchases the old bound of 50 per item dropped are rebuilt
-- once from the auction house record (SDD 124).

local ITEM, DUST, SHARD = 4251, 11083, 11082
local prices = { [DUST] = 300, [SHARD] = 1300 }
local function priceOf(id) return prices[id] end

-- What disenchant k gives (varied, so the shares per value are not trivial).
local function got(k)
    if k % 3 == 0 then return { [DUST] = 2, [SHARD] = 1 } end
    return { [DUST] = 1 + k % 2 }
end

local function disenchant(Ledger, state, k, t)
    return Ledger.Disenchant(state, { t = t, itemID = ITEM, link = "[Hillman's Shoulders]", quality = 2, classID = 4,
        band = 30, got = got(k) }, Ledger.TakePurchase(state, ITEM), priceOf, 0.05)
end

-- Everything paid is in a booked sale, on a unit not sold yet, or on gear not disenchanted yet, to the copper.
local function totals(state)
    local paid, waiting, booked, held, profit = 0, 0, 0, 0, 0
    for _, r in ipairs(state.disenchants) do if r.costKnown then paid = paid + r.cost end end
    for _, list in pairs(state.purchases) do for _, p in ipairs(list) do waiting = waiting + p.each end end
    for _, s in ipairs(state.sales) do booked, profit = booked + (s.cost or 0), profit + (s.profit or 0) end
    for _, s in pairs(state.stock) do held = held + s.cost end
    return { paid = paid, waiting = waiting, booked = booked, held = held, profit = profit }
end
local function conserved(state)
    local x = totals(state)
    assert.are.equal(x.paid + x.waiting, x.booked + x.held + x.waiting)
end

describe("Purchases of one item", function()
    local ns, Ledger, state, drops
    before_each(function()
        ns = helper.load()
        Ledger = ns.Ledger
        state = Ledger.Init({})
        drops = {}
        ns.Util.OnDrop = function(what, n, max) drops[#drops + 1] = { what = what, n = n, max = max } end
    end)

    it("are all kept, 120 of them, and every disenchant gets its cost", function()
        local paid = 0
        for i = 1, 120 do
            Ledger.AuctionPurchase(state, ITEM, 1000 + i, 1500, i, "[Hillman's Shoulders]")
            paid = paid + 1000 + i
        end
        assert.are.equal(120, #state.purchases[ITEM])
        for k = 1, 120 do assert.are.equal(1000 + k, disenchant(Ledger, state, k, 1000 + k).cost) end
        for _, r in ipairs(state.disenchants) do assert.is_true(r.costKnown) end
        assert.are.equal(paid, totals(state).paid)
        assert.is_nil(state.purchases[ITEM])
        assert.are.same({}, drops)
        conserved(state)
    end)

    it("are bounded over all items at MAX_RECORDS, the oldest first, and the drop is reported", function()
        Ledger.MAX_RECORDS = 10
        for i = 1, 8 do Ledger.AddPurchase(state, ITEM, 1, 100, nil, 100 + i) end
        for i = 1, 4 do Ledger.AddPurchase(state, 77, 1, 100, nil, 104 + i) end
        local n = 0
        for _, list in pairs(state.purchases) do n = n + #list end
        assert.are.equal(10, n)
        assert.are.equal(103, state.purchases[ITEM][1].t)   -- the two oldest of all went
        assert.are.equal(4, #state.purchases[77])
        assert.are.same({ { what = "purchases not disenchanted", n = 1, max = 10 },
            { what = "purchases not disenchanted", n = 1, max = 10 } }, drops)
    end)
end)

describe("No bound drops records without a report", function()
    local MODULES = { "Ledger", "Journal", "Statement", "Competition", "Gold" }

    it("every cap in the books' modules says what it drops", function()
        for _, m in ipairs(MODULES) do
            local n = 0
            for line in io.lines("Salvager/" .. m .. ".lua") do
                local call = line:match("[%.%s]Cap%((.*)%)") or line:match("^%s*cap%((.*)%)")
                if call and not line:match("function") then
                    n = n + 1
                    assert.is_truthy(call:match(",.*,%s*\"[^\"]+\""), m .. ": a cap with no name: " .. line)
                end
            end
            assert.is_true(n > 0, m)
        end
    end)

    it("each bound reports its count", function()
        local ns = helper.load()
        local seen = {}
        ns.Util.OnDrop = function(what, n) seen[what] = (seen[what] or 0) + n end
        local Ledger, Journal, Statement, C = ns.Ledger, ns.Journal, ns.Statement, ns.Competition
        local L = Ledger.Init({})
        Ledger.MAX_RECORDS, Ledger.MAX_FULL = 3, 4
        for i = 1, 5 do
            Ledger.AuctionPurchase(L, 1, 10, nil, i)
            Ledger.Sell(L, DUST, 1, 10, 0, i)
            Ledger.Disenchant(L, { t = i, itemID = 1, got = { [DUST] = 1 } }, nil, priceOf, 0)
        end
        -- (Disenchants and sales are not dropped: they are rolled up, SDD 126.)
        assert.are.same({ ["purchases not disenchanted"] = 2, ["auction-house purchases seen"] = 1 }, seen)
        assert.are.same({ 5, 5 }, { #L.disenchants, #L.sales })
        seen = {}
        Journal.MAX = 2
        local J = Journal.Init({})
        for i = 1, 4 do Journal.Seen(J, "A", i * 10, i) end
        local list = {}
        for i = 1, Journal.MAX_EXPECTED + 1 do Journal.Expect(list, { k = "buy", a = -i }, 0, 10) end
        Statement.MAX_SNAPS, Statement.MAX_SESSIONS = 1, 1
        local S = Statement.Init({})
        for i = 1, 3 do Statement.Login(S, "A" .. i, i, false, { v = 1, c = 1 }) end
        assert.are.same({ ["gold journal entries"] = 2, ["expected gold changes"] = 1, ["stock snapshots"] = 2,
            sessions = 1 }, seen)
        seen = {}
        C.MAX_LOSSES = 1
        local cs = C.Init({})
        C.Observe(cs, DUST, { { each = 90, qty = 1, owners = { "X" }, total = 1 } }, { { each = 100, qty = 1 } }, 1)
        for i = 1, 2 do C.NoteCancel(cs, { t = 2, id = DUST, auctionID = i, qty = 1, each = 100, fee = 5, deposit = 5 }) end
        assert.are.same({ ["profit-lost records"] = 1, ["cancels after an undercut"] = 1 }, seen)
    end)

    it("the addon logs a drop with its count, at most a line a minute per kind, the rest at logout", function()
        local env = wow.install()
        local ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        local function lines()
            local out = {}
            for _, l in ipairs(ns.LogLines()) do if l:find("bound:", 1, true) then out[#out + 1] = l:match("bound: .*") end end
            return out
        end
        ns.Util.Cap({ 1, 2, 3 }, 1, "test records")
        assert.are.same({ "bound: 2 oldest test records dropped (1 kept)" }, lines())
        ns.Util.Cap({ 1, 2, 3, 4 }, 1, "test records")   -- the same minute: counted
        assert.are.equal(1, #lines())
        env.clock = env.clock + 60
        ns.Util.Cap({ 1, 2 }, 1, "test records")
        assert.are.same("bound: 4 oldest test records dropped (1 kept)", lines()[2])
        ns.Util.Cap({ 1, 2 }, 1, "test records")
        wow.fire(ns, "PLAYER_LOGOUT")
        assert.are.same("bound: 1 oldest test records dropped (1 kept)", lines()[3])
    end)
end)

describe("The purchases the old bound of 50 per item dropped", function()
    local ns, Ledger
    local T0 = 1800000000

    -- 101 bought at the auction house (their mail taken), with what the old code kept: the newest 50. Then 107
    -- disenchants of the item: the first 50 took the 50 kept, 57 found none (51 dropped, 6 never bought). `sale(k)`
    -- (optional) sells after disenchant k. `price(i)`: what purchase i cost. `capped` false: the truth (no bound).
    local function history(capped, price, sale)
        local state = Ledger.Init({})
        for i = 1, 101 do
            Ledger.AuctionPurchase(state, ITEM, price(i), 1500, T0 + i * 10, "[Hillman's Shoulders]")
            assert.is_false(Ledger.MailPurchase(state, ITEM, 1, price(i), nil, T0 + 2000))
            local list = state.purchases[ITEM]
            while capped and #list > 50 do table.remove(list, 1) end
        end
        for k = 1, 107 do
            disenchant(Ledger, state, k, T0 + 3000 + k * 5)
            if sale then sale(state, k, T0 + 3000 + k * 5 + 1) end
        end
        return state
    end
    -- Sales after all the disenchants: dust and shards, part of the stock.
    local function sellAfter(state, k, t)
        if k == 107 then
            Ledger.Sell(state, DUST, 60, 60 * 300, 900, t)
            Ledger.Sell(state, SHARD, 20, 20 * 1300, 1300, t + 1)
        end
    end
    local function costs(state)
        local out = {}
        for i, r in ipairs(state.disenchants) do out[i] = r.costKnown and r.cost or false end
        return out
    end

    before_each(function()
        ns = helper.load()
        Ledger = ns.Ledger
    end)

    it("are restored exactly: each costless disenchant paid first in, first out, the books as with no bound", function()
        local function price(i) return 1000 + i * 7 end
        local state = history(true, price, sellAfter)
        local truth = history(false, price, sellAfter)
        local unknown = 0
        for _, r in ipairs(state.disenchants) do if not r.costKnown then unknown = unknown + 1 end end
        assert.are.equal(57, unknown)
        local before = totals(state)

        local r = Ledger.RestorePurchases(state, T0 + 4000)
        assert.are.same({ 51, 51, 0, 0, true }, { r.restored, r.costed, r.back, r.gone, r.replayed })
        assert.are.equal(1, #r.items)
        -- The 50 kept paid the first 50 (purchases 52..101); the 51 dropped (1..51) pay the next 51, oldest first;
        -- the last 6 were never bought.
        local c = costs(state)
        for k = 1, 50 do assert.are.equal(price(51 + k), c[k]) end
        for k = 51, 101 do
            assert.are.equal(price(k - 50), c[k])
            assert.is_true(state.disenchants[k].costRestored)
            assert.are.equal(T0 + (k - 50) * 10, state.disenchants[k].boughtAt)
        end
        for k = 102, 107 do assert.is_false(c[k]) end
        local cost = 0
        for i = 1, 51 do cost = cost + price(i) end
        assert.are.equal(cost, r.cost)
        -- The books: what the uncapped history booked, to the copper.
        local x, t = totals(state), totals(truth)
        assert.are.equal(t.paid, x.paid)
        assert.are.equal(before.paid + cost, x.paid)
        for id, s in pairs(truth.stock) do
            assert.are.same({ s.qty, s.unknown, s.cost }, { state.stock[id].qty, state.stock[id].unknown, state.stock[id].cost })
        end
        for i, s in ipairs(truth.sales) do
            assert.are.same({ s.cost, s.untracked, s.profit }, { state.sales[i].cost, state.sales[i].untracked,
                state.sales[i].profit })
        end
        assert.are.equal(t.profit, r.profitAfter)
        assert.are.equal(before.profit, r.profitBefore)
        assert.is_nil(state.purchases[ITEM])
        conserved(state)
    end)

    it("makes units sold as of no known cost known again, and books those sales as the uncapped history did", function()
        local function price() return 1100 end
        -- A sale in the costless run, of more dust than the known units then: part of it of no known cost.
        local function sale(state, k, t)
            if k == 70 then Ledger.Sell(state, DUST, 100, 100 * 300, 1500, t) end
            sellAfter(state, k, t)
        end
        local state = history(true, price, sale)
        local truth = history(false, price, sale)
        local was = 0
        for _, s in ipairs(state.sales) do was = was + s.untracked end
        assert.is_true(state.sales[1].untracked > 0)
        assert.are.equal(0, truth.sales[1].untracked)
        local r = Ledger.RestorePurchases(state, T0 + 4000)
        assert.are.same({ 51, 51, was, 0 }, { r.restored, r.costed, r.shifted, r.gone })
        for i, s in ipairs(truth.sales) do
            assert.are.same({ s.cost, s.untracked, s.profit, s.netUntracked },
                { state.sales[i].cost, state.sales[i].untracked, state.sales[i].profit, state.sales[i].netUntracked })
        end
        for id, s in pairs(truth.stock) do
            assert.are.same({ s.qty, s.unknown, s.cost }, { state.stock[id].qty, state.stock[id].unknown, state.stock[id].cost })
        end
        conserved(state)
    end)

    it("keeps the books balanced with prices that differ and sales between, puts the pieces left back, and runs once", function()
        local function price(i) return 900 + (i * 37) % 400 end
        local function sale(state, k, t)
            if k % 20 == 0 then Ledger.Sell(state, DUST, 30, 30 * 300, 450, t) end
        end
        local state = history(true, price, sale)
        -- Two of the costless disenchants never happened (the pieces are still in the bags): 2 purchases go back.
        table.remove(state.disenchants, 106)
        table.remove(state.disenchants, 105)
        -- (Their units out of stock again: they were of no known cost.)
        for _, k in ipairs({ 105, 106 }) do
            for id, qty in pairs(got(k)) do
                state.stock[id].qty, state.stock[id].unknown = state.stock[id].qty - qty, state.stock[id].unknown - qty
            end
        end
        local before = totals(state)
        local r = Ledger.RestorePurchases(state, T0 + 4000)
        assert.are.same({ 51, 51, 0 }, { r.restored, r.costed, r.back })
        local x = totals(state)
        assert.are.equal(before.paid + r.cost, x.paid)
        conserved(state)

        -- None of the dropped ones disenchanted yet (only the 50 that found a purchase): all 51 go back, oldest first.
        local s2 = history(true, price)
        for _ = 1, 57 do table.remove(s2.disenchants) end   -- only the 50 that found a purchase
        for id in pairs(s2.stock) do
            local known = 0
            for _, rec in ipairs(s2.disenchants) do known = known + (rec.got[id] or 0) end
            s2.stock[id].qty, s2.stock[id].unknown = known, 0
        end
        local r2 = Ledger.RestorePurchases(s2, T0 + 4000)
        assert.are.same({ 51, 0, 51 }, { r2.restored, r2.costed, r2.back })
        assert.are.equal(51, #s2.purchases[ITEM])
        assert.are.equal(T0 + 10, s2.purchases[ITEM][1].t)
        assert.are.equal(price(1), s2.purchases[ITEM][1].each)
        conserved(s2)

        -- Idempotent: nothing is left to restore, and a second run changes nothing.
        assert.are.same({}, Ledger.DroppedPurchases(state, T0 + 4000))
        local copy = ns.Util.Copy(state)
        assert.are.equal(0, Ledger.RestorePurchases(state, T0 + 4000).restored)
        assert.are.same(copy, state)
        -- Older than 30 days: not restored (Ledger.Expire would drop them anyway).
        local old = history(true, price)
        assert.are.same({}, Ledger.DroppedPurchases(old, T0 + 31 * 86400 + 4000))
        -- Items left out on purpose (ClearHistory's drop) are not brought back.
        assert.are.same({}, Ledger.DroppedPurchases(history(true, price), T0 + 4000, function(id) return id == ITEM end))
    end)
end)

describe("The one-time repair at load", function()
    it("runs after a backup with one log line, and never again", function()
        local env = wow.install()
        local ns0 = helper.load()
        local L = ns0.Ledger.Init({})
        local t0 = env.clock - 7200
        for i = 1, 60 do
            ns0.Ledger.AuctionPurchase(L, ITEM, 1000, 1500, t0 + i, "[Hillman's Shoulders]")
            L.bought[#L.bought].mail = true
            while #L.purchases[ITEM] > 50 do table.remove(L.purchases[ITEM], 1) end
        end
        for k = 1, 60 do
            ns0.Ledger.Disenchant(L, { t = t0 + 100 + k, itemID = ITEM, link = "[Hillman's Shoulders]", quality = 2,
                classID = 4, band = 30, got = got(k) }, ns0.Ledger.TakePurchase(L, ITEM), priceOf, 0.05)
        end
        _G.SalvagerDB = { ledger = L }
        local ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        local l = ns.db.ledger
        for _, r in ipairs(l.disenchants) do assert.is_true(r.costKnown) end
        assert.is_true(ns.db.purchasesRestored)
        assert.are.equal("before restoring the purchases the old bound dropped", ns.Backup.Last().reason)
        local found = {}
        for _, line in ipairs(ns.LogLines()) do if line:find("old bound of 50 per item", 1, true) then found[#found + 1] = line end end
        assert.are.equal(1, #found)
        assert.is_truthy(found[1]:find("10 purchases the old bound", 1, true))
        assert.is_truthy(found[1]:find("booked again once", 1, true))
        local backups = #ns.Backup.List()
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        assert.are.equal(backups, #ns.Backup.List())
    end)
end)

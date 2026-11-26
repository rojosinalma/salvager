local helper = require("spec.helper")

-- Accounting invariants over random runs of trading (a fixed seed, so a failure can be replayed): purchases,
-- disenchants with and without a known cost, posts and sales (seen sold, then paid by mail; or known from the mail
-- only; some while you were away), essences changing form, lost deposits, cancel fees, other gold, moving prices,
-- over several sessions.
describe("Accounting invariants", function()
    local ns, Ledger, Journal, Statement
    local DUST, LESSER, GREATER, SHARD = 11083, 10998, 11082, 11084
    local MATS = { DUST, LESSER, GREATER, SHARD }

    local function run(seed, sessions, steps)
        ns = helper.load()
        Ledger, Journal, Statement = ns.Ledger, ns.Journal, ns.Statement
        local L, J, S = Ledger.Init({}), Journal.Init({}), Statement.Init({})
        local prices = { [DUST] = 400, [LESSER] = 600, [GREATER] = 1700, [SHARD] = 5800 }
        local function priceOf(id) return prices[id] end
        local function stock() return Statement.StockValue(L, priceOf, { cut = 0.05 }) end
        local function rnd(n)
            seed = (seed * 1103515245 + 12345) % 2147483648
            return math.floor(seed / 65536) % n + 1   -- (the high bits: the low ones of this generator repeat soon)
        end
        local gold, t, item = 10000000, 1000, 5000
        local paidKnown = 0          -- what the disenchants with a recorded purchase cost
        local waiting = {}           -- items bought, not disenchanted yet: { itemID, cost }
        local unpaid = {}            -- sales seen sold whose mail is not taken yet, oldest first: { rec, deposit }
        local function gain(d, kind)
            gold = gold + d
            Journal.Seen(J, "A", gold, t, kind)
        end
        local function held(id) local s = L.stock[id] return s and s.qty or 0 end
        local function someMat()
            local list = {}
            for _, id in ipairs(MATS) do if held(id) > 0 then list[#list + 1] = id end end
            return list[1] and list[rnd(#list)]
        end
        local function hasUnpaid(id)
            for _, u in ipairs(unpaid) do if u.rec.id == id then return true end end
            return false
        end

        -- Everything paid for the known-cost disenchants is in a booked sale or on a unit not sold yet, to the copper.
        local function conserved()
            local booked, onUnits = 0, 0
            for _, s in ipairs(L.sales) do booked = booked + (s.cost or 0) end
            for _, s in pairs(L.stock) do onUnits = onUnits + s.cost end
            assert.are.equal(paidKnown, booked + onUnits)
        end

        -- Accuracy's total is the sum of its bands, field by field.
        local function accuracyAddsUp()
            local acc = Ledger.Accuracy(L)
            for _, field in ipairs({ "n", "paid", "promised", "got", "sold", "units", "soldUnits" }) do
                local sum = 0
                for _, b in ipairs(acc.bands) do sum = sum + b[field] end
                assert.is_true(math.abs(sum - acc.total[field]) < 1e-6, field .. ": " .. sum .. " ~= " .. acc.total[field])
            end
        end

        local spans, did = {}, { convert = 0, away = 0, unknown = 0, lost = 0, seen = 0, mailOnly = 0 }
        Journal.Seen(J, "A", gold, t)
        for _ = 1, sessions do
            t = t + 1000
            local start = t
            Statement.Login(S, "A", start, false, stock())
            for _ = 1, steps do
                t = t + 10
                local roll = rnd(20)
                if roll <= 4 then                                              -- buy one item
                    item = item + 1
                    local cost = rnd(3000) + 100
                    Ledger.AddPurchase(L, item, 1, cost, cost + rnd(800) - 300, t)
                    waiting[#waiting + 1] = { itemID = item, cost = cost }
                    gain(-cost, "buy")
                elseif roll <= 8 then                                          -- disenchant
                    local got = { [MATS[rnd(4)]] = rnd(4) }
                    local w = table.remove(waiting, 1)
                    local purchase = w and rnd(6) > 1 and Ledger.TakePurchase(L, w.itemID)
                    if w and not purchase then table.insert(waiting, 1, w) end
                    if purchase then paidKnown = paidKnown + w.cost else did.unknown = did.unknown + 1 end
                    Ledger.Disenchant(L, { t = t, itemID = purchase and w.itemID or 1, quality = 2, classID = 4,
                        band = 20 + 5 * rnd(3), got = got, planned = rnd(2000), salvager = rnd(2) == 1 },
                        purchase or nil, priceOf, 0.05)
                elseif roll <= 11 then                                         -- post, and it sells
                    local id = someMat()
                    if id then
                        local deposit = rnd(60)
                        gain(-deposit, "deposit")
                        t = t + 1
                        local rec = Ledger.SaleSeen(L, id, rnd(held(id)), prices[id] + rnd(50), 0.05, t)
                        rec.away = rnd(4) == 1                                 -- (sold before this session)
                        if rec.away then did.away = did.away + 1 end
                        unpaid[#unpaid + 1] = { rec = rec, deposit = deposit }
                        did.seen = did.seen + 1
                    end
                elseif roll <= 13 then                                         -- the oldest sale's mail, deposit back
                    local u = table.remove(unpaid, 1)
                    if u then
                        Ledger.SalePaid(L, u.rec.id, u.rec.count, u.rec.gross, u.rec.cut, t, u.deposit)
                        gain(u.rec.gross - u.rec.cut + u.deposit, "sale")
                    end
                elseif roll == 14 then                                         -- a sale known from its mail only
                    local id = someMat()
                    if id and not hasUnpaid(id) then
                        local n = rnd(held(id))
                        local gross = n * (prices[id] + rnd(50))
                        local cut = math.floor(gross * 0.05 + 0.5)
                        local rec = Ledger.SalePaid(L, id, n, gross, cut, t)
                        rec.away = rnd(2) == 1                                 -- sold while you were away
                        if rec.away then did.away = did.away + 1 end
                        did.mailOnly = did.mailOnly + 1
                        gain(gross - cut, "sale")
                    end
                elseif roll == 15 then                                         -- lesser essences into greater ones
                    local n = math.floor(held(LESSER) / 3)
                    if n > 0 then
                        Ledger.Convert(L, LESSER, 3 * n, GREATER, n)
                        did.convert = did.convert + 1
                    end
                elseif roll == 16 then                                         -- a post that expires: its deposit is lost
                    local id = someMat()
                    if id then
                        local deposit = rnd(40)
                        gain(-deposit, "deposit")
                        t = t + 1
                        Ledger.DepositLost(L, id, 1, deposit, "expired", t)
                        did.lost = did.lost + 1
                    end
                elseif roll == 17 then
                    gain(-rnd(30), "cancel")                                   -- a cancel fee
                elseif roll == 18 then
                    gain(-rnd(500), "repair")                                  -- gold not from trading
                else
                    prices[MATS[rnd(4)]] = rnd(8000)                           -- the market moves
                end
                Statement.Touch(S, t)
                conserved()
                accuracyAddsUp()
            end
            t = t + 10
            Statement.Leave(S, t, stock())
            spans[#spans + 1] = { from = start, to = t }
        end
        return { L = L, J = J, S = S, spans = spans, now = t, stockNow = stock(), did = did }
    end

    local function compute(r, from, to)
        return Statement.Compute({ ledger = r.L, journal = r.J, char = "A", from = from, to = to, now = r.now,
            snaps = r.S.snaps, stockNow = r.stockNow })
    end

    -- Trading profit + sold while you were away + stock change = Total; every change of gold is explained.
    local function holds(st)
        assert.are.equal(st.trading + st.away.profit + (st.stock and st.stock.change or 0), st.total)
        assert.are.equal(st.sales - st.cost - st.depositsLost + st.cancel, st.trading)
        assert.are.equal(0, st.check.missing)
        assert.is_true(st.check.ok)
    end

    for _, seed in ipairs({ 7, 42, 2026 }) do
        it("keeps every copper and adds sessions up to the whole time (seed " .. seed .. ")", function()
            local r = run(seed, 6, 120)
            for what, n in pairs(r.did) do assert.is_true(n > 0, what .. " never happened") end
            local whole = compute(r, r.spans[1].from, r.now)
            holds(whole)
            local sum = { trading = 0, total = 0, sales = 0, cost = 0, depositsLost = 0, cancel = 0, away = 0, stock = 0,
                change = 0, otherSum = 0 }
            for _, span in ipairs(r.spans) do
                local st = compute(r, span.from, span.to)
                holds(st)
                sum.trading, sum.total = sum.trading + st.trading, sum.total + st.total
                sum.sales, sum.cost = sum.sales + st.sales, sum.cost + st.cost
                sum.depositsLost, sum.cancel = sum.depositsLost + st.depositsLost, sum.cancel + st.cancel
                sum.away, sum.stock = sum.away + st.away.profit, sum.stock + st.stock.change
                sum.change, sum.otherSum = sum.change + st.check.change, sum.otherSum + st.otherSum
            end
            assert.are.same({ whole.trading, whole.total, whole.sales, whole.cost, whole.depositsLost, whole.cancel,
                whole.away.profit, whole.stock.change, whole.check.change, whole.otherSum },
                { sum.trading, sum.total, sum.sales, sum.cost, sum.depositsLost, sum.cancel, sum.away, sum.stock,
                    sum.change, sum.otherSum })
            -- The whole time starts with no stock: its total is the trading, the away sales and what is held now.
            assert.are.equal(0, whole.stock.v0)
        end)
    end

    it("shows a gold change with no record as Not explained, and only that", function()
        local r = run(99, 2, 40)
        local whole = compute(r, r.spans[1].from, r.now)
        assert.are.equal(0, whole.check.missing)
        -- 7s 77c come in with nothing booked for them, counted as a sale's mail.
        local last = r.J.chars.A.b
        Journal.Seen(r.J, "A", last + 777, r.now, "sale")
        assert.are.equal(777, compute(r, r.spans[1].from, r.now).check.missing)
        assert.are.equal(777, compute(r, r.spans[2].from, r.spans[2].to).check.missing)
        assert.are.equal(0, compute(r, r.spans[1].from, r.spans[1].to).check.missing)
    end)
end)

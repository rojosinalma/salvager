local helper = require("spec.helper")

describe("Statement", function()
    local ns, L, J, S, Ledger, Journal, Statement
    local DUST = 11083
    local function priceOf(id) return id == DUST and 433 or nil end
    local function stock() return Statement.StockValue(L, priceOf, 0.05) end
    local function compute(from, to, now)
        return Statement.Compute({ ledger = L, journal = J, char = "A", from = from, to = to, now = now or to,
            snaps = S.snaps, stockNow = stock() })
    end

    before_each(function()
        ns = helper.load()
        Ledger, Journal, Statement = ns.Ledger, ns.Journal, ns.Statement
        L, J, S = Ledger.Init({}), Journal.Init({}), Statement.Init({})
    end)

    -- Login with 1g, buy one item for 5s, disenchant it into 3 dust, post (6c deposit), sell 2 (seen sold, then
    -- the mail with the deposit back), repair for 1s.
    local function session()
        Journal.Seen(J, "A", 10000, 100)
        Statement.Login(S, "A", 100, false, stock())
        Ledger.AddPurchase(L, 5001, 1, 500, 800, 110)
        Journal.Seen(J, "A", 9500, 110, "buy")
        Ledger.Disenchant(L, { t = 120, itemID = 5001, quality = 2, classID = 4, band = 30, got = { [DUST] = 3 } },
            Ledger.TakePurchase(L, 5001), priceOf, 0.05)
        Journal.Seen(J, "A", 9494, 130, "deposit")
        Ledger.SaleSeen(L, DUST, 2, 600, 0.05, 140)                 -- 1200, cut 60: 1140 after the cut
        Ledger.SalePaid(L, DUST, 2, 1200, 60, 150, 6)                -- the mail: 1140 and the deposit back
        Journal.Seen(J, "A", 10640, 150, "sale")
        Journal.Seen(J, "A", 10540, 160, "repair")
    end

    it("adds up: trading profit, stock change and total; the check explains every change", function()
        session()
        local st = compute(100, 200)
        assert.are.same({ 1140, 333, 0, 0, 807 }, { st.sales, st.cost, st.depositsLost, st.cancel, st.trading })
        -- One dust left: worth 433 x 0.95 = 411, cost 167. At the start: nothing.
        assert.are.same({ true, 0, 0, 411, 167, 244 }, { st.stock.known, st.stock.v0, st.stock.c0, st.stock.v1,
            st.stock.c1, st.stock.change })
        assert.are.equal(st.trading + st.away.profit + st.stock.change, st.total)
        assert.are.same({ { k = "repair", name = "Repairs", amount = -100, n = 1 } }, st.other)
        local c = st.check
        assert.are.same({ 10000, 0, 10540, 0, 540 }, { c.g0, c.m0, c.g1, c.m1, c.change })
        assert.are.same({ 1140, 6, -500, -6, -100 }, { c.sales, c.back, c.buy, c.deposit, c.other })
        assert.are.equal(0, c.missing)
        assert.is_true(c.ok)
    end)

    it("counts the money in the mail: a sale seen sold and not collected yet", function()
        session()
        local c = compute(100, 145, 200).check
        assert.are.same({ 9494, 1140, 634 }, { c.g1, c.m1, c.change })   -- (the stock: from the snapshots)
        assert.are.equal(0, c.missing)
        c = compute(146, 200).check                                       -- from just before the mail was taken
        assert.are.same({ 1140, 0, 0 }, { c.m0, c.sales, c.missing })
    end)

    it("shows a missing record as Not explained", function()
        session()
        Journal.Seen(J, "A", 10840, 170, "sale")                          -- money with no sale in the ledger
        local c = compute(100, 200).check
        assert.are.equal(300, c.missing)
        assert.is_false(c.ok)
        Ledger.Sell(L, DUST, 1, 300, 0, 170)                              -- once booked, it is explained
        assert.are.equal(0, compute(100, 200).check.missing)
    end)

    it("values the stock at today's price, and the gear at its expected value", function()
        Ledger.SetStock(L, DUST, 10, 300)
        Ledger.AddPurchase(L, 5001, 1, 500, 800, 1)
        local v = stock()
        assert.are.same({ 4113, 3000, 800, 500, 4913, 3500 }, { v.mv, v.mc, v.gv, v.gc, v.v, v.c })
        Ledger.SetStock(L, 99999, 2, 50)                                  -- no price: at its cost
        assert.are.same({ 4213, 3100 }, { stock().mv, stock().mc })
    end)

    it("counts the stock change from its first record when the start is not known", function()
        Journal.Seen(J, "A", 10000, 100)
        Ledger.SetStock(L, DUST, 10, 300)
        Statement.Login(S, "A", 500, false, stock())
        Ledger.SaleSeen(L, DUST, 4, 450, 0.05, 600)                       -- 1710 after the cut, cost 1200
        local st = compute(100, 700)
        assert.is_false(st.stock.known)
        assert.are.equal(500, st.stock.since)
        assert.are.equal((2468 - 1800) - (4113 - 3000), st.stock.change)
        assert.are.equal(510 + st.stock.change, st.total)
        assert.is_nil(Statement.Compute({ ledger = L, journal = J, char = "A", from = 100, to = 400, now = 700,
            snaps = S.snaps }).stock)                                     -- no record at all in that time
    end)

    it("puts a sale made while you were away on its own line, not in the trading", function()
        Journal.Seen(J, "A", 10000, 100)
        Ledger.SetStock(L, DUST, 1, 300)
        Statement.Login(S, "A", 100, false, stock())
        local rec = Ledger.SalePaid(L, DUST, 1, 600, 30, 110)
        rec.away = true
        Journal.Seen(J, "A", 10570, 110, "sale")
        local st = compute(100, 200)
        assert.are.same({ 0, 0 }, { st.sales, st.trading })
        assert.are.same({ 1, 570, 300, 270 }, { st.away.n, st.away.net, st.away.cost, st.away.profit })
        assert.are.equal(-(411 - 300), st.stock.change)
        assert.are.equal(270 - 111, st.total)
        assert.are.equal(0, st.check.missing)                             -- its money is explained
    end)

    it("keeps a session over a reload, closes it at the next login, and at its last time when logout was not seen", function()
        local s, new = Statement.Login(S, "A", 100, false, { v = 1, c = 1 })
        assert.is_true(new)
        Statement.Touch(S, 150)
        Statement.Leave(S, 160, { v = 2, c = 1 })                         -- a /reload
        local again, new2 = Statement.Login(S, "A", 170, true, { v = 2, c = 1 })
        assert.are.equal(s, again)
        assert.is_false(new2)
        Statement.Leave(S, 200, { v = 3, c = 1 })                         -- logout
        Statement.Login(S, "A", 5000, false, { v = 3, c = 1 })            -- the next login
        assert.are.same({ 100, 200 }, { S.list[1].start, S.list[1].stop })
        assert.are.equal(5000, S.open.start)
        Statement.Touch(S, 5100)                                          -- the game closed: no logout seen
        Statement.Login(S, "A", 9000, false)
        assert.are.equal(5100, S.list[2].stop)
        Statement.Login(S, "B", 9100, true)                               -- another character: a new session
        assert.are.same({ "A", 9000, 9000 }, { S.list[3].c, S.list[3].start, S.list[3].stop })
        local list = Statement.Sessions(S, "A")
        assert.are.same({ 9000, 5000, 100 }, { list[1].start, list[2].start, list[3].start })
        assert.are.equal(list[2], Statement.Find(S, "A", 5000))
        assert.are.equal(4, #S.snaps)                                     -- each login and each leave with a stock
    end)

    it("keeps its lists bounded", function()
        for i = 1, Statement.MAX_SESSIONS + 5 do Statement.Login(S, "A", i * 10, false, { v = 0, c = 0 }) end
        assert.are.equal(Statement.MAX_SESSIONS, #S.list)
        for i = 1, Statement.MAX_SNAPS + 5 do Statement.Leave(S, 1e6 + i, { v = 0, c = 0 }) end
        assert.are.equal(Statement.MAX_SNAPS, #S.snaps)
    end)
end)

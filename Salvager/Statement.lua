-- Salvager: sessions and the statement (what the trading made, and the check against the gold).
-- Pure functions, no game API.
--
-- state (SalvagerDB.sessions) = {
--   open  = session or nil,                 the session being played (kept over a /reload)
--   list  = { session, ... },               closed sessions, oldest first
--   snaps = { { t, v, c }, ... },           the stock's value and cost at each session start and end, oldest first
-- }
-- session = { c = character, start, last (last time seen), stop (when closed), sum = { trading, total } (closed) }
local _, ns = ...
ns = ns or {}

local Util, Journal, Model = ns.Util, ns.Journal, ns.Model
local Statement = {}
ns.Statement = Statement

Statement.MAX_SESSIONS = 200
Statement.MAX_SNAPS = 1000
Statement.NEAR = 100   -- copper: a "Not explained" this small counts as none (rounding of part payments)

-- The kinds of the gold journal that are trading (the rest is gold not from trading).
Statement.TRADING = { buy = true, sale = true, deposit = true, cancel = true, auction = true }

function Statement.Init(state)
    state.list = state.list or {}
    state.snaps = state.snaps or {}
    return state
end

--- The stock now: unsold materials at what one unit is worth to the forecast (`Model.UnitValue`: price × sell
--- price ratio, after the cut, less the deposits lost per unit sold; `opts` as Model.Value), and gear not
--- disenchanted yet at its expected value. Without a price (or an expected value), at its cost: no gain, no loss.
--- Units with no known cost count at no cost.
--- @return table { v = value, c = cost, mv, mc (materials), gv, gc (gear) }
function Statement.StockValue(ledger, priceOf, opts)
    local out = { mv = 0, mc = 0, gv = 0, gc = 0 }
    for id, s in pairs(ledger.stock or {}) do
        local each = Model.UnitValue(id, priceOf, opts)
        local cost = s.cost or 0
        out.mc = out.mc + cost
        out.mv = out.mv + (each and math.floor(each * (s.qty or 0)) or cost)
    end
    for _, list in pairs(ledger.purchases or {}) do
        for _, p in ipairs(list) do
            out.gc = out.gc + (p.each or 0)
            out.gv = out.gv + (p.ev or p.each or 0)
        end
    end
    out.v, out.c = out.mv + out.gv, out.mc + out.gc
    return out
end

local function snap(state, t, stock)
    if not stock then return end
    state.snaps[#state.snaps + 1] = { t = t, v = stock.v, c = stock.c }
    Util.Cap(state.snaps, Statement.MAX_SNAPS)
end

--- A closed session goes to the list, closed at the last time it was seen.
local function close(state)
    local s = state.open
    if not s then return end
    s.stop = s.last or s.start
    state.list[#state.list + 1] = s
    Util.Cap(state.list, Statement.MAX_SESSIONS)
    state.open = nil
end

--- The game loaded the character `char` at `t`. A /reload (`reload`) of the same character keeps the open session;
--- anything else closes it (at its last known time: a logout that was never seen) and starts a new one.
--- @return table the session, boolean true when it is a new one
function Statement.Login(state, char, t, reload, stock)
    Statement.Init(state)
    local open = state.open
    if open and reload and open.c == char then
        open.last = math.max(open.last or t, t)
        return open, false
    end
    close(state)
    state.open = { c = char, start = t, last = t }
    snap(state, t, stock)
    return state.open, true
end

--- The session is still on at `t`.
function Statement.Touch(state, t)
    if state.open then state.open.last = math.max(state.open.last or t, t) end
end

--- The game is leaving (logout or /reload; the client does not tell which): the last time and the stock.
function Statement.Leave(state, t, stock)
    if not state.open then return end
    state.open.last = t
    snap(state, t, stock)
end

--- The sessions of `char`, newest first (the open one first).
function Statement.Sessions(state, char)
    local out = {}
    if state.open and state.open.c == char then out[1] = state.open end
    for i = #(state.list or {}), 1, -1 do
        if state.list[i].c == char then out[#out + 1] = state.list[i] end
    end
    return out
end

--- The session of `char` that started at `start`, or nil.
function Statement.Find(state, char, start)
    for _, s in ipairs(Statement.Sessions(state, char)) do
        if s.start == start then return s end
    end
    return nil
end

--- Money from sales on its way by mail just before `t`: sales booked before `t` and not paid before it.
--- A sale not fully paid yet counts its unpaid units (as now).
function Statement.MailAt(sales, t)
    local total = 0
    for _, s in ipairs(sales or {}) do
        if not s.lost and (s.count or 0) > 0 and (s.t or 0) < t then
            if s.paidAt then
                if s.paidAt >= t then total = total + (s.net or 0) end
            elseif (s.unpaid or 0) > 0 then
                total = total + math.floor((s.net or 0) * s.unpaid / math.max(1, s.count) + 0.5)
            end
        end
    end
    return total
end

-- The stock snapshot to start from: the last one at or before `t`; else the first one up to `to` (not known
-- at `t`: counted from then on). nil when there is none.
local function startSnap(snaps, t, to)
    local found
    for _, s in ipairs(snaps or {}) do
        if s.t <= t then found = s elseif not found and s.t <= to then return s, false end
    end
    return found, found ~= nil
end
local function endSnap(snaps, t)
    local found
    for _, s in ipairs(snaps or {}) do if s.t <= t then found = s end end
    return found
end

--- The statement of `char` from `from` to `to` (both included, seconds).
--- args = { ledger, journal (SalvagerDB.money), char, from, to, now, snaps, stockNow (StockValue now) }
--- @return table {
---   sales, salesN, cost, depositsLost, cancel (<= 0), trading,                          the trading
---   away = { net, cost, profit, n },                                                     sold while you were away
---   stock = { known, since, v0, c0, v1, c1, change } or nil (no snapshot),              stock change
---   total,
---   other = { { k, name, amount, n }, ... }, otherSum,                                   gold not from trading
---   check = { g0, m0, g1, m1, change, sales, back, buy, deposit, cancel, auction, other, explained, missing, ok }
---           (g0 nil: no gold recorded) }
function Statement.Compute(a)
    local from, to = a.from or 0, a.to or a.now
    local L = a.ledger
    local st = { from = from, to = to, sales = 0, salesN = 0, cost = 0, depositsLost = 0, cancel = 0,
        away = { net = 0, cost = 0, profit = 0, n = 0 } }
    local salesAll, back = 0, 0
    for _, s in ipairs(L.sales or {}) do
        local t = s.t or 0
        if t >= from and t <= to then
            if s.lost then
                st.depositsLost = st.depositsLost - (s.net or 0)
            elseif (s.count or 0) > 0 then
                salesAll = salesAll + (s.net or 0)
                if s.away then
                    st.away.net, st.away.cost, st.away.n = st.away.net + (s.net or 0), st.away.cost + (s.cost or 0),
                        st.away.n + 1
                else
                    st.sales, st.cost, st.salesN = st.sales + (s.net or 0), st.cost + (s.cost or 0), st.salesN + 1
                end
            end
        end
        if s.back and s.backAt and s.backAt >= from and s.backAt <= to then back = back + s.back end
    end
    st.away.profit = st.away.net - st.away.cost
    local sum = Journal.Summary(a.journal, a.char, from, to)
    local kinds = sum.kinds
    local function k(name) local x = kinds[name] return x and (x.gain + x.loss) or 0 end
    st.cancel = k("cancel")
    st.trading = st.sales - st.cost - st.depositsLost + st.cancel

    -- Stock change: (value - cost) at the end minus (value - cost) at the start.
    local s0, known = startSnap(a.snaps, from, to)
    local s1 = to >= a.now and a.stockNow or endSnap(a.snaps, to)
    if s0 and s1 then
        st.stock = { known = known, since = s0.t, v0 = s0.v, c0 = s0.c, v1 = s1.v, c1 = s1.c }
        st.stock.change = (s1.v - s1.c) - (s0.v - s0.c)
    end
    st.total = st.trading + st.away.profit + (st.stock and st.stock.change or 0)

    st.other, st.otherSum = {}, 0
    for _, kind in ipairs(Journal.KINDS) do
        local x = kinds[kind[1]]
        if x and not Statement.TRADING[kind[1]] then
            st.other[#st.other + 1] = { k = kind[1], name = kind[2], amount = x.gain + x.loss, n = x.n }
            st.otherSum = st.otherSum + x.gain + x.loss
        end
    end

    local c = { sales = salesAll, back = back, buy = k("buy"), deposit = k("deposit"), cancel = st.cancel,
        auction = k("auction"), other = st.otherSum }
    st.check = c
    if sum.start ~= nil then
        c.g0, c.g1 = sum.start, sum.finish
        c.m0, c.m1 = Statement.MailAt(L.sales, from), Statement.MailAt(L.sales, to + 1)
        c.change = (c.g1 + c.m1) - (c.g0 + c.m0)
        c.explained = c.sales + c.back + c.buy + c.deposit + c.cancel + c.auction + c.other
        c.missing = c.change - c.explained
        c.ok = math.abs(c.missing) <= Statement.NEAR
    end
    return st
end

return Statement

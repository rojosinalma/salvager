-- Salvager: the gold journal. Every change of a character's gold, with what caused it.
-- Pure functions on a state table (SalvagerDB.money), no game API.
--
-- state = {
--   chars   = { [char] = { b = balance, t = time last seen } },
--   entries = { { t, c = char, d = change, b = balance after, k = kind, r = what (text) }, ... }   oldest first
-- }
-- Kinds: see Journal.KINDS. "unseen" = the gold changed while the addon did not run (it is found at login).
local _, ns = ...
ns = ns or {}

local Util = ns.Util
local Journal = {}
ns.Journal = Journal

Journal.MAX = 20000

Journal.KINDS = {
    { "buy", "Gear bought" },
    { "sale", "Sales collected" },
    { "deposit", "Deposits" },
    { "cancel", "Cancel fees" },
    { "auction", "Other auction house" },
    { "mail", "Other mail" },
    { "vendor", "Sold to vendors" },
    { "merchant", "Bought from vendors" },
    { "repair", "Repairs" },
    { "trade", "Trades" },
    { "flight", "Flights" },
    { "training", "Training" },
    { "other", "Loot, quests and other" },
    { "unseen", "While the addon was off" },
}
Journal.KIND_NAME = {}
for _, k in ipairs(Journal.KINDS) do Journal.KIND_NAME[k[1]] = k[2] end

function Journal.Init(state)
    state.chars = state.chars or {}
    state.entries = state.entries or {}
    return state
end

--- The gold of `char` is `balance` at time `t`. A change from the last balance seen is recorded as `kind`.
--- The first balance of a character is its start: nothing is recorded for it.
--- @return table|nil  the entry recorded
function Journal.Seen(state, char, balance, t, kind, ref)
    if type(balance) ~= "number" or not char then return nil end
    local last = state.chars[char]
    state.chars[char] = { b = balance, t = t }
    if not last then
        state.entries[#state.entries + 1] = { t = t, c = char, d = 0, b = balance, k = "start" }
        return nil
    end
    local d = balance - last.b
    if d == 0 then return nil end
    local e = { t = t, c = char, d = d, b = balance, k = kind or "other", r = ref }
    state.entries[#state.entries + 1] = e
    Util.Cap(state.entries, Journal.MAX)
    return e
end

--- The balance of `char` at time `t`: after the last entry at or before `t`. nil when nothing is known.
function Journal.BalanceAt(state, char, t)
    local found
    for _, e in ipairs(state.entries) do
        if e.c == char then
            if e.t > t then return found or (e.b - e.d) end
            found = e.b
        end
    end
    return found
end

--- What happened to `char`'s gold from `from` to `to`.
--- @return table { start, finish, change, kinds = { [kind] = { gain, loss, n } }, entries = { ... } }
function Journal.Summary(state, char, from, to)
    local s = { kinds = {}, entries = {}, from = from, to = to }
    for _, e in ipairs(state.entries) do
        if e.c == char and e.t >= from and e.t <= to then
            if s.start == nil then s.start = e.b - e.d end
            s.finish = e.b
            if e.k ~= "start" then
                local k = s.kinds[e.k] or { gain = 0, loss = 0, n = 0 }
                s.kinds[e.k] = k
                if e.d > 0 then k.gain = k.gain + e.d else k.loss = k.loss + e.d end
                k.n = k.n + 1
            end
            s.entries[#s.entries + 1] = e
        end
    end
    if s.start == nil then
        s.start = Journal.BalanceAt(state, char, from)
        s.finish = s.start
    end
    s.change = (s.start and s.finish) and (s.finish - s.start) or nil
    return s
end

--- Expected changes: what the addon knows is coming (a purchase, a deposit, a mail's money).
--- `x` = { k = kind, a = exact change or nil, sign = 1 | -1 (when `a` is nil), r = what }; it lives `ttl` seconds.
function Journal.Expect(list, x, now, ttl)
    x.until_ = now + (ttl or 10)
    list[#list + 1] = x
    Util.Cap(list, 50)
end

--- Takes the expectation that explains a change of `d`: the oldest with this exact amount, else the oldest
--- with no amount and this sign.
--- @return string|nil kind, string|nil ref
function Journal.Match(list, d, now)
    for i = #list, 1, -1 do
        if list[i].until_ < now then table.remove(list, i) end
    end
    for i, x in ipairs(list) do
        if x.a == d then table.remove(list, i) return x.k, x.r end
    end
    local sign = d < 0 and -1 or 1
    for i, x in ipairs(list) do
        if x.a == nil and x.sign == sign then table.remove(list, i) return x.k, x.r end
    end
    -- Several at once (an "open all" takes many mails before the gold is read): the first ones, in order,
    -- whose amounts add up to the change.
    local sum, take = 0, {}
    for i, x in ipairs(list) do
        if x.a and (x.a < 0) == (d < 0) then
            sum = sum + x.a
            take[#take + 1] = i
            if sum == d then
                local kind = list[take[1]].k
                for j = #take, 1, -1 do
                    if list[take[j]].k ~= kind then kind = "mixed" end
                    table.remove(list, take[j])
                end
                return kind == "mixed" and "mail" or kind, string.format("%d at once", #take)
            end
            if (d > 0 and sum > d) or (d < 0 and sum < d) then break end
        end
    end
    return nil
end

return Journal

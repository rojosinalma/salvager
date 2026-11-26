-- Salvager: who undercuts you (SDD 109). Pure: no game API, so the tests load it alone.
--   Observe:   a material search's price lines against your live auctions of it -> undercut events, one per owner
--              per price line, not again while the same line stays between searches.
--   NoteCancel, NotePost, NoteSale: the chain listing -> cancel -> repost -> sale, per material, first in, first out
--              over units, for the profit lost to competitors (cancel costs, repost deposits, lower sale prices).
--   Competitors, Materials, Summary, AtStake: what the Ledger and the Reports show.
local _, ns = ...

local Competition = {}
ns.Competition = Competition

local dateOf = date or (os and os.date)   -- (the game's `date`; the tests' Lua has os.date)

Competition.UNKNOWN = "Unknown seller"
Competition.MAX_EVENTS = 5000      -- undercut events kept (the newest); the names keep their counts beyond that
Competition.MAX_LOSSES = 5000      -- records of profit lost kept (the newest)
Competition.UNDERCUT_WINDOW = 1800 -- s: a cancel counts as caused by an undercut seen at most this long before it
Competition.REPOST_WINDOW = 3600   -- s: a post replaces an undercut cancel of its material made at most this long before
Competition.POST_MAX_AGE = 30 * 86400 -- s: posts followed for their sales at most this long

--- The saved state, with its parts filled in.
function Competition.Init(state)
    state.events = state.events or {}   -- { t, id, p (their price each), my (yours), g (gap), q (their units), u (yours), o }
    state.names = state.names or {}     -- [name] = { n, first, last }: every undercut of that name, all time
    state.seen = state.seen or {}       -- [itemID] = { [line key] = true }: the lines of the last search
    state.last = state.last or {}       -- [itemID] = { t, lines = { { p, q, who } } }: the last search's lines
    state.posts = state.posts or {}     -- [auctionID] = { id, t, qty, each, chunks = { { n, base, who } } }
    -- [itemID] = { { n, base, who, cause, t, since } }: units cancelled after an undercut; `who` = every competitor of
    -- the chain (the lower sale price is theirs), `cause` = those under the listing when it was cancelled (the
    -- repost's deposit is theirs)
    state.pending = state.pending or {}
    state.losses = state.losses or {}   -- { t, id, kind = "cancel" | "repost" | "price", amount, who = { names } }
    state.cancels = state.cancels or {} -- { t, id, qty, since }: cancels of undercut listings
    state.reposts = state.reposts or {} -- { t, id, n, delay }: posts that replaced them
    return state
end

--- Clears everything (Clear history).
function Competition.Clear(state)
    for k in pairs(state) do state[k] = nil end
    return Competition.Init(state)
end

local function cap(list, max)
    while #list > max do table.remove(list, 1) end
end

local function union(a, b)
    local out, seen = {}, {}
    for _, list in ipairs({ a or {}, b or {} }) do
        for _, n in ipairs(list) do if not seen[n] then seen[n] = true out[#out + 1] = n end end
    end
    table.sort(out)
    return out
end

--- The other sellers' names of a price line: yours left out ("player" is how the client names you, and `self`), a
--- missing name ("", "...", nil: the client does not know it yet) is Unknown seller, and so are owners the list
--- leaves out (totalNumberOfOwners above the names given).
function Competition.Names(line, self)
    local names, seen, others = {}, {}, 0
    local own = line.own and 1 or 0
    for _, o in ipairs(line.owners or {}) do
        if o == "player" or (self and o == self) then
            own = math.max(own, 1)
        else
            others = others + 1
            local name = (type(o) == "string" and o ~= "" and o ~= "...") and o or Competition.UNKNOWN
            if not seen[name] then seen[name] = true names[#names + 1] = name end
        end
    end
    local total = (line.total or 0) - own
    if others == 0 and total <= 0 and own > 0 then return names end   -- (yours alone)
    if #names == 0 or (total > others and not seen[Competition.UNKNOWN]) then names[#names + 1] = Competition.UNKNOWN end
    return names
end

--- A search of material `id`: `lines` = its price lines, cheapest first ({ each, qty, ownQty, owners, total, own });
--- `mine` = your live auctions of it ({ each, qty }). Each line of others under one of your prices is an undercut:
--- one event per owner of the line, unless the same line (price, units, owner) was in the last search too.
--- @return table events added
function Competition.Observe(state, id, lines, mine, now, self)
    Competition.Init(state)
    local before, seen, added = state.seen[id] or {}, {}, {}
    local last = { t = now, lines = {} }
    for _, line in ipairs(lines) do
        local q = (line.qty or 0) - (line.ownQty or 0)
        if q > 0 and line.each and line.each > 0 then
            local my, u = nil, 0
            for _, m in ipairs(mine) do
                if m.each > line.each then
                    u = u + m.qty
                    if not my or m.each < my then my = m.each end
                end
            end
            local who = my and Competition.Names(line, self)
            if who and #who > 0 then
                last.lines[#last.lines + 1] = { p = line.each, q = q, who = who }
                for _, o in ipairs(who) do
                    local key = line.each .. ":" .. q .. ":" .. o
                    seen[key] = true
                    if not before[key] then
                        local e = { t = now, id = id, p = line.each, my = my, g = my - line.each, q = q, u = u, o = o }
                        state.events[#state.events + 1] = e
                        added[#added + 1] = e
                        local n = state.names[o] or { n = 0, first = now }
                        n.n, n.last = n.n + 1, now
                        state.names[o] = n
                    end
                end
            end
        end
    end
    state.seen[id], state.last[id] = seen, last
    cap(state.events, Competition.MAX_EVENTS)
    return added
end

--- Who was under `each` in the last search of `id`, at most UNDERCUT_WINDOW before `t`: their names, or nil.
local function under(state, id, each, t)
    local last = state.last[id]
    if not (last and t - last.t <= Competition.UNDERCUT_WINDOW and t >= last.t - 1) then return nil end
    local who = {}
    for _, l in ipairs(last.lines) do if l.p < each then who = union(who, l.who) end end
    return #who > 0 and who or nil
end

--- The first undercut event of `id` under `each` since `from` (when the undercut began), or nil.
local function firstUnder(state, id, each, from, to)
    for _, e in ipairs(state.events) do
        if e.id == id and e.p < each and e.t >= (from or 0) and e.t <= to then return e.t end
    end
end

local function lose(state, t, id, kind, amount, who)
    if amount <= 0 or not who or #who == 0 then return end
    state.losses[#state.losses + 1] = { t = t, id = id, kind = kind, amount = amount, who = who }
    cap(state.losses, Competition.MAX_LOSSES)
end

--- A post of yours (made through Salvager): it is followed for its sales. Units of `id` cancelled after an undercut
--- in the last REPOST_WINDOW are taken first in, first out: the post replaces them (their first price and the
--- competitors who caused it go with them), and its deposit for those units is lost to those competitors.
function Competition.NotePost(state, p)
    Competition.Init(state)
    local chunks, took, who, since = {}, 0, {}, nil
    local pend = state.pending[p.id] or {}
    local i = 1
    while i <= #pend and took < p.qty do
        local c = pend[i]
        if p.t - c.t > Competition.REPOST_WINDOW then
            table.remove(pend, i)
        else
            local n = math.min(c.n, p.qty - took)
            chunks[#chunks + 1] = { n = n, base = c.base, who = c.who, cause = c.cause }
            took = took + n
            who = union(who, c.who)
            since = since and math.min(since, c.since or c.t) or (c.since or c.t)
            c.n = c.n - n
            if c.n <= 0 then table.remove(pend, i) else i = i + 1 end
        end
    end
    state.pending[p.id] = pend
    if p.qty > took then chunks[#chunks + 1] = { n = p.qty - took } end
    state.posts[p.auctionID] = { id = p.id, t = p.t, qty = p.qty, each = p.each, chunks = chunks }
    if took > 0 then
        for _, c in ipairs(chunks) do
            if c.base then lose(state, p.t, p.id, "repost", math.floor((p.deposit or 0) * c.n / p.qty + 0.5), c.cause) end
        end
        state.reposts[#state.reposts + 1] = { t = p.t, id = p.id, n = took, delay = since and (p.t - since) or nil }
        cap(state.reposts, Competition.MAX_LOSSES)
    end
    -- Old posts go: their sales would come long after.
    for aid, post in pairs(state.posts) do
        if p.t - post.t > Competition.POST_MAX_AGE then state.posts[aid] = nil end
    end
end

--- A cancel of one of your auctions (`c` = { t, id, auctionID, qty, each, fee, deposit }). When the last search of
--- its material had others under its price (an undercut), the fee and the deposit lost are lost to them, and its
--- units wait for the repost that replaces them (with the first price of the chain: "base").
--- @return boolean  it was undercut
function Competition.NoteCancel(state, c)
    Competition.Init(state)
    local post = state.posts[c.auctionID]
    state.posts[c.auctionID] = nil
    local who = under(state, c.id, c.each, c.t)
    if not who then return false end
    lose(state, c.t, c.id, "cancel", (c.fee or 0) + (c.deposit or 0), who)
    local since = firstUnder(state, c.id, c.each, post and post.t, c.t)
    state.cancels[#state.cancels + 1] = { t = c.t, id = c.id, qty = c.qty, since = since }
    cap(state.cancels, Competition.MAX_LOSSES)
    local pend = state.pending[c.id] or {}
    local left = c.qty
    for _, ch in ipairs(post and post.chunks or {}) do
        if left <= 0 then break end
        local n = math.min(ch.n, left)
        pend[#pend + 1] = { n = n, base = ch.base or c.each, who = union(ch.who, who), cause = who, t = c.t,
            since = since }
        left = left - n
    end
    if left > 0 then pend[#pend + 1] = { n = left, base = c.each, who = who, cause = who, t = c.t, since = since } end
    state.pending[c.id] = pend
    return true
end

--- Units of one of your posts sold at `each`: those that came down a chain from a higher first price lost the
--- difference to the competitors of that chain.
function Competition.NoteSale(state, auctionID, qty, each, t)
    Competition.Init(state)
    local post = state.posts[auctionID]
    if not post then return end
    local left = qty
    while left > 0 and #post.chunks > 0 do
        local c = post.chunks[1]
        local n = math.min(c.n, left)
        if c.base and c.base > each then lose(state, t, post.id, "price", (c.base - each) * n, c.who) end
        c.n, left = c.n - n, left - n
        if c.n <= 0 then table.remove(post.chunks, 1) end
    end
end

------------------------------------------------------------------ what the windows show

local function median(list)
    if #list == 0 then return nil end
    table.sort(list)
    local m = math.floor((#list + 1) / 2)
    if #list % 2 == 1 then return list[m] end
    return (list[m] + list[m + 1]) / 2
end
Competition.Median = median

local function inTime(t, from, to) return t >= (from or 0) and (not to or t <= to) end

--- The profit lost in a time, per name (split evenly over each record's names) and in parts.
--- @return table { total, cancel, repost, price, by = { [name] = { total, cancel, repost, price, mats = { [id] = n } } } }
function Competition.Lost(state, from, to, id)
    Competition.Init(state)
    local out = { total = 0, cancel = 0, repost = 0, price = 0, by = {} }
    for _, l in ipairs(state.losses) do
        if inTime(l.t, from, to) and (not id or l.id == id) then
            out.total, out[l.kind] = out.total + l.amount, out[l.kind] + l.amount
            local share = l.amount / #l.who
            for _, o in ipairs(l.who) do
                local b = out.by[o] or { total = 0, cancel = 0, repost = 0, price = 0, mats = {} }
                b.total, b[l.kind] = b.total + share, b[l.kind] + share
                b.mats[l.id] = (b.mats[l.id] or 0) + share
                out.by[o] = b
            end
        end
    end
    return out
end

local function newGroup(key)
    return { key = key, n = 0, gaps = {}, pcts = {}, mats = {}, names = {}, hours = {}, first = nil, last = nil,
        lowest = nil, lowestId = nil }
end
local function add(g, e)
    g.n = g.n + 1
    g.gaps[#g.gaps + 1] = e.g
    g.pcts[#g.pcts + 1] = e.my > 0 and (e.g / e.my * 100) or 0
    g.mats[e.id] = (g.mats[e.id] or 0) + 1
    g.names[e.o] = (g.names[e.o] or 0) + 1
    local h = tonumber(dateOf("%H", e.t)) or 0
    g.hours[h] = (g.hours[h] or 0) + 1
    g.first = g.first and math.min(g.first, e.t) or e.t
    g.last = g.last and math.max(g.last, e.t) or e.t
    if not g.lowest or e.p < g.lowest then g.lowest, g.lowestId = e.p, e.id end
end
local function finish(g)
    g.gap, g.pct = median(g.gaps), median(g.pcts)
    local order = {}
    for k, n in pairs(g.mats) do order[#order + 1] = { id = k, n = n } end
    table.sort(order, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.id < b.id end)
    g.matOrder = order
    local names = {}
    for k, n in pairs(g.names) do names[#names + 1] = { name = k, n = n } end
    table.sort(names, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.name < b.name end)
    g.nameOrder = names
    local hours = {}
    for h, n in pairs(g.hours) do hours[#hours + 1] = { h = h, n = n } end
    table.sort(hours, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.h < b.h end)
    g.hourOrder = hours
    return g
end

--- The undercut events of a time (and of one material, `id`), grouped per competitor, the most seen first; each
--- with its materials (most often first), gaps (median in coins and %), lowest price, first and last time, hours.
--- @return table list, number total events
function Competition.Competitors(state, from, to, id)
    Competition.Init(state)
    local by, list, total = {}, {}, 0
    for _, e in ipairs(state.events) do
        if inTime(e.t, from, to) and (not id or e.id == id) then
            local g = by[e.o]
            if not g then g = newGroup(e.o) by[e.o] = g list[#list + 1] = g end
            add(g, e)
            g.byMat = g.byMat or {}
            local m = g.byMat[e.id] or newGroup(e.id)
            add(m, e)
            g.byMat[e.id] = m
            total = total + 1
        end
    end
    for _, g in ipairs(list) do
        finish(g)
        for _, m in pairs(g.byMat) do finish(m) end
    end
    table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.key < b.key end)
    return list, total
end

--- The same events grouped per material, the most undercut first; each with its competitors (most seen first).
function Competition.Materials(state, from, to, id)
    Competition.Init(state)
    local by, list = {}, {}
    for _, e in ipairs(state.events) do
        if inTime(e.t, from, to) and (not id or e.id == id) then
            local g = by[e.id]
            if not g then g = newGroup(e.id) by[e.id] = g list[#list + 1] = g end
            add(g, e)
            g.byName = g.byName or {}
            local m = g.byName[e.o] or newGroup(e.o)
            add(m, e)
            g.byName[e.o] = m
        end
    end
    for _, g in ipairs(list) do
        finish(g)
        for _, m in pairs(g.byName) do finish(m) end
    end
    table.sort(list, function(a, b) if a.n ~= b.n then return a.n > b.n end return a.key < b.key end)
    return list
end

--- Undercut events per name in a time (for the trend against the period before).
function Competition.Counts(state, from, to, id)
    local out = {}
    for _, e in ipairs(state.events) do
        if inTime(e.t, from, to) and (not id or e.id == id) then out[e.o] = (out[e.o] or 0) + 1 end
    end
    return out
end

--- Cancels of undercut listings and the reposts that replaced them, in a time: counts and the median time from the
--- undercut to the repost.
function Competition.Answers(state, from, to, id)
    Competition.Init(state)
    local cancels, reposts, delays = 0, 0, {}
    for _, c in ipairs(state.cancels) do
        if inTime(c.t, from, to) and (not id or c.id == id) then cancels = cancels + 1 end
    end
    for _, r in ipairs(state.reposts) do
        if inTime(r.t, from, to) and (not id or r.id == id) then
            reposts = reposts + 1
            if r.delay then delays[#delays + 1] = r.delay end
        end
    end
    return { cancels = cancels, reposts = reposts, delay = median(delays) }
end

--- Gold at stake now: your live auctions (`rows`: { auctionID, id, qty, each }) under-listed in the last search of
--- their material (units × the gap to the lowest line of others), and units of a chain listed below their first price
--- (units × that difference). Not lost yet: they have not sold.
--- @return number total, number undercut part, number lowered part
function Competition.AtStake(state, rows, now)
    Competition.Init(state)
    local undercut, lowered = 0, 0
    for _, r in ipairs(rows) do
        local last = state.last[r.id]
        local low
        if last and now - last.t <= Competition.UNDERCUT_WINDOW then
            for _, l in ipairs(last.lines) do if not low or l.p < low then low = l.p end end
        end
        if low and low < r.each then undercut = undercut + (r.each - low) * r.qty end
        local post = state.posts[r.auctionID]
        for _, c in ipairs(post and post.chunks or {}) do
            if c.base and c.base > r.each then lowered = lowered + (c.base - r.each) * c.n end
        end
    end
    return undercut + lowered, undercut, lowered
end

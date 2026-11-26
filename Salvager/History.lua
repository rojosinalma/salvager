-- Salvager: price history. One point per material and time slot, kept in SalvagerDB.history.
-- Pure functions on a state table, no game API.
--   state = { [matID] = { { t, p, lo, n }, ... } }    oldest first
--   t = time of the scan, p = price each (average of the cheapest units; nil when none was listed),
--   lo = the lowest listing, n = units listed by others
local _, ns = ...
ns = ns or {}

local History = {}
ns.History = History

History.SLOT = 60          -- seconds: scans closer together than this share one point (the last one stays)
History.MAX_POINTS = 1000 -- per material; past this, the older half keeps every second point

--- Adds a scan result.
function History.Add(state, matID, t, p, lo, n)
    local list = state[matID] or {}
    state[matID] = list
    local point = { t = t, p = p, lo = lo, n = n }
    local last = list[#list]
    if last and t - last.t < History.SLOT then
        list[#list] = point
        point.t = last.t   -- the slot keeps its start, so a run of quick scans does not slide forward for ever
        if t - last.t >= History.SLOT / 2 then point.t = t end
    else
        list[#list + 1] = point
    end
    if #list > History.MAX_POINTS then
        -- Old points get thinner, so a long time still fits: every second one of the older half goes.
        local half, kept = math.floor(#list / 2), {}
        for i = 1, #list do
            if i > half or i % 2 == 1 then kept[#kept + 1] = list[i] end
        end
        state[matID] = kept
    end
end

--- Puts older observations into the history: { { id, t, p, lo, n }, ... } in any order. They are merged
--- with the points already there, in time order.
--- @return number  points given
function History.Merge(state, points)
    local byMat = {}
    for _, pt in ipairs(points) do
        if pt.id and pt.t and pt.p then
            local list = byMat[pt.id]
            if not list then
                list = {}
                for _, old in ipairs(state[pt.id] or {}) do list[#list + 1] = old end
                byMat[pt.id] = list
            end
            list[#list + 1] = { t = pt.t, p = pt.p, lo = pt.lo, n = pt.n }
        end
    end
    for id, list in pairs(byMat) do
        table.sort(list, function(a, b) return a.t < b.t end)
        state[id] = {}
        for _, pt in ipairs(list) do History.Add(state, id, pt.t, pt.p, pt.lo, pt.n) end
    end
    return #points
end

--- The points of a material from `since` on (all when nil).
function History.Points(state, matID, since)
    local out = {}
    for _, pt in ipairs(state[matID] or {}) do
        if not since or pt.t >= since then out[#out + 1] = pt end
    end
    return out
end

--- The price of a material at a moment: the last one seen at or before it. nil when none yet.
function History.At(state, matID, t)
    local p
    for _, pt in ipairs(state[matID] or {}) do
        if pt.t > t then break end
        if pt.p then p = pt.p end
    end
    return p
end

--- Every moment at which one of these materials has a point, from `since` on, oldest first.
function History.Times(state, ids, since)
    local seen, out = {}, {}
    for _, id in ipairs(ids) do
        for _, pt in ipairs(state[id] or {}) do
            if (not since or pt.t >= since) and not seen[pt.t] then
                seen[pt.t] = true
                out[#out + 1] = pt.t
            end
        end
    end
    table.sort(out)
    return out
end

History.CEILING_WINDOW = 24 * 3600   -- seconds of history the ceiling looks at
History.CEILING_POINTS = 3           -- points it needs
History.CEILING_RISE = 1.25          -- how far over the median a price may go
History.THIN_UNITS = 5               -- fewer units listed than this: the price is no more than the median

--- The highest price each a material may be valued at now, from its own history: a thin market (one silly
--- listing) cannot raise the value of a whole band. nil when the history is too short to say.
--- @param units number|nil  units the price now rests on
function History.Ceiling(state, matID, now, units)
    local ps = {}
    for _, pt in ipairs(state[matID] or {}) do
        if pt.p and pt.t >= now - History.CEILING_WINDOW then ps[#ps + 1] = pt.p end
    end
    if #ps < History.CEILING_POINTS then return nil end
    table.sort(ps)
    local mid = math.floor((#ps + 1) / 2)
    local median = (#ps % 2 == 1) and ps[mid] or (ps[mid] + ps[mid + 1]) / 2
    if units and units < History.THIN_UNITS then return math.floor(median + 0.5) end
    return math.floor(median * History.CEILING_RISE + 0.5)
end

--- The average price per hour of the day (0 to 23) of a list of points.
--- @return table { { hour, average }, ... } for the hours that have a price, in order
function History.ByHour(points, hourOf)
    local sum, n = {}, {}
    for _, pt in ipairs(points) do
        if pt.p then
            local h = hourOf(pt.t)
            sum[h], n[h] = (sum[h] or 0) + pt.p, (n[h] or 0) + 1
        end
    end
    local out = {}
    for h = 0, 23 do
        if n[h] then out[#out + 1] = { h, math.floor(sum[h] / n[h] + 0.5) } end
    end
    return out
end

--- First and last price of a list of points, and the change between them as a share. nil when unknown.
function History.Change(points)
    local first, last
    for _, pt in ipairs(points) do
        if pt.p then
            first = first or pt.p
            last = pt.p
        end
    end
    if not first or first == 0 then return nil end
    return (last - first) / first, first, last
end

return History

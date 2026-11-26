-- Salvager: price history. One point per material and time slot, kept in SalvagerDB.history.
-- Pure functions on a state table, no game API.
--   state = { [matID] = { { t, p, lo, n }, ... } }    oldest first
--   t = time of the scan, p = price each (average of the cheapest units; nil when none was listed),
--   lo = the lowest listing, n = units listed by others
local _, ns = ...
ns = ns or {}

local History = {}
ns.History = History

History.SLOT = 600        -- seconds: scans closer together than this share one point (the last one stays)
History.MAX_POINTS = 600  -- per material; the oldest go first

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
    while #list > History.MAX_POINTS do table.remove(list, 1) end
end

--- The points of a material from `since` on (all when nil).
function History.Points(state, matID, since)
    local out = {}
    for _, pt in ipairs(state[matID] or {}) do
        if not since or pt.t >= since then out[#out + 1] = pt end
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

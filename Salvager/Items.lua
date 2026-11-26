-- Salvager: item levels without asking the game during a scan.
-- The level of an auction's item comes from, in order:
--   1. SalvagerDB.ilvl, learned from the game's own item data (kept between sessions);
--   2. the item level that comes with the auction listing.
-- Items not learned yet are asked for in the background, a few at a time, so a
-- scan never sends thousands of item requests at once.
local _, ns = ...

local Items = { queue = {}, pending = {}, waiting = {}, learned = 0 }
ns.Items = Items

-- Item lookups per tick (10 ticks a second). Slow while the listings carry a level (the lookups
-- then only confirm it); fast when a scan had to skip items because it had no level for them.
local PER_TICK, PER_TICK_URGENT = 5, 20

local function resolve(id)
    local _, _, quality, lvl = ns.GetItemInfo(id)
    if lvl and lvl > 0 then
        ns.db.ilvl[id] = lvl
        ns.db.quality[id] = quality
        Items.pending[id], Items.waiting[id] = nil, nil
        Items.learned = Items.learned + 1
        return true
    end
    return false
end

--- Queues an item to learn its level from the game.
function Items.Learn(id)
    if Items.pending[id] or (ns.db.ilvl[id] and ns.db.quality[id]) then return end
    Items.pending[id] = true
    Items.queue[#Items.queue + 1] = id
end

--- Item level for an auction's item key.
--- @return number|nil level, string|nil source ("cache" or "key")
function Items.Level(key)
    local id = key.itemID
    local lvl = ns.db.ilvl[id]
    if lvl then return lvl, "cache" end
    Items.Learn(id)
    local k = key.itemLevel
    if k and k > 0 then return k, "key" end
    Items.urgent = true
    return nil
end

--- An item's quality, from what was learned (no request to the game during a scan). nil = not learned yet:
--- it is asked for in the background.
function Items.Quality(id)
    local q = ns.db.quality[id]
    if q == nil then Items.Learn(id) end
    return q
end

function Items.Backlog() return #Items.queue end

ns.OnTick(function()
    local q = Items.queue
    if #q == 0 or not ns.db then
        Items.urgent = false
        return
    end
    for _ = 1, math.min(Items.urgent and PER_TICK_URGENT or PER_TICK, #q) do
        local id = table.remove(q)
        -- Not in the client yet: this call asks the server, and the answer comes as an event.
        if not resolve(id) then Items.waiting[id] = true end
    end
end)

ns.On("GET_ITEM_INFO_RECEIVED", function(id, ok)
    if not Items.waiting[id] then return end
    Items.waiting[id] = nil
    if not (ok and resolve(id)) then Items.pending[id] = nil end
end)

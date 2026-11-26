-- Salvager: material prices from the auction house.
-- Price each = average unit price of the cheapest N units (your own listings left out).
local _, ns = ...

local AH = C_AuctionHouse
local Data = ns.Data

local Prices = { scanning = false, done = 0, total = 0 }
ns.Prices = Prices

--- Average price of the cheapest `units` units in the client's current results.
--- @return table|nil { p, units, listings }
function Prices.ReadCommodity(itemID, units)
    local n = AH.GetNumCommoditySearchResults(itemID) or 0
    local need, sum, got, listings, lo = units, 0, 0, 0, nil
    for i = 1, n do
        local r = AH.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice and r.unitPrice > 0 then
            local qty = (r.quantity or 0) - (r.numOwnerItems or 0)
            if qty > 0 then
                lo = lo or r.unitPrice
                local take = math.min(qty, need)
                sum = sum + take * r.unitPrice
                got = got + take
                need = need - take
                listings = listings + 1
                if need <= 0 then break end
            end
        end
    end
    if got == 0 then return nil end
    return { p = math.floor(sum / got + 0.5), units = got, listings = listings, lo = lo }
end

local function store(itemID)
    local e = Prices.ReadCommodity(itemID, ns.db.settings.priceUnits)
    ns.Log("price %s (%d): %s, %d results", ns.MaterialName(itemID), itemID,
        e and (ns.Money(e.p) .. " over " .. e.units .. " units") or "none listed",
        AH.GetNumCommoditySearchResults(itemID) or 0)
    -- For the charts: this scan's price, lowest listing and units listed by others.
    local listed = 0
    for i = 1, (AH.GetNumCommoditySearchResults(itemID) or 0) do
        local r = AH.GetCommoditySearchResultInfo(itemID, i)
        if r then listed = listed + math.max(0, (r.quantity or 0) - (r.numOwnerItems or 0)) end
    end
    ns.History.Add(ns.db.history, itemID, time(), e and e.p, e and e.lo, listed)
    if e then
        e.t = time()
        ns.db.prices[itemID] = e
    else
        local old = ns.db.prices[itemID]
        ns.db.prices[itemID] = { p = nil, units = 0, listings = 0, t = time(),
            last = old and (old.p or old.last), lastT = old and (old.p and old.t or old.lastT) }
    end
end

Prices.Store = store

local function stepDone()
    Prices.done = Prices.done + 1
    ns.Fire("SALVAGER_PRICES", Prices.done, Prices.total)
    if Prices.done >= Prices.total then
        Prices.scanning = false
        ns.Print("material prices updated (%d)", Prices.total)
        ns.Fire("SALVAGER_PRICES_DONE")
    end
end

--- The materials you carry in your bags (the ones you can post).
function Prices.Owned()
    local ids = {}
    for _, m in ipairs(Data.MATERIALS) do
        if ns.Post.BagCount(m.id) > 0 then ids[#ids + 1] = m.id end
    end
    return ids
end

--- Searches every material once, or only `ids`. Needs the auction house open.
function Prices.Scan(ids)
    if not ns.Queue.open then ns.Print("open the auction house first") return end
    if Prices.scanning then return end
    -- The full scan changes the prices a gear scan works with, so it waits. A scan of a few materials
    -- (Scan owned) is let in: its searches take their turn in the queue.
    if not ids and ns.Scanner.state ~= "idle" then
        ns.Print("wait for the gear scan to finish (or use Scan both)")
        return
    end
    if ns.Listings and ns.Listings.checking then
        ns.Print("wait for the undercut check to finish")
        return
    end
    if not ids then
        ids = {}
        for _, m in ipairs(Data.MATERIALS) do ids[#ids + 1] = m.id end
    elseif #ids == 0 then
        ns.Print("no disenchanting material in your bags")
        return
    end
    Prices.scanning, Prices.done, Prices.total = true, 0, #ids
    ns.Log("material scan started (%d materials)", #ids)
    for _, id in ipairs(ids) do
        ns.Queue.Add({
            commodity = id,
            onResult = function() store(id) stepDone() end,
            onFail = function() stepDone() end,
        })
    end
    ns.Fire("SALVAGER_PRICES", 0, Prices.total)
end

--- Searches one material now (ahead of everything else), then calls done(ok).
function Prices.Refresh(itemID, done)
    ns.Queue.Add({
        commodity = itemID,
        onResult = function() store(itemID) ns.Fire("SALVAGER_PRICES", Prices.done, Prices.total) done(true) end,
        onFail = function() done(false) end,
    }, true)
end

--- Fills the price history from what the addon already knows from before it kept one: the price of each
--- material at its last scan, the prices written in the log, the material prices at each disenchant, and
--- the prices of your own posts (1 copper under the lowest listing of that moment). Runs once.
--- @return number  observations found
function Prices.SeedHistory()
    local db = ns.db
    if db.historySeeded then return 0 end
    db.historySeeded = true
    local points = {}
    local function add(id, t, p, lo, n)
        if Data.MATERIAL_BY_ID[id] and t and p and p > 0 then
            points[#points + 1] = { id = id, t = t, p = math.floor(p + 0.5), lo = lo, n = n }
        end
    end
    for id, e in pairs(db.prices) do add(id, e.t, e.p, e.lo) end
    -- The log has the time of day only, newest last: walk back from now and step a day at each wrap.
    local at = date("*t", time())
    local limit = time()
    for i = #db.log, 1, -1 do
        local h, m, sec, id, money = db.log[i]:match("^(%d%d):(%d%d):(%d%d) price .- %((%d+)%): (.-) over %d+ units")
        local hh, mm, ss = db.log[i]:match("^(%d%d):(%d%d):(%d%d) ")
        if hh then
            at.hour, at.min, at.sec = tonumber(hh), tonumber(mm), tonumber(ss)
            local t = time(at)
            while t > limit + 60 do
                t = t - 86400
                at = date("*t", t)
            end
            limit = t
            if h and sec and m then add(tonumber(id), t, ns.Util.ParseMoney(money)) end
        end
    end
    local keep = 1 - ns.Cut()
    for _, r in ipairs(db.ledger.disenchants) do
        for id, qty in pairs(r.got or {}) do
            local v = r.vals and r.vals[id]
            if v and qty > 0 then add(id, r.t, v / qty / keep) end
        end
    end
    for _, post in ipairs(db.posted or {}) do add(post.itemID, post.t, post.each + 1, post.each + 1) end
    ns.History.Merge(db.history, points)
    ns.Log("price history: filled with %d earlier observations", #points)
    return #points
end
ns.On("SALVAGER_READY", function()
    local ok, err = pcall(Prices.SeedHistory)
    if not ok then ns.Log("ERROR filling the price history: %s", tostring(err)) end
end)

--- Age in seconds of the oldest material price; math.huge when a material was never scanned.
function Prices.OldestAge()
    local oldest = 0
    for _, m in ipairs(Data.MATERIALS) do
        local e = ns.db.prices[m.id]
        if not (e and e.t) then return math.huge end
        oldest = math.max(oldest, time() - e.t)
    end
    return oldest
end

--- Age in seconds of a material's price, or nil.
function Prices.Age(itemID)
    local e = ns.db.prices[itemID]
    return e and e.t and (time() - e.t) or nil
end

ns.On("AUCTION_HOUSE_CLOSED", function() Prices.scanning = false end)

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

--- Is an item sold as a commodity (one price list per item) or as single auctions? The game's answer when it has one
--- (C_AuctionHouse.GetItemKeyInfo), else what Data says (SDD 128); a disagreement is logged once.
local commoditySaid = {}
function Prices.IsCommodity(itemID)
    local x = Data.SALVAGER_ITEM_BY_ID[itemID]
    local default = Data.MATERIAL_BY_ID[itemID] ~= nil or (x and x.commodity) or false
    local ok, info = pcall(function() return AH.GetItemKeyInfo and AH.GetItemKeyInfo(AH.MakeItemKey(itemID, 0, 0, 0)) end)
    if not (ok and type(info) == "table" and info.isCommodity ~= nil) then return default end
    if info.isCommodity ~= default and not commoditySaid[itemID] then
        commoditySaid[itemID] = true
        ns.Log("WARN", "scan", string.format("%s is %s, not %s as the addon had it", ns.MaterialName(itemID),
            info.isCommodity and "a commodity" or "sold as single auctions", default and "a commodity" or "single auctions"),
            { item = itemID, commodity = info.isCommodity and true or false })
    end
    return info.isCommodity and true or false
end

--- The cheapest buyout each in the client's current item search results of a non-commodity (your own left out).
--- @return table|nil { p, units, listings, lo, auctionID, buyout, qty } (the cheapest auction)
function Prices.ReadItem(itemID)
    local key = AH.MakeItemKey(itemID, 0, 0, 0)
    local best, units, listings = nil, 0, 0
    for i = 1, (AH.GetNumItemSearchResults(key) or 0) do
        local r = AH.GetItemSearchResultInfo(key, i)
        if r and r.buyoutAmount and r.buyoutAmount > 0 and not r.containsOwnerItem then
            local qty = math.max(1, r.quantity or 1)
            local each = math.floor(r.buyoutAmount / qty + 0.5)
            units, listings = units + qty, listings + 1
            if not best or each < best.each then
                best = { each = each, auctionID = r.auctionID, buyout = r.buyoutAmount, qty = qty }
            end
        end
    end
    if not best then return nil end
    return { p = best.each, units = units, listings = listings, lo = best.each, auctionID = best.auctionID,
        buyout = best.buyout, qty = best.qty }
end

local function store(itemID)
    local commodity = Prices.IsCommodity(itemID)
    local e
    if commodity then
        e = Prices.ReadCommodity(itemID, ns.db.settings.priceUnits)
    else
        e = Prices.ReadItem(itemID)
        if e then e.auctionID, e.buyout, e.qty = nil, nil, nil end
    end
    local results = commodity and (AH.GetNumCommoditySearchResults(itemID) or 0) or (e and e.listings or 0)
    ns.Log("DEBUG", "scan", string.format("price %s: %s, %d results", ns.MaterialName(itemID),
        e and (ns.Money(e.p) .. (commodity and (" over " .. e.units .. " units") or " the cheapest buyout each"))
            or "none listed", results),
        { item = itemID, price = e and e.p, units = e and e.units, lowest = e and e.lo, results = results,
            commodity = commodity })
    -- The ceiling comes from the history before this scan, so a spike now does not raise it.
    local cap = e and ns.History.Ceiling(ns.db.history, itemID, time(), e.units)
    if e and cap and e.p > cap then
        ns.Log("WARN", "scan", string.format("price %s: %s over %d units is far over its recent prices: valued at %s at "
            .. "most", ns.MaterialName(itemID), ns.Money(e.p), e.units, ns.Money(cap)), { item = itemID, price = e.p,
            units = e.units, cap = cap })
    end
    -- For the charts: this scan's price, lowest listing and units listed by others.
    local listed = 0
    if commodity then
        for i = 1, (AH.GetNumCommoditySearchResults(itemID) or 0) do
            local r = AH.GetCommoditySearchResultInfo(itemID, i)
            if r then listed = listed + math.max(0, (r.quantity or 0) - (r.numOwnerItems or 0)) end
        end
    else
        listed = e and e.units or 0
    end
    ns.History.Add(ns.db.history, itemID, time(), e and e.p, e and e.lo, listed)
    -- Who lists under your auctions of it (every material search comes here: SDD 109).
    if commodity then
        local ok, err = pcall(ns.Listings.Observe, itemID)
        if not ok then
            ns.Log("ERROR", "competition", string.format("Lua error reading the sellers of %s: %s",
                ns.MaterialName(itemID), tostring(err)), { item = itemID })
        end
    end
    if e then
        e.t, e.cap = time(), cap
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
        ns.Defer("prices", function() return ns.Scanner.state == "idle" end, Prices.Scan, "The material scan",
            "the gear scan is done")
        return
    end
    if ns.Listings and ns.Listings.checking then
        ns.Defer("prices", function() return not ns.Listings.checking end, function() Prices.Scan(ids) end,
            "The material scan", "the undercut check is done")
        return
    end
    if not ids then
        -- Every material, then the Arcane Salvager tab's items that are not materials (SDD 128).
        ids = {}
        for _, m in ipairs(Data.MATERIALS) do ids[#ids + 1] = m.id end
        for _, x in ipairs(Data.SALVAGER_ITEMS) do
            if x.auction ~= false and not Data.MATERIAL_BY_ID[x.id] then ids[#ids + 1] = x.id end
        end
    elseif #ids == 0 then
        ns.Print("no disenchanting material in your bags")
        return
    end
    Prices.scanning, Prices.done, Prices.total = true, 0, #ids
    ns.Log("INFO", "scan", string.format("material scan started (%d materials)", #ids), { materials = #ids })
    for _, id in ipairs(ids) do
        ns.Queue.Add(Prices.Task(id, function() store(id) stepDone() end, function() stepDone() end))
    end
    ns.Fire("SALVAGER_PRICES", 0, Prices.total)
end

--- The search of an item's prices for the queue: a commodity search, or an item search for a non-commodity.
function Prices.Task(itemID, onResult, onFail)
    local task = { onResult = onResult, onFail = onFail }
    if Prices.IsCommodity(itemID) then task.commodity = itemID else task.itemKey = AH.MakeItemKey(itemID, 0, 0, 0) end
    return task
end

--- Searches the Arcane Salvager tab's items that the auction house sells (its Scan button, SDD 128).
function Prices.ScanSalvager()
    local ids = {}
    for _, x in ipairs(Data.SALVAGER_ITEMS) do
        if x.auction ~= false then ids[#ids + 1] = x.id end
    end
    Prices.Scan(ids)
end

--- Searches one material (or an Arcane Salvager item) now, ahead of everything else, then calls done(ok).
--- `forBuy` = for a Buy click (Buy.lua): past the hold that buying puts on every other request.
function Prices.Refresh(itemID, done, forBuy)
    local task = Prices.Task(itemID,
        function() store(itemID) ns.Fire("SALVAGER_PRICES", Prices.done, Prices.total) done(true) end,
        function() done(false) end)
    task.forBuy = forBuy
    ns.Queue.Add(task, true)
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
    -- The log's price records (the old text lines, turned into records with their time, keep their text).
    for _, rec in ipairs(ns.LogBook.Records()) do
        local kv = rec.kv
        if kv and kv.price and rec.msg:find("^price ") then
            add(kv.item, rec.t, kv.price, kv.lowest)
        else
            local id, money = rec.msg:match("^price .- %((%d+)%): (.-) over %d+ units")
            if id then add(tonumber(id), rec.t, ns.Util.ParseMoney(money)) end
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
    ns.Log("INFO", "scan", string.format("price history: filled with %d earlier observations", #points),
        { observations = #points })
    return #points
end
ns.On("SALVAGER_READY", function()
    local ok, err = pcall(Prices.SeedHistory)
    if not ok then ns.Log("ERROR", "scan", "Lua error filling the price history: " .. tostring(err)) end
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

--- The Arcane Salvager tab's statement (SDD 128, Craft.Summary): the recipe known or not, the cost to craft one (the
--- stock's average cost when you hold enough, else the price now), craft or buy, the profit per craft and per stack,
--- the Blueprint's payback.
function Prices.Salvager()
    local L = ns.db.ledger
    return ns.Craft.Summary({
        priceOf = ns.PriceOf,
        avgCostOf = function(id) return ns.Ledger.AvgCost(L, id) end,
        knownOf = function(id) return ns.Ledger.KnownQty(L, id) end,
        cut = ns.Cut(),
        known = IsPlayerSpell and IsPlayerSpell(Data.SALVAGER_RECIPE_SPELL) or false,
    })
end

--- "Highest at" (`mode` "high") or "Lowest at" ("low") of an item (History.BestTime), on the Times option's clock.
function Prices.BestTime(itemID, mode)
    local function hourOf(t) return tonumber(ns.Date("%H", t)) end
    local function dayOf(t) return tonumber(ns.Date("%Y%j", t)) end
    return ns.History.BestTime(ns.db.history, itemID, time(), hourOf, mode, dayOf)
end

--- Age in seconds of a material's price, or nil.
function Prices.Age(itemID)
    local e = ns.db.prices[itemID]
    return e and e.t and (time() - e.t) or nil
end

ns.On("AUCTION_HOUSE_CLOSED", function() Prices.scanning = false end)

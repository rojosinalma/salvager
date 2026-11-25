-- Salvager: one-at-a-time queue for auction house searches.
-- The server takes about one search every 0.7 s (IsThrottledMessageSystemReady).
-- A second SendSearchQuery for an item the client already holds results for
-- never answers, so those are refreshed instead.
local _, ns = ...

local AH = C_AuctionHouse
local Queue = { items = {}, current = nil, open = false }
ns.Queue = Queue

local REPLY_TIMEOUT = 3     -- seconds to wait for an answer
local STUCK_WAIT = 1.5      -- seconds of "not ready" before sending anyway
local CACHE_GAP = 0.1       -- an answer this soon after a refresh is the client's cache

local COMMODITY_SORTS = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }
local ITEM_SORTS = {
    { sortOrder = Enum.AuctionHouseSortOrder.Buyout, reverseSort = false },
    { sortOrder = Enum.AuctionHouseSortOrder.Bid, reverseSort = false },
}

local notReadySince

local function ready()
    if not AH.IsThrottledMessageSystemReady or AH.IsThrottledMessageSystemReady() then
        notReadySince = nil
        return true
    end
    local t = GetTime()
    notReadySince = notReadySince or t
    if t - notReadySince >= STUCK_WAIT then
        notReadySince = t
        return true
    end
    return false
end

--- Adds a search. task = { commodity = itemID } or { itemKey = key }, plus
--- onResult(task) and onFail(task). Duplicates of a queued task are dropped.
function Queue.Add(task)
    for _, t in ipairs(Queue.items) do
        if (task.commodity and t.commodity == task.commodity)
            or (task.itemKey and t.itemKey and ns.KeyString(t.itemKey) == ns.KeyString(task.itemKey)) then
            return
        end
    end
    table.insert(Queue.items, task)
end

function Queue.Clear()
    wipe(Queue.items)
    Queue.current = nil
end

--- Holds the queue: nothing new goes out until resumed. An answer already on its way still counts.
function Queue.SetPaused(on)
    Queue.paused = on and true or false
    if Queue.current then Queue.current.sentAt = GetTime() end
end

function Queue.Pending()
    return #Queue.items + (Queue.current and 1 or 0)
end

function ns.KeyString(key)
    return string.format("%d:%d:%d", key.itemID or 0, key.itemLevel or 0, key.itemSuffix or 0)
end

local function describe(task)
    return task.commodity and ("commodity " .. task.commodity) or ("item " .. ns.KeyString(task.itemKey))
end

local function send(task)
    task.sentAt = GetTime()
    task.refreshed = false
    if task.commodity then
        local key = AH.MakeItemKey(task.commodity, 0, 0, 0)
        if AH.HasSearchResults(key) then
            task.refreshed = true
            AH.RefreshCommoditySearchResults(task.commodity)
        else
            AH.SendSearchQuery(key, COMMODITY_SORTS, true)
        end
    else
        if AH.HasSearchResults(task.itemKey) then
            task.refreshed = true
            AH.RefreshItemSearchResults(task.itemKey)
        else
            AH.SendSearchQuery(task.itemKey, ITEM_SORTS, true)
        end
    end
end

local function finish(ok)
    local task = Queue.current
    Queue.current = nil
    if not task then return end
    if not ok then
        ns.Log("search: no answer for %s after %.1fs%s", describe(task), GetTime() - task.sentAt,
            (task.tries or 0) < 1 and ", trying again" or ", skipped")
        if (task.tries or 0) < 1 then
            task.tries = (task.tries or 0) + 1
            table.insert(Queue.items, task)
            return
        end
    end
    local fn = ok and task.onResult or task.onFail
    if fn then
        local good, err = pcall(fn, task)
        if not good then
            ns.Print("search result error: %s", tostring(err))
            ns.Log("ERROR reading %s: %s", describe(task), tostring(err))
        end
    end
end

local function pump()
    if not Queue.open or Queue.paused then return end
    local task = Queue.current
    if task then
        if GetTime() - task.sentAt >= REPLY_TIMEOUT then
            -- A refresh that only gave the cached answer: use what the client has.
            finish(task.refreshed)
        end
        return
    end
    if #Queue.items == 0 or not ready() then return end
    Queue.current = table.remove(Queue.items, 1)
    local ok, err = pcall(send, Queue.current)
    if not ok then
        ns.Print("search failed: %s", tostring(err))
        ns.Log("ERROR sending %s: %s", describe(Queue.current), tostring(err))
        finish(false)
    end
end

local function answered(match)
    local task = Queue.current
    if not task or not match(task) then return end
    if task.refreshed and GetTime() - task.sentAt < CACHE_GAP then return end
    finish(true)
end

ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    answered(function(t) return t.commodity == itemID end)
end)
ns.On("ITEM_SEARCH_RESULTS_UPDATED", function(key)
    answered(function(t) return t.itemKey and key and t.itemKey.itemID == key.itemID end)
end)
ns.On("AUCTION_HOUSE_SHOW", function()
    Queue.open = true
    ns.Log("auction house opened")
end)
ns.On("AUCTION_HOUSE_CLOSED", function()
    Queue.open = false
    Queue.paused = false
    Queue.Clear()
end)

local elapsedSum = 0
ns.eventFrame:SetScript("OnUpdate", function(_, elapsed)
    elapsedSum = elapsedSum + elapsed
    if elapsedSum < 0.1 then return end
    elapsedSum = 0
    pump()
end)

-- Salvager: one-at-a-time queue for auction house searches.
-- The server takes about one search every 0.7 s (IsThrottledMessageSystemReady).
-- A second SendSearchQuery for an item the client already holds results for
-- never answers, so those are refreshed instead.
local _, ns = ...

local AH = C_AuctionHouse
local Queue = { items = {}, current = nil, open = false, lost = 0, late = 0 }
ns.Queue = Queue

local REPLY_TIMEOUT = 2     -- seconds to wait for an answer (one normally comes in about 0.3 s)
local MAX_TRIES = 2         -- times a search is sent again after no answer
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
--- With `urgent`, the task goes first and is sent even while the queue is paused
--- (something the player just clicked).
function Queue.Add(task, urgent)
    for i, t in ipairs(Queue.items) do
        if (task.commodity and t.commodity == task.commodity)
            or (task.itemKey and t.itemKey and ns.KeyString(t.itemKey) == ns.KeyString(task.itemKey)) then
            if not urgent then return end
            table.remove(Queue.items, i)
            break
        end
    end
    if urgent then
        task.urgent = true
        table.insert(Queue.items, 1, task)
    else
        table.insert(Queue.items, task)
    end
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
        Queue.lost = Queue.lost + 1
        local again = (task.tries or 0) < MAX_TRIES
        ns.Log("search: no answer for %s after %.1fs%s", describe(task), GetTime() - task.sentAt,
            again and ", trying again" or ", skipped (another addon may be using the auction house)")
        if again then
            task.tries = (task.tries or 0) + 1
            -- Next in line: the item stays in its place among the best candidates.
            table.insert(Queue.items, 1, task)
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

--- Does the client hold results for this task now?
local function hasResults(task)
    if task.commodity then return (AH.GetNumCommoditySearchResults(task.commodity) or 0) > 0 end
    return AH.HasSearchResults(task.itemKey) and true or false
end

local function pump()
    if not Queue.open then return end
    if Queue.paused and not (Queue.current or (Queue.items[1] and Queue.items[1].urgent)) then return end
    local task = Queue.current
    if task then
        if GetTime() - task.sentAt >= REPLY_TIMEOUT then
            if task.refreshed then
                -- A refresh that only gave the cached answer: use what the client has.
                Queue.late = Queue.late + 1
                ns.Log("search: the refresh of %s got no new answer in %.0fs, using what the game holds",
                    describe(task), REPLY_TIMEOUT)
                finish(true)
            elseif hasResults(task) then
                -- The answer came, but not the event that announces it.
                Queue.late = Queue.late + 1
                ns.Log("search: %s was answered without its event, using the results", describe(task))
                finish(true)
            else
                finish(false)
            end
        end
        return
    end
    if #Queue.items == 0 then return end
    -- A search sent while the gear browse loads its pages makes the auction house drop a page:
    -- searches wait for the browse, except one the player just asked for.
    if ns.Scanner and ns.Scanner.state == "browsing" and not Queue.items[1].urgent then return end
    if not ready() then return end
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

local function commodityAnswer(itemID)
    answered(function(t) return t.commodity == itemID end)
end
local function itemAnswer(key)
    answered(function(t) return t.itemKey and type(key) == "table" and t.itemKey.itemID == key.itemID end)
end
ns.On("COMMODITY_SEARCH_RESULTS_UPDATED", commodityAnswer)
ns.On("COMMODITY_SEARCH_RESULTS_ADDED", commodityAnswer)
ns.On("ITEM_SEARCH_RESULTS_UPDATED", itemAnswer)
ns.On("ITEM_SEARCH_RESULTS_ADDED", itemAnswer)
-- The auction house takes one request at a time from all addons together. When two arrive close
-- to each other it throws one away and says so, without saying which. If one of ours went out a
-- moment ago, it is sent again as soon as the auction house is ready, instead of waiting 3 s for
-- an answer that will not come.
local MAX_RESENDS = 3
ns.On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
    local task = Queue.current
    if not task or GetTime() - task.sentAt > 2 or (task.resends or 0) >= MAX_RESENDS then return end
    task.resends = (task.resends or 0) + 1
    Queue.dropped = (Queue.dropped or 0) + 1
    ns.Log("search: the auction house dropped %s (busy with another request), sending it again (%d of %d)",
        describe(task), task.resends, MAX_RESENDS)
    Queue.current = nil
    table.insert(Queue.items, 1, task)
end)
ns.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() pump() end)

ns.On("AUCTION_HOUSE_SHOW", function()
    Queue.open = true
    ns.Log("auction house opened")
end)
ns.On("AUCTION_HOUSE_CLOSED", function()
    Queue.open = false
    Queue.paused = false
    Queue.Clear()
end)

ns.OnTick(pump)

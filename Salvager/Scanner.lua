-- Salvager: gear scan and deals.
-- 1. One browse query lists every matching item with its lowest price (fast, not throttled).
-- 2. Items whose lowest price is under their disenchant value get an item search,
--    which lists each auction. Every auction under the buy limit becomes a deal.
local _, ns = ...

local AH = C_AuctionHouse


local Scanner = { state = "idle", deals = {}, checked = 0, toCheck = 0, browsed = 0, auto = false, summary = nil }
ns.Scanner = Scanner

local MAX_PAGES = 50
local BROWSE_STALL = 6     -- seconds without a browse page before carrying on
local lastBrowseAt = 0
local watchBrowse          -- (defined below)
local ourSend = false
local pages = 0
local results = {}

local function qualityFilters()
    local f, q = {}, ns.db.settings.qualities
    if q[2] then f[#f + 1] = Enum.AuctionHouseFilter.UncommonQuality end
    if q[3] then f[#f + 1] = Enum.AuctionHouseFilter.RareQuality end
    if q[4] then f[#f + 1] = Enum.AuctionHouseFilter.EpicQuality end
    return f
end

local function onlyQuality()
    local only
    for q, on in pairs(ns.db.settings.qualities) do
        if on then
            if only then return nil end
            only = q
        end
    end
    return only
end

local function setState(s)
    Scanner.state = s
    ns.Fire("SALVAGER_SCAN")
end

local function sortDeals()
    table.sort(Scanner.deals, function(a, b) return a.profit > b.profit end)
end

--- Value of an item key, using the scan's quality when the client has none yet.
local function keyValue(key)
    local info = AH.GetItemKeyInfo(key)
    local quality = (info and info.quality) or ns.QualityOf(key.itemID) or onlyQuality()
    local classID = ns.ClassOf(key.itemID)
    if classID and not ns.GearClasses()[classID] then return nil end
    local ilvl = (key.itemLevel and key.itemLevel > 0) and key.itemLevel or ns.ItemLevelOf(key.itemID)
    if not (quality and classID and ilvl) then return nil end
    local v, outcomes = ns.ItemValue(key.itemID, ilvl, quality, classID)
    if not v or ns.MissingMajor(v, outcomes) then return nil end
    return v, ilvl, quality, classID, outcomes, ns.BuyLimit(quality, classID, outcomes.band, v.net)
end

local function readAuctions(task)
    local key, v = task.itemKey, task.value
    local maxBuy = task.limit
    -- Drop the old rows of this item, then add what is listed now.
    for i = #Scanner.deals, 1, -1 do
        if Scanner.deals[i].keyString == task.keyString and not Scanner.deals[i].pending then
            table.remove(Scanner.deals, i)
        end
    end
    local n = AH.GetNumItemSearchResults(key) or 0
    local before = #Scanner.deals
    for i = 1, n do
        local r = AH.GetItemSearchResultInfo(key, i)
        if r and r.buyoutAmount and r.buyoutAmount > 0 and not r.containsOwnerItem and r.buyoutAmount <= maxBuy then
            Scanner.deals[#Scanner.deals + 1] = {
                auctionID = r.auctionID, itemKey = key, keyString = task.keyString,
                link = r.itemLink, itemID = key.itemID, ilvl = task.ilvl, quality = task.quality, classID = task.classID,
                buyout = r.buyoutAmount, value = v.net, profit = v.net - r.buyoutAmount,
            }
        end
    end
    ns.Log("checked %s: %d auctions, %d under %s", task.keyString, n, #Scanner.deals - before, ns.Money(maxBuy))
    sortDeals()
end

local function scheduleNext()
    if not Scanner.auto then return end
    C_Timer.After(ns.db.settings.autoInterval, function()
        if Scanner.auto and Scanner.state == "idle" and ns.Queue.open then Scanner.Scan() end
    end)
end

local function checkDone()
    Scanner.checked = Scanner.checked + 1
    ns.Fire("SALVAGER_DEALS")
    if Scanner.checked >= Scanner.toCheck then
        setState("idle")
        scheduleNext()
    end
end

local function evaluate()
    setState("checking")
    Scanner.toCheck, Scanner.checked = 0, 0
    local minProfit = ns.db.settings.minProfit
    local candidates = {}
    local sum = { browsed = #results, valued = 0, noValue = 0, noPrice = 0, candidates = 0, best = nil }
    for _, r in ipairs(results) do
        local key = r.itemKey
        if key and r.minPrice and r.minPrice > 0 then
            local v, ilvl, quality, classID, _, limit = keyValue(key)
            if v then
                sum.valued = sum.valued + 1
                local margin = v.net - r.minPrice
                if not sum.best or margin > sum.best.margin then
                    sum.best = { margin = margin, itemID = key.itemID, ilvl = ilvl, price = r.minPrice, value = v.net }
                end
                if r.minPrice <= limit then
                    candidates[#candidates + 1] = { key = key, v = v, ilvl = ilvl, quality = quality, classID = classID,
                        margin = margin, limit = limit }
                end
            else
                sum.noValue = sum.noValue + 1
            end
        else
            sum.noPrice = sum.noPrice + 1
        end
    end
    sum.candidates = #candidates
    Scanner.summary = sum
    ns.Log("gear scan: %d items browsed, %d valued, %d without a value, %d without a buyout, %d under the limit (min profit %s)",
        sum.browsed, sum.valued, sum.noValue, sum.noPrice, sum.candidates, ns.Money(minProfit))
    if sum.best then
        ns.Log("closest: item %d ilvl %s at %s, value %s, margin %s", sum.best.itemID, tostring(sum.best.ilvl),
            ns.Money(sum.best.price), ns.Money(sum.best.value), ns.Money(sum.best.margin))
    end
    table.sort(candidates, function(a, b) return a.margin > b.margin end)
    -- Each item search takes about 0.7 s: check the best ones first, at most maxChecks.
    for i = #candidates, ns.db.settings.maxChecks + 1, -1 do candidates[i] = nil end
    -- Rows of items no longer under the limit are stale.
    local live = {}
    for _, c in ipairs(candidates) do live[ns.KeyString(c.key)] = true end
    for i = #Scanner.deals, 1, -1 do
        if not live[Scanner.deals[i].keyString] and not Scanner.deals[i].pending then table.remove(Scanner.deals, i) end
    end
    Scanner.toCheck = #candidates
    for _, c in ipairs(candidates) do
        ns.Queue.Add({
            itemKey = c.key, keyString = ns.KeyString(c.key), value = c.v, ilvl = c.ilvl, quality = c.quality,
            classID = c.classID, limit = c.limit,
            onResult = function(task) readAuctions(task) checkDone() end,
            onFail = function() checkDone() end,
        })
    end
    if #candidates == 0 then
        Scanner.toCheck = 1
        checkDone()
    end
end

--- Starts a gear scan. Needs the auction house open and material prices.
function Scanner.Scan()
    if not ns.Queue.open then ns.Print("open the auction house first") return end
    if Scanner.state ~= "idle" then return end
    if ns.Prices.scanning then
        ns.Print("wait for the material scan to finish")
        return
    end
    if not next(ns.db.prices) then ns.Print("scan material prices first") return end
    local s = ns.db.settings
    local query = {
        searchString = "",
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } },
        filters = qualityFilters(),
        itemClassFilters = {},
    }
    for classID, on in pairs(ns.GearClasses()) do
        if on then table.insert(query.itemClassFilters, { classID = classID }) end
    end
    if s.minLevel > 0 then query.minLevel = s.minLevel end
    if s.maxLevel > 0 then query.maxLevel = s.maxLevel end
    results, pages = {}, 0
    lastBrowseAt = GetTime()
    Scanner.browseSeq = (Scanner.browseSeq or 0) + 1
    watchBrowse(Scanner.browseSeq)
    ns.Log("gear scan started: levels %d-%d, %d quality filters", s.minLevel, s.maxLevel, #query.filters)
    setState("browsing")
    ourSend = true
    local ok, err = pcall(AH.SendBrowseQuery, query)
    ourSend = false
    if not ok then
        ns.Print("browse failed: %s", tostring(err))
        ns.Log("ERROR browse: %s", tostring(err))
        setState("idle")
    end
end

function Scanner.SetAuto(on)
    Scanner.auto = on and true or false
    if Scanner.auto and Scanner.state == "idle" then Scanner.Scan() end
    ns.Fire("SALVAGER_SCAN")
end

-- A browse page that never comes: carry on with the pages that did.
function watchBrowse(seq)
    C_Timer.After(BROWSE_STALL, function()
        if Scanner.state ~= "browsing" or Scanner.browseSeq ~= seq then return end
        if GetTime() - lastBrowseAt < BROWSE_STALL then watchBrowse(seq) return end
        ns.Log("browse: no page for %ds, using the %d items received", BROWSE_STALL, #results)
        if #results > 0 then evaluate() else setState("idle") scheduleNext() end
    end)
end

local function onBrowse()
    if Scanner.state ~= "browsing" then return end
    lastBrowseAt = GetTime()
    results = AH.GetBrowseResults() or {}
    Scanner.browsed = #results
    ns.Log("browse page %d: %d items so far, %s", pages + 1, #results,
        AH.HasFullBrowseResults() and "last page" or "more pages to come")
    if not AH.HasFullBrowseResults() and pages < MAX_PAGES then
        pages = pages + 1
        AH.RequestMoreBrowseResults()
        ns.Fire("SALVAGER_SCAN")
        return
    end
    evaluate()
end

ns.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", onBrowse)
ns.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", onBrowse)
ns.On("AUCTION_HOUSE_BROWSE_FAILURE", function()
    if Scanner.state == "browsing" then
        ns.Print("the auction house did not answer the browse; try again")
        ns.Log("browse failure event")
        setState("idle")
        scheduleNext()
    end
end)

-- Another window's browse replaces our results: stop and let auto mode retry.
if hooksecurefunc then
    hooksecurefunc(AH, "SendBrowseQuery", function()
        if not ourSend and Scanner.state == "browsing" then
            setState("idle")
            scheduleNext()
        end
    end)
end

ns.On("AUCTION_HOUSE_CLOSED", function()
    Scanner.auto = false
    Scanner.state = "idle"
    wipe(Scanner.deals)
end)

------------------------------------------------------------------ buying

--- Buys a deal. Must run from a click (the server needs a hardware event).
function Scanner.Buy(deal)
    if deal.pending then return end
    if GetMoney() < deal.buyout then ns.Print("not enough money for %s", deal.link or "this item") return end
    deal.pending = true
    Scanner.buying = deal
    AH.PlaceBid(deal.auctionID, deal.buyout)
    ns.Fire("SALVAGER_DEALS")
end

local function removeDeal(auctionID)
    for i = #Scanner.deals, 1, -1 do
        if Scanner.deals[i].auctionID == auctionID then table.remove(Scanner.deals, i) end
    end
end

ns.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
    local d = Scanner.buying
    if d and d.auctionID == auctionID then
        ns.Print("bought %s for %s (expected profit %s)", d.link or "item", ns.Money(d.buyout), ns.Money(d.profit))
        Scanner.buying = nil
    end
    removeDeal(auctionID)
    ns.Fire("SALVAGER_DEALS")
end)

ns.On("AUCTION_HOUSE_SHOW_ERROR", function()
    local d = Scanner.buying
    if d then
        d.pending = false
        removeDeal(d.auctionID)
        Scanner.buying = nil
        ns.Print("could not buy %s (sold or changed)", d.link or "item")
        ns.Fire("SALVAGER_DEALS")
    end
end)

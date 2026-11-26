-- Salvager: gear scan and deals.
-- 1. Browse: one query per quality and gear type lists every matching item with its lowest
--    price. Each page is judged as it arrives, from data that came with it: no item lookups.
--    (The auction house does not return these in price order, so every page is read.)
-- 2. Check: items whose lowest price is under their buy limit get an item search, which lists
--    each auction. Every auction under the limit becomes a deal.
local _, ns = ...

local AH = C_AuctionHouse
local Data = ns.Data

local Scanner = { state = "idle", deals = {}, checked = 0, toCheck = 0, browsed = 0, auto = false, summary = nil }
ns.Scanner = Scanner

local MAX_PAGES = 80       -- pages of 500 per pass
local BROWSE_STALL = 4     -- seconds without a browse page before asking again
local STALL_RETRIES = 2    -- times a page is asked for again before the pass is given up
local QUALITY_FILTER = {
    [2] = Enum.AuctionHouseFilter.UncommonQuality, [3] = Enum.AuctionHouseFilter.RareQuality,
    [4] = Enum.AuctionHouseFilter.EpicQuality,
}
local QUALITY_NAME = { [2] = "uncommon", [3] = "rare", [4] = "epic" }
local CLASS_NAME = { [Data.CLASS_WEAPON] = "weapons", [Data.CLASS_ARMOR] = "armor" }

local scan                 -- the scan in progress: { seq, passes, index, pass, candidates, seen, sum }
local lastBrowseAt = 0
local ourSend = false
local pendingBuys = {}     -- [auctionID] = deal, purchases on their way

local function setState(s)
    Scanner.state = s
    ns.Fire("SALVAGER_SCAN")
end

local function sortDeals()
    table.sort(Scanner.deals, function(a, b) return a.profit > b.profit end)
end

local function readAuctions(task)
    local key = task.itemKey
    local maxBuy = task.limit
    -- Drop the old rows of this item, then add what is listed now.
    for i = #Scanner.deals, 1, -1 do
        if Scanner.deals[i].keyString == task.keyString and not Scanner.deals[i].pending then
            table.remove(Scanner.deals, i)
        end
    end
    local n = AH.GetNumItemSearchResults(key) or 0
    local before = #Scanner.deals
    local outcomes = ns.Model.Outcomes(task.quality, task.classID, task.ilvl)
    local s = ns.db.settings
    local odds = { salvager = ns.SalvagerForBuy(), salvagerChance = s.salvagerChance, cut = s.cut }
    for i = 1, n do
        local r = AH.GetItemSearchResultInfo(key, i)
        if r and r.buyoutAmount and r.buyoutAmount > 0 and not r.containsOwnerItem and r.buyoutAmount <= maxBuy then
            Scanner.deals[#Scanner.deals + 1] = {
                auctionID = r.auctionID, itemKey = key, keyString = task.keyString,
                link = r.itemLink, itemID = key.itemID, ilvl = task.ilvl, quality = task.quality, classID = task.classID,
                buyout = r.buyoutAmount, value = task.net, profit = task.net - r.buyoutAmount, task = task,
                lose = outcomes and ns.Model.LossChance(outcomes, ns.PriceOf, odds, r.buyoutAmount) or nil,
            }
        end
    end
    ns.Log("checked item %s: %d auctions, %d under %s", task.keyString, n, #Scanner.deals - before, ns.Money(maxBuy))
    sortDeals()
end

--- One round of Play: the material prices first when they are older than the setting, then the gear.
local function startCycle(clear)
    local every = ns.db.settings.priceRescan
    local age = ns.Prices.OldestAge()
    if every > 0 and age >= every * 60 and not ns.Busy() then
        ns.Log("material prices are %s old (limit %d min): scanning them first",
            age == math.huge and "missing or" or (math.floor(age / 60) .. " min"), every)
        ns.ScanBoth(clear)
    else
        Scanner.Scan(clear)
    end
end

local function scheduleNext()
    if not Scanner.auto then return end
    C_Timer.After(ns.db.settings.autoInterval, function()
        if Scanner.auto and not Scanner.paused and Scanner.state == "idle" and ns.Queue.open
            and not ns.Prices.scanning then
            startCycle()
        end
    end)
end

local function checkDone()
    Scanner.checked = Scanner.checked + 1
    ns.Fire("SALVAGER_DEALS")
    if Scanner.checked >= Scanner.toCheck then
        ns.Log("gear checks done: %d items in %.0fs; %d searches got no answer and were sent again, %d used the game's "
            .. "held results", Scanner.toCheck, GetTime() - (Scanner.checksAt or GetTime()), ns.Queue.lost, ns.Queue.late)
        setState("idle")
        scheduleNext()
    end
end

------------------------------------------------------------------ the plan

--- What one scan looks for, worked out once: for each quality and gear type, the value and
--- buy limit of every item level band, and the passes to browse.
local function buildPlan()
    local s = ns.db.settings
    local classes = ns.GearClasses()
    local cap = s.maxPrice > 0 and s.maxPrice or math.huge
    local bands = {}
    for _, row in ipairs(ns.Limits()) do
        bands[row.quality] = bands[row.quality] or { [Data.CLASS_ARMOR] = {}, [Data.CLASS_WEAPON] = {} }
        for classID, x in pairs({ [Data.CLASS_ARMOR] = row.armor, [Data.CLASS_WEAPON] = row.weapon }) do
            local list = bands[row.quality][classID]
            -- Never above the most the player pays for one item.
            list[#list + 1] = { up = row.up, net = x.value, limit = math.min(x.limit, cap), blocked = x.blocked }
        end
    end
    local passes = {}
    for _, quality in ipairs({ 2, 3, 4 }) do
        for _, classID in ipairs({ Data.CLASS_ARMOR, Data.CLASS_WEAPON }) do
            if s.qualities[quality] and classes[classID] and bands[quality] then
                local top = 0
                for _, b in ipairs(bands[quality][classID]) do
                    if not b.blocked and b.limit > top then top = b.limit end
                end
                passes[#passes + 1] = { quality = quality, classID = classID, bands = bands[quality][classID], top = top,
                    name = QUALITY_NAME[quality] .. " " .. CLASS_NAME[classID], got = 0, pages = 0, breaks = 0 }
            end
        end
    end
    return passes
end

------------------------------------------------------------------ judging a page

local function judge(r, pass, sum)
    local key, price = r.itemKey, r.minPrice
    sum.browsed = sum.browsed + 1
    if not key or not price or price <= 0 then sum.noPrice = sum.noPrice + 1 return end
    if pass.lastPrice and price < pass.lastPrice then pass.breaks = pass.breaks + 1 end
    pass.lastPrice = price
    -- Cheapest test first: above the highest limit of this quality and type, it can't be a deal.
    if price > pass.top then sum.overLimit = sum.overLimit + 1 return end
    if ns.NoDisenchant(key.itemID) then sum.noDisenchant = sum.noDisenchant + 1 return end
    local ilvl, source = ns.Items.Level(key)
    if not ilvl then sum.learning = sum.learning + 1 return end
    if not ns.LevelAllowed(ilvl) then sum.levelOut = sum.levelOut + 1 return end
    if source == "cache" and (key.itemLevel or 0) > 0 and key.itemLevel ~= ilvl then
        sum.levelDiffers = sum.levelDiffers + 1
        sum.levelExample = sum.levelExample or string.format("item %d: listing says %d, the game says %d",
            key.itemID, key.itemLevel, ilvl)
    end
    local band
    for _, b in ipairs(pass.bands) do
        if ilvl <= b.up then band = b break end
    end
    if not band or band.blocked then sum.noValue = sum.noValue + 1 return end
    local margin = band.net - price
    -- The closest item is the one nearest to its buy limit (the limit is what decides, not the value).
    local room = band.limit - price
    if not sum.best or room > sum.best.room then
        local best = sum.best or {}
        best.room, best.margin, best.itemID, best.ilvl, best.price, best.value, best.limit =
            room, margin, key.itemID, ilvl, price, band.net, band.limit
        sum.best = best
    end
    if price > band.limit then sum.overLimit = sum.overLimit + 1 return end
    local keyString = ns.KeyString(key)
    if scan.seen[keyString] then return end
    scan.seen[keyString] = true
    scan.candidates[#scan.candidates + 1] = { key = key, keyString = keyString, net = band.net, limit = band.limit,
        ilvl = ilvl, quality = pass.quality, classID = pass.classID, margin = margin }
end

------------------------------------------------------------------ after the browse

local function queueChecks()
    local candidates, sum = scan.candidates, scan.sum
    sum.candidates = #candidates
    sum.seconds = GetTime() - scan.startedAt
    Scanner.summary = sum
    scan = nil
    ns.Log("gear scan: %d items in %.0fs, %d under their limit, %d over, %d not disenchantable, %d level not known yet, "
        .. "%d outside the level filter, %d without a value, %d without a buyout (min profit %s)", sum.browsed, sum.seconds,
        sum.candidates, sum.overLimit, sum.noDisenchant, sum.learning, sum.levelOut, sum.noValue, sum.noPrice,
        ns.Money(ns.db.settings.minProfit))
    if sum.best then
        ns.Log("closest: item %d ilvl %s at %s, buy limit %s, value %s, margin %s", sum.best.itemID,
            tostring(sum.best.ilvl), ns.Money(sum.best.price), ns.Money(sum.best.limit), ns.Money(sum.best.value),
            ns.Money(sum.best.margin))
    end
    if sum.levelDiffers > 0 then
        ns.Log("item levels: %d listings differ from the game's data (%s)", sum.levelDiffers, sum.levelExample)
    end
    setState("checking")
    Scanner.toCheck, Scanner.checked = 0, 0
    Scanner.checksAt = GetTime()
    ns.Queue.lost, ns.Queue.late = 0, 0
    table.sort(candidates, function(a, b) return a.margin > b.margin end)
    -- Each item search takes about 0.7 s: check the best ones first, at most maxChecks.
    for i = #candidates, ns.db.settings.maxChecks + 1, -1 do candidates[i] = nil end
    -- Rows of items that are no longer under their limit go; the others are replaced as they are checked.
    local live = {}
    for _, c in ipairs(candidates) do live[c.keyString] = true end
    for i = #Scanner.deals, 1, -1 do
        if not live[Scanner.deals[i].keyString] and not Scanner.deals[i].pending then table.remove(Scanner.deals, i) end
    end
    Scanner.toCheck = #candidates
    for _, c in ipairs(candidates) do
        ns.Queue.Add({
            itemKey = c.key, keyString = c.keyString, net = c.net, ilvl = c.ilvl, quality = c.quality,
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

------------------------------------------------------------------ browsing

local nextPass

local function finishPass(why)
    local pass = scan.pass
    ns.Log("browse %s: %d items in %d pages, %.1fs%s%s", pass.name, pass.got, pass.pages, GetTime() - pass.startedAt,
        pass.breaks > 0 and string.format(", not in price order (%d breaks)", pass.breaks) or ", in price order",
        why and (", " .. why) or "")
    nextPass()
end

--- The next step of the pass: another page, or the next pass.
local function advance()
    if Scanner.paused then scan.held = true return end
    local pass = scan.pass
    if AH.HasFullBrowseResults() then return finishPass() end
    if pass.pages >= MAX_PAGES then return finishPass("page limit reached") end
    AH.RequestMoreBrowseResults()
    scan.askedAt = GetTime()
    ns.Fire("SALVAGER_SCAN")
end

-- The auction house threw a request away just after we asked for a page: ask again at once.
ns.On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
    if not scan or Scanner.state ~= "browsing" or Scanner.paused or not scan.pass then return end
    local pass = scan.pass
    if not scan.askedAt or GetTime() - scan.askedAt > 2 or (pass.resends or 0) >= 3 then return end
    pass.resends = (pass.resends or 0) + 1
    ns.Log("browse %s: the auction house dropped the request for page %d (busy with another request), asking again",
        pass.name, pass.pages + 1)
    C_Timer.After(0.8, function()
        if scan and scan.pass == pass and Scanner.state == "browsing" and not Scanner.paused then
            lastBrowseAt = GetTime()
            scan.askedAt = GetTime()
            AH.RequestMoreBrowseResults()
        end
    end)
end)

-- A browse page that never comes: move on with the pages that did.
local function watchBrowse(seq)
    C_Timer.After(BROWSE_STALL, function()
        if not scan or Scanner.state ~= "browsing" or scan.seq ~= seq then return end
        if Scanner.paused or GetTime() - lastBrowseAt < BROWSE_STALL then watchBrowse(seq) return end
        lastBrowseAt = GetTime()
        watchBrowse(seq)
        local pass = scan.pass
        if pass and pass.pages > 0 and (pass.retries or 0) < STALL_RETRIES then
            pass.retries = (pass.retries or 0) + 1
            ns.Log("browse %s: no page for %ds after page %d, asking again (%d of %d)", pass.name, BROWSE_STALL,
                pass.pages, pass.retries, STALL_RETRIES)
            AH.RequestMoreBrowseResults()
        else
            finishPass(string.format("no page for %ds, given up", BROWSE_STALL))
        end
    end)
end

function nextPass()
    scan.index = scan.index + 1
    local pass = scan.passes[scan.index]
    if not pass then return queueChecks() end
    scan.pass = pass
    pass.startedAt = GetTime()
    Scanner.passName = pass.name
    if pass.top <= 0 then return finishPass("no buy limit above zero, skipped") end
    local s = ns.db.settings
    local query = {
        searchString = "",
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } },
        filters = { QUALITY_FILTER[pass.quality] },
        itemClassFilters = { { classID = pass.classID } },
    }
    if s.minLevel > 0 then query.minLevel = s.minLevel end
    if s.maxLevel > 0 then query.maxLevel = s.maxLevel end
    lastBrowseAt = GetTime()
    ourSend = true
    local ok, err = pcall(AH.SendBrowseQuery, query)
    ourSend = false
    if not ok then
        ns.Print("browse failed: %s", tostring(err))
        ns.Log("ERROR browse: %s", tostring(err))
        scan = nil
        setState("idle")
        scheduleNext()
        return
    end
    ns.Fire("SALVAGER_SCAN")
end

--- Empties the Deals list.
function Scanner.ClearDeals()
    wipe(Scanner.deals)
    ns.Fire("SALVAGER_DEALS")
end

--- Starts a gear scan. Needs the auction house open and material prices.
--- `clear` = asked for by a click: the Deals list starts empty and is filled again. A round that
--- Play starts by itself keeps the list and only updates it.
function Scanner.Scan(clear)
    if not ns.Queue.open then ns.Print("open the auction house first") return end
    if Scanner.state ~= "idle" then return end
    if ns.Prices.scanning then
        ns.Print("wait for the material scan to finish")
        return
    end
    if not next(ns.db.prices) then ns.Print("scan material prices first") return end
    local passes = buildPlan()
    Scanner.browseSeq = (Scanner.browseSeq or 0) + 1
    scan = {
        seq = Scanner.browseSeq, passes = passes, index = 0, candidates = {}, seen = {}, startedAt = GetTime(),
        sum = { browsed = 0, overLimit = 0, noDisenchant = 0, learning = 0, noValue = 0, noPrice = 0, candidates = 0,
            levelDiffers = 0, levelOut = 0, best = nil },
    }
    Scanner.browsed = 0
    if clear then Scanner.ClearDeals() end
    local names = {}
    for _, p in ipairs(passes) do names[#names + 1] = p.name end
    local s = ns.db.settings
    ns.Log("gear scan started: %s; levels %d-%d; min profit %s, max price %s", table.concat(names, ", "), s.minLevel,
        s.maxLevel, ns.Money(s.minProfit), s.maxPrice > 0 and ns.Money(s.maxPrice) or "none")
    setState("browsing")
    watchBrowse(scan.seq)
    nextPass()
end

--- One page of browse results. `added` = the new rows (later pages); nil = read the list (first page).
local function onPage(added)
    if not scan or Scanner.state ~= "browsing" or not scan.pass then return end
    local pass, sum = scan.pass, scan.sum
    local list, from = added, 1
    if not list then
        list = AH.GetBrowseResults() or {}
        from = pass.got + 1
        -- The same list again (the game repeats this event when item data arrives): nothing new.
        if #list < from and pass.pages > 0 then return end
    end
    lastBrowseAt = GetTime()
    local ok, err = pcall(function()
        for i = from, #list do judge(list[i], pass, sum) end
    end)
    if not ok then ns.Log("ERROR judging a page of %s: %s", pass.name, tostring(err)) end
    if not scan then return end
    pass.got = pass.got + (#list - from + 1)
    pass.pages = pass.pages + 1
    Scanner.browsed = sum.browsed
    advance()
end

ns.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function() onPage(nil) end)
ns.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function(added) onPage(type(added) == "table" and added or nil) end)
ns.On("AUCTION_HOUSE_BROWSE_FAILURE", function()
    if scan and Scanner.state == "browsing" then finishPass("the auction house reported a failure") end
end)

-- Another window's browse replaces our results: give up this scan and let Play retry.
if hooksecurefunc then
    hooksecurefunc(AH, "SendBrowseQuery", function()
        if not ourSend and scan and Scanner.state == "browsing" then
            ns.Log("gear scan dropped: another addon or window started a browse")
            scan = nil
            setState("idle")
            scheduleNext()
        end
    end)
end

--- Play: scan the gear now and again every few seconds. Also resumes after a pause.
function Scanner.Play()
    if not ns.Queue.open then ns.Print("open the auction house first") return end
    local wasPaused = Scanner.paused
    Scanner.auto, Scanner.paused = true, false
    ns.Queue.SetPaused(false)
    ns.Log(wasPaused and "auto scan resumed" or "auto scan started")
    if scan and scan.held then
        scan.held = false
        lastBrowseAt = GetTime()
        advance()
    elseif Scanner.state == "idle" and not ns.Prices.scanning then
        startCycle(not wasPaused)   -- a fresh Play click starts with an empty list; resuming does not
    end
    ns.Fire("SALVAGER_SCAN")
end

--- Pause: hold every search where it is. Play continues from there.
function Scanner.Pause()
    if not Scanner.auto and not ns.Busy() then return end
    Scanner.paused = true
    ns.Queue.SetPaused(true)
    ns.Log("scanning paused")
    ns.Fire("SALVAGER_SCAN")
end

--- Stop: end auto scanning and drop the scan that is running. Deals found so far stay.
function Scanner.Stop()
    Scanner.auto, Scanner.paused = false, false
    ns.Queue.SetPaused(false)
    ns.Queue.Clear()
    Scanner.browseSeq = (Scanner.browseSeq or 0) + 1
    scan = nil
    Scanner.state = "idle"
    ns.Prices.scanning = false
    ns.scanBothPending = false
    ns.Log("scanning stopped")
    ns.Fire("SALVAGER_SCAN")
end

--- (Kept for /salv and older callers.)
function Scanner.SetAuto(on)
    if on then Scanner.Play() else Scanner.Stop() end
end

ns.On("AUCTION_HOUSE_CLOSED", function()
    wipe(pendingBuys)
    Scanner.auto = false
    Scanner.paused = false
    scan = nil
    Scanner.state = "idle"
    wipe(Scanner.deals)
end)

------------------------------------------------------------------ buying

local BUY_QUIET = 1.0      -- seconds after a Buy click in which searches wait (more clicks may follow)
local BUY_EXPIRES = 10     -- seconds after which a purchase with no answer is given up
local lastBuyAt = 0

--- Is a purchase on its way, or was Buy clicked a moment ago? Then nothing else talks to the
--- auction house: a search sent now would be dropped, or would make it drop the purchase.
function Scanner.Buying()
    if GetTime() - lastBuyAt < BUY_QUIET then return true end
    for id, d in pairs(pendingBuys) do
        if GetTime() - d.clickedAt < BUY_EXPIRES then return true end
        -- No answer at all: free the row again.
        pendingBuys[id] = nil
        d.pending = false
        ns.Log("purchase of %s got no answer in %ds", d.link or d.itemID, BUY_EXPIRES)
    end
    return false
end

--- Buys a deal. Must run from a click (the server needs a hardware event).
function Scanner.Buy(deal)
    if deal.pending then return end
    if GetMoney() < deal.buyout then ns.Print("not enough money for %s", deal.link or "this item") return end
    deal.pending = true
    deal.clickedAt = GetTime()
    lastBuyAt = deal.clickedAt
    pendingBuys[deal.auctionID] = deal
    AH.PlaceBid(deal.auctionID, deal.buyout)
    ns.Fire("SALVAGER_DEALS")
end

--- Searches a deal's item again, so its rows show what is listed now.
function Scanner.Recheck(deal)
    local t = deal and deal.task
    if not t or not ns.Queue.open then return end
    ns.Log("rechecking item %s after a purchase", t.keyString)
    ns.Queue.Add({
        itemKey = t.itemKey, keyString = t.keyString, net = t.net, ilvl = t.ilvl, quality = t.quality,
        classID = t.classID, limit = t.limit,
        onResult = function(task) readAuctions(task) ns.Fire("SALVAGER_DEALS") end,
        onFail = function() ns.Fire("SALVAGER_DEALS") end,
    })
end

--- The cheapest deal of a list that is not being bought already.
function Scanner.Cheapest(deals)
    local best
    for _, d in ipairs(deals) do
        if not d.pending and (not best or d.buyout < best.buyout) then best = d end
    end
    return best
end

local function removeDeal(auctionID)
    for i = #Scanner.deals, 1, -1 do
        if Scanner.deals[i].auctionID == auctionID then table.remove(Scanner.deals, i) end
    end
end

ns.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
    local d = pendingBuys[auctionID]
    pendingBuys[auctionID] = nil
    removeDeal(auctionID)
    if d then
        ns.Print("bought %s for %s (expected profit %s)", d.link or "item", ns.Money(d.buyout), ns.Money(d.profit))
        ns.Ledger.AuctionPurchase(ns.db.ledger, d.itemID, d.buyout, d.value, time(), d.link)
        ns.Log("bought %s for %s, value %s", d.link or d.itemID, ns.Money(d.buyout), ns.Money(d.value))
        ns.Fire("SALVAGER_LEDGER")
        Scanner.Recheck(d)
    end
    ns.Fire("SALVAGER_DEALS")
end)

-- The error does not say which purchase it is about: it is the oldest one still on its way.
ns.On("AUCTION_HOUSE_SHOW_ERROR", function()
    local d
    for _, x in pairs(pendingBuys) do
        if not d or x.clickedAt < d.clickedAt then d = x end
    end
    if not d then return end
    pendingBuys[d.auctionID] = nil
    d.pending = false
    removeDeal(d.auctionID)
    ns.Print("could not buy %s (sold or changed)", d.link or "item")
    ns.Log("could not buy %s for %s", d.link or d.itemID, ns.Money(d.buyout))
    Scanner.Recheck(d)
    ns.Fire("SALVAGER_DEALS")
end)

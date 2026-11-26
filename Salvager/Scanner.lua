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
local CLASS_NAME = { [Data.CLASS_WEAPON] = "Weapons", [Data.CLASS_ARMOR] = "Armor" }

local scan                 -- the scan in progress: { seq, passes, index, pass, candidates, seen, sum }
local lastBrowseAt = 0
local ourSend = false
local pendingBuys = {}     -- [auctionID] = deal, purchases on their way
local dropped = {}         -- [auctionID] = deal: purchases given up as dropped (an answer may still come)

local function setState(s)
    Scanner.state = s
    ns.Fire("SALVAGER_SCAN")
end

local function sortDeals()
    table.sort(Scanner.deals, function(a, b) return a.profit > b.profit end)
end

--- Queues the search of one item. `c` = { keyString, net, limit, ilvl, quality, classID }.
local function checkItem(c, itemKey, onResult, onFail)
    ns.Queue.Add({
        itemKey = itemKey, keyString = c.keyString, net = c.net, ilvl = c.ilvl, quality = c.quality,
        classID = c.classID, limit = c.limit, onResult = onResult, onFail = onFail,
    })
end

--- The value and buy limit of a quality, gear type and item level now. nil when the band is blocked.
local function currentBand(quality, classID, ilvl)
    local s = ns.db.settings
    local cap = s.maxPrice > 0 and s.maxPrice or math.huge
    for _, row in ipairs(ns.Limits()) do
        if row.quality == quality and ilvl >= row.lo and ilvl <= row.up then
            local x = classID == Data.CLASS_WEAPON and row.weapon or row.armor
            if not x or x.blocked then return nil end
            return { net = x.value, limit = math.min(x.limit, cap) }
        end
    end
    return nil
end

local function removeKey(keyString)
    for i = #Scanner.deals, 1, -1 do
        local d = Scanner.deals[i]
        if d.keyString == keyString and not d.pending then table.remove(Scanner.deals, i) end
    end
end

local function readAuctions(task)
    local key = task.itemKey
    local maxBuy = task.limit
    -- Drop the old rows of this item, then add what is listed now. A row being bought stays, and the same
    -- auction is not added again (a second row would send a second purchase).
    local buying = {}
    for i = #Scanner.deals, 1, -1 do
        local d = Scanner.deals[i]
        if d.pending then buying[d.auctionID] = true
        elseif d.keyString == task.keyString then table.remove(Scanner.deals, i) end
    end
    local n = AH.GetNumItemSearchResults(key) or 0
    local before = #Scanner.deals
    local outcomes = ns.Model.Outcomes(task.quality, task.classID, task.ilvl)
    local s = ns.db.settings
    local odds = { salvager = ns.SalvagerForBuy(), salvagerChance = s.salvagerChance, cut = s.cut }
    local wrong, unknown = 0, 0
    for i = 1, n do
        local r = AH.GetItemSearchResultInfo(key, i)
        -- The auction's own link has the last word on the quality: an item valued as another quality is
        -- never listed.
        -- The same for its gear type and its item level: a deal is only listed when the auction's own item
        -- gives the band it was valued with. What the link does not tell is not trusted: no deal.
        local link = r and r.itemLink
        local real = link and ns.QualityOf(link)
        local realClass = link and ns.ClassOf(link)
        local realLevel = link and ns.ItemLevelOf(link)
        local realBand = realLevel and outcomes and ns.Model.Outcomes(task.quality, task.classID, realLevel)
        if r and buying[r.auctionID] then
            r = nil   -- being bought: its row is there already
        elseif not (real and realClass and realBand) then
            unknown = unknown + 1
            r = nil
        elseif real ~= task.quality or realClass ~= task.classID or realBand.band ~= outcomes.band then
            wrong = wrong + 1
            r = nil
        end
        if r and r.buyoutAmount and r.buyoutAmount > 0 and not r.containsOwnerItem and r.buyoutAmount <= maxBuy then
            Scanner.deals[#Scanner.deals + 1] = {
                auctionID = r.auctionID, itemKey = key, keyString = task.keyString,
                link = r.itemLink, itemID = key.itemID, ilvl = task.ilvl, quality = task.quality, classID = task.classID,
                buyout = r.buyoutAmount, value = task.net, profit = task.net - r.buyoutAmount, task = task,
                lose = outcomes and ns.Model.LossChance(outcomes, ns.PriceOf, odds, r.buyoutAmount) or nil,
            }
        end
    end
    if wrong > 0 then
        ns.Log("item %s: %d auctions left out, their item is not %s %s of item level %s as it was valued",
            task.keyString, wrong, ns.QUALITY_NAME[task.quality] or tostring(task.quality),
            CLASS_NAME[task.classID] or tostring(task.classID), tostring(task.ilvl))
    end
    if unknown > 0 then
        ns.Log("item %s: %d auctions left out, the game did not tell their quality, gear type or item level yet",
            task.keyString, unknown)
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
        if not (Scanner.auto and ns.Queue.open) or Scanner.paused or Scanner.state ~= "idle" then return end
        if ns.Prices.scanning then
            -- A material scan is running: this round waits for it. (After "Scan both", the gear scan
            -- that follows schedules the next round itself.)
            if not ns.scanBothPending then scheduleNext() end
            return
        end
        startCycle()
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
                    name = ns.QUALITY_NAME[quality] .. " " .. CLASS_NAME[classID], got = 0, pages = 0, breaks = 0 }
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
    -- The item's own quality decides, not the browse it came in. A page of another browse can arrive in
    -- this pass (measured 2026-11-26: uncommon items came during the rare pass and were valued as rare).
    -- (Read from what was learned: asking the game here would send a request per item of the page. An item
    -- not learned yet goes on: the auction's own link decides before it is listed, see readAuctions.)
    local quality = ns.Items.Quality(key.itemID)
    if quality and quality ~= pass.quality then sum.wrongQuality = sum.wrongQuality + 1 return end
    -- The same for the gear type: armor that comes in the weapon pass is not valued as a weapon.
    local classID = ns.ClassOf(key.itemID)
    if classID and classID ~= pass.classID then sum.wrongQuality = sum.wrongQuality + 1 return end
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
    sum.passes = scan.passes
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
    if sum.wrongQuality > 0 then
        ns.Log("gear scan: %d items left out, they came in the browse of another quality or gear type", sum.wrongQuality)
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
    -- Only what this round has read counts: when the browse of a quality and gear type did not load in
    -- full (the auction house gave no page, or dropped requests), its rows stay as they are. Without
    -- this, a round with a failed browse emptied the list, and the next one filled it again.
    local live, read = {}, {}
    for _, c in ipairs(candidates) do live[c.keyString] = true end
    for _, pass in ipairs(sum.passes or {}) do read[pass.quality .. ":" .. pass.classID] = pass.full and "full" or "part" end
    local kept = 0
    for i = #Scanner.deals, 1, -1 do
        local d = Scanner.deals[i]
        local how = read[tostring(d.quality) .. ":" .. tostring(d.classID)]
        if not live[d.keyString] and not d.pending then
            if how == "part" then kept = kept + 1 else table.remove(Scanner.deals, i) end
        end
    end
    if kept > 0 then ns.Log("gear scan: %d deals kept as they were, their browse did not load in full", kept) end
    Scanner.toCheck = #candidates
    for _, c in ipairs(candidates) do
        checkItem(c, c.key, function(task) readAuctions(task) checkDone() end, checkDone)
    end
    if #candidates == 0 then
        Scanner.toCheck = 1
        checkDone()
    end
end

------------------------------------------------------------------ browsing

local nextPass, advance

local function finishPass(why)
    local pass = scan.pass
    ns.Log("browse %s: %d items in %d pages, %.1fs%s%s", pass.name, pass.got, pass.pages, GetTime() - pass.startedAt,
        pass.breaks > 0 and string.format(", not in price order (%d breaks)", pass.breaks) or ", in price order",
        why and (", " .. why) or "")
    nextPass()
end

--- The next step of the pass: another page, or the next pass.
function advance()
    if Scanner.paused then scan.held = true return end
    -- Buying first: while a purchase is on its way, the next page waits (as the searches do).
    if Scanner.Buying() then
        local seq = scan.seq
        lastBrowseAt = GetTime()
        C_Timer.After(0.3, function()
            if scan and scan.seq == seq and Scanner.state == "browsing" then advance() end
        end)
        return
    end
    local pass = scan.pass
    if AH.HasFullBrowseResults() then
        pass.full = true
        return finishPass()
    end
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
            if Scanner.Buying() then return advance() end   -- a purchase goes first; the page is asked for after it
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
        elseif pass and pass.pages == 0 and (pass.retries or 0) < STALL_RETRIES and pass.query then
            -- Not even the first page came: send the browse again.
            pass.retries = (pass.retries or 0) + 1
            ns.Log("browse %s: no first page for %ds, sending the browse again (%d of %d)", pass.name, BROWSE_STALL,
                pass.retries, STALL_RETRIES)
            ourSend = true
            pcall(AH.SendBrowseQuery, pass.query)
            ourSend = false
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
    if pass.top <= 0 then
        pass.full = true   -- nothing of it can be a deal
        return finishPass("no buy limit above zero, skipped")
    end
    local s = ns.db.settings
    local query = {
        searchString = "",
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } },
        filters = { QUALITY_FILTER[pass.quality] },
        itemClassFilters = { { classID = pass.classID } },
    }
    if s.minLevel > 0 then query.minLevel = s.minLevel end
    if s.maxLevel > 0 then query.maxLevel = s.maxLevel end
    pass.query = query
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
        ns.Defer("gear", function() return not ns.Prices.scanning end, function() Scanner.Scan(clear) end,
            "The gear scan", "the material scan is done")
        return
    end
    if not next(ns.db.prices) then ns.Print("scan material prices first") return end
    local passes = buildPlan()
    Scanner.browseSeq = (Scanner.browseSeq or 0) + 1
    scan = {
        seq = Scanner.browseSeq, passes = passes, index = 0, candidates = {}, seen = {}, startedAt = GetTime(),
        sum = { browsed = 0, overLimit = 0, noDisenchant = 0, learning = 0, noValue = 0, noPrice = 0, candidates = 0,
            levelDiffers = 0, levelOut = 0, wrongQuality = 0, best = nil },
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
    for i = from, #list do
        local ok, err = pcall(judge, list[i], pass, sum)
        if not ok then ns.Log("ERROR judging item %d of a page of %s: %s", i, pass.name, tostring(err)) end
    end
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
    ns.Queue.Clear(true)   -- a price the player just asked for (Post) still comes
    Scanner.browseSeq = (Scanner.browseSeq or 0) + 1
    scan = nil
    Scanner.state = "idle"
    ns.Prices.scanning = false
    ns.scanBothPending = false
    if ns.Listings and ns.Listings.checking then
        ns.Listings.checking = nil
        ns.Fire("SALVAGER_LISTINGS")
    end
    ns.Log("scanning stopped")
    ns.Fire("SALVAGER_SCAN")
end

--- (Kept for /salv and older callers.)
function Scanner.SetAuto(on)
    if on then Scanner.Play() else Scanner.Stop() end
end

ns.On("AUCTION_HOUSE_CLOSED", function()
    wipe(pendingBuys)
    wipe(dropped)
    Scanner.auto = false
    Scanner.paused = false
    scan = nil
    Scanner.state = "idle"
    wipe(Scanner.deals)
end)

------------------------------------------------------------------ buying

local BUY_QUIET = 1.0      -- seconds after a Buy click in which searches wait (more clicks may follow)
local BUY_EXPIRES = 10     -- seconds after which a purchase with no answer is given up
local BUSY_HOLD = 2        -- extra seconds everything is held after the auction house dropped a purchase
local DROP_WINDOW = 2      -- a "request dropped" this soon after a Buy click is taken to be about the purchase
local AIM_HOLD = 4         -- seconds the scan stays quiet while the mouse is on a Buy button
local lastBuyAt = 0
local aimUntil = 0

--- The mouse is on a Buy button (or left it): the scan sends nothing new, so the auction house is free
--- when the click comes. The purchase must never wait for the scan; the scan waits for the purchase.
function Scanner.Aim(on)
    aimUntil = on and (GetTime() + AIM_HOLD) or 0
end

--- Is a purchase on its way, or was Buy clicked a moment ago? Then nothing else talks to the
--- auction house: a search sent now would be dropped, or would make it drop the purchase.
function Scanner.Buying()
    if GetTime() - lastBuyAt < BUY_QUIET then return true end
    if GetTime() < aimUntil then return true end
    for id, d in pairs(pendingBuys) do
        if GetTime() - d.clickedAt < BUY_EXPIRES then return true end
        -- No answer at all: free the row again. (If it went through after all, it is still booked.)
        pendingBuys[id] = nil
        dropped[id] = d
        d.pending = false
        ns.Log("purchase of %s got no answer in %ds", d.link or d.itemID, BUY_EXPIRES)
    end
    return false
end

--- Buys a deal. Must run from a click (the server needs a hardware event).
function Scanner.Buy(deal)
    if deal.pending then return end
    if GetMoney() < deal.buyout then ns.Print("not enough money for %s", deal.link or "this item") return end
    -- A click on Buy always buys. Everything else stops at once, and the purchase is next on the line:
    --   the auction house is free: it goes out now;
    --   the auction house is busy with one request (a purchase sent now is lost without any answer,
    --   measured 2026-11-26): it goes out the moment that one request is answered, ahead of the queue.
    deal.pending = true
    deal.clickedAt = GetTime()
    ns.Gold.Expect("buy", -deal.buyout, deal.link, 120)
    lastBuyAt = deal.clickedAt
    pendingBuys[deal.auctionID] = deal
    local busy = AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady()
    if busy and not ns.db.buyResendBlocked then
        deal.resend, deal.queued = true, true
        ns.Log("purchase of %s: the auction house is busy, it goes out the moment it is ready", deal.link or deal.itemID)
        C_Timer.After(1, function() Scanner.SendWaiting(true) end)   -- in case the "ready" event does not come
    else
        ns.NoteRequest("buy")
        AH.PlaceBid(deal.auctionID, deal.buyout)
    end
    ns.Fire("SALVAGER_DEALS")
end

--- Searches a deal's item again, so its rows show what is listed now.
function Scanner.Recheck(deal)
    local t = deal and deal.task
    if not t or not ns.Queue.open then return end
    -- The value and limit of now: prices or settings may have changed since the scan.
    local band = currentBand(t.quality, t.classID, t.ilvl)
    if not band then
        ns.Log("rechecking item %s: its band has no value or limit now, its rows go", t.keyString)
        removeKey(t.keyString)
        ns.Fire("SALVAGER_DEALS")
        return
    end
    ns.Log("rechecking item %s after a purchase", t.keyString)
    local c = { keyString = t.keyString, net = band.net, limit = band.limit, ilvl = t.ilvl, quality = t.quality,
        classID = t.classID }
    checkItem(c, t.itemKey, function(task) readAuctions(task) ns.Fire("SALVAGER_DEALS") end,
        function() ns.Fire("SALVAGER_DEALS") end)
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

-- The auction house says it threw a request away, just after a Buy click: the purchase did not go
-- through. It is sent again by the addon the moment the auction house is ready, ahead of every search and
-- browse page (they all wait while a purchase is on its way). The player does nothing.
-- The game marks PlaceBid as restricted, so it may refuse a purchase that does not come straight from a
-- click. If it does (it then reports a blocked action), that is remembered and the row is freed instead.
local MAX_BUY_RESENDS = 3
local function free(d, why)
    pendingBuys[d.auctionID] = nil
    dropped[d.auctionID] = d
    d.pending, d.resend = false, nil
    lastBuyAt = GetTime() + BUSY_HOLD
    ns.Print("purchase of %s was dropped by the auction house: click Buy again", d.link or "the item")
    ns.Log("purchase of %s dropped by the auction house, row freed (%s)", d.link or d.itemID, why)
    ns.Fire("SALVAGER_DEALS")
end

--- Sends the oldest purchase that waits for the auction house. One at a time: each purchase makes the
--- auction house busy again, and the next one goes out when it is ready again.
--- `force` = send even if the auction house does not say it is ready (its "ready" event did not come).
function Scanner.SendWaiting(force)
    local d
    for _, x in pairs(pendingBuys) do
        if x.resend and (not d or x.clickedAt < d.clickedAt) then d = x end
    end
    if not d then return end
    if not force and AH.IsThrottledMessageSystemReady and not AH.IsThrottledMessageSystemReady() then return end
    d.resend = nil
    if not d.queued then d.resends = (d.resends or 0) + 1 end
    d.sentByAddon = true
    d.clickedAt = GetTime()
    lastBuyAt = d.clickedAt
    ns.NoteRequest("buy")
    local ok, err = pcall(AH.PlaceBid, d.auctionID, d.buyout)
    ns.Log("purchase of %s sent%s%s", d.link or d.itemID, d.queued and " (it waited for the auction house)"
        or string.format(" again (%d of %d)", d.resends, MAX_BUY_RESENDS), ok and "" or (": " .. tostring(err)))
    d.queued = nil
    if not ok then free(d, "the game refused it") end
    -- More of them waiting: the next one after this one.
    C_Timer.After(1, function() Scanner.SendWaiting(true) end)
end

ns.On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
    for _, d in pairs(pendingBuys) do
        if GetTime() - d.clickedAt < DROP_WINDOW and not d.resend then
            if ns.db.buyResendBlocked or (d.resends or 0) >= MAX_BUY_RESENDS then
                free(d, ns.db.buyResendBlocked and "the game does not allow a resend" or "resent 3 times")
            else
                d.resend = true
                d.clickedAt = GetTime()   -- (it stays "on its way": everything else keeps waiting)
                ns.Log("purchase of %s dropped by the auction house: sending it again when it is ready",
                    d.link or d.itemID)
                -- In case the "ready" event does not come.
                C_Timer.After(1, function() Scanner.SendWaiting(true) end)
            end
        end
    end
end)
ns.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function() Scanner.SendWaiting() end)

-- The game refused an action of this addon. If that was a purchase sent again, never try that again.
local function blocked(addon)
    if addon ~= "Salvager" then return end
    if not ns.db.buyResendBlocked then
        ns.db.buyResendBlocked = true
        ns.Log("the game does not allow a purchase without a click: purchases are not sent again from now on")
    end
    for _, d in pairs(pendingBuys) do
        if d.sentByAddon then free(d, "the game blocked a purchase sent without a click") end
    end
end
ns.On("ADDON_ACTION_BLOCKED", blocked)
ns.On("ADDON_ACTION_FORBIDDEN", blocked)

ns.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
    -- (A purchase given up as dropped that went through after all is still booked.)
    local d = pendingBuys[auctionID] or dropped[auctionID]
    pendingBuys[auctionID], dropped[auctionID] = nil, nil
    removeDeal(auctionID)
    if d then
        ns.Print("bought %s for %s (expected profit %s)", d.link or "item", ns.Money(d.buyout), ns.Money(d.profit))
        local o = ns.Model.Outcomes(d.quality, d.classID, d.ilvl)
        ns.Ledger.AuctionPurchase(ns.db.ledger, d.itemID, d.buyout, d.value, time(), d.link,
            { q = d.quality, cls = d.classID, band = o and o.band, ilvl = d.ilvl, v = ns.VERSION })
        ns.Log("bought %s for %s, value %s", d.link or d.itemID, ns.Money(d.buyout), ns.Money(d.value))
        ns.Fire("SALVAGER_LEDGER")
        Scanner.Recheck(d)
    end
    ns.Fire("SALVAGER_DEALS")
end)

-- The error does not say which purchase it is about: it is the oldest one still on its way.
ns.On("AUCTION_HOUSE_SHOW_ERROR", function()
    -- (The same event answers posts and cancels: it is about a purchase only when one was sent last.)
    if not ns.ErrorIs("buy") then return end
    local d
    for _, x in pairs(pendingBuys) do
        if not d or x.clickedAt < d.clickedAt then d = x end
    end
    if not d then return end
    pendingBuys[d.auctionID] = nil
    dropped[d.auctionID] = d
    d.pending = false
    removeDeal(d.auctionID)
    ns.Print("could not buy %s (sold or changed)", d.link or "item")
    ns.Log("could not buy %s for %s", d.link or d.itemID, ns.Money(d.buyout))
    Scanner.Recheck(d)
    ns.Fire("SALVAGER_DEALS")
end)

-- New settings (a buy limit, the most to pay, the gear type): rows that are no deal under them go at once.
ns.On("SALVAGER_SETTINGS", function()
    local gone = 0
    for i = #Scanner.deals, 1, -1 do
        local d = Scanner.deals[i]
        local band = not d.pending and currentBand(d.quality, d.classID, d.ilvl)
        if not d.pending and (not band or d.buyout > band.limit) then
            table.remove(Scanner.deals, i)
            gone = gone + 1
        end
    end
    if gone > 0 then
        ns.Log("settings changed: %d deals left out, they are over their buy limit now", gone)
        ns.Fire("SALVAGER_DEALS")
    end
end)

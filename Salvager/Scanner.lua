-- Salvager: gear scan and deals.
-- 1. Browse: one query per quality and gear type lists every matching item with its lowest
--    price. Each page is judged as it arrives, from data that came with it: no item lookups.
--    (The auction house does not return these in price order, so every page is read.)
-- 2. Check: items whose lowest price is under their buy limit get an item search, which lists
--    each auction. Every auction under the limit becomes a deal.
local _, ns = ...

local AH = C_AuctionHouse
local Data = ns.Data

local Scanner = { state = "idle", deals = {}, checked = 0, toCheck = 0, browsed = 0, auto = false, summary = nil,
    browseEpoch = 0 }
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

--- A deal's return: its expected profit as a share of its price.
function Scanner.Return(d) return d.buyout > 0 and d.profit / d.buyout or 0 end

--- A deal's Return per day (SDD 100): its Return ÷ the days until its materials sell (at least 1). nil when no
--- material has a time to sell yet.
function Scanner.ReturnPerDay(d) return ns.Model.ReturnPerDay(d.profit, d.buyout, d.days) end

--- Which deal comes first, by the order the player picked (Expected profit or Return).
function Scanner.Better(a, b)
    if ns.db.settings.dealSort == "return" then return Scanner.Return(a) > Scanner.Return(b) end
    return a.profit > b.profit
end

local function sortDeals()
    table.sort(Scanner.deals, Scanner.Better)
end
Scanner.Sort = sortDeals

--- Queues the search of one item. `c` = { keyString, net, limit, ilvl, quality, classID }.
--- `forBuy` = for a Buy click: it goes first, and past the hold that buying puts on every other request.
--- `overlap` = a Live search: it may go out while other Live searches wait for their answers (Queue, SDD 122).
local function checkItem(c, itemKey, onResult, onFail, forBuy, overlap)
    ns.Queue.Add({
        itemKey = itemKey, keyString = c.keyString, net = c.net, ilvl = c.ilvl, quality = c.quality,
        classID = c.classID, limit = c.limit, onResult = onResult, onFail = onFail, forBuy = forBuy,
        overlap = overlap or nil,
    }, forBuy)
end
Scanner.CheckItem = checkItem   -- (for the Live scan)

--- The value and buy limit of a quality, gear type and item level now. nil when the band is blocked.
--- `limits`: ns.Limits() when the caller has it (one table for many deals).
local function currentBand(quality, classID, ilvl, limits)
    local s = ns.db.settings
    local cap = s.maxPrice > 0 and s.maxPrice or math.huge
    for _, row in ipairs(limits or ns.Limits()) do
        if row.quality == quality and ilvl >= row.lo and ilvl <= row.up then
            local x = classID == Data.CLASS_WEAPON and row.weapon or row.armor
            if not x or x.blocked then return nil end
            return { net = x.value, limit = math.min(x.limit, cap) }
        end
    end
    return nil
end

--- A row the player is buying: on its way, waiting for the auction house, or showing "Buy now". Scans never
--- remove or replace it.
local function inHand(d) return d.pending or d.wait or d.buyNow end
Scanner.InHand = inHand

local function removeKey(keyString)
    for i = #Scanner.deals, 1, -1 do
        local d = Scanner.deals[i]
        if d.keyString == keyString and not inHand(d) then table.remove(Scanner.deals, i) end
    end
end

local function removeDeal(auctionID)
    for i = #Scanner.deals, 1, -1 do
        if Scanner.deals[i].auctionID == auctionID then table.remove(Scanner.deals, i) end
    end
end

local afterSearch   -- (buying, below: a row that waited for its item's search)

local function readAuctions(task)
    local key = task.itemKey
    local maxBuy = task.limit
    -- Drop the old rows of this item, then add what is listed now. A row being bought stays, and the same
    -- auction is not added again (a second row would send a second purchase).
    local buying = {}
    for i = #Scanner.deals, 1, -1 do
        local d = Scanner.deals[i]
        if inHand(d) then buying[d.auctionID] = d
        elseif d.keyString == task.keyString then table.remove(Scanner.deals, i) end
    end
    local listed = {}   -- [auctionID] = true: the auctions this answer lists
    local n = AH.GetNumItemSearchResults(key) or 0
    local before = #Scanner.deals
    local odds = ns.ValueOptions()
    local outcomes = ns.Outcomes(task.quality, task.classID, task.ilvl, odds.salvager)
    -- Days until the materials sell, by their part of the value (Return per day, SDD 100).
    local days, daysFew, sellSeconds
    if outcomes then days, daysFew, sellSeconds = ns.DaysToSell(ns.Model.Value(outcomes, ns.PriceOf, odds).parts) end
    -- Every whole-unit outcome of one disenchant and the range (SDD 116), shared by the deals of this answer.
    local spread = outcomes and ns.Spread(outcomes)
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
        if r then listed[r.auctionID] = true end
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
                spread = spread, low = spread and spread.low and spread.low.value,
                high = spread and spread.high and spread.high.value,
                days = days, daysFew = daysFew, sellSeconds = sellSeconds,
                epoch = Scanner.browseEpoch,   -- (the browse count at its search: SDD 105)
                searchedAt = GetTime(),
            }
        end
    end
    -- Rows the player is buying of this item: this answer makes them current again, or says they are gone.
    for id, d in pairs(buying) do
        if d.keyString == task.keyString and not d.pending then
            if listed[id] then d.epoch, d.searchedAt = Scanner.browseEpoch, GetTime() end
            afterSearch(d, listed[id])
        end
    end
    if wrong > 0 then
        ns.Log("DEBUG", "search", string.format("%s: %d auctions left out, their item is not %s %s of item level %s as "
            .. "it was valued", ns.LogItem(ns.LogBook.ItemOf(task.keyString)), wrong,
            ns.QUALITY_NAME[task.quality] or tostring(task.quality), CLASS_NAME[task.classID] or tostring(task.classID),
            tostring(task.ilvl)), { key = task.keyString, auctions = wrong, quality = task.quality,
            classID = task.classID, ilvl = task.ilvl })
    end
    if unknown > 0 then
        ns.Log("DEBUG", "search", string.format("%s: %d auctions left out, the game did not tell their quality, gear "
            .. "type or item level yet", ns.LogItem(ns.LogBook.ItemOf(task.keyString)), unknown),
            { key = task.keyString, auctions = unknown })
    end
    ns.Log("DEBUG", "search", string.format("checked %s: %d auctions, %d under %s",
        ns.LogItem(ns.LogBook.ItemOf(task.keyString)), n, #Scanner.deals - before, ns.Money(maxBuy)),
        { key = task.keyString, auctions = n, deals = #Scanner.deals - before, maxBuy = maxBuy })
    sortDeals()
end
Scanner.ReadAuctions = readAuctions   -- (for the Live scan)


--- Does Play run the Live scan now (SDD 122)? Not when this session found the browse not sorted by price: then it
--- runs the full rounds.
local function liveMode() return Scanner.auto and ns.Live and ns.Live.Usable() or false end
Scanner.LiveMode = liveMode

--- One round of Play: the material prices first when they are older than the setting, then the gear: a Live round,
--- or a full round when the Live scan fell back.
local function startCycle(clear)
    local every = ns.db.settings.priceRescan
    local age = ns.Prices.OldestAge()
    local live = liveMode()
    if every > 0 and age >= every * 60 and not ns.Busy() then
        ns.Log("INFO", "scan", string.format("material prices are %s old (limit %d min): scanning them first",
            age == math.huge and "missing or" or (math.floor(age / 60) .. " min"), every),
            { age = age ~= math.huge and math.floor(age) or nil, limitMin = every })
        if live then
            if clear then Scanner.ClearDeals() end
            ns.Live.AfterPrices()
        else
            ns.ScanBoth(clear)
        end
    elseif live then
        ns.Live.Round(clear)
    else
        Scanner.Scan(clear)
    end
end
Scanner.StartCycle = startCycle

--- The next round of Play: `liveInterval` seconds after a Live round ended, `autoInterval` after a full one.
--- (`Scanner.nextAt`: when, for the status text. Only the timer set last starts a round.)
local cycleToken = 0
local function scheduleNext()
    if not Scanner.auto then return end
    local wait = liveMode() and ns.Live.Rest() or ns.db.settings.autoInterval
    Scanner.nextAt = GetTime() + wait
    cycleToken = cycleToken + 1
    local token = cycleToken
    C_Timer.After(wait, function()
        if token ~= cycleToken then return end
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
Scanner.ScheduleNext = scheduleNext

--- The time the scans of this round waited for purchases, by reason (`Scanner.HoldReason`), counted while a material
--- or gear scan runs; said once at its end and started again (SDD 105k).
Scanner.holds = {}
local function logHolds()
    local total, parts = 0, {}
    for _, why in ipairs({ "purchase", "waiting", "click" }) do
        local t = Scanner.holds[why]
        if t and t > 0 then
            total = total + t
            parts[#parts + 1] = string.format("%s %.1fs", why, t)
        end
    end
    ns.Log("INFO", "scan", "scan held for purchases: " .. (total > 0 and string.format("%.1fs (%s)", total,
        table.concat(parts, ", ")) or "not at all"), { seconds = total, purchase = Scanner.holds.purchase,
        waiting = Scanner.holds.waiting, click = Scanner.holds.click })
    wipe(Scanner.holds)
end
Scanner.LogHolds = logHolds

local function checkDone()
    Scanner.checked = Scanner.checked + 1
    ns.Fire("SALVAGER_DEALS")
    if Scanner.checked >= Scanner.toCheck then
        local seconds = GetTime() - (Scanner.checksAt or GetTime())
        ns.Log("INFO", "scan", string.format("show top done: %d gear searches in %.0fs; %d searches got no answer and "
            .. "were sent again, %d used the game's held results", Scanner.toCheck, seconds, ns.Queue.lost,
            ns.Queue.late), { searches = Scanner.toCheck, seconds = math.floor(seconds + 0.5), lost = ns.Queue.lost,
            late = ns.Queue.late })
        logHolds()
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
            list[#list + 1] = { lo = row.lo, up = row.up, net = x.value, limit = math.min(x.limit, cap), blocked = x.blocked }
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
Scanner.BuildPlan = buildPlan   -- (for the Live scan)
Scanner.QUALITY_FILTER, Scanner.CLASS_NAME = QUALITY_FILTER, CLASS_NAME

------------------------------------------------------------------ judging a page

--- Judges one browse row. `ctx` = { seen, candidates }: the keys taken this round and the candidates for a search.
local function judge(r, pass, sum, ctx)
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
    if ctx.seen[keyString] then return end
    ctx.seen[keyString] = true
    ctx.candidates[#ctx.candidates + 1] = { key = key, keyString = keyString, net = band.net, limit = band.limit,
        ilvl = ilvl, quality = pass.quality, classID = pass.classID, margin = margin, price = price,
        quantity = r.totalQuantity or 0 }
end
Scanner.Judge = judge   -- (for the Live scan)

--- The counts of one scan's judging, all zero.
function Scanner.NewSum()
    return { browsed = 0, overLimit = 0, noDisenchant = 0, learning = 0, noValue = 0, noPrice = 0, candidates = 0,
        levelDiffers = 0, levelOut = 0, wrongQuality = 0, best = nil }
end

------------------------------------------------------------------ after the browse

local function queueChecks()
    local candidates, sum = scan.candidates, scan.sum
    sum.passes = scan.passes
    sum.candidates = #candidates
    sum.seconds = GetTime() - scan.startedAt
    Scanner.summary = sum
    scan = nil
    ns.Log("INFO", "scan", string.format("gear scan: %d gear listings in %.0fs, %d under their limit, %d over, %d not "
        .. "disenchantable, %d level not known yet, %d outside the level filter, %d without a value, %d without a buyout "
        .. "(min profit %s)", sum.browsed, sum.seconds, sum.candidates, sum.overLimit, sum.noDisenchant, sum.learning,
        sum.levelOut, sum.noValue, sum.noPrice, ns.Money(ns.db.settings.minProfit)), { listings = sum.browsed,
        seconds = math.floor(sum.seconds + 0.5), underLimit = sum.candidates, overLimit = sum.overLimit,
        noDisenchant = sum.noDisenchant, levelUnknown = sum.learning, levelOut = sum.levelOut, noValue = sum.noValue,
        noBuyout = sum.noPrice, minProfit = ns.db.settings.minProfit })
    if sum.best then
        local b = sum.best
        ns.Log("INFO", "scan", string.format("closest: %s of item level %s at %s, buy limit %s, value %s, margin %s",
            ns.LogItem(b.itemID), tostring(b.ilvl), ns.Money(b.price), ns.Money(b.limit), ns.Money(b.value),
            ns.Money(b.margin)), { item = b.itemID, ilvl = b.ilvl, price = b.price, limit = b.limit, value = b.value,
            margin = b.margin })
    end
    if sum.wrongQuality > 0 then
        ns.Log("DEBUG", "scan", string.format("gear scan: %d gear listings left out, they came in the browse of another "
            .. "quality or gear type", sum.wrongQuality), { listings = sum.wrongQuality })
    end
    if sum.levelDiffers > 0 then
        ns.Log("DEBUG", "scan", string.format("item levels: %d listings differ from the game's data (%s)",
            sum.levelDiffers, sum.levelExample), { listings = sum.levelDiffers })
    end
    setState("checking")
    Scanner.toCheck, Scanner.checked = 0, 0
    Scanner.checksAt = GetTime()
    ns.Queue.lost, ns.Queue.late = 0, 0
    -- (In the order of the Gear list: by margin, or by return on the price.)
    local byReturn = ns.db.settings.dealSort == "return"
    table.sort(candidates, function(a, b)
        if byReturn then return a.margin / math.max(1, a.price) > b.margin / math.max(1, b.price) end
        return a.margin > b.margin
    end)
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
        if not live[d.keyString] and not inHand(d) then
            if how == "part" then kept = kept + 1 else table.remove(Scanner.deals, i) end
        end
    end
    if kept > 0 then
        ns.Log("WARN", "scan", string.format("gear scan: %d deals kept as they were, their browse did not load in full",
            kept), { deals = kept })
    end
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
    local seconds = GetTime() - pass.startedAt
    ns.Log("DEBUG", "scan", string.format("browse %s: %d gear listings in %d pages, %.1fs%s%s", pass.name, pass.got,
        pass.pages, seconds, pass.breaks > 0 and string.format(", not in price order (%d breaks)", pass.breaks)
        or ", in price order", why and (", " .. why) or ""), { pass = pass.name, listings = pass.got, pages = pass.pages,
        seconds = math.floor(seconds * 10 + 0.5) / 10, breaks = pass.breaks, why = why })
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
    ns.Log("WARN", "scan", string.format("browse %s: the auction house dropped the request for page %d (busy with "
        .. "another request), asking again", pass.name, pass.pages + 1), { pass = pass.name, page = pass.pages + 1 })
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
        -- (Buying first: no page is asked for again while the player aims at Buy or buys, SDD 105.)
        if Scanner.Buying() then lastBrowseAt = GetTime() end
        if Scanner.paused or GetTime() - lastBrowseAt < BROWSE_STALL then watchBrowse(seq) return end
        lastBrowseAt = GetTime()
        watchBrowse(seq)
        local pass = scan.pass
        if pass and pass.pages > 0 and (pass.retries or 0) < STALL_RETRIES then
            pass.retries = (pass.retries or 0) + 1
            ns.Log("WARN", "scan", string.format("browse %s: no page for %ds after page %d, asking again (%d of %d)",
                pass.name, BROWSE_STALL, pass.pages, pass.retries, STALL_RETRIES), { pass = pass.name,
                page = pass.pages, retry = pass.retries, seconds = BROWSE_STALL })
            AH.RequestMoreBrowseResults()
        elseif pass and pass.pages == 0 and (pass.retries or 0) < STALL_RETRIES and pass.query then
            -- Not even the first page came: send the browse again.
            pass.retries = (pass.retries or 0) + 1
            ns.Log("WARN", "scan", string.format("browse %s: no first page for %ds, sending the browse again (%d of %d)",
                pass.name, BROWSE_STALL, pass.retries, STALL_RETRIES), { pass = pass.name, retry = pass.retries,
                seconds = BROWSE_STALL })
            ourSend = true
            pcall(AH.SendBrowseQuery, pass.query)
            ourSend = false
        else
            finishPass(string.format("no page for %ds, given up", BROWSE_STALL))
        end
    end)
end

function nextPass()
    -- Buying first: a new pass (its SendBrowseQuery) waits while the player aims at Buy or buys (SDD 105). A browse
    -- also makes the item searches the Gear list came from stale, so it never starts under the pointer.
    if Scanner.Buying() then
        local seq = scan.seq
        lastBrowseAt = GetTime()
        C_Timer.After(0.3, function()
            if scan and scan.seq == seq and Scanner.state == "browsing" then nextPass() end
        end)
        return
    end
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
        ns.Log("ERROR", "scan", "the browse failed: " .. tostring(err))
        scan = nil
        setState("idle")
        scheduleNext()
        return
    end
    ns.Fire("SALVAGER_SCAN")
end

--- Empties the Gear list. (The Live scan forgets what it searched: every key is new again.)
function Scanner.ClearDeals()
    wipe(Scanner.deals)
    if ns.Live then ns.Live.Forget() end
    ns.Fire("SALVAGER_DEALS")
end

--- Starts a gear scan. Needs the auction house open and material prices.
--- `clear` = asked for by a click: the Gear list starts empty and is filled again. A round that
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
        sum = Scanner.NewSum(),
    }
    Scanner.browsed = 0
    if clear then Scanner.ClearDeals() end
    local names = {}
    for _, p in ipairs(passes) do names[#names + 1] = p.name end
    local s = ns.db.settings
    ns.Log("INFO", "scan", string.format("gear scan started: %s; levels %d-%d; min profit %s, min return %s, max price %s",
        table.concat(names, ", "), s.minLevel, s.maxLevel, ns.Money(s.minProfit),
        s.minReturn > 0 and (s.minReturn .. "%") or "off", s.maxPrice > 0 and ns.Money(s.maxPrice) or "none"),
        { passes = #names, minLevel = s.minLevel, maxLevel = s.maxLevel, minProfit = s.minProfit,
            minReturn = s.minReturn, maxPrice = s.maxPrice })
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
        local ok, err = pcall(judge, list[i], pass, sum, scan)
        if not ok then
            ns.Log("ERROR", "scan", string.format("Lua error judging listing %d of a page of %s: %s", i, pass.name,
                tostring(err)), { pass = pass.name, listing = i })
        end
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
--- Sends a browse of this addon (the hook below tells it from another window's).
function Scanner.SendBrowse(query)
    ourSend = true
    local ok, err = pcall(AH.SendBrowseQuery, query)
    ourSend = false
    return ok, err
end

if hooksecurefunc then
    hooksecurefunc(AH, "SendBrowseQuery", function()
        -- Any browse, ours or another window's, makes the item searches held so far stale: a purchase of an
        -- auction found before it gets no answer (SDD 105). Counted, so a Buy click knows.
        Scanner.browseEpoch = Scanner.browseEpoch + 1
        Scanner.browseAt = GetTime()
        if not ourSend and ns.Live then ns.Live.ForeignBrowse() end
        if not ourSend and scan and Scanner.state == "browsing" then
            ns.Log("WARN", "scan", "gear scan dropped: another addon or window started a browse")
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
    ns.Log("INFO", "scan", wasPaused and "auto scan resumed" or "auto scan started")
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
    ns.Log("INFO", "scan", "scanning paused")
    ns.Fire("SALVAGER_SCAN")
end

--- Stop: end auto scanning and drop the scan that is running. Deals found so far stay.
function Scanner.Stop()
    if Scanner.state ~= "idle" or ns.Prices.scanning then logHolds() end
    Scanner.auto, Scanner.paused = false, false
    ns.Queue.SetPaused(false)
    ns.Queue.Clear(true)   -- a price the player just asked for (Post) still comes
    Scanner.browseSeq = (Scanner.browseSeq or 0) + 1
    scan = nil
    if ns.Live then ns.Live.Abort() end
    Scanner.state = "idle"
    Scanner.nextAt = nil
    ns.Prices.scanning = false
    ns.scanBothPending = false
    if ns.Listings and ns.Listings.checking then
        ns.Listings.checking = nil
        ns.Fire("SALVAGER_LISTINGS")
    end
    ns.Log("INFO", "scan", "scanning stopped")
    ns.Fire("SALVAGER_SCAN")
end

--- (Kept for /salv and older callers.)
function Scanner.SetAuto(on)
    if on then Scanner.Play() else Scanner.Stop() end
end

local waiting   -- (buying, below)
local oldestBuy   -- (buying, below)
ns.On("AUCTION_HOUSE_CLOSED", function()
    wipe(waiting)
    wipe(pendingBuys)
    wipe(dropped)
    Scanner.auto = false
    Scanner.paused = false
    scan = nil
    if ns.Live then ns.Live.Abort() ns.Live.Forget() end
    Scanner.state = "idle"
    Scanner.nextAt = nil
    wipe(Scanner.deals)
end)

------------------------------------------------------------------ buying

local BUY_QUIET = 1.0      -- seconds after a Buy click in which searches wait (more clicks may follow)
local LIVE_BUY_QUIET = 3   -- the same while the Live scan runs: a buying streak keeps the auction house (SDD 122)
local BUY_EXPIRES = 3      -- seconds a purchase gets for its answer, from its click or the answer before it (said)
local BUSY_HOLD = 2        -- extra seconds everything is held after the auction house dropped a purchase
local DROP_WINDOW = 2      -- a "request dropped" this soon after a Buy click is taken to be about the purchase
local WAIT_MAX = 10        -- seconds a click waits for the auction house (or its search) before it is said and dropped
local BUY_NOW_HOLD = 20    -- seconds a "Buy now" holds the scan for the click it asks for
local lastBuyAt = 0
local lastAnswerAt = 0     -- when the auction house last answered a purchase (or one was given up)
local buySeq = 0           -- the order purchases went out in (the oldest one is answered first)
local busyClicks = 0       -- Buy Top clicks on a busy auction house since the last purchase sent (logged once)
waiting = {}               -- [auctionID] = deal: clicked, not sent yet (deal.wait = "ready" or "search"), or "Buy now"

--- The purchase on its way that went out first: the auction house answers it next.
function oldestBuy()
    local d
    for _, x in pairs(pendingBuys) do
        if not d or (x.buySeq or 0) < (d.buySeq or 0) then d = x end
    end
    return d
end

--- Why the scan and every other request wait for a purchase now, or nil: "click" (Buy was clicked a moment ago, or
--- the auction house dropped a purchase), "waiting" (a click waits for the auction house or its search, or "Buy
--- now" is offered), "purchase" (one is on its way). Where the mouse is does not hold anything (0.3.142, the user:
--- the scan must not stop under the mouse; SDD 105b).
function Scanner.HoldReason()
    if GetTime() - lastBuyAt < (liveMode() and LIVE_BUY_QUIET or BUY_QUIET) then return "click" end

    if next(waiting) then return "waiting" end
    -- (A purchase from a price list, Buy.lua, SDD 128, holds the same way.)
    if ns.Buy and ns.Buy.Busy() then return "purchase" end
    -- The auction house answers purchases in the order they went out: only the oldest one's clock runs, from its
    -- click or from the answer to the one before it, whichever is later (SDD 105g).
    local d = oldestBuy()
    if not d then return nil end
    local since = math.max(d.clickedAt, lastAnswerAt)
    if GetTime() - since < BUY_EXPIRES then return "purchase" end
    -- No answer: free the row again, and say so. (If it went through after all, it is still booked.) The next one's
    -- clock starts now.
    pendingBuys[d.auctionID] = nil
    dropped[d.auctionID] = d
    d.pending = false
    lastAnswerAt = GetTime()
    ns.Log("WARN", "buy", string.format("purchase of %s got no answer in %ds", ns.LogItem(d.itemID, d.link), BUY_EXPIRES),
        { item = d.itemID, auction = d.auctionID, seconds = BUY_EXPIRES })
    ns.Print("no answer yet for %s: click Buy again if it is still listed", d.link or "the gear")
    ns.Fire("SALVAGER_DEALS")
    return next(pendingBuys) and "purchase" or nil
end

--- How a purchase went, for its log line: the time from its click to the answer, and its search then (SDD 122).
local function answerNote(d)
    if not d.buySentAt then return "" end
    return string.format("; answered %.2fs after the click, its search was %s (%s old)", GetTime() - d.buySentAt,
        d.sentCurrent and "current" or "stale", d.searchedAt and string.format("%.0fs", d.buySentAt - d.searchedAt) or "?")
end

--- The same as data for the log record: `kv` with the answer's time and its search's age (s, one decimal).
local function answerData(d, kv)
    if not d.buySentAt then return kv end
    kv.answerS = math.floor((GetTime() - d.buySentAt) * 100 + 0.5) / 100
    kv.searchCurrent = d.sentCurrent and true or false
    kv.searchAgeS = d.searchedAt and math.floor(d.buySentAt - d.searchedAt + 0.5) or nil
    return kv
end

--- Is a purchase on its way, waiting, offered as "Buy now", or was Buy clicked a moment ago? Then nothing else talks
--- to the auction house: a request sent now would be dropped, would make it drop the purchase, or (a browse) would
--- make the purchase's search stale.
function Scanner.Buying() return Scanner.HoldReason() ~= nil end

--- The mouse is on this deal's Buy (its row, Buy Top, Gear Details): if a browse came after its search (a click
--- would get no answer, SDD 105), search its gear again now, ahead of every hold, so the click that comes is on a
--- current search and buys at once. Once per gear and browse.
local prefetched = {}   -- [keyString] = browseEpoch searched at
function Scanner.Prefetch(d)
    if not d or d.pending or d.wait or d.buyNow or not d.task or not ns.Queue.open then return end
    if d.epoch == nil or d.epoch >= Scanner.browseEpoch then return end
    if prefetched[d.keyString] == Scanner.browseEpoch then return end
    prefetched[d.keyString] = Scanner.browseEpoch
    Scanner.prefetchAt = GetTime()   -- (the Live scan sends no look right after it: the click comes, SDD 122)
    ns.Log("INFO", "buy", string.format("searching %s again: the mouse is on its Buy and a browse came after its search",
        ns.LogItem(d.itemID, d.link)), { item = d.itemID, auction = d.auctionID })
    Scanner.Recheck(d, true)
end

--- What talks to the auction house now, for the log line of a Buy click.
local function inFlight()
    local parts = {}
    local q = ns.Queue.current
    if q then parts[#parts + 1] = string.format("search of %s sent %.1fs ago", ns.Queue.Describe(q), GetTime() - (q.sentAt or 0)) end
    if scan and scan.pass then
        local pass = scan.pass
        parts[#parts + 1] = string.format("browse %s, %d pages%s", pass.name, pass.pages,
            scan.askedAt and string.format(", a page asked %.1fs ago", GetTime() - scan.askedAt) or "")
    end
    if Scanner.browseAt then parts[#parts + 1] = string.format("last browse sent %.1fs ago", GetTime() - Scanner.browseAt) end
    local live = ns.Live and ns.Live.Current()
    if live then
        parts[#parts + 1] = string.format("live round %s, look %d/%d", live.phase, live.index, #live.slice)
    end
    if #ns.Queue.flying > 1 then parts[#parts + 1] = #ns.Queue.flying .. " searches in flight" end
    local n = 0
    for _ in pairs(pendingBuys) do n = n + 1 end
    if n > 0 then parts[#parts + 1] = n .. " purchases on their way" end
    if ns.Queue.paused then parts[#parts + 1] = "queue paused" end
    return string.format("scan %s; %s", Scanner.state, #parts > 0 and table.concat(parts, "; ") or "nothing")
end

local function forget(d)
    waiting[d.auctionID] = nil
    d.wait, d.waitAt, d.buyNow, d.readyAt = nil, nil, nil, nil
end

--- Sends a purchase now, in the click. `later` = put it on its way, but SendWaiting sends it (the game allows a
--- purchase without a click: `buyResendBlocked` not set).
local function send(deal, later)
    forget(deal)
    deal.pending = true
    deal.clickedAt = GetTime()
    -- (For the purchase's log line: when it went out, and whether its search was current then, SDD 122.)
    deal.buySentAt = deal.clickedAt
    deal.sentCurrent = deal.epoch == nil or deal.epoch >= Scanner.browseEpoch
    ns.Gold.Expect("buy", -deal.buyout, deal.link, 120)
    lastBuyAt = deal.clickedAt
    buySeq = buySeq + 1
    deal.buySeq = buySeq
    busyClicks = 0
    pendingBuys[deal.auctionID] = deal
    if later then
        deal.resend, deal.queued = true, true
        return
    end
    ns.NoteRequest("buy")
    AH.PlaceBid(deal.auctionID, deal.buyout)
end

--- The auction house is ready for a waiting click: its Buy turns into "Buy now", and the chat says it.
local function offer(d)
    d.wait, d.waitAt = nil, nil
    d.buyNow, d.readyAt = true, GetTime()
    waiting[d.auctionID] = d
    ns.Print("auction house ready: click Buy now for %s", d.link or "the gear")
    ns.Log("INFO", "buy", string.format("purchase of %s: the auction house is ready, Buy now offered",
        ns.LogItem(d.itemID, d.link)), { item = d.itemID, auction = d.auctionID })
    ns.Fire("SALVAGER_DEALS")
end

local function isReady() return not AH.IsThrottledMessageSystemReady or AH.IsThrottledMessageSystemReady() end

--- Why a click cannot send a purchase now, or nil: the auction house is busy (a purchase sent now is lost without
--- an answer, SDD 105e). Buy Top shows "..." with this reason; its click does nothing until it is ready.
function Scanner.BuyBusy()
    if not ns.Queue.open or isReady() then return nil end
    if next(pendingBuys) then
        return "The auction house is still answering your last purchase: Buy Top buys the next one the moment it has "
            .. "answered."
    end
    return "The auction house is answering a request of the scan: Buy Top is on again the moment it is ready."
end

--- The answer of the search a click waited for (from readAuctions). `listed` = the auction is still there.
function afterSearch(d, listed)
    if d.wait ~= "search" then return end
    if not listed then
        forget(d)
        removeDeal(d.auctionID)
        ns.Print("%s is no longer listed: someone else bought it", d.link or "the gear")
        ns.Log("INFO", "buy", string.format("purchase of %s: its search no longer lists it, row removed",
            ns.LogItem(d.itemID, d.link)), { item = d.itemID, auction = d.auctionID })
        return
    end
    if not ns.db.buyResendBlocked then
        -- The game may still allow a purchase without a click: send it the moment the auction house is ready.
        send(d, true)
        Scanner.SendWaiting()
        C_Timer.After(1, function() Scanner.SendWaiting(true) end)   -- in case the "ready" event does not come
        return
    end
    -- Current again: its Buy is a plain Buy, on as soon as the auction house is free (no "Buy now" state, 0.4.0).
    forget(d)
    ns.Log("INFO", "buy", string.format("purchase of %s: its search is current again, Buy is on",
        ns.LogItem(d.itemID, d.link)), { item = d.itemID, auction = d.auctionID })
    ns.Fire("SALVAGER_DEALS")
end

--- Buys a deal. Must run from a click (the server needs a hardware event per purchase, and nothing can be sent
--- again without one: SDD 9, 74c). A click on Buy always buys; everything else holds at once (SDD 105):
---   its search is current and the auction house is free: the purchase goes out in this click;
---   a browse came after its search (the purchase would get no answer): its item is searched first, ahead of
---   everything; then its Buy says "Buy now";
---   the auction house is busy (a purchase sent now is lost without any answer): its Buy says "Buy now" the moment
---   the auction house is ready. When the game allows a purchase without a click, it is sent then by itself;
---   a "Buy now" click sends at once, when the auction house is still ready (else it stays "Buy now": never sent
---   while busy).
--- `top` = the click is on Buy Top: while the auction house is busy it does nothing at all (no wait, no chat line;
--- the button says "..." with the reason), so clicking Buy Top again and again buys one auction per answer.
function Scanner.Buy(deal, top)
    if deal.pending or deal.wait or pendingBuys[deal.auctionID] then return end
    if GetMoney() < deal.buyout then ns.Print("not enough money for %s", deal.link or "this gear") return end
    local ready = isReady()
    -- Busy (the answer to the last purchase, or a scan request, is still out): a purchase sent now is lost, and it
    -- cannot be sent later without a click. Every Buy button is off while busy (UI.BuyLook), so this is a click in the
    -- same instant the auction house became busy: nothing is sent and nothing waits; the button lights again in a
    -- moment and the next click buys (0.4.0, the user: no "Buy now" second click).
    if not ready and ns.db.buyResendBlocked then
        busyClicks = busyClicks + 1
        if busyClicks == 1 then
            ns.Log("WARN", "buy", string.format("Buy click on %s%s: the auction house is still answering; nothing sent, "
                .. "the next click after its answer buys (in flight: %s)", ns.LogItem(deal.itemID, deal.link),
                top and " (Buy Top)" or "", inFlight()), { item = deal.itemID, auction = deal.auctionID,
                top = top and true or nil })
        end
        return
    end
    local stale = deal.epoch ~= nil and deal.epoch < Scanner.browseEpoch
    ns.Log("INFO", "buy", string.format("Buy click on %s: auction house %s, %s%s; in flight: %s",
        ns.LogItem(deal.itemID, deal.link), ready and "ready" or "busy",
        stale and "a browse came after its search" or "its search is current", deal.buyNow and ", Buy now" or "",
        inFlight()), { item = deal.itemID, auction = deal.auctionID, buyout = deal.buyout, ready = ready and true or false,
        stale = stale and true or false, buyNow = deal.buyNow and true or nil })
    lastBuyAt = GetTime()
    if stale and deal.task then
        forget(deal)
        deal.wait, deal.waitAt = "search", GetTime()
        waiting[deal.auctionID] = deal
        ns.Print("%s: searching it again first (a scan browse came after its search); Buy now comes in a moment",
            deal.link or "the gear")
        Scanner.Recheck(deal, true)
    elseif ready then
        send(deal)
    elseif not ns.db.buyResendBlocked then
        send(deal, true)
        ns.Log("INFO", "buy", string.format("purchase of %s: the auction house is busy, it goes out the moment it is "
            .. "ready", ns.LogItem(deal.itemID, deal.link)), { item = deal.itemID, auction = deal.auctionID })
        C_Timer.After(1, function() Scanner.SendWaiting(true) end)   -- in case the "ready" event does not come
        ns.Fire("SALVAGER_DEALS")
        return
    end
    ns.Fire("SALVAGER_DEALS")
end

--- Is the auction house free for a purchase now? (Buy buttons are on only then: UI.BuyLook.)
function Scanner.Ready() return isReady() end

-- Waiting clicks: "Buy now" the moment the auction house is ready (its event, or this poll); a wait that lasts is
-- said and dropped, and an offer nobody clicks lapses, so the scan goes on.
local function pollWaiting()
    if next(pendingBuys) then Scanner.Buying() end   -- (says a purchase with no answer on time, BUY_EXPIRES)
    if not next(waiting) then return end
    local now = GetTime()
    for _, d in pairs(waiting) do
        if d.wait == "ready" and isReady() then
            offer(d)
        elseif d.wait and now - d.waitAt >= WAIT_MAX then
            forget(d)
            ns.Print("the auction house did not answer for %s in %ds: click Buy again if it is still listed",
                d.link or "the gear", WAIT_MAX)
            ns.Log("WARN", "buy", string.format("purchase of %s: waited %ds, given up", ns.LogItem(d.itemID, d.link),
                WAIT_MAX), { item = d.itemID, auction = d.auctionID, seconds = WAIT_MAX })
            ns.Fire("SALVAGER_DEALS")
        elseif d.buyNow and now - d.readyAt >= BUY_NOW_HOLD then
            forget(d)
            ns.Log("INFO", "buy", string.format("purchase of %s: Buy now not clicked in %ds, the scan goes on",
                ns.LogItem(d.itemID, d.link), BUY_NOW_HOLD), { item = d.itemID, auction = d.auctionID,
                seconds = BUY_NOW_HOLD })
            ns.Fire("SALVAGER_DEALS")
        end
    end
end
ns.OnTick(pollWaiting)

-- The time the scan waits for purchases (`Scanner.holds`), so a slow scan can be measured.
local holdTickAt
ns.OnTick(function()
    local now = GetTime()
    local dt = holdTickAt and now - holdTickAt or 0
    holdTickAt = now
    if Scanner.state == "idle" and not ns.Prices.scanning then return end
    local why = Scanner.HoldReason()
    if why then Scanner.holds[why] = (Scanner.holds[why] or 0) + dt end
end)
ns.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", pollWaiting)

--- Searches a deal's item again, so its rows show what is listed now. `forBuy` = for a Buy click that waits for it
--- (first in line, past every hold). `live` = { why, onDone }: a search of the Live scan (it may overlap others,
--- SDD 122); onDone() when it is answered or given up. Returns true when a search was queued.
function Scanner.Recheck(deal, forBuy, live)
    local t = deal and deal.task
    if not t or not ns.Queue.open then return end
    -- The value and limit of now: prices or settings may have changed since the scan. (A click keeps the auction it
    -- clicked whatever they say now: the player decided.)
    local band = currentBand(t.quality, t.classID, t.ilvl) or (forBuy and { net = t.net, limit = t.limit })
    if not band then
        ns.Log("INFO", "search", string.format("rechecking %s: its band has no value or limit now, its rows go",
            ns.LogItem(ns.LogBook.ItemOf(t.keyString))), { key = t.keyString })
        removeKey(t.keyString)
        ns.Fire("SALVAGER_DEALS")
        return
    end
    ns.Log("DEBUG", "search", string.format(live and ("searching %s again: " .. live.why)
        or (forBuy and "searching %s again for a Buy click" or "rechecking %s after a purchase"),
        ns.LogItem(ns.LogBook.ItemOf(t.keyString))), { key = t.keyString, forBuy = forBuy and true or nil,
        live = live and true or nil })
    local c = { keyString = t.keyString, net = band.net, limit = band.limit, ilvl = t.ilvl, quality = t.quality,
        classID = t.classID }
    local done = live and live.onDone or function() end
    checkItem(c, t.itemKey, function(task)
        if forBuy then Scanner.prefetchAt = GetTime() end
        readAuctions(task)
        ns.Fire("SALVAGER_DEALS")
        done(task)
    end,
        function()
            if forBuy and deal.wait == "search" then
                forget(deal)
                ns.Print("the search of %s got no answer: click Buy again if it is still listed", deal.link or "the gear")
            end
            ns.Fire("SALVAGER_DEALS")
            done()
        end, forBuy, live and true)
    return true
end


--- The auction a group's Buy buys: one the player clicked that waits or says "Buy now", else the cheapest one not
--- being bought already.
function Scanner.Cheapest(deals)
    local best
    for _, d in ipairs(deals) do
        if (d.wait or d.buyNow) and not d.pending then return d end
    end
    for _, d in ipairs(deals) do
        if not d.pending and (not best or d.buyout < best.buyout) then best = d end
    end
    return best
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
    ns.Print("purchase of %s was dropped by the auction house: click Buy again", d.link or "the gear")
    ns.Log("WARN", "buy", string.format("purchase of %s dropped by the auction house, row freed (%s)",
        ns.LogItem(d.itemID, d.link), why), { item = d.itemID, auction = d.auctionID })
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
    ns.Log(ok and "INFO" or "ERROR", "buy", string.format("purchase of %s sent%s%s", ns.LogItem(d.itemID, d.link),
        d.queued and " (it waited for the auction house)" or string.format(" again (%d of %d)", d.resends,
        MAX_BUY_RESENDS), ok and "" or (": " .. tostring(err))), { item = d.itemID, auction = d.auctionID,
        resends = d.resends, queued = d.queued and true or nil })
    d.queued = nil
    if not ok then free(d, "the game refused it") end
    -- More of them waiting: the next one after this one.
    C_Timer.After(1, function() Scanner.SendWaiting(true) end)
end

ns.On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
    -- With a search on its way too, the dropped request is the search, not the purchase (measured
    -- 2026-11-26 06:10: 23 drops during 36 purchases, each with the recheck search just sent; every
    -- purchase went through). The search sends itself again when it gets no answer.
    local task = ns.Queue.current
    if task and task.sentAt and GetTime() - task.sentAt <= DROP_WINDOW then return end
    -- The game does not allow a resend: nothing can be done about a dropped purchase, and it is often not
    -- the purchase that was dropped (measured 2026-11-26 06:31: rows freed at every purchase, each bought).
    -- It stays on its way until its answer comes, or until BUY_EXPIRES.
    if ns.db.buyResendBlocked then return end
    for _, d in pairs(pendingBuys) do
        if GetTime() - d.clickedAt < DROP_WINDOW and not d.resend then
            if ns.db.buyResendBlocked or (d.resends or 0) >= MAX_BUY_RESENDS then
                free(d, ns.db.buyResendBlocked and "the game does not allow a resend" or "resent 3 times")
            else
                d.resend = true
                d.clickedAt = GetTime()   -- (it stays "on its way": everything else keeps waiting)
                ns.Log("WARN", "buy", string.format("purchase of %s dropped by the auction house: sending it again "
                    .. "when it is ready", ns.LogItem(d.itemID, d.link)), { item = d.itemID, auction = d.auctionID })
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
        ns.Log("WARN", "buy", "the game does not allow a purchase without a click: purchases are not sent again from "
            .. "now on")
    end
    for _, d in pairs(pendingBuys) do
        if d.sentByAddon then free(d, "the game blocked a purchase sent without a click") end
    end
end
ns.On("ADDON_ACTION_BLOCKED", blocked)
ns.On("ADDON_ACTION_FORBIDDEN", blocked)

-- After a purchase its gear is searched again only once the buying has stopped (0.3.144, the user: the search right
-- after each purchase kept the auction house busy for the next click; measured 2026-11-27 04:00-04:16: 110 such
-- searches for 106 purchases, and 111 of the 132 clicks that found the auction house busy came within 2 s after
-- one). The bought auction leaves the list at once; the rest of its gear's rows wait for this one search, made when
-- no Buy was clicked for RECHECK_QUIET and nothing is on its way.
local RECHECK_QUIET = 8
local toRecheck = {}   -- [keyString] = the deal to search again
local function recheckLater(d) if d and d.keyString then toRecheck[d.keyString] = d end end
ns.OnTick(function()
    if not next(toRecheck) or Scanner.Buying() or GetTime() - lastBuyAt < RECHECK_QUIET then return end
    local key, d = next(toRecheck)
    toRecheck[key] = nil
    Scanner.Recheck(d)
end)

ns.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
    -- (A purchase given up as dropped that went through after all is still booked.)
    local d = pendingBuys[auctionID] or dropped[auctionID]
    if pendingBuys[auctionID] then lastAnswerAt = GetTime() end   -- (the clock of the next one starts now)
    pendingBuys[auctionID], dropped[auctionID] = nil, nil
    removeDeal(auctionID)
    if d then
        ns.Print("bought %s for %s (avg profit %s)", d.link or "gear", ns.Money(d.buyout), ns.Money(d.profit))
        local o = ns.Model.Outcomes(d.quality, d.classID, d.ilvl)
        -- (`lo`, `hi`: the pessimistic and optimistic values of one disenchant when bought, SDD 116.)
        ns.Ledger.AuctionPurchase(ns.db.ledger, d.itemID, d.buyout, d.value, time(), d.link,
            { q = d.quality, cls = d.classID, band = o and o.band, ilvl = d.ilvl, v = ns.VERSION, lo = d.low, hi = d.high })
        ns.Log("INFO", "buy", string.format("bought %s for %s, value %s%s", ns.LogItem(d.itemID, d.link),
            ns.Money(d.buyout), ns.Money(d.value), answerNote(d)), answerData(d, { item = d.itemID,
            auction = d.auctionID, paid = d.buyout, value = d.value, ilvl = d.ilvl }))
        ns.Fire("SALVAGER_LEDGER")
        recheckLater(d)
    end
    ns.Fire("SALVAGER_DEALS")
end)

-- The error does not say which purchase it is about: it is the oldest one still on its way.
ns.On("AUCTION_HOUSE_SHOW_ERROR", function()
    -- (The same event answers posts and cancels: it is about a purchase only when one was sent last.)
    if not ns.ErrorIs("buy") then return end
    local d = oldestBuy()
    if not d then return end
    pendingBuys[d.auctionID] = nil
    dropped[d.auctionID] = d
    d.pending = false
    lastAnswerAt = GetTime()
    removeDeal(d.auctionID)
    ns.Print("could not buy %s (sold or changed)", d.link or "the gear")
    ns.Log("ERROR", "buy", string.format("could not buy %s for %s%s", ns.LogItem(d.itemID, d.link), ns.Money(d.buyout),
        answerNote(d)), answerData(d, { item = d.itemID, auction = d.auctionID, buyout = d.buyout }))

    recheckLater(d)
    ns.Fire("SALVAGER_DEALS")
end)

-- New settings (a buy limit, the most to pay, the gear type): rows that are no deal under them go at once.
ns.On("SALVAGER_SETTINGS", function()
    if ns.Live then ns.Live.Forget() end   -- (limits may have moved: every gear is new to the next Live round)
    local gone, limits = 0, nil

    for i = #Scanner.deals, 1, -1 do
        local d = Scanner.deals[i]
        if not limits and not inHand(d) then limits = ns.Limits() end
        local band = not inHand(d) and currentBand(d.quality, d.classID, d.ilvl, limits)
        if not inHand(d) and (not band or d.buyout > band.limit) then
            table.remove(Scanner.deals, i)
            gone = gone + 1
        end
    end
    if gone > 0 then
        ns.Log("INFO", "scan", string.format("settings changed: %d deals left out, they are over their buy limit now",
            gone), { deals = gone })
        ns.Fire("SALVAGER_DEALS")
    end
end)

-- Salvager: the Live scan, what Play runs (SDD 122).
-- A round looks at a few targets (one browse each, sorted by price, page 1 and more only while it is under the buy
-- limit), searches only the gear that changed since its last search, makes the top deals current again, and rests,
-- so the auction house is free when the player clicks Buy. If the auction house does not return the looks in price
-- order, the session falls back to the full rounds (Scanner.Scan).
local _, ns = ...

local AH = C_AuctionHouse
local Scanner = ns.Scanner

local Live = { seen = {}, rounds = 0, targets = 0, unsorted = false, split = {}, cursor = 0 }
ns.Live = Live

local LOOKS_PER_ROUND = 4     -- looks a round sends (round-robin over the targets): about 0.7 s of the lock each
local LOOK_PAGES = 3          -- most pages one look reads
local LOOK_WAIT = 3           -- seconds a look waits for its page; then it is sent again once, then given up
local LOOK_RESENDS = 2        -- times a look is sent again (no page, or dropped)
local LOOK_AFTER_PREFETCH = 3 -- seconds no look goes out after a search for the deal under the mouse (fact 7, SDD 122)
local REQ_BELOW = 8           -- a band's look asks for required levels from its lowest item level minus this
local REQ_TOP = 60            -- the highest required level: a band reaching it asks for no upper level
local ILVL_TOP = 100          -- (the item levels a band is looked at up to, for the open band 61+)
local NO_REQ_MAX = 1          -- the look for gear without a required level: required level up to this
local SORT_TOLERANCE = 0.01   -- share of a page's rows that may be out of price order
local SORT_MIN_BREAKS = 3     -- breaks a page may have whatever its size (a price can change between two pages)
local SEEN_MAX_AGE = 60       -- seconds after which a gear's deals are searched again, changed or not
local TOP_REFRESH = 3         -- top deals of the active sort made current after each round (Buy Top's next ones)
local ROUND_MAX = 40          -- seconds a round may take before it is ended (a safety net)
-- The rest after a round: the setting, and never less than this many times the round's length, so the auction house
-- is free about two thirds of the time whatever a round costs (2 / (1 + 2); the target is at least 60 %).
local REST_PER_ROUND = 2
Live.LOOKS_PER_ROUND, Live.TOP_REFRESH, Live.SEEN_MAX_AGE = LOOKS_PER_ROUND, TOP_REFRESH, SEEN_MAX_AGE

--- Seconds to rest before the next round.
function Live.Rest()
    return math.max(ns.db.settings.liveInterval, (Live.last and Live.last.seconds or 0) * REST_PER_ROUND)
end


local SORTS = {
    { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false },
    { sortOrder = Enum.AuctionHouseSortOrder.Name, reverseSort = false },
}

local round   -- the round in progress: { n, phase = "look"|"search", slice, index, look, ctx, sum, ... }

local function setState(s)
    Scanner.state = s
    ns.Fire("SALVAGER_SCAN")
end

--- Does Play run Live rounds this session? (No once a look came back out of price order.)
function Live.Usable() return not Live.unsorted end

--- Forgets what was searched: every gear is new to the next round (the Gear list was emptied, or settings changed).
function Live.Forget() wipe(Live.seen) end

------------------------------------------------------------------ targets

--- The item levels of [lo, up] the level filter lets through: the lowest and highest, or nil.
local function allowedRange(lo, up)
    local a, b
    for ilvl = lo, math.min(up, ILVL_TOP) do
        if ns.LevelAllowed(ilvl) then
            a = a or ilvl
            b = ilvl
        end
    end
    return a, b
end

--- The required levels a look asks for: `lo` = the lowest item level (nil: from 0, so gear without a required level is
--- in it), `hi` = the highest. The options' required-level filter narrows it. nil when nothing is left.
local function reqRange(lo, hi)
    local s = ns.db.settings
    local minL = lo and lo - REQ_BELOW > 1 and lo - REQ_BELOW or nil
    local maxL = hi and hi < REQ_TOP and hi or nil
    if s.minLevel > 0 then minL = math.max(minL or 0, s.minLevel) end
    if s.maxLevel > 0 then maxL = math.min(maxL or math.huge, s.maxLevel) end
    if minL and maxL and minL > maxL then return nil end
    return true, minL, maxL
end

--- Every target now: per quality and gear type one look over all its bands, or, once that needed a second page
--- (`Live.split`), one per band and one for gear without a required level.
local function buildTargets()
    local out = {}
    for _, pass in ipairs(Scanner.BuildPlan()) do
        local key = pass.quality .. ":" .. pass.classID
        local bands, top, lo, hi = {}, 0, nil, nil
        for _, b in ipairs(pass.bands) do
            local a, z = allowedRange(b.lo or 1, b.up)
            if a and not b.blocked and b.limit > 0 then
                bands[#bands + 1] = { band = b, lo = a, hi = z }
                top = math.max(top, b.limit)
                lo, hi = lo or a, z
            end
        end
        local function add(name, limit, minL, maxL)
            out[#out + 1] = { name = name, quality = pass.quality, classID = pass.classID, pass = pass,
                limit = limit, minLevel = minL, maxLevel = maxL, key = key }
        end
        if #bands > 0 and not Live.split[key] then
            local ok, minL, maxL = reqRange(nil, hi < ILVL_TOP and hi or nil)
            if ok then
                add(pass.name, top, minL, maxL)
                out[#out].merged = true
            end
        elseif #bands > 0 then

            for _, x in ipairs(bands) do
                local ok, minL, maxL = reqRange(x.lo, x.hi < ILVL_TOP and x.hi or nil)
                if ok then
                    add(string.format("%s %d-%s", pass.name, x.lo, x.hi < ILVL_TOP and tostring(x.hi) or "+"), x.band.limit,
                        minL, maxL)
                end
            end
            -- Gear with no required level (0 or 1) is in no band's look: one look for it, at the highest limit.
            local ok, minL, maxL = reqRange(nil, NO_REQ_MAX)
            if ok and ns.db.settings.minLevel <= NO_REQ_MAX then add(pass.name .. ", no level", top, minL, maxL) end
        end
    end
    return out
end
Live.BuildTargets = buildTargets

------------------------------------------------------------------ the round

--- May a look (or its next page) go out now? Never while buying (a click a moment ago: 3 s; a purchase on its way;
--- a click that waits), never on top of a search (it would make it stale), never right after a search for the deal
--- under the mouse, and only when the lock is open.
local function canSend()
    if not ns.Queue.open or Scanner.paused or Scanner.Buying() then return false end
    if #ns.Queue.flying > 0 then return false end
    if Scanner.prefetchAt and GetTime() - Scanner.prefetchAt < LOOK_AFTER_PREFETCH then return false end
    return Scanner.Ready()
end

-- The share of time the auction house was free for a click (ready, nothing of ours on its way), since the last round.
local clock = { total = 0, free = 0 }
local clockAt

local finishRound   -- (below)

local function sendLook(look)
    local t = look.target
    local query = {
        searchString = "", sorts = SORTS,
        filters = { Scanner.QUALITY_FILTER[t.quality] },
        itemClassFilters = { { classID = t.classID } },
    }
    if t.minLevel then query.minLevel = t.minLevel end
    if t.maxLevel then query.maxLevel = t.maxLevel end
    look.askedAt = GetTime()
    look.query = query
    local ok, err = Scanner.SendBrowse(query)
    if not ok then
        ns.Log("ERROR", "scan", string.format("live: the look at %s failed: %s", t.name, tostring(err)),
            { target = t.key, minLevel = t.minLevel, maxLevel = t.maxLevel })
        finishRound("a look failed")
    end
end

local function endLook()
    round.look = nil
end

--- The search phase: the gear under its limit that changed since its last search (new, cheaper, more of it, or its
--- deals older than SEEN_MAX_AGE); the best first, at most the setting's item checks.
local refreshTop   -- (below)
local function startSearches()
    round.phase = "search"
    setState("searching")
    local now = GetTime()
    local list = {}
    for _, c in ipairs(round.ctx.candidates) do
        local s = Live.seen[c.keyString]
        if not s or c.price < s.minPrice or c.quantity > s.quantity or now - s.t >= SEEN_MAX_AGE then
            list[#list + 1] = c
        else
            round.unchanged = round.unchanged + 1
        end
    end
    local byReturn = ns.db.settings.dealSort == "return"
    table.sort(list, function(a, b)
        if byReturn then return a.margin / math.max(1, a.price) > b.margin / math.max(1, b.price) end
        return a.margin > b.margin
    end)
    for i = #list, ns.db.settings.maxChecks + 1, -1 do list[i] = nil end
    local mine = round
    local function done()
        if round ~= mine then return end
        mine.waiting = mine.waiting - 1
        ns.Fire("SALVAGER_DEALS")
        if mine.waiting <= 0 then
            if mine.phase == "search" then refreshTop() else finishRound() end
        end
    end
    round.searched = #list
    round.waiting = #list
    for _, c in ipairs(list) do
        round.searchedKeys[c.keyString] = true
        Scanner.CheckItem(c, c.key, function(task)
            Scanner.ReadAuctions(task)
            Live.seen[c.keyString] = { minPrice = c.price, quantity = c.quantity, t = GetTime() }
            done()
        end, done, false, true)
    end
    round.done = done
    if #list == 0 then refreshTop() end
end

--- After the searches: the top deals of the active sort whose search a look made stale are searched again, so Buy
--- Top's next ones buy with one click (SDD 105i, 122).
function refreshTop()
    round.phase = "refresh"
    Scanner.Sort()
    local keys, n = {}, 0
    for _, d in ipairs(Scanner.deals) do
        if n >= TOP_REFRESH then break end
        if not Scanner.InHand(d) and not keys[d.keyString] then
            keys[d.keyString] = true
            n = n + 1
            if not round.searchedKeys[d.keyString] and d.epoch and d.epoch < Scanner.browseEpoch then
                round.searchedKeys[d.keyString] = true
                round.waiting = round.waiting + 1
                local queued = Scanner.Recheck(d, false, { why = "one of the top " .. TOP_REFRESH .. " deals, a look came "
                    .. "after its search", onDone = round.done })
                if queued then round.refreshed = round.refreshed + 1 else round.waiting = round.waiting - 1 end
            end
        end
    end
    if round.waiting <= 0 then finishRound() end
end

--- Starts the next look of the round, or the searches after the last one.
local function nextLook()
    round.index = round.index + 1
    local t = round.slice[round.index]
    if not t then return startSearches() end
    local pass = t.pass
    round.look = { target = t, got = 0, pages = 0, resends = 0,
        pass = { quality = t.quality, classID = t.classID, bands = pass.bands, top = pass.top, name = t.name, breaks = 0 } }
    round.looks = round.looks + 1
    sendLook(round.look)
    ns.Fire("SALVAGER_SCAN")
end

--- One Live round. `clear` = asked for by a click (Play): the Gear list starts empty.
function Live.Round(clear)
    if not ns.Queue.open or Scanner.state ~= "idle" or round then return end
    if not next(ns.db.prices) then ns.Print("scan material prices first") return end
    if clear then Scanner.ClearDeals() end
    local targets = buildTargets()
    Live.targets = #targets
    if #targets == 0 then
        ns.Log("WARN", "scan", "live: nothing to look at (no quality, gear type and level band with a buy limit above "
            .. "zero)")
        Scanner.ScheduleNext()
        return
    end
    local slice = {}
    for _ = 1, math.min(LOOKS_PER_ROUND, #targets) do
        Live.cursor = Live.cursor % #targets + 1
        slice[#slice + 1] = targets[Live.cursor]
    end
    -- The gear in the list, so a look that shows it dearer drops its rows that are sold.
    local dealKeys = {}
    for _, d in ipairs(Scanner.deals) do dealKeys[d.keyString] = true end
    round = { n = Live.rounds + 1, phase = "look", slice = slice, index = 0, startedAt = GetTime(),
        deadline = GetTime() + ROUND_MAX, ctx = { seen = {}, candidates = {} }, sum = Scanner.NewSum(), dealKeys = dealKeys,
        looks = 0, pages = 0, breaks = 0, rows = 0, searched = 0, unchanged = 0, refreshed = 0, sold = 0, waiting = 0,
        searchedKeys = {} }
    Scanner.browsed = 0
    setState("looking")
    if canSend() then nextLook() end
end

--- Rows of a gear whose cheapest auction now costs more than they do: those auctions are gone (sold).
local function dropSold(keyString, minPrice)
    for i = #Scanner.deals, 1, -1 do
        local d = Scanner.deals[i]
        if d.keyString == keyString and d.buyout < minPrice and not Scanner.InHand(d) then
            table.remove(Scanner.deals, i)
            round.sold = round.sold + 1
        end
    end
end

--- The looks came back out of price order: this session runs the full rounds (they read every page).
local function fallBack(look, breaks, rows, allowed)
    Live.unsorted = true
    ns.Log("WARN", "scan", string.format("live: browse not price-sorted (%s: %d breaks in %d rows, %d allowed): Play "
        .. "runs full rounds for the rest of this session", look.target.name, breaks, rows, allowed),
        { target = look.target.key, breaks = breaks, rows = rows, allowed = allowed })
    ns.Print("the auction house does not sort the listings by price: Play scans full rounds this session")
    round = nil
    setState("idle")
    if Scanner.auto then Scanner.Scan() end
end

--- One page of a look. `added` = the new rows (later pages); nil = read the list (first page).
local function onPage(added)
    local look = round and round.look
    if not look or look.wantMore then return end
    local list, from = added, 1
    if not list then
        list = AH.GetBrowseResults() or {}
        from = look.got + 1
        -- The same list again (the game repeats this event when item data arrives): nothing new.
        if #list < from and look.pages > 0 then return end
    end
    look.resend = nil   -- (the page came after all: not sent again)

    local pass, sum = look.pass, round.sum
    local before = pass.breaks
    for i = from, #list do
        local r = list[i]
        local ok, err = pcall(Scanner.Judge, r, pass, sum, round.ctx)
        if not ok then
            ns.Log("ERROR", "scan", string.format("Lua error judging listing %d of a look at %s: %s", i,
                look.target.name, tostring(err)), { target = look.target.key, listing = i })
        end
        if r.itemKey and r.minPrice and r.minPrice > 0 then
            local ks = ns.KeyString(r.itemKey)
            if round.dealKeys[ks] then dropSold(ks, r.minPrice) end
        end
    end
    local n = math.max(0, #list - from + 1)
    look.got, look.pages = look.got + n, look.pages + 1
    round.pages, round.rows = round.pages + 1, round.rows + n
    Scanner.browsed = sum.browsed
    local breaks = pass.breaks - before
    round.breaks = round.breaks + breaks
    -- The guard: a page out of price order (over a small tolerance) means the stop rule cannot hold.
    local allowed = math.max(SORT_MIN_BREAKS, math.floor(n * SORT_TOLERANCE))
    if breaks > allowed then return fallBack(look, breaks, n, allowed) end
    local last = list[#list]
    local lastPrice = last and last.minPrice
    if n == 0 or AH.HasFullBrowseResults() or not lastPrice or lastPrice > look.target.limit then
        endLook()
    elseif look.target.merged then
        -- One look for the whole quality and gear type is not enough: from the next round, one per band.
        Live.split[look.target.key] = true
        ns.Log("INFO", "scan", string.format("live: %s has more than a page under its buy limit: looked at per item "
            .. "level band from now on", look.target.name), { target = look.target.key })
        endLook()
    elseif look.pages >= LOOK_PAGES then
        ns.Log("DEBUG", "scan", string.format("live: %s still under its buy limit after %d pages: the rest waits for "
            .. "its next look", look.target.name, look.pages), { target = look.target.key, pages = look.pages })
        endLook()
    else
        look.wantMore = true   -- (asked for when the lock is open, see step)
    end
    ns.Fire("SALVAGER_SCAN")
end

ns.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function() onPage(nil) end)
ns.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function(added) onPage(type(added) == "table" and added or nil) end)
ns.On("AUCTION_HOUSE_BROWSE_FAILURE", function()
    if round and round.look then
        ns.Log("WARN", "scan", string.format("live: the auction house reported a failure for the look at %s",
            round.look.target.name), { target = round.look.target.key })
        endLook()
    end
end)

-- A request dropped just after a look (and no search after it): the look goes out again when the lock is open.
ns.On("AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", function()
    local look = round and round.look
    if not look or look.wantMore or look.resend or not look.askedAt or GetTime() - look.askedAt > 2 then return end
    if #ns.Queue.flying > 0 or look.resends >= LOOK_RESENDS then return end
    look.resends = look.resends + 1
    look.resend = true
    ns.Log("WARN", "scan", string.format("live: the auction house dropped the look at %s, sending it again (%d of %d)",
        look.target.name, look.resends, LOOK_RESENDS), { target = look.target.key, resend = look.resends })
end)

--- Another addon or window sent a browse: the looks' results are replaced; this round's looks end here.
function Live.ForeignBrowse()
    if not round or round.phase ~= "look" then return end
    ns.Log("WARN", "scan", "live round dropped: another addon or window started a browse")
    round = nil
    setState("idle")
    Scanner.ScheduleNext()
end

--- Ends the round in progress (Stop, the auction house closed). Its searches still answer; nothing waits for them.
function Live.Abort()
    round = nil
    Live.afterPrices = nil
end

--- The material prices are old: scan them, then the Live round.
function Live.AfterPrices()
    Live.afterPrices = true
    ns.Prices.Scan()
end
ns.On("SALVAGER_PRICES_DONE", function()
    if not Live.afterPrices then return end
    Live.afterPrices = nil
    if Scanner.LiveMode() and Scanner.state == "idle" then Live.Round() end
end)

function finishRound(why)
    local r = round
    if not r then return end
    round = nil
    local now = GetTime()
    local secs = now - r.startedAt
    local held = 0
    for _, t in pairs(Scanner.holds) do held = held + t end
    wipe(Scanner.holds)
    Live.rounds = r.n
    Live.last = { seconds = secs, at = now }
    local free = clock.total > 0 and math.floor(clock.free / clock.total * 100 + 0.5) or 100
    ns.Log("INFO", "scan", string.format("live round %d: %d looks of %d targets, %d pages, %d gear listings, %d breaks, "
        .. "%d under their limit, %d searched, %d unchanged (not searched), %d top deals searched again, %d sold rows "
        .. "gone, %.1fs%s; held for purchases %.1fs; auction house free %d%% of the %.0fs since the last round", r.n,
        r.looks, Live.targets, r.pages, r.rows, r.breaks, #r.ctx.candidates, r.searched, r.unchanged, r.refreshed, r.sold,
        secs, why and (" (" .. why .. ")") or "", held, free, clock.total),
        { round = r.n, looks = r.looks, targets = Live.targets, pages = r.pages, rows = r.rows, breaks = r.breaks,
            candidates = #r.ctx.candidates, searched = r.searched, unchanged = r.unchanged, refreshed = r.refreshed,
            sold = r.sold, seconds = math.floor(secs * 10 + 0.5) / 10, why = why,
            heldS = math.floor(held * 10 + 0.5) / 10, freePct = free })
    clock.total, clock.free = 0, 0
    local sum = r.sum
    sum.seconds, sum.candidates, sum.live = secs, #r.ctx.candidates, true
    Scanner.summary = sum
    setState("idle")
    ns.Fire("SALVAGER_DEALS")
    Scanner.ScheduleNext()
end

--- The round's next step, each tick: the next page or look when the lock is open, a look with no page sent again or
--- given up, the safety net.
local function step()
    local now = GetTime()
    if Scanner.auto then
        local dt = clockAt and now - clockAt or 0
        clock.total = clock.total + dt
        local look = round and round.look
        local waitingPage = look and not look.wantMore and not look.resend
        if Scanner.Ready() and #ns.Queue.flying == 0 and not waitingPage then clock.free = clock.free + dt end
    end
    clockAt = now
    if not round then return end
    if Scanner.paused then
        round.deadline = now + ROUND_MAX
        if round.look then round.look.askedAt = now end
        return
    end
    if now > round.deadline then return finishRound("took over " .. ROUND_MAX .. "s, ended") end
    if round.phase ~= "look" then return end
    local look = round.look
    if not look then
        if canSend() then nextLook() end
        return
    end
    if look.wantMore or look.resend then
        if not canSend() then return end
        if look.resend then
            look.resend = nil
            if look.pages == 0 then return sendLook(look) end
            look.askedAt = now
            AH.RequestMoreBrowseResults()
            return
        end
        look.wantMore = nil
        look.askedAt = now
        AH.RequestMoreBrowseResults()
        return
    end
    if now - look.askedAt >= LOOK_WAIT then
        if Scanner.Buying() then look.askedAt = now return end   -- (a purchase goes first; its answer may be slow)
        if look.resends < LOOK_RESENDS then
            look.resends = look.resends + 1
            look.resend = true
            ns.Log("WARN", "scan", string.format("live: no page for the look at %s in %ds, sending it again (%d of %d)",
                look.target.name, LOOK_WAIT, look.resends, LOOK_RESENDS), { target = look.target.key,
                seconds = LOOK_WAIT, resend = look.resends })
        else
            ns.Log("WARN", "scan", string.format("live: no page for the look at %s, given up for this round",
                look.target.name), { target = look.target.key })
            endLook()
        end
    end
end
ns.OnTick(step)
ns.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", step)

--- The status line of the Live scan: "Live: 20 targets, round 2.1 s, next in 6 s", or what the round does now. nil when
--- Play is off.
function Live.Status()
    if not Scanner.auto then return nil end
    if Live.unsorted then return "Full rounds: browse not price-sorted" end
    local head = string.format("Live: %d target%s", Live.targets, Live.targets == 1 and "" or "s")
    if round then
        if round.phase == "look" then return string.format("%s, looking %d/%d", head, round.index, #round.slice) end
        return string.format("%s, searching %d", head, round.searched + round.refreshed)
    end
    local parts = { head }
    if Live.last then parts[#parts + 1] = string.format("round %.1f s", Live.last.seconds) end
    if Scanner.nextAt and Scanner.state == "idle" then
        parts[#parts + 1] = string.format("next in %d s", math.max(0, math.ceil(Scanner.nextAt - GetTime())))
    end
    return table.concat(parts, ", ")
end

--- (For the specs: the round in progress.)
function Live.Current() return round end

local wow = require("spec.wow")

-- The Live scan (SDD 122) against a small auction house that behaves as measured (FFA's numbers): the lock shuts for
-- 0.7 s after every request, an answer comes 0.2 s after it, a browse comes in pages of PAGE rows sorted by price then
-- name (or, for the fallback, in no order), and a purchase is answered after 0.3 s.
describe("The Live scan", function()
    local env, ns
    local PAGE, LOCK, ANSWER = 20, 0.7, 0.2
    local house, queue, served, bidsSeen, lockUntil, cursor, sorted, silent

    local function link(r) return string.format("|cnIQ%d:|Hitem:%d::::::::30:::::|h[%s]|h|r", r.quality, r.id, r.name) end
    local function key(r) return { itemID = r.id, itemLevel = r.ilvl, itemSuffix = 0 } end
    local function byID(id) for _, r in ipairs(house) do if r.id == id then return r end end end

    -- One gear in the house: `qty` auctions, the cheapest at `price`.
    local function add(id, ilvl, price, qty, classID)
        local r = { id = id, name = "Gear " .. id, quality = 2, classID = classID or 4, ilvl = ilvl,
            req = math.min(60, ilvl - 5), price = price, qty = qty or 1 }
        house[#house + 1] = r
        env.items[id] = { name = r.name, quality = 2, ilvl = ilvl, req = r.req, classID = r.classID }
        return r
    end

    local function matches(r, q)
        local quality = q.filters and q.filters[1] and q.filters[1] - 6
        local class = q.itemClassFilters and q.itemClassFilters[1] and q.itemClassFilters[1].classID
        return r.qty > 0 and (not quality or r.quality == quality) and (not class or r.classID == class)
            and r.req >= (q.minLevel or 0) and r.req <= (q.maxLevel or 999)
    end
    local function results(q)
        local list = {}
        for _, r in ipairs(house) do if matches(r, q) then list[#list + 1] = r end end
        if sorted then
            table.sort(list, function(a, b)
                if a.price ~= b.price then return a.price < b.price end
                return a.name < b.name
            end)
        else
            table.sort(list, function(a, b) return (a.id * 7919) % 101 < (b.id * 7919) % 101 end)   -- a fixed shuffle
        end
        return list
    end
    local function page()
        local out = {}
        for i = cursor.pos + 1, math.min(cursor.pos + PAGE, #cursor.list) do
            local r = cursor.list[i]
            out[#out + 1] = { itemKey = key(r), minPrice = r.price, totalQuantity = r.qty }
        end
        cursor.pos = cursor.pos + #out
        for _, x in ipairs(out) do cursor.shown[#cursor.shown + 1] = x end
        env.ah.browse = cursor.shown
        env.ah.fullBrowse = cursor.pos >= #cursor.list
        return out
    end
    local function answerSearch(k)
        local r = byID(k.itemID)
        local list = {}
        for j = 1, r and r.qty or 0 do
            list[j] = { auctionID = r.id * 10 + j, buyoutAmount = r.price + j - 1, itemLink = link(r) }
        end
        env.ah.itemResults[k.itemID] = list
        wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", k)
    end
    local function later(dt, fn) queue[#queue + 1] = { at = env.now + dt - 1e-6, fn = fn } end

    -- The auction house's side, after each tick: new requests shut the lock and get their answers later.
    local function serve()
        for i = served + 1, #env.ah.sent do
            local s = env.ah.sent[i]
            s.at = env.now
            env.ah.ready, lockUntil = false, env.now + LOCK
            if s.kind == "browse" then
                local q = s.query
                later(ANSWER, function()
                    cursor = { list = results(q), pos = 0, shown = {} }
                    page()
                    wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
                end)
            elseif s.kind == "more" then
                later(ANSWER, function() wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", page()) end)
            elseif s.kind == "search" or s.kind == "refreshI" then
                local k = s.key
                if not silent[k.itemID] then later(ANSWER, function() answerSearch(k) end) end
            end
        end
        served = #env.ah.sent
        for i = bidsSeen + 1, #env.ah.bids do
            local b = env.ah.bids[i]
            b.at = env.now
            env.ah.ready, lockUntil = false, env.now + LOCK
            later(0.3, function()
                local r = byID(math.floor(b.id / 10))
                if r then r.qty = r.qty - 1 end
                wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", b.id)
            end)
        end
        bidsSeen = #env.ah.bids
        local due = {}
        for i = #queue, 1, -1 do
            if queue[i].at <= env.now then table.insert(due, 1, table.remove(queue, i)) end
        end
        for _, d in ipairs(due) do d.fn() end
        if not env.ah.ready and env.now >= lockUntil - 1e-6 then
            env.ah.ready = true
            wow.fire(ns, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
        end
    end
    local function run(seconds, each)
        for _ = 1, math.floor(seconds * 10 + 0.5) do
            wow.tick(ns, 0.1)
            serve()
            if each then each() end
        end
    end
    local function untilRound(n)
        for _ = 1, 3000 do
            if ns.Live.rounds >= n then return end
            run(0.1)
        end
        error("round " .. n .. " never ended")
    end
    local function sentSince(from, kind)
        local out = {}
        for i = from + 1, #env.ah.sent do
            local s = env.ah.sent[i]
            if not kind or s.kind == kind then out[#out + 1] = s end
        end
        return out
    end
    local function searches(from)
        local out = {}
        for _, s in ipairs(sentSince(from)) do
            if s.kind == "search" or s.kind == "refreshI" then out[#out + 1] = s end
        end
        return out
    end
    local function logged(text, from)
        for i = (from or 0) + 1, #ns.db.log do if ns.db.log[i]:find(text, 1, true) then return ns.db.log[i] end end
    end
    local function roundLine(n) return logged("live round " .. n .. ":") end
    local function dealsOf(id)
        local n = 0
        for _, d in ipairs(ns.Scanner.deals) do if d.itemID == id then n = n + 1 end end
        return n
    end

    -- A new client and addon: Uncommon gear of the bands in `bands` (their upper item levels), armor unless `classes`.
    local function fresh(bands, classes)
        env = wow.install()
        house, queue, served, bidsSeen, lockUntil, cursor, sorted, silent = {}, {}, 0, 0, 0, nil, true, {}
        ns = wow.loadAddon()
        for _, m in ipairs(ns.Data.MATERIALS) do env.items[m.id] = { name = m.name, quality = 1, ilvl = 1, classID = 7 } end
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        local s = ns.db.settings
        s.minProfit, s.minReturn, s.priceRescan = 0, 0, 0
        s.qualities = { [2] = true, [3] = false, [4] = false }
        s.gearClasses = classes or "armor"
        local on = {}
        for _, up in ipairs(bands) do on[up] = true end
        for _, b in ipairs(ns.LevelBands()) do s.levelBandsOff[b.up] = not on[b.up] or nil end
        for _, m in ipairs(ns.Data.MATERIALS) do ns.db.prices[m.id] = { p = 2000, units = 20, t = env.clock } end
        ns.db.buyResendBlocked = true   -- the game refuses a purchase without a click (SDD 74c)
    end
    -- The buy limit of Uncommon gear of the band that ends at `up`.
    local function limit(up, classID)
        for _, row in ipairs(ns.Limits()) do
            if row.quality == 2 and row.up == up then return (classID == 2 and row.weapon or row.armor).limit end
        end
    end

    after_each(function() if ns then ns.Scanner.Stop() end end)

    it("sends one look per target, sorted by price then name, reads on only while under the limit, stops at it", function()
        fresh({ 30 })
        local L = limit(30)
        assert.is_true(L > 100)
        for i = 1, 22 do add(500000 + i, 26 + i % 5, math.floor(L / 2) + i) end    -- 22 under the limit
        for i = 1, 8 do add(500100 + i, 26 + i % 5, L * 3 + i) end                 -- 8 over it
        ns.Scanner.Play()
        assert.are.equal("looking", ns.Scanner.state)
        untilRound(1)
        -- Round 1: one look over the whole quality and gear type; its first page is all under the limit, so it is
        -- looked at per band from now on.
        assert.are.equal(1, #sentSince(0, "browse"))
        assert.are.equal(0, #sentSince(0, "more"))
        assert.is_truthy(logged("looked at per item level band from now on"))
        local first = sentSince(0, "browse")[1].query
        assert.are.same({ 0, 1 }, { first.sorts[1].sortOrder, first.sorts[2].sortOrder })   -- Price, then Name
        assert.is_false(first.sorts[1].reverseSort)
        local from = #env.ah.sent
        untilRound(2)
        -- Round 2: the band's look and the look for gear without a required level: one each.
        local looks = sentSince(from, "browse")
        assert.are.equal(2, #looks)
        table.sort(looks, function(x, y) return x.query.maxLevel > y.query.maxLevel end)
        assert.are.equal(18, looks[1].query.minLevel)                -- item level 26 - 8
        assert.are.equal(30, looks[1].query.maxLevel)
        assert.are.equal(1, looks[2].query.maxLevel)                 -- no required level
        assert.is_nil(looks[2].query.minLevel)
        -- Page 1 of the band ends under the limit: page 2 is asked for; it ends over the limit: no page 3.
        assert.are.equal(1, #sentSince(from, "more"))
        assert.is_truthy(roundLine(2):find("2 looks of 2 targets, 3 pages, 30 gear listings, 0 breaks", 1, true))
        assert.are.equal("idle", ns.Scanner.state)
        assert.is_truthy(ns.Live.Status():find("^Live: 2 targets, round %d+%.%d s, next in %d+ s$"))
    end)

    it("searches only the gear that is new, cheaper or more since its search; the rows of the others stay", function()
        fresh({ 30 })
        local L = limit(30)
        local a = add(500001, 28, math.floor(L / 2))
        local b = add(500002, 28, math.floor(L / 2) + 10)
        for i = 3, 5 do add(500000 + i, 28, math.floor(L / 2) + 20 * i) end
        for i = 1, 5 do add(500100 + i, 28, L * 2 + i) end
        ns.Scanner.Play()
        untilRound(1)
        assert.is_truthy(roundLine(1):find("5 under their limit, 5 searched, 0 unchanged", 1, true))
        assert.are.equal(5, #ns.Scanner.deals)
        local from = #env.ah.sent
        untilRound(2)
        assert.is_truthy(roundLine(2):find("5 under their limit, 0 searched, 5 unchanged", 1, true))
        -- (Only the top 3 deals are searched again, to be current for Buy Top: the other two are not.)
        assert.are.equal(3, #searches(from))
        assert.are.equal(5, #ns.Scanner.deals)                       -- every row stays
        a.price = a.price - 1                                        -- cheaper
        b.qty = 2                                                    -- more of it
        from = #env.ah.sent
        untilRound(3)
        assert.is_truthy(roundLine(3):find("2 searched, 3 unchanged", 1, true))
        local ids = {}
        for _, s in ipairs(searches(from)) do ids[s.key.itemID] = true end
        assert.is_true(ids[a.id] and ids[b.id])
        assert.are.equal(2, dealsOf(b.id))                           -- its second auction is listed now
        assert.are.equal(6, #ns.Scanner.deals)
    end)

    it("falls back to the full rounds, with a log line, when a look comes back out of price order", function()
        fresh({ 30 })
        sorted = false
        local L = limit(30)
        for i = 1, 30 do add(500000 + i, 28, L + 1000 * ((i * 37) % 30)) end
        ns.Scanner.Play()
        run(1)
        local line = logged("live: browse not price-sorted (Uncommon Armor: ")
        assert.is_truthy(line)
        assert.is_truthy(line:find("breaks in 20 rows, 3 allowed): Play runs full rounds for the rest of this session", 1,
            true))
        assert.is_false(ns.Live.Usable())
        assert.are_not.equal("idle", ns.Scanner.state)               -- the full round started at once
        local looks = sentSince(0, "browse")
        assert.are.equal(1, #looks[#looks].query.sorts)               -- its browse: by price only, every page
        assert.is_nil(looks[#looks].query.minLevel)
        assert.are.equal("Full rounds: browse not price-sorted", ns.Live.Status())
        for _ = 1, 600 do
            if ns.Scanner.state == "idle" then break end
            run(0.1)
        end
        assert.are.equal(1, #sentSince(0, "more"))                   -- every page, whatever the prices
        assert.are.equal(0, ns.Live.rounds)
    end)

    it("keeps up to 3 searches in flight, each on its own clock, and uses an answer that comes late", function()
        fresh({ 30 })
        local L = limit(30)
        for i = 1, 5 do
            add(500000 + i, 28, math.floor(L / 2) + i)
            silent[500000 + i] = true                                -- no answer for now
        end
        ns.Scanner.Play()
        for _ = 1, 100 do
            if ns.Scanner.state == "searching" then break end
            run(0.1)
        end
        assert.are.equal("searching", ns.Scanner.state)
        local from = #env.ah.sent
        run(2.4)
        assert.are.equal(3, #searches(from))                         -- sent as the lock opened, no answer waited for
        assert.are.equal(3, #ns.Queue.flying)
        assert.are.equal(0, #ns.Scanner.deals)
        run(1)                                                       -- the first one's clock ran out
        local first = searches(from)[1].key
        silent = {}
        answerSearch(first)                                          -- its answer comes now, late
        assert.are.equal(1, dealsOf(first.itemID))                   -- used
        untilRound(1)
        assert.are.equal(5, #ns.Scanner.deals)
    end)

    it("leaves the auction house free at least 60 % of a simulated minute with typical data", function()
        fresh({ 30, 35, 40, 45, 50, 55, 60, 999 }, "both")
        local id = 600000
        for _, classID in ipairs({ 4, 2 }) do
            for _, up in ipairs({ 30, 35, 40, 45, 50, 55, 60, 999 }) do
                local L = limit(up, classID)
                local lo = up == 999 and 61 or up - 4
                for k = 1, 12 do
                    id = id + 1
                    add(id, lo + k % 5, k == 1 and math.floor(L * 0.6) or math.floor(L * (1.5 + k / 4)), 1, classID)
                end
            end
            for k = 1, 30 do id = id + 1 add(id, 18 + k % 7, 50 + k, 1, classID) end   -- cheap gear of the bands off
        end
        ns.Scanner.Play()
        local free, total = 0, 0
        run(60, function()
            total = total + 1
            if env.ah.ready and #queue == 0 then free = free + 1 end
        end)
        assert.is_true(free / total >= 0.6, string.format("free %.0f%%", free / total * 100))
        assert.is_true(ns.Live.rounds >= 3)
        assert.are.equal(18, ns.Live.targets)                        -- 8 bands and the no-level look, per gear type
        assert.is_truthy(logged("auction house free "))
    end)

    it("sends a Buy click during the rest at once, and no look for 3 s after it", function()
        fresh({ 30 })
        local L = limit(30)
        add(500001, 28, math.floor(L / 2))
        add(500002, 28, math.floor(L / 2) + 5)
        ns.Scanner.Play()
        untilRound(1)
        run(1)
        local deal = ns.Scanner.deals[1]
        assert.is_true(deal.epoch >= ns.Scanner.browseEpoch)          -- its search is current
        assert.is_true(env.ah.ready)
        -- Just before the next round would start.
        for _ = 1, 300 do
            if ns.Scanner.nextAt - env.now <= 0.3 then break end
            run(0.1)
        end
        local bids, from = #env.ah.bids, #env.ah.sent
        ns.Scanner.Buy(deal)
        assert.are.equal(bids + 1, #env.ah.bids)                     -- sent in the click
        local clickAt = env.now
        run(2.9)
        assert.are.equal(0, #sentSince(from, "browse"))              -- no look while the buying may go on
        local line = logged("; answered ")
        assert.is_truthy(line and line:find("s after the click, its search was current", 1, true))
        run(3)
        local looks = sentSince(from, "browse")
        assert.is_true(#looks >= 1)
        assert.is_true(looks[1].at - clickAt >= 3)
    end)

    it("searches the top 3 deals of the active sort again after a round, so Buy Top's next ones are current", function()
        fresh({ 30 })
        local L = limit(30)
        for i = 1, 5 do add(500000 + i, 28, math.floor(L / 2) + 10 * i) end
        ns.Scanner.Play()
        untilRound(1)
        local from = #env.ah.sent
        untilRound(2)
        local ids = {}
        for _, s in ipairs(searches(from)) do ids[#ids + 1] = s.key.itemID end
        table.sort(ids)
        assert.are.same({ 500001, 500002, 500003 }, ids)            -- the best three (cheapest of one band)
        assert.is_truthy(roundLine(2):find("3 top deals searched again", 1, true))
        assert.is_truthy(logged("again: one of the top 3 deals, a look came after its search"))
        for _, d in ipairs(ns.Scanner.deals) do
            local current = d.epoch >= ns.Scanner.browseEpoch
            assert.are.equal(d.itemID <= 500003, current)
        end
    end)

    it("leaves Scan once: Gear as it was: one browse by price, every page read", function()
        fresh({ 30 })
        local L = limit(30)
        for i = 1, 30 do add(500000 + i, 28, L * 2 + i) end         -- all over the limit
        ns.Scanner.Scan(true)
        assert.are.equal("browsing", ns.Scanner.state)
        for _ = 1, 600 do
            if ns.Scanner.state == "idle" then break end
            run(0.1)
        end
        local looks = sentSince(0, "browse")
        assert.are.equal(1, #looks)
        assert.are.equal(1, #looks[1].query.sorts)
        assert.is_nil(looks[1].query.minLevel)
        assert.are.equal(1, #sentSince(0, "more"))                   -- page 2 too, though page 1 was over the limit
        assert.are.equal(0, ns.Live.rounds)
    end)
end)

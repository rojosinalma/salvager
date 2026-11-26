local helper = require("spec.helper")

-- Who undercuts you (SDD 109): the events of a search, and the profit lost to competitors (cancel costs, repost
-- deposits, lower sale prices) along the chain listing -> cancel -> repost -> sale.
describe("Competition", function()
    local C, S
    local DUST, VISION = 11083, 11137
    local T = 1800000000
    local mine = { { each = 500, qty = 20 } }
    local function line(each, qty, owners, extra)
        local l = { each = each, qty = qty, ownQty = 0, owners = owners, total = #owners }
        for k, v in pairs(extra or {}) do l[k] = v end
        return l
    end

    before_each(function()
        C = helper.load().Competition
        S = C.Init({})
    end)

    it("counts an undercut by a named owner once per changed line, and the counts add up over checks", function()
        local added = C.Observe(S, DUST, { line(430, 50, { "Bob" }), line(600, 10, { "Ann" }) }, mine, T)
        assert.are.equal(1, #added)                              -- Ann's 6s is not under your 5s
        assert.are.same({ 430, 500, 70, 50, 20, "Bob" }, { added[1].p, added[1].my, added[1].g, added[1].q, added[1].u,
            added[1].o })
        assert.are.equal(0, #C.Observe(S, DUST, { line(430, 50, { "Bob" }) }, mine, T + 60))   -- the same line
        assert.are.equal(1, #C.Observe(S, DUST, { line(430, 40, { "Bob" }) }, mine, T + 120))  -- it changed: 40 left
        assert.are.equal(1, #C.Observe(S, DUST, { line(420, 40, { "Bob" }) }, mine, T + 180))
        assert.are.same({ 3, T, T + 180 }, { S.names.Bob.n, S.names.Bob.first, S.names.Bob.last })
        local list, total = C.Competitors(S)
        assert.are.same({ "Bob", 3, 3 }, { list[1].key, list[1].n, total })
        assert.are.equal(70, list[1].gap)                        -- the median of 70, 70, 80
    end)

    it("never counts your own auctions", function()
        assert.are.equal(0, #C.Observe(S, DUST, { line(450, 20, { "player" }, { ownQty = 20, own = true }) }, mine, T))
        assert.are.equal(0, #C.Observe(S, DUST, { line(450, 20, { "Tester" }) }, mine, T + 1, "Tester"))
        -- A line of yours and someone else's: only the other one counts.
        local added = C.Observe(S, DUST, { line(450, 30, { "player", "Cid" }, { ownQty = 20, own = true }) }, mine, T + 2)
        assert.are.same({ 1, "Cid", 10 }, { #added, added[1].o, added[1].q })
        -- Nothing listed by you: nothing is an undercut.
        assert.are.equal(0, #C.Observe(S, VISION, { line(100, 5, { "Bob" }) }, {}, T))
    end)

    it("groups owners the client does not name as Unknown seller", function()
        local added = C.Observe(S, DUST, { line(430, 5, {}, { total = 1 }) }, mine, T)
        assert.are.same({ C.UNKNOWN }, { added[1].o })
        added = C.Observe(S, DUST, { line(420, 5, { "", "..." }) }, mine, T + 1)
        assert.are.same({ 1, C.UNKNOWN }, { #added, added[1].o })
        -- More owners than names: the rest are Unknown seller too.
        added = C.Observe(S, DUST, { line(410, 9, { "Bob" }, { total = 3 }) }, mine, T + 2)
        assert.are.same({ "Bob", C.UNKNOWN }, { added[1].o, added[2].o })
        assert.are.equal(3, S.names[C.UNKNOWN].n)
    end)

    it("books the profit lost along the chain: cancel costs, the repost's deposit and the lower sale price", function()
        C.NotePost(S, { t = T, id = DUST, auctionID = 1, qty = 20, each = 500, deposit = 60 })
        C.Observe(S, DUST, { line(430, 50, { "Bob" }) }, mine, T + 100)
        assert.is_true(C.NoteCancel(S, { t = T + 200, id = DUST, auctionID = 1, qty = 20, each = 500, fee = 12, deposit = 60 }))
        C.NotePost(S, { t = T + 260, id = DUST, auctionID = 2, qty = 20, each = 429, deposit = 60 })
        -- Undercut again, by Ann this time: cancelled and posted lower once more.
        C.Observe(S, DUST, { line(420, 10, { "Ann" }) }, { { each = 429, qty = 20 } }, T + 400)
        assert.is_true(C.NoteCancel(S, { t = T + 500, id = DUST, auctionID = 2, qty = 20, each = 429, fee = 12, deposit = 60 }))
        C.NotePost(S, { t = T + 560, id = DUST, auctionID = 3, qty = 20, each = 400, deposit = 60 })
        C.NoteSale(S, 3, 15, 400, T + 900)                       -- 5 still unsold: at stake, not lost
        local lost = C.Lost(S)
        assert.are.same({ 72 + 72, 60 + 60, (500 - 400) * 15 }, { lost.cancel, lost.repost, lost.price })
        assert.are.equal(lost.cancel + lost.repost + lost.price, lost.total)   -- the parts add up
        -- Each: the cancel and the repost they caused, and half the price loss (the chain's competitors share it).
        assert.are.equal(72 + 60 + 750, lost.by.Bob.total)
        assert.are.equal(72 + 60 + 750, lost.by.Ann.total)
        assert.are.same({ 72, 60, 750 }, { lost.by.Ann.cancel, lost.by.Ann.repost, lost.by.Ann.price })
        assert.are.equal(lost.total, lost.by.Bob.total + lost.by.Ann.total)
        local total, _, lowered = C.AtStake(S, { { auctionID = 3, id = DUST, qty = 5, each = 400 } }, T + 900)
        assert.are.same({ 500, 500 }, { total, lowered })        -- 5 units 1s under the first price
        local a = C.Answers(S)
        assert.are.same({ 2, 2 }, { a.cancels, a.reposts })
        assert.are.equal(160, a.delay)                           -- (100 to 260 and 400 to 560)
    end)

    it("splits a loss evenly over the owners under your price, Unknown seller included", function()
        C.NotePost(S, { t = T, id = DUST, auctionID = 1, qty = 20, each = 500, deposit = 60 })
        C.Observe(S, DUST, { line(430, 50, { "Bob", "" }), line(450, 5, { "Ann" }) }, mine, T + 10)
        C.NoteCancel(S, { t = T + 20, id = DUST, auctionID = 1, qty = 20, each = 500, fee = 0, deposit = 60 })
        local lost = C.Lost(S)
        assert.are.same({ 20, 20, 20 }, { lost.by.Bob.total, lost.by.Ann.total, lost.by[C.UNKNOWN].total })
    end)

    it("does not count a cancel or a lower price without an undercut", function()
        C.NotePost(S, { t = T, id = DUST, auctionID = 1, qty = 20, each = 500, deposit = 60 })
        assert.is_false(C.NoteCancel(S, { t = T + 20, id = DUST, auctionID = 1, qty = 20, each = 500, fee = 12, deposit = 60 }))
        C.NotePost(S, { t = T + 30, id = DUST, auctionID = 2, qty = 20, each = 450, deposit = 60 })
        C.NoteSale(S, 2, 20, 450, T + 100)
        assert.are.equal(0, C.Lost(S).total)
        -- An undercut seen too long before the cancel does not count either.
        C.Observe(S, DUST, { line(430, 50, { "Bob" }) }, mine, T + 200)
        C.NotePost(S, { t = T + 210, id = DUST, auctionID = 4, qty = 20, each = 500, deposit = 60 })
        assert.is_false(C.NoteCancel(S, { t = T + 200 + C.UNDERCUT_WINDOW + 1, id = DUST, auctionID = 4, qty = 20,
            each = 500, deposit = 60 }))
    end)

    it("keeps its storage bounded and clears", function()
        for i = 1, C.MAX_EVENTS + 10 do C.Observe(S, DUST, { line(400 - (i % 300), i, { "Bob" }) }, mine, T + i) end
        assert.are.equal(C.MAX_EVENTS, #S.events)
        assert.are.equal(C.MAX_EVENTS + 10, S.names.Bob.n)       -- the name keeps its count
        C.Clear(S)
        assert.are.same({ 0, nil }, { #S.events, S.names.Bob })
    end)
end)

describe("Competition in a simulated client", function()
    local wow = require("spec.wow")
    local env, ns
    local DUST = 11083
    local function answer()
        for _ = 1, 20 do
            wow.tick(ns, 0.2)
            local c = ns.Queue.current
            if c and c.commodity then wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", c.commodity) end
        end
    end
    setup(function()
        env = wow.install()
        env.items[DUST] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        env.ah.owned = { { auctionID = 1, itemKey = { itemID = DUST }, status = 0, quantity = 20, timeLeftSeconds = 40000,
            buyoutAmount = 500 } }
        -- The client's lines: Bob and a seller it does not name yet under you, yours, Ann above you.
        env.ah.commodities[DUST] = {
            { unitPrice = 430, quantity = 50, numOwnerItems = 0, owners = { "Bob", "" }, totalNumberOfOwners = 2 },
            { unitPrice = 500, quantity = 20, numOwnerItems = 20, owners = { "player" }, totalNumberOfOwners = 1,
                containsOwnerItem = true },
            { unitPrice = 600, quantity = 10, numOwnerItems = 0, owners = { "Ann" }, totalNumberOfOwners = 1 } }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        ns.Listings.NotePost(1, DUST, 20, 500, 60)
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        wow.tick(ns, 0.5)
    end)

    it("records who undercuts you from an undercut check, once while the lines stay the same", function()
        ns.Listings.Check()
        wow.tick(ns, 0.3)
        answer()
        local names = ns.db.competition.names
        assert.are.same({ 1, 1 }, { names.Bob.n, names[ns.Competition.UNKNOWN].n })
        assert.is_nil(names.Ann)                                  -- above your price
        assert.is_nil(names.player)
        ns.Listings.Check()
        wow.tick(ns, 0.3)
        answer()
        assert.are.equal(1, names.Bob.n)                          -- the same line: not again
        -- The Ledger's Competition subtab lists them, the most seen first.
        ns.LedgerWindow.Show()
        ns.LedgerWindow.tabs.sales:Click()
        ns.LedgerWindow.salesTabs.competition:Click()
        local rows = ns.LedgerWindow.CompetitionRows()
        assert.are.equal("Bob", rows[1].cells[1])
        assert.are.equal("1", rows[1].cells[2])
    end)

    it("books what a cancel of an undercut auction, its repost and the lower sale cost, to those under you", function()
        assert.is_true(ns.Listings.CancelNext())
        for i = #env.ah.owned, 1, -1 do if env.ah.owned[i].auctionID == 1 then table.remove(env.ah.owned, i) end end
        wow.tick(ns, 2)                                           -- the read that shows it gone
        local lost = ns.Competition.Lost(ns.db.competition)
        assert.are.equal(12 + 60, lost.cancel)                    -- the cancel cost the game names, and the deposit
        assert.are.equal(36, lost.by.Bob.total)                   -- half each: Bob and the unknown seller
        ns.Listings.NotePost(2, DUST, 20, 429, 60)                -- the repost
        env.ah.owned = { { auctionID = 2, itemKey = { itemID = DUST }, status = 1, quantity = 20, timeLeftSeconds = 3000,
            buyoutAmount = 429 } }
        wow.fire(ns, "OWNED_AUCTIONS_UPDATED")                    -- sold
        lost = ns.Competition.Lost(ns.db.competition)
        assert.are.same({ 72, 60, (500 - 429) * 20 }, { lost.cancel, lost.repost, lost.price })
        assert.are.equal(lost.total, lost.cancel + lost.repost + lost.price)
        -- The report says the same.
        ns.Reports.Show()
        ns.Reports.tabs.competition:Click()
        local text = {}
        for _, r in ipairs(ns.Reports.CompetitionSummaryRows()) do text[#text + 1] = table.concat(r.cells, " | ") end
        text = table.concat(text, "\n")
        assert.is_truthy(text:find("Reposted after an undercut | 1 of 1", 1, true))
        assert.is_truthy(text:find("Profit lost to competitors", 1, true))
        local comp = ns.Reports.CompetitorRows()
        assert.is_truthy(comp[#comp].cells[12]:find(ns.MoneyColumn(lost.total), 1, true))
    end)

    it("clears with Clear history", function()
        ns.Backup.ClearHistory()
        assert.are.same({}, ns.db.competition.events)
        assert.is_nil(ns.db.competition.names.Bob)
    end)
end)

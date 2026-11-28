local wow = require("spec.wow")

-- The selling side of the books: posts, your auctions, deposits, sales, disenchants and mail.

describe("Posting in a simulated client", function()
    local env, ns, d
    local DUST = 11083
    setup(function()
        env = wow.install()
        env.items[DUST] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        -- One unit far under the market, then the market.
        env.ah.commodities[DUST] = { { unitPrice = 100, quantity = 1, numOwnerItems = 0 },
            { unitPrice = 430, quantity = 50, numOwnerItems = 0 } }
        env.bags[DUST] = 12
        env.bagSlots = { [2] = DUST }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        ns.Ledger.AddStock(ns.db.ledger, DUST, 12, 12 * 300)
        ns.Post.Open(DUST)
        wow.tick(ns, 0.2)
        wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", DUST)
        d = _G.SalvagerPostFrame
    end)

    it("does not follow a thin listing far under the market", function()
        assert.are.equal(100, ns.db.prices[DUST].lo)
        local s = ns.Post.Suggest(DUST)
        assert.are.equal(430, s.lowest)
        assert.are.equal(429, s.price)
        assert.are.equal(1, #s.skipped)
        assert.are.equal(429, d.price:Get())
        assert.is_truthy(d.lines[1]:GetText():find("1 cheaper left out", 1, true))
        -- A real amount at that price is followed.
        local rows = { { price = 100, qty = 5, mine = 0 }, { price = 430, qty = 50, mine = 0 } }
        assert.are.equal(100, ns.Post.Floor(rows).price)
    end)

    it("keeps nothing pending after the confirm question, and closes when the auction is created", function()
        -- (The stand-in's frames answer every unknown field with a function: rawget reads the real value.)
        d.confirm = false
        env.ah.needsConfirm = true
        d.post:Click()
        assert.is_true(rawget(d, "confirm"))
        assert.is_nil(ns.Post.pending)                      -- nothing was posted yet
        env.ah.needsConfirm = false
        d.post:Click()
        assert.is_true(env.ah.posts[#env.ah.posts].confirmed)
        assert.is_table(ns.Post.pending)
        assert.is_true(d:IsShown())                         -- open until the auction house answers
        assert.is_false(d.post:IsEnabled())
        assert.is_truthy(rawget(d.post, "reason"):find("on its way", 1, true))
        wow.fire(ns, "AUCTION_HOUSE_AUCTION_CREATED", 42)
        assert.is_nil(ns.Post.pending)
        assert.is_false(d:IsShown())
        local p = ns.db.posted[#ns.db.posted]
        assert.are.same({ 42, 12, 36 }, { p.auctionID, p.qty, p.deposit })
    end)

    it("takes an error only when the last request was a post, and forgets a post after 10 s or on close", function()
        assert.is_true(ns.Post.Send(DUST, 5, 429, 2))
        ns.NoteRequest("buy")
        wow.fire(ns, "AUCTION_HOUSE_SHOW_ERROR", 1)          -- the purchase's error, not the post's
        assert.is_table(ns.Post.pending)
        ns.NoteRequest("post")
        wow.fire(ns, "AUCTION_HOUSE_SHOW_ERROR", 1)
        assert.is_nil(ns.Post.pending)
        assert.is_true(ns.Post.Send(DUST, 5, 429, 2))
        wow.tick(ns, 11)
        assert.is_nil(ns.Post.Pending())
        assert.is_true(ns.Post.Send(DUST, 5, 429, 2))
        d.scripts.OnHide(d)                                  -- the window closed
        assert.is_nil(ns.Post.pending)
    end)

    it("switches Post off while a purchase is on its way, with the reason, and on again after", function()
        d:Show()
        local done = wow.buying(ns)                          -- a purchase on its way
        wow.tick(ns, 0.2)
        assert.is_false(d.post:IsEnabled())
        assert.is_truthy(rawget(d.post, "reason"):find("purchase", 1, true))
        local ok, why = ns.Post.Send(DUST, 5, 429, 2)
        assert.is_false(ok)
        assert.is_truthy(why:find("purchase", 1, true))
        done()                                               -- its answer
        wow.tick(ns, 1.2)                                    -- (and the second after a click)
        assert.is_true(d.post:IsEnabled())
        assert.is_nil(rawget(d.post, "reason"))
    end)
end)

describe("Your auctions in a simulated client", function()
    local env, ns
    local DUST, VISION = 11083, 11137
    local function answer()
        for _ = 1, 20 do
            wow.tick(ns, 0.2)
            local c = ns.Queue.current
            if c and c.commodity then wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", c.commodity) end
        end
    end
    local function last() local s = ns.db.ledger.sales return s[#s] end
    setup(function()
        env = wow.install()
        env.items[DUST] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        env.items[VISION] = { name = "Vision Dust", quality = 1, ilvl = 1, classID = 7 }
        env.ah.owned = {
            { auctionID = 1, itemKey = { itemID = DUST }, status = 0, quantity = 20, timeLeftSeconds = 40000, buyoutAmount = 500 },
        }
        env.ah.commodities[DUST] = { { unitPrice = 430, quantity = 50, numOwnerItems = 0 },
            { unitPrice = 500, quantity = 20, numOwnerItems = 20 } }
        env.ah.commodities[VISION] = { { unitPrice = 900, quantity = 10, numOwnerItems = 10 } }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        ns.Listings.NotePost(1, DUST, 20, 500, 60)
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        wow.tick(ns, 0.5)
        ns.Ledger.AddStock(ns.db.ledger, DUST, 40, 40 * 300)
    end)

    it("checks the auctions the refresh brings, not the ones read before", function()
        table.insert(env.ah.owned, { auctionID = 2, itemKey = { itemID = VISION }, status = 0, quantity = 10,
            timeLeftSeconds = 40000, buyoutAmount = 900 })
        ns.Listings.Check()
        assert.are.equal(0, ns.Listings.checking.total)      -- waiting for the list
        wow.tick(ns, 0.3)
        assert.are.equal(2, ns.Listings.checking.total)
        answer()
        assert.is_nil(ns.Listings.checking)
        local rows = ns.db.listings.rows
        assert.are.equal(70, ns.Listings.Undercut(rows[1]))
        assert.is_false(ns.Listings.Lowest(rows[2]))
    end)

    it("does not offer a cancel on old data or when the deposits cost more than the gap", function()
        local row, lowest = ns.db.listings.rows[1], ns.db.listings.lowest
        local keep = lowest[DUST]
        lowest[DUST] = { lo = 499, t = time() }             -- 1 copper x 20 = 20, a cancel and a new post cost 72
        assert.is_nil(ns.Listings.Undercut(row))
        lowest[DUST] = keep
        env.clock = env.clock + 121                          -- checked more than 2 minutes ago
        assert.is_nil(ns.Listings.Undercut(row))
        assert.is_nil(ns.Listings.Lowest(row))
        env.clock = env.clock - 121
        assert.are.equal(70, ns.Listings.Undercut(row))
    end)

    it("does not cancel while a purchase is on its way, and says nothing", function()
        local done = wow.buying(ns)
        local before = #env.chat
        assert.is_false(ns.Listings.CancelNext())
        assert.are.equal(before, #env.chat)
        assert.are.equal(0, #env.ah.cancels)
        done()
        wow.tick(ns, 1.1)
    end)

    it("takes an error only when the last request was a cancel, and books the deposit of a cancel as lost", function()
        assert.is_true(ns.Listings.CancelNext())
        ns.NoteRequest("buy")
        wow.fire(ns, "AUCTION_HOUSE_SHOW_ERROR", 1)
        assert.is_true(ns.Listings.Cancelling())             -- still waiting: the error was the purchase's
        wow.fire(ns, "AUCTION_CANCELED", 1)
        assert.is_false(ns.Listings.Cancelling())
        assert.are.same({ "cancelled", -60, 20 }, { last().lost, last().profit, last().qty })
        assert.are.equal(60, ns.Report.Totals().depositsLost)
        local found
        for _, r in ipairs(ns.LedgerWindow.SoldRows(true)) do
            if r.cells[3] and r.cells[3]:find("cancelled", 1, true) then found = r end
        end
        assert.is_table(found)
    end)

    it("knows a cancel from the list of your auctions: this client sends no event for it", function()
        ns.Listings.NotePost(5, VISION, 4, 900, 40)
        table.insert(env.ah.owned, { auctionID = 5, itemKey = { itemID = VISION }, status = 0, quantity = 4,
            timeLeftSeconds = 40000, buyoutAmount = 900 })
        ns.Listings.Refresh(true)
        wow.tick(ns, 0.5)
        local n = #ns.db.ledger.sales
        C_AuctionHouse.CancelAuction(5)                           -- (any window: the call is what counts)
        for i = #env.ah.owned, 1, -1 do if env.ah.owned[i].auctionID == 5 then table.remove(env.ah.owned, i) end end
        wow.tick(ns, 2)                                           -- the addon reads your auctions again
        assert.are.equal(n + 1, #ns.db.ledger.sales)
        assert.are.same({ "cancelled", -40, VISION }, { last().lost, last().profit, last().id })
    end)

    it("shows where a listing stands: what is ahead of it, and whether a repost pays", function()
        ns.Listings.Refresh(true)
        wow.tick(ns, 0.5)
        local row
        for _, r in ipairs(ns.LedgerWindow.ListingRows()) do if r.itemID == DUST then row = r end end
        assert.is_function(row.onClick)                         -- a click on a listing of yours for sale
        row.onClick()
        assert.is_true(_G.SalvagerStandFrame:IsShown())
        assert.is_true(ns.Stand.loading)                        -- its material is searched first
        answer()
        assert.is_false(ns.Stand.loading)
        local mine = ns.Stand.row
        local facts = table.concat(ns.Stand.Facts(mine, ns.Post.Market(DUST)), "\n")
        assert.is_truthy(facts:find("Ahead of you", 1, true))
        assert.is_truthy(facts:find("50 units", 1, true))       -- the other seller's 50 at 4s 30c, under your 5s
        assert.is_truthy(facts:find("To be first again", 1, true))
        _G.SalvagerStandFrame:Hide()
    end)

    it("does not take a sale for a cancel: the game sends the cancel event for both", function()
        local n = #ns.db.ledger.sales
        wow.fire(ns, "AUCTION_CANCELED", 4242)                 -- no cancel was asked for this auction
        assert.are.equal(n, #ns.db.ledger.sales)
    end)

    it("books the deposit of an auction that expired, once", function()
        local n = #ns.db.ledger.sales
        env.ah.owned = {
            { auctionID = 3, itemKey = { itemID = DUST }, status = 0, quantity = 5, timeLeftSeconds = 100, buyoutAmount = 450 },
            { auctionID = 4, itemKey = { itemID = DUST }, status = 0, quantity = 10, timeLeftSeconds = 100, buyoutAmount = 450 },
            { auctionID = 5, itemKey = { itemID = DUST }, status = 0, quantity = 4, timeLeftSeconds = 40000, buyoutAmount = 450 },
        }
        ns.Listings.NotePost(3, DUST, 5, 450, 15)
        ns.Listings.NotePost(4, DUST, 10, 450, 30)
        ns.Listings.NotePost(5, DUST, 4, 450, 12)
        wow.fire(ns, "OWNED_AUCTIONS_UPDATED")
        -- While the auction house is open: the game says so.
        wow.fire(ns, "AUCTION_HOUSE_AUCTIONS_EXPIRED", 3)
        wow.fire(ns, "AUCTION_HOUSE_AUCTIONS_EXPIRED", 3)
        assert.are.equal(n + 1, #ns.db.ledger.sales)
        assert.are.same({ "expired", -15 }, { last().lost, last().net })
        -- Between two reads: gone unsold after its end time. Auction 5 was taken off before its end: not this.
        env.clock = env.clock + 200
        env.ah.owned = { { auctionID = 9, itemKey = { itemID = DUST }, status = 0, quantity = 1, timeLeftSeconds = 40000,
            buyoutAmount = 450 } }
        wow.fire(ns, "OWNED_AUCTIONS_UPDATED")
        assert.are.equal(n + 2, #ns.db.ledger.sales)
        assert.are.same({ "expired", -30, 10 }, { last().lost, last().net, last().qty })
        env.clock = env.clock - 200
    end)

    it("writes the real cut back when the sale's mail is taken", function()
        env.ah.owned = { { auctionID = 6, itemKey = { itemID = DUST }, status = 1, quantity = 3, timeLeftSeconds = 2400,
            buyoutAmount = 480 } }
        wow.fire(ns, "OWNED_AUCTIONS_UPDATED")
        local sale = last()
        assert.are.same({ 3, 72 }, { sale.unpaid, sale.cut })   -- the cut estimated at 5%
        env.inbox = { { sender = "Auction House", subject = "Auction successful: Soul Dust (3)", money = 1390,
            invoice = { "seller", "Soul Dust", "Buyer", 1440, 1440, 0, 50, 0, 0, 0, 3 } } }
        TakeInboxMoney(1)
        env.inbox = {}
        wow.fire(ns, "MAIL_INBOX_UPDATE")
        assert.are.same({ 0, 50, 1390, 1390 - 900 }, { sale.unpaid, sale.cut, sale.net, sale.profit })
        wow.fire(ns, "MAIL_CLOSED")
    end)

    it("keeps what is seen sold through a ledger reset, so it is not booked again", function()
        env.ah.owned = { { auctionID = 7, itemKey = { itemID = DUST }, status = 1, quantity = 2, timeLeftSeconds = 2400,
            buyoutAmount = 480 } }
        wow.fire(ns, "OWNED_AUCTIONS_UPDATED")
        assert.are.equal(2, last().unpaid)
        SlashCmdList.SALVAGER("reset ledger confirm")
        assert.are.equal(0, #ns.db.ledger.sales)
        assert.are.equal(ns.Ledger.DOUBLES_REPAIR, ns.db.ledger.doubleSalesFixed)
        wow.fire(ns, "OWNED_AUCTIONS_UPDATED")
        assert.are.equal(0, #ns.db.ledger.sales)
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)
end)

describe("Disenchants and conversions in a simulated client", function()
    local env, ns
    local BOOTS_LINK = "|cff1eff00|Hitem:5001::::::::30:::::|h[Test Boots]|h|r"
    local DUST, SHARD, CLOTH = 11083, 11084, 2589
    local function disenchant(loot)
        wow.fire(ns, "UNIT_SPELLCAST_SENT", "player", nil, "cast-guid", 13262)
        wow.fire(ns, "ITEM_LOCK_CHANGED", 0, 1)
        env.loot = loot
        wow.fire(ns, "LOOT_READY")
    end
    setup(function()
        env = wow.install()
        env.items[5001] = { name = "Test Boots", quality = 2, ilvl = 28, req = 23, classID = 4 }
        env.items[DUST] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        env.items[CLOTH] = { name = "Linen Cloth", quality = 1, ilvl = 1, classID = 7 }
        env.bagLinks = { ["0:1"] = BOOTS_LINK }
        env.guids = { ["0:1"] = "Item-1" }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
    end)

    it("books only disenchanting materials that come from the item", function()
        disenchant({ { id = DUST, qty = 2, source = "Item-1" }, { id = CLOTH, qty = 1, source = "Item-1" },
            { id = SHARD, qty = 1, source = "Creature-0-1" } })
        local rec = ns.db.ledger.disenchants[1]
        assert.are.same({ [DUST] = 2 }, rec.got)
        disenchant({ { id = CLOTH, qty = 3 } })              -- no material at all: not a disenchant result
        assert.are.equal(1, #ns.db.ledger.disenchants)
        disenchant({ { id = SHARD, qty = 1 } })              -- the client does not say the source: taken
        assert.are.equal(2, #ns.db.ledger.disenchants)
    end)

    it("does not read a bag change that comes with loot or mail as a conversion", function()
        local greater = 11082   -- Greater Astral Essence
        local lesser = ns.Data.ESSENCE_PAIR[greater].other
        local stock = ns.db.ledger.stock
        stock[lesser] = { qty = 6, cost = 3000, unknown = 0 }
        env.bags[lesser], env.bags[greater] = 6, 0
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        wow.fire(ns, "LOOT_READY")
        env.bags[lesser], env.bags[greater] = 3, 1
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        assert.are.equal(6, stock[lesser].qty)
        assert.is_nil(stock[greater])
        wow.tick(ns, 3)
        TakeInboxItem(1, 1)
        env.bags[lesser], env.bags[greater] = 0, 2
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        assert.are.equal(6, stock[lesser].qty)
        wow.tick(ns, 3)
        env.bags[lesser], env.bags[greater] = 3, 1           -- a split, on its own
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        assert.are.equal(9, stock[lesser].qty)
    end)
end)

describe("Old ledger records in a simulated client", function()
    it("are dropped on load after 30 days", function()
        local env = wow.install()
        local old, recent = env.clock - 31 * 86400, env.clock - 3600
        _G.SalvagerDB = { ledger = {
            bought = { { itemID = 1, each = 5, t = old }, { itemID = 2, each = 5, t = recent } },
            purchases = { [1] = { { each = 5, t = old } }, [2] = { { each = 5, t = recent } } },
            sales = { { id = 11083, count = 2, unpaid = 2, each = 100, gross = 200, cut = 10, net = 190, cost = 0,
                untracked = 2, profit = 190, t = old } },
        } }
        local ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        local l = ns.db.ledger
        assert.are.equal(1, #l.bought)
        assert.is_nil(l.purchases[1])
        assert.are.same({ 0, true }, { l.sales[1].unpaid, l.sales[1].unpaidExpired })
        assert.are.same({ 0, 190 }, { l.sales[1].profit, l.sales[1].netUntracked })   -- no known cost: no profit
        -- The costs are shared per band once (SDD 4), after a backup, with one line in the log.
        assert.are.equal(ns.Ledger.JOINT_COST, l.jointCost)
        assert.are.equal("before sharing the costs per band", ns.Backup.Last().reason)
        assert.is_nil(ns.Backup.Last().ledger.jointCost)
        local lines = 0
        for _, line in ipairs(ns.db.log) do if line:find("shared per band once", 1, true) then lines = lines + 1 end end
        assert.are.equal(1, lines)
        -- A second load does nothing again.
        local backups = #ns.Backup.List()
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        assert.are.equal(backups, #ns.Backup.List())
    end)
end)

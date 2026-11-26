local wow = require("spec.wow")

describe("The gold journal in a simulated client", function()
    local env, ns
    local BOOTS_LINK = "|cff1eff00|Hitem:5001::::::::30:::::|h[Test Boots]|h|r"

    local function money(amount)
        env.money = env.money + amount
        wow.fire(ns, "PLAYER_MONEY")
    end

    setup(function()
        env = wow.install()
        env.items[5001] = { name = "Test Boots", quality = 2, ilvl = 28, req = 23, classID = 4 }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
    end)

    local function last() local e = ns.db.money.entries return e[#e] end

    it("starts from the gold at login", function()
        assert.are.equal(1000000, ns.db.money.chars["Tester-Realm"].b)
        assert.are.equal("start", last().k)
    end)

    it("books a purchase as gear bought, with what it was valued as", function()
        local deal = { auctionID = 501, itemID = 5001, link = BOOTS_LINK, buyout = 9125, value = 22000, profit = 12875,
            quality = 2, classID = 4, ilvl = 28 }
        ns.Scanner.Buy(deal)
        money(-9125)
        assert.are.same({ "buy", -9125, BOOTS_LINK }, { last().k, last().d, last().r })
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 501)
        local p = ns.db.ledger.purchases[5001][1]
        assert.are.same({ 2, 4, 30, ns.VERSION }, { p.j.q, p.j.cls, p.j.band, p.j.v })
    end)

    it("books mail money: an auction sale as a sale, other money as mail", function()
        wow.fire(ns, "MAIL_SHOW")
        env.inbox[1] = { sender = "Auction House", subject = "Auction successful: Soul Dust (2)", money = 1140,
            invoice = { "seller", "Soul Dust", "Buyer", 1200, 1200, 60, 60, 0, 0, 0, 2 } }
        env.inbox[2] = { sender = "Alt", subject = "gold", money = 50000, invoice = {} }
        TakeInboxMoney(1)
        money(1140)
        assert.are.same({ "sale", "Soul Dust" }, { last().k, last().r })
        TakeInboxMoney(2)
        money(50000)
        assert.are.equal("mail", last().k)
        wow.fire(ns, "MAIL_CLOSED")
        env.inbox = {}
    end)

    it("tells vendor sales, vendor buys and repairs apart by the window open", function()
        wow.fire(ns, "MERCHANT_SHOW")
        money(300)
        assert.are.equal("vendor", last().k)
        money(-200)
        assert.are.equal("merchant", last().k)
        RepairAllItems()
        money(-150)
        assert.are.equal("repair", last().k)
        wow.fire(ns, "MERCHANT_CLOSED")
        wow.tick(ns, 3)
        money(25)
        assert.are.equal("other", last().k)
    end)

    it("tells the kind by the window opened last, also when the game did not say the other one closed", function()
        wow.fire(ns, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 17)   -- the mailbox, never closed
        wow.fire(ns, "PLAYER_INTERACTION_MANAGER_FRAME_SHOW", 21)   -- then the auction house
        money(-500)
        assert.are.equal("auction", last().k)
        wow.fire(ns, "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", 21)
        wow.tick(ns, 3)
        money(10)
        assert.are.equal("other", last().k)
    end)

    it("does not read the gold at logout (the game says 0 then)", function()
        local n = #ns.db.money.entries
        env.money, env.realMoney = 0, env.money
        wow.fire(ns, "PLAYER_LOGOUT")
        assert.are.equal(n, #ns.db.money.entries)
        env.money = env.realMoney
    end)

    it("starts each day of the log with a date line, and filters trades and errors", function()
        ns.db.logDay = "1999-01-01"
        ns.Log("bought [Boots] for 1s")
        local log = ns.db.log
        assert.is_truthy(log[#log - 1]:find("^== "))
        local trades = { "trades", "", { "bought " } }
        assert.is_true(ns.LogWindow.Matches(log[#log], trades))
        assert.is_false(ns.LogWindow.Matches("12:00:00 checked item 5", trades))
        assert.is_true(ns.LogWindow.Matches(log[#log - 1], trades))   -- day lines always show
        assert.is_truthy(table.concat(log, "\n"):find("session: Tester%-Realm logged in"))
    end)

    it("reports the period: start, now, what is in the mail, and the buys that lost", function()
        ns.db.ledger.sales[#ns.db.ledger.sales + 1] = { id = 11083, count = 2, unpaid = 2, net = 2000, gross = 2100,
            cut = 100, t = time() }
        ns.db.ledger.disenchants[#ns.db.ledger.disenchants + 1] = { link = BOOTS_LINK, costKnown = true, cost = 9125,
            value = 2464, quality = 2, classID = 4, band = 30, boughtAt = time(), t = time(),
            judged = { q = 3, cls = 4, band = 30 } }
        local before = #env.chat
        SlashCmdList.SALVAGER("gold 24")
        local out = table.concat(env.chat, "\n", before + 1)
        assert.is_truthy(out:find("at the start:", 1, true))
        assert.is_truthy(out:find("in the mail:", 1, true))
        assert.is_truthy(out:find("Gear bought:", 1, true))
        assert.is_truthy(out:find("valued wrong", 1, true))
        ns.Reports.Toggle()
        ns.Reports.view = "gold"
        ns.Reports.Refresh()
        local log = ns.Reports.ChangeRows()
        assert.is_true(#log >= 5)
        local statement = ns.Reports.StatementRows()
        local text = {}
        for _, r in ipairs(statement) do text[#text + 1] = r.cells[1] end
        text = table.concat(text, "\n")
        for _, want in ipairs({ "Sales, after the auction house cut", "Trading profit", "Change in your stock's value",
            "Total: how much richer you are", "Gold not from trading", "Check against your gold", "Money in the mail" }) do
            assert.is_truthy(text:find(want, 1, true), want)
        end
        for _, tab in ipairs({ "changes", "statement" }) do ns.Reports.goldTab = tab ns.Reports.Refresh() end
        -- Every view draws, with data and the time picked: Gear (its subtabs Bands and History), Materials.
        for _, v in ipairs({ { "gear", "bands" }, { "gear", "history" }, { "materials" } }) do
            ns.Reports.view, ns.Reports.gearTab = v[1], v[2] or ns.Reports.gearTab
            for _, range in ipairs({ "24h", "all" }) do ns.Reports.range = range ns.Reports.Refresh() end
            local set = rawget(ns.Reports.list, "columnSet")
            assert.are.equal(v[2] == "history" and "reports.items" or v[2] == "bands" and "reports.profit"
                or "reports.materials", set)
        end
        local rows = ns.Reports.ProfitRows()
        assert.are.same({ "Total", "total" }, { rows[#rows].cells[1], rows[#rows].rule })   -- the totals row last
        assert.is_truthy(rows[1].cells[1]:find("Armor", 1, true))                -- gear type first
        assert.is_truthy(rows[2].cells[1]:find("Uncommon", 1, true))             -- quality under it
        assert.are.equal("26-30", rows[3].cells[1])                              -- the range only
        -- Each heading opens and closes (its arrow says which); a closed one keeps its totals; the state is kept.
        assert.is_true(rows[1].open and rows[2].open)
        local n = #rows
        rows[2].onClick()
        rows = ns.Reports.ProfitRows()
        assert.are.equal(n - 1, #rows)                                           -- the band under Uncommon is gone
        assert.is_false(rows[2].open)
        assert.are.equal(rows[1].cells[4], rows[2].cells[4])                     -- its Paid stays on the heading
        assert.is_true(ns.db.groups["reports.bands"]["4:2"])
        rows[1].onClick()
        assert.are.equal(2, #ns.Reports.ProfitRows())                            -- Armor closed: the heading, the total
        ns.Reports.ProfitRows()[1].onClick()
        ns.Reports.ProfitRows()[2].onClick()
        assert.are.equal(n, #ns.Reports.ProfitRows())
        assert.is_nil(next(ns.db.groups["reports.bands"]))
        assert.are.equal(1, #ns.Reports.ItemRows())
        ns.Reports.filter.classes[4] = nil                                       -- weapons only: nothing
        assert.are.equal(1, #ns.Reports.ProfitRows())
        assert.is_truthy(ns.Reports.ProfitRows()[1].cells[1]:find("filters", 1, true))
        ns.Reports.filter.classes[4] = true
        ns.Reports.filter.salvager = "with"
        assert.are.equal(1, #ns.Reports.ProfitRows())
        ns.Reports.filter.salvager = "all"
        -- Held (bags and bank) and listed are apart.
        env.bags[11083] = 7
        ns.db.listings.rows = { { itemID = 11083, qty = 5, sold = false }, { itemID = 11083, qty = 2, sold = true } }
        assert.are.same({ 7, 5 }, { ns.Reports.HeldAndListed(11083) })
        local l = ns.Gold.Losses(0)[1]
        assert.are.same({ -6661, true }, { l.loss, l.misjudged })
    end)
end)

describe("The gold journal at login", function()
    it("waits for the realm name, and moves records kept without it", function()
        local realm = ""
        wow.install()
        _G.GetRealmName = function() return realm end
        _G.UnitName = function() return "Solo" end
        local ns = wow.loadAddon()
        _G.SalvagerDB = { money = { chars = { ["Solo-"] = { b = 50, t = 1 } },
            entries = { { t = 1, c = "Solo-", d = 0, b = 50, k = "start" } } } }
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
        assert.is_nil(ns.Gold.Char())                           -- no realm yet: no session yet
        realm = "Realm"
        wow.tick(ns, 1.5)
        assert.are.equal("Solo-Realm", ns.Gold.Char())
        assert.is_table(ns.db.money.chars["Solo-Realm"])
        assert.is_nil(ns.db.money.chars["Solo-"])
        assert.are.equal("Solo-Realm", ns.db.money.entries[1].c)
        local e = ns.db.money.entries[#ns.db.money.entries]          -- the gold moved while the addon was off
        assert.are.same({ "unseen", 1000000 - 50 }, { e.k, e.d })
    end)
end)

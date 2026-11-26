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
        assert.are.same({ 2, 4, 30, "test" }, { p.j.q, p.j.cls, p.j.band, p.j.v })
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

    it("finds a change made while the addon was off at the next login", function()
        env.money = env.money + 777
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
        assert.are.same({ "unseen", 777 }, { last().k, last().d })
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
        ns.LedgerWindow.Toggle()
        ns.LedgerWindow.view = "gold"
        ns.LedgerWindow.Refresh()
        local sums, log = ns.LedgerWindow.GoldRows()
        assert.are.equal("At the start", sums[1].cells[1])
        assert.is_truthy(sums[4].cells[1]:find("In the mail", 1, true))
        assert.is_true(#log >= 5)
        local l = ns.Gold.Losses(0)[1]
        assert.are.same({ -6661, true }, { l.loss, l.misjudged })
    end)
end)

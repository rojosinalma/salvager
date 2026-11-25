local wow = require("spec.wow")

describe("Salvager in a simulated client", function()
    local env, ns
    local BOOTS, BOOTS_LINK = 5001, "|cff1eff00|Hitem:5001::::::::30:::::|h[Test Boots]|h|r"

    local function answerCommoditySearches(times)
        for _ = 1, times do
            wow.tick(ns, 0.2)
            local current = ns.Queue.current
            if current and current.commodity then
                wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", current.commodity)
            end
        end
    end

    setup(function()
        env = wow.install()
        for _, m in ipairs({ { 11083, "Soul Dust" }, { 11082, "Greater Astral Essence" }, { 11084, "Large Glimmering Shard" },
            { 11137, "Vision Dust" } }) do
            env.items[m[1]] = { name = m[2], quality = 1, ilvl = 1, classID = 7 }
        end
        env.items[BOOTS] = { name = "Test Boots", quality = 2, ilvl = 28, req = 23, classID = 4 }
        env.ah.commodities[11083] = { { unitPrice = 433, quantity = 50, numOwnerItems = 0 } }
        env.ah.commodities[11082] = { { unitPrice = 1700, quantity = 5, numOwnerItems = 0 },
            { unitPrice = 1832, quantity = 30, numOwnerItems = 0 } }
        env.ah.commodities[11084] = { { unitPrice = 5780, quantity = 3, numOwnerItems = 0 } }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
    end)

    it("loads and opens with the auction house", function()
        local before = #env.chat
        assert.is_table(ns.db)
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        assert.is_true(_G.SalvagerFrame:IsShown())
        assert.are.equal(before, #env.chat, env.chat[#env.chat])
    end)

    it("prices materials from the cheapest units", function()
        ns.Prices.Scan()
        answerCommoditySearches(40)
        assert.is_false(ns.Prices.scanning)
        assert.are.equal(433, ns.db.prices[11083].p)
        -- 5 at 17s + 15 at 18.32s = average of the cheapest 20
        assert.are.equal(math.floor((5 * 1700 + 15 * 1832) / 20 + 0.5), ns.db.prices[11082].p)
        assert.is_nil(ns.db.prices[11137].p)
    end)

    it("finds a deal and buys it", function()
        ns.db.settings.minProfit = 100
        env.ah.browse = { { itemKey = { itemID = BOOTS, itemLevel = 28, itemSuffix = 0 }, minPrice = 500, totalQuantity = 2 } }
        ns.Scanner.Scan()
        assert.are.equal("browsing", ns.Scanner.state)
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        env.ah.itemResults[BOOTS] = {
            { auctionID = 77, buyoutAmount = 500, itemLink = BOOTS_LINK, containsOwnerItem = false },
            { auctionID = 78, buyoutAmount = 5000, itemLink = BOOTS_LINK, containsOwnerItem = false },
        }
        wow.tick(ns, 0.5)
        wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", { itemID = BOOTS, itemLevel = 28, itemSuffix = 0 })
        assert.are.equal("idle", ns.Scanner.state)
        assert.are.equal(1, #ns.Scanner.deals)
        local deal = ns.Scanner.deals[1]
        assert.are.equal(77, deal.auctionID)
        assert.is_true(deal.profit > 0)
        ns.UI.view = "deals"
        ns.UI.Refresh()
        ns.Scanner.Buy(deal)
        assert.are.equal(77, env.ah.bids[1].id)
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 77)
        assert.are.equal(0, #ns.Scanner.deals)
    end)

    it("records the purchase from the Auction won mail", function()
        env.inbox[1] = { sender = "Auction House", subject = "Auction won: Test Boots", link = BOOTS_LINK,
            invoice = { "buyer", "Test Boots", "Seller", 500, 500, 0, 0, 0, 0, 0, 1 } }
        assert.are.equal(1, #ns.db.ledger.purchases[BOOTS])   -- recorded when bought
        TakeInboxItem(1, 1)
        AutoLootMailItem(1)   -- the same mail again must not count twice
        assert.are.equal(1, #ns.db.ledger.purchases[BOOTS])
        assert.are.equal(500, ns.db.ledger.purchases[BOOTS][1].each)
    end)

    it("books a disenchant with the purchase cost", function()
        env.bagLinks = { ["0:1"] = BOOTS_LINK }
        env.auras = { { name = "Arcane Salvager", spellId = 4242 } }
        wow.fire(ns, "UNIT_SPELLCAST_SENT", "player", nil, "cast-guid", 13262)
        wow.fire(ns, "ITEM_LOCK_CHANGED", 0, 1)
        env.loot = { { id = 11083, qty = 2 } }
        wow.fire(ns, "LOOT_READY")
        local rec = ns.db.ledger.disenchants[1]
        assert.is_table(rec)
        assert.are.equal(500, rec.cost)
        assert.is_true(rec.salvager)
        assert.are.equal(30, rec.band)
        assert.are.equal(2, ns.db.ledger.stock[11083].qty)
        assert.are.equal(500, ns.db.ledger.stock[11083].cost)
        assert.are.equal("Arcane Salvager", ns.db.auraSeen[4242])
    end)

    it("books a material sale from the Auction successful mail", function()
        env.inbox[2] = { sender = "Auction House", subject = "Auction successful: Soul Dust (2)",
            invoice = { "seller", "Soul Dust", "Buyer", 1200, 1200, 60, 60, 0, 0, 0, 2 } }
        TakeInboxMoney(2)
        local sale = ns.db.ledger.sales[1]
        assert.are.equal(2, sale.count)
        assert.are.equal(1140, sale.net)
        assert.are.equal(640, sale.profit)
        assert.is_nil(ns.db.ledger.stock[11083])
    end)

    it("adds tooltip lines without errors", function()
        local lines = {}
        GameTooltip.AddDoubleLine = function(_, l, r) lines[#lines + 1] = l .. " = " .. tostring(r) end
        env.tooltipPost(GameTooltip, { hyperlink = BOOTS_LINK })
        env.tooltipPost(GameTooltip, { hyperlink = "|Hitem:11083|h" })
        assert.is_true(#lines >= 3)
        assert.is_nil(ns.tooltipErrorShown)
    end)

    it("draws every view and runs the slash commands", function()
        for _, v in ipairs({ "deals", "materials", "limits" }) do
            ns.UI.view = v
            ns.UI.Refresh()
        end
        local before = #env.chat
        SlashCmdList.SALVAGER("minprofit 20s")
        assert.are.equal(2000, ns.db.settings.minProfit)
        SlashCmdList.SALVAGER("stock 11137 40 6s")
        assert.are.equal(40, ns.db.ledger.stock[11137].qty)
        assert.are.equal(24000, ns.db.ledger.stock[11137].cost)
        SlashCmdList.SALVAGER("salvager off")
        assert.is_false(ns.SalvagerForBuy())
        SlashCmdList.SALVAGER("report")
        SlashCmdList.SALVAGER("auras")
        SlashCmdList.SALVAGER("help")
        assert.is_true(#env.chat > before)
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)

    it("closes cleanly", function()
        wow.fire(ns, "AUCTION_HOUSE_CLOSED")
        assert.is_false(ns.Queue.open)
    end)
end)

describe("Salvager window and options", function()
    local env, ns

    setup(function()
        env = wow.install()
        env.items[11083] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        env.ah.commodities[11083] = { { unitPrice = 433, quantity = 50, numOwnerItems = 0 } }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
    end)

    it("registers the options panel and a minimap button", function()
        assert.is_true(env.settingsRegistered)
        assert.is_table(_G.SalvagerMinimapButton)
        _G.SalvagerMinimapButton:Click("RightButton")
        assert.is_true(env.settingsOpened)
        _G.SalvagerOptionsPanel:Show()
        ns.db.settings.minimap.hide = true
        ns.Fire("SALVAGER_SETTINGS")
        assert.is_false(_G.SalvagerMinimapButton:IsShown())
    end)

    it("scans materials, then gear, with Scan both", function()
        env.ah.browse = {}
        ns.ScanBoth()
        assert.is_true(ns.Busy())
        for _ = 1, 40 do
            wow.tick(ns, 0.2)
            local c = ns.Queue.current
            if c and c.commodity then wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", c.commodity) end
        end
        assert.are.equal("browsing", ns.Scanner.state)
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        wow.tick(ns, 0.2)
        assert.is_false(ns.Busy())
        assert.is_table(ns.Scanner.summary)
    end)

    it("sends only the chosen gear type to the auction house", function()
        ns.db.settings.gearClasses = "weapons"
        ns.Scanner.Scan()
        local q
        for _, s in ipairs(env.ah.sent) do if s.kind == "browse" then q = s.query end end
        assert.are.equal(1, #q.itemClassFilters)
        assert.are.equal(2, q.itemClassFilters[1].classID)
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    end)

    it("lists buy limits per band", function()
        local rows = ns.Limits()
        assert.are.equal(#ns.Data.GREEN, #rows)
        local r = rows[5]  -- item level 31-35: soul dust
        assert.is_true(r.armor.value > 0)
        assert.are.equal(math.max(0, r.armor.value - ns.db.settings.minProfit), r.armor.limit)
        assert.is_false(r.armor.manual)
        ns.SetLimitOverride(2, 4, r.armor.band, 123)
        local again = ns.Limits()[5]
        assert.are.equal(123, again.armor.limit)
        assert.is_true(again.armor.manual)
        assert.are.equal(r.armor.recommended, again.armor.recommended)
        assert.are.equal(123, (ns.BuyLimit(2, 4, r.armor.band, 99999)))
        ns.SetLimitOverride(2, 4, r.armor.band, nil)
        assert.is_false(ns.Limits()[5].armor.manual)
    end)

    it("draws every view and the log panel without errors", function()
        for _, v in ipairs({ "deals", "materials", "limits" }) do
            ns.UI.view = v
            ns.UI.Refresh()
        end
        ns.UI.view = "limits"
        ns.UI.Refresh()
        ns.LogPanel.Toggle()
        ns.LogPanel.mode = "activity"
        ns.LogPanel.Refresh()
        ns.LogPanel.mode = "results"
        ns.LogPanel.Refresh()
        assert.is_true(#ns.db.log > 0)
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)

    it("reads gold, silver and copper boxes", function()
        local got
        local m = ns.Widgets.Money(_G.UIParent, function(c) got = c end)
        m:Set(12345)
        assert.are.equal(12345, m:Get())
        m.boxes[2]:SetText("50")
        m.boxes[2].scripts.OnEditFocusLost(m.boxes[2])
        assert.are.equal(15045, got)
    end)
end)

describe("Salvager scan safety", function()
    local env, ns
    setup(function()
        env = wow.install()
        env.items[11083] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        env.items[5001] = { name = "Test Boots", quality = 2, ilvl = 28, classID = 4 }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        ns.db.prices[11083] = { p = 433, t = 0 }
        ns.db.settings.minProfit = 0
    end)

    it("carries on when a browse page never comes", function()
        env.ah.fullBrowse = false
        env.ah.browse = { { itemKey = { itemID = 5001, itemLevel = 28, itemSuffix = 0 }, minPrice = 1 } }
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        assert.are.equal("browsing", ns.Scanner.state)
        wow.tick(ns, 20)
        assert.are.equal("idle", ns.Scanner.state)
        assert.are.equal(1, ns.Scanner.summary.browsed)
    end)

    it("stops loading pages once items cost more than every buy limit", function()
        env.ah.fullBrowse = false
        env.ah.browse = { { itemKey = { itemID = 5001, itemLevel = 28, itemSuffix = 0 }, minPrice = 999999 } }
        local before = #env.ah.sent
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        for i = before + 1, #env.ah.sent do assert.are_not.equal("more", env.ah.sent[i].kind) end
        wow.tick(ns, 1)
        assert.are.equal("idle", ns.Scanner.state)
        assert.are.equal(1, ns.Scanner.summary.overCeiling)
    end)

    it("values a large browse over several frames", function()
        env.ah.fullBrowse = true
        env.ah.browse = {}
        for n = 1, 1000 do
            env.ah.browse[n] = { itemKey = { itemID = 5001, itemLevel = 28, itemSuffix = 0 }, minPrice = 999999 }
        end
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        assert.are.equal("checking", ns.Scanner.state)
        assert.is_true(ns.Scanner.valuedSoFar < 1000)
        wow.tick(ns, 1)
        assert.are.equal("idle", ns.Scanner.state)
        assert.are.equal(1000, ns.Scanner.summary.overCeiling)
    end)

    it("does not start a material scan during a gear scan", function()
        ns.Scanner.state = "browsing"
        ns.Prices.Scan()
        assert.is_false(ns.Prices.scanning)
        ns.Scanner.state = "idle"
    end)

    it("tries a search once more when it gets no answer", function()
        ns.Prices.Scan()
        local first = ns.Queue.items[1] and ns.Queue.items[1].commodity
        wow.tick(ns, 0.2)
        assert.are.equal(first, ns.Queue.current.commodity)
        wow.tick(ns, 3.2)
        local again = false
        for _, t in ipairs(ns.Queue.items) do if t.commodity == first then again = true end end
        assert.is_true(again)
    end)
end)

describe("Salvager deals list", function()
    local env, ns
    local LINK = "|cff1eff00|Hitem:5001::::::::30:::::|h[Test Boots]|h|r"
    setup(function()
        env = wow.install()
        env.items[5001] = { name = "Test Boots", quality = 2, ilvl = 28, classID = 4 }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
    end)

    it("groups auctions of one item and buys the cheapest first, then searches again", function()
        local task = { itemKey = { itemID = 5001, itemLevel = 28, itemSuffix = 0 }, keyString = "5001:28:0",
            value = { net = 3000 }, limit = 2500, ilvl = 28, quality = 2, classID = 4 }
        ns.Scanner.deals = {
            { auctionID = 2, itemID = 5001, link = LINK, buyout = 900, value = 3000, profit = 2100, classID = 4, task = task,
                keyString = task.keyString },
            { auctionID = 1, itemID = 5001, link = LINK, buyout = 500, value = 3000, profit = 2500, classID = 4, task = task,
                keyString = task.keyString },
        }
        ns.UI.view = "deals"
        ns.UI.Refresh()
        local row = _G.SalvagerFrame and nil
        -- The first visible row is the group.
        local rows = {}
        for _, fr in ipairs(env.frames) do if rawget(fr, "buy") then rows[#rows + 1] = fr end end
        local head = rows[1]
        assert.is_table(head.item.group)
        assert.are.equal(2, #head.item.group.deals)
        head.scripts.OnClick(head)                       -- open the group
        assert.is_true(rows[2].item.child)
        head.buy.scripts.OnClick(head.buy)                -- Buy 1st
        assert.are.equal(1, env.ah.bids[#env.ah.bids].id)
        assert.are.equal(500, env.ah.bids[#env.ah.bids].amount)
        local queued = #ns.Queue.items
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 1)
        assert.are.equal(queued + 1, #ns.Queue.items)    -- searched again for price changes
        assert.are.equal(1, #ns.db.ledger.purchases[5001])
        assert.is_nil(row)
    end)

    it("picks qualities in the drop-down and keeps at least one", function()
        local drop
        for _, fr in ipairs(env.frames) do if rawget(fr, "checks") then drop = fr end end
        assert.is_table(drop)
        drop.scripts.OnClick(drop)
        assert.is_true(drop.list:IsShown())
        drop.checks[2]:SetChecked(true)                  -- the game ticks the box, then runs OnClick
        drop.checks[2].scripts.OnClick(drop.checks[2])
        assert.is_true(ns.db.settings.qualities[3])
        ns.db.settings.qualities = { [2] = true, [3] = false, [4] = false }
        drop.checks[1]:SetChecked(false)
        drop.checks[1].scripts.OnClick(drop.checks[1])   -- uncommon off: refused
        assert.is_true(ns.db.settings.qualities[2])
    end)

    it("resizes from the corner and keeps the size", function()
        local f = _G.SalvagerFrame
        assert.is_function(f.scripts.OnSizeChanged)
        f.scripts.OnSizeChanged(f)
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)
end)

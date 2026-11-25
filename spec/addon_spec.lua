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
        assert.is_number(deal.lose)
        assert.is_true(deal.lose >= 0 and deal.lose <= 1)
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
        AutoLootMailItem(1)   -- asked twice for the same mail
        table.remove(env.inbox, 1)                            -- the item left the mailbox
        wow.fire(ns, "MAIL_INBOX_UPDATE")
        assert.are.equal(1, #ns.db.ledger.purchases[BOOTS])   -- the mail matches the purchase: not counted again
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
        env.inbox[1] = { sender = "Auction House", subject = "Auction successful: Soul Dust (2)", money = 1140,
            invoice = { "seller", "Soul Dust", "Buyer", 1200, 1200, 60, 60, 0, 0, 0, 2 } }
        TakeInboxMoney(1)
        assert.are.equal(0, #ns.db.ledger.sales)              -- not booked until the money is gone
        table.remove(env.inbox, 1)
        wow.fire(ns, "MAIL_INBOX_UPDATE")
        local sale = ns.db.ledger.sales[1]
        assert.are.equal(2, sale.count)
        assert.are.equal(1140, sale.net)
        assert.are.equal(640, sale.profit)
        assert.is_nil(ns.db.ledger.stock[11083])
    end)

    it("shows the purchase with its materials under it, and the sale with its profit", function()
        local rows = ns.LedgerWindow.PurchaseRows()
        assert.are.equal(2, #rows)
        assert.are.equal(BOOTS, rows[1].itemID)               -- the item, once
        assert.is_truthy(rows[1].cells[3]:find("5", 1, true)) -- paid 5s
        assert.are.equal(11083, rows[2].itemID)               -- what it gave, indented
        assert.is_true(rows[2].indent > 0)
        assert.is_truthy(rows[2].cells[1]:find("2x Soul Dust", 1, true))
        local sales = ns.LedgerWindow.SaleRows()
        local paid
        for _, r in ipairs(sales) do if r.itemID == 11083 then paid = r end end
        assert.is_truthy(paid.cells[1]:find("2x Soul Dust", 1, true))
        local odds = ns.LedgerWindow.OddsRows()
        -- Every band of every quality and type is there, with or without data: 24 bands twice,
        -- and at least two rows each.
        assert.is_true(#odds > 2 * 24 * 2)
        local band, dust
        for i, r in ipairs(odds) do
            if r.cells[1]:find("Green armor, item level 26-30", 1, true) then band, dust = r, odds[i + 1] end
        end
        assert.are.equal("1", band.cells[2])                       -- the one disenchant
        assert.are.equal(11083, dust.itemID)
        assert.is_truthy(dust.cells[3]:find("75%", 1, true))       -- expected
        assert.is_truthy(dust.cells[4]:find("100%", 1, true))      -- you got
        -- The band row: its buy limit and the chance one disenchant is worth less than it.
        local v = ns.Model.Value(ns.Model.Outcomes(2, ns.Data.CLASS_ARMOR, 30), ns.PriceOf,
            { cut = ns.db.settings.cut })
        local limit = ns.BuyLimit(2, ns.Data.CLASS_ARMOR, 30, v.net)
        assert.is_true(limit > 0)
        assert.are.equal(ns.Money(limit), band.cells[6])
        assert.is_truthy(band.cells[7]:find("%d+%%"))
        assert.are.equal("", dust.cells[6])                         -- a material row: no limit, no risk
        assert.are.equal("", dust.cells[7])
        assert.are.equal(8, #ns.LedgerWindow.OddsRows()[1].cells)
        -- A material the table does not have for the band.
        local des = ns.db.ledger.disenchants
        des[#des + 1] = { quality = 2, classID = ns.Data.CLASS_ARMOR, band = 30, value = 0, got = { [10940] = 1 } }
        local odd
        for _, r in ipairs(ns.LedgerWindow.OddsRows()) do
            if r.itemID == 10940 and r.cells[3]:find("not expected", 1, true) then odd = r end
        end
        des[#des] = nil
        assert.is_table(odd)
        -- Only the bands with data: the one band, its table rows.
        ns.db.windows.ledger = { oddsDataOnly = true }
        local mine = ns.LedgerWindow.OddsRows()
        assert.are.equal(4, #mine)                                 -- the band, dust, essence, shard
        assert.is_truthy(mine[1].cells[1]:find("item level 26-30", 1, true))
        -- Filters: only blue weapons.
        ns.db.windows.ledger = { oddsQuality = { [3] = true }, oddsType = { w = true } }
        local few = ns.LedgerWindow.OddsRows()
        assert.are.equal(#ns.Data.BLUE * 2, #few)                  -- each band: its row and its one shard
        assert.is_truthy(few[1].cells[1]:find("Blue weapons", 1, true))
        ns.db.windows.ledger = nil
        local a, b = ns.LedgerWindow.Summary()
        assert.is_truthy(a:find("Bought", 1, true))
        assert.is_truthy(b:find("Sold", 1, true))
    end)

    it("clears the history after a confirmation, and keeps the stock", function()
        ns.Ledger.AddStock(ns.db.ledger, 11137, 3, 900)
        ns.Ledger.AddPurchase(ns.db.ledger, 11287, 1, 150, 259, 1)   -- a wand: can never be disenchanted
        ns.Ledger.AddPurchase(ns.db.ledger, BOOTS, 1, 700, 900, 2)   -- still to disenchant
        ns.LedgerWindow.Show()
        local button
        for _, fr in ipairs(env.frames) do if fr.text == "Clear history" then button = fr end end
        button:Click()
        assert.are.equal("SALVAGER_CLEAR_LEDGER", env.popup)
        assert.is_true(#ns.db.ledger.disenchants > 0)       -- nothing cleared before the answer
        StaticPopupDialogs.SALVAGER_CLEAR_LEDGER.OnAccept()
        assert.are.equal(0, #ns.db.ledger.disenchants)
        assert.are.equal(0, #ns.db.ledger.sales)
        assert.is_nil(ns.db.ledger.purchases[11287])
        assert.are.equal(1, #ns.db.ledger.purchases[BOOTS])
        assert.are.equal(3, ns.db.ledger.stock[11137].qty)
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
        for _, id in ipairs({ 11082, 11084 }) do ns.db.prices[id] = { p = 1700, t = 0 } end
    end)

    it("registers the options panel and a minimap button", function()
        assert.is_true(env.settingsRegistered)
        assert.is_table(_G.SalvagerMinimapButton)
        _G.SalvagerMinimapButton:Click("RightButton")
        assert.is_true(_G.SalvagerOptionsFrame:IsShown())   -- the addon's own options window
        assert.is_nil(env.settingsOpened)                   -- not the game's settings: those close other windows
        assert.is_true(_G.SalvagerFrame:IsShown())
        ns.Options.Refresh()
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
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")   -- green armor: nothing listed
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")   -- green weapons: nothing listed
        wow.tick(ns, 0.2)
        assert.is_false(ns.Busy())
        assert.is_table(ns.Scanner.summary)
    end)

    it("sends only the chosen gear type to the auction house", function()
        ns.db.settings.gearClasses = "weapons"
        ns.db.settings.minProfit = 0
        ns.db.prices[10939] = { p = 1700, t = 0 }   -- Greater Magic Essence: what low green weapons give
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
        ns.LedgerWindow.Toggle()
        for _, v in ipairs({ "purchases", "sales", "odds" }) do
            ns.LedgerWindow.view = v
            ns.LedgerWindow.Refresh()
        end
        ns.LogWindow.Toggle()
        ns.LogWindow.Refresh()
        assert.is_true(_G.SalvagerLedgerFrame:IsShown())
        assert.is_true(_G.SalvagerLogFrame:IsShown())
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
    local function row(price) return { itemKey = { itemID = 5001, itemLevel = 28, itemSuffix = 0 }, minPrice = price } end
    setup(function()
        env = wow.install()
        env.items[11083] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        env.items[5001] = { name = "Test Boots", quality = 2, ilvl = 28, classID = 4 }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        for _, id in ipairs({ 11083, 11082, 11084 }) do ns.db.prices[id] = { p = 433, t = 0 } end
        ns.db.settings.minProfit = 0
        ns.db.settings.gearClasses = "armor"
        ns.db.settings.priceRescan = 0
    end)

    it("scans the material prices first when Play finds them old", function()
        ns.db.settings.priceRescan = 10
        ns.Scanner.Play()
        assert.is_true(ns.Prices.scanning)                -- never scanned: materials first
        assert.are.equal("idle", ns.Scanner.state)
        ns.Scanner.Stop()
        for _, m in ipairs(ns.Data.MATERIALS) do
            ns.db.prices[m.id] = ns.db.prices[m.id] or { p = 433 }
            ns.db.prices[m.id].t = env.clock - 60         -- one minute old
        end
        ns.Scanner.Play()
        assert.is_false(ns.Prices.scanning)               -- fresh enough: straight to the gear
        assert.are.equal("browsing", ns.Scanner.state)
        ns.Scanner.Stop()
        ns.db.settings.priceRescan = 0
    end)

    it("holds searches while the browse loads its pages", function()
        env.ah.fullBrowse = false
        env.ah.browse = { row(999999) }
        ns.Scanner.Scan()
        ns.Queue.Add({ commodity = 11083, onResult = function() end, onFail = function() end })
        wow.tick(ns, 1)
        assert.is_nil(ns.Queue.current)
        ns.Scanner.Stop()
        env.ah.fullBrowse = true
    end)

    it("moves on when a browse page never comes", function()
        env.ah.fullBrowse = false
        env.ah.browse = { row(1) }
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        assert.are.equal("browsing", ns.Scanner.state)
        local before = #env.ah.sent
        wow.tick(ns, 9)
        assert.are.equal("browsing", ns.Scanner.state)   -- asked for the page again, twice
        assert.are.equal(before + 2, #env.ah.sent)
        wow.tick(ns, 5)
        assert.are.equal("checking", ns.Scanner.state)   -- given up: the one candidate is being checked
        assert.are.equal(1, ns.Scanner.summary.browsed)
        assert.are.equal(1, ns.Scanner.summary.candidates)
        ns.Scanner.Stop()
    end)

    it("reads every page: the auction house does not sort by price", function()
        env.ah.fullBrowse = false
        env.ah.browse = { row(999999) }
        local before = #env.ah.sent
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        assert.are.equal("more", env.ah.sent[#env.ah.sent].kind)
        assert.is_true(#env.ah.sent > before)
        env.ah.fullBrowse = true
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", { row(1) })   -- a cheap one on the last page
        assert.are.equal(2, ns.Scanner.summary.browsed)
        assert.are.equal(1, ns.Scanner.summary.overLimit)
        assert.are.equal(1, ns.Scanner.summary.candidates)
        ns.Scanner.Stop()
    end)

    it("judges a large page without item lookups", function()
        env.ah.fullBrowse = true
        env.ah.browse = {}
        for n = 1, 1000 do env.ah.browse[n] = row(999999) end
        local lookups = 0
        local real = ns.GetItemInfo
        ns.GetItemInfo = function(...) lookups = lookups + 1 return real(...) end
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        ns.GetItemInfo = real
        assert.are.equal("idle", ns.Scanner.state)
        assert.are.equal(1000, ns.Scanner.summary.overLimit)
        assert.are.equal(0, lookups)
    end)

    it("holds the browse while paused and continues on Play", function()
        env.ah.fullBrowse = false
        env.ah.browse = { row(999999) }
        ns.Scanner.Play()
        ns.Scanner.Pause()
        local sent = #env.ah.sent
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        assert.are.equal(sent, #env.ah.sent)              -- no next page while paused
        ns.Scanner.Play()
        assert.are.equal("more", env.ah.sent[#env.ah.sent].kind)
        ns.Scanner.Stop()
        env.ah.fullBrowse = true
    end)

    it("learns item levels in the background and prefers them over the listing's", function()
        ns.db.ilvl[5001] = nil
        local lvl, src = ns.Items.Level({ itemID = 5001, itemLevel = 23 })
        assert.are.equal(23, lvl)
        assert.are.equal("key", src)
        wow.tick(ns, 0.2)
        lvl, src = ns.Items.Level({ itemID = 5001, itemLevel = 23 })
        assert.are.equal(28, lvl)
        assert.are.equal("cache", src)
    end)

    it("starts every round with an empty deals list", function()
        ns.Scanner.deals = { { auctionID = 9, itemID = 5001, buyout = 1, value = 2, profit = 1, keyString = "5001:28:0" } }
        env.ah.fullBrowse = true
        env.ah.browse = {}
        ns.Scanner.Scan()
        assert.are.equal(0, #ns.Scanner.deals)             -- cleared when the round starts, not when it ends
        assert.are.equal("browsing", ns.Scanner.state)
        ns.Scanner.Stop()
    end)

    it("never lists an item above the most you pay for one item", function()
        env.ah.fullBrowse = true
        env.ah.browse = { row(50), row(300) }             -- both far under the item's value
        ns.db.settings.maxPrice = 100                      -- but you pay at most 1s for anything
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        assert.are.equal(1, ns.Scanner.summary.candidates)
        assert.are.equal(1, ns.Scanner.summary.overLimit)
        ns.Scanner.Stop()
        ns.db.settings.maxPrice = 0
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        assert.are.equal(1, ns.Scanner.summary.candidates) -- the same item key: still one candidate, now with no cap
        ns.Scanner.Stop()
    end)

    it("does not start a material scan during a gear scan", function()
        ns.Scanner.state = "browsing"
        ns.Prices.Scan()
        assert.is_false(ns.Prices.scanning)
        ns.Scanner.state = "idle"
    end)

    it("sends a search again at once when the auction house drops it", function()
        ns.Queue.Clear()
        ns.Queue.Add({ commodity = 11083, onResult = function() end, onFail = function() end })
        wow.tick(ns, 0.2)
        local sent = #env.ah.sent
        assert.are.equal(11083, ns.Queue.current.commodity)
        wow.fire(ns, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
        assert.is_nil(ns.Queue.current)
        wow.tick(ns, 0.2)                                  -- well before the 3 s wait for an answer
        assert.are.equal(sent + 1, #env.ah.sent)
        assert.are.equal(11083, ns.Queue.current.commodity)
        ns.Queue.Clear()
    end)

    it("uses the results when the answer came without its event", function()
        ns.Queue.Clear()
        local got
        ns.Queue.Add({ itemKey = { itemID = 5001, itemLevel = 28, itemSuffix = 0 },
            onResult = function() got = "result" end, onFail = function() got = "fail" end })
        wow.tick(ns, 0.2)
        env.ah.hasResults[5001] = true          -- the game holds results, but no event was seen
        wow.tick(ns, 2.2)
        assert.are.equal("result", got)
        env.ah.hasResults[5001] = nil
    end)

    it("tries a search once more when it gets no answer", function()
        ns.Prices.Scan()
        local first = ns.Queue.items[1] and ns.Queue.items[1].commodity
        wow.tick(ns, 0.2)
        assert.are.equal(first, ns.Queue.current.commodity)
        wow.tick(ns, 2.3)                       -- no answer in 2 s: the same search goes out again, next in line
        assert.are.equal(first, ns.Queue.current.commodity)
        assert.are.equal(1, ns.Queue.current.tries)
        assert.are.equal(1, ns.Queue.lost)
        ns.Scanner.Stop()
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
            net = 3000, limit = 2500, ilvl = 28, quality = 2, classID = 4 }
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
        for _, fr in ipairs(env.frames) do
            if rawget(fr, "checks") and #fr.checks == 3 and not drop then drop = fr end
        end
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

    it("picks gear types in the drop-down and keeps at least one", function()
        ns.db.settings.gearClasses = "both"
        ns.SetGearType("armor", false)
        assert.are.equal("weapons", ns.db.settings.gearClasses)
        ns.SetGearType("weapons", false)
        assert.are.equal("weapons", ns.db.settings.gearClasses)
        ns.SetGearType("armor", true)
        assert.are.equal("both", ns.db.settings.gearClasses)
    end)

    it("plays, pauses and stops", function()
        for _, id in ipairs({ 11083, 11082, 11084 }) do ns.db.prices[id] = { p = 433, t = 0 } end
        ns.db.settings.minProfit = 0
        ns.db.settings.priceRescan = 0
        ns.Scanner.Play()
        assert.is_true(ns.Scanner.auto)
        assert.are.equal("browsing", ns.Scanner.state)
        ns.Scanner.Pause()
        assert.is_true(ns.Scanner.paused)
        assert.is_true(ns.Queue.paused)
        ns.Scanner.Play()
        assert.is_false(ns.Scanner.paused)
        ns.Scanner.Stop()
        assert.is_false(ns.Scanner.auto)
        assert.are.equal("idle", ns.Scanner.state)
        assert.are.equal(0, ns.Queue.Pending())
    end)

    it("shows help over the column titles that have it", function()
        local list = ns.Widgets.List(_G.UIParent, {})
        list:SetColumns({ { "Item", 220 }, { "Paid", 84, "RIGHT", help = { "Paid", "What you paid." } } })
        list:SetSource(0, function() end)
        list.GetWidth = function() return 600 end
        list:Refresh()
        assert.is_false(list.helps[1]:IsShown())
        assert.is_true(list.helps[2]:IsShown())
        list.helps[2]:GetScript("OnEnter")(list.helps[2])
        assert.are.equal("Paid", _G.GameTooltip:GetText())
        list.GetWidth = function() return 120 end      -- the column is left out, and so is its help
        list:Refresh()
        assert.is_false(list.helps[2]:IsShown())
        list:SetColumns({ { "Item", 220 } })
        list.GetWidth = function() return 600 end
        list:Refresh()
        assert.is_false(list.helps[2]:IsShown())
    end)

    it("leaves out columns that do not fit a narrow window", function()
        local list = ns.Widgets.List(_G.UIParent, {})
        list:SetColumns({ { "Item", 220 }, { "Bought", 82 }, { "Paid", 84, "RIGHT" } })
        list:SetSource(1, function() return { cells = { "a", "b", "c" } } end)
        list.GetWidth = function() return 600 end
        list:Refresh()
        assert.is_true(list.headers[3]:IsShown())
        assert.is_true(list.rows[1].cells[3]:IsShown())
        list.GetWidth = function() return 250 end      -- room for the first two columns only
        list:Refresh()
        assert.is_true(list.headers[2]:IsShown())
        assert.is_false(list.headers[3]:IsShown())
        assert.is_false(list.rows[1].cells[3]:IsShown())
        list.GetWidth = function() return 120 end      -- only the first column, cut to the width
        list:Refresh()
        assert.is_false(list.headers[2]:IsShown())
        assert.is_true(list.headers[1]:IsShown())
    end)

    it("records every purchase of a fast run of Buy clicks, and holds searches meanwhile", function()
        local task = { itemKey = { itemID = 5001, itemLevel = 28, itemSuffix = 0 }, keyString = "5001:28:0",
            net = 3000, limit = 2500, ilvl = 28, quality = 2, classID = 4 }
        local function deal(id, price)
            return { auctionID = id, itemID = 5001, link = LINK, buyout = price, value = 3000, profit = 3000 - price,
                classID = 4, task = task, keyString = task.keyString }
        end
        local a, b, c = deal(11, 500), deal(12, 501), deal(13, 502)
        ns.Scanner.deals = { a, b, c }
        local before = #(ns.db.ledger.purchases[5001] or {})
        ns.Scanner.Buy(a)
        ns.Scanner.Buy(b)                                  -- clicked before the first one came back
        ns.Scanner.Buy(c)
        assert.is_true(ns.Scanner.Buying())
        ns.Queue.Add({ commodity = 11083, onResult = function() end, onFail = function() end })
        wow.tick(ns, 0.5)
        assert.is_nil(ns.Queue.current)                    -- searches wait for the purchases
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 11)
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 12)
        wow.fire(ns, "AUCTION_HOUSE_SHOW_ERROR", 5)        -- the third was sold to someone else
        assert.are.equal(before + 2, #ns.db.ledger.purchases[5001])
        assert.is_false(c.pending)
        wow.tick(ns, 1.5)
        assert.is_false(ns.Scanner.Buying())
        assert.is_table(ns.Queue.current)                  -- and go on afterwards
        ns.Queue.Clear()
    end)

    it("resizes from the corner and keeps the size", function()
        local f = _G.SalvagerFrame
        assert.is_function(f.scripts.OnSizeChanged)
        f.scripts.OnSizeChanged(f)
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)
end)

describe("Salvager posting", function()
    local env, ns
    local DUST = 11083
    setup(function()
        env = wow.install()
        env.items[DUST] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        env.ah.commodities[DUST] = { { unitPrice = 500, quantity = 10, numOwnerItems = 10 },   -- your own: not counted
            { unitPrice = 430, quantity = 50, numOwnerItems = 0 } }
        env.bags[DUST] = 12
        env.bagSlots = { [2] = DUST }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        ns.Ledger.AddStock(ns.db.ledger, DUST, 12, 12 * 300)   -- break-even ceil(300 / 0.95) = 316
    end)

    it("gets the price first, then suggests one copper under the lowest listing", function()
        ns.Post.Open(DUST)
        assert.is_true(ns.Post.loading[DUST])
        wow.tick(ns, 0.2)
        wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", DUST)
        assert.is_nil(ns.Post.loading[DUST])
        assert.is_true(_G.SalvagerPostFrame:IsShown())
        local s = ns.Post.Suggest(DUST)
        assert.are.equal(430, s.lowest)
        assert.are.equal(429, s.price)
        assert.are.equal(316, s.breakEven)
        assert.is_false(s.below)
    end)

    it("works out what the post brings", function()
        local o = ns.Post.Outcome(DUST, 10, 429, 2)
        assert.are.equal(4290, o.gross)
        assert.are.equal(4076, o.net)        -- after the 5% cut
        assert.are.equal(3000, o.cost)
        assert.are.equal(1076, o.profit)
        assert.are.equal(30, o.deposit)
    end)

    it("warns when the market is below the break-even", function()
        ns.db.prices[DUST].lo = 300
        local s = ns.Post.Suggest(DUST)
        assert.are.equal(299, s.price)
        assert.is_true(s.below)
        ns.UI.view = "materials"
        ns.UI.Refresh()
        ns.db.prices[DUST].lo = 430
    end)

    it("posts from the bag slot, and asks again when the auction house wants a confirmation", function()
        assert.is_true(ns.Post.Send(DUST, 12, 429, 2))
        local p = env.ah.posts[#env.ah.posts]
        assert.are.equal(2, p.loc.slot)
        assert.are.equal(12, p.quantity)
        assert.are.equal(429, p.unitPrice)
        wow.fire(ns, "AUCTION_HOUSE_AUCTION_CREATED", 5)
        assert.is_nil(ns.Post.pending)
        env.ah.needsConfirm = true
        assert.are.equal("confirm", ns.Post.Send(DUST, 12, 100, 2))
        assert.is_true(ns.Post.Send(DUST, 12, 100, 2, true))
        assert.is_true(env.ah.posts[#env.ah.posts].confirmed)
    end)

    it("pops the materials list out to its own window and puts it back when closed", function()
        ns.UI.view = "materials"
        ns.UI.Refresh()
        ns.Scanner.auto = true                             -- a scan setting that must survive
        ns.Materials.PopOut()
        assert.is_true(ns.Materials.IsPoppedOut())
        assert.is_true(_G.SalvagerMaterialsFrame:IsShown())
        ns.UI.Refresh()
        assert.are.equal("deals", ns.UI.view)              -- the main window gave up the list
        assert.is_true(ns.Scanner.auto)
        -- The window's row for the dust has a Post button.
        local posted
        for _, fr in ipairs(env.frames) do
            local data = rawget(fr, "data")
            if data and data.itemID == DUST and data.action then posted = data.action end
        end
        assert.is_table(posted)
        assert.are.equal("Post", posted.text)
        _G.SalvagerMaterialsFrame:Hide()                   -- closed with its X
        _G.SalvagerMaterialsFrame.scripts.OnHide()
        assert.is_false(ns.Materials.IsPoppedOut())
        ns.UI.view = "materials"
        ns.UI.Refresh()
        assert.are.equal("materials", ns.UI.view)          -- back in the tab
        ns.Scanner.auto = false
    end)

    it("refuses when none is in the bags", function()
        env.bagSlots = {}
        local ok, why = ns.Post.Send(DUST, 1, 429, 2)
        assert.is_false(ok)
        assert.is_string(why)
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)
end)

describe("Salvager mail", function()
    local env, ns
    local HOOD, LINK = 7048, "|cff1eff00|Hitem:7048::::::::30:::::|h[Azure Silk Hood]|h|r"
    local function won()
        return { sender = "Auction House", subject = "Auction won: Azure Silk Hood", link = LINK,
            invoice = { "buyer", "Azure Silk Hood", "Seller", 1000, 1000, 0, 0, 0, 0, 0, 1 } }
    end
    setup(function()
        env = wow.install()
        env.items[HOOD] = { name = "Azure Silk Hood", quality = 2, ilvl = 29, classID = 4 }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
    end)

    it("books two identical purchase mails as two purchases", function()
        env.inbox = { won(), won(), won() }
        TakeInboxItem(1, 1)
        table.remove(env.inbox, 1)
        wow.fire(ns, "MAIL_INBOX_UPDATE")
        assert.are.equal(1, #ns.db.ledger.purchases[HOOD])
        TakeInboxItem(1, 1)                    -- the next one: the same sender, subject and price
        table.remove(env.inbox, 1)
        wow.fire(ns, "MAIL_INBOX_UPDATE")
        assert.are.equal(2, #ns.db.ledger.purchases[HOOD])
    end)

    it("books a mail once when it is asked for twice, and not before it is gone", function()
        TakeInboxItem(1, 1)
        wow.fire(ns, "MAIL_INBOX_UPDATE")      -- nothing left the mailbox yet (bags full, lag)
        assert.are.equal(2, #ns.db.ledger.purchases[HOOD])
        TakeInboxItem(1, 1)
        table.remove(env.inbox, 1)
        wow.fire(ns, "MAIL_INBOX_UPDATE")
        assert.are.equal(3, #ns.db.ledger.purchases[HOOD])
    end)

    it("books every mail of an open-all run", function()
        env.inbox = { won(), won(), won(), won() }
        for i = 1, 4 do AutoLootMailItem(i) end
        for _ = 1, 4 do
            table.remove(env.inbox, 1)
            wow.fire(ns, "MAIL_INBOX_UPDATE")
        end
        assert.are.equal(7, #ns.db.ledger.purchases[HOOD])
    end)
end)

describe("Salvager layout", function()
    local env, ns
    setup(function()
        env = wow.install()
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
    end)

    it("reopens the windows that were open when the auction house opens again", function()
        ns.LedgerWindow.Toggle()
        ns.LogWindow.Toggle()
        ns.Materials.PopOut()
        -- Escape, or leaving the auction house: everything hides at once.
        for _, name in ipairs({ "SalvagerFrame", "SalvagerLedgerFrame", "SalvagerLogFrame", "SalvagerMaterialsFrame" }) do
            _G[name]:Hide()
        end
        wow.fire(ns, "AUCTION_HOUSE_CLOSED")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        assert.is_true(_G.SalvagerFrame:IsShown())
        assert.is_true(_G.SalvagerLedgerFrame:IsShown())
        assert.is_true(_G.SalvagerLogFrame:IsShown())
        assert.is_true(ns.Materials.IsPoppedOut())
    end)

    it("leaves closed what the player closed on purpose", function()
        ns.LogWindow.Toggle()                               -- the Log button: closed on purpose
        ns.Materials.PutBack()
        for _, name in ipairs({ "SalvagerFrame", "SalvagerLedgerFrame" }) do _G[name]:Hide() end
        wow.fire(ns, "AUCTION_HOUSE_CLOSED")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        assert.is_true(_G.SalvagerLedgerFrame:IsShown())
        assert.is_false(_G.SalvagerLogFrame:IsShown())
        assert.is_false(ns.Materials.IsPoppedOut())
    end)

    it("can be turned off", function()
        ns.db.settings.restoreWindows = false
        _G.SalvagerLedgerFrame:Hide()
        wow.fire(ns, "AUCTION_HOUSE_CLOSED")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        assert.is_false(_G.SalvagerLedgerFrame:IsShown())
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)
end)

describe("Salvager listings", function()
    local env, ns
    local DUST, VISION = 11083, 11137
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
        env.items[VISION] = { name = "Vision Dust", quality = 1, ilvl = 1, classID = 7 }
        env.ah.owned = {
            { auctionID = 1, itemKey = { itemID = DUST }, status = 0, quantity = 20, timeLeftSeconds = 40000, buyoutAmount = 500 },
            { auctionID = 2, itemKey = { itemID = VISION }, status = 0, quantity = 10, timeLeftSeconds = 40000, buyoutAmount = 900 },
            { auctionID = 3, itemKey = { itemID = DUST }, status = 1, quantity = 5, timeLeftSeconds = 2400, buyoutAmount = 480 },
        }
        -- Soul Dust: someone else is cheaper. Vision Dust: only your own listing.
        env.ah.commodities[DUST] = { { unitPrice = 430, quantity = 50, numOwnerItems = 0 },
            { unitPrice = 500, quantity = 20, numOwnerItems = 20 } }
        env.ah.commodities[VISION] = { { unitPrice = 900, quantity = 10, numOwnerItems = 10 } }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        ns.Ledger.AddStock(ns.db.ledger, DUST, 25, 25 * 300)
    end)

    it("reads your auctions when the auction house opens", function()
        wow.tick(ns, 0.5)
        local rows = ns.db.listings.rows
        assert.are.equal(3, #rows)
        assert.are.equal(500, rows[1].each)
        assert.is_true(rows[3].sold)
        assert.is_true(rows[1].commodity)
    end)

    it("shows them in the Sales view: listed, and sold with the wait for the money", function()
        local rows = ns.LedgerWindow.SaleRows()
        local listed, sold
        for _, r in ipairs(rows) do
            if r.cells[1]:find("20x", 1, true) then listed = r end
            if r.cells[1]:find("5x", 1, true) then sold = r end
        end
        assert.is_truthy(listed.cells[2]:find("listed", 1, true))          -- not checked yet
        assert.is_truthy(sold.cells[2]:find("money in 40 min", 1, true))
        assert.is_truthy(listed.cells[7]:find("35", 1, true))              -- 20 x 500 x 0.95 - 20 x 300 = 35s profit
    end)

    it("finds the undercut listings", function()
        ns.Listings.Check()
        assert.is_table(ns.Listings.checking)
        answer()
        assert.is_nil(ns.Listings.checking)
        assert.are.equal(1, ns.Listings.CountUndercut())
        local rows = ns.db.listings.rows
        assert.are.equal(70, ns.Listings.Undercut(rows[1]))        -- 500 against 430
        assert.is_nil(ns.Listings.Undercut(rows[2]))               -- nobody else lists it
        assert.is_false(ns.Listings.Lowest(rows[2]))
        assert.is_nil(ns.Listings.Undercut(rows[3]))               -- sold: nothing to cancel
        local sale = ns.LedgerWindow.SaleRows()
        local found
        for _, r in ipairs(sale) do if r.cells[2] and r.cells[2]:find("undercut by", 1, true) then found = true end end
        assert.is_true(found)
    end)

    it("cancels one undercut listing per click", function()
        assert.is_true(ns.Listings.CancelNext())
        assert.are.equal(1, env.ah.cancels[1])
        assert.is_false(ns.Listings.CancelNext())                  -- the first one is still on its way
        wow.fire(ns, "AUCTION_CANCELED", 1)
        assert.are.equal(2, #ns.db.listings.rows)
        assert.are.equal(0, ns.Listings.CountUndercut())
        assert.is_false(ns.Listings.CancelNext())                  -- nothing left to cancel
        assert.are.equal(1, #env.ah.cancels)
        ns.LedgerWindow.Show()
        ns.LedgerWindow.view = "sales"
        ns.LedgerWindow.Refresh()
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)
end)

describe("Salvager log window", function()
    local env, ns
    setup(function()
        env = wow.install()
        env.items[11083] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        env.items[7048] = { name = "Azure Silk Hood", quality = 2, ilvl = 29, classID = 4 }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
    end)

    it("shows the items of a line by name, with the item as the line's tooltip", function()
        local row = ns.LogWindow.Row("19:00:01 price Soul Dust (11083): 4s 30c over 20 units, 19 results")
        assert.are.equal("item:11083", row.link)
        assert.is_truthy(row.cells[1]:find("[Soul Dust]", 1, true))
        assert.is_nil(row.cells[1]:find("(11083)", 1, true))
        row = ns.LogWindow.Row("19:00:02 search: no answer for commodity 11083 after 2.0s, trying again")
        assert.are.equal("item:11083", row.link)
        assert.is_truthy(row.cells[1]:find("[Soul Dust]", 1, true))
        row = ns.LogWindow.Row("19:00:03 checked item 7048:29:0: 12 auctions, 3 under 12s")
        assert.are.equal("item:7048", row.link)
        row = ns.LogWindow.Row("19:00:04 search: no answer for item 7048:29:0 after 2.0s, trying again")
        assert.are.equal("item:7048", row.link)
        assert.is_truthy(row.cells[1]:find("[Azure Silk Hood]", 1, true))
        assert.is_truthy(row.cells[1]:find("(level 29)", 1, true))
        row = ns.LogWindow.Row("19:00:05 bought |cff1eff00|Hitem:7048::::::::30:::::|h[Azure Silk Hood]|h|r for 11s 47c")
        assert.are.equal("item:7048", row.link)
        row = ns.LogWindow.Row("19:00:06 auction house opened")
        assert.is_nil(row.link)
        assert.are.equal("19:00:06 auction house opened", row.cells[1])
    end)

    it("lists the newest line at the bottom and follows it", function()
        for i = 1, 200 do ns.Log("line %d", i) end
        ns.LogWindow.Show()
        local list
        for _, fr in ipairs(env.frames) do if rawget(fr, "getRow") and rawget(fr, "count") then list = fr end end
        assert.is_truthy(list.getRow(list.count).cells[1]:find("line 200", 1, true))
        assert.is_true(list.atBottom)
        list.offset = 0                                      -- scrolled up to read
        list:Refresh()
        ns.Log("one more")
        ns.LogWindow.Refresh()
        assert.are.equal(0, list.offset)                     -- stays where you are reading
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)
end)

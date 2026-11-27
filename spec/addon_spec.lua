local wow = require("spec.wow")

-- The width of a text as the stand-in measures it: 6 px a character, the color codes left out, an icon 12 px.
local function shownWidth(text)
    if not text then return 0 end
    local plain = text:gsub("|T.-|t", "\1\1"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return #plain * 6
end

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
        assert.is_nil(ns.Scanner.ReturnPerDay(deal))         -- no sale yet: no time to sell, no Return per day
        ns.UI.view = "deals"
        ns.UI.Refresh()
        ns.Scanner.Buy(deal)
        assert.are.equal(77, env.ah.bids[1].id)
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 77)
        assert.are.equal(0, #ns.Scanner.deals)
    end)

    it("lists the purchase as not picked up, with its total and the bag space", function()
        local W = ns.LedgerWindow
        W.Show()
        W.view = "purchases"
        ns.db.windows.ledger.purchaseTab = nil
        W.Refresh()
        assert.is_true(W.purchaseTabs.all:IsShown())          -- the main subtab first, and shown
        assert.are.equal("Not picked up (1)", W.purchaseTabs.mail:GetText())
        local ARROW = "|TInterface\\ChatFrame\\ChatFrameExpandArrow:12:12:0:0|t"
        -- The stand-in's backpack, then the arrow and the space after taking the one item in the mail.
        assert.is_truthy(W.bagLabel:GetText():find(" 4/4 " .. ARROW .. " 3/4", 1, true))
        W.purchaseTabs.mail:Click()
        assert.are.equal("mail", W.PurchaseTab())
        local rows = W.NotPickedUpRows()
        assert.are.equal(2, #rows)                            -- the heading with the totals, then the purchase
        assert.is_true(rows[1].group)
        assert.is_truthy(rows[1].cells[1]:find("1 piece of gear in the mail", 1, true))
        assert.are.equal(ns.Money(500), rows[1].cells[4])
        assert.are.equal(BOOTS, rows[2].itemID)
        assert.are.equal("28", rows[2].cells[2])              -- the item level it was judged by
        assert.are.equal(ns.Money(500), rows[2].cells[4])
        assert.are.same({ 1, 500 }, { W.NotPickedUpTotal() })
        -- Bags full (the profession bag's free slots do not count): the minus and the alert sign say it.
        env.bagSize, env.bagFree, env.bagFamily = { [0] = 16, [1] = 10, [2] = 12 }, { [0] = 0, [1] = 0, [2] = 5 },
            { [2] = 8 }
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        -- Full: the slot missing as a negative, red, with the alert sign.
        assert.is_truthy(W.bagLabel:GetText():find(" 0/26 " .. ARROW .. " |cffff4040-1/26|r ", 1, true))
        assert.is_truthy(W.bagLabel:GetText():find("AlertNew", 1, true))
        env.bagFree[1] = 3                                    -- room made: the label follows the bag event
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        assert.is_truthy(W.bagLabel:GetText():find(" 3/26 " .. ARROW .. " 2/26", 1, true))
        assert.is_nil(W.bagLabel:GetText():find("AlertNew", 1, true))
        local waiting = W.NotPickedUpTotal                    -- nothing in the mail: the space now only
        W.NotPickedUpTotal = function() return 0, 0 end
        assert.is_nil(W.BagText():find(ARROW, 1, true))
        assert.is_truthy(W.BagText():find(" 3/26$"))
        W.NotPickedUpTotal = waiting
        env.bagSize, env.bagFree, env.bagFamily = { [0] = 4 }, {}, {}
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
        -- Its mail is taken: it leaves Not picked up, and the subtab says why it is empty.
        assert.are.equal(0, (ns.LedgerWindow.NotPickedUpTotal()))
        assert.are.equal("Not picked up (0)", ns.LedgerWindow.purchaseTabs.mail:GetText())
        assert.is_truthy(ns.LedgerWindow.NotPickedUpRows()[1].cells[1]:find("Nothing waits in the mail", 1, true))
        ns.db.windows.ledger.purchaseTab = nil
        ns.LedgerWindow.view = "sales"
        ns.LedgerWindow.Refresh()
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
        assert.are.equal(3, #rows)                            -- the day, its status, one row per item (closed)
        assert.is_true(rows[1].group and rows[1].open)        -- the day it was bought, open, with its totals
        assert.is_truthy(rows[1].cells[1]:find("1 piece", 1, true))
        assert.is_truthy(rows[1].cells[3]:find("5", 1, true))
        assert.is_truthy(rows[2].cells[1]:find("^Disenchanted"))   -- the only status of that day
        assert.is_true(rows[2].indent > 0 and rows[2].open)
        assert.are.equal(BOOTS, rows[3].itemID)
        assert.is_truthy(rows[3].cells[1]:find("x1", 1, true))
        assert.is_truthy(rows[3].cells[3]:find("5", 1, true)) -- paid 5s
        rows[3].onClick()                                     -- a click opens it
        rows = ns.LedgerWindow.PurchaseRows()
        assert.are.equal(4, #rows)
        assert.is_true(rows[4].indent > rows[3].indent)       -- each purchase under it, with what it gave
        assert.is_truthy(rows[4].cells[1]:find("2x Soul Dust", 1, true))
        rows[1].onClick()                                     -- the day closes: its heading stays, with its totals
        rows = ns.LedgerWindow.PurchaseRows()
        assert.are.equal(1, #rows)
        assert.is_false(rows[1].open)
        assert.is_truthy(rows[1].cells[3]:find("5", 1, true))
        rows[1].onClick()
        local x = ns.LedgerWindow.PurchaseFilter()
        x.search = "nothing like it"
        assert.is_truthy(ns.LedgerWindow.PurchaseRows()[1].cells[1]:find("matches", 1, true))
        x.search = "test"                                     -- the name, any case
        assert.are.equal(BOOTS, ns.LedgerWindow.PurchaseRows()[3].itemID)
        x.search = nil
        x.classes[4] = nil                                    -- weapons only: the boots go
        assert.is_nil(ns.LedgerWindow.PurchaseRows()[1].itemID)
        assert.are.equal(1, #ns.LedgerWindow.PurchaseRows())
        x.classes[4] = true
        assert.is_false(ns.LedgerWindow.PurchaseRows()[3].open == nil)   -- it has the open / close sign
        x.show = "done"                                       -- the boots were disenchanted: still there
        assert.are.equal(BOOTS, ns.LedgerWindow.PurchaseRows()[3].itemID)
        x.show = "waiting"                                    -- nothing waits: the table says why
        rows = ns.LedgerWindow.PurchaseRows()
        assert.are.equal(1, #rows)
        assert.is_truthy(rows[1].cells[1]:find("Every piece of gear you bought is disenchanted", 1, true))
        x.show = "all"
        assert.are.same({ 6, true }, { ns.LedgerWindow.PurchaseSort().col, ns.LedgerWindow.PurchaseSort().desc })
        x.open, x.collapsed = {}, {}
        local accRows = ns.LedgerWindow.AccuracyBandRows()
        assert.is_true(#accRows >= 4)                              -- all bands, gear type, quality, a band
        assert.is_truthy(accRows[2].cells[1]:find("Armor", 1, true))
        assert.is_true(accRows[2].group)
        assert.is_truthy(accRows[3].cells[1]:find("Uncommon", 1, true))
        assert.is_true(accRows[3].group)
        assert.are.equal("26-30", accRows[4].cells[1])             -- the band row: its range only
        local sales = ns.LedgerWindow.SoldRows(true)               -- booked from its mail: it is history at once
        local paid
        for _, r in ipairs(sales) do if r.itemID == 11083 then paid = r end end
        assert.is_truthy(paid.cells[1]:find("2x Soul Dust", 1, true))
        ns.db.windows.ledger = nil
        ns.LedgerWindow.OddsFilter().classes[ns.Data.CLASS_WEAPON] = nil     -- the Gear filter: armor only
        local odds = ns.LedgerWindow.OddsRows()
        -- Every band of every quality is there for armor, with or without data: 24 bands, two rows each at least.
        assert.is_true(#odds > 2 * 24)
        local band, dust
        for i, r in ipairs(odds) do
            if r.cells[1]:find("Uncommon", 1, true) and r.cells[1]:find("26-30", 1, true) then
                band, dust = r, odds[i + 1]
            end
        end
        assert.are.equal("1", band.cells[2])                       -- the one disenchant
        assert.are.equal(11083, dust.itemID)
        assert.is_truthy(dust.cells[3]:find("75%", 1, true))       -- expected
        assert.are.equal("1-2", dust.cells[4])                     -- one value per cell: the quantity apart
        assert.is_truthy(dust.cells[5]:find("100%", 1, true))      -- your result rate
        -- The band row: its buy limit and the chance one disenchant is worth less than it.
        local v = ns.Model.Value(ns.Model.Outcomes(2, ns.Data.CLASS_ARMOR, 30), ns.PriceOf, ns.ValueOptions())
        local limit = ns.BuyLimit(2, ns.Data.CLASS_ARMOR, 30, v.net)
        assert.is_true(limit > 0)
        assert.are.equal(ns.Money(limit), band.cells[6])
        assert.is_truthy(band.cells[7]:find("%d+%%"))
        assert.are.equal(9, #ns.LedgerWindow.OddsRows()[1].cells)
        -- What the rates used rest on: buying counts no Salvager here, and the one disenchant was with it.
        assert.are.equal("0 without Salvager", band.cells[9])
        assert.is_truthy(dust.cells[7]:find("75%% %(few results%)"))   -- the table's rate, marked
        -- A material the table does not have for the band.
        local des = ns.db.ledger.disenchants
        des[#des + 1] = { quality = 2, classID = ns.Data.CLASS_ARMOR, band = 30, value = 0, got = { [10940] = 1 } }
        local odd
        for _, r in ipairs(ns.LedgerWindow.OddsRows()) do
            if r.itemID == 10940 and r.cells[3]:find("not expected", 1, true) then odd = r end
        end
        des[#des] = nil
        assert.is_table(odd)
        -- In the window: a heading for the gear type, one per quality, and a card per band, each opens and closes.
        local cards = ns.LedgerWindow.OddsCards()
        assert.are.equal(1 + 3 + 24, #cards)
        assert.is_true(cards[1].heading)
        assert.is_truthy(cards[1].title:find("Armor", 1, true))
        local card
        for _, c in ipairs(cards) do
            if not c.heading and c.title:find("Uncommon", 1, true) and c.title:find("26-30", 1, true) then card = c end
        end
        assert.are.equal(3, #card.rows)                            -- dust, essence, shard
        assert.is_truthy(card.facts:find("Value now", 1, true))
        assert.is_truthy(card.facts:find("Buy below", 1, true))
        assert.are.equal(11083, card.rows[1].itemID)
        card.onClick()                                             -- closed: no rows
        for _, c in ipairs(ns.LedgerWindow.OddsCards()) do
            if not c.heading and c.title:find("Uncommon", 1, true) and c.title:find("26-30", 1, true) then card = c end
        end
        assert.are.same({ false, 0 }, { card.open, #card.rows })
        card.onClick()
        cards[2].onClick()                                         -- the Uncommon heading closes its bands
        assert.are.equal(1 + 3 + 24 - #ns.Data.GREEN, #ns.LedgerWindow.OddsCards())
        cards[2].onClick()
        -- Only the bands with data: the one band, its table rows.
        ns.LedgerWindow.OddsFilter().dataOnly = true
        local mine = ns.LedgerWindow.OddsRows()
        assert.are.equal(4, #mine)                                 -- the band, dust, essence, shard
        assert.is_truthy(mine[1].cells[1]:find("26-30", 1, true))
        -- Filters: only rare weapons.
        ns.db.windows.ledger = { oddsFilter = { qualities = { [3] = true }, classes = { [ns.Data.CLASS_WEAPON] = true } } }
        local few = ns.LedgerWindow.OddsRows()
        assert.are.equal(#ns.Data.BLUE * 2, #few)                  -- each band: its row and its one shard
        assert.is_truthy(few[1].cells[1]:find("Rare", 1, true))
        -- The band filter: only item levels 26-30.
        local off = {}
        for _, range in ipairs(ns.LevelBands()) do if range.up ~= 30 then off[range.up] = true end end
        ns.db.windows.ledger = { oddsFilter = { bandsOff = off, qualities = { [2] = true },
            classes = { [ns.Data.CLASS_ARMOR] = true } } }
        local one = ns.LedgerWindow.OddsCards()
        assert.are.equal(3, #one)                                  -- Armor, Uncommon, the band
        assert.is_truthy(one[3].title:find("26-30", 1, true))
        -- Settings from before (a gear subtab, qualities of their own) move into the filter.
        ns.db.windows.ledger = { oddsQuality = { [3] = true }, oddsTab = "w", oddsDataOnly = true }
        assert.are.same({ true, true }, { ns.LedgerWindow.OddsFilter().qualities[3], ns.LedgerWindow.OddsFilter().dataOnly })
        assert.is_nil(ns.db.windows.ledger.oddsTab)
        -- Accuracy: AP/EP %, its filters and its headings that close.
        ns.db.windows.ledger = nil
        local acc = ns.LedgerWindow.AccuracyBandRows()
        assert.are.equal(11, #acc[1].cells)                         -- with AP/EP %
        -- AP/EP % in percent of the expected profit (its size: it can be a loss); "-" where none.
        local realAccuracy = ns.Ledger.Accuracy
        local function vsExpected(cost, promised, sold)
            ns.Ledger.Accuracy = function()
                return { total = { n = 30, paid = cost, promised = promised, got = promised, sold = sold, units = 10,
                    soldUnits = 10 }, bands = {}, mats = {} }
            end
            local cells = ns.LedgerWindow.AccuracyBandRows()[1].cells
            ns.Ledger.Accuracy = realAccuracy
            return cells[11], cells
        end
        local vs, cells = vsExpected(1000, 2000, 2500)              -- expected 1000, actual 1500
        assert.are.equal("|cff40ff40+50%|r", vs)                    -- better than the forecast: green, signed
        assert.are.equal("+" .. ns.Money(1000), cells[9]:match("^|cff40ff40(.*)|r$"))    -- Expected profit, green
        assert.are.equal(ns.Money(1500), cells[10]:match("^|c%x%x%x%x%x%x%x%x(.*)|r$"))  -- Actual profit
        assert.are.equal("|cffff4040-25%|r", (vsExpected(1000, 2000, 1750)))          -- actual 750: less, red
        assert.are.equal("|cffff4040-100%|r", (vsExpected(1000, 800, 600)))           -- expected -200, actual -400
        assert.are.equal("|cff808080-|r", (vsExpected(1000, 1000, 1500)))             -- nothing expected
        assert.is_true(acc[2].open)
        acc[2].onClick()                                            -- the Armor heading closes
        assert.are.equal(2, #ns.LedgerWindow.AccuracyBandRows())
        ns.LedgerWindow.AccuracyFilter().collapsed = {}
        ns.LedgerWindow.AccuracyFilter().qualities[2] = nil         -- no uncommon: nothing left to compare
        assert.are.equal(1, #ns.LedgerWindow.AccuracyBandRows())
        ns.db.windows.ledger = nil
        -- In the window: the By band table shows AP/EP %, after Actual profit, with the titles in order,
        -- and its first column is wide enough for the indented quality heading ("Uncommon", not "Uncom...").
        local realWidth = ns.Widgets.TextWidth
        ns.Widgets.TextWidth = shownWidth
        ns.LedgerWindow.Show()
        local frame = _G.SalvagerLedgerFrame
        local frameW = 860
        frame.GetWidth = function() return frameW end
        -- The client keeps a resizable frame inside its resize bounds, SetWidth included.
        local minW, maxW = 860, 860
        frame.SetResizeBounds = function(_, lo, _, hi) minW, maxW = lo, hi or math.huge end
        frame.SetWidth = function(_, w) frameW = math.max(minW, math.min(maxW, w)) end
        local byBand = ns.LedgerWindow.salesParts[2]
        byBand.GetWidth = function() return frameW - 24 end   -- anchored 12 px in from each side
        byBand.GetHeight = function() return 300 end
        local byMat = ns.LedgerWindow.salesParts[4]
        byMat.GetWidth, byMat.GetHeight = byBand.GetWidth, byBand.GetHeight
        local headW
        byBand.headers[1].SetWidth = function(_, w) headW = w end
        ns.LedgerWindow.view = "accuracy"
        ns.LedgerWindow.Refresh()                             -- one refresh: the window fits at once
        -- The quality heading: its indent, its open/close sign and its text fit the first column.
        local uncommon
        for r = 1, #byBand.rows do
            local data = rawget(byBand.rows[r], "data")
            if data and data.cells[1]:find("Uncommon", 1, true) then uncommon = byBand.rows[r] end
        end
        assert.is_table(uncommon)
        local text = ns.Widgets.TextWidth(uncommon.data.cells[1])
        assert.is_true(headW >= uncommon.data.indent + 22 + text)   -- indent, open/close sign (18 + 4), text
        local at
        local titles = {}
        for i, h in ipairs(byBand.headers) do if h:IsShown() then titles[#titles + 1] = h:GetText() end
            if h:IsShown() and h:GetText() == "AP/EP %" then at = i end end
        assert.are.same({ "Band", "Disenchanted", "Paid", "Expected value (EV)", "Disenchant value (DV)", "DV/EV %", "Sold value (SV)",
            "SV/DV %", "Expected profit (EP)", "Actual profit (AP)", "AP/EP %" }, titles)
        -- The help of a comparison names both values in full.
        assert.is_truthy(byBand.columns[8].help[2]:find("Sold value (SV) and Disenchant value (DV)", 1, true))
        assert.is_number(at)                                  -- the title is drawn, inside the resize bounds
        local total = ns.Ledger.Accuracy(ns.db.ledger, function() return true end).total
        local cell = byBand.rows[1].cells[at]
        assert.is_true(cell:IsShown())
        local expected, actual = total.promised - total.paid, math.floor(total.sold + 0.5) - total.paid
        local pct = math.floor((actual - expected) / math.abs(expected) * 100 + 0.5)
        local tone = pct > 0 and "|cff40ff40" or pct < 0 and "|cffff4040" or ""
        assert.are.equal(tone .. (pct > 0 and "+" or "") .. pct .. "%" .. (pct ~= 0 and "|r" or ""), cell:GetText())
        local matTitles = {}
        for _, h in ipairs(byMat.headers) do if h:IsShown() then matTitles[#matTitles + 1] = h:GetText() end end
        assert.are.same({ "Material", "Units", "Disenchant value each (DV)", "Sold value each (SV)", "SV - DV",
            "SV/DV %", "Units sold" }, matTitles)
        -- At logout the layout of every window on show is written for the developer: the main window and the
        -- Ledger with their regions, and the By band table as the client drew it.
        _G.SalvagerFrame:Show()
        wow.fire(ns, "PLAYER_LOGOUT")
        local layout = _G.SalvagerDB.layout
        assert.are.equal(ns.VERSION, layout.version)
        local main, ledger = layout.windows.main, layout.windows.ledger
        assert.is_true(main.shown and ledger.shown)
        assert.are.equal("accuracy", ledger.view)
        assert.is_true(#main.regions > 10 and #ledger.regions > 10)
        assert.is_truthy(ledger.regions[1]:find("^ledger\tFrame\tSV"))
        local bandList
        for _, info in pairs(ledger.lists) do
            if info.columns[10] == "Actual profit (AP)\t70" then bandList = info end
        end
        assert.is_table(bandList)
        assert.are.equal(12, bandList.cells)
        assert.are.equal("AP/EP %\tS", bandList.headers[11]:match("^[^\t]*\t[^\t]*"))
        assert.is_true(layout.entries <= 2000 and layout.size <= 600 * 1024)
        ns.Widgets.TextWidth = realWidth
        assert.is_true(frameW > 860)                          -- wider than its bounds at build
        frame.GetWidth, frame.SetWidth, frame.SetResizeBounds = nil, nil, nil
        ns.db.windows.ledger = nil
        local short, lines = ns.LedgerWindow.Summary()
        for _, word in ipairs({ "Bought", "Disenchanted", "Sold", "Profit" }) do
            assert.is_truthy(short:find(word, 1, true), word)
        end
        assert.is_falsy(short:find("after the cut", 1, true))       -- the details are behind the chart button
        assert.is_true(#lines >= 4)
        assert.is_truthy(table.concat(lines, "\n"):find("materials worth", 1, true))
    end)

    it("lists purchases by profit by default, any column on a click, and hides what is not disenchanted", function()
        local L = ns.db.ledger
        local saved = { purchases = L.purchases, disenchants = L.disenchants }
        L.purchases = { [7001] = { { each = 100, t = 50 } } }                 -- bought, not disenchanted yet
        L.disenchants = {
            { t = 10, itemID = 7002, link = "|Hitem:7002|h[Alpha]|h", costKnown = true, cost = 100, value = 900, got = {} },
            { t = 20, itemID = 7003, link = "|Hitem:7003|h[Beta]|h", costKnown = true, cost = 100, value = 300, got = {} },
        }
        local x = ns.LedgerWindow.PurchaseFilter()
        x.sort = nil
        -- One day: its heading; Not disenchanted first (what you act on), then Disenchanted, by profit, best first.
        local rows = ns.LedgerWindow.PurchaseRows()
        assert.are.equal(6, #rows)
        assert.is_truthy(rows[1].cells[1]:find("3 pieces", 1, true))
        assert.is_truthy(rows[2].cells[1]:find("^Not disenchanted"))
        assert.is_truthy(rows[4].cells[1]:find("^Disenchanted"))
        assert.are.same({ 7001, 7002, 7003 }, { rows[3].itemID, rows[5].itemID, rows[6].itemID })
        assert.are.equal(ns.Money(1200), rows[4].cells[5])                 -- the status heading's totals
        x.sort = { col = 2, desc = true }                                    -- by date, newest first
        rows = ns.LedgerWindow.PurchaseRows()
        assert.are.same({ 7001, 7003, 7002 }, { rows[3].itemID, rows[5].itemID, rows[6].itemID })
        x.show = nil
        x.hideWaiting = true                                  -- the old check box, unticked: Show Disenchanted
        assert.are.equal("done", ns.LedgerWindow.PurchaseFilter().show)
        assert.is_nil(x.hideWaiting)
        rows = ns.LedgerWindow.PurchaseRows()
        assert.are.equal(4, #rows)                            -- the day, Disenchanted and its two
        assert.is_truthy(rows[2].cells[1]:find("^Disenchanted"))
        x.show = "waiting"
        assert.are.same({ 3, 7001 }, { #ns.LedgerWindow.PurchaseRows(), ns.LedgerWindow.PurchaseRows()[3].itemID })
        x.show, x.sort = "all", nil
        L.purchases, L.disenchants = saved.purchases, saved.disenchants
    end)

    it("tracks the current batch: picked up, disenchanted, then posted (SDD 107)", function()
        local L, W = ns.db.ledger, ns.LedgerWindow
        local saved = { purchases = L.purchases, disenchants = L.disenchants, bought = L.bought, sales = L.sales,
            posted = ns.db.posted, bags = env.bags }
        L.purchases = { [7001] = { { each = 1000, ev = 1500, t = 50, link = "|Hitem:7001|h[Alpha]|h" } },
            [7004] = { { each = 300, ev = 400, t = 60, link = "|Hitem:7004|h[Delta]|h" } } }
        L.bought = { { itemID = 7004, each = 300, t = 60 } }                -- still in the mail: not in the batch
        L.disenchants = { { t = 40, itemID = 7002, link = "|Hitem:7002|h[Beta]|h", costKnown = true, cost = 1000,
            evAtBuy = 1200, value = 1600, got = { [11083] = 2 }, quality = 2, classID = 4, band = 30, ilvl = 28 } }
        L.sales, ns.db.posted = {}, {}
        env.bags = { [7001] = 1, [11083] = 2 }
        W.Show()
        ns.db.windows.ledger = _G.SalvagerLedgerFrame.saved   -- (an earlier test dropped the window's saved table)
        W.view = "purchases"
        W.Refresh()
        W.purchaseTabs.batch:Click()
        assert.are.equal("batch", W.PurchaseTab())
        assert.are.equal("Current batch (2)", W.purchaseTabs.batch:GetText())
        local rows = W.BatchRows()
        assert.are.equal(5, #rows)                -- Not disenchanted first, its piece, the disenchanted, its piece, totals
        assert.is_truthy(rows[1].cells[1]:find("^Not disenchanted"))
        assert.are.same({ 7001, ns.Money(1000), ns.Money(1500) }, { rows[2].itemID, rows[2].cells[3], rows[2].cells[4] })
        assert.is_truthy(rows[2].cells[5]:find(ns.Money(500), 1, true))          -- Expected profit, before the disenchant
        assert.is_truthy(rows[2].cells[6]:find("not disenchanted yet", 1, true))
        assert.is_truthy(rows[3].cells[1]:find("^Disenchanted, not posted"))
        local de = rows[4].cells
        assert.are.same({ 7002, "28", "2x Soul Dust", ns.Money(1600), "2x Soul Dust" },
            { rows[4].itemID, de[2], de[6], de[7], de[10] })
        assert.is_truthy(de[8]:find("+33%", 1, true))                           -- luck: 1600 against 1200
        assert.is_truthy(de[9]:find(ns.Money(600), 1, true))                    -- Profit so far
        local now = ns.Money(math.floor(2 * (ns.UnitValue(11083) or 0) + 0.5))
        assert.are.equal(now, de[11])
        local total = rows[5]
        assert.is_true(total.bold and total.rule == "total")
        assert.is_truthy(total.cells[1]:find("2 pieces, 1 disenchanted", 1, true))
        assert.are.same({ ns.Money(2000), ns.Money(2700), ns.Money(1600), "2 units", now },
            { total.cells[3], total.cells[4], total.cells[7], total.cells[10], total.cells[11] })
        assert.is_truthy(total.cells[5]:find(ns.Money(700), 1, true))           -- Expected profit of the batch
        assert.is_truthy(total.cells[9]:find(ns.Money(600), 1, true))           -- Profit so far: the disenchanted part
        ns.db.posted[1] = { itemID = 11083, qty = 1, each = 500, t = 100 }      -- partly posted: it stays
        env.bags[11083] = 1
        assert.are.equal("1x Soul Dust", W.BatchRows()[4].cells[10])
        ns.db.posted[2] = { itemID = 11083, qty = 1, each = 500, t = 110 }      -- all posted: it leaves
        env.bags[11083] = 0
        rows = W.BatchRows()
        assert.are.same({ 3, 7001 }, { #rows, rows[2].itemID })
        rows[1].onClick()                                                       -- the heading closes, remembered
        assert.are.equal(2, #W.BatchRows())
        assert.is_true(ns.db.groups["ledger.batch"].waiting)
        rows[1].onClick()
        env.bags[7001] = 0                                                      -- worn, not in the bags: not in it
        env.equipped = { [10] = 7001 }
        assert.are.equal(1, ns.GetItemCount(7001))                              -- (the game counts what you wear)
        assert.is_truthy(W.BatchRows()[1].cells[1]:find("No batch", 1, true))
        env.equipped = nil
        env.bags[7001] = 0                                                      -- the piece is gone: no batch
        assert.is_truthy(W.BatchRows()[1].cells[1]:find("No batch", 1, true))
        W.Refresh()
        L.purchases, L.disenchants, L.bought, L.sales = saved.purchases, saved.disenchants, saved.bought, saved.sales
        ns.db.posted, env.bags = saved.posted, saved.bags
        ns.db.windows.ledger.purchaseTab = nil
        W.view = "sales"
        W.Refresh()
    end)

    it("clears the history after a confirmation, and keeps the stock", function()
        ns.Ledger.AddStock(ns.db.ledger, 11137, 3, 900)
        ns.Ledger.AddPurchase(ns.db.ledger, 11287, 1, 150, 259, 1)   -- a wand: can never be disenchanted
        ns.Ledger.AddPurchase(ns.db.ledger, BOOTS, 1, 700, 900, 2)   -- still to disenchant
        ns.Options.Open()                                   -- the button is in the options
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
        -- A copy was kept, outside the addon's data: Restore brings the history back.
        local copy = ns.Backup.Last()
        assert.is_true(#copy.ledger.disenchants > 0)
        assert.is_true(ns.Backup.Sizes() > 0)
        ns.Backup.AskRestore()
        assert.are.equal("SALVAGER_RESTORE_LEDGER", env.popup)
        StaticPopupDialogs.SALVAGER_RESTORE_LEDGER.OnAccept()
        assert.is_true(#ns.db.ledger.disenchants > 0)
        assert.are.equal(0, #ns.Backup.Last().ledger.disenchants)      -- what it replaced is a backup too
        ns.Backup.Restore()                                           -- (and so it can be undone)
        assert.are.equal(0, #ns.db.ledger.disenchants)
        ns.Options.Refresh()
        ns.Options.Open()
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
        for _, v in ipairs({ "deals", "materials" }) do
            ns.UI.view = v
            ns.UI.Refresh()
        end
        ns.LimitsWindow.Show()
        ns.LimitsWindow.Refresh()
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
        for _, id in ipairs({ 11082, 11084 }) do ns.db.prices[id] = { p = 1700, t = env.clock } end
    end)

    it("shows the addon version at the left end of each window's title bar", function()
        local toc = io.open("Salvager/Salvager.toc")
        local version = toc:read("*a"):match("## Version: ([^\r\n]+)")
        toc:close()
        ns.LedgerWindow.Show()
        for _, name in ipairs({ "SalvagerFrame", "SalvagerLedgerFrame" }) do
            local f = _G[name]
            local v = rawget(f, "versionText")
            assert.are.equal("v" .. version, v:GetText(), name)
            assert.are.equal(f, v:GetParent(), name)                  -- on the window itself, not in a panel
            assert.are.same({ "LEFT", f.TitleBg, "LEFT", 6, 0 }, v.points[1], name)   -- in the title bar
            assert.is_true(v:IsShown(), name)
        end
        _G.SalvagerLedgerFrame.UserHide()
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
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")   -- uncommon armor: nothing listed
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")   -- uncommon weapons: nothing listed
        wow.tick(ns, 0.2)
        assert.is_false(ns.Busy())
        assert.is_table(ns.Scanner.summary)
    end)

    it("sends only the chosen gear type to the auction house", function()
        ns.db.settings.gearClasses = "weapons"
        ns.db.settings.minProfit = 0
        ns.db.prices[10939] = { p = 1700, t = env.clock }   -- Greater Magic Essence: what low green weapons give
        ns.Scanner.Scan()
        local q
        for _, s in ipairs(env.ah.sent) do if s.kind == "browse" then q = s.query end end
        assert.are.equal(1, #q.itemClassFilters)
        assert.are.equal(2, q.itemClassFilters[1].classID)
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    end)

    it("lowers the buy limits with cautious pricing, not the value", function()
        local normal = ns.Limits()[5]
        ns.db.settings.cautious = true
        local careful = ns.Limits()[5]
        ns.db.settings.cautious = false
        assert.are.equal(normal.armor.value, careful.armor.value)
        assert.is_true(careful.armor.recommended < normal.armor.recommended)
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
        for _, v in ipairs({ "deals", "materials" }) do
            ns.UI.view = v
            ns.UI.Refresh()
        end
        ns.LimitsWindow.Show()
        ns.LimitsWindow.Refresh()
        -- The Limits window: an Armor half and a Weapons half; the rows are the bands of every quality, whatever
        -- the scan looks at, under a heading per quality.
        local limitRows = ns.UI.Rows("limits")
        assert.is_truthy(limitRows[1].cells[1]:find("Uncommon", 1, true))
        assert.is_nil(limitRows[1].limits)
        assert.is_truthy(limitRows[2].cells[1]:find("^1%-"))
        assert.are.equal(22, limitRows[2].indent)
        assert.is_table(limitRows[2].limits.armor)
        assert.is_table(limitRows[2].limits.weapon)
        local qualities = {}
        for _, r in ipairs(limitRows) do if r.head then qualities[#qualities + 1] = r.cells[1] end end
        assert.are.equal(3, #qualities)                       -- Uncommon, Rare, Epic, even with only Uncommon scanned
        ns.LedgerWindow.Toggle()
        assert.is_true(#ns.LedgerWindow.AccuracyBandRows() >= 1)
        assert.is_true(#ns.LedgerWindow.AccuracyMaterialRows() >= 1)
        for _, v in ipairs({ "purchases", "sales", "odds", "accuracy" }) do
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

    it("groups every list of bands one way: gear type, quality, then the range", function()
        local entries = { { quality = 3, classID = 4, band = 50 }, { quality = 2, classID = 2, band = 30 },
            { quality = 2, classID = 4, band = 35 }, { quality = 2, classID = 4, band = 30 } }
        local rows = ns.GroupedRows(entries, function() return { cells = { "" } } end)
        local labels = {}
        for _, r in ipairs(rows) do labels[#labels + 1] = (r.cells[1]:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")) end
        assert.are.same({ "Armor", "Uncommon", "26-30", "31-35", "Rare", "46-50", "Weapons", "Uncommon", "26-30" }, labels)
        -- The market's Disenchant value tab uses it, and its sorting stays inside each group.
        ns.Market.Toggle()
        ns.Market.view = "value"
        local value = ns.Market.Rows()
        for i = 2, #value do assert.is_true((value[i].section or 0) >= (value[i - 1].section or 0)) end
        ns.Market.view = "hour"
        assert.are.equal("Time of day", ns.Market.VIEWS.hour.title)
        local chart = ns.Market.VIEWS.hour.Chart(11083)
        assert.are.equal(24, #chart.xTicks)
        assert.are.equal("03:00", chart.xTicks[4][2])
        ns.Market.view = "material"
        ns.Market.Toggle()
        -- The chart under the mouse: the values at the nearest moment that has one.
        local data = { from = 0, to = 100, lines = {
            { label = "Price", color = { 1, 1, 0 }, points = { { 10, 500 }, { 50, 520 }, { 90, 480 } } },
            { label = "Lowest", color = { 1, 1, 1 }, points = { { 10, 450 }, { 90, 470 } } } },
            bars = { label = "Units listed", points = { { 50, 1300 } } },
            levels = { { label = "Your break-even", value = 600, color = { 1, 0, 0 } } } }
        local n = ns.Widgets.Chart(_G.UIParent).Nearest(data, 47)
        assert.are.equal(50, n.t)
        assert.are.same({ "Price", 520 }, { n.values[1].label, n.values[1].value })   -- "Lowest" has no point there
        assert.are.same({ "Units listed", 1300, true }, { n.values[2].label, n.values[2].value, n.values[2].count })
        assert.are.equal("Your break-even", n.values[3].label)
        assert.is_nil(ns.Widgets.Chart(_G.UIParent).Nearest({ lines = {} }, 5))
    end)

    it("fits the popped out materials list to its columns: no room to spare after Post", function()
        local real = ns.Widgets.TextWidth
        ns.Widgets.TextWidth = shownWidth
        ns.Materials.PopOut()
        local frame = _G.SalvagerMaterialsFrame
        local width
        frame.SetWidth = function(_, w) width = w end
        ns.db.columns = ns.db.columns or {}
        ns.db.columns.materials = { ["Sell price ratio"] = false, ["Time to sell"] = false }
        ns.Materials.Refresh()
        assert.is_number(width)
        assert.is_true(width < 800)                               -- narrower than before, as wide as it needs
        local without = width
        ns.db.columns.materials = nil                             -- both shown: wider by their columns
        ns.Materials.PutBack()
        ns.Materials.PopOut()
        frame.SetWidth = function(_, w) width = w end
        ns.Materials.Refresh()
        assert.is_true(width > without)
        ns.Materials.PutBack()
        ns.Widgets.TextWidth = real
    end)

    it("draws nothing, and no error, for a table shown before it has columns", function()
        local real = ns.Widgets.TextWidth
        ns.Widgets.TextWidth = function(text) return text and #text * 6 or 0 end
        local list = ns.Widgets.List(_G.UIParent, {})
        list:SetSource(0, function() return nil end)
        assert.has_no.errors(function() list:Refresh() end)
        ns.Widgets.TextWidth = real
    end)

    it("makes every column as wide as its widest text, where the client can measure text", function()
        local real = ns.Widgets.TextWidth
        ns.Widgets.TextWidth = function(text) return text and #text * 6 or 0 end
        local need = ns.Widgets.FitColumns({ "Name", "Qty" }, 2, function(r)
            return ({ { "Soul Dust", "5" }, { "Large Glimmering Shard", "12" } })[r], 20
        end)
        assert.are.equal(22 * 6 + 20 + 10, need[1])                -- the longest name, its icon, the padding
        assert.are.equal(3 * 6 + 10, need[2])                      -- the title "Qty" is wider than "12"
        local list = ns.Widgets.List(_G.UIParent, {})
        list:SetColumns({ { "Item", 220 }, { "Paid", 84, "RIGHT" } })
        local rows = { { cells = { "Boots", "1g 20s" } } }
        list:SetSource(1, function(i) return rows[i] end)
        list.GetWidth = function() return 600 end
        local width
        list.headers[2].SetWidth = function(_, w) width = w end
        list:Refresh()
        assert.are.equal(6 * 6 + 10, width)                        -- "1g 20s", not the 84 written in the code
        -- A column with a sample keeps the sample's width, with the widest digit, while its values shrink.
        local digits = ns.Widgets.TextWidth
        ns.Widgets.TextWidth = function(text) return text and (#text * 6 + (text:find("8") and 4 or 0)) or 0 end
        assert.are.equal("88:88", ns.Widgets.WidestDigits("00:00"))
        list:SetColumns({ { "Item", 220 }, { "Time", 62, "RIGHT", sample = "00:00:00" } })
        rows = { { cells = { "Boots", "1:05" } } }
        list:Refresh()
        assert.are.equal(8 * 6 + 4 + 10, width)                    -- "88:88:88", not "1:05"
        ns.Widgets.TextWidth = digits
        -- Every window draws with fitted columns.
        for _, v in ipairs({ "deals", "materials" }) do
            ns.UI.view = v
            ns.UI.Refresh()
        end
        ns.LimitsWindow.Show()
        ns.LimitsWindow.Refresh()
        for _, v in ipairs({ "purchases", "sales", "odds", "accuracy" }) do
            ns.LedgerWindow.view = v
            ns.LedgerWindow.Refresh()
        end
        ns.Materials.PopOut()
        ns.Materials.Refresh()
        ns.Materials.PutBack()
        ns.Market.Toggle()
        ns.Market.Toggle()
        ns.Breakdown.Open(11083)
        ns.LogWindow.Refresh()
        ns.Widgets.TextWidth = real
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)

    it("counts the sort arrow in the width of the main window's sorted column, and keeps a live column's width", function()
        local real = ns.Widgets.TextWidth
        ns.Widgets.TextWidth = shownWidth
        local ARROW = " |TInterface\\Buttons\\Arrow-Down-Up:10|t"
        local function want(view, i, title)
            local w = shownWidth(title)
            for _, r in ipairs(ns.UI.Rows(view)) do w = math.max(w, shownWidth(r.cells[i])) end
            return w + 10
        end
        local widths = {}
        for i = 1, 8 do ns.UI.headers[i].SetWidth = function(_, w) widths[i] = w end end
        ns.UI.view = "deals"
        ns.db.settings.dealSort = "return"
        ns.UI.Refresh()
        assert.are.equal(want("deals", 7, "Return" .. ARROW), widths[7])          -- the title with its arrow
        assert.are.equal(want("deals", 6, "Expected profit"), widths[6])
        ns.db.settings.dealSort = "profit"
        ns.UI.Refresh()
        assert.are.equal(want("deals", 6, "Expected profit" .. ARROW), widths[6])
        assert.are.equal(want("deals", 7, "Return"), widths[7])
        -- The Materials tab's Age grows while it shows: its width stays that of "88m" (8 the widest digit here).
        ns.Widgets.TextWidth = function(text)
            return text and (shownWidth(text) + select(2, text:gsub("8", "")) * 4) or 0
        end
        ns.UI.view = "materials"
        ns.db.prices[11083] = { p = 433, t = time() - 10 }
        ns.UI.Refresh()
        local now = widths[3]
        ns.db.prices[11083] = { p = 433, t = time() - 58 * 60 }
        ns.UI.Refresh()
        assert.are.equal(now, widths[3])
        assert.are.equal(3 * 6 + 2 * 4 + 10, widths[3])
        for i = 1, 8 do ns.UI.headers[i].SetWidth = nil end
        ns.Widgets.TextWidth = real
        ns.UI.view = "deals"
    end)

    it("lets a window go off the screen until 40 px of its title bar are left, and brings them all back", function()
        ns.UI.Show()
        ns.LedgerWindow.Toggle()
        for _, f in ipairs({ _G.SalvagerFrame, _G.SalvagerLedgerFrame }) do
            local insets
            f.SetClampRectInsets = function(_, ...) insets = { ... } end
            f.GetWidth = function() return 860 end
            f.GetHeight = function() return 500 end
            f:GetScript("OnSizeChanged")(f)
            assert.are.same({ 820, -820, 0, 476 }, insets)                    -- 40 px on the left or right, the bar
            f.GetWidth = function() return 900 end                            -- resized: computed again
            f:GetScript("OnSizeChanged")(f)
            assert.are.same({ 860, -860, 0, 476 }, insets)
            f.GetWidth, f.GetHeight, f.SetClampRectInsets = nil, nil, nil
        end
        local ledger = ns.db.windows.ledger
        ledger.x, ledger.y = -700, 300                                         -- dragged mostly off the screen
        ns.db.windows.reports = ns.db.windows.reports or {}
        ns.db.windows.reports.x, ns.db.windows.reports.y = 3000, 10
        ns.db.windows.ahButton = { x = -40, y = 2 }
        ns.db.window.point, ns.db.window.x, ns.db.window.y = "TOPLEFT", -600, 900
        env.chat = {}
        SlashCmdList.SALVAGER("windows reset")
        assert.are.same({ nil, nil }, { ledger.x, ledger.y })
        assert.is_nil(ns.db.windows.reports.x)
        assert.is_nil(ns.db.window.point)
        assert.are.same({ x = -40, y = 2 }, ns.db.windows.ahButton)          -- the auction house button stays
        local p = _G.SalvagerLedgerFrame.points
        assert.are.same({ "CENTER", _G.UIParent, "CENTER", 0, 0 }, p[#p])
        p = _G.SalvagerFrame.points
        assert.are.equal("CENTER", p[#p][1])
        assert.is_truthy(env.chat[#env.chat]:find("back on the screen", 1, true))
        local help = {}
        SlashCmdList.SALVAGER("help")
        for _, m in ipairs(env.chat) do help[#help + 1] = m end
        assert.is_truthy(table.concat(help, "\n"):find("/salv windows reset", 1, true))
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
        for _, id in ipairs({ 11083, 11082, 11084 }) do ns.db.prices[id] = { p = 433, t = env.clock } end
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
            ns.db.prices[m.id] = { p = 433, t = env.clock - 60 }   -- one minute old
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

    it("empties the deals list for a scan started by a click, and keeps it for Play's own rounds", function()
        local function old()
            return { { auctionID = 9, itemID = 5001, buyout = 1, value = 2, profit = 1, keyString = "5001:28:0" } }
        end
        env.ah.fullBrowse = true
        env.ah.browse = { row(1) }
        ns.Scanner.deals = old()
        ns.Scanner.Scan()                                  -- a round Play starts by itself
        assert.are.equal(1, #ns.Scanner.deals)             -- the list stays while the round loads
        ns.Scanner.Stop()
        ns.Scanner.deals = old()
        ns.Scanner.Scan(true)                              -- the Scan gear button
        assert.are.equal(0, #ns.Scanner.deals)
        ns.Scanner.Stop()
        ns.Scanner.deals = old()
        ns.Scanner.Play()                                  -- the Play button
        assert.are.equal(0, #ns.Scanner.deals)
        ns.Scanner.Stop()
        -- An item that is no longer under its limit leaves the list when the round has read the gear.
        env.ah.browse = { row(999999) }
        ns.Scanner.deals = old()
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        assert.are.equal(0, #ns.Scanner.deals)
        ns.Scanner.Stop()
    end)

    it("keeps the deals on screen through Play's own rounds, also when the material prices are scanned first", function()
        ns.Scanner.Stop()
        env.ah.fullBrowse = true
        env.ah.browse = { row(1) }
        env.ah.itemResults[5001] = { { auctionID = 71, buyoutAmount = 1, itemLink = "|Hitem:5001|h[Test Boots]|h" } }
        local function round()
            for _ = 1, 400 do
                if ns.Scanner.state == "browsing" then wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end
                local task = ns.Queue.current
                if task and task.itemKey then wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", task.itemKey) end
                if task and task.commodity then wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", task.commodity) end
                wow.tick(ns, 0.2)
                assert.is_true(#ns.Scanner.deals > 0 or ns.Scanner.round == 1)
                if ns.Scanner.state == "idle" and not ns.Prices.scanning and not ns.scanBothPending then break end
            end
        end
        ns.db.settings.priceRescan = 10
        ns.Scanner.round = 1
        ns.Scanner.Play()
        round()
        assert.are.equal(1, #ns.Scanner.deals)
        ns.Scanner.round = 2
        for id in pairs(ns.db.prices) do ns.db.prices[id].t = env.clock - 3600 end      -- old prices: the next round scans them first
        wow.tick(ns, ns.db.settings.autoInterval + 1)
        assert.is_true(ns.scanBothPending)
        round()
        assert.are.equal(1, #ns.Scanner.deals)
        -- A round whose browse does not load (no page at all): the deals stay as they were.
        ns.Scanner.round = 3
        wow.tick(ns, ns.db.settings.autoInterval + 1)
        assert.are.equal("browsing", ns.Scanner.state)
        for _ = 1, 400 do
            wow.tick(ns, 0.5)
            assert.are.equal(1, #ns.Scanner.deals)
            if ns.Scanner.state == "idle" then break end
        end
        assert.are.equal("idle", ns.Scanner.state)
        assert.are.equal(0, ns.Scanner.summary.candidates)                 -- the round read nothing
        assert.are.equal(1, #ns.Scanner.deals)                             -- and the list still has its deal
        ns.Scanner.round = nil
        ns.Scanner.Stop()
        ns.db.settings.priceRescan = 0
    end)

    it("never values an item with the quality of another browse", function()
        ns.Scanner.Stop()
        local q = ns.db.settings.qualities
        local was = q[3]
        q[3] = true                                                -- the uncommon pass, then the rare pass
        ns.db.prices[11084] = { p = 433, t = env.clock }
        for _, band in ipairs(ns.Data.BLUE) do ns.db.prices[band.shard] = ns.db.prices[band.shard] or { p = 90000, t = 0, test = true } end
        env.ah.fullBrowse = true
        env.ah.browse = { row(1) }                                 -- the uncommon boots
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")       -- the uncommon pass reads them
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", { row(1) })   -- a late page of it, now in the rare pass
        local sum = ns.Scanner.summary
        ns.Scanner.Stop()
        q[3] = was
        for id, e in pairs(ns.db.prices) do if e.test then ns.db.prices[id] = nil end end
        assert.are.equal(1, sum.wrongQuality)                      -- not valued as a rare item
        assert.are.equal(1, sum.candidates)                        -- only as what it is
    end)

    it("only lists item levels inside the ticked bands and the custom range", function()
        local s = ns.db.settings
        assert.is_true(ns.LevelAllowed(28))
        s.levelBandsOff[30] = true                         -- the 26-30 band off
        assert.is_false(ns.LevelAllowed(28))
        assert.is_true(ns.LevelAllowed(31))
        s.levelBandsOff[30] = nil
        s.ilvlMin, s.ilvlMax = 29, 40                      -- a range of your own
        assert.is_false(ns.LevelAllowed(28))
        assert.is_true(ns.LevelAllowed(29))
        assert.is_false(ns.LevelAllowed(41))
        -- The scan: the boots are item level 28, outside 29-40.
        env.ah.fullBrowse = true
        env.ah.browse = { row(1) }
        ns.Scanner.Scan()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        assert.are.equal(0, ns.Scanner.summary.candidates)
        assert.are.equal(1, ns.Scanner.summary.levelOut)
        ns.Scanner.Stop()
        s.ilvlMin, s.ilvlMax = 0, 0
        assert.are.equal(11, #ns.LevelBands())
        assert.are.equal("26-30", ns.LevelBands()[4].label)
        assert.are.equal("61+", ns.LevelBands()[11].label)
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

    it("holds the next browse page while a purchase is on its way", function()
        ns.Scanner.Stop()
        env.ah.fullBrowse = false
        ns.Scanner.Scan()
        local deal = { auctionID = 991, buyout = 100, itemID = 2000, value = 200, profit = 100 }
        ns.Scanner.Buy(deal)
        local sent = #env.ah.sent
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")       -- a page came: the next one is not asked for yet
        assert.are.equal(sent, #env.ah.sent)
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 991)
        wow.tick(ns, 1.5)                                          -- the purchase is done, and the quiet second is over
        assert.are.equal("more", env.ah.sent[#env.ah.sent].kind)
        env.ah.fullBrowse = true
        ns.Scanner.Stop()
        ns.Queue.Clear()
        assert.is_table(ns.Ledger.TakePurchase(ns.db.ledger, 2000))   -- the purchase was recorded; undo it
        table.remove(ns.db.ledger.bought)
    end)

    it("always sends a purchase at once, and frees a dropped one", function()
        wow.tick(ns, 1.1)
        assert.is_false(ns.Scanner.Buying())                       -- nothing holds while nothing is bought
        ns.Scanner.Stop()                                          -- (what the second started is not part of this)
        ns.Queue.Clear()
        local bids = #env.ah.bids
        local deal = { auctionID = 992, buyout = 100, itemID = 2001, value = 200, profit = 100 }
        -- The auction house is busy with one request: the purchase waits for that one answer only, and
        -- goes out the moment the auction house is ready. No second click.
        env.ah.ready = false
        ns.Scanner.Buy(deal)
        assert.is_true(deal.pending)
        assert.are.equal(bids, #env.ah.bids)
        env.ah.ready = true
        wow.fire(ns, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
        assert.are.equal(bids + 1, #env.ah.bids)
        assert.is_true(deal.pending)
        -- The auction house threw it away: the addon sends it again as soon as the auction house is ready,
        -- ahead of everything else. No second click.
        ns.Queue.Add({ commodity = 11083, onResult = function() end, onFail = function() end })
        local sent = #env.ah.sent
        wow.fire(ns, "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED")
        assert.is_true(deal.pending)
        wow.fire(ns, "AUCTION_HOUSE_THROTTLED_SYSTEM_READY")
        assert.are.equal(bids + 2, #env.ah.bids)
        assert.are.equal(sent, #env.ah.sent)                       -- the queued search still waits
        -- The game refuses a purchase without a click: remembered, and the row is freed instead.
        wow.fire(ns, "ADDON_ACTION_BLOCKED", "Salvager", "PlaceBid")
        assert.is_true(ns.db.buyResendBlocked)
        assert.is_false(deal.pending)
        ns.db.buyResendBlocked = nil
        ns.Queue.Clear()
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 992)      -- it went through after all: still booked
        assert.is_table(ns.Ledger.TakePurchase(ns.db.ledger, 2001))
        table.remove(ns.db.ledger.bought)
        wow.tick(ns, 5)
    end)

    it("lets a scan of a few materials in during a gear scan", function()
        ns.Scanner.state = "checking"
        ns.Prices.Scan({ 11083 })
        assert.is_true(ns.Prices.scanning)
        ns.Scanner.state = "idle"
        ns.Scanner.Stop()
        assert.is_false(ns.Prices.scanning)
    end)

    it("merges two searches for the same thing, and both get the answer", function()
        ns.Queue.Clear()
        local got = {}
        ns.Queue.Add({ commodity = 11083, onResult = function() got[#got + 1] = "scan" end, onFail = function() end })
        ns.Queue.Add({ commodity = 11082, onResult = function() got[#got + 1] = "other" end, onFail = function() end })
        -- A click (urgent) for a material whose search is queued: one search, sent first, answers both.
        ns.Queue.Add({ commodity = 11083, onResult = function() got[#got + 1] = "post" end, onFail = function() end }, true)
        ns.Queue.Add({ commodity = 11082, onResult = function() got[#got + 1] = "again" end, onFail = function() end })
        assert.are.equal(2, #ns.Queue.items)
        wow.tick(ns, 0.2)
        assert.are.equal(11083, ns.Queue.current.commodity)
        wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", 11083)
        assert.are.same({ "post", "scan" }, got)
        -- Stop keeps what the player clicked, and drops the rest.
        ns.Queue.Add({ commodity = 11084, onResult = function() end, onFail = function() end }, true)
        ns.Scanner.Stop()
        assert.are.equal(1, #ns.Queue.items)
        assert.are.equal(11084, ns.Queue.items[1].commodity)
        ns.Queue.Clear()
    end)

    it("ends a running undercut check on Stop", function()
        ns.Listings.checking = { done = 0, total = 3 }
        ns.Scanner.Stop()
        assert.is_nil(ns.Listings.checking)
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
        wow.tick(ns, 3.2)
        assert.are.equal("result", got)
        env.ah.hasResults[5001] = nil
    end)

    it("tries a search once more when it gets no answer", function()
        ns.Prices.Scan()
        local first = ns.Queue.items[1] and ns.Queue.items[1].commodity
        wow.tick(ns, 0.2)
        assert.are.equal(first, ns.Queue.current.commodity)
        wow.tick(ns, 2.3)
        assert.are.equal(0, ns.Queue.lost)      -- 2 s is not "no answer" (late answers come, measured 2026-11-27)
        wow.tick(ns, 1)                         -- no answer in 3 s: the same search goes out again, next in line
        assert.are.equal(first, ns.Queue.current.commodity)
        assert.are.equal(1, ns.Queue.current.tries)
        assert.are.equal(1, ns.Queue.lost)
        ns.Scanner.Stop()
    end)

    it("uses a late answer of a search that waits to be sent again, and does not send it again", function()
        ns.Queue.Clear()
        local key = { itemID = 5001, itemLevel = 28, itemSuffix = 0 }
        local got
        ns.Queue.Add({ itemKey = key, onResult = function() got = "result" end, onFail = function() got = "fail" end })
        wow.tick(ns, 0.2)
        local sent = #env.ah.sent
        env.ah.ready = false                    -- the auction house is busy: the second try waits
        wow.tick(ns, 3.0)
        assert.is_nil(ns.Queue.current)
        assert.is_true(ns.Queue.items[1].itemKey == key)
        wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", key)   -- the first answer, late
        assert.are.equal("result", got)
        assert.are.equal(0, #ns.Queue.items)
        env.ah.ready = true
        wow.tick(ns, 2)
        assert.are.equal(sent, #env.ah.sent)    -- not sent a second time
        local late = false
        for _, m in ipairs(ns.db.log) do if m:find("came late", 1, true) then late = true end end
        assert.is_true(late)
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
        for _, id in ipairs({ 11083, 11082, 11084 }) do ns.db.prices[id] = { p = 433, t = env.clock } end   -- a band with a value
        local function rechecked()
            for _, l in ipairs(ns.db.log) do
                if l:find("rechecking item 5001:28:0 after a purchase", 1, true) then return true end
            end
            return false
        end
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 1)
        assert.is_false(rechecked())                     -- not at once: the next click finds the auction house free
        wow.tick(ns, 3)
        assert.is_false(rechecked())                     -- still buying (a click less than 8 s ago)
        wow.tick(ns, 6)
        assert.is_true(rechecked())                      -- searched again once the buying stopped
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

    it("closes a drop-down when you click somewhere else", function()
        local drop
        for _, fr in ipairs(env.frames) do
            if rawget(fr, "checks") and not drop then drop = fr end
        end
        local list = drop.list
        list:Hide()
        drop.scripts.OnClick(drop)
        assert.is_true(list:IsShown())
        list.mouseOver = true                              -- a click on one of its check boxes
        list.scripts.OnEvent(list, "GLOBAL_MOUSE_DOWN")
        assert.is_true(list:IsShown())
        list.mouseOver = false                             -- a click somewhere else
        list.scripts.OnEvent(list, "GLOBAL_MOUSE_DOWN")
        assert.is_false(list:IsShown())
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
        for _, id in ipairs({ 11083, 11082, 11084 }) do ns.db.prices[id] = { p = 433, t = env.clock } end
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
        -- An essence: is the other form the better one to sell?
        local greater = 11082
        local lesser = ns.Data.ESSENCE_PAIR[greater].other
        local keep = { ns.db.prices[greater], ns.db.prices[lesser] }
        local function listed(price, qty) return { rows = { { price = price, qty = qty, mine = 0 } } } end
        ns.db.prices[greater] = { p = 1700, lo = 1700, t = env.clock }
        ns.db.prices[lesser] = { p = 700, lo = 700, t = env.clock }          -- three lesser: 20s 97c, a greater: 16s 99c
        local c = ns.Post.Convert(greater, 1, listed(1700, 10), listed(700, 40))
        assert.are.equal("convert", c.verdict)
        assert.are.equal(3 * 699 - 1699, c.gain)
        assert.are.equal(40, c.otherNear)
        assert.is_truthy(ns.Post.ConvertText(greater, 2, listed(1700, 10), listed(700, 40)):find("split each into 3", 1, true))
        -- The same gain (23%) holds even against a crowded market; a small gain does not.
        assert.are.equal("convert", ns.Post.Convert(greater, 1, listed(1700, 10), listed(700, 4000)).verdict)
        ns.db.prices[lesser] = { p = 600, lo = 600, t = env.clock }          -- three lesser: 17s 97c, +6%
        assert.are.equal("convert", ns.Post.Convert(greater, 1, listed(1700, 10), listed(600, 50)).verdict)
        assert.are.equal("crowded", ns.Post.Convert(greater, 1, listed(1700, 10), listed(600, 4000)).verdict)
        assert.is_truthy(ns.Post.ConvertText(greater, 1, listed(1700, 10), listed(600, 4000)):find("Far more is listed", 1, true))
        assert.are.equal("keep", ns.Post.Convert(lesser, 6).verdict)
        ns.db.prices[lesser] = { p = 500, lo = 500, t = env.clock }          -- now the greater pays more
        assert.is_truthy(ns.Post.ConvertText(lesser, 7):find("Your 7 make 2", 1, true))
        assert.is_nil(ns.Post.Convert(lesser, 2))                    -- fewer than three: nothing to combine
        assert.are.equal("", ns.Post.ConvertText(lesser, 2))
        assert.is_nil(ns.Post.Convert(DUST, 5))                      -- not an essence
        ns.db.prices[greater], ns.db.prices[lesser] = keep[1], keep[2]
        -- A conversion in the bags moves the cost in the ledger.
        local stock = ns.db.ledger.stock
        local had = { stock[lesser], stock[greater], env.bags[lesser], env.bags[greater] }
        stock[lesser], stock[greater] = { qty = 6, cost = 3000, unknown = 0 }, nil
        env.bags[lesser], env.bags[greater] = 6, 0
        wow.fire(ns, "BAG_UPDATE_DELAYED")                           -- the first look
        env.bags[lesser], env.bags[greater] = 3, 1
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        assert.are.equal(3, stock[lesser].qty)
        assert.are.equal(1500, stock[lesser].cost)
        assert.are.equal(1, stock[greater].qty)
        assert.are.equal(1500, stock[greater].cost)
        env.bags[lesser], env.bags[greater] = 6, 0                   -- and split again
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        assert.are.equal(6, stock[lesser].qty)
        assert.are.equal(3000, stock[lesser].cost)
        assert.is_nil(stock[greater])
        env.bags[lesser] = 5                                         -- one posted or mailed: not a conversion
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        assert.are.equal(6, stock[lesser].qty)
        stock[lesser], stock[greater], env.bags[lesser], env.bags[greater] = had[1], had[2], had[3], had[4]
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        -- The other sellers, against a price and a break-even.
        local saved = env.ah.commodities[DUST]
        env.ah.commodities[DUST] = { { unitPrice = 400, quantity = 30, numOwnerItems = 0 },
            { unitPrice = 450, quantity = 25, numOwnerItems = 5 }, { unitPrice = 500, quantity = 10, numOwnerItems = 10 },
            { unitPrice = 600, quantity = 40, numOwnerItems = 0 } }
        local market = ns.Post.Market(DUST)
        assert.are.equal(3, market.listings)                       -- your own listing at 500 is left out
        assert.are.equal(90, market.units)
        local rows, counts = ns.Post.MarketRows(market, 450, 520)
        assert.are.equal(50, counts.ahead)                         -- 30 at 400 and 20 at 450 sell before a post at 450
        assert.are.equal(2, counts.aheadListings)
        assert.are.equal(50, counts.under)                         -- and both are under a break-even of 520
        assert.are.equal(4, #rows)                                 -- three listings and your break-even
        assert.is_truthy(rows[2].cells[1]:find("Your price", 1, true))   -- on the line of the listing at that price
        assert.is_true(rows[2].group)
        assert.is_truthy(rows[3].cells[1]:find("Your break-even", 1, true))
        local between = ns.Post.MarketRows(market, 500, nil)       -- no listing at 500: a line of its own, in its place
        assert.is_truthy(between[3].cells[1]:find("Your price", 1, true))
        assert.is_truthy(rows[2].cells[2]:find("+5 yours", 1, true))
        assert.is_truthy(rows[4].cells[3]:find("90", 1, true))
        assert.are.equal(400, rows[1].pick)                        -- a click on a line: exactly its price
        assert.are.equal(520, rows[3].pick)                        -- on the break-even line: that price
        env.ah.commodities[DUST] = saved
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
        assert.is_true(posted.enabled)
        -- A material you have none of still has its button, switched off.
        local none
        for _, fr in ipairs(env.frames) do
            local data = rawget(fr, "data")
            if data and data.itemID == 11137 and data.action then none = data.action end
        end
        assert.is_table(none)
        assert.is_false(none.enabled)
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

    it("closes every window with the main one, and brings back the ones that were open", function()
        ns.LedgerWindow.Show()
        ns.LogWindow.Show()
        _G.SalvagerFrame:Hide()
        assert.is_false(_G.SalvagerLedgerFrame:IsShown())
        assert.is_false(_G.SalvagerLogFrame:IsShown())
        assert.is_true(ns.db.windows.ledger.open)                -- still remembered
        ns.UI.Show()
        assert.is_true(_G.SalvagerLedgerFrame:IsShown())
        assert.is_true(_G.SalvagerLogFrame:IsShown())
    end)

    it("goes to the game's auction house and back, without stopping a scan", function()
        _G.AuctionHouseFrame = wow.widget("Frame")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        ns.Scanner.state = "browsing"
        ns.UI.ToAuctionHouse()
        assert.is_false(_G.SalvagerFrame:IsShown())
        assert.is_false(_G.SalvagerLedgerFrame:IsShown())
        assert.is_true(_G.AuctionHouseFrame:IsShown())
        assert.are.equal("browsing", ns.Scanner.state)
        local button
        for _, fr in ipairs(env.frames) do if fr.parent == _G.AuctionHouseFrame and fr.text == "Salvager" then button = fr end end
        assert.is_table(button)
        button:Click()
        assert.is_true(_G.SalvagerFrame:IsShown())
        assert.is_true(_G.SalvagerLedgerFrame:IsShown())
        -- ForeverForge's auction window, built a moment after the auction house opens, gets one too.
        _G.ForeverForgeAuctionFrame = wow.widget("Frame")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        wow.tick(ns, 0.6)
        local ff
        for _, fr in ipairs(env.frames) do
            if fr.parent == _G.ForeverForgeAuctionFrame and fr.text == "Salvager" then ff = fr end
        end
        assert.is_table(ff)
        ns.Scanner.state = "idle"
        _G.AuctionHouseFrame, _G.ForeverForgeAuctionFrame = nil, nil
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

    it("splits the Sales view: open auctions, sold with the money to collect, and a history subtab", function()
        local listed, paid = ns.LedgerWindow.ListingRows(), ns.LedgerWindow.SoldRows(false)
        assert.are.equal(2, #listed)                               -- the two auctions still for sale
        -- The sold one is booked as a sale as soon as it is seen, before its mail is taken.
        assert.are.equal(1, #paid)
        assert.is_truthy(paid[1].cells[1]:find("5x Soul Dust", 1, true))
        assert.is_nil(paid[1].cells[2]:find("money due", 1, true))
        assert.is_truthy(paid[1].cells[3]:find("%d+:%d%d"))        -- the time until its money, as a timer
        local sale = ns.db.ledger.sales[1]
        assert.are.equal(5, sale.count)
        assert.are.equal(5, sale.unpaid)
        assert.are.equal(2400, sale.gross)                         -- 5 x 4s 80c
        assert.are.equal(2280 - 5 * 300, sale.profit)              -- after the 5% cut, minus 5 x 3s cost
        assert.are.equal(20, ns.db.ledger.stock[DUST].qty)         -- and they have left the stock
        wow.fire(ns, "OWNED_AUCTIONS_UPDATED")                     -- read again: the same sale is not booked twice
        assert.are.equal(1, #ns.db.ledger.sales)
        ns.LedgerWindow.Show()
        ns.LedgerWindow.view = "sales"
        ns.LedgerWindow.Refresh()
        -- The history is empty until the money is taken from the mail.
        assert.is_truthy(ns.LedgerWindow.SoldRows(true)[1].cells[1]:find("No sale collected yet", 1, true))
        ns.db.windows.ledger.salesTab = "history"
        ns.LedgerWindow.Refresh()
        ns.Ledger.SalePaid(ns.db.ledger, DUST, 5, 2400, 120, time())
        local history = ns.LedgerWindow.SoldRows(true)
        assert.is_truthy(history[1].cells[1]:find("5x Soul Dust", 1, true))
        assert.is_truthy(ns.LedgerWindow.SoldRows(false)[1].cells[1]:find("No sale is waiting", 1, true))
        sale.unpaid, sale.paidAt = 5, nil                          -- (back, for the tests that follow)
        ns.db.windows.ledger.salesTab = nil
        ns.LedgerWindow.Refresh()
        -- The border between the two tables can be moved, within limits, and is remembered.
        ns.LedgerWindow.SetSalesSplit(0.7)
        assert.are.equal(0.7, ns.db.windows.ledger.salesSplit)
        ns.LedgerWindow.SetSalesSplit(5)
        assert.are.equal(0.9, ns.db.windows.ledger.salesSplit)
        ns.db.windows.ledger.salesSplit = nil
        ns.LedgerWindow.view = "purchases"
        ns.LedgerWindow.Refresh()
    end)

    it("shows them in the Sales view: listed, and sold with the wait for the money", function()
        local rows = ns.LedgerWindow.ListingRows()
        local listed, sold
        for _, r in ipairs(rows) do
            if r.cells[1]:find("20x", 1, true) then listed = r end
            if r.cells[1]:find("5x", 1, true) then sold = r end
        end
        assert.is_truthy(listed.cells[2]:find("listed", 1, true))          -- not checked yet
        assert.is_nil(sold)                                                -- a sold auction is not an open one
        sold = ns.LedgerWindow.SoldRows(false)[1]
        assert.is_truthy(sold.cells[1]:find("5x", 1, true))
        assert.is_truthy(sold.cells[3]:find("%d+:%d%d"))                   -- a running timer, minutes:seconds
        assert.is_nil(sold.cells[7]:find("not known", 1, true))            -- its cost: 5 x 3s
        assert.is_truthy(sold.cells[7]:find("15", 1, true))
        assert.is_truthy(listed.cells[8]:find("35", 1, true))              -- 20 x 500 x 0.95 - 20 x 300 = 35s profit
    end)

    it("scans only the owned materials, lists only the materials with data, and breaks a material down", function()
        local before = env.bags[DUST]
        env.bags[DUST] = 7
        local owned = ns.Prices.Owned()
        assert.are.equal(1, #owned)
        assert.are.equal(DUST, owned[1])
        ns.Prices.Scan(owned)
        assert.are.equal(1, ns.Prices.total)
        answer()
        assert.is_false(ns.Prices.scanning)
        ns.db.settings.materialsDataOnly = true
        local rows = ns.Materials.Rows()
        local all = false
        for _, r in ipairs(rows) do if r.itemID == DUST then all = true end end
        assert.is_true(all)
        ns.db.settings.materialsDataOnly = false
        assert.is_true(#ns.Materials.Rows() > #rows)
        env.bags[DUST] = before
        assert.is_true(#ns.Materials.HelpLines() > 5)
        assert.is_true(ns.Breakdown.Is(DUST))
        assert.is_false(ns.Breakdown.Is(1))
        ns.Breakdown.Open(DUST)
        local b = ns.Ledger.Breakdown(ns.db.ledger, DUST)
        local out = ns.Breakdown.Rows(b.items, DUST, function(s) return "x", s.itemID end)
        assert.is_true(#out >= 1)
        assert.is_string((ns.Breakdown.Summary(DUST)))
        assert.is_string((ns.LedgerWindow.Summary()))
    end)

    it("pops the odds out to a window of their own, and puts them back", function()
        ns.LedgerWindow.Show()
        ns.LedgerWindow.view = "odds"
        ns.LedgerWindow.Refresh()
        assert.is_false(ns.LedgerWindow.OddsPoppedOut())
        ns.LedgerWindow.OddsPopOut()
        assert.is_true(ns.LedgerWindow.OddsPoppedOut())
        assert.is_true(ns.db.windows.odds.open)
        ns.LedgerWindow.Refresh()
        assert.are.equal("sales", ns.LedgerWindow.view)            -- the ledger shows another view meanwhile
        ns.LedgerWindow.OddsPutBack()
        assert.is_false(ns.LedgerWindow.OddsPoppedOut())
        assert.is_false(ns.db.windows.odds.open)
    end)

    it("records each material scan and charts it in the Market window", function()
        local points = ns.db.history[DUST]
        assert.is_true(#points >= 1)                               -- the scans of this session
        assert.is_number(points[#points].n)
        ns.db.history[DUST] = { { t = time() - 7200, p = 400, lo = 390, n = 100 }, { t = time() - 3600, p = 500, lo = 480, n = 80 },
            { t = time() - 60, p = 440, lo = 430, n = 120 } }
        ns.Market.Toggle()
        ns.Market.view = "material"
        ns.Market.Select(DUST)
        local data, name, text = ns.Market.VIEWS.material.Chart(DUST)
        assert.are.equal("Soul Dust", name)
        assert.are.equal(2, #data.lines)
        assert.are.equal(3, #data.bars.points)
        assert.is_truthy(text:find("+10%", 1, true))
        local row
        for _, r in ipairs(ns.Market.Rows()) do if r.itemID == DUST then row = r end end
        assert.is_true(row.group)                                  -- the picked one
        assert.is_truthy(row.cells[3]:find("+10%", 1, true))
        -- Every view draws, with and without data.
        for _, view in ipairs({ "value", "profit", "essence", "hour", "material" }) do
            ns.Market.view = view
            ns.Market.Refresh()
            local rows = ns.Market.Rows()
            assert.is_true(#rows >= 1)
        end
        -- The value of one disenchant over time follows the material prices.
        for _, res in ipairs(ns.Model.Outcomes(2, ns.Data.CLASS_ARMOR, 30).results) do
            if res.id ~= DUST then ns.db.history[res.id] = { { t = time() - 5000, p = 900 } } end
        end
        local series = ns.Market.ValueSeries(2, ns.Data.CLASS_ARMOR, 30)
        assert.is_true(#series >= 1)
        assert.is_number(series[#series].p)
        -- By hour: the average per hour of the day.
        local byHour = ns.History.ByHour({ { t = 1, p = 100 }, { t = 2, p = 300 }, { t = 3, p = 50 } },
            function(t) return t == 3 and 5 or 2 end)
        assert.are.same({ { 2, 200 }, { 5, 50 } }, byHour)
        assert.are.equal(500, ns.History.At(ns.db.history, DUST, time() - 100))
        -- Sorting by a column, and every time range.
        ns.Market.view = "material"
        local byChange = ns.Market.Rows()                          -- with no click: by change, the biggest rise first
        assert.is_true(byChange[1].sort[3] >= byChange[#byChange].sort[3])
        ns.Market.sort.material = { col = 2, desc = true }
        local sorted = ns.Market.Rows()
        assert.is_true(sorted[1].sort[2] >= sorted[#sorted].sort[2])
        ns.Market.sort.material = nil
        for _, range in ipairs({ "1m", "1h", "90d", "all" }) do
            ns.Market.range = range
            ns.Market.Refresh()
        end
        ns.Market.range = "24h"
        ns.db.history[DUST] = points
        ns.Market.Toggle()
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
        local sale = ns.LedgerWindow.ListingRows()
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

describe("Salvager Buy Top", function()
    local env, ns
    local LOW, HIGH = 6001, 6002             -- uncommon armor: item level 28 (26-30) and 33 (31-35)
    local function link(id, name, ilvl)
        return "|cff1eff00|Hitem:" .. id .. "::::::::" .. ilvl .. ":::::|h[" .. name .. "]|h|r"
    end
    local function click(b) b.scripts.OnClick(b) end
    local function bid() return env.ah.bids[#env.ah.bids] end
    local function reason()
        local b = ns.UI.buyTop
        b.scripts.OnEnter(b)
        local text = _G.GameTooltip.lines and table.concat(_G.GameTooltip.lines, "\n") or ""
        b.scripts.OnLeave(b)
        return text
    end
    -- A gear scan, answered through events until it is done.
    local function scan()
        ns.Scanner.Scan(true)
        for _ = 1, 200 do
            if ns.Scanner.state == "browsing" then wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end
            local task = ns.Queue.current
            if task and task.itemKey then wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", task.itemKey) end
            wow.tick(ns, 0.2)
            if ns.Scanner.state == "idle" then break end
        end
        ns.UI.Refresh()
    end
    local function value(ilvl)
        for _, r in ipairs(ns.Limits(true)) do
            if r.quality == 2 and ilvl >= r.lo and ilvl <= r.up then return r.armor.value end
        end
    end

    setup(function()
        env = wow.install()
        env.items[LOW] = { name = "Low Boots", quality = 2, ilvl = 28, classID = 4 }
        env.items[HIGH] = { name = "High Helm", quality = 2, ilvl = 33, classID = 4 }
        -- The tooltip keeps what it shows, so a spec can read the reason.
        _G.GameTooltip.SetText = function(self, t) rawset(self, "lines", { t }) end
        _G.GameTooltip.AddLine = function(self, t) table.insert(self.lines, t) end
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        for _, m in ipairs(ns.Data.MATERIALS) do ns.db.prices[m.id] = { p = 1000, t = env.clock } end
        local s = ns.db.settings
        s.minProfit, s.minReturn, s.gearClasses, s.priceRescan = 0, 0, "armor", 0
        s.qualities = { [2] = true, [3] = false, [4] = false }
        s.dealSort = "profit"
    end)

    it("is off with the reason before any scan", function()
        assert.is_false(ns.UI.buyTop:IsEnabled())
        assert.is_truthy(reason():find("No gear scan yet", 1, true))
        local bids = #env.ah.bids
        click(ns.UI.buyTop)
        assert.are.equal(bids, #env.ah.bids)
    end)

    it("buys the top deal by Expected profit, then by Return, each click the next one, never a pending one", function()
        local vLow, vHigh = value(28), value(33)
        assert.is_true(vHigh > vLow + 4)
        -- Low Boots: tiny price, the best Return. High Helm: dearer, the best Expected profit.
        local pHigh = math.floor((vHigh - vLow) / 2)
        env.ah.browse = {
            { itemKey = { itemID = LOW, itemLevel = 28, itemSuffix = 0 }, minPrice = 1 },
            { itemKey = { itemID = HIGH, itemLevel = 33, itemSuffix = 0 }, minPrice = pHigh },
        }
        env.ah.itemResults[LOW] = {
            { auctionID = 101, buyoutAmount = 1, itemLink = link(LOW, "Low Boots", 28) },
            { auctionID = 102, buyoutAmount = 2, itemLink = link(LOW, "Low Boots", 28) },
        }
        env.ah.itemResults[HIGH] = {
            { auctionID = 201, buyoutAmount = pHigh, itemLink = link(HIGH, "High Helm", 33) },
            { auctionID = 202, buyoutAmount = pHigh + 1, itemLink = link(HIGH, "High Helm", 33) },
        }
        scan()
        assert.are.equal(4, #ns.Scanner.deals)
        local rows = ns.UI.Rows("deals")
        assert.are.equal(HIGH, rows[1].itemID)               -- by Expected profit the helm comes first
        assert.is_true(ns.UI.buyTop:IsEnabled())
        local tip = reason()
        assert.is_truthy(tip:find("High Helm", 1, true))     -- the tooltip says what the click buys
        click(ns.UI.buyTop)
        assert.are.same({ id = 201, amount = pHigh }, bid())
        assert.is_true(ns.Scanner.Buying())                   -- the scan holds for the purchase, as for a row's Buy
        -- By Return (a click on the Return title): the boots first; the pending helm is never bought twice.
        local area
        for _, fr in ipairs(env.frames) do if rawget(fr, "sortKey") == "return" then area = fr end end
        area.scripts.OnMouseUp(area)
        assert.are.equal("return", ns.db.settings.dealSort)
        assert.are.equal(LOW, ns.UI.Rows("deals")[1].itemID)
        click(ns.UI.buyTop)
        assert.are.same({ id = 101, amount = 1 }, bid())
        click(ns.UI.buyTop)                                  -- the next one: the other boots
        assert.are.same({ id = 102, amount = 2 }, bid())
        click(ns.UI.buyTop)                                  -- then the other helm
        assert.are.same({ id = 202, amount = pHigh + 1 }, bid())
        ns.UI.Refresh()
        assert.is_false(ns.UI.buyTop:IsEnabled())            -- all on their way
        assert.is_truthy(reason():find("being bought", 1, true))
        local bids = #env.ah.bids
        click(ns.UI.buyTop)
        assert.are.equal(bids, #env.ah.bids)
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)

    it("shows the footer in two lines, the closest item on the second", function()
        local lines = ns.UI.footerLines
        assert.are.equal(2, #lines)
        assert.is_truthy(lines[1]:GetText():find("^%d+ deals%."))
        assert.is_nil(lines[1]:GetText():find("Closest", 1, true))
        assert.is_truthy(lines[2]:GetText():find("^Closest: "))
    end)

    it("is off with the reason when the list is empty, or the auction house is closed", function()
        for _, id in ipairs({ 101, 102, 201, 202 }) do wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", id) end
        ns.Queue.Clear()
        assert.are.equal(0, #ns.Scanner.deals)
        ns.UI.Refresh()
        assert.is_false(ns.UI.buyTop:IsEnabled())
        assert.is_truthy(reason():find("Gear list is empty", 1, true))
        wow.fire(ns, "AUCTION_HOUSE_CLOSED")
        assert.is_false(ns.UI.buyTop:IsEnabled())
        assert.is_truthy(reason():find("Open the auction house first", 1, true))
    end)
end)

describe("Salvager Buy Top, the best single auction", function()
    local env, ns
    local A, B, C = 6011, 6012, 6013         -- uncommon armor: A and B item level 28, C item level 33
    local function link(id, name, ilvl)
        return "|cff1eff00|Hitem:" .. id .. "::::::::" .. ilvl .. ":::::|h[" .. name .. "]|h|r"
    end
    local function click(b) b.scripts.OnClick(b) end
    local function bid() return env.ah.bids[#env.ah.bids].id end
    local function label() return ns.UI.topItem and ns.UI.topItem.text:GetText() or "" end
    local function scan()
        ns.Scanner.Scan(true)
        for _ = 1, 200 do
            if ns.Scanner.state == "browsing" then wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end
            local task = ns.Queue.current
            if task and task.itemKey then wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", task.itemKey) end
            wow.tick(ns, 0.2)
            if ns.Scanner.state == "idle" then break end
        end
        ns.UI.Refresh()
    end
    local function band(ilvl)
        for _, r in ipairs(ns.Limits(true)) do
            if r.quality == 2 and ilvl >= r.lo and ilvl <= r.up then return r.armor.value, r.armor.limit end
        end
    end
    local function auction(id, item, name, ilvl, buyout)
        return { auctionID = id, buyoutAmount = buyout, itemLink = link(item, name, ilvl) }
    end
    local function start(sort)
        env = wow.install()
        env.items[A] = { name = "Alpha Boots", quality = 2, ilvl = 28, classID = 4 }
        env.items[B] = { name = "Beta Boots", quality = 2, ilvl = 28, classID = 4 }
        env.items[C] = { name = "Gamma Helm", quality = 2, ilvl = 33, classID = 4 }
        _G.GameTooltip.SetText = function(self, t) rawset(self, "lines", { t }) end
        _G.GameTooltip.AddLine = function(self, t) table.insert(self.lines, t) end
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        for _, m in ipairs(ns.Data.MATERIALS) do ns.db.prices[m.id] = { p = 1000, t = env.clock } end
        local s = ns.db.settings
        s.minProfit, s.minReturn, s.gearClasses, s.priceRescan = 0, 0, "armor", 0
        s.qualities = { [2] = true, [3] = false, [4] = false }
        s.dealSort = sort
    end

    it("by Expected profit: the best auction of any row, not the rest of the top row", function()
        start("profit")
        local v, limit = band(28)
        assert.is_true(limit >= 6 and limit <= v)
        -- A: three auctions, profits v-1 > v-limit/2 > v-limit; B: one auction, profit v-limit/3 in between.
        local bB, b2 = math.floor(limit / 3), math.floor(limit / 2)
        env.ah.browse = {
            { itemKey = { itemID = A, itemLevel = 28, itemSuffix = 0 }, minPrice = 1 },
            { itemKey = { itemID = B, itemLevel = 28, itemSuffix = 0 }, minPrice = bB },
        }
        env.ah.itemResults[A] = { auction(301, A, "Alpha Boots", 28, 1), auction(302, A, "Alpha Boots", 28, b2),
            auction(303, A, "Alpha Boots", 28, limit) }
        env.ah.itemResults[B] = { auction(401, B, "Beta Boots", 28, bB) }
        scan()
        assert.are.equal(4, #ns.Scanner.deals)
        assert.are.equal(A, ns.UI.Rows("deals")[1].itemID)
        assert.is_truthy(label():find("Alpha Boots", 1, true))   -- the label above the button: what it buys
        local shown
        _G.GameTooltip.SetHyperlink = function(_, l) shown = l end
        ns.UI.topItem.scripts.OnEnter(ns.UI.topItem)              -- its hover: the item's own tooltip
        assert.is_truthy(shown and shown:find("item:" .. A, 1, true))
        ns.UI.topItem.scripts.OnLeave(ns.UI.topItem)
        local order = {}
        for _, want in ipairs({ { 301, "Beta Boots" }, { 401, "Alpha Boots" }, { 302, "Alpha Boots" }, { 303 } }) do
            click(ns.UI.buyTop)
            order[#order + 1] = bid()
            wow.tick(ns, 0.5)                                     -- the window's own refresh (all four within 3 s)
            if want[2] then assert.is_truthy(label():find(want[2], 1, true), label()) end
        end
        assert.are.same({ 301, 401, 302, 303 }, order)
        assert.are.equal(A, ns.UI.Rows("deals")[1].itemID)        -- the list does not move
        ns.UI.Refresh()
        assert.is_false(ns.UI.buyTop:IsEnabled())
        assert.are.equal("", label())                             -- no deal: no label
    end)

    it("by Return: the best auction by Return, which is not the order by Expected profit", function()
        start("return")
        local vL, limL = band(28)
        local vH, limH = band(33)
        local x = math.floor((vH - vL) / 2)
        assert.is_true(x >= 2 and x <= limH)
        local y = math.min(math.floor(vL * 2 / 3), limL - 1)
        assert.is_true(y >= 2)
        -- A (item level 28): returns vL-1, then about 0.5. C (item level 33): one auction, return above 1,
        -- the best Expected profit of all.
        env.ah.browse = {
            { itemKey = { itemID = A, itemLevel = 28, itemSuffix = 0 }, minPrice = 1 },
            { itemKey = { itemID = C, itemLevel = 33, itemSuffix = 0 }, minPrice = x },
        }
        env.ah.itemResults[A] = { auction(301, A, "Alpha Boots", 28, 1), auction(302, A, "Alpha Boots", 28, y),
            auction(303, A, "Alpha Boots", 28, y + 1) }
        env.ah.itemResults[C] = { auction(501, C, "Gamma Helm", 33, x) }
        scan()
        assert.are.equal(4, #ns.Scanner.deals)
        local byId = {}
        for _, d in ipairs(ns.Scanner.deals) do byId[d.auctionID] = d end
        local R = ns.Scanner.Return
        assert.is_true(R(byId[301]) > R(byId[501]) and R(byId[501]) > R(byId[302]) and R(byId[302]) > R(byId[303]))
        assert.is_true(byId[501].profit > byId[301].profit)       -- by Expected profit the helm would come first
        local order = {}
        for _ = 1, 4 do click(ns.UI.buyTop) order[#order + 1] = bid() end
        assert.are.same({ 301, 501, 302, 303 }, order)
    end)

    it("skips the best auction when the gold is short for it, and says so", function()
        start("profit")
        local vL = band(28)
        local vH, limH = band(33)
        local x = math.floor((vH - vL) / 2)
        assert.is_true(x >= 2 and x <= limH)
        env.ah.browse = {
            { itemKey = { itemID = A, itemLevel = 28, itemSuffix = 0 }, minPrice = 1 },
            { itemKey = { itemID = C, itemLevel = 33, itemSuffix = 0 }, minPrice = x },
        }
        env.ah.itemResults[A] = { auction(301, A, "Alpha Boots", 28, 1) }
        env.ah.itemResults[C] = { auction(501, C, "Gamma Helm", 33, x) }
        scan()
        local function tip()
            local b = ns.UI.buyTop
            b.scripts.OnEnter(b)
            local text = table.concat(_G.GameTooltip.lines, "\n")
            b.scripts.OnLeave(b)
            return text
        end
        env.money = x - 1                                          -- enough for the boots, not for the helm
        ns.UI.Refresh()
        assert.is_true(ns.UI.buyTop:IsEnabled())
        assert.is_truthy(label():find("Alpha Boots", 1, true))
        assert.is_truthy(tip():find("Gamma Helm", 1, true))       -- the best one, named as skipped
        assert.is_truthy(tip():find("not enough gold", 1, true))
        env.money = 0                                              -- enough for neither
        ns.UI.Refresh()
        assert.is_false(ns.UI.buyTop:IsEnabled())
        assert.is_truthy(tip():find("Not enough gold for Gamma Helm", 1, true))
        assert.are.equal("", label())
        env.money = x
        ns.UI.Refresh()
        click(ns.UI.buyTop)
        assert.are.equal(501, bid())
    end)

end)

describe("Salvager column chooser", function()
    local env, ns, realWidth, frameW

    -- One band of uncommon armor, so By band has the total, the Armor and Uncommon headings and the band.
    local function accuracy()
        local band = { classID = 4, quality = 2, band = 30, n = 25, paid = 1000, promised = 2000, got = 1900,
            sold = 2100, units = 10, soldUnits = 8 }
        local total = {}
        for k, v in pairs(band) do total[k] = v end
        return { total = total, bands = { band }, mats = { { id = 11083, units = 10, valued = 1000, soldUnits = 8,
            soldNet = 900 } } }
    end

    local function load(db)
        env = wow.install()
        _G.SalvagerDB = db
        env.items[11083] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        ns.Ledger.Accuracy = accuracy
        realWidth = ns.Widgets.TextWidth
        ns.Widgets.TextWidth = shownWidth
    end

    -- The Ledger on its Accuracy view, as wide as the client lets it be (its resize bounds).
    local function openAccuracy()
        ns.LedgerWindow.Show()
        local frame = _G.SalvagerLedgerFrame
        frameW = 860
        local minW, maxW = 860, 860
        frame.GetWidth = function() return frameW end
        frame.SetResizeBounds = function(_, lo, _, hi) minW, maxW = lo, hi or math.huge end
        frame.SetWidth = function(_, w) frameW = math.max(minW, math.min(maxW, w)) end
        local byBand, byMat = ns.LedgerWindow.salesParts[2], ns.LedgerWindow.salesParts[4]
        for _, l in ipairs({ byBand, byMat }) do
            l.GetWidth = function() return frameW - 24 end
            l.GetHeight = function() return 300 end
        end
        ns.LedgerWindow.view = "accuracy"
        ns.LedgerWindow.Refresh()
        return byBand, byMat
    end

    local function shownTitles(list)
        local out = {}
        for _, h in ipairs(list.headers) do if h:IsShown() then out[#out + 1] = h:GetText() end end
        return out
    end

    local function check(chooser, key)
        for _, c in ipairs(chooser.checks) do if c:IsShown() and c.key == key then return c end end
    end

    -- A click on a check box: the client flips it, then runs its script.
    local function toggle(c)
        c:SetChecked(not c:GetChecked())
        c:Click()
    end

    local function hasTitle(list, title)
        for i, h in ipairs(list.headers) do if h:IsShown() and h:GetText() == title then return i end end
    end

    after_each(function() ns.Widgets.TextWidth = realWidth end)

    it("has a chooser at the right end of the titles of the Deals table, the Materials list and the Ledger's tables",
        function()
        load(nil)
        -- The main window: Deals, with its Buy column that cannot be hidden.
        ns.UI.view = "deals"
        ns.UI.Refresh()
        local b = ns.UI.columnsButton
        assert.is_true(b:IsShown())
        b:Click()
        assert.is_true(b.menu:IsShown())
        local n = 0
        for _, c in ipairs(b.checks) do if c:IsShown() then n = n + 1 end end
        assert.are.equal(8 + 1, n)                                 -- every title, and Buy
        assert.are.same({ "Gear", true, false }, { b.checks[1].key, b.checks[1]:GetChecked(), b.checks[1]:IsEnabled() })
        assert.are.same({ "Buy", false }, { b.checks[9].key, b.checks[9]:IsEnabled() })
        assert.is_truthy(b.checks[9].reason:find("buttons", 1, true))
        toggle(check(b, "Type"))                                    -- hidden at once, the menu stays open
        assert.is_false(ns.UI.headers[2]:IsShown())
        assert.is_true(ns.UI.headers[3]:IsShown())
        assert.is_true(b.menu:IsShown())
        assert.are.equal(false, ns.db.columns.deals.Type)
        -- Escape closes the menu; so does a click outside it, and the button again.
        b.menu:GetScript("OnKeyDown")(b.menu, "ESCAPE")
        assert.is_false(b.menu:IsShown())
        b:Click()
        b.menu:GetScript("OnEvent")(b.menu, "GLOBAL_MOUSE_DOWN")
        assert.is_false(b.menu:IsShown())
        b:Click()
        b:Click()
        assert.is_false(b.menu:IsShown())
        -- The Limits window has none: its columns go in pairs, Armor and Weapons.
        ns.LimitsWindow.Show()
        assert.is_false(ns.LimitsWindow.list.chooser:IsShown())
        ns.UI.view = "deals"
        -- The Materials window's list.
        ns.Materials.PopOut()
        local mats
        for _, c in ipairs(_G.SalvagerMaterialsFrame._children) do
            if rawget(c, "columnSet") == "materials" then mats = c end
        end
        assert.is_table(mats)
        assert.is_true(mats.chooser:IsShown())
        mats.chooser:Click()
        assert.is_truthy(check(mats.chooser, "Post"))               -- the buttons' column, greyed
        assert.is_false(check(mats.chooser, "Post"):IsEnabled())
        mats.chooser:Click()
        ns.Materials.PutBack()
        -- The Ledger's tables, each view.
        local byBand, byMat = openAccuracy()
        for _, l in ipairs({ byBand, byMat }) do assert.is_true(l.chooser:IsShown()) end
        for _, v in ipairs({ "purchases", "sales", "odds" }) do
            ns.LedgerWindow.view = v
            ns.LedgerWindow.Refresh()
        end
        assert.is_true(ns.LedgerWindow.salesParts[2].chooser:IsShown())
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)

    it("hides SV/DV % in rows and headings, narrows the table, keeps the choice over a reload, and shows all again",
        function()
        load(nil)
        local byBand, byMat = openAccuracy()
        assert.are.same({ "Band", "Disenchanted", "Paid", "Expected value (EV)", "Disenchant value (DV)", "DV/EV %",
            "Sold value (SV)", "SV/DV %", "Expected profit (EP)", "Actual profit (AP)", "AP/EP %" }, shownTitles(byBand))
        local wide = byBand.neededWidth
        assert.is_number(wide)
        local chooser = byBand.chooser
        chooser:Click()
        local n = 0
        for _, c in ipairs(chooser.checks) do if c:IsShown() then n = n + 1 end end
        assert.are.equal(11, n)                                     -- one row per column
        -- The first column cannot be hidden.
        local first = check(chooser, "Band")
        assert.are.same({ true, false }, { first:GetChecked(), first:IsEnabled() })
        assert.is_truthy(first.reason:find("first column", 1, true))
        assert.is_false(chooser.showAll:IsEnabled())                -- nothing hidden yet
        toggle(check(chooser, "SV/DV %"))
        assert.is_nil(hasTitle(byBand, "SV/DV %"))
        assert.is_number(hasTitle(byMat, "SV/DV %"))                -- By material keeps its own
        -- Its cells are gone from every row, the headings included; the next column moves into its place.
        local headings = 0
        for _, row in ipairs(byBand.rows) do
            local data = rawget(row, "data")
            if data then
                assert.is_false(row.cells[8]:IsShown())
                if data.group or data.head then headings = headings + 1 end
            end
        end
        assert.is_true(headings >= 3)                               -- All bands, Armor, Uncommon
        assert.is_true(byBand.neededWidth < wide)
        assert.is_true(chooser.showAll:IsEnabled())
        assert.are.same({ ["SV/DV %"] = false }, _G.SalvagerDB.columns.accBands)
        -- The first column stays even when the saved data says otherwise; unknown titles are ignored.
        _G.SalvagerDB.columns.accBands.Band = false
        _G.SalvagerDB.columns.accBands["Not a column"] = false
        -- A reload: a new load with the same saved data.
        wow.fire(ns, "PLAYER_LOGOUT")
        local layout = _G.SalvagerDB.layout
        assert.is_truthy(layout.hidden.accBands:find("SV/DV %", 1, true))
        local db = _G.SalvagerDB
        load(db)
        byBand = openAccuracy()
        assert.is_nil(hasTitle(byBand, "SV/DV %"))
        assert.are.equal(1, hasTitle(byBand, "Band"))
        assert.are.equal(10, #shownTitles(byBand))
        local listed
        wow.fire(ns, "PLAYER_LOGOUT")
        for _, info in pairs(_G.SalvagerDB.layout.windows.ledger.lists) do
            if info.set == "accBands" then listed = info end
        end
        assert.is_table(listed)
        assert.is_truthy(table.concat(listed.hidden, ","):find("SV/DV %", 1, true))
        -- Show all brings every column back.
        byBand.chooser:Click()
        byBand.chooser.showAll:Click()
        assert.are.equal(11, #shownTitles(byBand))
        assert.is_nil(_G.SalvagerDB.columns.accBands)
        assert.is_true(byBand.chooser.menu:IsShown())
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)
end)

describe("Salvager layout dump", function()
    local env, ns
    setup(function()
        env = wow.install()
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
    end)

    local function logList()
        wow.fire(ns, "PLAYER_LOGOUT")
        local layout = _G.SalvagerDB.layout
        local _, info = next(layout.windows.log.lists)
        return layout, info
    end

    it("writes every row on screen of a list in full, with the font, the justification and the color", function()
        local long = string.rep("a long log line ", 10)        -- 160 characters: more than the cut of hidden texts
        for i = 1, 50 do ns.Log(i == 50 and long or ("line %d"), i) end
        ns.LogWindow.Show()
        local layout, info = logList()
        assert.are.same({ w = "1920", h = "1080", scale = "1", eff = "1" }, layout.screen)
        assert.are.equal("1", layout.windows.log.scale)
        -- The list follows its last line: the rows on screen are the last ones, the rows scrolled away are not written.
        local fit = math.floor(560 / 15)
        local count = #ns.db.log
        assert.are.equal(count, info.count)
        assert.are.equal(fit, #info.rows)
        assert.are.equal(info.rowsShown, #info.rows)
        assert.are.equal(count - fit + 1, info.rows[1].n)
        assert.are.equal(count, info.rows[#info.rows].n)
        local last = info.rows[#info.rows].cells[1]
        local flags, width, text = last:match("^([^\t]*)\t([^\t]*)\t([^\t]*)")
        assert.are.equal("SV", flags)
        assert.are.equal("140", width)
        assert.is_truthy(text:find(long, 1, true))            -- in full
        assert.is_truthy(last:find("\tf=10", 1, true))
        assert.is_truthy(last:find("\tj=L", 1, true))
        assert.is_falsy(last:find("\tc=", 1, true))           -- white: no color written
        -- Scrolled to the top: the first lines, and a text color that is not white.
        local list
        for _, f in ipairs(env.frames) do
            if rawget(f, "rows") and rawget(f, "headers") and f.parent == _G.SalvagerLogFrame then list = f end
        end
        list.offset, list.atBottom = 0, false
        list:Refresh()
        list.rows[1].cells[1]:SetTextColor(1, 0, 0)
        info = select(2, logList())
        assert.are.equal(1, info.rows[1].n)
        assert.is_truthy(info.rows[1].cells[1]:find("\tc=ff0000ff", 1, true))
        -- Regions carry the drawing facts: a color texture's color, a text's font size.
        local main = _G.SalvagerDB.layout.windows.main
        local colored, sized = false, false
        for _, line in ipairs(main.regions) do
            if line:find("\tTexture\t", 1, true) and line:find("\tct=%x%x%x%x%x%x%x%x") then colored = true end
            if line:find("\tFontString\t", 1, true) and line:find("\tf=10", 1, true) then sized = true end
        end
        assert.is_true(colored and sized)
    end)

    it("writes the texts on show in full and stays within its size bound", function()
        local long = string.rep("x", 20000)
        local function inMain(f)
            while type(f) == "table" do
                if f == _G.SalvagerFrame then return true end
                f = rawget(f, "parent")
            end
            return false
        end
        -- Every text of the main window, and of the Log window's own, far too long for the bound together.
        for _, f in ipairs(env.frames) do
            if inMain(f) or f == _G.SalvagerLogFrame then
                for _, r in ipairs(f._regions) do if r.kind == "FontString" then r.text = long end end
            end
        end
        wow.fire(ns, "PLAYER_LOGOUT")
        local layout = _G.SalvagerDB.layout
        assert.is_true(layout.size <= 600 * 1024)
        -- The regions went from the last window on show (main, after log); the first one keeps them, in full.
        local log, main = layout.windows.log, layout.windows.main
        assert.is_true(main.dropped)
        assert.is_nil(main.regions)
        local full = false
        for _, line in ipairs(log.regions) do if line:find(long, 1, true) then full = true end end
        assert.is_true(full)
        for _, rec in pairs(layout.windows) do assert.is_table(rec.lists) end
    end)
end)

describe("The cost of disenchanted gear in a simulated client", function()
    local env, ns
    local BOOTS_LINK = "|cff1eff00|Hitem:5001::::::::30:::::|h[Test Boots]|h|r"
    local DUST, SHARD = 11083, 11084
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
        env.items[SHARD] = { name = "Large Glimmering Shard", quality = 1, ilvl = 1, classID = 7 }
        env.bagLinks = { ["0:1"] = BOOTS_LINK }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
    end)

    it("shares what two 11s boots cost over the dust and the shard they gave, by value", function()
        ns.db.prices[DUST] = { p = 433, t = time() }
        ns.db.prices[SHARD] = { p = 1800, t = time() }   -- the two boots were worth about what they cost
        local L = ns.db.ledger
        ns.Ledger.AddPurchase(L, 5001, 2, 2200, 2500, time())     -- two boots, 11s each
        disenchant({ { id = DUST, qty = 1 } })
        assert.are.equal(1100, L.stock[DUST].cost)                -- alone in its band so far
        disenchant({ { id = SHARD, qty = 1 } })
        assert.are.equal(2, #L.disenchants)
        assert.are.equal(L.disenchants[1].band, L.disenchants[2].band)
        -- The same cost for each copper of value: dust and shard get 22s in the ratio of 4.33s to 18s.
        local dustCost, shardCost = L.stock[DUST].cost, L.stock[SHARD].cost
        assert.are.equal(2200, dustCost + shardCost)
        assert.are.same({ 426, 1774 }, { dustCost, shardCost })   -- by value after the cut: 411 and 1710
        assert.is_true(math.abs(dustCost / 411 - shardCost / 1710) < 0.001)
        -- So the dust's break-even sits near its market price, not near the 11s its boots cost.
        local even = ns.Ledger.BreakEven(L, DUST, ns.Cut())
        assert.are.equal(math.ceil(426 / (1 - ns.Cut())), even)
        assert.is_true(even > 433 * 0.9 and even < 433 * 1.1, tostring(even))
        -- The Materials list shows that break-even.
        local found
        for _, r in ipairs(ns.Materials.Rows()) do if r.itemID == DUST then found = r end end
        assert.is_table(found)
        assert.are.equal(ns.Money(even), found.cells[8])
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)
end)

describe("The forecast learns from your own sales in a simulated client", function()
    local env, ns
    local DUST = 11083
    local function answer()
        for _ = 1, 40 do
            wow.tick(ns, 0.2)
            local c = ns.Queue.current
            if c and c.commodity then wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", c.commodity) end
        end
    end
    local function dustBandLimit()
        for _, row in ipairs(ns.Limits(true)) do
            if row.quality == 2 and row.up == 30 then return row.armor.limit, row.armor.value end
        end
    end

    setup(function()
        env = wow.install()
        env.items[DUST] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        env.ah.commodities[DUST] = { { unitPrice = 430, quantity = 50, numOwnerItems = 0 } }
        env.bags[DUST] = 10
        env.bagSlots = { [2] = DUST }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        ns.Prices.Scan({ DUST })
        answer()
    end)

    it("sells below the value, so the sell price ratio and the buy limit go down", function()
        assert.are.equal(430, ns.PriceOf(DUST))
        ns.db.settings.minProfit, ns.db.settings.minReturn = 100, 0
        local r = ns.SellRatio(DUST)
        assert.are.same({ 1, 0, true }, { r.ratio, r.n, r.few })        -- no sales: 1, and it says few sales
        assert.are.equal(3, ns.DepositPerUnit(DUST))                     -- no data: one post's deposit per unit
        local limit0, value0 = dustBandLimit()
        -- Five posts of 2 at 80% of the value, each sold.
        for i = 1, 5 do
            assert.is_true(ns.Post.Send(DUST, 2, 344, 2))
            wow.fire(ns, "AUCTION_HOUSE_AUCTION_CREATED", 100 + i)
            assert.are.equal(430, ns.db.posted[#ns.db.posted].val)       -- the value when it was posted
        end
        env.ah.owned = {}
        for i = 1, 5 do
            env.ah.owned[i] = { auctionID = 100 + i, itemKey = { itemID = DUST }, status = 1, quantity = 2,
                timeLeftSeconds = 3000, buyoutAmount = 344 }
        end
        wow.fire(ns, "OWNED_AUCTIONS_UPDATED")
        assert.are.equal(5, #ns.db.ledger.sales)
        assert.are.equal(430, ns.db.ledger.sales[1].val)
        r = ns.SellRatio(DUST)
        assert.are.same({ 0.8, 5, false }, { r.ratio, r.n, r.few })
        assert.are.equal(0, ns.DepositPerUnit(DUST))                     -- five sales, no deposit lost
        local limit1, value1 = dustBandLimit()
        assert.is_true(value1 < value0, value1 .. " " .. value0)
        assert.is_true(limit1 < limit0, limit1 .. " " .. limit0)
        -- The Materials list and the tooltip show it.
        local row
        for _, m in ipairs(ns.Materials.Rows()) do if m.itemID == DUST then row = m end end
        assert.are.equal("80.0%", row.cells[10])
        -- Time to sell: each sale knows its post (postedAt); sold as soon as posted here.
        assert.is_number(ns.db.ledger.sales[1].postedAt)
        assert.are.same({ 5, false }, { ns.TimeToSell(DUST).n, ns.TimeToSell(DUST).few })
        assert.are.equal("< 1 min", row.cells[11])
        assert.are.equal("3 h 05 min", ns.DurationText(3 * 3600 + 5 * 60))
        assert.are.equal("2 d 4 h", ns.DurationText(52 * 3600))
        -- Return per day: minutes to sell count as a day, so it is the Return.
        local days, few, secs = ns.DaysToSell({ { id = DUST, value = 100 } })
        assert.are.same({ 1, false, 0 }, { days, few, secs })
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)
end)

describe("Sessions and the statement in a simulated client", function()
    local env, ns
    local BOOTS_LINK = "|cff1eff00|Hitem:5001::::::::30:::::|h[Test Boots]|h|r"
    local DUST = 11083
    local function money(amount)
        env.money = env.money + amount
        wow.fire(ns, "PLAYER_MONEY")
    end
    -- A fresh client (the game reloaded or logged in again) with the saved data, the gold and the clock it had.
    local function load(saved, gold, clock, initial, reload)
        env = wow.install()
        env.items[5001] = { name = "Test Boots", quality = 2, ilvl = 28, req = 23, classID = 4 }
        env.items[DUST] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        env.bagLinks = { ["0:1"] = BOOTS_LINK }
        env.money, env.clock = gold, clock
        _G.SalvagerDB = saved
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "PLAYER_ENTERING_WORLD", initial, reload)
    end
    local function sellMail(bid, cut, count, daysLeft)
        wow.fire(ns, "MAIL_SHOW")
        env.inbox[1] = { sender = "Auction House", subject = "Auction successful: Soul Dust", money = bid - cut,
            daysLeft = daysLeft, invoice = { "seller", "Soul Dust", "Buyer", bid, bid, 0, cut, 0, 0, 0, count } }
        TakeInboxMoney(1)
        money(bid - cut)
        table.remove(env.inbox, 1)
        wow.fire(ns, "MAIL_INBOX_UPDATE")
        wow.fire(ns, "MAIL_CLOSED")
    end
    local function labels(rows)
        local out = {}
        for _, r in ipairs(rows) do out[#out + 1] = r.cells[1] end
        return table.concat(out, "\n")
    end

    setup(function() load(nil, 1000000, 1700000000, true, false) end)

    it("starts a session at login, and books a buy, a disenchant and a sale in it", function()
        local s = ns.db.sessions.open
        assert.are.same({ "Tester-Realm", 1700000000 }, { s.c, s.start })
        ns.db.prices[DUST] = { p = 433, t = time() }
        local deal = { auctionID = 501, itemID = 5001, link = BOOTS_LINK, buyout = 500, value = 900, profit = 400,
            quality = 2, classID = 4, ilvl = 28 }
        ns.Scanner.Buy(deal)
        money(-500)
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 501)
        env.clock = env.clock + 60
        wow.fire(ns, "UNIT_SPELLCAST_SENT", "player", nil, "cast-guid", 13262)
        wow.fire(ns, "ITEM_LOCK_CHANGED", 0, 1)
        env.loot = { { id = DUST, qty = 3 } }
        wow.fire(ns, "LOOT_READY")
        env.clock = env.clock + 60
        sellMail(1200, 60, 2, 30)
        local st = ns.Gold.Statement(s.start)
        assert.are.same({ 1140, 333, 807 }, { st.sales, st.cost, st.trading })
        assert.are.equal(st.trading + st.away.profit + st.stock.change, st.total)
        assert.are.equal(0, st.check.missing)
        ns.Reports.Show()
        ns.Reports.view, ns.Reports.range, ns.Reports.goldTab = "gold", "session", "statement"
        ns.Reports.Refresh()
        local rows = ns.Reports.StatementRows()
        assert.is_truthy(labels(rows):find("Trading profit", 1, true))
        assert.is_nil(labels(rows):find("Sold while you were away", 1, true))
        assert.is_nil(labels(rows):find("Sessions:", 1, true))              -- one session: no list of sessions
        local seen = {}
        for _, r in ipairs(rows) do
            local plain = r.cells[1]:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            if (r.indent or 0) == 0 and (plain == "Trading" or plain == "Gold not from trading"
                or plain == "Check against your gold") then
                assert.is_true(r.group, plain)                           -- a section heading, no amount
                assert.are.equal("", r.cells[2])
                seen[plain] = true
            end
            if plain:find("^Sales, after the auction house cut") or plain:find("^Less gold at the start") then
                assert.is_true((r.indent or 0) > 0, plain)               -- lines indented under their heading
            end
            if plain == "Trading profit" or plain == "Change in gold and mail" or plain == "Explained by the records"
                or plain == "Total gold not from trading" then
                assert.are.equal("total", r.rule, plain)                 -- a subtotal: a rule over the amount
                assert.is_true(r.bold, plain)                            -- totals are bold
                assert.are.equal(0, r.indent or 0)                       -- at the heading's level
                seen[plain] = true
            end
            if plain == "Total: how much richer you are" or plain == "Not explained: none" then
                assert.are.equal("final", r.rule, plain)                 -- the bottom line: a double rule under it
                assert.is_true(r.bold, plain)
                seen[plain] = true
            end
            assert.is_nil(plain:find("^="), plain)                       -- no "=" lines
            -- One sign rule: + came in, - went out, on every amount.
            local amount = r.cells[2]:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            if amount ~= "" and amount ~= "-" and not amount:find("^0") then
                assert.is_truthy(amount:find("^[+-]"), plain .. ": " .. amount)
            end
            if plain == "Trading profit" then
                -- the sign with the amount, the coins of a column (8s 07c: every unit under the largest, two digits)
                assert.are.equal("|cff40ff40+" .. ns.MoneyColumn(807) .. "|r", r.cells[2])
                assert.is_truthy(ns.Util.FormatMoney(807, false, true) == "8s 07c")
            end
            if r.cells[1]:find("Not explained", 1, true) then
                assert.is_nil(r.cells[1]:find("check", 1, true))        -- every change has its record
            end
            if r.cells[1] ~= "" and not r.cells[1]:find("^|cff808080") then assert.is_table(r.tip, r.cells[1]) end
        end
        for _, want in ipairs({ "Trading", "Gold not from trading", "Check against your gold", "Trading profit",
            "Change in gold and mail", "Explained by the records", "Total gold not from trading",
            "Total: how much richer you are", "Not explained: none" }) do
            assert.is_true(seen[want], want)
        end
        -- The heading says what it is, for which character and which time.
        assert.are.equal("Gold statement of Tester-Realm", rows[1].cells[1])
        assert.is_truthy(rows[2].cells[1]:find("This session: %d%d%-%d%d %d%d:%d%d to now %(%d+ min%)"), rows[2].cells[1])
        -- A statement: the amount column as wide as its widest text (the stand-in measures 6 px a character) and
        -- flush with the table's right edge; the label column takes the rest.
        local real = ns.Widgets.TextWidth
        ns.Widgets.TextWidth = shownWidth
        local list, widths = ns.Reports.list, {}
        list.GetWidth = function() return 860 end
        for i = 1, 2 do list.headers[i].SetWidth = function(_, w) widths[i] = w end end
        ns.Reports.Refresh()
        local want = shownWidth("Amount")   -- (a total's texts are in the larger font: 12 pt against 10)
        for _, r in ipairs(rows) do
            want = math.max(want, r.bold and (math.ceil(shownWidth(r.cells[2]) * 1.2)) or shownWidth(r.cells[2]))
        end
        local right = 860 - 18 - 4          -- the table's right: its width, less the scroll bar and the inset
        local x2 = list.headers[2].points[1][4]
        assert.are.equal(want + 10, widths[2])
        assert.are.equal(right, x2 + widths[2])                          -- the amounts end at the right edge
        assert.are.equal(right, list.amountsRight)
        assert.are.equal(x2 - 6 - 4, widths[1])                          -- the labels fill the free width
        assert.is_true(widths[1] > 600)
        -- A table that is not a statement does the same: its label column takes the free width, so its last
        -- column ends at the right edge (UI.md Tables 2), here the Gear Bands table of a wide window.
        ns.Reports.view, ns.Reports.gearTab = "gear", "bands"
        local bands, bw = ns.Reports.list, {}
        bands.GetWidth = function() return 1200 end
        for i = 1, #bands.headers do bands.headers[i].SetWidth = function(_, w) bw[i] = w end end
        ns.Reports.Refresh()
        local last
        for i = #bands.headers, 2, -1 do if bands.headers[i].shown ~= false and bw[i] then last = i break end end
        assert.is_number(last)
        assert.are.equal(1200 - 18 - 4, bands.headers[last].points[1][4] + bw[last])
        ns.Reports.view = "gold"
        ns.Reports.Refresh()
        -- Every amount cell is right-justified, and a total line draws its rules over the amounts.
        for _, row in ipairs(list.rows) do
            local data = rawget(row, "data")
            if data then
                assert.are.equal("RIGHT", row.cells[2].justifyH)
                assert.are.equal(data.rule ~= nil, row.rules[1].shown)
                assert.are.equal(data.rule == "final", row.rules[2].shown and row.rules[3].shown)
            end
        end
        ns.Widgets.TextWidth = real
    end)

    it("keeps the session over a /reload", function()
        local start = ns.db.sessions.open.start
        wow.fire(ns, "PLAYER_LOGOUT")
        load(_G.SalvagerDB, env.money, env.clock + 30, false, true)
        assert.are.equal(start, ns.db.sessions.open.start)
        assert.are.equal(0, #ns.db.sessions.list)
        assert.is_truthy(table.concat(ns.db.log, "\n"):find("reloaded with", 1, true))
        assert.are.equal(807, ns.Gold.Statement(start).trading)         -- the session's trading goes on
    end)

    it("closes the session at logout, and puts a sale paid while away on its own line at the next login", function()
        env.clock = env.clock + 60
        wow.fire(ns, "PLAYER_LOGOUT")
        local stop = env.clock
        -- Ten hours later; the last dust sold five hours ago, its mail waits.
        load(_G.SalvagerDB, env.money, stop + 36000, true, false)
        local list = ns.db.sessions.list
        assert.are.equal(1, #list)
        assert.are.same({ 1700000000, stop }, { list[1].start, list[1].stop })
        local s = ns.db.sessions.open
        assert.are.equal(stop + 36000, s.start)
        sellMail(600, 30, 1, 30 - 5 / 24)
        local sale = ns.db.ledger.sales[#ns.db.ledger.sales]
        assert.is_true(sale.away)
        local st = ns.Gold.Statement(s.start)
        assert.are.same({ 0, 0 }, { st.sales, st.trading })
        assert.are.same({ 1, 570, 167, 403 }, { st.away.n, st.away.net, st.away.cost, st.away.profit })
        -- The dust left the stock: at the start worth what the forecast gave one unit then (under 433 x 0.95 = 411:
        -- its deposits lost per unit sold come off, SDD 97b).
        assert.is_true(st.stock.v0 < 411)
        assert.are.same({ 0, -(st.stock.v0 - 167) }, { st.stock.v1, st.stock.change })
        assert.are.equal(st.away.profit + st.stock.change, st.total)
        assert.are.equal(0, st.check.missing)
        ns.Reports.Show()
        ns.Reports.view, ns.Reports.range, ns.Reports.goldTab = "gold", "session", "statement"
        ns.Reports.Refresh()
        assert.is_truthy(labels(ns.Reports.StatementRows()):find("Sold while you were away", 1, true))
        -- No Sessions subtab: the Gold view has Statement and All gold changes; a session is a choice of the period.
        for _, fr in ipairs(env.frames) do assert.are_not.equal("Sessions", rawget(fr, "text")) end
        local name = ns.Reports.SessionName(ns.db.sessions.list[1])
        assert.is_truthy(name:match("^%d%d%-%d%d %d%d:%d%d, %d+ min$"), name)
        local keys = {}
        for _, o in ipairs(ns.Reports.PeriodOptions()) do keys[#keys + 1] = o[1] end
        assert.are.same({ "session", "s:1700000000", "24h", "7d", "30d", "all" }, keys)
        assert.are.same({ "all", "All time" }, ns.Reports.PeriodOptions()[6])
        assert.are.equal(name, ns.Reports.PeriodOptions()[2][2])
        -- All time: the statement of every record, then one line per session with its total; a click shows it.
        ns.Reports.range = "all"
        ns.Reports.Refresh()
        local rows = ns.Reports.StatementRows()
        assert.is_truthy(rows[2].cells[1]:find("All time: every record kept", 1, true))
        local at
        for i, r in ipairs(rows) do
            if r.cells[1] == "|cffffd100Sessions: how much richer each one made you|r" then at = i end
        end
        assert.is_number(at)
        assert.is_truthy(rows[at + 1].cells[1]:find("(now)", 1, true))
        assert.are.equal(name, rows[at + 2].cells[1])
        assert.are.equal("|cff40ff40+" .. ns.MoneyColumn(ns.db.sessions.list[1].sum.total) .. "|r", rows[at + 2].cells[2])
        assert.is_truthy(table.concat(rows[at + 2].tip, " "):find("Trading profit: |cff40ff40+" .. ns.MoneyColumn(807), 1,
            true))
        rows[at + 2].onClick()
        assert.are.equal("s:1700000000", ns.Reports.range)
        assert.are.equal("s:1700000000", ns.db.windows.reports.range)       -- remembered with the window
        local from, _, to = ns.Reports.From()
        assert.are.same({ 1700000000, stop }, { from, to })
        rows = ns.Reports.StatementRows()
        assert.is_truthy(rows[2].cells[1]:find("Session " .. name, 1, true))
        assert.is_nil(labels(rows):find("Sessions:", 1, true))              -- one session: no list of sessions
        -- The rows from the top: tabs, the Gold subtabs, the filter row with "Period", then the table.
        local bars = ns.Reports.bars
        assert.are.equal("filterrow", bars.filters.uiKind)
        assert.are.equal(86, bars.filters.top)                            -- under the tabs (24-54) and the subtabs
        assert.are.equal(58, bars.gold.top)
        assert.are.equal(-116, ns.Reports.list.points[1][5])
        ns.Reports.view = "materials"
        ns.Reports.Refresh()
        assert.are.equal(58, bars.filters.top)                            -- no subtabs: right under the tabs
        assert.is_false(bars.gold:IsShown())
        assert.is_false(bars.gear:IsShown())
        assert.are.equal(-88, ns.Reports.list.points[1][5])
        -- Gear: its subtabs Bands and History, then the filter row (Period, then the gear's filters).
        ns.Reports.view = "gear"
        ns.Reports.Refresh()
        assert.is_true(bars.gear:IsShown())
        assert.are.equal(58, bars.gear.top)
        assert.are.equal(86, bars.filters.top)
        assert.are.equal(-116, ns.Reports.list.points[1][5])
        ns.Reports.view = "gold"
        for _, tab in ipairs({ "changes", "statement" }) do
            ns.Reports.goldTab = tab
            ns.Reports.Refresh()
        end
        -- A /reload keeps the period picked.
        wow.fire(ns, "PLAYER_LOGOUT")
        load(_G.SalvagerDB, env.money, env.clock + 30, false, true)
        ns.Reports.Show()
        assert.are.equal("s:1700000000", ns.Reports.range)
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)

    it("values stock the same in the statement and in Reports, Materials: as the forecast values a unit", function()
        ns.db.prices[DUST] = { p = 433, t = time() }
        ns.db.ledger.stock[DUST] = { qty = 4, cost = 600 }
        env.bags[DUST] = 4
        ns.ForecastChanged()
        local each = ns.UnitValue(DUST)
        local opts = ns.ValueOptions()
        -- price x sell price ratio x (1 - cut) - deposits lost per unit sold, not price x (1 - cut)
        assert.are.equal(433 * opts.ratio(DUST) * 0.95 - opts.deposit(DUST), each)
        assert.is_true(opts.deposit(DUST) > 0)
        assert.are.equal(math.floor(each * 4), ns.Gold.Stock().mv)
        ns.Reports.view, ns.Reports.range = "materials", "all"
        local value
        for _, r in ipairs(ns.Reports.MaterialRows()) do
            if r.itemID == DUST then value = r.cells[10] end
        end
        assert.are.equal(ns.MoneyColumn(math.floor(each * 4)), value)
    end)
end)

describe("Salvager control hierarchy (UI.md Controls)", function()
    local env, ns
    local KINDS = { tabrow = { tab = true }, subtabrow = { subtab = true },
        filterrow = { dropdown = true, check = true, edit = true, button = true, help = true } }
    setup(function()
        env = wow.install()
        env.items[11083] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        -- Every window, every view.
        ns.UI.Show()
        for _, v in ipairs({ "deals", "materials" }) do ns.UI.view = v ns.UI.Refresh() end
        ns.LedgerWindow.Show()
        for _, v in ipairs({ "sales", "purchases", "accuracy", "odds" }) do
            ns.LedgerWindow.view = v
            ns.LedgerWindow.Refresh()
        end
        ns.LedgerWindow.OddsPopOut()
        ns.Materials.PopOut()
        ns.Market.Toggle()
        ns.Reports.Show()
        for _, v in ipairs({ "gear", "materials", "gold" }) do ns.Reports.view = v ns.Reports.Refresh() end
        ns.LogWindow.Show()
        ns.LimitsWindow.Show()
        ns.Options.Open()
        pcall(ns.Post.Open, 11083)
        ns.GearWindow.Open({ auctionID = 1, itemID = 5001, quality = 2, classID = 4, ilvl = 28, buyout = 100,
            value = 500, profit = 400 })
    end)

    local function windowOf(frame)
        local p = frame
        while type(p) == "table" and rawget(p, "parent") ~= _G.UIParent and rawget(p, "parent") ~= nil do p = p.parent end
        return p
    end

    it("puts only tabs on a tab row and only subtabs on a subtab row, and nothing hangs on them", function()
        local rows = 0
        for _, fr in ipairs(env.frames) do
            local allowed = KINDS[rawget(fr, "uiKind") or ""]
            if allowed then
                rows = rows + 1
                for _, child in ipairs(fr._children) do
                    -- (A dropdown's list is its own child, not the row's.)
                    assert.is_true(allowed[rawget(child, "uiKind") or ""] or false,
                        fr.uiKind .. " holds a " .. tostring(rawget(child, "uiKind") or child.kind))
                end
                if fr.uiKind ~= "filterrow" then
                    for _, r in ipairs(fr._regions) do
                        assert.are_not.equal("FontString", r.kind, fr.uiKind .. " holds a text: " .. tostring(r.text))
                    end
                end
            end
        end
        assert.is_true(rows >= 12)
        -- No other control is placed by a tab or a row of tabs.
        local function isTabby(x) return type(x) == "table" and (rawget(x, "uiKind") == "tab" or rawget(x, "uiKind") == "tabrow"
            or rawget(x, "uiKind") == "subtab" or rawget(x, "uiKind") == "subtabrow") end
        local function check(obj)
            for _, p in ipairs(rawget(obj, "points") or {}) do
                for i = 1, #p do
                    -- (A row's or a tab's own art and text hang on it.)
                    if isTabby(p[i]) and not isTabby(obj) and rawget(obj, "parent") ~= p[i] then
                        error("a " .. tostring(rawget(obj, "uiKind") or obj.kind) .. " hangs on a " .. p[i].uiKind
                            .. ": " .. tostring(rawget(obj, "text")))
                    end
                end
            end
        end
        for _, fr in ipairs(env.frames) do
            check(fr)
            for _, r in ipairs(fr._regions) do check(r) end
        end
    end)

    it("gives each kind of control its own look", function()
        local seen = {}
        for _, fr in ipairs(env.frames) do
            local kind = rawget(fr, "uiKind")
            if kind == "tab" or kind == "subtab" or kind == "dropdown" then
                seen[kind] = true
                assert.are_not.equal("UIPanelButtonTemplate", rawget(fr, "_template"), kind .. " looks like a button")
            end
        end
        assert.are.same({ tab = true, subtab = true, dropdown = true }, seen)
    end)

    it("labels every filter at its left, and puts a check box's label at its right", function()
        for _, fr in ipairs(env.frames) do
            if rawget(fr, "uiKind") == "filterrow" then
                for i, item in ipairs(fr.items) do
                    local kind = rawget(item, "uiKind")
                    if kind == "dropdown" or kind == "edit" then
                        local before = fr.items[i - 1]
                        assert.are.equal("FontString", before and before.kind, "a filter without its label")
                    elseif kind == "check" then
                        assert.are.equal("RIGHT", item.label.points[1][3])
                    end
                end
            end
        end
    end)

    it("orders the rows: tabs, subtabs, filters, then the content", function()
        local L = ns.LedgerWindow
        L.view = "purchases"
        L.Refresh()
        local b = L.bars
        assert.is_true(b.tabs.top < b.purchases.top and b.purchases.top < b.purchaseFilters.top)
        L.view = "accuracy"
        L.Refresh()
        assert.is_true(b.tabs.top < b.accuracyFilters.top)
        assert.are.equal(b.purchases.top, b.accuracyFilters.top)   -- no subtabs: right under the tabs
        -- The main window: tabs, then the Deals view's settings or the Materials view's filter row.
        assert.are.equal(24, ns.UI.tabBar.top)
        assert.is_true(ns.UI.materialsBar.top > ns.UI.tabBar.top)
        assert.are.equal("footer", ns.UI.footerBar.uiKind)
        -- The Market: tabs, then its filter row.
        assert.is_true(ns.Market.bars.tabs.top < ns.Market.bars.filters.top)
    end)

    it("fits every row in its window at the smallest width", function()
        for _, fr in ipairs(env.frames) do
            if rawget(fr, "used") and rawget(fr, "items") then
                local w = windowOf(fr)
                local min = rawget(w, "minWidth")
                assert.is_number(min, "a row in a window without a smallest width")
                assert.is_true(fr.used <= min - 20, string.format("%s needs %d px in a window of %d",
                    fr.uiKind, fr.used, min))
            end
        end
    end)

    it("closes every window with Escape", function()
        local names = {}
        for _, n in ipairs(_G.UISpecialFrames) do names[n] = true end
        for _, n in ipairs({ "SalvagerFrame", "SalvagerLedgerFrame", "SalvagerOddsFrame", "SalvagerMaterialsFrame",
            "SalvagerMarketFrame", "SalvagerReportsFrame", "SalvagerLogFrame", "SalvagerLimitsFrame",
            "SalvagerOptionsFrame", "SalvagerGearFrame" }) do
            assert.is_true(names[n] or false, n)
        end
    end)
end)

describe("Salvager gear, Gear details and headings that open and close (0.3.129)", function()
    local env, ns
    local A, B = 6021, 6022                  -- uncommon armor, item level 28 (band 26-30)
    local function link(id, name) return "|cff1eff00|Hitem:" .. id .. "::::::::28:::::|h[" .. name .. "]|h|r" end
    local function auction(id, item, name, buyout) return { auctionID = id, buyoutAmount = buyout, itemLink = link(item, name) } end
    local function tip() return table.concat(_G.GameTooltip.lines or {}, "\n") end
    local function rowFrames()
        local out = {}
        for _, fr in ipairs(env.frames) do if rawget(fr, "buy") and fr:IsShown() then out[#out + 1] = fr end end
        return out
    end
    local function scan()
        ns.Scanner.Scan(true)
        for _ = 1, 200 do
            if ns.Scanner.state == "browsing" then wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end
            local task = ns.Queue.current
            if task and task.itemKey then wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", task.itemKey) end
            wow.tick(ns, 0.2)
            if ns.Scanner.state == "idle" then break end
        end
        ns.UI.Refresh()
    end

    setup(function()
        env = wow.install()
        env.items[A] = { name = "Alpha Boots", quality = 2, ilvl = 28, classID = 4 }
        env.items[B] = { name = "Beta Gloves", quality = 2, ilvl = 28, classID = 4 }
        env.items[11083] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        -- The tooltip keeps what it shows.
        _G.GameTooltip.SetText = function(self, t) rawset(self, "lines", { t }) end
        _G.GameTooltip.SetHyperlink = function(self, l) rawset(self, "lines", { l }) end
        _G.GameTooltip.AddLine = function(self, t) table.insert(self.lines, t) end
        _G.GameTooltip.AddDoubleLine = function(self, a, b) table.insert(self.lines, a .. " = " .. b) end
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        for _, m in ipairs(ns.Data.MATERIALS) do
            ns.db.prices[m.id] = { p = 1000, t = env.clock }
            ns.History.Add(ns.db.history, m.id, env.clock - 3600, 900, 900, 10)
            ns.History.Add(ns.db.history, m.id, env.clock - 60, 1000, 1000, 10)
        end
        local s = ns.db.settings
        s.minProfit, s.minReturn, s.gearClasses, s.priceRescan = 0, 0, "armor", 0
        s.qualities = { [2] = true, [3] = false, [4] = false }
        s.dealSort = "profit"
        env.ah.browse = {
            { itemKey = { itemID = A, itemLevel = 28, itemSuffix = 0 }, minPrice = 1 },
            { itemKey = { itemID = B, itemLevel = 28, itemSuffix = 0 }, minPrice = 2 },
        }
        env.ah.itemResults[A] = { auction(301, A, "Alpha Boots", 1), auction(302, A, "Alpha Boots", 3) }
        env.ah.itemResults[B] = { auction(401, B, "Beta Gloves", 2) }
        ns.UI.Show()
        ns.UI.view = "deals"
        scan()
        assert.are.equal(3, #ns.Scanner.deals)
    end)

    it("names the main window's tabs Gear and Materials, the scans Gear, Materials, Both, and Buy Top", function()
        local names = {}
        for _, t in ipairs(ns.UI.tabBar.items) do names[#names + 1] = t:GetText() end
        assert.are.same({ "Gear", "Materials" }, names)
        assert.are.equal("Gear", ns.UI.headers[1]:GetText())                  -- the first column: the gear
        local b = ns.UI.scanButtons
        assert.are.same({ "Gear", "Materials", "Both" }, { b[1]:GetText(), b[2]:GetText(), b[3]:GetText() })
        -- Each one hangs at the left of the next: Gear, Materials, Both from left to right.
        assert.are.equal(b[2], b[1].points[1][2])
        assert.are.equal(b[3], b[2].points[1][2])
        assert.are.equal("Buy Top", ns.UI.buyTop:GetText())
        ns.UI.buyTop.scripts.OnEnter(ns.UI.buyTop)
        assert.are.equal("Buy Top", _G.GameTooltip.lines[1])
        ns.UI.buyTop.scripts.OnLeave(ns.UI.buyTop)
        -- The help in chat says gear, not items.
        local before = #env.chat
        SlashCmdList.SALVAGER("help")
        local out = table.concat(env.chat, "\n", before + 1)
        assert.is_truthy(out:find("which gear types the scan looks at", 1, true))
        assert.is_nil(out:find("items", 1, true))
    end)

    it("titles every window \"Salvager <Name>\", the name capitalized", function()
        local titles = {}
        for line in io.lines("Salvager/Salvager.toc") do
            if line:match("%.lua$") then
                local text = io.open("Salvager/" .. line):read("*a")
                for title in text:gmatch('W%.Window%("Salvager%w+Frame", "([^"]+)"') do titles[#titles + 1] = title end
            end
        end
        assert.is_true(#titles >= 12)
        for _, t in ipairs(titles) do
            -- (The mini panel is the main window's small form: "Salvager", as the main window, UI.md Layout 10.)
            assert.is_truthy(t == "Salvager" or t:match("^Salvager %u%l+$") or t:match("^Salvager %u%l+ %u%l+$"), t)
        end
    end)

    it("shows the same deal lines on a Gear row and on the gear above Buy Top", function()
        local d = ns.UI.TopDeal()
        assert.are.equal(301, d.auctionID)
        local top = ns.UI.topItem
        top.scripts.OnEnter(top)
        local fromTop = tip()
        top.scripts.OnLeave(top)
        local head = rowFrames()[1]                                          -- Alpha Boots x2: its numbers are 301's
        assert.are.equal(A, head.item.itemID)
        head.scripts.OnEnter(head)
        local fromRow = tip()
        head.scripts.OnLeave(head)
        for _, want in ipairs({ "Item level = 28", "Buyout = ", "Expected value = ", "Expected profit = ", "Return = ",
            "Loss chance = ", "Time to sell (its materials) = ", "Return per day = " }) do
            assert.is_truthy(fromTop:find(want, 1, true), want)
        end
        -- The row's tooltip is the same; each ends with the hint of its click.
        assert.are.equal((fromTop:gsub("\n[^\n]*$", "")), (fromRow:gsub("\n[^\n]*$", "")))
        assert.is_truthy(fromRow:find("Click: open or close the group", 1, true))
        assert.is_truthy(fromTop:find("Click: Gear Details", 1, true))
        -- Expected profit and Return with their sign: green when they gain (UI.md Tables 7).
        assert.is_truthy(head.item.cells[6]:find("^|cff40ff40%+"))
        assert.is_truthy(head.item.cells[7]:find("^|cff40ff40%+"))
        -- A click on the gear above Buy Top opens its Gear Details.
        local realOpen, opened = ns.GearWindow.Open, nil
        ns.GearWindow.Open = function(deal) opened = deal end
        ns.UI.topItem.scripts.OnClick(ns.UI.topItem)
        ns.GearWindow.Open = realOpen
        assert.are.equal(ns.UI.topItem.deal, opened)
        assert.is_table(opened)
    end)

    it("opens a group heading with a click and keeps it open; a click on an auction opens its Gear details", function()
        local head = rowFrames()[1]
        assert.is_false(head.item.open)
        assert.is_false(head.toggle.open)                                    -- the arrow points right: closed
        head.scripts.OnClick(head)
        assert.is_nil(ns.GearWindow.Frame())                                 -- a heading never opens the details
        assert.is_true(ns.db.groups["main.gear"]["Alpha Boots"])             -- remembered in the saved data
        local rows = rowFrames()
        assert.is_true(rows[1].item.open)
        assert.is_true(rows[1].toggle.open)                                  -- the arrow points down: open
        assert.is_true(rows[2].item.child)
        rows[2].scripts.OnEnter(rows[2])
        assert.is_truthy(tip():find("Click: Gear details of this auction", 1, true))
        rows[2].scripts.OnClick(rows[2])                                     -- Alpha Boots, 1c
        local g = ns.GearWindow
        local frame = _G.SalvagerGearFrame
        assert.is_true(frame:IsShown())
        assert.are.equal("Salvager Gear Details", frame.TitleText:GetText())
        assert.are.equal(301, g.deal.auctionID)
        -- A click on another row replaces the content.
        local beta
        for _, r in ipairs(rowFrames()) do if r.item.deal and r.item.deal.auctionID == 401 then beta = r end end
        beta.scripts.OnClick(beta)
        assert.are.equal(401, g.deal.auctionID)
        rows[2].scripts.OnClick(rows[2])
        assert.are.equal(301, g.deal.auctionID)
    end)

    it("shows the deal as a statement, how its Expected value is built, your history and the other auctions", function()
        local g, d = ns.GearWindow, ns.GearWindow.deal
        local deal = g.DealRows(d)
        assert.are.same({ "Expected value of one disenchant", "Buyout", "Expected profit" },
            { deal[1].cells[1], deal[2].cells[1], deal[3].cells[1] })
        assert.are.equal("|cff40ff40+" .. ns.MoneyColumn(d.value) .. "|r", deal[1].cells[2])  -- comes in: green, +
        assert.are.equal("-" .. ns.MoneyColumn(d.buyout), deal[2].cells[2])                    -- goes out: -
        assert.are.same({ "final", true }, { deal[3].rule, deal[3].bold })
        assert.are.equal(14, deal[1].indent)                                                    -- lines one step in
        local m = g.MeasureRows(d)[1].cells
        assert.are.equal(6, #m)
        assert.is_truthy(m[4] == "Min profit" or m[4] == "Min return")                         -- which rule set it
        -- One row per possible result, the totals row last: the parts add up to the Expected value.
        local build, from = g.BuildRows(d)
        local total = build[#build]
        assert.are.same({ "total", true }, { total.rule, total.bold })
        assert.are.equal(ns.MoneyColumn(d.value), total.cells[5])
        assert.is_true(#build >= 3)
        assert.is_truthy(from:find("0 of your disenchants of this band (few results)", 1, true))
        local hist = g.HistoryRows(d)
        assert.are.equal("Alpha Boots", hist[1].cells[1])
        assert.is_truthy(hist[2].cells[1]:find("Its band: ", 1, true))
        local others = g.OtherRows(d)
        assert.are.equal(1, #others)                                         -- the other Alpha Boots, 3c
        assert.are.equal(ns.MoneyColumn(3), others[1].cells[1])
        -- The window draws every part, with its tables under their titles.
        for _, key in ipairs({ "deal", "measures", "build", "history", "others" }) do
            assert.is_true(g.parts[key].list:IsShown(), key)
        end
        for _, msg in ipairs(env.chat) do assert.is_nil(msg:find("error", 1, true), msg) end
    end)

    it("buys from its footer (Buy, then Close last), says why Buy is off, and keeps the auction on show", function()
        local g = ns.GearWindow
        local close = g.footer.items[1]
        assert.are.equal("Close", close:GetText())
        assert.are.equal(close, g.buyButton.points[1][2])                    -- Buy sits left of Close
        assert.is_true(g.buyButton:IsEnabled())
        g.buyButton.scripts.OnClick(g.buyButton)
        assert.are.same({ id = 301, amount = 1 }, env.ah.bids[#env.ah.bids])
        g.Refresh()
        assert.is_false(g.buyButton:IsEnabled())
        g.buyButton.scripts.OnEnter(g.buyButton)
        assert.is_truthy(tip():find("being bought", 1, true))
        g.buyButton.scripts.OnLeave(g.buyButton)
        -- The auction leaves the list: the window still shows it; Buy says why it is off.
        wow.fire(ns, "AUCTION_HOUSE_PURCHASE_COMPLETED", 301)
        g.Refresh()
        assert.are.equal(301, g.deal.auctionID)
        assert.is_truthy(g.BuyReason(nil):find("no longer in the Gear list", 1, true))
        assert.is_false(g.buyButton:IsEnabled())
        local names = {}
        for _, n in ipairs(_G.UISpecialFrames) do names[n] = true end
        assert.is_true(names.SalvagerGearFrame)                              -- Escape closes it
        close.scripts.OnClick(close)
        assert.is_false(_G.SalvagerGearFrame:IsShown())
        ns.Queue.Clear()
    end)

    it("has the Reports tabs Gold, Gear, Materials, Competition; Gear has Bands then History; an old Items view moves over", function()
        ns.db.windows.reports = { view = "items" }                           -- saved by 0.3.128: the Items tab
        ns.Reports.Show()
        assert.are.same({ "gear", "history" }, { ns.Reports.view, ns.Reports.gearTab })
        local names = {}
        for _, t in ipairs(ns.Reports.bars.tabs.items) do names[#names + 1] = t:GetText() end
        assert.are.same({ "Gold", "Gear", "Materials", "Competition" }, names)
        names = {}
        for _, t in ipairs(ns.Reports.bars.gear.items) do names[#names + 1] = t:GetText() end
        assert.are.same({ "Bands", "History" }, names)
        assert.is_true(ns.Reports.gearTabs.history.selected)
        assert.are.equal("reports.items", rawget(ns.Reports.list, "columnSet"))
        ns.Reports.gearTabs.bands:Click()
        assert.are.equal("reports.profit", rawget(ns.Reports.list, "columnSet"))
        assert.are.equal("bands", ns.db.windows.reports.gearTab)             -- remembered with the window
        assert.is_true(ns.Reports.bars.filters.top > ns.Reports.bars.gear.top)   -- filters under the subtabs
        ns.Reports.Toggle()
    end)

    it("opens and closes the headings of the Limits, the Market's Disenchant value and the Breakdown", function()
        -- The Limits: a heading per quality.
        local rows = ns.LimitsWindow.Rows()
        local n = #rows
        assert.is_true(rows[1].head and rows[1].open)
        rows[1].onClick()
        assert.is_true(ns.db.groups.limits["2"])
        rows = ns.LimitsWindow.Rows()
        assert.is_false(rows[1].open)
        assert.is_true(rows[2].head)                                         -- Uncommon's bands are gone
        assert.is_true(#rows < n)
        ns.LimitsWindow.Show()
        ns.LimitsWindow.Refresh()
        assert.is_false(ns.LimitsWindow.list.rows[1].toggle.open)            -- the arrow points right
        rows[1].onClick()
        assert.are.equal(n, #ns.LimitsWindow.Rows())
        -- The Market's Disenchant value: gear type and quality headings.
        ns.Market.Toggle()
        ns.Market.view = "value"
        local value = ns.Market.Rows()
        assert.is_true(value[1].head and value[1].open)
        local before = #value
        value[1].onClick()
        assert.is_true(ns.db.groups["market.value"]["4"])
        local after = ns.Market.Rows()
        assert.is_false(after[1].open)                                       -- Armor closed: its bands are gone,
        assert.is_true(after[2].head)                                        -- the Weapons heading comes next
        assert.is_true(#after < before)
        ns.Market.Rows()[1].onClick()
        assert.are.equal(before, #ns.Market.Rows())
        ns.Market.view = "material"
        ns.Market.Toggle()
        -- The Breakdown's bands.
        ns.db.ledger.disenchants[#ns.db.ledger.disenchants + 1] = { link = link(A, "Alpha Boots"), itemID = A,
            costKnown = true, cost = 100, value = 900, quality = 2, classID = 4, band = 30, got = { [11083] = 2 },
            vals = { [11083] = 900 }, t = time() }
        local bands = ns.Breakdown.BandRows(11083)
        assert.is_true(bands[1].head and bands[1].open)
        before = #bands
        bands[2].onClick()
        assert.is_true(ns.db.groups["breakdown.bands"]["4:2"])
        assert.are.equal(before - 1, #ns.Breakdown.BandRows(11083))
        ns.Breakdown.BandRows(11083)[2].onClick()
        assert.are.equal(before, #ns.Breakdown.BandRows(11083))
    end)

    it("draws a heading's arrow one way in every table, and a heading card's whole title band is its click", function()
        local list = ns.Widgets.List(_G.UIParent, {})
        list:SetColumns({ { "Band", 100 } })
        local data = { { cells = { "Armor" }, open = true }, { cells = { "Weapons" }, open = false } }
        list:SetSource(2, function(i) return data[i] end)
        list.GetWidth = function() return 400 end
        list:Refresh()
        assert.are.same({ true, false }, { list.rows[1].toggle.open, list.rows[2].toggle.open })
        local stack = ns.Widgets.CardList(_G.UIParent)
        stack:SetColumns({ { "Material", 100 } })
        stack:SetCards({ { heading = true, title = "Armor", open = false, onClick = function() end } })
        stack:Refresh()
        local card = stack.cards[1]
        assert.is_false(card.toggle.open)
        assert.are.equal(0, card.click.points[2][4])                         -- to the right edge: the whole band
    end)
end)

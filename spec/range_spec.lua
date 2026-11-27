local helper = require("spec.helper")
local wow = require("spec.wow")

-- Outcomes in whole units, the range of a deal and its evidence (SDD 116): one disenchant gives whole units of one
-- material, never 1.5; the range is two real outcomes; every average says it is one.
describe("Whole-unit outcomes and the range of one disenchant", function()
    local ns, Model, Data
    local function price(id) return ({ [11083] = 400, [11082] = 1700, [11084] = 5800, [20725] = 600000 })[id] end
    local opts = { cut = 0.05 }

    before_each(function()
        ns = helper.load()
        Model, Data = ns.Model, ns.Data
    end)

    local function sum(list)
        local s = 0
        for _, x in ipairs(list) do s = s + x.chance end
        return s
    end

    it("lists every outcome in whole units, the chances adding up to 1, lowest value first", function()
        local o = Model.Outcomes(2, Data.CLASS_ARMOR, 28)
        for _, salvager in ipairs({ false, true }) do
            local o2 = { band = o.band, results = o.results }
            local list = Model.Results(o2, price, { cut = 0.05, salvager = salvager, salvagerChance = 0.5 })
            assert.is_true(math.abs(sum(list) - 1) < 1e-9)
            for i, x in ipairs(list) do
                assert.are.equal(math.floor(x.qty), x.qty)                       -- never a fraction of a unit
                assert.is_true(x.qty >= 1)
                if i > 1 then assert.is_true(list[i - 1].value <= x.value) end
            end
            -- Dust 1-2, essence 1-2 and one shard; with the Salvager dust and essence go up to 3.
            assert.are.equal(salvager and 7 or 5, #list)
        end
        -- Blended with your results, the same holds, and what you got is marked seen.
        local seen = { n = 10, mats = { [11083] = { hits = 8, qty = { [1] = 3, [3] = 5 } }, [11082] = { hits = 2, qty = { [2] = 2 } } } }
        local b = Model.Blended(o, seen, { salvager = true, salvagerChance = 0.5 })
        local list = Model.Results(b, price, opts)
        assert.is_true(math.abs(sum(list) - 1) < 1e-9)
        local marks = {}
        for _, x in ipairs(list) do marks[x.id .. "x" .. x.qty] = x.seen end
        assert.is_true(marks["11083x3"])
        assert.is_true(marks["11082x2"])
        assert.is_false(marks["11083x2"])
    end)

    it("takes the 10th and the 90th percentile as real outcomes: two outcomes half and half are low and high", function()
        local o = { band = 99, results = { { id = 11083, chance = 1, min = 1, max = 2, bonus = false } } }
        local sp = Model.Spread(o, price, opts)
        assert.are.same({ 1, 2 }, { sp.low.qty, sp.high.qty })
        assert.are.equal(math.floor(400 * 0.95 + 0.5), sp.low.value)
        assert.are.equal(math.floor(800 * 0.95 + 0.5), sp.high.value)
        -- The average is the sum of chance × value: what Model.Value counts, to the copper.
        assert.is_true(math.abs(sp.average - Model.Value(o, price, opts).net) <= 1)
        -- One outcome: both ends are it.
        local one = Model.Spread({ band = 99, results = { { id = 11084, chance = 1, min = 1, max = 1, bonus = false } } },
            price, opts)
        assert.are.equal(one.low, one.high)
        -- Uncommon Armor 26-30 without the Salvager: dust 75% (1 or 2), essence 20%, shard 5%.
        local u = Model.Spread(Model.Outcomes(2, Data.CLASS_ARMOR, 28), price, opts)
        assert.are.same({ 11083, 1 }, { u.low.id, u.low.qty })                -- 37.5% get 1 dust: the pessimistic one
        assert.are.same({ 11082, 2 }, { u.high.id, u.high.qty })              -- 15% get 2 essences or a shard
        -- The pessimistic one: at most 10% of the chance below it; the optimistic one: at most 10% above it.
        local below, above = 0, 0
        for _, x in ipairs(u.list) do
            if x.value < u.low.value then below = below + x.chance end
            if x.value > u.high.value then above = above + x.chance end
        end
        assert.is_true(below <= 0.1 + 1e-9 and above <= 0.1 + 1e-9)
    end)

    it("marks Epic 56+ as inferred, its optimistic outcome not proven until you got it, and observed from 50 of yours", function()
        local o = Model.Outcomes(4, Data.CLASS_ARMOR, 61)
        assert.is_true(o.inferred)
        assert.is_true(Model.Outcomes(4, Data.CLASS_ARMOR, 58).inferred)
        assert.is_nil(Model.Outcomes(4, Data.CLASS_ARMOR, 50).inferred)
        assert.are.equal("documented", Model.Evidence(Model.Outcomes(2, Data.CLASS_ARMOR, 28)))
        -- The leggings: one disenchant, 1 Nexus Crystal.
        local one = Model.Blended(o, { n = 1, mats = { [20725] = { hits = 1, qty = { [1] = 1 } } } }, {})
        local sp = Model.Spread(one, price, opts)
        assert.are.equal("inferred", sp.evidence)
        assert.are.same({ 1, 2 }, { sp.low.qty, sp.high.qty })
        assert.is_true(sp.low.seen)
        assert.is_true(sp.unproven)                                          -- 2 Nexus Crystals: never seen
        local both = Model.Blended(o, { n = 2, mats = { [20725] = { hits = 2, qty = { [1] = 1, [2] = 1 } } } }, {})
        assert.is_false(Model.Spread(both, price, opts).unproven)
        local many = Model.Blended(o, { n = 50, mats = { [20725] = { hits = 50, qty = { [1] = 50 } } } }, {})
        assert.are.equal("observed", Model.Evidence(many))
        assert.is_false(Model.Spread(many, price, opts).unproven)
    end)

    it("writes money short for a range: gold and silver from 1 gold up, with the sign", function()
        local U = ns.Util
        assert.are.equal("+25g 49s", U.MoneyShort(254890, false, true))
        assert.are.equal("-4g 20s", U.MoneyShort(-42013, false, true))
        assert.are.equal("59s 78c", U.MoneyShort(5978))
        assert.are.equal("-3c", U.MoneyShort(-3, false, true))
    end)
end)

describe("The range in the Gear list, the inferred buy limit and the highlight (SDD 116)", function()
    local env, ns
    local LEGS, BOOTS, CHEAP = 6031, 6032, 6033
    local function link(id, name, q, ilvl)
        return "|cff" .. (q == 4 and "a335ee" or "1eff00") .. "|Hitem:" .. id .. "::::::::" .. ilvl .. ":::::|h[" .. name
            .. "]|h|r"
    end
    local function tip() return table.concat(_G.GameTooltip.lines or {}, "\n") end
    local function rowFrames()
        local out = {}
        for _, fr in ipairs(env.frames) do if rawget(fr, "buy") and fr:IsShown() then out[#out + 1] = fr end end
        return out
    end
    local function rowOf(id)
        for _, r in ipairs(rowFrames()) do if r.item and r.item.itemID == id then return r end end
    end
    local function scan()
        ns.Scanner.Scan(true)
        for _ = 1, 300 do
            if ns.Scanner.state == "browsing" then wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end
            local task = ns.Queue.current
            if task and task.itemKey then wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", task.itemKey) end
            wow.tick(ns, 0.2)
            if ns.Scanner.state == "idle" and not ns.Queue.current then break end
        end
        ns.UI.Refresh()
    end

    setup(function()
        env = wow.install()
        env.items[LEGS] = { name = "Ironfeather Leggings", quality = 4, ilvl = 61, classID = 4 }
        env.items[BOOTS] = { name = "Alpha Boots", quality = 2, ilvl = 28, classID = 4 }
        env.items[CHEAP] = { name = "Cheap Boots", quality = 2, ilvl = 28, classID = 4 }
        _G.GameTooltip.SetText = function(self, t) rawset(self, "lines", { t }) end
        _G.GameTooltip.SetHyperlink = function(self, l) rawset(self, "lines", { l }) end
        _G.GameTooltip.AddLine = function(self, t) table.insert(self.lines, t) end
        _G.GameTooltip.AddDoubleLine = function(self, a, b) table.insert(self.lines, a .. " = " .. b) end
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        for _, m in ipairs(ns.Data.MATERIALS) do
            local p = m.id == 20725 and 600000 or 1000
            ns.db.prices[m.id] = { p = p, t = env.clock }
            ns.History.Add(ns.db.history, m.id, env.clock - 3600, p, p, 10)
            ns.History.Add(ns.db.history, m.id, env.clock - 60, p, p, 10)
        end
        local s = ns.db.settings
        s.minProfit, s.minReturn, s.gearClasses, s.priceRescan, s.salvager = 0, 0, "armor", 0, "off"
        s.qualities = { [2] = true, [3] = false, [4] = true }
        s.dealSort = "profit"
        env.ah.browse = {
            { itemKey = { itemID = LEGS, itemLevel = 61, itemSuffix = 0 }, minPrice = 500000 },
            { itemKey = { itemID = BOOTS, itemLevel = 28, itemSuffix = 0 }, minPrice = 1000 },
            { itemKey = { itemID = CHEAP, itemLevel = 28, itemSuffix = 0 }, minPrice = 100 },
        }
        env.ah.itemResults[LEGS] = { { auctionID = 701, buyoutAmount = 500000, itemLink = link(LEGS, "Ironfeather Leggings", 4, 61) } }
        env.ah.itemResults[BOOTS] = { { auctionID = 801, buyoutAmount = 1000, itemLink = link(BOOTS, "Alpha Boots", 2, 28) } }
        env.ah.itemResults[CHEAP] = { { auctionID = 901, buyoutAmount = 100, itemLink = link(CHEAP, "Cheap Boots", 2, 28) },
            { auctionID = 902, buyoutAmount = 1200, itemLink = link(CHEAP, "Cheap Boots", 2, 28) } }
        ns.UI.Show()
        ns.UI.view = "deals"
        scan()
    end)

    local function deal(id)
        for _, d in ipairs(ns.Scanner.deals) do if d.auctionID == id then return d end end
    end

    it("limits an inferred band by its pessimistic value: no unproven upside in the limit", function()
        local row
        for _, r in ipairs(ns.Limits(true)) do if r.quality == 4 and r.up == 999 then row = r end end
        local nexus = math.floor(600000 * 0.95 - (ns.DepositPerUnit(20725)) + 0.5)
        assert.is_true(row.armor.fromLow)
        assert.are.equal(nexus, row.armor.recommended)                         -- 1 Nexus Crystal, not the 1.5 average
        assert.is_true(row.armor.value > nexus)
        -- A documented band keeps its average.
        for _, r in ipairs(ns.Limits(true)) do if r.quality == 2 and r.up == 30 then row = r end end
        assert.is_false(row.armor.fromLow)
        assert.are.equal(row.armor.value, row.armor.recommended)
        -- The leggings at 50g are under the 57g limit: a deal, shown with its range.
        local d = deal(701)
        assert.is_table(d)
        assert.are.equal(nexus, d.low)
        assert.are.equal(2 * nexus, d.high)
        assert.is_true(d.spread.unproven)
    end)

    it("shows one profit cell: pessimistic - average - optimistic, a ? on an unproven optimistic, sorted by the average",
        function()
        assert.are.equal("Profit: low - avg - high", ns.UI.headers[5]:GetText():gsub(" |T.*$", ""))
        local d = deal(701)
        local r = rowOf(LEGS)
        local cell = r.item.cells[5]
        local want = ns.SignedShort(d.low - d.buyout) .. "|cff808080 - |r" .. ns.SignedShort(d.profit)
            .. "|cff808080 - |r" .. ns.SignedShort(d.high - d.buyout) .. "|cff808080?|r"
        assert.are.equal(want, cell)
        -- The order: by the average profit.
        for i = 2, #ns.Scanner.deals do assert.is_true(ns.Scanner.deals[i - 1].profit >= ns.Scanner.deals[i].profit) end
        -- Hovering the cell: every outcome, the range and the labelled averages; elsewhere the item's tooltip.
        r.rangeArea.scripts.OnEnter(r.rangeArea)
        local t = tip()
        r.rangeArea.scripts.OnLeave(r.rangeArea)
        assert.is_truthy(t:find("Chance   What one disenchant gives = Value   Profit", 1, true))
        assert.is_truthy(t:find(" 1 Nexus Crystal = ", 1, true))
        assert.is_truthy(t:find(" 2 Nexus Crystal = ", 1, true))
        assert.is_truthy(t:find("Optimistic (1 in 10 gets this or more) = 2 Nexus Crystal", 1, true))
        assert.is_truthy(t:find("not proven on Forever", 1, true))
        assert.is_truthy(t:find("Average value (over many pieces) = ", 1, true))
        assert.is_truthy(t:find("Rule: inferred", 1, true))
        r.scripts.OnEnter(r)
        assert.is_truthy(_G.GameTooltip.lines[1]:find("Hitem:" .. LEGS, 1, true))
        r.scripts.OnLeave(r)
    end)

    it("highlights a return of 50% or more: an orange row, ! after the buyout with its help, on its heading too", function()
        local cheap = deal(901)                                               -- 1s for about 1s 40c: a high return
        assert.is_true(ns.UI.HighReturn(cheap))
        assert.is_false(ns.UI.HighReturn(deal(801)))
        assert.are.equal(50, ns.db.settings.highlightReturn)
        assert.are.equal(0.5, ns.HIGH_RETURN)
        local head = rowOf(CHEAP)
        assert.is_true(head.item.group ~= nil and head.item.high)            -- the heading: one auction under it has it
        assert.is_true(head.tint:IsShown())
        assert.is_truthy(head.item.cells[4]:find("|cffff8040!|r", 1, true))
        head.buyoutArea.scripts.OnEnter(head.buyoutArea)
        assert.is_truthy(tip():find("Unusually high return (50% or more)", 1, true))
        head.buyoutArea.scripts.OnLeave(head.buyoutArea)
        local boots = rowOf(BOOTS)
        assert.is_false(boots.tint:IsShown())
        assert.is_nil(boots.item.cells[4]:find("!", 1, true))
        -- Buy Top says it too when its deal has it.
        ns.UI.topItem.scripts.OnEnter(ns.UI.topItem)
        local top = ns.UI.TopDeal()
        assert.are.equal(ns.UI.HighReturn(top), tip():find("Unusually high return", 1, true) ~= nil)
        ns.UI.topItem.scripts.OnLeave(ns.UI.topItem)
        -- 0 = off.
        ns.db.settings.highlightReturn = 0
        ns.UI.Refresh()
        assert.is_false(ns.UI.HighReturn(cheap))
        assert.is_false(rowOf(CHEAP).tint:IsShown())
        ns.db.settings.highlightReturn = 50
        ns.UI.Refresh()
    end)

    it("keeps the purchase's range for the Current batch", function()
        local d = deal(701)
        ns.Ledger.AuctionPurchase(ns.db.ledger, LEGS, d.buyout, d.value, env.clock, d.link,
            { q = 4, cls = 4, band = 999, ilvl = 61, lo = d.low, hi = d.high })
        local p = ns.db.ledger.purchases[LEGS][1]
        local row = ns.LedgerWindow.BatchWaitingRow({ itemID = LEGS, link = d.link, each = p.each, ev = p.ev, j = p.j })
        assert.are.equal(ns.RangeText(d.low - d.buyout, d.value - d.buyout, d.high - d.buyout), row.cells[5])
    end)
end)

describe("Every average says it is one (SDD 116, UI.md Words 2)", function()
    it("has no visible text with Expected value, Expected profit, Rate used, Quantity used or Result quantity", function()
        local BAD = { "Expected", "[Ee]xpected value", "[Ee]xpected profit", "Rate used", "Quantity used",
            "Result quantity" }
        local found = {}
        for line in io.lines("Salvager/Salvager.toc") do
            if line:match("%.lua$") then
                local n = 0
                for text in io.lines("Salvager/" .. line) do
                    n = n + 1
                    local code = text:match("^%s*%-%-") and "" or text:gsub("%s%-%-%s.*$", "")
                    for lit in code:gmatch('"([^"]*)"') do
                        for _, bad in ipairs(BAD) do
                            if lit:find(bad) and not lit:lower():find("avg") and not lit:lower():find("average") then
                                found[#found + 1] = line .. ":" .. n .. ": " .. lit
                            end
                        end
                    end
                end
            end
        end
        assert.are.same({}, found)
    end)
end)

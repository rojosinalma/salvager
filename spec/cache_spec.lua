-- The caches of 0.4.0's optimizations: the forecast (sell ratios, results, the blended outcomes) is kept until the
-- ledger, the prices or the settings change, and the deals are checked against one table of limits.
local wow = require("spec.wow")

describe("The forecast cache", function()
    local env, ns
    local DUST = 11083

    local function disenchant(t)
        table.insert(ns.db.ledger.disenchants, { itemID = 7048, quality = 2, classID = 4, ilvl = 29, band = 30, t = t,
            got = { [DUST] = 2 }, vals = { [DUST] = 800 }, value = 800, cost = 700, costKnown = true, salvager = false })
    end

    setup(function()
        env = wow.install()
        env.items[DUST] = { name = "Soul Dust", quality = 1, ilvl = 1, classID = 7 }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        for id in pairs(ns.Data.MATERIAL_BY_ID) do ns.db.prices[id] = { p = 1000, t = time() } end
    end)

    it("keeps the blended outcomes until the ledger changes, then counts the new disenchant", function()
        local before = ns.Outcomes(2, 4, 29, false)
        assert.are.equal(0, before.count)
        disenchant(time())
        assert.are.equal(before, ns.Outcomes(2, 4, 29, false))   -- the same table: no change event yet
        wow.fire(ns, "SALVAGER_LEDGER")
        local after = ns.Outcomes(2, 4, 29, false)
        assert.are_not.equal(before, after)
        assert.are.equal(1, after.count)
        assert.are.equal(after, ns.Outcomes(2, 4, 29, false))    -- and kept again
    end)

    it("is made again on a settings change and on new prices, not on other events", function()
        local o = ns.Outcomes(2, 4, 29, false)
        wow.fire(ns, "SALVAGER_DEALS")
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        assert.are.equal(o, ns.Outcomes(2, 4, 29, false))
        wow.fire(ns, "SALVAGER_SETTINGS")
        local o2 = ns.Outcomes(2, 4, 29, false)
        assert.are_not.equal(o, o2)
        wow.fire(ns, "SALVAGER_PRICES_DONE")
        assert.are_not.equal(o2, ns.Outcomes(2, 4, 29, false))
    end)

    it("leaves out the deals over their new buy limit at a settings change, the others stay", function()
        local cheap = { auctionID = 1, itemID = 7048, quality = 2, classID = 4, ilvl = 29, buyout = 1, profit = 1, value = 2 }
        local dear = { auctionID = 2, itemID = 7048, quality = 2, classID = 4, ilvl = 29, buyout = 99999999, profit = 1,
            value = 2 }
        ns.Scanner.deals = { cheap, dear }
        wow.fire(ns, "SALVAGER_SETTINGS")
        assert.are.same({ cheap }, ns.Scanner.deals)
    end)
end)

describe("The money text memo", function()
    it("gives the same text as a fresh copy, in every form, past its bound", function()
        local a, b = {}, {}
        assert(loadfile("Salvager/Util.lua"))("Salvager", a)
        for c = -6000, 6000, 3 do
            for _, icons in ipairs({ false, true }) do
                for _, aligned in ipairs({ false, true }) do
                    local first = a.Util.FormatMoney(c, icons, aligned)
                    assert.are.equal(first, a.Util.FormatMoney(c, icons, aligned))
                    if c % 999 == 0 then
                        assert(loadfile("Salvager/Util.lua"))("Salvager", b)
                        assert.are.equal(b.Util.FormatMoney(c, icons, aligned), first)
                    end
                end
            end
        end
        assert.are.equal("1g 05s 00c", a.Util.FormatMoney(10500, false, true))
        assert.are.equal("1g 5s", a.Util.FormatMoney(10500))
    end)
end)

describe("The Ledger's summary totals", function()
    it("count what Ledger.History counts, without its order", function()
        local ns = require("spec.helper").load()
        local state = ns.Ledger.Init({})
        state.purchases[7048] = { { each = 1200, t = 10 }, { each = 900, t = 20 } }
        state.disenchants = { { itemID = 7048, cost = 1100, costKnown = true, value = 1500, t = 5, got = { [11083] = 2 },
            quality = 2, classID = 4, band = 30 }, { itemID = 9, value = 300, t = 6, got = { [11083] = 1 } } }
        local function sums(list)
            local paid, got, done, n = 0, 0, 0, 0
            for _, e in ipairs(list) do
                paid, got, n = paid + (e.paid or 0), got + (e.got or 0), n + 1
                if e.done then done = done + 1 end
            end
            return { paid, got, done, n }
        end
        assert.are.same(sums(ns.Ledger.History(state)), sums(ns.Ledger.HistoryTotals(state)))
        assert.are.same({ 3200, 1800, 2, 4 }, sums(ns.Ledger.HistoryTotals(state)))
    end)
end)

-- One material order everywhere, and the search boxes of the Reports and Market windows (0.3.145, the user,
-- 2026-11-27; UI.md Controls 6, SDD 111).
local wow = require("spec.wow")

describe("One material order, and a search on the Reports and Market filter rows", function()
    local env, ns
    -- Three materials, out of the materials' order on purpose (Illusion Dust, then Strange Dust, then Soul Dust).
    local ILLUSION, STRANGE, SOUL = 16204, 10940, 11083
    local MATS = { ILLUSION, STRANGE, SOUL }

    local function typeIn(box, text)
        box:SetText(text)
        box.scripts.OnTextChanged(box)
    end
    local function firstCells(rows)
        local out = {}
        for _, r in ipairs(rows) do out[#out + 1] = r.cells[1] end
        return out
    end
    local function idsOf(rows)
        local out = {}
        for _, r in ipairs(rows) do if r.itemID or r.key then out[#out + 1] = r.itemID or r.key end end
        return out
    end

    setup(function()
        env = wow.install()
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        for i, id in ipairs(MATS) do
            env.items[id] = { name = ns.Data.MATERIAL_BY_ID[id].name, quality = 1, ilvl = 1, classID = 7 }
            env.bags[id] = 10 * i
            ns.db.prices[id] = { p = 100 * (4 - i), t = env.clock }
            -- The biggest rise first would be Illusion, Strange, Soul: not the materials' order.
            ns.History.Add(ns.db.history, id, env.clock - 3600, 100, 100, 10)
            ns.History.Add(ns.db.history, id, env.clock - 60, 100 + 100 * (4 - i), 100, 10)
            local C = ns.Competition
            C.Observe(ns.db.competition, id, { { each = 50, qty = 5 * i, ownQty = 0, owners = { "Seller" .. i }, total = 1 } },
                { { each = 90, qty = 5 } }, env.clock - 120)
        end
    end)

    it("sorts every material list the way the Materials window does", function()
        assert.are.same({ STRANGE, SOUL, ILLUSION }, ns.Data.SortMaterials({ ILLUSION, STRANGE, SOUL }))
        assert.is_true(ns.Data.MaterialRank(STRANGE) < ns.Data.MaterialRank(SOUL))
        assert.are.equal(#ns.Data.MATERIALS + 1, ns.Data.MaterialRank(12345))
        -- The Materials window's own order: Data.MATERIALS.
        local window = {}
        for _, r in ipairs(ns.Materials.Rows()) do if r.itemID and env.bags[r.itemID] then window[#window + 1] = r.itemID end end
        assert.are.same({ STRANGE, SOUL, ILLUSION }, window)
        -- Market: Materials, Time of day (the materials' order with no click), Essences.
        ns.Market.Toggle()
        for _, view in ipairs({ "material", "hour" }) do
            ns.Market.view = view
            assert.are.same(window, idsOf(ns.Market.Rows()), view)
        end
        -- Reports: Materials, Competition per material.
        ns.Reports.Show()
        ns.Reports.view = "materials"
        local rows = ns.Reports.MaterialRows()
        table.remove(rows)   -- (the totals)
        assert.are.same(window, idsOf(rows))
        ns.Reports.range = "all"
        local comp = {}
        for _, r in ipairs(ns.Reports.CompetitionMaterialRows()) do comp[#comp + 1] = r.itemID end
        assert.are.same(window, comp)
    end)

    it("filters the Reports rows by name as you type, any case, per view, and clears in one click", function()
        local box = ns.Reports.searchBox
        ns.Reports.view = "materials"
        ns.Reports.Refresh()
        assert.is_true(box:IsShown())
        typeIn(box, "sOuL")
        local rows = ns.Reports.MaterialRows()
        assert.are.same({ "Soul Dust", "Total" }, firstCells(rows))
        -- A text that matches nothing says so.
        typeIn(box, "zzz")
        assert.are.equal("|cff808080" .. ns.Widgets.NoMatch("zzz") .. "|r", ns.Reports.MaterialRows()[1].cells[1])
        assert.truthy(ns.Widgets.NoMatch("zzz"):find("Nothing matches \"zzz\"", 1, true))
        -- Each view keeps its own: the Competition view's is empty, the Materials view's comes back.
        ns.Reports.view = "competition"
        ns.Reports.Refresh()
        assert.are.equal("", box:GetText())
        typeIn(box, "seller2")
        local names = {}
        for _, r in ipairs(ns.Reports.CompetitorRows()) do if r.group then names[#names + 1] = r.cells[1] end end
        assert.are.same({ "Seller2" }, names)
        ns.Reports.view = "materials"
        ns.Reports.Refresh()
        assert.are.equal("zzz", box:GetText())
        assert.are.equal("zzz", ns.db.windows.reports.search.materials)   -- (remembered with the window)
        -- The X clears it, and so does Escape.
        assert.is_true(box.clear:IsShown())
        box.clear:Click()
        assert.are.equal("", box:GetText())
        assert.is_false(box.clear:IsShown())
        assert.is_nil(ns.Reports.search.materials)
        assert.are.equal(4, #ns.Reports.MaterialRows())
        ns.Reports.view = "competition"
        ns.Reports.Refresh()
        box.scripts.OnEscapePressed(box)
        assert.are.equal("", box:GetText())
        assert.is_nil(ns.Reports.search.competition)
        -- The Gold statement has no search; All gold changes has one.
        ns.Reports.view, ns.Reports.goldTab = "gold", "statement"
        ns.Reports.Refresh()
        assert.is_false(box:IsShown())
        assert.is_nil(ns.Reports.SearchKey())
        ns.Reports.goldTab = "changes"
        ns.Reports.Refresh()
        assert.is_true(box:IsShown())
    end)

    it("filters the Market rows by name, per view, and leaves the search out of Profit", function()
        local box = ns.Market.searchBox
        ns.Market.view = "material"
        ns.Market.Refresh()
        typeIn(box, "DUST")
        assert.are.equal(3, #ns.Market.Rows())
        typeIn(box, "strange")
        assert.are.same({ STRANGE }, idsOf(ns.Market.Rows()))
        ns.Market.view = "hour"
        ns.Market.Refresh()
        assert.are.equal("", box:GetText())
        assert.are.equal(3, #ns.Market.Rows())
        typeIn(box, "nothing like it")
        assert.truthy(ns.Market.Rows()[1].cells[1]:find("Nothing matches", 1, true))
        ns.Market.view = "profit"
        ns.Market.Refresh()
        assert.is_false(box:IsShown())
        ns.Market.view = "material"
        ns.Market.Refresh()
        assert.are.equal("strange", box:GetText())
        box.scripts.OnEscapePressed(box)
        assert.are.equal(3, #ns.Market.Rows())
    end)
end)

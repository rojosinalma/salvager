-- The ratchet works (SDD 121): a column made wider on purpose is found, `make check`'s step fails on it, and the
-- baseline only moves to better numbers unless a looser one is allowed with a reason.
local wow = require("spec.wow")
local check = require("spec.layoutcheck")
local R = dofile("scripts/ratchet.lua")

local function materials()
    local env = wow.install({ layout = true })
    local ns = wow.loadAddon()
    wow.fire(ns, "ADDON_LOADED", "Salvager")
    wow.fire(ns, "AUCTION_HOUSE_SHOW")
    for _, m in ipairs(ns.Data.MATERIALS) do
        env.items[m.id] = { name = m.name, quality = 1, ilvl = 1, classID = 7 }
        ns.db.prices[m.id] = { p = 509, lo = 509, t = env.clock - 60 }
    end
    ns.db.settings.materialsDataOnly = false
    ns.Materials.PopOut()
    return ns, _G.SalvagerMaterialsFrame
end

local function numbers(ns, win)
    local m = check.measure(win, ns)
    local _, gap = check.badGaps(m)
    return { ["layout-typical"] = { ["materials/-/default"] = { width = math.floor(m.width + 0.5),
        gap = math.floor(gap + 0.5), cut = 0, overlap = 0 } } }
end

describe("The ratchet (scripts/ratchet.lua, SDD 121)", function()
    local base, wider

    it("finds a column made wider on purpose", function()
        local ns, win = materials()
        base = numbers(ns, win)
        assert.are.same({}, (R.compare(base, base)))
        -- The bug the ratchet is for: a column wider than its text (here the third, Age, 40 px too wide).
        local real = ns.Widgets.FitColumns
        ns.Widgets.FitColumns = function(...)
            local need = real(...)
            if need and need[3] then need[3] = need[3] + 40 end
            return need
        end
        ns.Materials.Refresh()
        wider = numbers(ns, win)
        ns.Widgets.FitColumns = real
        local worse = R.compare(base, wider)
        local fields = {}
        for _, w in ipairs(worse) do fields[w[3]] = w[5] - w[4] end
        assert.is_true((fields.width or 0) > 1, R.report(worse, {}))
    end)

    it("fails the check (make check's ratchet step) and says what got worse", function()
        os.execute("mkdir -p .ratchet/test/now")
        R.write(".ratchet/test/base.json", base)
        R.write(".ratchet/test/now/layout-typical.json", wider["layout-typical"])
        local cmd = "RATCHET_BASE=.ratchet/test/base.json RATCHET_DIR=.ratchet/test/now lua scripts/ratchet.lua check"
        local failed = os.execute(cmd .. " > .ratchet/test/out.txt 2>&1")
        assert.are_not.equal(0, failed)
        local f = io.open(".ratchet/test/out.txt")
        local out = f:read("*a")
        f:close()
        assert.is_truthy(out:find("materials/-/default", 1, true), out)
        assert.is_truthy(out:find("width", 1, true), out)
        -- The same numbers again pass.
        R.write(".ratchet/test/now/layout-typical.json", base["layout-typical"])
        assert.are.equal(0, os.execute(cmd .. " > .ratchet/test/out.txt 2>&1"))
    end)

    it("moves the baseline only to better numbers, a looser one only when allowed, with its reason", function()
        local out, changes = R.tighten(base, wider)
        assert.are.same(base["layout-typical"], out["layout-typical"])
        assert.are.same({}, changes)
        local narrower = { ["layout-typical"] = { ["materials/-/default"] = {
            width = base["layout-typical"]["materials/-/default"].width - 5, gap = 0, cut = 0, overlap = 0 } } }
        out = R.tighten(base, narrower)
        assert.are.equal(narrower["layout-typical"]["materials/-/default"].width, out["layout-typical"]["materials/-/default"].width)
        local took
        out, changes, took = R.tighten(base, wider, { "^layout%-typical:materials/" }, "a wider Post button", "2026-11-28")
        assert.is_truthy(changes[1]:find("LOOSER", 1, true))
        assert.are.equal(wider["layout-typical"]["materials/-/default"].width, out["layout-typical"]["materials/-/default"].width)
        assert.is_true(#took > 0)
        assert.is_truthy(out.reasons[#out.reasons]:find("a wider Post button", 1, true))
        -- Timings: 1.5 times the baseline is noise, more is worse; a timing tightens only when 20 % better.
        assert.are.same({}, (R.compare({ perf = { x = 10 } }, { perf = { x = 14.9 } })))
        assert.are.equal(1, #R.compare({ perf = { x = 10 } }, { perf = { x = 15.1 } }))
        assert.are.equal(10, R.tighten({ perf = { x = 10 } }, { perf = { x = 9 } }).perf.x)
        assert.are.equal(7, R.tighten({ perf = { x = 10 } }, { perf = { x = 7 } }).perf.x)
        -- The suite: fewer specs or a luacheck warning is worse.
        assert.are.equal(2, #R.compare({ suite = { all = { specs = 300, luacheck = 0 } } },
            { suite = { all = { specs = 299, luacheck = 1 } } }))
    end)
end)

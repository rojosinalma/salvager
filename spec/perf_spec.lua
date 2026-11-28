-- How long the windows take to draw, on synthetic data at the code's caps (ten times a heavy player's ledger: 5000
-- purchases, disenchants and sales; SDD 121): each window and view's refresh (best of 3, os.clock), one tick of the
-- Ledger's countdowns, and the gear scan's judge per listing. The numbers go to .ratchet/perf.json; the ratchet allows
-- 1.5 times the baseline (noise), never more. Synthetic, so no player's data is in the repo.
local wow = require("spec.wow")
local ratchet = require("spec.ratchetout")

local N = 5000
local GEAR = 60

local function seed(env, ns)
    local L = ns.db.ledger
    local mats = ns.Data.MATERIALS
    for _, m in ipairs(mats) do
        env.items[m.id] = { name = m.name, quality = 1, ilvl = 1, classID = 7 }
        local p = 100 + (m.id % 97) * 53
        ns.db.prices[m.id] = { p = p, lo = p, t = env.clock - 600 }
        ns.History.Add(ns.db.history, m.id, env.clock - 86400, p, p, 20)
    end
    local gear = {}
    for i = 1, GEAR do
        local id = 8000 + i
        env.items[id] = { name = "Gear piece " .. i, quality = 2 + i % 3, ilvl = 10 + (i * 7) % 55, req = 5,
            classID = i % 2 == 0 and 2 or 4 }
        gear[i] = id
    end
    local function link(id) return "|cff1eff00|Hitem:" .. id .. "::::::::60:::::|h[" .. env.items[id].name .. "]|h|r" end
    for i = 1, N do
        local id = gear[i % GEAR + 1]
        local it = env.items[id]
        local t = env.clock - (N - i) * 120
        local price = 500 + (i % 50) * 137
        ns.Ledger.AddPurchase(L, id, 1, price, math.floor(price * 1.3), t, link(id))
        local purchase = ns.Ledger.TakePurchase and ns.Ledger.TakePurchase(L, id, link(id), t + 60) or nil
        local o = ns.Model.Outcomes(it.quality, it.classID, it.ilvl)
        local m = mats[(i % #mats) + 1]
        ns.Ledger.Disenchant(L, { t = t + 60, link = link(id), itemID = id, ilvl = it.ilvl, quality = it.quality,
            classID = it.classID, band = o and o.band, salvager = i % 4 == 0, got = { [m.id] = 1 + i % 3 },
            planned = price }, purchase, ns.PriceOf, 0.05)
        ns.Ledger.SaleSeen(L, m.id, 1, ns.db.prices[m.id].p, 0.05, t + 3600)
        ns.Ledger.SalePaid(L, m.id, 1, ns.db.prices[m.id].p, math.floor(ns.db.prices[m.id].p * 0.05), t + 7200)
    end
    return gear
end

describe("Draw times at ten times a heavy ledger (the ratchet, SDD 121)", function()
    it("measures every window and view, the countdown tick and the scan's judge", function()
        local env = wow.install()
        local ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        local gear = seed(env, ns)
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        wow.tick(ns, 0.5)
        local clock = os.clock
        local out = {}
        local function measure(label, fn, reps)
            local best = math.huge
            for _ = 1, reps or 3 do
                local t0 = clock()
                fn()
                best = math.min(best, (clock() - t0) * 1000)
            end
            out[label] = math.floor(best * 1000 + 0.5) / 1000   -- ms
        end
        local function kids(x, kind, acc)
            acc = acc or {}
            for _, c in ipairs(x._children) do
                if rawget(c, "uiKind") == kind then acc[#acc + 1] = c end
                kids(c, kind, acc)
            end
            return acc
        end
        local function walk(win, name)
            local tabs = kids(win, "tab")
            if #tabs == 0 then return end
            for _, t in ipairs(tabs) do
                if t:IsVisible() then
                    measure(name .. "/" .. tostring(t.text), function() t:Click() end)
                    for _, s in ipairs(kids(win, "subtab")) do
                        if s:IsVisible() then
                            local sub = tostring(s.text):gsub(" %(%d+%)$", "")
                            measure(name .. "/" .. tostring(t.text) .. "/" .. sub, function() s:Click() end)
                        end
                    end
                end
            end
        end
        ns.UI.Show()
        walk(_G.SalvagerFrame, "main")
        ns.LedgerWindow.Show()
        walk(_G.SalvagerLedgerFrame, "ledger")
        ns.Reports.Show()
        ns.Reports.range = "all"
        walk(_G.SalvagerReportsFrame, "reports")
        if not (_G.SalvagerMarketFrame and _G.SalvagerMarketFrame:IsShown()) then ns.Market.Toggle() end
        walk(_G.SalvagerMarketFrame, "market")
        ns.Materials.PopOut()
        measure("materials", function() ns.Materials.Refresh() end)
        measure("disenchant", function() ns.DisenchantPanel.Show() ns.DisenchantPanel.Refresh() end)
        ns.LimitsWindow.Show()
        measure("limits", function() ns.LimitsWindow.Refresh() end)
        ns.LogWindow.Show()
        measure("log", function() ns.LogWindow.Refresh() end)
        -- The Ledger's countdowns: one tick at the second (their cells only).
        ns.LedgerWindow.Show()
        ns.LedgerWindow.tabs.sales:Click()
        measure("tick: Ledger Sales countdown", function()
            env.now = env.now + 1.1
            ns.eventFrame.scripts.OnUpdate(ns.eventFrame, 0.1)
        end, 5)
        -- The gear scan's judge: one browse page, per listing (us).
        local rows = {}
        for i = 1, 2000 do
            local id = gear[i % GEAR + 1]
            rows[i] = { itemKey = { itemID = id, itemLevel = env.items[id].ilvl, itemSuffix = 0 },
                minPrice = (i % 3 == 0) and 50 or 99999999, totalQuantity = 1 }
        end
        env.ah.browse = rows
        ns.Scanner.Scan()
        local t0 = clock()
        wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
        out["judge per listing (us)"] = math.floor((clock() - t0) * 1e6 / #rows * 1000 + 0.5) / 1000
        ratchet.write("perf", out)
        local n = 0
        for _ in pairs(out) do n = n + 1 end
        assert.is_true(n > 20, n .. " timings")
        for _, m in ipairs(env.chat) do assert.is_nil(m:lower():find("error", 1, true), m) end
    end)
end)

-- Windows and columns as tight as their content (UI.md Tables 2, SDD 120), measured on what the stand-in draws with
-- TYPICAL data, built from the shapes of the player's own (material prices of a real auction house, gear names and
-- counts of a real ledger), not extremes: at the default and the smallest size of every window and view,
--   1. no window is wider than its widest row of content needs + 8 px (a table, a row of controls, a heading);
--   2. the texts of two columns next to each other are the normal gap apart (16 px, +- 2; the first one may be wider
--      where another row makes the window wider);
--   3. no text is cut, nothing overlaps (spec/layoutcheck.lua, fit_spec's rules);
--   4. the same with no data at all (an empty table is as wide as its titles, or its note);
--   5. a window shrinks when its table empties, and stays put over refreshes and a round of its tabs.
-- The numbers go to .ratchet/layout.json for the ratchet (scripts/ratchet.py, SDD 121).
local wow = require("spec.wow")
local check = require("spec.layoutcheck")
local ratchet = require("spec.ratchetout")

local WINDOWS = { "SalvagerFrame", "SalvagerLedgerFrame", "SalvagerOddsFrame", "SalvagerMaterialsFrame",
    "SalvagerMarketFrame", "SalvagerReportsFrame", "SalvagerLimitsFrame", "SalvagerPostFrame", "SalvagerGearFrame",
    "SalvagerBreakdownFrame", "SalvagerStandFrame", "SalvagerDisenchantFrame" }
local SHORT = { SalvagerFrame = "main", SalvagerLedgerFrame = "ledger", SalvagerOddsFrame = "odds",
    SalvagerMaterialsFrame = "materials", SalvagerMarketFrame = "market", SalvagerReportsFrame = "reports",
    SalvagerLimitsFrame = "limits", SalvagerPostFrame = "post", SalvagerGearFrame = "gear",
    SalvagerBreakdownFrame = "breakdown", SalvagerStandFrame = "stand", SalvagerDisenchantFrame = "disenchant" }

-- The shapes of a real ledger (2026-11-27): the gear bought most, its material prices (copper a unit), a few gold.
local NAMES = { "Azure Silk Hood", "Hillman's Shoulders", "Hillman's Leather Gloves", "Hillman's Cloak",
    "Embossed Leather Gloves", "Green Iron Bracers", "Silvered Bronze Boots", "Guardian Gloves", "Dokebi Cape",
    "Sunscale Wristguards", "Double-Stitched Woolen Shoulders", "Ironfeather Leggings" }
local PRICES = { [10940] = 124, [11134] = 739, [16203] = 33515, [11135] = 2298, [11174] = 4484, [16204] = 1945,
    [11082] = 1718, [11137] = 700, [11083] = 509, [10998] = 589, [20725] = 629458, [11138] = 1001, [11084] = 4999,
    [11139] = 3899, [11178] = 18490, [10938] = 182, [14344] = 34510, [14343] = 8554, [11177] = 8587, [10939] = 445,
    [10978] = 523, [11175] = 13697, [16202] = 11750, [11176] = 1698 }
local BUYOUTS = { 1199, 1650, 2400, 980, 3100, 5200, 7400, 12000, 18500, 26000, 41000, 639967 }

local function seed(env, ns)
    local gear = {}
    for i, n in ipairs(NAMES) do
        local id = 7000 + i
        local quality = i <= 10 and 2 or (i == 11 and 3 or 4)
        env.items[id] = { name = n, quality = quality, ilvl = 18 + i * 3, req = 15 + i * 3, classID = i % 3 == 0 and 2 or 4 }
        env.bags[id] = 1
        gear[#gear + 1] = id
    end
    local function link(id) return "|cff1eff00|Hitem:" .. id .. "::::::::60:::::|h[" .. env.items[id].name .. "]|h|r" end
    for _, m in ipairs(ns.Data.MATERIALS) do
        local p = PRICES[m.id] or 900
        env.items[m.id] = { name = m.name, quality = 1, ilvl = 1, classID = 7 }
        ns.db.prices[m.id] = { p = p, lo = p, t = env.clock - 300 }
        ns.History.Add(ns.db.history, m.id, env.clock - 86400, math.floor(p * 1.08), p, 20)
        ns.History.Add(ns.db.history, m.id, env.clock - 300, p, p, 20)
        env.ah.commodities[m.id] = { { unitPrice = p, quantity = 20, numOwnerItems = 0 } }
        env.bags[m.id] = 1 + (m.id % 7) * 3
    end
    env.bagSize = { [0] = 16, [1] = 14, [2] = 14, [3] = 14, [4] = 14 }
    env.bagFree = { [0] = 2, [1] = 3, [2] = 0, [3] = 1, [4] = 4 }
    local slots = {}
    for i, m in ipairs(ns.Data.MATERIALS) do slots[i] = m.id end
    env.bagSlots = slots
    env.bagItems = {}
    for i, id in ipairs(gear) do if i <= 5 then env.bagItems["4:" .. (8 + i)] = id end end
    env.money = 127940   -- 12g 79s 40c
    local s = ns.db.settings
    s.minProfit, s.minReturn, s.priceRescan = 0, 0, 0
    s.qualities = { [2] = true, [3] = true, [4] = true }
    -- A gear scan: one or two auctions of each piece.
    env.ah.browse = {}
    for i, id in ipairs(gear) do
        env.ah.browse[i] = { itemKey = { itemID = id, itemLevel = env.items[id].ilvl, itemSuffix = 0 }, minPrice = BUYOUTS[i] }
        env.ah.itemResults[id] = {}
        for a = 1, 1 + i % 2 do
            env.ah.itemResults[id][a] = { auctionID = id * 10 + a, buyoutAmount = BUYOUTS[i] + a * 37, itemLink = link(id),
                containsOwnerItem = false }
        end
    end
    ns.UI.Show()
    ns.Scanner.Scan(true)
    for _ = 1, 400 do
        if ns.Scanner.state == "browsing" then wow.fire(ns, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end
        local task = ns.Queue.current
        if task and task.itemKey then wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", task.itemKey) end
        if task and task.commodity then wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", task.commodity) end
        wow.tick(ns, 0.2)
        if ns.Scanner.state == "idle" and not ns.Queue.current then break end
    end
    local L = ns.db.ledger
    for i, id in ipairs(gear) do
        ns.Ledger.AuctionPurchase(L, id, BUYOUTS[i], math.floor(BUYOUTS[i] * 1.3), env.clock - i * 3600, link(id))
        ns.Ledger.AddPurchase(L, id, 1 + i % 3, BUYOUTS[i] * (1 + i % 3), math.floor(BUYOUTS[i] * 1.3) * (1 + i % 3),
            env.clock - i * 7200, link(id))
    end
    for i, m in ipairs(ns.Data.MATERIALS) do
        if i <= 12 then
            env.bagLinks = { ["0:1"] = link(gear[(i % #gear) + 1]) }
            wow.fire(ns, "UNIT_SPELLCAST_SENT", "player", nil, "cast-guid", 13262)
            wow.fire(ns, "ITEM_LOCK_CHANGED", 0, 1)
            env.loot = { { id = m.id, qty = 1 + i % 3 } }
            wow.fire(ns, "LOOT_READY")
        end
    end
    env.ah.owned = {}
    for i, m in ipairs(ns.Data.MATERIALS) do
        if i <= 8 and ns.Post.Send(m.id, 5, PRICES[m.id] or 900, 3) then
            local auction = 9000 + i
            wow.fire(ns, "AUCTION_HOUSE_AUCTION_CREATED", auction)
            env.ah.owned[#env.ah.owned + 1] = { auctionID = auction, itemKey = { itemID = m.id }, quantity = 5,
                status = i % 2, timeLeftSeconds = 86400, buyoutAmount = (PRICES[m.id] or 900) * 5 }
        end
    end
    wow.fire(ns, "OWNED_AUCTIONS_UPDATED")
    wow.fire(ns, "PLAYER_MONEY")
    local C, CS = ns.Competition, ns.db.competition
    for i, m in ipairs(ns.Data.MATERIALS) do
        if i <= 4 then
            local p = PRICES[m.id] or 900
            C.Observe(CS, m.id, { { each = p - 3, qty = 20, ownQty = 0, owners = { "Thrallbank" }, total = 1 } },
                { { each = p, qty = 5 } }, env.clock - 3600)
        end
    end
    for i = 1, 200 do ns.Log("checked item %s: %d auctions", NAMES[i % #NAMES + 1], i % 9) end
    return gear
end

local function sized(f)
    local function fire(x)
        local fn = x.scripts.OnSizeChanged
        if fn then fn(x, x:GetWidth(), x:GetHeight()) end
        for _, c in ipairs(x._children) do fire(c) end
    end
    fire(f)
end

local function tabsOf(win, kind)
    local out = {}
    local function walk(x)
        for _, c in ipairs(x._children) do
            if rawget(c, "uiKind") == kind and c:IsVisible() then out[#out + 1] = c end
            walk(c)
        end
    end
    walk(win)
    return out
end

local function openers(ns)
    local mat = ns.Data.MATERIALS[3].id
    local function answer()
        for _ = 1, 60 do
            wow.tick(ns, 0.2)
            local c = ns.Queue.current
            if c and c.commodity then wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", c.commodity) end
            if c and c.itemKey then wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", c.itemKey) end
        end
    end
    return {
        SalvagerFrame = function() ns.UI.Show() end,
        SalvagerLedgerFrame = function() ns.LedgerWindow.Show() end,
        SalvagerOddsFrame = function() ns.Odds.PopOut() end,
        SalvagerMaterialsFrame = function() ns.Materials.PopOut() end,
        SalvagerMarketFrame = function() if not (_G.SalvagerMarketFrame or {}).shown then ns.Market.Toggle() end end,
        SalvagerReportsFrame = function() ns.Reports.Show() end,
        SalvagerLimitsFrame = function() ns.LimitsWindow.Show() end,
        SalvagerPostFrame = function() ns.Post.Open(mat) answer() end,
        SalvagerBreakdownFrame = function() ns.Breakdown.Open(mat) end,
        SalvagerDisenchantFrame = function() ns.DisenchantPanel.Show() end,
        SalvagerStandFrame = function()
            local row
            for _, r in ipairs(ns.db.listings.rows) do if not r.sold and r.commodity then row = r end end
            if not row then return false end
            ns.Stand.Show(row)
            answer()
        end,
        SalvagerGearFrame = function()
            if #ns.Scanner.deals == 0 then return false end
            ns.GearWindow.Open(ns.Scanner.deals[1])
        end,
    }
end

-- The smallest size (the player drags the corner to it) and the default one (the view's own width).
local function smallest(win)
    local b = rawget(win, "_bounds")
    local w = b and b[1] or rawget(win, "minWidth") or win:GetWidth()
    rawset(win, "userW", w)
    win:SetSize(w, b and b[2] or win:GetHeight())
    sized(win)
end
local function default(win)
    rawset(win, "userW", nil)
    win:SetSize(rawget(win, "_firstW") or win:GetWidth(), rawget(win, "_firstH") or win:GetHeight())
    sized(win)
end

-- Every view of a window: no tabs, its tabs, each tab's subtabs. fn(label) runs on each.
local function eachView(win, fn)
    local tabs = tabsOf(win, "tab")
    if #tabs == 0 then fn("-") return end
    for _, tab in ipairs(tabs) do
        tab:Click()
        fn(tostring(tab.text))
        for _, sub in ipairs(tabsOf(win, "subtab")) do
            sub:Click()
            fn(tostring(tab.text) .. "/" .. tostring((tostring(sub.text):gsub(" %(%d+%)$", ""))))
        end
    end
end

-- Checks one view at one size; adds to `found`, and the numbers to `numbers` (the ratchet).
local function look(ns, win, name, view, size, found, numbers)
    if size == "smallest" then smallest(win) else default(win) end
    local where = name .. "/" .. view .. " " .. size
    local m = check.measure(win, ns)
    if m.slack > check.SLACK then
        local rows = {}
        for _, r in ipairs(m.rows) do rows[#rows + 1] = string.format("%s %s %.0f", r.kind, r.name or "", r.slack) end
        found[#found + 1] = string.format("%s: %.0f px wider than its content needs (rows: %s)", where, m.slack,
            table.concat(rows, "; "))
        if os.getenv("TIGHT_DEBUG") then
            print(where, "width", win:GetWidth(), "need", rawget(win, "contentNeed"), "controls",
                ns.Widgets.ControlsWidth and ns.Widgets.ControlsWidth(win))
            for _, t in ipairs(m.tables) do
                local parts = {}
                for _, c in ipairs(t.cols) do parts[#parts + 1] = string.format("%s[%.0f-%.0f]", c.title, c.l, c.r) end
                print("  ", t.name, "right", t.right, table.concat(parts, " "))
                if t.obj then print("   needed", rawget(t.obj, "neededWidth"), "w", t.obj:GetWidth()) end
            end
        end
    end
    local bad, most = check.badGaps(m)
    if size == "default" then for _, b in ipairs(bad) do found[#found + 1] = where .. ": gap " .. b end end
    local probs = {}
    check.problems(win, where, probs, size == "default", ns)
    local cut, overlap = 0, 0
    for _, p in ipairs(probs) do
        if p:find(" cut: ", 1, true) or p:find("text %d+ px in a button") then cut = cut + 1 else overlap = overlap + 1 end
        found[#found + 1] = p
    end
    numbers[name .. "/" .. view .. "/" .. size] = { width = math.floor(m.width + 0.5), gap = math.floor(most + 0.5),
        cut = cut, overlap = overlap }
end

local function everyWindow(ns, found, numbers, skip)
    local open = openers(ns)
    for _, global in ipairs(WINDOWS) do
        if not (skip and skip[global]) then
            ns.UI.Show()
            if open[global]() ~= false then
                local win = _G[global]
                assert.is_true(win ~= nil and win:IsShown(), global .. " is not open")
                for _, size in ipairs({ "default", "smallest" }) do
                    eachView(win, function(view) look(ns, win, SHORT[global], view, size, found, numbers) end)
                end
                if global == "SalvagerOddsFrame" then ns.Odds.PutBack() end
            end
        end
    end
end

describe("Windows and columns as tight as their content, with typical data (SDD 120)", function()
    local env, ns
    setup(function()
        env = wow.install({ layout = true })
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        seed(env, ns)
    end)

    it("draws every window and view no wider than its content, with normal gaps, nothing cut", function()
        local found, numbers = {}, {}
        local before = #ns.db.log
        for k in pairs(ns.Widgets.layoutLogged) do ns.Widgets.layoutLogged[k] = nil end
        everyWindow(ns, found, numbers)
        -- The addon's own self-check (Widgets.CheckLayout, the one the client runs) says nothing either.
        for i = before + 1, #ns.db.log do
            local line = tostring(ns.db.log[i])
            if line:find("layout: ", 1, true) then found[#found + 1] = "self-check: " .. line end
        end
        ratchet.write("layout-typical", numbers)
        assert.is_true(next(numbers) ~= nil)
        assert.are.equal("", table.concat(found, "\n"))
    end)

    it("shrinks a window when its table empties (a search that finds nothing), and stays tight", function()
        local found, shrank = {}, 0
        local cases = {
            { "SalvagerReportsFrame", function() ns.Reports.ShowView("gear") end, function(t)
                ns.Reports.searchBox:SetText(t)
                local fn = ns.Reports.searchBox.scripts.OnTextChanged
                if fn then fn(ns.Reports.searchBox, true) end
            end },
            { "SalvagerReportsFrame", function() ns.Reports.ShowView("materials") end, function(t)
                ns.Reports.searchBox:SetText(t)
                local fn = ns.Reports.searchBox.scripts.OnTextChanged
                if fn then fn(ns.Reports.searchBox, true) end
            end },
            { "SalvagerLedgerFrame", function()
                ns.LedgerWindow.Show()
                ns.LedgerWindow.view = "purchases"
                ns.LedgerWindow.Refresh()
            end, function(t)
                ns.db.windows.ledger.purchaseFilter = ns.db.windows.ledger.purchaseFilter or {}
                for _, f in ipairs({ ns.LedgerWindow.PurchaseFilter and ns.LedgerWindow.PurchaseFilter() }) do
                    f.search = t
                end
                ns.LedgerWindow.Refresh()
            end },
        }
        for _, c in ipairs(cases) do
            c[2]()
            local win = _G[c[1]]
            default(win)
            local before = win:GetWidth()
            c[3]("zzzz")
            default(win)
            local after = win:GetWidth()
            if after < before - 0.5 then shrank = shrank + 1 end
            if after > before + 0.5 then found[#found + 1] = c[1] .. ": wider with an empty table" end
            local m = check.measure(win, ns)
            if m.slack > check.SLACK then found[#found + 1] = string.format("%s empty: %.0f px too wide", c[1], m.slack) end
            c[3]("")
            default(win)
            if math.abs(win:GetWidth() - before) > 0.5 then
                found[#found + 1] = string.format("%s: %.0f after the search, %.0f before", c[1], win:GetWidth(), before)
            end
        end
        assert.are.equal("", table.concat(found, "\n"))
        assert.is_true(shrank >= 1, "no window shrank when its table emptied")
    end)

    it("keeps every view's width over 10 refreshes and after a round of its tabs", function()
        local found = {}
        local open = openers(ns)
        for _, global in ipairs(WINDOWS) do
            ns.UI.Show()
            if open[global]() ~= false then
                local win = _G[global]
                local widths = {}
                for round = 1, 2 do
                    eachView(win, function(view)
                        default(win)
                        local w = win:GetWidth()
                        for _ = 1, 10 do
                            ns.Fire("SALVAGER_LEDGER")
                            sized(win)
                        end
                        if math.abs(win:GetWidth() - w) > 0.5 then
                            found[#found + 1] = string.format("%s/%s: %.0f, then %.0f after 10 refreshes", global, view, w,
                                win:GetWidth())
                        end
                        if round == 2 and widths[view] and math.abs(widths[view] - w) > 0.5 then
                            found[#found + 1] = string.format("%s/%s: %.0f, %.0f after a round of the tabs", global, view,
                                widths[view], w)
                        end
                        widths[view] = w
                    end)
                end
                if global == "SalvagerOddsFrame" then ns.Odds.PutBack() end
            end
        end
        assert.are.equal("", table.concat(found, "\n"))
    end)

    it("runs the Sales countdowns by drawing only their cells, not the whole view, each second", function()
        ns.LedgerWindow.Show()
        ns.LedgerWindow.view = "sales"
        ns.db.windows.ledger.salesTab = "open"
        ns.LedgerWindow.Refresh()
        local listA = ns.LedgerWindow.salesParts[2]
        local cell
        for _, row in ipairs(listA.rows) do
            if row:IsShown() and row.data and row.data.live then cell = row.cells[3] break end
        end
        assert.is_table(cell, "no countdown on show")
        local before = cell.text
        local real, refreshes = ns.LedgerWindow.Refresh, 0
        ns.LedgerWindow.Refresh = function(...) refreshes = refreshes + 1 return real(...) end
        for _ = 1, 3 do
            env.clock = env.clock + 1
            wow.tick(ns, 1.05)
        end
        ns.LedgerWindow.Refresh = real
        assert.are.equal(0, refreshes)
        assert.are_not.equal(before, cell.text)
    end)

    it("logs a window wider than its content once per view (the self-check, Widgets.CheckLayout)", function()
        local W = ns.Widgets
        if not W.CheckLayout then return pending("no self-check") end
        ns.Materials.PopOut()
        local win = _G.SalvagerMaterialsFrame
        local list = rawget(win, "fitLists")[1]
        -- A width the content does not need (what a constant did): the check says so, once.
        rawset(win, "contentNeed", win:GetWidth() - 40)
        W.layoutLogged["materials/bloat"] = nil
        local before = #ns.db.log
        W.CheckLayout(win, { list }, "bloat")
        W.CheckLayout(win, { list }, "bloat")
        local lines = {}
        for i = before + 1, #ns.db.log do lines[#lines + 1] = tostring(ns.db.log[i]) end
        local text = table.concat(lines, "\n")
        assert.is_truthy(text:find("layout: materials/bloat wider than its content by 40 px", 1, true), text)
        local _, n = text:gsub("layout: materials/bloat", "")
        assert.are.equal(1, n)
        -- A tight window logs nothing.
        default(win)
        local count = #ns.db.log
        W.layoutLogged["materials/materials"] = nil
        W.CheckLayout(win, { list }, "materials")
        for i = count + 1, #ns.db.log do assert.is_nil(tostring(ns.db.log[i]):find("layout:", 1, true)) end
    end)
end)

describe("Windows as tight as their titles with no data at all (SDD 120)", function()
    it("draws every empty view no wider than its titles, its note or its controls need", function()
        wow.install({ layout = true })
        local ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        local found, numbers = {}, {}
        everyWindow(ns, found, numbers, { SalvagerStandFrame = true, SalvagerGearFrame = true })
        ratchet.write("layout-empty", numbers)
        assert.are.equal("", table.concat(found, "\n"))
    end)
end)

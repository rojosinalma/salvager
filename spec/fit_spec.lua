-- Every Salvager window, every tab and subtab, at its smallest size and at its default size, with long data: no text
-- is cut unless the code says it may be (UI.md Layout 6, Tables 2), no two controls of a row overlap, nothing is
-- outside its window, and every table's last column ends at the table's right edge (UI.md Tables 2). The stand-in
-- models sizes, anchors and text widths for this (spec/wow.lua, layout mode; SDD 106).
local wow = require("spec.wow")

local WINDOWS = { "SalvagerFrame", "SalvagerLedgerFrame", "SalvagerOddsFrame", "SalvagerMaterialsFrame",
    "SalvagerMarketFrame", "SalvagerReportsFrame", "SalvagerLogFrame", "SalvagerLimitsFrame", "SalvagerOptionsFrame",
    "SalvagerPostFrame", "SalvagerGearFrame", "SalvagerBreakdownFrame", "SalvagerStandFrame" }
local ROWS = { tabrow = true, subtabrow = true, filterrow = true, footer = true }
local POPUP = { DIALOG = true, TOOLTIP = true, FULLSCREEN_DIALOG = true }
local EPS = 0.5
local ns_   -- (the addon, for the debug lines)

local function rect(r)
    local l, b, w, h = wow.rectOf(r)
    if not l then return nil end
    return { l = l, b = b, r = l + w, t = b + h, w = w, h = h }
end

local function inside(a, box) return a.l >= box.l - EPS and a.r <= box.r + EPS and a.b >= box.b - EPS and a.t <= box.t + EPS end
local function apart(a, box) return a.r <= box.l + EPS or a.l >= box.r - EPS or a.t <= box.b + EPS or a.b >= box.t - EPS end
local function clipTo(a, box)
    if not box then return a end
    return { l = math.max(a.l, box.l), r = math.min(a.r, box.r), b = math.max(a.b, box.b), t = math.min(a.t, box.t) }
end

-- The field that holds `r` in its parent or its parent's parent ("cells", "footer2"), to say which one it is.
local function key(r)
    for _, p in ipairs({ rawget(r, "parent"), rawget(r, "parent") and rawget(r.parent, "parent") }) do
        if type(p) == "table" then
            for k, v in pairs(p) do
                if v == r and type(k) == "string" then return k end
                if type(v) == "table" and type(k) == "string" and k ~= "_children" and k ~= "_regions" then
                    for _, x in ipairs(v) do if x == r then return k end end
                end
            end
        end
    end
end

local function name(r)
    local text = rawget(r, "text")
    local what = (rawget(r, "uiKind") or r.kind) .. (key(r) and ("." .. key(r)) or "")
    return what .. (type(text) == "string" and text ~= "" and (" \"" .. text:sub(1, 60) .. "\"") or "")
end

local function isList(obj)
    return type(rawget(obj, "headers")) == "table" and type(rawget(obj, "rows")) == "table"
        and type(rawget(obj, "columns")) == "table"
end

-- The problems of one window as it is drawn now; `where` names the window, the view and the size.
local function problems(win, where, out, atDefault)
    local box = rect(win)
    local function add(msg) out[#out + 1] = where .. ": " .. msg end
    local function visit(obj, clip, list)
        if not obj:IsShown() then return end
        if POPUP[rawget(obj, "_strata") or ""] then return end
        local r = rect(obj)
        if r and r.w > 0 and r.h > 0 then
            local seen = clipTo(r, clip)
            local hidden = clip and (seen.l >= seen.r - EPS or seen.b >= seen.t - EPS)
            if hidden then return end   -- (scrolled away)
            if not clip and not inside(r, box) and obj.kind ~= "Texture" then
                add(string.format("%s outside the window (%.0f..%.0f of %.0f..%.0f wide, %.0f..%.0f of %.0f..%.0f high)",
                    name(obj), r.l, r.r, box.l, box.r, r.b, r.t, box.b, box.t))
            end
        end
        if obj.kind == "FontString" then
            if rawget(obj, "buttonText") then
                local b = rect(obj.parent)
                local tw = wow.textWidth(obj.text, obj:GetFont() and select(2, obj:GetFont()))
                if b and tw > b.w - 4 + EPS and (obj.text or "") ~= "" then
                    add(string.format("%s: text %.0f px in a button of %.0f", name(obj.parent), tw, b.w))
                end
            elseif wow.isCut(obj) and not rawget(obj, "canCut") then
                add(string.format("%s cut: %.0f px of text in %.0f%s", name(obj), obj:GetStringWidth(), r and r.w or -1,
                    list and (" (table " .. tostring(list.columns[1] and list.columns[1][1]) .. ")") or ""))
            end
            return
        end
        if obj.kind == "Texture" then return end
        local inner = clip
        if obj:DoesClipChildren() and r then inner = clip and clipTo(r, clip) or r end
        if ROWS[rawget(obj, "uiKind") or ""] then
            -- The controls and texts of a row: none overlaps another, all inside the row's ends.
            local items = {}
            local function collect(x)
                if not x:IsShown() or rawget(x, "uiKind") == "help" then return end   -- (a help area lies over its label)
                local xr = rect(x)
                if not xr or xr.w <= 0 then return end
                if x.kind == "FontString" and (x.text or "") == "" then return end
                -- A check box with its label is one item.
                local label = rawget(x, "label")
                if type(label) == "table" and label:IsShown() and (label.text or "") ~= "" then
                    local lr = rect(label)
                    if lr then xr = { l = math.min(xr.l, lr.l), r = math.max(xr.r, lr.r), b = math.min(xr.b, lr.b),
                        t = math.max(xr.t, lr.t) } end
                end
                items[#items + 1] = { x = x, r = xr }
            end
            for _, c in ipairs(obj._children) do if not POPUP[rawget(c, "_strata") or ""] then collect(c) end end
            for _, t in ipairs(obj._regions) do if t.kind == "FontString" then collect(t) end end
            for i = 1, #items do
                local a = items[i]
                if r and (a.r.l < r.l - EPS or a.r.r > r.r + EPS) then
                    add(string.format("%s beyond its %s's ends (%.0f..%.0f of %.0f..%.0f)", name(a.x), obj.uiKind,
                        a.r.l, a.r.r, r.l, r.r))
                end
                for j = i + 1, #items do
                    local b = items[j]
                    if not apart(a.r, b.r) then
                        add(string.format("%s overlaps %s in the %s (%.0f..%.0f and %.0f..%.0f)", name(a.x), name(b.x),
                            obj.uiKind, a.r.l, a.r.r, b.r.l, b.r.r))
                    end
                end
            end
        end
        if atDefault and isList(obj) and r then
            local right, n = nil, 0
            for i, h in ipairs(obj.headers) do
                if h:IsShown() and obj.columns[i] then
                    n = n + 1
                    local hr = rect(h)
                    if hr and (not right or hr.r > right) then right = hr.r end
                end
            end
            -- (Left at the right: the scroll bar and its gaps, 22 px; 32 where the rows' buttons are the last column.)
            local action = rawget(obj, "actionTitle")
            if action and action:IsShown() then local ar = rect(action) if ar then right = math.max(right or 0, ar.r) end end
            if n >= 2 and right and r.r - right > 34 then
                add(string.format("table %s: its last column ends %.0f px before its right edge", tostring(obj.columns[1][1]),
                    r.r - right))
            end
        end
        if atDefault and rawget(obj, "cards") and rawget(obj, "widths") and r then
            -- A stack of cards (the Odds): in each card, the last column ends at the card's right edge.
            for _, card in ipairs(obj.cards) do
                if card:IsShown() and card.heads:IsShown() then
                    local cr, right = rect(card), nil
                    for i, h in ipairs(card.headTexts) do
                        if h:IsShown() and i > 1 then local hr = rect(h) if hr then right = math.max(right or 0, hr.r) end end
                    end
                    if cr and right and inside(cr, clip or box) and cr.r - right > 34 then
                        add(string.format("cards %s: the last column ends %.0f px before the card's right edge",
                            tostring(card.title.text), cr.r - right))
                    end
                end
            end
        end
        -- FIT_DEBUG=1: the columns a table leaves out for want of room (not a failure: UI.md Tables 2).
        if isList(obj) and os.getenv("FIT_DEBUG") then
            local W, dropped = ns_.Widgets, {}
            for i, col in ipairs(obj.columns) do
                local wanted = W.ColumnShown(rawget(obj, "columnSet"), W.ColumnKey(col))
                if i > 1 and wanted and not obj.headers[i]:IsShown() then dropped[#dropped + 1] = tostring(col[1]) end
            end
            if #dropped > 0 then
                print(where .. ": table " .. tostring(obj.columns[1][1]) .. " leaves out " .. table.concat(dropped, ", "))
            end
        end
        local within = list
        if isList(obj) then within = obj end
        for _, c in ipairs(obj._children) do visit(c, inner, within) end
        for _, t in ipairs(obj._regions) do visit(t, inner, within) end
    end
    visit(win, nil)
end

-- Every size change reaches the frames that watch it, as in the client.
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

-- Long data: long gear names, the largest amounts (9999g 99s 99c a unit, 9,999,999g in the bags), every material,
-- full bags, a full log, many purchases, disenchants, posts and sales.
local NAMES = { "Bloodforged Shoulderpads of the Whale", "Thunderbrew's Ceremonial Boot Knife of the Monkey",
    "Grimlok's Spiked Crown of the Twilight Sentinel", "Lightforged Gauntlets of Arcane Wrath",
    "Cerulean Ring of the Eternal Bear", "Embrace of the Wind Serpent's Ancient Guardian",
    "Blackhand's Breadth of the Unyielding Tiger", "Venomshroud Mantle of Shadow Wrath",
    "Stormpike Soldier's Plated Legguards of Stamina", "Silvermoon Battle Staff of the Fiery Wrath",
    "Felstriker Dagger of the Unrelenting Eagle", "Bracers of the Frozen Wastes Guardian" }
local BIG = 99999999   -- 9999g 99s 99c

local function seed(env, ns)
    local gear = {}
    for i, n in ipairs(NAMES) do
        local id = 7000 + i
        local quality = 2 + (i % 3)
        env.items[id] = { name = n, quality = quality, ilvl = 20 + i * 4, req = 15 + i * 3, classID = i % 2 == 0 and 2 or 4 }
        gear[#gear + 1] = id
    end
    local function link(id) return "|cff1eff00|Hitem:" .. id .. "::::::::60:::::|h[" .. env.items[id].name .. "]|h|r" end
    for _, m in ipairs(ns.Data.MATERIALS) do
        env.items[m.id] = { name = m.name, quality = 1, ilvl = 1, classID = 7 }
        ns.db.prices[m.id] = { p = BIG, lo = BIG, t = env.clock }
        ns.History.Add(ns.db.history, m.id, env.clock - 86400, BIG - 1000, BIG - 1000, 9999)
        ns.History.Add(ns.db.history, m.id, env.clock - 60, BIG, BIG, 9999)
        env.ah.commodities[m.id] = { { unitPrice = BIG, quantity = 9999, numOwnerItems = 0 } }
        env.bags[m.id] = 999
    end
    env.money = 2147483647                                   -- the gold cap: 214748g 36s 47c
    env.bagSize = { [0] = 16, [1] = 36, [2] = 36, [3] = 36, [4] = 36 }
    env.bagFree = { [0] = 0, [1] = 0, [2] = 0, [3] = 0, [4] = 1 }
    local slots = {}
    for i, m in ipairs(ns.Data.MATERIALS) do slots[i] = m.id end
    env.bagSlots = slots
    local s = ns.db.settings
    s.minProfit, s.minReturn, s.priceRescan = 0, 0, 0
    s.qualities = { [2] = true, [3] = true, [4] = true }
    -- A gear scan: three auctions of each piece, at the largest buyouts.
    env.ah.browse = {}
    for i, id in ipairs(gear) do
        env.ah.browse[i] = { itemKey = { itemID = id, itemLevel = env.items[id].ilvl, itemSuffix = 0 }, minPrice = BIG - i }
        env.ah.itemResults[id] = {}
        for a = 1, 3 do
            env.ah.itemResults[id][a] = { auctionID = id * 10 + a, buyoutAmount = BIG - a, itemLink = link(id),
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
    -- Purchases (left in the mail), disenchants of them, posts and sales of their materials.
    local L = ns.db.ledger
    for i, id in ipairs(gear) do
        ns.Ledger.AuctionPurchase(L, id, BIG - i, BIG * 3, env.clock - i * 3600, link(id))
        ns.Ledger.AddPurchase(L, id, 99, BIG * 99, BIG * 300, env.clock - i * 7200, link(id))
    end
    for i, m in ipairs(ns.Data.MATERIALS) do
        env.bagLinks = { ["0:1"] = link(gear[(i % #gear) + 1]) }
        wow.fire(ns, "UNIT_SPELLCAST_SENT", "player", nil, "cast-guid", 13262)
        wow.fire(ns, "ITEM_LOCK_CHANGED", 0, 1)
        env.loot = { { id = m.id, qty = 99 } }
        wow.fire(ns, "LOOT_READY")
    end
    env.ah.owned = {}
    for i, m in ipairs(ns.Data.MATERIALS) do
        for k = 1, 2 do
            if ns.Post.Send(m.id, 200, BIG, 3) then
                local auction = 9000 + i * 10 + k
                wow.fire(ns, "AUCTION_HOUSE_AUCTION_CREATED", auction)
                env.ah.owned[#env.ah.owned + 1] = { auctionID = auction, itemKey = { itemID = m.id }, quantity = 200,
                    status = k == 1 and 1 or 0, timeLeftSeconds = 172800, buyoutAmount = BIG }
            end
        end
    end
    wow.fire(ns, "OWNED_AUCTIONS_UPDATED")
    wow.fire(ns, "PLAYER_MONEY")
    for i = 1, 5000 do
        ns.Log("checked item %s: %d auctions, %d under %s", NAMES[i % #NAMES + 1], 999, 999, ns.Money(BIG))
    end
    return gear
end

describe("The stand-in's text widths (spec/wow.lua)", function()
    it("measures texts within 8 % of the client and never more than 5 % short", function()
        -- Widths the client measured (the layout dump: texts sized to their text), in 12 and 10 pt.
        local samples = { { "Salvager ledger", 12, 96.8 }, { "Purchases", 12, 62.5 }, { "Accuracy", 12, 57.9 },
            { "Auction house", 12, 90.7 }, { "Scan materials", 12, 89.9 }, { "Clear", 12, 32.8 },
            { "Only bands with my data", 10, 128 }, { "Only materials with my data", 10, 144.8 },
            { "or item level from", 10, 92.2 }, { "Item checks", 10, 60.2 }, { "v0.3.117", 10, 44.2 }, { "Odds", 12, 33.5 },
            { "Quality", 10, 38.9 }, { "Market", 12, 45 } }
        for _, x in ipairs(samples) do
            local w = wow.textWidth(x[1], x[2])
            assert.is_true(w >= x[3] * 0.95 and w <= x[3] * 1.08, string.format("%s: %.1f, the client %.1f", x[1], w, x[3]))
        end
        -- Color and link codes take no room; an icon is as wide as its size.
        assert.are.equal(wow.textWidth("Dust", 10), wow.textWidth("|cff1eff00|Hitem:1|hDust|h|r", 10))
        assert.are.equal(wow.textWidth("1", 10) + 16, wow.textWidth("1|TInterface\\Icon:16:16:0:0|t", 10))
        assert.are.equal(wow.textWidth("1", 10) + 10, wow.textWidth("1|TInterface\\Icon:0|t", 10))
    end)
end)

describe("Every window fits its texts at its smallest and its default size (UI.md Layout 6)", function()
    local env, ns, open
    local found = {}

    setup(function()
        env = wow.install({ layout = true })
        ns = wow.loadAddon()
        ns_ = ns
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        assert.is_true(#seed(env, ns) > 0)
        local function answer()
            for _ = 1, 60 do
                wow.tick(ns, 0.2)
                local c = ns.Queue.current
                if c and c.commodity then wow.fire(ns, "COMMODITY_SEARCH_RESULTS_UPDATED", c.commodity) end
                if c and c.itemKey then wow.fire(ns, "ITEM_SEARCH_RESULTS_UPDATED", c.itemKey) end
            end
        end
        local mat = ns.Data.MATERIALS[#ns.Data.MATERIALS].id
        -- How each window opens (one at a time: some close others).
        open = {
            SalvagerFrame = function() ns.UI.Show() end,
            SalvagerLedgerFrame = function() ns.LedgerWindow.Show() end,
            SalvagerOddsFrame = function() ns.LedgerWindow.OddsPopOut() end,
            SalvagerMaterialsFrame = function() ns.Materials.PopOut() end,
            SalvagerMarketFrame = function() if not (_G.SalvagerMarketFrame or {}).shown then ns.Market.Toggle() end end,
            SalvagerReportsFrame = function() ns.Reports.Show() end,
            SalvagerLogFrame = function() ns.LogWindow.Show() end,
            SalvagerLimitsFrame = function() ns.LimitsWindow.Show() end,
            SalvagerOptionsFrame = function() ns.Options.Open() end,
            SalvagerPostFrame = function() ns.Post.Open(mat) answer() end,
            SalvagerBreakdownFrame = function() ns.Breakdown.Open(mat) end,
            SalvagerStandFrame = function()
                local row
                for _, r in ipairs(ns.db.listings.rows) do if not r.sold and r.commodity then row = r end end
                assert.is_table(row, "no open listing for the Stand window")
                ns.Stand.Show(row)
                answer()
            end,
            SalvagerGearFrame = function()
                assert.is_true(#ns.Scanner.deals > 0)
                ns.GearWindow.Open(ns.Scanner.deals[1])
            end,
        }
    end)

    local function each(win, where, atDefault)
        problems(win, where, found, atDefault)
        for _, tab in ipairs(tabsOf(win, "tab")) do
            tab:Click()
            problems(win, where .. " / " .. tostring(tab.text), found, atDefault)
            for _, sub in ipairs(tabsOf(win, "subtab")) do
                sub:Click()
                problems(win, where .. " / " .. tostring(tab.text) .. " / " .. tostring(sub.text), found, atDefault)
            end
        end
    end

    it("draws every window without a cut text, an overlap or a control outside it", function()
        for _, global in ipairs(WINDOWS) do
            ns.UI.Show()
            open[global]()
            local win = _G[global]
            assert.is_true(win ~= nil and win:IsShown(), global .. " is not open")
            do
                local bounds = rawget(win, "_bounds")
                local minW = bounds and bounds[1] or rawget(win, "minWidth") or win:GetWidth()
                local minH = bounds and bounds[2] or win:GetHeight()
                local w0, h0 = rawget(win, "_firstW") or win:GetWidth(), rawget(win, "_firstH") or win:GetHeight()
                win:SetSize(minW, minH)
                sized(win)
                each(win, global .. " at " .. math.floor(win:GetWidth()) .. "x" .. math.floor(win:GetHeight()), false)
                win:SetSize(w0, h0)
                sized(win)
                each(win, global .. " at " .. math.floor(win:GetWidth()) .. "x" .. math.floor(win:GetHeight()), true)
            end
        end
        assert.are.equal("", table.concat(found, "\n"))
    end)
end)

-- Every Salvager window, every tab and subtab, at its smallest size and at its default size, with long data: no text
-- is cut unless the code says it may be (UI.md Layout 6, Tables 2), no two controls of a row overlap, nothing is
-- outside its window, and every table's last column ends at the table's right edge (UI.md Tables 2). The stand-in
-- models sizes, anchors and text widths for this (spec/wow.lua, layout mode; SDD 106).
local wow = require("spec.wow")

local WINDOWS = { "SalvagerFrame", "SalvagerMiniFrame", "SalvagerLedgerFrame", "SalvagerOddsFrame", "SalvagerMaterialsFrame",
    "SalvagerMarketFrame", "SalvagerReportsFrame", "SalvagerLogFrame", "SalvagerLimitsFrame", "SalvagerOptionsFrame",
    "SalvagerPostFrame", "SalvagerGearFrame", "SalvagerBreakdownFrame", "SalvagerStandFrame", "SalvagerDisenchantFrame" }
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
local function tableName(obj)
    if isList(obj) then return tostring(obj.columns[1] and obj.columns[1][1]) end
    return "of cards"
end

local function problems(win, where, out, atDefault)
    local box = rect(win)
    local tables = {}
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
        -- The main window's own table (the Gear and Materials tabs): its last column, the buttons', ends at the list's
        -- right edge too (the first column takes the spare width).
        if atDefault and ns_ and obj == ns_.UI.list and r then
            local right
            for _, h in ipairs(ns_.UI.headers) do
                if h:IsShown() and (h.text or "") ~= "" then local hr = rect(h) if hr then right = math.max(right or 0, hr.r) end end
            end
            for _, row in ipairs(ns_.UI.rows) do
                if row:IsShown() and row.buy:IsShown() then local br = rect(row.buy) if br then right = math.max(right or 0, br.r) end end
            end
            if os.getenv("FIT_DEBUG") then print("main table", where, r.r, right) end
            if right and r.r - right > 12 then
                add(string.format("the main window's table: its last column ends %.0f px before its right edge", r.r - right))
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
        -- A table leaves no column out at the default size (on a 1920 wide screen): the window fits its columns
        -- (SDD 107). At the smallest size a column may be left out, and then the table's note says so. FIT_DEBUG=1
        -- lists them.
        if isList(obj) then
            local W, dropped = ns_.Widgets, {}
            for i, col in ipairs(obj.columns) do
                local wanted = W.ColumnShown(rawget(obj, "columnSet"), W.ColumnKey(col))
                if i > 1 and wanted and not obj.headers[i]:IsShown() then dropped[#dropped + 1] = tostring(col[1]) end
            end
            if #dropped > 0 then
                local text = "table " .. tostring(obj.columns[1][1]) .. " leaves out " .. table.concat(dropped, ", ")
                if atDefault then add(text) end
                local note = rawget(obj, "leftOutNote")
                if rawget(obj, "headers")[1]:IsShown() and not (note and note:IsShown()) then
                    add(text .. " without its note")
                end
                if os.getenv("FIT_DEBUG") then print(where .. ": " .. text) end
            end
        end
        -- The tables of the window (lists and stacks of cards), for the check that none overlaps another.
        if r and not clip and (isList(obj) or rawget(obj, "cards")) then tables[#tables + 1] = { obj = obj, r = r } end
        local within = list
        if isList(obj) then within = obj end
        for _, c in ipairs(obj._children) do visit(c, inner, within) end
        for _, t in ipairs(obj._regions) do visit(t, inner, within) end
    end
    visit(win, nil)
    -- No table overlaps another, and each is at least as tall as its titles and two rows (SDD 113).
    for i, a in ipairs(tables) do
        local least = 3 * 22
        if isList(a.obj) then
            local rowH = rawget(a.obj.rows[1], "_h") or 22
            -- (A table of one row may be as tall as that row.)
            least = ((a.obj.headers[1]:IsShown() and 1 or 0) + math.min(2, math.max(1, rawget(a.obj, "count") or 2))) * rowH
        end
        if a.r.h < least - EPS then
            add(string.format("table %s: %.0f px high, less than its titles and two rows (%.0f)", tableName(a.obj), a.r.h, least))
        end
        for j = i + 1, #tables do
            local b = tables[j]
            if not apart(a.r, b.r) then
                add(string.format("table %s overlaps table %s (%.0f..%.0f and %.0f..%.0f high)", tableName(a.obj),
                    tableName(b.obj), a.r.b, a.r.t, b.r.b, b.r.t))
            end
        end
    end
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
        env.bags[id] = 99   -- (picked up: the Current batch has them)
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
    -- The gear in the last slots of the bags (the Disenchant panel lists it), twice each.
    env.bagItems = {}
    for i, id in ipairs(gear) do
        env.bagItems["4:" .. (24 + i)] = id
        env.bagItems["3:" .. (24 + i)] = id
    end
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
    -- Disenchants after the posts: their materials are not posted (the Current batch has them).
    env.clock = env.clock + 60
    for i = 1, 4 do
        local m = ns.Data.MATERIALS[#ns.Data.MATERIALS - i + 1]
        env.bagLinks = { ["0:1"] = link(gear[i]) }
        wow.fire(ns, "UNIT_SPELLCAST_SENT", "player", nil, "cast-guid", 13262)
        wow.fire(ns, "ITEM_LOCK_CHANGED", 0, 1)
        env.loot = { { id = m.id, qty = 99 }, { id = ns.Data.MATERIALS[i].id, qty = 99 } }
        wow.fire(ns, "LOOT_READY")
    end
    wow.fire(ns, "PLAYER_MONEY")
    -- Competitors with long names under every material, a chain of cancel, repost and sale for the profit lost, and
    -- the first heading of each competition table open.
    local C, CS = ns.Competition, ns.db.competition
    local SELLERS = { "Bloodforgedauctioneer", "Thunderbrewmerchant", "Grimlokthetrader", "" }
    for i, m in ipairs(ns.Data.MATERIALS) do
        for k = 1, 3 do
            C.Observe(CS, m.id, { { each = BIG - 1000 * k, qty = 9999, ownQty = 0, owners = { SELLERS[(i + k) % 4 + 1],
                SELLERS[(i + k + 1) % 4 + 1] }, total = 5 } }, { { each = BIG, qty = 9999 } }, env.clock - k * 3600)
        end
        C.NotePost(CS, { t = env.clock - 7000, id = m.id, auctionID = 50000 + i, qty = 9999, each = BIG, deposit = BIG })
        C.Observe(CS, m.id, { { each = BIG - 99999, qty = 99, ownQty = 0, owners = { SELLERS[1] }, total = 1 } },
            { { each = BIG, qty = 9999 } }, env.clock - 60)
        C.NoteCancel(CS, { t = env.clock - 30, id = m.id, auctionID = 50000 + i, qty = 9999, each = BIG, fee = BIG,
            deposit = BIG })
        C.NotePost(CS, { t = env.clock - 20, id = m.id, auctionID = 60000 + i, qty = 9999, each = BIG - 100000, deposit = BIG })
        C.NoteSale(CS, 60000 + i, 9999, BIG - 100000, env.clock - 10)
    end
    ns.GroupState("ledger.competition")[SELLERS[1]] = true
    ns.GroupState("reports.competitors")[SELLERS[1]] = true
    ns.GroupState("reports.compMaterials")[tostring(ns.Data.MATERIALS[1].id)] = true
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
            SalvagerMiniFrame = function() ns.MiniPanel.Show() end,
            SalvagerLedgerFrame = function() ns.LedgerWindow.Show() end,
            SalvagerOddsFrame = function() ns.Odds.PopOut() end,
            SalvagerMaterialsFrame = function() ns.Materials.PopOut() end,
            SalvagerMarketFrame = function() if not (_G.SalvagerMarketFrame or {}).shown then ns.Market.Toggle() end end,
            SalvagerReportsFrame = function() ns.Reports.Show() end,
            SalvagerLogFrame = function() ns.LogWindow.Show() end,
            SalvagerLimitsFrame = function() ns.LimitsWindow.Show() end,
            SalvagerOptionsFrame = function() ns.Options.Open() end,
            SalvagerPostFrame = function() ns.Post.Open(mat) answer() end,
            SalvagerBreakdownFrame = function() ns.Breakdown.Open(mat) end,
            SalvagerDisenchantFrame = function()
                env.cvars.autoLootDefault = false   -- (its note shows)
                ns.DisenchantPanel.Show()
                assert.is_true(#ns.DisenchantPanel.Pieces() >= 24)
            end,
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

    -- The smallest size, as the player drags the corner to it (the window keeps that width until a view change),
    -- or the default size (the width the view needs).
    local function smallest(win)
        local bounds = rawget(win, "_bounds")
        local minW = bounds and bounds[1] or rawget(win, "minWidth") or win:GetWidth()
        local minH = bounds and bounds[2] or win:GetHeight()
        rawset(win, "userW", minW)
        win:SetSize(minW, minH)
        sized(win)
    end
    local function default(win)
        rawset(win, "userW", nil)
        win:SetSize(rawget(win, "_firstW") or win:GetWidth(), rawget(win, "_firstH") or win:GetHeight())
        sized(win)
    end
    -- A tab change: at the smallest size the player sizes it down again (a view change gives the window the new view's
    -- width, SDD 113); at the default size each view's width is noted, to check it comes back (no other view's width).
    local widths = {}
    local function view(win, where, atDefault)
        if not atDefault then smallest(win) end
        problems(win, where, found, atDefault)
        if atDefault then
            local w, need = win:GetWidth(), rawget(win, "fitNeed")
            if type(need) == "number" and w > need + EPS then
                found[#found + 1] = string.format("%s: %.0f wide, its view needs %.0f", where, w, need)
            end
            local vkey = where:gsub(" at %d+x%d+", "")
            if widths[vkey] and math.abs(widths[vkey] - w) > EPS then
                found[#found + 1] = string.format("%s: %.0f wide, %.0f the first time (another view's width kept)",
                    where, w, widths[vkey])
            end
            widths[vkey] = w
        end
    end
    local function each(win, where, atDefault)
        local tabbed = #tabsOf(win, "tab") > 0
        -- (Twice at the default size: each view comes back at its own width.)
        for pass = 1, (atDefault and tabbed) and 2 or 1 do
            if pass == 1 then view(win, where, atDefault) end
            for _, tab in ipairs(tabsOf(win, "tab")) do
                tab:Click()
                view(win, where .. " / " .. tostring(tab.text), atDefault)
                for _, sub in ipairs(tabsOf(win, "subtab")) do
                    sub:Click()
                    view(win, where .. " / " .. tostring(tab.text) .. " / " .. tostring(sub.text), atDefault)
                end
            end
        end
    end

    it("draws every window without a cut text, an overlap or a control outside it", function()
        for _, global in ipairs(WINDOWS) do
            ns.UI.Show()
            open[global]()
            local win = _G[global]
            assert.is_true(win ~= nil and win:IsShown(), global .. " is not open")
            smallest(win)
            each(win, global .. " at " .. math.floor(win:GetWidth()) .. "x" .. math.floor(win:GetHeight()), false)
            default(win)
            each(win, global .. " at " .. math.floor(win:GetWidth()) .. "x" .. math.floor(win:GetHeight()), true)
        end
        assert.are.equal("", table.concat(found, "\n"))
    end)
    it("drew the competition tables with data (the Ledger's subtab, the Reports' tab)", function()
        assert.is_true(#ns.LedgerWindow.CompetitionRows() > 5)
        assert.is_true(#ns.Reports.CompetitorRows() > 5)
        assert.is_true(#ns.Reports.CompetitionMaterialRows() > 5)
        local seen = {}
        for _, f in ipairs(found) do seen[#seen + 1] = f end
        assert.are.equal("", table.concat(seen, "\n"))
    end)
    it("gives each view its own width after a tab change, narrower too (SDD 113)", function()
        local function tab(win, text)
            for _, t in ipairs(tabsOf(win, "tab")) do if t.text == text then t:Click() return end end
            error("no tab " .. text)
        end
        local function sub(win, text)
            for _, t in ipairs(tabsOf(win, "subtab")) do if t.text:find(text, 1, true) == 1 then t:Click() return end end
            error("no subtab " .. text)
        end
        -- The main window: the Materials tab widens it, back on Gear it is as wide as Gear needs; its width is fixed
        -- (0.3.149): a width set from outside goes back to the view's on the next refresh.
        ns.UI.Show()
        local main = _G.SalvagerFrame
        tab(main, "Gear")
        local gearW = rawget(main, "minWidth")
        tab(main, "Materials")
        local matW = main:GetWidth()
        assert.is_true(matW > gearW, matW .. " " .. gearW)
        tab(main, "Gear")
        assert.are.equal(gearW, main:GetWidth())
        main:SetWidth(gearW + 300)
        tab(main, "Gear")
        assert.are.equal(gearW, main:GetWidth())
        local lo, _, hi = main:GetResizeBounds()
        if lo then assert.are.same({ gearW, gearW }, { lo, hi }) end   -- only the height can be dragged
        -- The Ledger: Competition, then History (890, its smallest).
        ns.LedgerWindow.Show()
        local ledger = _G.SalvagerLedgerFrame
        tab(ledger, "Sales") sub(ledger, "Competition")
        assert.is_true(ledger:GetWidth() > 890)
        sub(ledger, "History")
        assert.are.equal(890, ledger:GetWidth())
        -- The Reports: Competition, then Gold (its smallest); narrowed by the player, the next tab is as wide as it needs.
        ns.Reports.Show()
        local reports = _G.SalvagerReportsFrame
        rawset(reports, "userW", nil)
        tab(reports, "Competition")
        local compW = reports:GetWidth()
        assert.is_true(compW > 1050)
        tab(reports, "Gold")
        assert.are.equal(1050, reports:GetWidth())
        tab(reports, "Competition")
        rawset(reports, "userW", 1050)
        reports:SetWidth(1050)
        sized(reports)
        assert.are.equal(1050, reports:GetWidth())
        tab(reports, "Gold")
        tab(reports, "Competition")
        assert.are.equal(compW, reports:GetWidth())
        -- The Market: Essences is wider than Materials; back on Materials it shrinks back.
        if not _G.SalvagerMarketFrame or not _G.SalvagerMarketFrame:IsShown() then ns.Market.Toggle() end
        local market = _G.SalvagerMarketFrame
        rawset(market, "userW", nil)
        tab(market, "Materials")
        local mw = market:GetWidth()
        tab(market, "Essences")
        assert.is_true(market:GetWidth() > mw)
        tab(market, "Materials")
        assert.are.equal(mw, market:GetWidth())
    end)
    it("shares the height of two tables by the bar between them, each keeping two rows (SDD 113)", function()
        local mat = ns.Data.MATERIALS[#ns.Data.MATERIALS].id
        local cases = {
            { "SalvagerBreakdownFrame", function() ns.Breakdown.Open(mat) end },
            { "SalvagerDisenchantFrame", function() ns.DisenchantPanel.Show() end },
            { "SalvagerLedgerFrame", function() ns.LedgerWindow.Show() ns.LedgerWindow.view = "accuracy" ns.LedgerWindow.Refresh() end },
            { "SalvagerReportsFrame", function() ns.Reports.Show() ns.Reports.view = "competition" ns.Reports.Refresh() end },
        }
        local seen = {}
        for _, c in ipairs(cases) do
            c[2]()
            local win = _G[c[1]]
            for _, share in ipairs({ 0.9, 0.1 }) do
                win.saved.split, win.saved.salesSplit, win.saved.compSplit = share, share, share
                for _, size in ipairs({ "smallest", "default" }) do
                    if size == "smallest" then smallest(win) else default(win) end
                    problems(win, c[1] .. " split " .. share .. " " .. size, seen, false)
                end
            end
            win.saved.split, win.saved.salesSplit, win.saved.compSplit = nil, nil, nil
        end
        assert.are.equal("", table.concat(seen, "\n"))
    end)
    -- The player drags a window's corner (its grip): mouse down, the client sizes it step by step inside its resize
    -- bounds (each step fires OnSizeChanged down the window), mouse up. `steps` = { { w, h }, ... }; `check(i, want)`
    -- runs after each step with the size asked for (clamped to the bounds).
    local function gripOf(win)
        for _, c in ipairs(win._children) do
            if c.scripts.OnMouseDown and c.scripts.OnMouseUp and c:GetWidth() == 16 then return c end
        end
    end
    local function drag(win, steps, check)
        local grip = gripOf(win)
        assert.is_table(grip, "no grip")
        grip.scripts.OnMouseDown(grip, "LeftButton")
        local lo, loH, hi, hiH = win:GetResizeBounds()
        for i, st in ipairs(steps) do
            local w = math.max(lo, math.min(hi or 1e9, st[1]))
            local h = math.max(loH, math.min(hiH or 1e9, st[2]))
            win:SetSize(w, h)
            sized(win)
            check(i, w, h)
            -- (While the corner is dragged the bounds hold: a bound that moves makes the client move the corner.)
            local lo2, loH2, hi2 = win:GetResizeBounds()
            assert.are.same({ lo, loH, hi }, { lo2, loH2, hi2 }, "the bounds changed during the drag, step " .. i)
        end
        grip.scripts.OnMouseUp(grip, "LeftButton")
    end
    it("resizes the Disenchant panel smoothly both ways: the corner follows, the tables share the height", function()
        ns.DisenchantPanel.Show()
        local win, P = _G.SalvagerDisenchantFrame, ns.DisenchantPanel
        win.saved.split = nil
        default(win)
        local lo, loH, hi = win:GetResizeBounds()
        assert.is_true(hi > lo, lo .. " " .. hi)
        local seen, steps = {}, {}
        for k = 0, 10 do steps[#steps + 1] = { lo + (hi - lo) * k / 10, loH + 60 * k } end
        for k = 9, 0, -1 do steps[#steps + 1] = { lo + (hi - lo) * k / 10, loH + 60 * k } end
        local last
        -- A drag lays the tables out again; it does not read the bags or the batch again (each step did, 0.3.150).
        local LW, batches, realBatch = ns.LedgerWindow, 0, ns.LedgerWindow.Batch
        LW.Batch = function(...) batches = batches + 1 return realBatch(...) end
        local layouts = P.layouts or 0
        drag(win, steps, function(i, w, h)
            local where = string.format("SalvagerDisenchantFrame drag step %d (%dx%d)", i, w, h)
            -- The size is the one dragged to: nothing snaps it back or widens it.
            assert.are.equal(w, win:GetWidth(), where .. ": width")
            assert.are.equal(h, win:GetHeight(), where .. ": height")
            local b, r, f = rect(P.bags), rect(P.results), rect(win)
            -- The bags table stays at the top; the results table ends over the footer; both reach the right edge.
            assert.is_true(math.abs((f.t - b.t) - (last and last.top or (f.t - b.t))) < EPS, where .. ": the top table moved")
            assert.is_true(math.abs(r.b - f.b - 44) < EPS, where .. ": the results table's bottom")
            assert.is_true(math.abs(f.r - b.r - 12) < EPS and math.abs(f.r - r.r - 12) < EPS, where .. ": the right edges")
            -- Taller window, taller (or as tall) tables; lower, lower.
            if last then
                local up = h >= last.h
                assert.is_true(up and b.h >= last.bh - EPS or (not up and b.h <= last.bh + EPS), where .. ": the top table")
                assert.is_true(up and r.h >= last.rh - EPS or (not up and r.h <= last.rh + EPS), where .. ": the results")
            end
            last = { top = f.t - b.t, h = h, bh = b.h, rh = r.h }
            problems(win, where, seen, false)
        end)
        LW.Batch = realBatch
        assert.are.equal(0, batches, "the batch was read again during the drag")
        assert.is_true(P.layouts >= layouts + #steps, "the tables were not laid out on each step")
        -- After the mouse is let go, the width holds, through a refresh (a bag update) too.
        local w = win:GetWidth()
        P.Refresh()
        sized(win)
        assert.are.equal(w, win:GetWidth())
        assert.are.equal("", table.concat(seen, "\n"))
    end)
    it("moves the border of the Disenchant panel's tables with the bar, from where it was grabbed (no jump)", function()
        ns.DisenchantPanel.Show()
        local win, P = _G.SalvagerDisenchantFrame, ns.DisenchantPanel
        win.saved.split = nil
        default(win)
        local bar, bags = P.splitBar, P.bags
        local real = _G.GetCursorPosition
        local y0 = rect(bar).t - 11   -- (grabbed in the bar's middle)
        local cursor = y0
        _G.GetCursorPosition = function() return 600, cursor end
        local h0 = rect(bags).h
        bar.scripts.OnMouseDown(bar, "LeftButton")
        bar.scripts.OnUpdate(bar, 0.01)
        sized(win)
        assert.is_true(math.abs(rect(bags).h - h0) <= 1, "the border jumped at the grab: " .. h0 .. " -> " .. rect(bags).h)
        local prev = rect(bags).h
        for k = 1, 6 do
            cursor = y0 - 15 * k   -- (down: the top table grows with the cursor)
            bar.scripts.OnUpdate(bar, 0.01)
            sized(win)
            local now = rect(bags).h
            assert.is_true(now >= prev - EPS, "step " .. k .. ": " .. prev .. " -> " .. now)
            assert.is_true(math.abs((h0 + 15 * k) - now) <= 1 or now <= prev + EPS, "step " .. k .. " follows the cursor")
            prev = now
        end
        bar.scripts.OnMouseUp(bar, "LeftButton")
        _G.GetCursorPosition = real
        win.saved.split = nil
        P.Refresh()
    end)
    it("lays the Odds cards two per row at the default width, one per row at the smallest (SDD 114)", function()
        local seen = {}
        for _, both in ipairs({ false, true }) do
            ns.Odds.Filter().both = both or nil
            ns.Odds.Filter().dataOnly = nil
            for _, case in ipairs({
                { "SalvagerReportsFrame", function() ns.Reports.ShowView("odds") end, function() return ns.Reports.oddsView end },
                { "SalvagerOddsFrame", function() ns.Odds.PopOut() end, function() return ns.Odds.out end } }) do
                ns.UI.Show()
                case[2]()
                local win, odds = _G[case[1]], case[3]()
                default(win)
                local where = case[1] .. (both and " (with and without the Salvager)" or "")
                assert.are.equal(2, odds.stack.perRow, where .. " at the default width")
                problems(win, where .. " default", seen, true)
                smallest(win)
                assert.are.equal(1, odds.stack.perRow, where .. " at the smallest width")
                problems(win, where .. " smallest", seen, false)
                -- Two cards of a row share its width; each card's columns end at its right edge (problems, above).
                default(win)
                local a, b = odds.stack.cards[3], odds.stack.cards[4]   -- (Armor, Uncommon, then the first two bands)
                assert.is_true(a.data.pair and b.data.pair)
                assert.are.equal(a:GetWidth(), b:GetWidth())
                assert.are.equal(a:GetTop(), b:GetTop())
                assert.is_true(b:GetLeft() > a:GetRight())
                -- The column titles of a card do not overlap; each line lies between the two columns it parts (one
                -- before Results, one more before the Salvager's columns while both show).
                local heads, lines = {}, 0
                for i, h in ipairs(a.headTexts) do if h:IsShown() then heads[#heads + 1] = { i = i, r = rect(h) } end end
                for k = 2, #heads do
                    assert.is_true(heads[k].r.l >= heads[k - 1].r.r - EPS, where .. ": titles " .. heads[k - 1].i
                        .. " and " .. heads[k].i .. " overlap")
                end
                for _, t in ipairs(a.seps) do
                    if t:IsShown() then
                        lines = lines + 1
                        local x = rect(t).l
                        local after
                        for k = 2, #heads do if heads[k].r.l >= x then after = k break end end
                        assert.is_true(after ~= nil and heads[after - 1].r.r <= x + EPS, where .. ": a line inside a column")
                    end
                end
                assert.are.equal(both and 2 or 1, lines, where .. ": the lines")
                if case[1] == "SalvagerOddsFrame" then ns.Odds.PutBack() end
            end
        end
        ns.Odds.Filter().both = nil
        assert.are.equal("", table.concat(seen, "\n"))
    end)
    it("resizes the Odds smoothly both ways: one or two cards per row as the width allows, nothing jumps back", function()
        local seen = {}
        for _, both in ipairs({ false, true }) do
            ns.Odds.Filter().both = both or nil
            for _, case in ipairs({
                { "SalvagerReportsFrame", function() ns.Reports.ShowView("odds") end, function() return ns.Reports.oddsView end },
                { "SalvagerOddsFrame", function() ns.Odds.PopOut() end, function() return ns.Odds.out end } }) do
                ns.UI.Show()
                case[2]()
                local win, odds = _G[case[1]], case[3]()
                default(win)
                local lo, loH, hi = win:GetResizeBounds()
                local stack = odds.stack
                assert.is_true(hi > lo, case[1] .. " " .. lo .. " " .. hi)
                -- The narrowest width with two per row: what the stack says two need.
                local two = stack.fitWidth + 24
                local steps = {}
                for k = 0, 12 do steps[#steps + 1] = { hi - (hi - lo) * k / 12, loH + 200 - 10 * k } end
                for k = 11, 0, -1 do steps[#steps + 1] = { hi - (hi - lo) * k / 12, loH + 200 - 10 * k } end
                local cards, realCards = 0, ns.Odds.Cards
                ns.Odds.Cards = function(...) cards = cards + 1 return realCards(...) end
                local prev, flips = nil, 0
                drag(win, steps, function(i, w, h)
                    local where = string.format("%s%s drag step %d (%dx%d)", case[1], both and " (both)" or "", i, w, h)
                    assert.are.equal(w, win:GetWidth(), where .. ": width")
                    -- Two per row exactly where two fit, from the window's width (not the width before).
                    assert.are.equal(w >= two - 1 and 2 or 1, stack.perRow, where .. ": cards per row (two need " .. two .. ")")
                    if prev and prev ~= stack.perRow then flips = flips + 1 end
                    prev = stack.perRow
                    -- No card reaches past the scroll bar.
                    local sr = rect(stack)
                    for _, c in ipairs(stack.cards) do
                        if c:IsShown() and c.data and not c.data.heading then
                            local cr = rect(c)
                            assert.is_true(cr.r <= sr.r - 18 + EPS, where .. ": a card past the scroll bar")
                        end
                    end
                    problems(win, where, seen, false)
                end)
                ns.Odds.Cards = realCards
                assert.are.equal(0, cards, case[1] .. ": the cards were built again during the drag")
                assert.are.equal(2, flips, case[1] .. ": one or two per row changed " .. flips .. " times (down, then up)")
                -- Let go at a width: it holds through a refresh (an event that draws the cards again).
                local w = win:GetWidth()
                ns.Odds.Refresh()
                sized(win)
                assert.are.equal(w, win:GetWidth(), case[1] .. ": the width after a refresh")
                if case[1] == "SalvagerOddsFrame" then ns.Odds.PutBack() end
            end
        end
        ns.Odds.Filter().both = nil
        assert.are.equal("", table.concat(seen, "\n"))
    end)
    it("shows the gold in full right next to the bag space, as wide as its text, at any amount (0.3.151)", function()
        ns.UI.Show()
        local win, gold, bags = _G.SalvagerFrame, ns.UI.gold, ns.UI.bags
        local seen = {}
        for _, money in ipairs({ 0, 123456, 99999999, 2147483647 }) do
            env.money = money
            ns.UI.Refresh()
            smallest(win)
            local g, b = rect(gold), rect(bags)
            assert.is_false(wow.isCut(gold), gold:GetText())
            assert.is_false(wow.isCut(bags), bags:GetText())
            -- Each box is its text (and 4 px): the gold's text ends 8 px before the bag space's text starts.
            for _, r in ipairs({ gold, bags }) do
                assert.is_true(math.abs(rect(r).w - (r:GetStringWidth() + 4)) <= 1, tostring(r:GetText()))
            end
            assert.is_true(math.abs(b.l - g.r - 8) <= EPS, string.format("%.0f..%.0f, then %.0f", g.l, g.r, b.l))
            problems(win, "SalvagerFrame with " .. money .. "c", seen, false)
        end
        assert.are.equal("", table.concat(seen, "\n"))
    end)
    it("has the mini panel in two columns of buttons, Disenchant across both under them (SDD 114)", function()
        ns.MiniPanel.Show()
        local b = ns.MiniPanel.buttons
        local function r(n) return rect(b[n]) end
        for _, col in ipairs({ { "Salvager", "Ledger", "Materials" }, { "Reports", "Market", "Log" } }) do
            for i = 2, 3 do
                assert.is_true(math.abs(r(col[i]).l - r(col[1]).l) < EPS, col[i] .. " under " .. col[1])
                assert.is_true(r(col[i]).t <= r(col[i - 1]).b + EPS, col[i] .. " below " .. col[i - 1])
            end
        end
        for i, left in ipairs({ "Salvager", "Ledger", "Materials" }) do
            local right = ({ "Reports", "Market", "Log" })[i]
            assert.is_true(math.abs(r(left).t - r(right).t) < EPS, left .. " and " .. right .. " on one row")
            assert.is_true(r(right).l > r(left).r, right .. " right of " .. left)
        end
        assert.is_true(r("Disenchant").t <= r("Materials").b + EPS)
        assert.is_true(math.abs(r("Disenchant").l - r("Materials").l) < EPS)
        assert.is_true(math.abs(r("Disenchant").r - r("Log").r) < EPS)
        -- The Reports button opens the Reports on the tab seen last (the Odds here).
        ns.Reports.ShowView("odds")
        ns.Reports.Toggle()
        b.Reports:Click()
        assert.is_true(_G.SalvagerReportsFrame:IsShown())
        assert.are.equal("odds", ns.Reports.view)
        assert.is_true(ns.Reports.tabs.odds.selected)
        ns.Reports.Toggle()
    end)
    it("drew the Disenchant panel with pieces and results", function()
        local top, bottom = ns.DisenchantPanel.Rows()
        assert.is_true(#top >= 24)
        assert.is_true(#bottom >= 3)
        assert.is_true(ns.DisenchantPanel.lootNote:IsShown())
    end)
    it("says so where a table leaves columns out for want of room, and fits them where it can", function()
        local W = ns.Widgets
        local parent = CreateFrame("Frame", nil, UIParent)
        parent:SetSize(300, 200)
        parent:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        local l = W.List(parent)
        l:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
        l:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", 0, 0)
        l:SetColumns({ { "Gear", 100 }, { "Paid", 80, "RIGHT" }, { "Expected value", 80, "RIGHT" },
            { "Disenchant value", 80, "RIGHT" }, { "Profit", 80, "RIGHT" } })
        l:SetSource(1, function() return { cells = { NAMES[2], ns.Money(BIG), ns.Money(BIG), ns.Money(BIG), ns.Money(BIG) } } end)
        l:Refresh()
        local note = l.leftOutNote
        assert.is_true(#l.leftOut > 0)
        assert.is_true(note:IsShown())
        assert.are.equal(#l.leftOut .. (#l.leftOut == 1 and " column" or " columns") .. " left out", note:GetText())
        assert.is_false(wow.isCut(note))
        -- The note sits after the last column shown, before the scroll bar.
        local last
        for i, h in ipairs(l.headers) do if h:IsShown() and l.columns[i] then last = rect(h) end end
        assert.is_true(last.r <= rect(note).l + EPS and rect(note).r <= rect(l).r - 18 + EPS)
        -- As wide as it needs (what a window that fits its tables does): nothing left out, no note.
        parent:SetWidth(l.fitWidth)
        l:Refresh()
        assert.are.same({}, l.leftOut)
        assert.is_false(note:IsShown())
        parent:Hide()
    end)
end)

describe("Every window fits its texts with no data at all (an empty table says why in full, UI.md Tables 6)", function()
    it("draws every view at its smallest and its default size without a cut note", function()
        wow.install({ layout = true })
        local ns = wow.loadAddon()
        ns_ = ns
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        local mat = ns.Data.MATERIALS[1].id
        local open = {
            SalvagerFrame = function() ns.UI.Show() end,
            SalvagerLedgerFrame = function() ns.LedgerWindow.Show() end,
            SalvagerOddsFrame = function() ns.Odds.PopOut() end,
            SalvagerMarketFrame = function() if not (_G.SalvagerMarketFrame or {}).shown then ns.Market.Toggle() end end,
            SalvagerReportsFrame = function() ns.Reports.Show() end,
            SalvagerLogFrame = function() ns.LogWindow.Show() end,
            SalvagerBreakdownFrame = function() ns.Breakdown.Open(mat) end,
            SalvagerDisenchantFrame = function() ns.DisenchantPanel.Show() end,
        }
        local found = {}
        for _, global in ipairs(WINDOWS) do
            if open[global] then
                ns.UI.Show()
                open[global]()
                local win = _G[global]
                assert.is_true(win ~= nil and win:IsShown(), global .. " is not open")
                for _, size in ipairs({ "smallest", "default" }) do
                    local function fit()
                        local bounds = rawget(win, "_bounds")
                        if size == "smallest" then
                            local minW = bounds and bounds[1] or rawget(win, "minWidth") or win:GetWidth()
                            rawset(win, "userW", minW)
                            win:SetSize(minW, bounds and bounds[2] or win:GetHeight())
                        else
                            rawset(win, "userW", nil)
                            win:SetSize(rawget(win, "_firstW") or win:GetWidth(), rawget(win, "_firstH") or win:GetHeight())
                        end
                        sized(win)
                    end
                    local function look(where)
                        fit()
                        problems(win, global .. " (no data, " .. size .. ")" .. where, found, false)
                    end
                    look("")
                    for _, tab in ipairs(tabsOf(win, "tab")) do
                        tab:Click()
                        look(" / " .. tostring(tab.text))
                        for _, sub in ipairs(tabsOf(win, "subtab")) do
                            sub:Click()
                            look(" / " .. tostring(tab.text) .. " / " .. tostring(sub.text))
                        end
                    end
                end
            end
        end
        assert.are.equal("", table.concat(found, "\n"))
    end)
end)

describe("A dropdown shows every value it can take in full (UI.md Controls 5)", function()
    it("fits each choice of its options (Gear, Quality, Bands: any of them ticked) in the game's font", function()
        local env = wow.install({ layout = true })
        local ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        assert.is_true(#seed(env, ns) > 0)
        ns.UI.Show()
        ns.LedgerWindow.Show()
        ns.Reports.Show()
        ns.Odds.PopOut()
        ns.LogWindow.Show()
        ns.Options.Open()
        if not (_G.SalvagerMarketFrame or {}).shown then ns.Market.Toggle() end
        local MULTI = { Gear = true, Quality = true, Bands = true }
        local cut, seenDrops = {}, 0
        for _, d in ipairs(env.frames) do
            local opts = rawget(d, "uiKind") == "dropdown" and rawget(d, "options")
            if opts then
                seenDrops = seenDrops + 1
                local summary, n = rawget(d, "summary"), #opts
                local function text(picked)
                    local names = {}
                    for i = 1, n do if picked[i] then names[#names + 1] = opts[i][2] end end
                    return summary and summary(names, n) or (#names > 0 and table.concat(names, ", ") or "none")
                end
                local function try(picked)
                    local t = text(picked)
                    -- (The game's dropdown writes its value in GameFontHighlight, 12 pt; 32 px go to its edges and arrow.)
                    local need = wow.textWidth(t, 12) + 32
                    if need > d.maxWidth + EPS then
                        cut[#cut + 1] = string.format("%s \"%s\": %.0f px in %d", tostring(d.title), t, need, d.maxWidth)
                    end
                end
                for i = 1, n do try({ [i] = true }) end
                if MULTI[d.title or ""] then
                    -- Every choice of up to three, and all but one (more names make a longer text, unless the summary
                    -- shortens them).
                    for i = 1, n do for j = i + 1, n do
                        try({ [i] = true, [j] = true })
                        for k = j + 1, n do try({ [i] = true, [j] = true, [k] = true }) end
                    end end
                    for i = 1, n do
                        local all = {}
                        for k = 1, n do all[k] = k ~= i end
                        try(all)
                    end
                    local all = {}
                    for k = 1, n do all[k] = true end
                    try(all)
                end
            end
        end
        assert.is_true(seenDrops >= 10, seenDrops .. " dropdowns")
        local seen, out = {}, {}
        for _, c in ipairs(cut) do if not seen[c] then seen[c] = true out[#out + 1] = c end end
        assert.are.equal("", table.concat(out, "\n"))
    end)
end)

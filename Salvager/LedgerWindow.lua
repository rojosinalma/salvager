-- Salvager: the Ledger window. A window of its own (move it, resize it), with three views:
--   Purchases: every item bought, and under it what it was disenchanted into.
--   Sales:     every material sale, with its profit against what the materials cost you.
--   Odds:      per item level band, what your disenchants gave against the table, the buy limit and its risk.
local _, ns = ...

local Ledger, Data, Model, W = ns.Ledger, ns.Data, ns.Model, ns.Widgets

local Window = { view = "sales" }
ns.LedgerWindow = Window

local GREY, GOLD, GREEN, RED = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040"
local PROFIT_HELP = { "Profit", "What you got after the cut minus what the materials cost you, for the units with a "
    .. "known cost only. \"+3?\" in Cost = 3 units with no recorded cost, left out. An auction that expired or was "
    .. "cancelled shows the deposit the auction house kept, as a loss." }
local INDENT = 22
local ODDS_INDENT = 12   -- each level of the Odds cards (gear type, quality, band) sits in this much
-- The longest countdown (an auction runs up to 48 hours): the Time columns keep this width while they count.
local COUNTDOWN_MAX = "00:00:00"

local COLUMNS = {
    purchases = { { "Item", 220 }, { "Bought", 82 }, { "Paid", 84, "RIGHT" },
        { "Expected value", 84, "RIGHT", help = { "Expected value", "The value the Deals list showed when you "
            .. "bought: the average disenchant value at the prices of that moment, after the auction house cut." } },
        { "Disenchant value", 96, "RIGHT", help = { "Disenchant value", "The market value of the materials you got, "
            .. "at the prices of the moment you disenchanted, after the auction house cut." } },
        { "Profit", 84, "RIGHT", help = { "Profit", "Disenchant value minus Paid." } } },
    -- The Purchases view's second subtab: what waits in the mail.
    waiting = { { "Item", 220 },
        { "Item level", 60, "CENTER", help = { "Item level", "The item's level, as the Deals list judged it when you bought." } },
        { "Bought", 82 }, { "Paid", 84, "RIGHT" },
        { "Expected value", 84, "RIGHT", help = { "Expected value", "The value the Deals list showed when you "
            .. "bought: the average disenchant value at the prices of that moment, after the auction house cut." } } },
    -- The Accuracy view is two tables: by band, and by material.
    accBands = { { "Band", 170 }, { "Items", 44, "CENTER", help = { "Items", "How many disenchants with a recorded "
            .. "purchase are in the row. Grey = fewer than 20: too few to judge, one lucky shard moves it a lot." } },
        { "Paid", 70, "RIGHT" },
        { "Expected value", 70, "RIGHT", help = { "Expected value", "The Value the Deals list showed when you bought: "
            .. "the average disenchant value at the material prices of that moment, after the auction house cut." } },
        { "Disenchant value", 70, "RIGHT", help = { "Disenchant value", "The market value of the materials you got, "
            .. "at the prices of the moment you disenchanted, after the auction house cut." } },
        { "Diff", 46, "RIGHT", help = { "Disenchant value against Expected value", "How far the disenchant value is "
            .. "from the expected value. The gap is drop luck, or drop rates that are not what the addon assumes." } },
        { "Sold value", 70, "RIGHT", help = { "Sold value", "The same materials at the average price each one really "
            .. "sold for, after the auction house cut. Materials you have not sold yet count at their disenchant value." } },
        { "Diff", 46, "RIGHT", help = { "Sold value against Disenchant value", "How far the sold value is from the "
            .. "disenchant value. The gap is prices that moved, and undercutting. * = more than half of the row's "
            .. "materials are not sold yet, so most of it is still the disenchant value." } },
        { "Expected profit", 70, "RIGHT", help = { "Expected profit", "Expected value minus Paid." } },
        { "Actual profit", 70, "RIGHT", help = { "Actual profit", "Sold value minus Paid." } },
        { "Profit difference", 70, "RIGHT", help = { "Profit difference", "Actual profit minus Expected profit: how "
            .. "much more (+) or less (-) the items made than the Deals list said when you bought them." } } },
    accMats = { { "Material", 170 }, { "Units", 44, "CENTER" },
        { "Disenchant value each", 80, "RIGHT", help = { "Disenchant value each", "The average market price of one "
            .. "unit at the moment you disenchanted, after the auction house cut." } },
        { "Sold value each", 80, "RIGHT", help = { "Sold value each", "The average of what one unit really brought "
            .. "in your sales, after the auction house cut." } },
        { "Difference", 80, "RIGHT", help = { "Difference", "Sold value each minus Disenchant value each." } },
        { "Diff", 46, "RIGHT", help = { "Difference in percent", "The same difference as a share of the disenchant value." } },
        { "Units sold", 70, "CENTER" } },
    -- The Sales view is two tables: your auctions, and the sales already paid.
    listed = { { "Material", 150 }, { "Status", 110 },
        { "Time", 62, "RIGHT", sample = COUNTDOWN_MAX, help = { "Time", "A sold auction: the time until its money arrives by mail. "
            .. "An auction still for sale: the time until it ends. It counts down from the last time the addon read "
            .. "your auctions (see \"as of\" above)." } },
        { "Each", 64, "RIGHT" }, { "Price", 76, "RIGHT" },
        { "You get", 76, "RIGHT" }, { "Cost", 84, "RIGHT" }, { "Profit", 76, "RIGHT" } },
    history = { { "Material", 150 }, { "Sold", 110 },
        { "Collected", 110, "LEFT", help = { "Collected", "When you took the money of this sale from the mail." } },
        { "Each", 64, "RIGHT" }, { "Price", 76, "RIGHT" },
        { "You got", 76, "RIGHT" }, { "Cost", 84, "RIGHT" }, { "Profit", 76, "RIGHT", help = PROFIT_HELP } },
    paid = { { "Material", 150 }, { "Sold", 110 },
        { "Time", 62, "RIGHT", sample = COUNTDOWN_MAX, help = { "Time", "The time until the money of this sale arrives by mail." } },
        { "Each", 64, "RIGHT" }, { "Price", 76, "RIGHT" },
        { "You get", 76, "RIGHT" }, { "Cost", 84, "RIGHT" }, { "Profit", 76, "RIGHT", help = PROFIT_HELP } },
}

local f, list, summary, tabs = nil, nil, nil, {}
local newOddsView
local checkButton, cancelButton
local oddsView          -- the Odds view in the ledger window: its filters and one table per band
local oddsFrame, oddsOut -- the odds in a window of their own
local popOut            -- the button next to the Odds tab that moves them there and back
local salesParts = {}   -- title, table, title, table of the Sales view
local purchaseControls = {} -- the Purchases view's search box and filters
local accuracyControls = {} -- the Accuracy view's filters
local salesTabs = {}    -- the Sales view's subtabs: open and sold, history
local purchaseTabs = {} -- the Purchases view's subtabs: all purchases, not picked up
local bagLabel, bagArea -- the Purchases view's bag space, on its subtab row

--- Which bands the Odds view shows: { quality = { [2], [3], [4] }, type = { a, w } }, kept with the window.
--- A filter set as every view keeps it: gear types, qualities, item level bands left out, Salvager
--- ("all" | "with" | "without"), and the closed headings. Missing parts are filled in.
local function filterSet(x)
    x.classes = x.classes or { [Data.CLASS_ARMOR] = true, [Data.CLASS_WEAPON] = true }
    x.qualities = x.qualities or { [2] = true, [3] = true, [4] = true }
    x.bandsOff = x.bandsOff or {}
    x.salvager = x.salvager or "all"
    x.collapsed = x.collapsed or {}
    return x
end

--- Does a thing of this gear type, quality, item level (and Salvager) pass the filter? Unknown parts pass.
-- The Purchases view's search and filters (in the window's saved data): text in the item's name, gear types,
-- qualities, item level bands left out.
local function purchaseFilter()
    ns.db.windows.ledger = ns.db.windows.ledger or {}
    local saved = ns.db.windows.ledger
    saved.purchaseFilter = saved.purchaseFilter or {}
    local x = filterSet(saved.purchaseFilter)
    x.open = x.open or {}
    return x
end
Window.PurchaseFilter = purchaseFilter

local function filterPasses(x, classID, quality, ilvl, salvager)
    if classID and not x.classes[classID] then return false end
    if quality and not x.qualities[quality] then return false end
    if x.salvager == "with" and salvager == false then return false end
    if x.salvager == "without" and salvager == true then return false end
    if ilvl then
        for _, b in ipairs(ns.LevelBands()) do
            if ilvl <= b.up then return not x.bandsOff[b.up] end
        end
    end
    return true
end
Window.FilterPasses = filterPasses

--- The filter row every view has: Gear, Quality, Bands (and Salvager with `salvager`), after `after` (a
--- region) or at `point` = { x, y } of `parent`. `changed()` runs after each change.
--- @return table controls, region the last one
local function filterRow(parent, x, changed, point, salvager)
    local controls, prev = {}, nil
    local function setOf(tbl, invert, all)
        return function(key) if invert then return not tbl[key] end return tbl[key] and true or false end,
            function(key, on)
                if invert then tbl[key] = (not on) or nil else tbl[key] = on or nil end
                local any = false
                for _, k in ipairs(all) do if (invert and not tbl[k]) or (not invert and tbl[k]) then any = true end end
                if not any then
                    if invert then tbl[key] = nil else tbl[key] = true end
                    ns.Print("at least one must stay ticked")
                end
                changed()
            end
    end
    local function allOr(names, total) return #names == total and "All" or table.concat(names, ", ") end
    local function add(label, drop, help)
        local l = W.Label(parent, label, "GameFontHighlightSmall")
        if prev then
            l:SetPoint("LEFT", prev, "RIGHT", 14, 0)
        elseif type(point) == "table" and point.GetObjectType then
            l:SetPoint("LEFT", point, "RIGHT", 14, 0)
        else
            l:SetPoint("LEFT", parent, "TOPLEFT", point[1], point[2])
        end
        drop:SetPoint("LEFT", l, "RIGHT", 6, 0)
        -- (The help area hides with its label, so it never covers the table of another subtab or view.)
        controls[#controls + 1] = W.HelpArea(parent, l, label, help)
        controls[#controls + 1] = l
        controls[#controls + 1] = drop
        prev = drop
    end
    local gGet, gSet = setOf(x.classes, false, { Data.CLASS_ARMOR, Data.CLASS_WEAPON })
    add("Gear", W.CheckDropdown(parent, 100, { { Data.CLASS_ARMOR, "Armor" }, { Data.CLASS_WEAPON, "Weapons" } }, gGet, gSet,
        "Which gear types show.", "Gear", allOr), "Armor, weapons, or both.")
    local qGet, qSet = setOf(x.qualities, false, { 2, 3, 4 })
    add("Quality", W.CheckDropdown(parent, 130, { { 2, "|cff1eff00Uncommon|r" }, { 3, "|cff0070ddRare|r" },
        { 4, "|cffa335eeEpic|r" } }, qGet, qSet, "Which qualities show.", "Quality", allOr), "Uncommon, Rare, Epic.")
    local bandOptions, bandKeys = {}, {}
    for _, b in ipairs(ns.LevelBands()) do
        bandOptions[#bandOptions + 1] = { b.up, b.label }
        bandKeys[#bandKeys + 1] = b.up
    end
    local bGet, bSet = setOf(x.bandsOff, true, bandKeys)
    add("Bands", W.CheckDropdown(parent, 120, bandOptions, bGet, bSet, "Which item level bands show.", "Bands",
        function(names, total)
            if #names == total then return "All" end
            if #names > 3 then return #names .. " bands" end
            return table.concat(names, ", ")
        end), "Item level bands: a band is a range of item levels that disenchants into the same materials.")
    if salvager then
        local drop
        drop = W.CheckDropdown(parent, 100, { { "all", "All" }, { "with", "With it" }, { "without", "Without it" } },
            function(key) return x.salvager == key end,
            function(key)
                x.salvager = key
                drop:Close()
                changed()
            end, "Disenchants with the Arcane Salvager's bonus, without it, or all.", "Salvager")
        add("Salvager", drop, "Disenchants with the Arcane Salvager's bonus, without it, or all.")
    end
    return controls, prev
end

--- The Odds view's filters (saved; the gear type was a subtab before 0.3.99, the qualities and bands
--- had keys of their own).
local function oddsFilter()
    local saved = ns.db.windows.ledger or {}
    ns.db.windows.ledger = saved
    if not saved.oddsFilter then
        saved.oddsFilter = { qualities = saved.oddsQuality, bandsOff = saved.oddsBandsOff,
            dataOnly = saved.oddsDataOnly }
        saved.oddsQuality, saved.oddsBandsOff, saved.oddsDataOnly, saved.oddsTab = nil, nil, nil, nil
    end
    return filterSet(saved.oddsFilter)
end
Window.OddsFilter = oddsFilter

local function when(t) return (t and t > 0) and date("%m-%d %H:%M", t) or "-" end
local function money(c) return c and ns.Money(c) or "-" end
local function signed(c)
    if not c then return "" end
    return (c >= 0 and GREEN or RED) .. ns.Money(c) .. "|r"
end
local function itemName(itemID, link)
    return link or (ns.GetItemInfo(itemID)) or ("item " .. tostring(itemID))
end
local function note(text) return { cells = { GREY .. text .. "|r" } } end

------------------------------------------------------------------ rows

--- Purchases: one row per item, its materials indented under it.

--- The Purchases view's order: { col, desc }, by Profit (the 6th column), the highest first, until a title
--- is clicked.
function Window.PurchaseSort()
    local x = purchaseFilter()
    if type(x.sort) ~= "table" or not tonumber(x.sort.col) then x.sort = { col = 6, desc = true } end
    return x.sort
end

--- An entry's gear type, quality and item level: from its record, else from its link.
local function describeEntry(e)
    local classID = e.classID or (e.itemID and ns.ClassOf(e.itemID))
    local quality = e.quality or (e.link and ns.QualityOf(e.link)) or (e.itemID and ns.Items.Quality(e.itemID))
    local ilvl = e.ilvl or e.band or (e.link and ns.ItemLevelOf(e.link))
    return classID, quality, ilvl
end

local function passes(e, x, search)
    if x.hideWaiting and not e.done then return false end
    local classID, quality, ilvl = describeEntry(e)
    if not filterPasses(x, classID, quality, ilvl) then return false end
    if search ~= "" then
        local name = (e.link and e.link:match("%[(.-)%]")) or (ns.GetItemInfo(e.itemID)) or ""
        if not name:lower():find(search, 1, true) then return false end
    end
    return true
end

--- Every item bought, one row per item name (newest first), with its totals. A click opens it: each
--- purchase under it, with what it gave. The search and the filters pick which items show.
function Window.PurchaseRows()
    local x = purchaseFilter()
    local search = (x.search or ""):lower()
    local groups, order = {}, {}
    for _, e in ipairs(Ledger.History(ns.db.ledger)) do
        if passes(e, x, search) then
            local key = tostring(e.itemID)
            local g = groups[key]
            if not g then
                g = { itemID = e.itemID, link = e.link, list = {}, paid = 0, known = 0, expected = 0, got = 0, done = 0,
                    result = 0, salvager = 0, last = e.boughtAt or e.t }
                groups[key] = g
                order[#order + 1] = g
            end
            g.list[#g.list + 1] = e
            if e.paid then g.paid, g.known = g.paid + e.paid, g.known + 1 end
            g.expected = g.expected + (e.expected or 0)
            if e.done then g.got, g.done = g.got + (e.got or 0), g.done + 1 end
            if e.result then g.result = g.result + e.result end
            if e.salvager then g.salvager = g.salvager + 1 end
        end
    end
    -- Items in the order of the column picked (a click on its title), the best profit first by default.
    -- The purchases under an item keep their own order (newest first).
    local sort = Window.PurchaseSort()
    local keyOf = {
        function(g) return (itemName(g.itemID, g.link):match("%[(.-)%]") or itemName(g.itemID, g.link)):lower() end,
        function(g) return g.last or 0 end,
        function(g) return g.known > 0 and g.paid or -math.huge end,
        function(g) return g.expected end,
        function(g) return g.done > 0 and g.got or -math.huge end,
        function(g) return g.known > 0 and g.result or -math.huge end,
    }
    local key = keyOf[sort.col] or keyOf[6]
    for i, g in ipairs(order) do g.index = i end
    table.sort(order, function(a, b)
        local ka, kb = key(a), key(b)
        if ka == kb then return a.index < b.index end
        if sort.desc then return ka > kb end
        return ka < kb
    end)
    local rows = {}
    for _, g in ipairs(order) do
        local open = x.open[g.itemID] and true or false
        local n = #g.list
        rows[#rows + 1] = {
            itemID = g.itemID, link = g.link, group = true, open = open,
            onClick = function()
                x.open[g.itemID] = (not open) or nil
                Window.Refresh()
            end,
            cells = {
                itemName(g.itemID, g.link) .. GREY .. "  x" .. n .. "|r"
                    .. (g.salvager > 0 and ("  |cff9370db[Salvager " .. g.salvager .. "]|r") or ""),
                when(g.last), g.known > 0 and ns.Money(g.paid) or (GREY .. "not recorded|r"), money(g.expected),
                g.done > 0 and money(g.got) or (GREY .. "not disenchanted|r"), g.known > 0 and signed(g.result) or "",
            },
        }
        if open then
            for _, e in ipairs(g.list) do
                local gave = {}
                for _, m in ipairs(e.mats or {}) do gave[#gave + 1] = m.qty .. "x " .. ns.MaterialName(m.id) end
                local what = e.done and table.concat(gave, ", ")
                    or (GREY .. (ns.NoDisenchant(e.itemID) and "cannot be disenchanted" or "not disenchanted") .. "|r")
                rows[#rows + 1] = {
                    indent = INDENT, link = e.link,
                    cells = { what .. (e.salvager and "  |cff9370db[Salvager]|r" or ""),
                        when(e.boughtAt or (not e.done and e.t) or nil),
                        e.paid and ns.Money(e.paid) or (GREY .. "not recorded|r"), money(e.expected),
                        e.done and money(e.got) or "", signed(e.result) },
                }
            end
        end
    end
    if #rows == 0 then
        rows[1] = note((search ~= "" or next(x.bandsOff)) and "No purchase matches the search and the filters."
            or "Nothing yet. Buy from the Deals tab, or take your \"Auction won\" mail, then disenchant.")
    end
    return rows
end

--- The Purchases view's subtab: "all" (every purchase) or "mail" (not picked up), kept with the window.
function Window.PurchaseTab()
    local saved = ns.db.windows.ledger
    return (saved and saved.purchaseTab == "mail") and "mail" or "all"
end

--- What waits in the mail: the count and the price paid of the purchases whose "Auction won" mail is not
--- taken yet.
--- @return number count, number paid
function Window.NotPickedUpTotal()
    local n, paid = 0, 0
    for _, b in ipairs(Ledger.NotPickedUp(ns.db.ledger)) do n, paid = n + 1, paid + (b.each or 0) end
    return n, paid
end

--- The purchases made at the auction house whose "Auction won" mail is not taken yet, oldest first (its
--- mail came first, and goes first when the mail runs out of time). A heading row has the count and totals.
function Window.NotPickedUpRows()
    local rows, waiting = {}, Ledger.NotPickedUp(ns.db.ledger)
    if #waiting == 0 then
        rows[1] = note("Nothing waits in the mail. A purchase made with Buy shows here until you take its "
            .. "\"Auction won\" mail.")
        return rows
    end
    local paid, ev, evMissing = 0, 0, false
    for _, b in ipairs(waiting) do
        paid = paid + (b.each or 0)
        if b.ev then ev = ev + b.ev else evMissing = true end
    end
    rows[1] = { group = true, cells = { GOLD .. #waiting .. (#waiting == 1 and " item" or " items") .. " in the mail|r", "", "",
        ns.Money(paid), ns.Money(ev) .. (evMissing and (GREY .. "?|r") or "") } }
    for _, b in ipairs(waiting) do
        local ilvl = (b.j and b.j.ilvl) or (b.link and ns.ItemLevelOf(b.link)) or ns.db.ilvl[b.itemID]
        rows[#rows + 1] = {
            itemID = b.itemID, link = b.link,
            cells = { itemName(b.itemID, b.link), ilvl and tostring(ilvl) or (GREY .. "-|r"), when(b.t),
                ns.Money(b.each or 0), money(b.ev) },
        }
    end
    return rows
end

--- The bag space for gear, and a warning in words when what waits in the mail does not fit.
function Window.BagText()
    local free, total = ns.Items.BagSpace()
    local waiting = Window.NotPickedUpTotal()
    local text = string.format("%sBag space|r %d free of %d", GOLD, free, total)
    if waiting > free then
        text = text .. string.format("  %snot enough for the %d %s in the mail|r", RED, waiting,
            waiting == 1 and "item" or "items")
    end
    return text
end

--- A countdown: "44:05", or "23:10:42" from one hour up.
local function countdown(seconds)
    if not seconds then return GREY .. "?|r" end
    seconds = math.max(0, math.floor(seconds))
    local h, m, sec = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
    return string.format("%d:%02d", m, sec)
end

--- Your auctions as last read: what is listed, what is sold and waiting for its money.
function Window.ListingRows()
    local rows = {}
    local l = ns.db.listings
    local mine = l.rows or {}
    if #mine == 0 then
        rows[1] = note(l.t and "Nothing listed." or "Not read yet: open the auction house.")
        return rows
    end
    -- Only the auctions still for sale. (The game keeps a sold auction in its list until the money is
    -- mailed; those show in the table of sold auctions, as sales.)
    for _, r in ipairs(mine) do
      if not r.sold then
        local gross = r.qty * r.each
        local net = math.floor(gross * (1 - ns.Cut()) + 0.5)
        local avg = Ledger.AvgCost(ns.db.ledger, r.itemID)
        local cost = avg and math.floor(avg * r.qty + 0.5) or nil
        local left = ns.Listings.TimeLeft(r)
        local status
        local under, lowest = ns.Listings.Undercut(r), ns.Listings.Lowest(r)
        if under then
            status = RED .. "undercut by " .. ns.Money(under) .. "|r"
        elseif lowest == false then
            status = GREEN .. "only yours|r"
        elseif lowest then
            status = GREEN .. "lowest|r"
        else
            status = "listed"
        end
        rows[#rows + 1] = {
            itemID = r.itemID, link = r.link,
            -- A click shows where it stands among the other sellers' listings.
            onClick = r.commodity and function() ns.Stand.Show(r) end or nil,
            cells = { r.qty .. "x " .. ((r.link and r.link:match("%[(.-)%]")) or ns.MaterialName(r.itemID)), status,
                countdown(left),
                ns.Money(r.each), ns.Money(gross), ns.Money(net), cost and ns.Money(cost) or (GREY .. "not known|r"),
                cost and signed(net - cost) or "" },
        }
      end
    end
    if #rows == 0 then rows[1] = note("No open auctions.") end
    return rows
end

--- Every sale, newest first. Profit = what you get after the cut - what those materials cost you.
--- A sale is booked when its listing is seen as sold; Time counts down to its money, "paid" = mail taken.
--- @param history boolean  true = the sales whose money you have taken; false = the ones still to collect
function Window.SoldRows(history)
    local rows = {}
    local sales = ns.db.ledger.sales
    -- A sale booked before the due time was kept: its time is the one of the sold auction it came from.
    local used = {}
    local function dueOf(s)
        if s.due then return s.due - time() end
        for _, r in ipairs(ns.db.listings.rows or {}) do
            if not used[r] and r.sold and r.itemID == s.id and r.qty == s.count and s.each and math.abs(s.each - r.each) < 1 then
                used[r] = true
                return ns.Listings.TimeLeft(r)
            end
        end
    end
    for i = #sales, 1, -1 do
      local s = sales[i]
      local due = (s.unpaid or 0) > 0
      if due ~= history then
        local tracked = s.count - (s.untracked or 0)
        if s.lost then
            -- An auction that expired or was cancelled: the deposit the auction house kept.
            rows[#rows + 1] = {
                itemID = s.id,
                cells = { (s.qty or 0) .. "x " .. ns.MaterialName(s.id), when(s.t),
                    GREY .. (s.lost == "cancelled" and "cancelled" or "expired") .. "|r", "", "",
                    signed(s.net), "", signed(s.profit) },
            }
        else
            local cost, profit
            if tracked <= 0 then
                cost, profit = GREY .. "not known|r", GREY .. "not known|r"
            else
                -- "+3?" = units with no known cost: they are left out of the profit.
                cost = ns.Money(s.cost) .. ((s.untracked or 0) > 0 and (GREY .. " +" .. s.untracked .. "?|r") or "")
                profit = signed(s.profit)
            end
            rows[#rows + 1] = {
                itemID = s.id,
                cells = { s.count .. "x " .. ns.MaterialName(s.id),
                    when(s.t),
                    due and (GOLD .. countdown(dueOf(s)) .. "|r") or (s.paidAt and when(s.paidAt) or (GREY .. "-|r")),
                    ns.Money(math.floor(s.gross / s.count + 0.5)),
                    ns.Money(s.gross), ns.Money(s.net), cost, profit },
            }
        end
      end
    end
    if #rows == 0 then
        rows[1] = note(history and "No sale collected yet. A sale comes here when you take its mail."
            or "No sale is waiting for its money.")
    end
    return rows
end

--- "+5%" in green, "-3%" in red: how far `part` is from `whole`.
local function share(part, whole)
    if not whole or whole == 0 then return GREY .. "-|r" end
    local pct = math.floor((part - whole) / whole * 100 + 0.5)
    return (pct > 0 and (GREEN .. "+") or pct < 0 and RED or GREY) .. pct .. "%|r"
end

--- Accuracy, by band: what was promised, what the disenchants gave, what the sales brought.
--- The Accuracy view's filters and closed headings (saved).
local function accuracyFilter()
    ns.db.windows.ledger = ns.db.windows.ledger or {}
    local saved = ns.db.windows.ledger
    saved.accuracyFilter = filterSet(saved.accuracyFilter or {})
    return saved.accuracyFilter
end
Window.AccuracyFilter = accuracyFilter

local function accuracyKeep(r)
    return filterPasses(accuracyFilter(), r.classID, r.quality, r.ilvl or r.band, r.salvager and true or false)
end

function Window.AccuracyBandRows()
    local acc = Ledger.Accuracy(ns.db.ledger, accuracyKeep)
    local rows = {}
    local function row(b, name, group)
        local few = b.n < 20
        rows[#rows + 1] = { group = group, cells = { name, (few and GREY or "") .. b.n .. (few and "|r" or ""),
            ns.Money(b.paid), ns.Money(b.promised), ns.Money(b.got), share(b.got, b.promised), ns.Money(b.sold),
            share(b.sold, b.got) .. ((b.units > 0 and b.soldUnits < b.units / 2) and (GREY .. "*|r") or ""),
            signed(b.promised - b.paid), signed(math.floor(b.sold + 0.5) - b.paid),
            signed(math.floor(b.sold + 0.5) - b.promised) } }
    end
    if acc.total.n == 0 then
        rows[1] = note("Nothing to compare yet, or nothing under these filters: it needs items you bought and then "
            .. "disenchanted.")
        return rows
    end
    row(acc.total, GOLD .. "All bands|r", true)
    -- Grouped the one way (ns.GroupedRows): gear type, quality, then each band by its range, with totals.
    local FIELDS = { "n", "paid", "promised", "got", "sold", "units", "soldUnits" }
    local function sum(bands)
        local t = {}
        for _, field in ipairs(FIELDS) do t[field] = 0 end
        for _, b in ipairs(bands) do for _, field in ipairs(FIELDS) do t[field] = t[field] + b[field] end end
        return t
    end
    local function made(b, name, group)
        row(b, name, group)
        local r = rows[#rows]
        rows[#rows] = nil
        return r
    end
    local opts = { collapsed = accuracyFilter().collapsed, changed = function() Window.Refresh() end }
    for _, r in ipairs(ns.GroupedRows(acc.bands, function(b) return made(b, "") end,
        function(of, label) return made(sum(of), label, true) end, INDENT, opts)) do
        rows[#rows + 1] = r
    end
    return rows
end

--- Accuracy, by material: the price it was valued at when disenchanted against what it really sold for.
function Window.AccuracyMaterialRows()
    local rows = {}
    for _, m in ipairs(Ledger.Accuracy(ns.db.ledger, accuracyKeep).mats) do
        local valued = m.units > 0 and m.valued / m.units or nil
        local sold = m.soldUnits > 0 and m.soldNet / m.soldUnits or nil
        rows[#rows + 1] = { itemID = m.id, cells = { ns.MaterialName(m.id), tostring(m.units),
            valued and ns.Money(valued) or (GREY .. "-|r"), sold and ns.Money(sold) or (GREY .. "not sold yet|r"),
            (valued and sold) and signed(sold - valued) or "", (valued and sold) and share(sold, valued) or "",
            m.soldUnits > 0 and tostring(m.soldUnits) or (GREY .. "0|r") } }
    end
    if #rows == 0 then rows[1] = note("No disenchant with a recorded purchase yet.") end
    return rows
end

--- Is a band of item levels lo..up inside one of the ticked item level ranges? The ranges are the
--- scan's level bands; a rare or epic band, which is wider, shows when it overlaps a ticked one.
local function levelShown(lo, up, off)
    local from = 1
    for _, range in ipairs(ns.LevelBands()) do
        if not off[range.up] and lo <= range.up and up >= from then return true end
        from = range.up + 1
    end
    return false
end

--- Odds: every item level band of every quality and gear type that the filters show, with the table
--- the addon uses and, where you have disenchanted, what you got.
--- @return table  bands { head = the band's row, rows = its material rows }, in the flat list's cell order
function Window.OddsBands()
    local bands = {}
    local by = Ledger.Report(ns.db.ledger, nil, function(r)
        local f0 = oddsFilter()
        return filterPasses(f0, nil, nil, nil, r.salvager and true or false)
    end)
    local s = ns.db.settings
    local opts = { salvager = ns.SalvagerForBuy(), salvagerChance = s.salvagerChance, cut = s.cut }
    local x = oddsFilter()
    for _, q in ipairs({ { 2, Data.GREEN }, { 3, Data.BLUE }, { 4, Data.PURPLE } }) do
        for _, c in ipairs({ { Data.CLASS_ARMOR }, { Data.CLASS_WEAPON } }) do
            local lo = 1
            for _, band in ipairs((x.qualities[q[1]] and x.classes[c[1]]) and q[2] or {}) do
                local quality, classID, up = q[1], c[1], band.up
                local inRange = levelShown(lo, up, x.bandsOff)
                lo = up + 1
                local outcomes = Model.Outcomes(quality, classID, up)
                local mine = by[Ledger.BandKey(quality, classID, up)]
                local n = mine and mine.n or 0
                if inRange and (n > 0 or not x.dataOnly) then
                    local v = Model.Value(outcomes, ns.PriceOf, opts)
                    local limit = ns.BuyLimit(quality, classID, up, ns.LimitBasis(v))
                    local entry = { quality = quality, classID = classID, band = up, rows = {}, head = {
                        group = true,
                        -- (The subtab is the gear type: the quality and the range say the rest.)
                        cells = { ns.QualityText(quality) .. " " .. ns.BandRange(quality, up),
                            n > 0 and tostring(n) or (GREY .. "0|r"), "", "",
                            ns.Money(v.net) .. (#v.missing > 0 and (GREY .. "?|r") or ""),
                            ns.Money(limit),
                            limit > 0 and ns.LoseText(Model.LossChance(outcomes, ns.PriceOf, opts, limit)) or (GREY .. "-|r"),
                            n > 0 and ns.Money(mine.value / n) or (GREY .. "-|r") },
                    } }
                    local inTable = {}
                    for _, r in ipairs(outcomes.results) do
                        inTable[r.id] = true
                        local m = mine and mine.mats[r.id]
                        local price = ns.PriceOf(r.id)
                        entry.rows[#entry.rows + 1] = {
                            itemID = r.id, indent = INDENT,
                            cells = { ns.MaterialName(r.id), m and tostring(m.hits) or (GREY .. "0|r"),
                                math.floor(r.chance * 100 + 0.5) .. "%",
                                r.min == r.max and tostring(r.min) or (r.min .. "-" .. r.max),
                                n > 0 and (math.floor((m and m.hits or 0) / n * 100 + 0.5) .. "%") or (GREY .. "-|r"),
                                m and string.format("%.2f", m.qty / m.hits) or (GREY .. "-|r"),
                                price and ns.Money(price) or (GREY .. "no price|r") },
                        }
                    end
                    -- What came that the table does not have for this band.
                    for id, m in pairs(mine and mine.mats or {}) do
                        if not inTable[id] then
                            entry.rows[#entry.rows + 1] = {
                                itemID = id, indent = INDENT,
                                cells = { ns.MaterialName(id), tostring(m.hits), RED .. "not expected|r", "",
                                    math.floor(m.hits / n * 100 + 0.5) .. "%", string.format("%.2f", m.qty / m.hits),
                                    "" },
                            }
                        end
                    end
                    bands[#bands + 1] = entry
                end
            end
        end
    end
    return bands
end

local function oddsNote()
    return oddsFilter().dataOnly and "No disenchants yet in the selected bands. Untick \"Only bands with my data\" "
        .. "to see the tables." or "Nothing selected: pick a quality and an item level band above."
end

--- The same as one flat list: each band's row, then its material rows.
function Window.OddsRows()
    local rows = {}
    for _, band in ipairs(Window.OddsBands()) do
        rows[#rows + 1] = band.head
        for _, r in ipairs(band.rows) do rows[#rows + 1] = r end
    end
    if #rows == 0 then rows[1] = note(oddsNote()) end
    return rows
end

-- The Odds view shows each band as a table of its own.
local ODDS_COLUMNS = {
    { "Material", 150 },
    { "Drops", 50, "CENTER", help = { "Drops", "How many of your own disenchants in this band gave this material." } },
    { "Drop rate", 64, "CENTER", help = { "Drop rate", "How often this material comes from one disenchant in this "
        .. "band, by the table the addon uses (Classic's table; not confirmed for Forever)." } },
    { "Quantity", 60, "CENTER", help = { "Quantity", "How many come when it drops, by the same table." } },
    { "Your drop rate", 84, "CENTER", help = { "Your drop rate", "How often it came in your own disenchants in "
        .. "this band." } },
    { "Your quantity", 84, "CENTER", help = { "Your quantity", "How many came on average when it dropped for you." } },
    { "Price now", 90, "RIGHT", help = { "Price now", "What one of this material costs on the auction house now, "
        .. "from your last material scan. Value now is worked out from these prices." } },
}
local BAND_HELP = { "This band", "Disenchants: how many of yours are in this band.\n\n"
    .. "Value now: what ONE disenchant is worth on average over many, at today's material prices, after the 5% cut. "
    .. "It is not the buy limit.\n\n"
    .. "Buy below: the most the addon lets you pay: Value now minus your minimum profit, or the limit you set in the "
    .. "Limits tab.\n\n"
    .. "Loss chance: the chance that one disenchant is worth less than Buy below, so the risk when you pay the full limit.\n\n"
    .. "Your average: what your own disenchants gave on average, at the prices of the moment. Compare it with Value now." }

--- One card per band for the Odds view.
function Window.OddsCards()
    local cards = {}
    local function fact(label, value) return GREY .. label .. "|r " .. value end
    local x = oddsFilter()
    local byKey = {}
    for _, band in ipairs(Window.OddsBands()) do byKey[Ledger.BandKey(band.quality, band.classID, band.band)] = band end
    -- Grouped the one way: gear type, quality, then each band by its range; every heading and band opens
    -- and closes.
    local rows = ns.GroupedRows(Window.OddsBands(), function(band)
        return { key = Ledger.BandKey(band.quality, band.classID, band.band), cells = { "" } }
    end, nil, ODDS_INDENT, { collapsed = x.collapsed, changed = function() Window.Refresh() end })
    for _, r in ipairs(rows) do
        if r.head then
            cards[#cards + 1] = { heading = true, title = r.cells[1], open = r.open, onClick = r.onClick,
                indent = r.indent }
        else
            local band = byKey[r.key]
            local c = band.head.cells
            local open = not x.collapsed["b" .. r.key]
            cards[#cards + 1] = {
                title = ns.QualityText(band.quality) .. " " .. r.cells[1], indent = r.indent, open = open,
                onClick = function()
                    x.collapsed["b" .. r.key] = open or nil
                    Window.Refresh()
                end,
                facts = table.concat({ fact("Disenchants", c[2]), fact("Value now", c[5]), fact("Buy below", c[6]),
                    fact("Loss chance", c[7]), fact("Your average", c[8]) }, "     "),
                factsHelp = BAND_HELP, rows = open and band.rows or {},
            }
        end
    end
    if #cards == 0 then cards[1] = { title = GREY .. oddsNote() .. "|r", rows = {} } end
    return cards
end

--- The two lines above the list.
function Window.Summary()
    local bought, spent, done, got, waiting, waitingCost = 0, 0, 0, 0, 0, 0
    local waitingBy = {}
    for _, e in ipairs(Ledger.History(ns.db.ledger)) do
        if e.paid then bought, spent = bought + 1, spent + e.paid end
        if e.done then
            done, got = done + 1, got + (e.got or 0)
        else
            waiting, waitingCost = waiting + 1, waitingCost + (e.paid or 0)
            if e.itemID then waitingBy[e.itemID] = (waitingBy[e.itemID] or 0) + 1 end
        end
    end
    local t = ns.Report.Totals()
    -- The top line: four numbers. The rest is behind the chart button, one line each.
    local short = string.format("%sBought|r %d for %s    %sDisenchanted|r %d    %sSold|r %d for %s    %sProfit|r %s",
        GOLD, bought, ns.Money(spent), GOLD, done, GOLD, t.sold, ns.Money(t.soldNet), GOLD, signed(t.soldProfit))
    local lines = {
        string.format("%sBought|r %d items for %s", GOLD, bought, ns.Money(spent)),
        string.format("%sDisenchanted|r %d, materials worth %s after the cut", GOLD, done, ns.Money(got)),
    }
    if waiting > 0 then
        -- Where those items are: counted in the bags and the bank; the rest is taken to be in the mail.
        local bags, bank = 0, 0
        for id, n in pairs(waitingBy) do
            local okA, inBags = pcall(ns.GetItemCount, id)
            local okB, withBank = pcall(ns.GetItemCount, id, true)
            inBags = math.min(n, okA and tonumber(inBags) or 0)
            bags = bags + inBags
            bank = bank + math.min(n - inBags, math.max(0, (okB and tonumber(withBank) or 0) - inBags))
        end
        local where = {}
        if bags > 0 then where[#where + 1] = bags .. " in bags" end
        if bank > 0 then where[#where + 1] = bank .. " in bank" end
        if waiting - bags - bank > 0 then where[#where + 1] = (waiting - bags - bank) .. " in mail or gone" end
        lines[#lines + 1] = string.format("%sBought, not disenchanted yet|r %d (%s): %s", GOLD, waiting,
            ns.Money(waitingCost), table.concat(where, ", "))
    end
    lines[#lines + 1] = string.format("%sSold|r %d materials for %s after the cut", GOLD, t.sold, ns.Money(t.soldNet))
    lines[#lines + 1] = string.format("%sProfit on sales|r %s", GOLD, signed(t.soldProfit))
    if t.untracked > 0 then
        lines[#lines + 1] = string.format("%sNo recorded cost|r %d units, %s after the cut (not in the profit)", GOLD,
            t.untracked, ns.Money(t.untrackedNet))
    end
    if t.depositsLost > 0 then
        lines[#lines + 1] = string.format("%sDeposits lost|r %s (in the profit)", GOLD, signed(-t.depositsLost))
    end
    return short, lines
end

local VIEWS = { sales = true, purchases = true, odds = true, accuracy = true }

------------------------------------------------------------------ the window

--- The Odds view: the three filters and the stack of tables, one per band. The caller anchors its parts.
--- The ledger window has one, and the popped-out odds window has one.
--- `checkPoint` = { x, y }: "Only bands with my data" on a row of its own there (a narrow window); else at the
--- end of the filter row.
function newOddsView(parent, point, checkPoint)
    local view = {}
    local function changed()
        view.stack.offset = 0
        Window.Refresh()
    end
    -- The filter row, as everywhere: Gear, Quality, Bands, Salvager; then "Only bands with my data".
    local controls, last = filterRow(parent, oddsFilter(), changed, point, true)
    view.controls = controls
    view.dataOnly = W.Check(parent, "Only bands with my data",
        "Lists only the item level bands you have disenchanted in. Untick it to see the table of every band.",
        function(on)
            oddsFilter().dataOnly = on or nil
            changed()
        end)
    if checkPoint then
        view.dataOnly:SetPoint("LEFT", parent, "TOPLEFT", checkPoint[1], checkPoint[2])
    else
        view.dataOnly:SetPoint("LEFT", last, "RIGHT", 12, 0)
    end
    controls[#controls + 1] = view.dataOnly
    view.stack = W.CardList(parent)
    view.stack:SetColumns(ODDS_COLUMNS)
    function view:SetShown(on)
        for _, c in ipairs(self.controls) do c:SetShown(on) end
        self.stack:SetShown(on)
    end
    function view:Refresh()
        self.dataOnly:SetChecked(oddsFilter().dataOnly and true or false)
        for _, c in ipairs(self.controls) do if c.Update then c:Update() end end
        self.stack:SetCards(Window.OddsCards())
        self.stack:Refresh()
    end
    return view
end

-- The Sales view's two tables share the height under the tabs; the bar between them moves the border.
local SPLIT_DEFAULT, SPLIT_MIN, SPLIT_MAX, TABLE_MIN = 0.45, 0.1, 0.9, 66
local SUBTABS = 28   -- the height of a row of subtabs over the tables
local function salesRoom()
    return (f:GetHeight() or 0) - 98 - 14 - 2 * 20 - ((Window.view == "sales" or Window.view == "accuracy") and SUBTABS or 0)
end

--- Sets how much of the room the upper Sales table takes (0.1 to 0.9), and remembers it.
function Window.SetSalesSplit(part)
    if not f then return end
    f.saved.salesSplit = math.max(SPLIT_MIN, math.min(SPLIT_MAX, part))
    Window.Refresh()
end

local ODDS_TOP, ODDS_W = 84, 740

function Window.Refresh()
    if oddsFrame and oddsFrame:IsShown() then oddsOut:Refresh() end
    if not f or not f:IsShown() then return end
    -- While the odds are in their own window, the ledger shows another view.
    if Window.view == "odds" and Window.OddsPoppedOut() then Window.view = "sales" end
    -- Sales (its first subtab) and Accuracy are two tables, each in its own panel; the other views are one.
    local accuracy = Window.view == "accuracy"
    local sales = Window.view == "sales"
    local history = sales and f.saved.salesTab == "history"
    local split = (sales and not history) or accuracy
    local odds = Window.view == "odds"
    list:SetShown(not split and not odds)
    -- The Sales view has a row of subtabs, the Purchases view its search and filters; the tables start under.
    local purchases = Window.view == "purchases"
    local mailTab = purchases and Window.PurchaseTab() == "mail"
    for _, c in ipairs(purchaseControls) do
        c:SetShown(purchases and not mailTab)
        if purchases and not mailTab and c.Update then c:Update() end
    end
    for _, c in ipairs(accuracyControls) do
        c:SetShown(accuracy)
        if accuracy and c.Update then c:Update() end
    end
    -- (The Purchases view has its subtabs, then on the first one its search and filters under them.)
    local down = (sales or purchases or accuracy) and SUBTABS or 0
    if purchases and not mailTab then down = 2 * SUBTABS end
    for key, b in pairs(salesTabs) do
        b:SetShown(sales)
        if (key == "history") == history then b:LockHighlight() else b:UnlockHighlight() end
    end
    for key, b in pairs(purchaseTabs) do
        b:SetShown(purchases)
        if (key == "mail") == mailTab then b:LockHighlight() else b:UnlockHighlight() end
    end
    bagLabel:SetShown(purchases)
    bagArea:SetShown(purchases)
    if purchases then
        purchaseTabs.mail:SetText(string.format("Not picked up (%d)", (Window.NotPickedUpTotal())))
        bagLabel:SetText(Window.BagText())
    end
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -98 - down)
    salesParts[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -100 - down)
    salesParts[2]:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -118 - down)
    salesParts[2]:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -118 - down)
    oddsView:SetShown(odds)
    for _, part in ipairs(salesParts) do part:SetShown(split) end
    if split then
        -- The upper table takes the share of the room that the bar between the tables was dragged to.
        local room = salesRoom()
        local share_ = f.saved.salesSplit or SPLIT_DEFAULT
        salesParts[2]:SetHeight(math.max(TABLE_MIN, math.min(room - TABLE_MIN, math.floor(room * share_))))
    end
    if accuracy then
        salesParts[1]:SetText(GOLD .. "By band|r" .. GREY .. "  expected value, disenchant value, sold value|r")
        salesParts[3]:SetText(GOLD .. "By material|r" .. GREY .. "  disenchant value against sold value, per unit|r")
        local bands, mats = Window.AccuracyBandRows(), Window.AccuracyMaterialRows()
        salesParts[2]:SetColumns(COLUMNS.accBands)
        salesParts[2]:SetSource(#bands, function(i) return bands[i] end)
        salesParts[2]:Refresh()
        salesParts[4]:SetColumns(COLUMNS.accMats)
        salesParts[4]:SetSource(#mats, function(i) return mats[i] end)
        salesParts[4]:Refresh()
    elseif split then
        local l = ns.db.listings
        salesParts[1]:SetText(GOLD .. "Open auctions|r" .. (l.t and (GREY .. "  as of " .. date("%H:%M", l.t) .. "|r") or "")
            .. GREY .. "  click one to see where it stands|r")
        salesParts[3]:SetText(GOLD .. "Sold|r" .. GREY .. "  the money is on its way, or waits in your mail|r")
        local listed, paid = Window.ListingRows(), Window.SoldRows(false)
        salesParts[2]:SetColumns(COLUMNS.listed)
        salesParts[4]:SetColumns(COLUMNS.paid)
        salesParts[2]:SetSource(#listed, function(i) return listed[i] end)
        salesParts[2]:Refresh()
        salesParts[4]:SetSource(#paid, function(i) return paid[i] end)
        salesParts[4]:Refresh()
    elseif odds then
        oddsView:Refresh()
    elseif history then
        local rows = Window.SoldRows(true)
        list.onSort = nil
        list:SetColumns(COLUMNS.history)
        list:SetSource(#rows, function(i) return rows[i] end)
        list:Refresh()
    elseif mailTab then
        local rows = Window.NotPickedUpRows()
        list.onSort = nil
        list:SetColumns(COLUMNS.waiting)
        list:SetSource(#rows, function(i) return rows[i] end)
        list:Refresh()
    else
        local rows = Window.PurchaseRows()
        -- The title it is ordered by shows an arrow; a click on a title orders by it, again turns it round.
        local sort, cols = Window.PurchaseSort(), {}
        for i, col in ipairs(COLUMNS.purchases) do
            cols[i] = { col[1], col[2], col[3], help = col.help }
            if sort.col == i then
                cols[i][1] = col[1] .. (sort.desc and " |TInterface\\Buttons\\Arrow-Down-Up:10|t"
                    or " |TInterface\\Buttons\\Arrow-Up-Up:10|t")
            end
        end
        list.onSort = function(col)
            local s = Window.PurchaseSort()
            if s.col == col then s.desc = not s.desc else s.col, s.desc = col, col > 1 end
            list.offset = 0
            Window.Refresh()
        end
        list:SetColumns(cols)
        list:SetSource(#rows, function(i) return rows[i] end)
        list:Refresh()
    end
    summary:SetText((Window.Summary()))
    for name, button in pairs(tabs) do
        if name == Window.view then button:LockHighlight() else button:UnlockHighlight() end
    end
    -- The pop-out button looks pressed while the odds are in their own window.
    if Window.OddsPoppedOut() then popOut:LockHighlight() else popOut:UnlockHighlight() end
    -- The two listing buttons belong to the Sales view.
    checkButton:SetShown(sales)
    cancelButton:SetShown(sales)
    if sales then
        local c, n = ns.Listings.checking, ns.Listings.CountUndercut()
        -- Only what is still for sale can be undercut: sold auctions are not checked.
        local unsold = ns.Listings.CountUnsold()
        checkButton:SetText(c and string.format("Checking %d/%d", c.done, c.total)
            or string.format("Check undercuts (%d)", unsold))
        checkButton:SetEnabled(ns.Queue.open and not c and unsold > 0)
        cancelButton:SetText(ns.Listings.Cancelling() and "Cancelling..." or string.format("Cancel undercut (%d)", n))
        -- CancelAuction needs the click itself: it cannot wait for a purchase, so the button is off meanwhile.
        local buying = ns.Scanner.Buying()
        cancelButton.reason = buying and "A purchase is on its way: Cancel comes back as soon as it is done." or nil
        cancelButton:SetEnabled(ns.Queue.open and n > 0 and not ns.Listings.Cancelling() and not buying)
    end
end

local function build()
    -- As wide as its tables need; the height is the player's.
    f = W.Window("SalvagerLedgerFrame", "Salvager ledger", "ledger", 860, 480, 860, 260, "vertical")
    -- The totals: one short line, and all of them behind the chart button at its right end.
    local details = W.HelpButton(f, "Totals", function() return select(2, Window.Summary()) end, {
        glyph = "chart", tooltip = { "Totals", "Click to see every total of the ledger, one per line." } })
    details:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -30)
    summary = W.Label(f, "", "GameFontHighlightSmall")
    summary:SetPoint("LEFT", f, "TOPLEFT", 14, -41)
    summary:SetPoint("RIGHT", details, "LEFT", -8, 0)
    summary:SetJustifyH("LEFT")
    summary:SetWordWrap(false)
    local x = 12
    for _, t in ipairs({ { "sales", "Sales" }, { "purchases", "Purchases" }, { "accuracy", "Accuracy" },
        { "odds", "Odds" } }) do
        local b = W.Button(f, t[2], 88, function()
            -- The Odds tab, while the odds are in their own window: put them back here.
            if t[1] == "odds" then Window.OddsPutBack() end
            Window.view = t[1]
            f.saved.view = t[1]
            list.offset = 0
            oddsView.stack.offset = 0
            Window.Refresh()
        end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -68)
        tabs[t[1]] = b
        x = x + (t[1] == "odds" and 116 or 92)   -- (the Odds tab has its pop-out button after it)
    end
    W.Tooltip(tabs.accuracy, "Accuracy", "Expected value when you bought, against the disenchant value of what you got, "
        .. "against the sold value. By band and by material.")
    W.Tooltip(tabs.purchases, "Purchases", "Every item you bought, newest first. Under each one: what it was disenchanted "
        .. "into, the part of its price given to each material, and what each was worth then. The Not picked up "
        .. "subtab has what still waits in the mail, with your bag space.")
    W.Tooltip(tabs.sales, "Sales", "Your open auctions, and what is sold with its money still to collect. The History "
        .. "subtab has the sales you have collected. Profit = what you get after the cut, minus what those "
        .. "materials cost you.")
    W.Tooltip(tabs.odds, "Odds", "Every item level band of every quality and gear type. Expected = how often each "
        .. "material comes and how many (the table the addon uses). You got = what your own disenchants gave. Value "
        .. "now = what one disenchant is worth on average at today's prices, after the cut. Buy below = the buy "
        .. "limit; Loss chance = the chance one disenchant is worth less than it. Point at a column title for more.")
    -- (Clear history is in the options, with the backups.)
    cancelButton = W.Button(f, "Cancel undercut (0)", 150, function() ns.Listings.CancelNext() end,
        "Cancels one undercut listing per click (the game wants a click for each). The materials come back by mail, "
        .. "and the auction house keeps its deposit. Needs the auction house open, and a check first.")
    -- On the row of the Sales subtabs, at the right: the row of the main tabs is full.
    cancelButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -98)
    cancelButton:SetMotionScriptsWhileDisabled(true)
    cancelButton:HookScript("OnEnter", function(self)
        local why = self.reason
        if why then GameTooltip:AddLine(why, 1, 0.3, 0.3, true) GameTooltip:Show() end
    end)
    checkButton = W.Button(f, "Check undercuts (0)", 150, function() ns.Listings.Check() end,
        "Searches each material you still have for sale and compares your price with the lowest listing that is not "
        .. "yours. Auctions that are sold are not checked. The number is how many listings are still for sale. "
        .. "About one second per material. Needs the auction house open.")
    checkButton:SetPoint("RIGHT", cancelButton, "LEFT", -6, 0)
    -- The Odds filters on the row under the tabs, as in the other views.
    oddsView = newOddsView(f, { 14, -109 })
    oddsView.stack:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -126)
    oddsView.stack:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    -- Right next to the Odds tab: the odds in a window of their own, and back.
    popOut = W.IconButton(f, 22, function()
        if Window.OddsPoppedOut() then Window.OddsPutBack() else Window.OddsPopOut() end
    end)
    popOut:SetPoint("LEFT", tabs.odds, "RIGHT", 0, 0)
    popOut:SetPopOutGlyph()
    popOut:SetScript("OnEnter", function(self)
        local out = Window.OddsPoppedOut()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(out and "Put the odds back" or "Pop out the odds", 1, 1, 1)
        GameTooltip:AddLine(out and "Closes their window and shows them in the Odds tab again."
            or "Moves the odds to a window of their own. Click again, or close that window, to put them back.",
            1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    popOut:SetScript("OnLeave", function() GameTooltip:Hide() end)
    list = W.List(f, { rowHeight = 22 })
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -98)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    -- The Sales view: a title and a table for your auctions, a title and a table for the paid sales.
    local titleA = W.Label(f, "", "GameFontNormal")
    titleA:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -100)
    local listA = W.List(f, { rowHeight = 22 })
    listA:SetColumns(COLUMNS.listed)
    listA:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -118)
    listA:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -118)
    listA:SetHeight(120)
    local titleB = W.Label(f, "", "GameFontNormal")
    titleB:SetPoint("TOPLEFT", listA, "BOTTOMLEFT", 2, -6)
    local listB = W.List(f, { rowHeight = 22 })
    listB:SetColumns(COLUMNS.paid)
    listB:SetPoint("TOPLEFT", listA, "BOTTOMLEFT", 0, -24)
    listB:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    -- The bar between the two tables: drag it up or down to make one table taller and the other shorter.
    local bar = CreateFrame("Button", nil, f)
    bar:SetPoint("TOPLEFT", listA, "BOTTOMLEFT", 0, -1)
    bar:SetPoint("TOPRIGHT", listA, "BOTTOMRIGHT", 0, -1)
    bar:SetHeight(22)
    local handle = bar:CreateTexture(nil, "ARTWORK")
    handle:SetSize(60, 3)
    handle:SetPoint("TOP", bar, "TOP", 0, -2)
    handle:SetColorTexture(1, 0.82, 0, 0.45)
    local glow = bar:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAllPoints()
    glow:SetColorTexture(1, 1, 1, 0.08)
    W.Tooltip(bar, "Resize", "Drag up or down to make one table taller and the other shorter. Right-click: back to "
        .. "the default.")
    bar:RegisterForClicks("RightButtonUp")
    bar:SetScript("OnClick", function()
        f.saved.salesSplit = nil
        Window.Refresh()
    end)
    bar:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self:SetScript("OnUpdate", function()
            local top, room = listA:GetTop(), salesRoom()
            local _, y = GetCursorPosition()
            if type(top) ~= "number" or type(y) ~= "number" or room <= 0 then return end
            y = y / (f:GetEffectiveScale() or 1)
            Window.SetSalesSplit((top - y - 4) / room)
        end)
    end)
    bar:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil) end)
    bar:SetScript("OnHide", function(self) self:SetScript("OnUpdate", nil) end)
    salesParts = { titleA, listA, titleB, listB, bar }
    -- The subtabs of the Sales view: what is open and what is sold; and the history.
    for _, t in ipairs({ { "open", "Open and sold", "Your open auctions, and what is sold with its money still to collect." },
        { "history", "History", "The sales whose money you have taken from the mail, newest first." } }) do
        local b = W.Button(f, t[2], t[1] == "open" and 120 or 90, function()
            f.saved.salesTab = t[1]
            list.offset = 0
            Window.Refresh()
        end, t[3])
        if salesTabs.open then
            b:SetPoint("LEFT", salesTabs.open, "RIGHT", 4, 0)
        else
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -98)
        end
        salesTabs[t[1]] = b
    end
    -- The subtabs of the Purchases view: every purchase; and what waits in the mail.
    for _, t in ipairs({ { "all", "All purchases", "Every item you bought, with what it was disenchanted into." },
        { "mail", "Not picked up", "The items you bought with Buy whose \"Auction won\" mail you have not taken "
            .. "yet, the first bought first. The number is how many." } }) do
        local b = W.Button(f, t[2], t[1] == "all" and 110 or 140, function()
            f.saved.purchaseTab = t[1] == "mail" and "mail" or nil
            list.offset = 0
            Window.Refresh()
        end, t[3])
        if purchaseTabs.all then
            b:SetPoint("LEFT", purchaseTabs.all, "RIGHT", 4, 0)
        else
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -98)
        end
        purchaseTabs[t[1]] = b
        b:Hide()
    end
    -- On the same row, at the right: the bag space, for both subtabs (do the mails fit?).
    bagLabel = W.Label(f, "", "GameFontHighlightSmall")
    bagLabel:SetPoint("RIGHT", f, "TOPRIGHT", -14, -109)
    bagLabel:SetJustifyH("RIGHT")
    bagArea = W.HelpArea(f, bagLabel, "Bag space", "Free slots in your backpack and bags, of all their slots, now. "
        .. "Profession bags are left out: they do not hold gear. \"Not enough\" = the items in the mail do not fit.")
    bagLabel:Hide()
    bagArea:Hide()
    Window.purchaseTabs, Window.bagLabel = purchaseTabs, bagLabel   -- (the specs click and read them)
    -- The Purchases view: a search box, and filters by gear type, quality and item level band.
    do
        local pf = purchaseFilter()
        local function changed()
            list.offset = 0
            Window.Refresh()
        end
        local searchLabel = W.Label(f, "Search", "GameFontHighlightSmall")
        searchLabel:SetPoint("LEFT", f, "TOPLEFT", 14, -109 - SUBTABS)
        local search = W.Edit(f, 120)
        search:SetPoint("LEFT", searchLabel, "RIGHT", 8, 0)
        search:SetText(pf.search or "")
        search:SetScript("OnTextChanged", function(self)
            local text = self:GetText() or ""
            if text ~= (pf.search or "") then
                pf.search = text
                changed()
            end
        end)
        search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
        purchaseControls = { searchLabel, search,
            W.HelpArea(f, searchLabel, "Search", "Shows the items whose name has this text in it.") }
        local row, last = filterRow(f, pf, changed, search, false)
        for _, c in ipairs(row) do purchaseControls[#purchaseControls + 1] = c end
        local prev = last
        local waiting = W.Check(f, "Not disenchanted", "Shows the items you bought and have not disenchanted yet. "
            .. "Untick it to see only what was disenchanted.", function(on)
            pf.hideWaiting = (not on) or nil
            changed()
        end)
        waiting:SetPoint("LEFT", prev, "RIGHT", 12, 0)
        waiting:SetChecked(not pf.hideWaiting)
        purchaseControls[#purchaseControls + 1] = waiting
        for _, c in ipairs(purchaseControls) do c:Hide() end
    end
    -- The Accuracy view: the filter row, Salvager too.
    do
        accuracyControls = filterRow(f, accuracyFilter(), function()
            salesParts[2].offset, salesParts[4].offset = 0, 0
            Window.Refresh()
        end, { 14, -109 }, true)
        for _, c in ipairs(accuracyControls) do c:Hide() end
    end
    if VIEWS[f.saved.view] then Window.view = f.saved.view end
    f.onResize = Window.Refresh
    f:SetScript("OnShow", Window.Refresh)
end


local function buildOdds()
    -- As wide as its tables need; the height is the player's (the corner sizes it up and down only).
    -- 740 wide: the cards need about 700 (their columns, the icon, two levels of indent, the scroll bar); the
    -- filter row about 700, with "Only bands with my data" on the row under it.
    oddsFrame = W.Window("SalvagerOddsFrame", "Salvager odds", "odds", ODDS_W, 520, ODDS_W, 200, "vertical")
    oddsFrame.onResize = Window.Refresh
    oddsOut = newOddsView(oddsFrame, { 14, -41 }, { 12, -66 })
    oddsOut.stack:SetPoint("TOPLEFT", oddsFrame, "TOPLEFT", 12, -ODDS_TOP)
    oddsOut.stack:SetPoint("BOTTOMRIGHT", oddsFrame, "BOTTOMRIGHT", -12, 14)
    oddsFrame:SetScript("OnShow", Window.Refresh)
    oddsFrame:SetScript("OnHide", Window.Refresh)
end

function Window.OddsPoppedOut()
    return oddsFrame ~= nil and oddsFrame:IsShown()
end

--- Moves the odds to their own window.
function Window.OddsPopOut()
    if not oddsFrame then buildOdds() end
    oddsFrame.UserShow()
    ns.Log("odds popped out")
end

--- Puts the odds back in the ledger window's tab.
function Window.OddsPutBack()
    if Window.OddsPoppedOut() then
        oddsFrame.UserHide()
        ns.Log("odds put back")
    end
end

function Window.Toggle()
    if not f then build() end
    f.UserToggle()
end

function Window.Show()
    if not f then build() end
    f.UserShow()
end

--- Opens the window again if it was open the last time (the auction house opened).
function Window.Restore()
    local saved = ns.db.windows.ledger
    if saved and saved.open then
        if not f then build() end
        f:Show()
    end
    local odds = ns.db.windows.odds
    if odds and odds.open then
        if not oddsFrame then buildOdds() end
        oddsFrame:Show()
    end
end

-- The countdowns of the Sales view run: once a second while it shows.
local lastCount = 0
ns.OnTick(function()
    if f and f:IsShown() and Window.view == "sales" and GetTime() - lastCount >= 1 then
        lastCount = GetTime()
        Window.Refresh()
    end
end)

for _, e in ipairs({ "SALVAGER_LEDGER", "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS", "SALVAGER_LISTINGS",
    "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do
    ns.On(e, function() Window.Refresh() end)
end
-- The bag space of the Purchases view is live while it shows.
ns.On("BAG_UPDATE_DELAYED", function() if Window.view == "purchases" then Window.Refresh() end end)

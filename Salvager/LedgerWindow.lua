-- Salvager: the Ledger window. A window of its own (move it, resize it), with three views:
--   Sales:     your auctions, every material sale with its profit against what the materials cost you, and who
--              undercuts you.
--   Purchases: every item bought, and under it what it was disenchanted into; what waits in the mail; the batch.
--   Accuracy:  what the Gear tab expected against what the disenchants gave and the materials sold for.
-- (The Odds moved to the Reports in 0.3.148: OddsWindow.lua.)
local _, ns = ...

local Ledger, Data, W = ns.Ledger, ns.Data, ns.Widgets

local Window = { view = "sales" }
ns.LedgerWindow = Window

local GREY, GOLD, GREEN, RED = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040"
local PROFIT_HELP = { "Profit", "What you got after the cut minus what the materials cost you, for the units with a "
    .. "known cost only. \"+3?\" in Cost = 3 units with no recorded cost, left out. An auction that expired or was "
    .. "cancelled shows the deposit the auction house kept, as a loss." }
local INDENT = 22
-- The longest countdown (an auction runs up to 48 hours): the Time columns keep this width while they count.
local COUNTDOWN_MAX = "00:00:00"

local COLUMNS = {
    purchases = { { "Gear", 220 }, { "Bought", 82, help = ns.TimeHelp("Bought", "When you bought it.") }, { "Paid", 84, "RIGHT" },
        { "Avg value", 84, "RIGHT", help = { "Avg value", "The average value the Gear tab showed when you "
            .. "bought: the average disenchant value over many pieces at the prices of that moment, after the auction "
            .. "house cut. One disenchant gives one of its outcomes, not this." } },
        { "Disenchant value", 96, "RIGHT", help = { "Disenchant value", "The market value of the materials you got, "
            .. "at the prices of the moment you disenchanted, after the auction house cut." } },
        { "Profit", 84, "RIGHT", help = { "Profit", "Disenchant value minus Paid." } } },
    -- The Purchases view's second subtab: what waits in the mail.
    waiting = { { "Gear", 220 },
        { "Item level", 60, "CENTER", help = { "Item level", "The gear's item level, as the Gear tab judged it when you bought." } },
        { "Bought", 82, help = ns.TimeHelp("Bought", "When you bought it.") }, { "Paid", 84, "RIGHT" },
        { "Avg value", 84, "RIGHT", help = { "Avg value", "The average value the Gear tab showed when you "
            .. "bought: the average disenchant value over many pieces at the prices of that moment, after the auction "
            .. "house cut." } } },
    -- The Purchases view's third subtab: the current batch (SDD 107).
    batch = { { "Gear", 220 },
        { "Item level", 60, "CENTER", help = { "Item level", "The gear's item level, as the Gear tab judged it when you "
            .. "bought (or as it was disenchanted)." } },
        { "Paid", 84, "RIGHT" },
        { "Avg value (EV)", 84, "RIGHT", help = { "Average value (EV)", "The average value the Gear tab showed when "
            .. "you bought: the average disenchant value over many pieces at the prices of that moment, after the "
            .. "auction house cut. On a heading or the totals: the sum of averages, an average too." } },
        { "Profit: low - avg - high", 84, "RIGHT", help = { "Profit: pessimistic - average - optimistic",
            "Before the disenchant: what one disenchant makes against Paid, as the Gear tab showed it when you bought "
            .. "(9 in 10 give the first or more, the middle is the average over many pieces, 1 in 10 gives the last "
            .. "or more). Gear bought before 0.3.152, a disenchanted piece, a heading and the totals: the average "
            .. "profit alone (Avg value minus Paid; summed: an average too)." } },
        { "Materials got", 120, help = { "Materials got", "What the disenchant gave. Grey \"not disenchanted yet\": "
            .. "not known until you disenchant it." } },
        { "Disenchant value (DV)", 96, "RIGHT", help = { "Disenchant value (DV)", "The market value of the materials "
            .. "you got, at the prices of the moment you disenchanted, after the auction house cut." } },
        { "DV/EV %", 46, "RIGHT", help = { "DV/EV %", "The difference between Disenchant value (DV) and Average value "
            .. "(EV), in percent of the Average value: the luck of the disenchant (or result rates that are not what "
            .. "the addon assumes). On the totals: of the disenchanted pieces only." } },
        { "Profit so far", 84, "RIGHT", help = { "Profit so far", "Disenchant value minus Paid: what the disenchant "
            .. "made, before the materials sell. On the totals: of the disenchanted pieces only." } },
        { "Not posted yet", 120, help = { "Not posted yet", "The materials of this disenchant you have not posted "
            .. "yet. Your posts, sales and what you hold take them, first in, first out. When none is left, the gear "
            .. "leaves the batch." } },
        { "Value now", 84, "RIGHT", help = { "Value now", "The materials not posted yet (real units, not an average) at "
            .. "what one unit is worth to the forecast now: price × sell price ratio, after the cut, less the deposits "
            .. "lost." } } },
    -- The Accuracy view is two tables: by band, and by material.
    accBands = { { "Band", 170 }, { "Disenchanted", 70, "CENTER", help = { "Disenchanted", "How many disenchants with a recorded "
            .. "purchase are in the row. Grey = fewer than 20: too few to judge, one lucky shard moves it a lot." } },
        { "Paid", 70, "RIGHT" },
        { "Average value (EV)", 70, "RIGHT", help = { "Average value (EV)", "The average value the Gear tab showed "
            .. "when you bought: the average disenchant value over many pieces at the material prices of that moment, "
            .. "after the auction house cut; summed over the row's pieces." } },
        { "Disenchant value (DV)", 70, "RIGHT", help = { "Disenchant value (DV)", "The market value of the materials you "
            .. "got, at the prices of the moment you disenchanted, after the auction house cut." } },
        { "DV/EV %", 46, "RIGHT", help = { "DV/EV %",
            "The difference between Disenchant value (DV) and Average value (EV), in percent of the Average value. The "
            .. "gap comes from luck in the results, or from result rates that are not what the addon assumes."
            .. " Grey: a gap from a forecast, not gold you gained or lost." } },
        { "Sold value (SV)", 70, "RIGHT", help = { "Sold value (SV)", "The same materials at the average price each one "
            .. "really sold for, after the auction house cut. Materials you have not sold yet count at their disenchant "
            .. "value." } },
        { "SV/DV %", 46, "RIGHT", help = { "SV/DV %",
            "The difference between Sold value (SV) and Disenchant value (DV), in percent of the Disenchant value. The "
            .. "gap comes from prices that moved, and from undercutting. * = more than half of the row's materials are "
            .. "not sold yet, so most of it is still the disenchant value."
            .. " Grey: a gap from a forecast, not gold you gained or lost." } },
        { "Average profit (EP)", 70, "RIGHT", help = { "Average profit (EP)", "Average value minus Paid: the average "
            .. "profit the Gear tab showed, over many pieces." } },
        { "Actual profit (AP)", 70, "RIGHT", help = { "Actual profit (AP)", "Sold value minus Paid." } },
        { "AP/EP %", 46, "RIGHT", help = { "AP/EP %",
            "The difference between Actual profit (AP) and Average profit (EP), in percent of the Average profit: how "
            .. "much more (+) or less (-) the gear made than the Gear tab said when you bought it. "
            .. "- = no average profit to compare with."
            .. " Grey: a gap from a forecast, not gold you gained or lost." } } },
    accMats = { { "Material", 170 }, { "Units", 44, "CENTER" },
        { "Disenchant value each (DV)", 80, "RIGHT", help = { "Disenchant value each (DV)", "The average market price of "
            .. "one unit at the moment you disenchanted, after the auction house cut." } },
        { "Sold value each (SV)", 80, "RIGHT", help = { "Sold value each (SV)", "The average of what one unit really "
            .. "brought in your sales, after the auction house cut." } },
        { "SV - DV", 80, "RIGHT", help = { "SV - DV",
            "The difference between Sold value each (SV) and Disenchant value each (DV), in coins: SV minus DV." } },
        { "SV/DV %", 46, "RIGHT", help = { "SV/DV %",
            "The difference between Sold value each (SV) and Disenchant value each (DV), in percent of the Disenchant "
            .. "value each. The gap comes from prices that moved, and from undercutting." } },
        { "Units sold", 70, "CENTER" } },
    -- The Sales view is two tables: your auctions, and the sales already paid.
    listed = { { "Material", 150 }, { "Status", 110 },
        { "Time", 62, "RIGHT", sample = COUNTDOWN_MAX, help = { "Time", "A sold auction: the time until its money arrives by mail. "
            .. "An auction still for sale: the time until it ends. It counts down from the last time the addon read "
            .. "your auctions (see \"as of\" above)." } },
        { "Each", 64, "RIGHT" }, { "Price", 76, "RIGHT" },
        { "You get", 76, "RIGHT" }, { "Cost", 84, "RIGHT" }, { "Profit", 76, "RIGHT" } },
    history = { { "Material", 150 },
        { "Sold", 110, help = ns.TimeHelp("Sold", "When it sold (an auction that expired or was cancelled: when that was).") },
        { "Collected", 110, "LEFT", help = ns.TimeHelp("Collected", "When you took the money of this sale from the mail.") },
        { "Each", 64, "RIGHT" }, { "Price", 76, "RIGHT" },
        { "You got", 76, "RIGHT" }, { "Cost", 84, "RIGHT" }, { "Profit", 76, "RIGHT", help = PROFIT_HELP } },
    -- The Sales view's third subtab: who undercuts you (SDD 109).
    competition = { { "Name", 150, help = { "Name", "The seller whose listing was under the price of one of your "
            .. "auctions of that material, as the auction house names them. Unknown seller: the client did not give a "
            .. "name (it learns names over time). Click a row for each time it was seen, newest first." } },
        { "Times seen", 60, "RIGHT", help = { "Times seen", "How many times a search found a price line of theirs "
            .. "under one of your auctions: once per line, not again while the line stays the same. All time." } },
        { "Last seen", 82, help = ns.TimeHelp("Last seen", "The last time a search found them under you.") },
        { "Materials", 120, help = { "Materials", "Which of your materials they undercut, the most often first." } },
        { "Typical gap", 76, "RIGHT", help = { "Typical gap", "How far under your price their price each was: the "
            .. "median, in coins." } },
        { "Typical gap %", 50, "RIGHT", help = { "Typical gap %", "The same in percent of your price each." } },
        { "Lowest price seen", 76, "RIGHT", help = { "Lowest price seen", "The lowest price each of theirs seen under "
            .. "your price (the material is in the row's tooltip)." } },
        { "Profit lost to them", 84, "RIGHT", help = { "Profit lost to them", "What their undercuts cost you: the "
            .. "cancel fees and deposits of your undercut auctions you cancelled, the deposits of the reposts, and "
            .. "the lower price your reposted units sold at against your first price. Split evenly when several "
            .. "were under you. Units not sold yet are not in it." } } },
    paid = { { "Material", 150 },
        { "Sold", 110, help = ns.TimeHelp("Sold", "When it sold (an auction that expired or was cancelled: when that was).") },
        { "Time", 62, "RIGHT", sample = COUNTDOWN_MAX, help = { "Time", "The time until the money of this sale arrives by mail." } },
        { "Each", 64, "RIGHT" }, { "Price", 76, "RIGHT" },
        { "You get", 76, "RIGHT" }, { "Cost", 84, "RIGHT" }, { "Profit", 76, "RIGHT", help = PROFIT_HELP } },
}

local f, list, summary, tabs = nil, nil, nil, {}
local checkButton, cancelButton, autoButton
local salesParts = {}   -- title, table, title, table of the Sales view
local purchaseControls = {} -- the Purchases view's search box and filters
local accuracyControls = {} -- the Accuracy view's filters
local salesTabs = {}    -- the Sales view's subtabs: open and sold, history
local purchaseTabs = {} -- the Purchases view's subtabs: all purchases, not picked up
local bagLabel, bagArea -- the Purchases view's bag space, in the footer

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
Window.FilterSet = filterSet

--- Does a thing of this gear type, quality, item level (and Salvager) pass the filter? Unknown parts pass.
-- The Purchases view's search and filters (in the window's saved data): text in the item's name, gear types,
-- qualities, item level bands left out.
local function purchaseFilter()
    ns.db.windows.ledger = ns.db.windows.ledger or {}
    local saved = ns.db.windows.ledger
    saved.purchaseFilter = saved.purchaseFilter or {}
    local x = filterSet(saved.purchaseFilter)
    x.open = x.open or {}
    -- Show: "all" gear, only the "done" (disenchanted) or only the "waiting" (not disenchanted). The check box
    -- "Not disenchanted" before 0.3.136 kept its untick as hideWaiting.
    if x.hideWaiting then x.show, x.hideWaiting = "done", nil end
    if x.show ~= "done" and x.show ~= "waiting" then x.show = "all" end
    return x
end
Window.PurchaseFilter = purchaseFilter   -- (the specs set its search)
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

--- The filters every view has: Gear, Quality, Bands (and Salvager with `salvager`), each with its label at its
--- left, added to `bar` (a Widgets.Bar of filters). `changed()` runs after each change.
--- @return table controls  the dropdowns (Update them on refresh)
local function filterRow(bar, x, changed, salvager)
    local controls = {}
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
    local function add(label, width, drop, help)
        bar:AddFilter(label, drop, width, help)
        controls[#controls + 1] = drop
    end
    local gGet, gSet = setOf(x.classes, false, { Data.CLASS_ARMOR, Data.CLASS_WEAPON })
    add("Gear", 100, W.Dropdown(bar, 100, { { Data.CLASS_ARMOR, "Armor" }, { Data.CLASS_WEAPON, "Weapons" } }, gGet,
        gSet, "Which gear types show.", "Gear", allOr), "Armor, weapons, or both.")
    local qGet, qSet = setOf(x.qualities, false, { 2, 3, 4 })
    add("Quality", 140, W.Dropdown(bar, 140, { { 2, "|cff1eff00Uncommon|r" }, { 3, "|cff0070ddRare|r" },
        { 4, "|cffa335eeEpic|r" } }, qGet, qSet, "Which qualities show.", "Quality", allOr), "Uncommon, Rare, Epic.")
    local bandOptions, bandKeys = {}, {}
    for _, b in ipairs(ns.LevelBands()) do
        bandOptions[#bandOptions + 1] = { b.up, b.label }
        bandKeys[#bandKeys + 1] = b.up
    end
    local bGet, bSet = setOf(x.bandsOff, true, bandKeys)
    add("Bands", 120, W.Dropdown(bar, 120, bandOptions, bGet, bSet, "Which item level bands show.", "Bands",
        function(names, total)
            if #names == total then return "All" end
            if #names > 2 then return #names .. " bands" end   -- (three names did not fit, 0.3.151)
            return table.concat(names, ", ")
        end), "Item level bands: a band is a range of item levels that disenchants into the same materials.")
    if salvager then
        local drop
        drop = W.Dropdown(bar, 100, { { "all", "All" }, { "with", "With it" }, { "without", "Without it" } },
            function(key) return x.salvager == key end,
            function(key)
                x.salvager = key
                drop:Close()
                changed()
            end, "Disenchants with the Arcane Salvager's bonus, without it, or all.", "Salvager")
        add("Salvager", 100, drop, "Disenchants with the Arcane Salvager's bonus, without it, or all.")
    end
    return controls
end
Window.FilterRow = filterRow

local function when(t) return (t and t > 0) and ns.Date("%m-%d %H:%M", t) or "-" end
local function money(c) return c and ns.Money(c) or "-" end
local function signed(c)
    if not c then return "" end
    return (c >= 0 and GREEN or RED) .. ns.Money(c) .. "|r"
end
local function itemName(itemID, link)
    return link or (ns.GetItemInfo(itemID)) or ("item " .. tostring(itemID))
end
local function note(text) return { cells = { GREY .. text .. "|r" }, span = true } end

--- A signed number's color (UI.md Tables 7): green when it is good (more than planned, a gain), red when it is
--- bad, none at 0; the sign says it too.
local function tone(n) return n > 0 and GREEN or n < 0 and RED or "" end
local function toned(n, text) return n ~= 0 and (tone(n) .. text .. "|r") or text end

--- "+5%", "-3%": how far `part` is from `whole`, green above, red below.
local function share(part, whole)
    if not whole or whole == 0 then return GREY .. "-|r" end
    local pct = math.floor((part - whole) / whole * 100 + 0.5)
    return toned(pct, (pct > 0 and "+" or "") .. pct .. "%")
end

--- An amount with its sign, green when it gains, red when it loses (Expected profit).
local function gap(c)
    c = math.floor(c + 0.5)
    return toned(c, (c > 0 and "+" or "") .. ns.Money(c))
end


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
    if x.show == "done" and not e.done then return false end
    if x.show == "waiting" and e.done then return false end
    local classID, quality, ilvl = describeEntry(e)
    if not filterPasses(x, classID, quality, ilvl) then return false end
    if search ~= "" then
        local name = (e.link and e.link:match("%[(.-)%]")) or (ns.GetItemInfo(e.itemID)) or ""
        if not name:lower():find(search, 1, true) then return false end
    end
    return true
end

--- Totals of a list of History entries: count, paid (known), expected, and for the disenchanted ones what they
--- gave and the result.
local function totalsOf(entries)
    local t = { n = #entries, paid = 0, known = 0, expected = 0, got = 0, done = 0, result = 0, resultKnown = 0 }
    for _, e in ipairs(entries) do
        if e.paid then t.paid, t.known = t.paid + e.paid, t.known + 1 end
        t.expected = t.expected + (e.expected or 0)
        if e.done then t.got, t.done = t.got + (e.got or 0), t.done + 1 end
        if e.result then t.result, t.resultKnown = t.result + e.result, t.resultKnown + 1 end
    end
    return t
end

local function pieces(n) return n .. (n == 1 and " piece" or " pieces") end

--- Is a filter of the Purchases view narrowing the list (the search, Gear, Quality, Bands)?
local function narrowed(x, search)
    if search ~= "" or next(x.bandsOff) then return true end
    if not (x.classes[Data.CLASS_ARMOR] and x.classes[Data.CLASS_WEAPON]) then return true end
    return not (x.qualities[2] and x.qualities[3] and x.qualities[4])
end

--- One row per item name of `list` (in the order of the column picked), each opening to its purchases with what
--- they gave; `scope` keeps its open state apart from the same item under another heading.
local function itemRows(rows, entries, x, scope, indent)
    local groups, order = {}, {}
    for _, e in ipairs(entries) do
        local key = tostring(e.itemID)
        local g = groups[key]
        if not g then
            g = { itemID = e.itemID, link = e.link, entries = {}, paid = 0, known = 0, expected = 0, got = 0, done = 0,
                result = 0, salvager = 0, last = e.boughtAt or e.t }
            groups[key] = g
            order[#order + 1] = g
        end
        g.entries[#g.entries + 1] = e
        if e.paid then g.paid, g.known = g.paid + e.paid, g.known + 1 end
        g.expected = g.expected + (e.expected or 0)
        if e.done then g.got, g.done = g.got + (e.got or 0), g.done + 1 end
        if e.result then g.result = g.result + e.result end
        if e.salvager then g.salvager = g.salvager + 1 end
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
    for _, g in ipairs(order) do
        local n = #g.entries
        local head = {
            itemID = g.itemID, link = g.link, indent = indent,
            cells = {
                itemName(g.itemID, g.link) .. GREY .. "  x" .. n .. "|r"
                    .. (g.salvager > 0 and ("  |cff9370db[Salvager " .. g.salvager .. "]|r") or ""),
                when(g.last), g.known > 0 and ns.Money(g.paid) or (GREY .. "not recorded|r"), money(g.expected),
                g.done > 0 and money(g.got) or (GREY .. "not disenchanted|r"), g.known > 0 and signed(g.result) or "",
            },
        }
        rows[#rows + 1] = head
        -- A heading that opens and closes (ns.HeadingToggle); it starts closed.
        if ns.HeadingToggle(head, x.open, scope .. ":" .. tostring(g.itemID), function() Window.Refresh() end, true) then
            for _, e in ipairs(g.entries) do
                local gave = {}
                for _, m in ipairs(e.mats or {}) do gave[#gave + 1] = m.qty .. "x " .. ns.MaterialName(m.id) end
                local what = e.done and table.concat(gave, ", ")
                    or (GREY .. (ns.NoDisenchant(e.itemID) and "cannot be disenchanted" or "not disenchanted") .. "|r")
                rows[#rows + 1] = {
                    indent = indent + INDENT, link = e.link,
                    cells = { what .. (e.salvager and "  |cff9370db[Salvager]|r" or ""),
                        when(e.boughtAt or (not e.done and e.t) or nil),
                        e.paid and ns.Money(e.paid) or (GREY .. "not recorded|r"), money(e.expected),
                        e.done and money(e.got) or "", signed(e.result) },
                }
            end
        end
    end
end

--- Every piece of gear bought (SDD 107): a heading per day it was bought (newest first) with its totals, under it
--- a heading per status (Not disenchanted first: what you act on, then Disenchanted) with theirs, and under those
--- one row per item name that opens to each purchase with what it gave. The search, the filters and Show pick
--- what is in it; every heading opens and closes, remembered.
function Window.PurchaseRows()
    local x = purchaseFilter()
    local search = (x.search or ""):lower()
    local all = Ledger.History(ns.db.ledger)
    local days, order = {}, {}
    for _, e in ipairs(all) do
        if passes(e, x, search) then
            local t = e.boughtAt or e.t or 0
            local key = ns.Date("%Y-%m-%d", t)
            local d = days[key]
            if not d then
                d = { key = key, t = t, all = {}, waiting = {}, done = {} }
                days[key] = d
                order[#order + 1] = d
            end
            d.all[#d.all + 1] = e
            table.insert(e.done and d.done or d.waiting, e)
        end
    end
    table.sort(order, function(a, b) return a.key > b.key end)
    local rows = {}
    local function refresh() Window.Refresh() end
    for _, d in ipairs(order) do
        local t = totalsOf(d.all)
        local head = { group = true, cells = { GOLD .. ns.Date("%a %m-%d", d.t) .. "|r" .. GREY .. "  " .. pieces(t.n) .. "|r",
            "", t.known > 0 and ns.Money(t.paid) or (GREY .. "not recorded|r"), money(t.expected),
            t.done > 0 and money(t.got) or "", t.resultKnown > 0 and signed(t.result) or "" },
            tip = { ns.Date("%A %m-%d", d.t), "The gear you bought this day: how many pieces, what you paid and their average value; "
                .. "Disenchant value and Profit for the pieces disenchanted so far. Click to open or close. Days in "
                .. ns.TimesName() .. "." } }
        rows[#rows + 1] = head
        if ns.HeadingToggle(head, x.collapsed, "d" .. d.key, refresh) then
            for _, st in ipairs({ { "waiting", "Not disenchanted" }, { "done", "Disenchanted" } }) do
                local group = d[st[1]]
                if #group > 0 then
                    local s = totalsOf(group)
                    local sh = { group = true, indent = INDENT, cells = { st[2] .. GREY .. "  " .. pieces(s.n) .. "|r",
                        "", s.known > 0 and ns.Money(s.paid) or (GREY .. "not recorded|r"), money(s.expected),
                        st[1] == "done" and money(s.got) or "", (st[1] == "done" and s.resultKnown > 0) and signed(s.result)
                        or "" } }
                    rows[#rows + 1] = sh
                    if ns.HeadingToggle(sh, x.collapsed, "s" .. d.key .. ":" .. st[1], refresh) then
                        itemRows(rows, group, x, d.key .. ":" .. st[1], 2 * INDENT)
                    end
                end
            end
        end
    end
    if #rows == 0 then
        -- Why it is empty, for the Show choice (UI.md Tables 6).
        local filtered = narrowed(x, search)
        local text
        if #all == 0 then
            text = "Nothing yet. Buy from the main window's Gear tab, or take your \"Auction won\" mail, then disenchant."
        elseif x.show == "done" then
            text = filtered and "No disenchanted gear matches the search and the filters."
                or "Nothing disenchanted yet: disenchant the gear you bought, or pick All gear in Show."
        elseif x.show == "waiting" then
            text = filtered and "No gear that is not disenchanted matches the search and the filters."
                or "Every piece of gear you bought is disenchanted. Pick All gear in Show to see it."
        else
            text = "No purchase matches the search and the filters."
        end
        rows[1] = note(text)
    end
    return rows
end

--- The Purchases view's subtab: "all" (every purchase), "mail" (not picked up) or "batch" (the current batch),
--- kept with the window.
local PURCHASE_TABS = { mail = true, batch = true }
function Window.PurchaseTab()
    local saved = ns.db.windows.ledger
    return (saved and PURCHASE_TABS[saved.purchaseTab]) and saved.purchaseTab or "all"
end

--- What you hold of an item, the bags and the bank; nil where the client does not say.
-- (Gear the player wears is not in the batch: SDD 107.)
local function held(id) return ns.HeldCount(id, true) end

--- The current batch (Ledger.Batch, SDD 107).
function Window.Batch() return Ledger.Batch(ns.db.ledger, ns.db.posted, held) end

--- "2x Soul Dust, 1x Greater Astral Essence": units of each material, the most valuable first.
local function matsText(units)
    local names = {}
    for id, n in pairs(units) do if n > 0 then names[#names + 1] = { id = id, n = n } end end
    table.sort(names, function(a, b)
        local va, vb = (ns.PriceOf(a.id) or 0), (ns.PriceOf(b.id) or 0)
        if va ~= vb then return va > vb end
        return a.id < b.id
    end)
    for i, m in ipairs(names) do names[i] = m.n .. "x " .. ns.MaterialName(m.id) end
    return table.concat(names, ", ")
end

--- The current batch (SDD 107): the gear you picked up and have not disenchanted (first: what you act on), then
--- the disenchants whose materials are not all posted, newest first, each under its status heading with totals,
--- and the batch's totals last: what it cost, what it was expected to make, what the disenchants gave so far
--- against what they were expected to give, and the materials still to post.
local NOT_YET, NONE, IN_MAIL = GREY .. "not disenchanted yet|r", GREY .. "-|r", GREY .. "in the mail|r"
local function ilvlText(ilvl) return ilvl and tostring(ilvl) or NONE end

-- The Current batch's columns (COLUMNS.batch), by name: the Disenchant panel shows some of them (SDD 112).
Window.BATCH_COLUMNS = COLUMNS.batch
Window.BATCH = { gear = 1, ilvl = 2, paid = 3, ev = 4, ep = 5, got = 6, dv = 7, dvev = 8, profit = 9, left = 10, now = 11 }

--- A purchase's profit before its disenchant: the range the Gear tab showed when it was bought (pessimistic -
--- average - optimistic, SDD 116), or the average alone for a purchase from before 0.3.152.
local function profitRange(p)
    if not p.ev then return NONE end
    local paid, j = p.each or 0, p.j or {}
    if j.lo and j.hi then return ns.RangeText(j.lo - paid, p.ev - paid, j.hi - paid) end
    return gap(p.ev - paid)
end

--- A row of the Current batch for a piece not disenchanted yet (an entry of Ledger.Batch's `waiting`): its cells in
--- the order of COLUMNS.batch, and its numbers (paid, ev). One builder for the Ledger and the Disenchant panel.
function Window.BatchWaitingRow(p)
    local ilvl = (p.j and p.j.ilvl) or (p.link and ns.ItemLevelOf(p.link)) or ns.db.ilvl[p.itemID]
    return { itemID = p.itemID, link = p.link, indent = INDENT, paid = p.each or 0, ev = p.ev or 0,
        cells = { itemName(p.itemID, p.link), ilvlText(ilvl), money(p.each), money(p.ev), profitRange(p),
            NOT_YET, NONE, NONE, NONE, NONE, NONE } }
end

--- A row of the Current batch for a purchase still in the mail (an entry of Ledger.Batch's `mail`): as one not
--- disenchanted yet, its materials cells "in the mail" (grey).
function Window.BatchMailRow(p)
    local row = Window.BatchWaitingRow(p)
    row.cells[6] = IN_MAIL
    return row
end

--- A row of the Current batch for a disenchant (an entry of Ledger.Batch's `done`): its cells in the order of
--- COLUMNS.batch, and its numbers (paid, ev, got = its Disenchant value, units not posted, now = their value now).
function Window.BatchDoneRow(x)
    local r = x.rec
    local ev, paid = r.evAtBuy or r.planned or 0, r.cost or 0
    local now = 0
    for id, n in pairs(x.left) do now = now + n * (ns.UnitValue(id) or 0) end
    now = math.floor(now + 0.5)
    return { itemID = r.itemID, link = r.link, indent = INDENT, paid = paid, ev = ev, got = r.value or 0,
        units = x.units, now = now,
        cells = { itemName(r.itemID, r.link) .. (r.salvager and "  |cff9370db[Salvager]|r" or ""),
            ilvlText(r.ilvl or r.band), money(paid), money(ev), gap(ev - paid), matsText(r.got or {}),
            money(r.value or 0), share(r.value or 0, ev), signed((r.value or 0) - paid), matsText(x.left),
            ns.Money(now) } }
end

--- The cells of a batch total in COLUMNS.batch's order (Paid, EV, EP; DV, DV/EV %, Profit so far where `d.n` > 0).
function Window.BatchTotals(label, w, d)
    local function units(n) return n .. (n == 1 and " unit" or " units") end
    local paid, ev = w.paid + d.paid, w.ev + d.ev
    return { label, "", ns.Money(paid), ns.Money(ev), gap(ev - paid), "", d.n > 0 and ns.Money(d.got) or NONE,
        d.n > 0 and share(d.got, d.ev) or NONE, d.n > 0 and signed(d.got - d.paid) or NONE, units(d.units or 0),
        ns.Money(d.now or 0) }
end

function Window.BatchRows()
    local b = Window.Batch()
    local rows = {}
    if #b.mail == 0 and #b.waiting == 0 and #b.done == 0 then
        rows[1] = note("No batch: every purchase you made is picked up and disenchanted, and its materials are posted.")
        return rows
    end
    local m = { n = #b.mail, paid = 0, ev = 0 }
    local mRows = {}
    for _, p in ipairs(b.mail) do
        local row = Window.BatchMailRow(p)
        m.paid, m.ev = m.paid + row.paid, m.ev + row.ev
        mRows[#mRows + 1] = row
    end
    local w = { n = #b.waiting, paid = 0, ev = 0 }
    local wRows = {}
    for _, p in ipairs(b.waiting) do
        local row = Window.BatchWaitingRow(p)
        w.paid, w.ev = w.paid + row.paid, w.ev + row.ev
        wRows[#wRows + 1] = row
    end
    local d = { n = #b.done, paid = 0, ev = 0, got = 0, units = 0, now = 0 }
    local dRows = {}
    for _, x in ipairs(b.done) do
        local row = Window.BatchDoneRow(x)
        d.paid, d.ev, d.got, d.units, d.now = d.paid + row.paid, d.ev + row.ev, d.got + row.got, d.units + row.units,
            d.now + row.now
        dRows[#dRows + 1] = row
    end
    local state = ns.GroupState("ledger.batch")
    local function refresh() Window.Refresh() end
    local function units(n) return n .. (n == 1 and " unit" or " units") end
    -- In the mail first (still to pick up), then not disenchanted, then disenchanted and not posted.
    if m.n > 0 then
        local h = { group = true, cells = { "In the mail" .. GREY .. "  " .. pieces(m.n) .. "|r", "",
            ns.Money(m.paid), ns.Money(m.ev), gap(m.ev - m.paid), "", "", "", "", "", "" },
            tip = { "In the mail", "Gear you bought with Buy whose \"Auction won\" mail you have not taken yet. Paid, "
                .. "Avg value and the average profit (sums of averages: averages too)." } }
        rows[#rows + 1] = h
        if ns.HeadingToggle(h, state, "mail", refresh) then
            for _, r in ipairs(mRows) do rows[#rows + 1] = r end
        end
    end
    if w.n > 0 then
        local h = { group = true, cells = { "Not disenchanted" .. GREY .. "  " .. pieces(w.n) .. "|r", "",
            ns.Money(w.paid), ns.Money(w.ev), gap(w.ev - w.paid), "", "", "", "", "", "" } }
        rows[#rows + 1] = h
        if ns.HeadingToggle(h, state, "waiting", refresh) then
            for _, r in ipairs(wRows) do rows[#rows + 1] = r end
        end
    end
    if d.n > 0 then
        local h = { group = true, cells = { "Disenchanted, not posted" .. GREY .. "  " .. pieces(d.n) .. "|r", "",
            ns.Money(d.paid), ns.Money(d.ev), gap(d.ev - d.paid), "", ns.Money(d.got), share(d.got, d.ev),
            signed(d.got - d.paid), units(d.units), ns.Money(d.now) } }
        rows[#rows + 1] = h
        if ns.HeadingToggle(h, state, "done", refresh) then
            for _, r in ipairs(dRows) do rows[#rows + 1] = r end
        end
    end
    -- The batch's totals, the last row (UI.md Tables 13).
    local all = { n = m.n + w.n, paid = m.paid + w.paid, ev = m.ev + w.ev }
    -- (Its label as short as the headings' (the count, grey): what is where is in its hover. The whole split in the
    -- label made the Gear column 371 px wide for names of 110, 0.4.0.)
    local split = pieces(all.n + d.n) .. ": " .. m.n .. " in the mail, " .. w.n .. " waiting, " .. d.n .. " disenchanted."
    rows[#rows + 1] = { bold = true, rule = "total",
        cells = Window.BatchTotals("Batch" .. GREY .. "  " .. pieces(all.n + d.n) .. "|r", all, d),
        tip = { "The batch", split, "Paid, Avg value and the average profit: every piece of the batch, the ones in the mail "
            .. "too (sums of averages: "
            .. "averages too). Disenchant value, DV/EV % and Profit so far: the pieces disenchanted so far, against their "
            .. "average value. "
            .. "Not posted yet and Value now: their materials still to post, at what they are worth now. Post them "
            .. "from the Materials window (the main window's Materials tab)." } }
    return rows
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
    local what = #waiting == 1 and " piece of gear" or " pieces of gear"
    rows[1] = { group = true, cells = { GOLD .. #waiting .. what .. " in the mail|r", "", "",
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

local BAG_ICON = "|TInterface\\Buttons\\Button-Backpack-Up:16:16:0:0|t"
local ALERT_ICON = "|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:14:14:0:0|t"
-- The game fonts have no "→": a small arrow the game ships.
local ARROW_ICON = "|TInterface\\ChatFrame\\ChatFrameExpandArrow:12:12:0:0|t"

--- The bag space for gear: bag icon, free/total now, and while items wait in the mail an arrow and the free
--- space after taking them all (one slot each: gear does not stack). Below 0 it is the slots missing, as a
--- negative, red with the alert sign after it (the sign, not the color alone, says it).
function Window.BagText()
    local free, total = ns.Items.BagSpace()
    local waiting = Window.NotPickedUpTotal()
    local now = string.format("%s %d/%d", BAG_ICON, free, total)
    if waiting == 0 then return now end
    local after = free - waiting
    if after < 0 then
        return string.format("%s %s %s%d/%d|r %s", now, ARROW_ICON, RED, after, total, ALERT_ICON)
    end
    return string.format("%s %s %d/%d", now, ARROW_ICON, after, total)
end

--- The widest bag space text (a column of live values keeps the width of its widest one, UI.md Tables 2).
Window.BAG_SAMPLE = string.format("%s 888/888 %s %s-888/888|r %s", BAG_ICON, ARROW_ICON, RED, ALERT_ICON)
--- The help on the bag space, wherever it shows (the Purchases view, the main window's footer).
Window.BAG_HELP = "Free slots / all slots of your backpack and bags, now; after the arrow: the free slots once you take "
    .. "every purchase still in the mail (one slot each). Below 0, red with the alert sign: that many slots are missing. "
    .. "Profession bags are left out: they do not hold gear."

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
        local built = time()
        rows[#rows + 1] = {
            itemID = r.itemID, link = r.link,
            -- A click shows where it stands among the other sellers' listings.
            onClick = r.commodity and function() ns.Stand.Show(r) end or nil,
            -- The countdown runs: only its cell is drawn again each second (list:RefreshLive).
            live = left and { [3] = function()
                local now = left - (time() - built)
                return countdown(now), now
            end } or nil,
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
            local left, built = due and dueOf(s), time()
            rows[#rows + 1] = {
                itemID = s.id,
                live = left and { [3] = function()
                    local now = left - (time() - built)
                    return GOLD .. countdown(now) .. "|r", now
                end } or nil,
                cells = { s.count .. "x " .. ns.MaterialName(s.id),
                    when(s.t),
                    due and (GOLD .. countdown(left) .. "|r") or (s.paidAt and when(s.paidAt) or (GREY .. "-|r")),
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

------------------------------------------------------------------ competition (SDD 109)

local EVENTS_SHOWN = 30   -- events listed under an opened competitor (the Reports have them all)

local function gapText(g) return g and (RED .. "-" .. ns.Money(math.floor(g + 0.5)) .. "|r") or "-" end
local function gapPct(p) return p and string.format("%s-%.1f%%|r", RED, p) or "-" end
local function lostText(c)
    c = math.floor((c or 0) + 0.5)
    return c > 0 and (RED .. "-" .. ns.Money(c) .. "|r") or ns.Money(0)
end
Window.GapText, Window.GapPct, Window.LostText = gapText, gapPct, lostText

--- Materials by name, the most often first ("Soul Dust, Vision Dust").
local function matList(order, n)
    local out = {}
    for i, m in ipairs(order) do
        if i > (n or 3) then out[#out] = out[#out] .. ", ..." break end
        out[#out + 1] = ns.MaterialName(m.id) or tostring(m.id)
    end
    return table.concat(out, ", ")
end
Window.MatList = matList

--- One row per competitor (all time), the most seen first: a heading that opens to its undercut events, newest first.
function Window.CompetitionRows()
    local state = ns.db.competition
    local comps = ns.Competition.Competitors(state)
    if #comps == 0 then
        return { note("No undercut seen yet. Check undercuts, the Post window's search and a material scan record who "
            .. "lists under your price.") }
    end
    local lost = ns.Competition.Lost(state)
    local rows, groups, total = {}, ns.GroupState("ledger.competition"), 0
    for _, g in ipairs(comps) do
        local name = g.key
        local seen = state.names[name] or { n = g.n, last = g.last }
        total = total + seen.n
        local by = lost.by[name] or { total = 0, cancel = 0, repost = 0, price = 0 }
        local head = { group = true, cells = { name, tostring(seen.n), when(seen.last), matList(g.matOrder),
            gapText(g.gap), gapPct(g.pct), ns.Money(g.lowest), lostText(by.total) },
            tip = { name, string.format("Lowest price seen: %s each, on %s.", ns.Money(g.lowest),
                ns.MaterialName(g.lowestId) or "?"),
                "Profit lost to them: cancel fees and deposits " .. lostText(by.cancel) .. ", deposits of the reposts "
                    .. lostText(by.repost) .. ", lower sale prices " .. lostText(by.price) .. ".",
                "Click: each time they were seen under you, newest first." } }
        rows[#rows + 1] = head
        if ns.HeadingToggle(head, groups, name, function() Window.Refresh() end, true) then
            local shown = 0
            for i = #state.events, 1, -1 do
                local e = state.events[i]
                if e.o == name then
                    shown = shown + 1
                    if shown > EVENTS_SHOWN then break end
                    rows[#rows + 1] = { indent = INDENT, itemID = e.id, cells = {
                        string.format("%d of theirs under your %d", e.q, e.u), "", when(e.t),
                        ns.MaterialName(e.id) or tostring(e.id), gapText(e.g), gapPct(e.my > 0 and e.g / e.my * 100 or 0),
                        ns.Money(e.p), "" },
                        tip = { ns.MaterialName(e.id) or "", string.format("%s: %d units at %s each, under your %d at %s each "
                            .. "(%s less).", ns.Date("%m-%d %H:%M", e.t), e.q, ns.Money(e.p), e.u, ns.Money(e.my), ns.Money(e.g)) } }
                end
            end
            if shown > EVENTS_SHOWN then
                rows[#rows + 1] = { indent = INDENT, cells = { GREY .. "older ones: Reports, Competition|r" } }
            end
        end
    end
    rows[#rows + 1] = { rule = "total", bold = true, cells = { "Total", tostring(total), "", "", "", "", "",
        lostText(lost.total) }, tip = { "Total", "Every undercut seen and every copper lost to competitors, all time." } }
    return rows
end

--- AP/EP %: how far the actual profit is from the expected one, in percent of the expected one
--- (which can be a loss, so its size). "-" where nothing was expected.
local function profitShare(actual, expected)
    if not expected or expected == 0 then return GREY .. "-|r" end
    local pct = math.floor((actual - expected) / math.abs(expected) * 100 + 0.5)
    return toned(pct, (pct > 0 and "+" or "") .. pct .. "%")
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

--- The Accuracy filter as a test of one disenchant (the filter read once, not per record).
local function accuracyKeep()
    local x = accuracyFilter()
    return function(r) return filterPasses(x, r.classID, r.quality, r.ilvl or r.band, r.salvager and true or false) end
end

function Window.AccuracyBandRows()
    local acc = Ledger.Accuracy(ns.db.ledger, accuracyKeep())
    local rows = {}
    local function row(b, name, group)
        local few = b.n < 20
        rows[#rows + 1] = { group = group, cells = { name, (few and GREY or "") .. b.n .. (few and "|r" or ""),
            ns.Money(b.paid), ns.Money(b.promised), ns.Money(b.got), share(b.got, b.promised), ns.Money(b.sold),
            share(b.sold, b.got) .. ((b.units > 0 and b.soldUnits < b.units / 2) and (GREY .. "*|r") or ""),
            gap(b.promised - b.paid), signed(math.floor(b.sold + 0.5) - b.paid),
            profitShare(math.floor(b.sold + 0.5) - b.paid, b.promised - b.paid) } }
    end
    if acc.total.n == 0 then
        rows[1] = note("Nothing to compare yet, or nothing under these filters: it needs gear you bought and then "
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
    -- (In the materials' order, as every material list: Data.SortMaterials.)
    for _, m in ipairs(Data.SortMaterials(Ledger.Accuracy(ns.db.ledger, accuracyKeep()).mats, function(x) return x.id end)) do
        local valued = m.units > 0 and m.valued / m.units or nil
        local sold = m.soldUnits > 0 and m.soldNet / m.soldUnits or nil
        rows[#rows + 1] = { itemID = m.id, cells = { ns.MaterialName(m.id), tostring(m.units),
            valued and ns.Money(valued) or (GREY .. "-|r"), sold and ns.Money(sold) or (GREY .. "not sold yet|r"),
            (valued and sold) and gap(sold - valued) or "", (valued and sold) and share(sold, valued) or "",
            m.soldUnits > 0 and tostring(m.soldUnits) or (GREY .. "0|r") } }
    end
    if #rows == 0 then rows[1] = note("No disenchant with a recorded purchase yet.") end
    return rows
end

--- The two lines above the list.
function Window.Summary()
    local bought, spent, done, got, waiting, waitingCost = 0, 0, 0, 0, 0, 0
    local waitingBy = {}
    for _, e in ipairs(Ledger.HistoryTotals(ns.db.ledger)) do
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
        string.format("%sBought|r %d pieces of gear for %s", GOLD, bought, ns.Money(spent)),
        string.format("%sDisenchanted|r %d, materials worth %s after the cut", GOLD, done, ns.Money(got)),
    }
    if waiting > 0 then
        -- Where those items are: counted in the bags and the bank; the rest is taken to be in the mail.
        local bags, bank = 0, 0
        for id, n in pairs(waitingBy) do
            -- (Worn pieces are not counted: they are not waiting for a disenchant.)
            local inBags = math.min(n, ns.HeldCount(id) or 0)
            bags = bags + inBags
            bank = bank + math.min(n - inBags, math.max(0, (ns.HeldCount(id, true) or 0) - inBags))
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

local VIEWS = { sales = true, purchases = true, accuracy = true }

------------------------------------------------------------------ the window

-- The Sales view's two tables share the height under the tabs; the bar between them moves the border.
local SPLIT_DEFAULT = 0.45
-- From the top (UI.md Controls 1): the tabs (24 to 54 px), the view's subtabs, its filter row, the tables; the
-- footer (FOOT px) has two lines: the totals (one line of the whole width), and under them the view's actions.
local TABS_TOP, FOOT = 24, 70
local bars = {}          -- the rows: tabs, sales and purchases (subtabs), purchaseFilters, accuracyFilters, totals, footer
local contentTop = 86    -- where the tables of the view on show start (set by Window.Refresh)
local function salesRoom()
    return (f:GetHeight() or 0) - contentTop - FOOT - 44   -- (the titles: the upper one 20 px, the lower one 24)
end

--- Sets how much of the room the upper Sales table takes (0.1 to 0.9), and remembers it.
function Window.SetSalesSplit(part)
    if not f then return end
    f.saved.salesSplit = math.max(W.SPLIT_LO, math.min(W.SPLIT_HI, part))
    Window.Refresh()
end

local WIDTH = 890   -- the width it opens with, before its content is measured (Widgets.FitTables sets it)
-- The least height (SDD 113): the rows above the tables (the tabs, a subtab row or a filter row), two titles, two
-- tables of TABLE_MIN each and the footer, so the Sales and Accuracy tables never overlap.
local MIN_H = TABS_TOP + W.BAR_H.tabs + 4 + W.BAR_H.filters + 4 + 44 + 2 * W.TABLE_MIN + FOOT

function Window.Refresh()
    if not f or not f:IsShown() then return end
    -- Sales (its first subtab) and Accuracy are two tables, each in its own panel; the other views are one.
    local accuracy = Window.view == "accuracy"
    local sales = Window.view == "sales"
    local history = sales and f.saved.salesTab == "history"
    local competition = sales and f.saved.salesTab == "competition"
    local split = (sales and not history and not competition) or accuracy
    list:SetShown(not split)
    -- The Sales view has a row of subtabs, the Purchases view its search and filters; the tables start under.
    local purchases = Window.view == "purchases"
    local purchaseTab = Window.PurchaseTab()
    local mailTab = purchases and purchaseTab == "mail"
    local batchTab = purchases and purchaseTab == "batch"
    -- Under the tabs: the view's subtabs (Sales, Purchases), then its filter row (Purchases' first subtab,
    -- Accuracy), then its tables.
    local top = TABS_TOP + W.BAR_H.tabs + 4
    bars.sales:SetShown(sales)
    bars.purchases:SetShown(purchases)
    if sales or purchases then top = top + W.BAR_H.subtabs + 4 end
    local filterBar = (purchases and purchaseTab == "all" and bars.purchaseFilters) or (accuracy and bars.accuracyFilters)
        or nil
    for _, b in ipairs({ bars.purchaseFilters, bars.accuracyFilters }) do b:SetShown(b == filterBar) end
    for _, c in ipairs((filterBar == bars.purchaseFilters and purchaseControls)
        or (filterBar == bars.accuracyFilters and accuracyControls) or {}) do
        if c.Update then c:Update() end
    end
    if filterBar then
        filterBar:Place(top, 12, 12)
        top = top + W.BAR_H.filters + 4
    end
    contentTop = top
    local salesTab = (history and "history") or (competition and "competition") or "open"
    for key, b in pairs(salesTabs) do b:SetSelected(key == salesTab) end
    for key, b in pairs(purchaseTabs) do b:SetSelected(key == purchaseTab) end
    bagLabel:SetShown(purchases)
    bagArea:SetShown(purchases)
    if purchases then
        purchaseTabs.mail:SetText(string.format("Not picked up (%d)", (Window.NotPickedUpTotal())))
        local batch = Window.Batch()
        purchaseTabs.batch:SetText(string.format("Current batch (%d)", #batch.mail + #batch.waiting + #batch.done))
        bagLabel:SetText(Window.BagText())
    end
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -top)
    salesParts[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -top - 2)
    salesParts[2]:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -top - 20)
    salesParts[2]:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -top - 20)
    for _, part in ipairs(salesParts) do part:SetShown(split) end
    if split then
        -- The upper table takes the share of the room that the bar between the tables was dragged to.
        salesParts[2]:SetHeight(W.SplitHeight(salesRoom(), f.saved.salesSplit or SPLIT_DEFAULT))
    end
    if accuracy then
        salesParts[1]:SetText(GOLD .. "By band|r" .. GREY .. "  average value, disenchant value, sold value|r")
        salesParts[3]:SetText(GOLD .. "By material|r" .. GREY .. "  disenchant value against sold value, per unit|r")
        local bands, mats = Window.AccuracyBandRows(), Window.AccuracyMaterialRows()
        salesParts[2]:SetColumns(COLUMNS.accBands, "accBands")
        salesParts[2]:SetSource(#bands, function(i) return bands[i] end)
        salesParts[2]:Refresh()
        salesParts[4]:SetColumns(COLUMNS.accMats, "accMats")
        salesParts[4]:SetSource(#mats, function(i) return mats[i] end)
        salesParts[4]:Refresh()
    elseif split then
        local l = ns.db.listings
        salesParts[1]:SetText(GOLD .. "Open auctions|r" .. (l.t and (GREY .. "  as of " .. ns.Date("%H:%M", l.t) .. "|r") or "")
            .. GREY .. "  click one to see where it stands|r")
        salesParts[3]:SetText(GOLD .. "Sold|r" .. GREY .. "  the money is on its way, or waits in your mail|r")
        local listed, paid = Window.ListingRows(), Window.SoldRows(false)
        salesParts[2]:SetColumns(COLUMNS.listed, "listed")
        salesParts[4]:SetColumns(COLUMNS.paid, "paid")
        salesParts[2]:SetSource(#listed, function(i) return listed[i] end)
        salesParts[2]:Refresh()
        salesParts[4]:SetSource(#paid, function(i) return paid[i] end)
        salesParts[4]:Refresh()
    elseif competition then
        local rows = Window.CompetitionRows()
        list.onSort = nil
        list:SetColumns(COLUMNS.competition, "competition")
        list:SetSource(#rows, function(i) return rows[i] end)
        list:Refresh()
    elseif history then
        local rows = Window.SoldRows(true)
        list.onSort = nil
        list:SetColumns(COLUMNS.history, "history")
        list:SetSource(#rows, function(i) return rows[i] end)
        list:Refresh()
    elseif batchTab then
        local rows = Window.BatchRows()
        list.onSort = nil
        list:SetColumns(COLUMNS.batch, "batch")
        list:SetSource(#rows, function(i) return rows[i] end)
        list:Refresh()
    elseif mailTab then
        local rows = Window.NotPickedUpRows()
        list.onSort = nil
        list:SetColumns(COLUMNS.waiting, "waiting")
        list:SetSource(#rows, function(i) return rows[i] end)
        list:Refresh()
    else
        local rows = Window.PurchaseRows()
        -- The title it is ordered by shows an arrow; a click on a title orders by it, again turns it round.
        local sort, cols = Window.PurchaseSort(), {}
        for i, col in ipairs(COLUMNS.purchases) do
            cols[i] = { col[1], col[2], col[3], help = col.help, key = col[1] }
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
        list:SetColumns(cols, "purchases")
        list:SetSource(#rows, function(i) return rows[i] end)
        list:Refresh()
    end
    -- As wide as the tables on show need (all their columns, the first one not cut, SDD 91), at least its own width,
    -- and no wider (SDD 113): each view sets it again, so a view that needs less makes it narrower.
    local shown = split and { salesParts[2], salesParts[4] } or { list }
    summary:SetText((Window.Summary()))
    W.FitTables(f, shown, Window.view .. (sales and ("/" .. salesTab) or purchases and ("/" .. purchaseTab) or ""))
    for name, button in pairs(tabs) do button:SetSelected(name == Window.view) end
    -- The two listing buttons belong to the Sales view; the bag space to the Purchases view. The totals have a
    -- line of their own above them, so no view's controls cut them.
    checkButton:SetShown(sales)
    cancelButton:SetShown(sales)
    autoButton:SetShown(sales)
    if sales then
        local c, n = ns.Listings.checking, ns.Listings.CountUndercut()
        -- Only what is still for sale can be undercut: sold auctions are not checked.
        local unsold = ns.Listings.CountUnsold()
        checkButton:SetText(c and string.format("Checking %d/%d", c.done, c.total)
            or string.format("Check undercuts (%d)", unsold))
        local open = ns.Queue.open
        checkButton:SetEnabled(open and not c and unsold > 0)
        checkButton.reason = (not open and W.AH_CLOSED) or (c and "A check is running.")
            or (unsold == 0 and "Nothing of yours is for sale.") or nil
        cancelButton:SetText(ns.Listings.Cancelling() and "Cancelling..." or string.format("Cancel undercut (%d)", n))
        -- CancelAuction needs the click itself: it cannot wait for a purchase, so the button is off meanwhile.
        local buying = ns.Scanner.Buying()
        cancelButton.reason = (not open and W.AH_CLOSED)
            or (buying and "A purchase is on its way: Cancel comes back as soon as it is done.")
            or (ns.Listings.Cancelling() and "A cancel is on its way.")
            or (n == 0 and "None of your listings is undercut by more than a cancel and a new post cost (check first).")
            or nil
        cancelButton:SetEnabled(open and n > 0 and not ns.Listings.Cancelling() and not buying)
        autoButton:SetEnabled(open)
        autoButton:SetRunning(open and ns.Listings.auto)
        autoButton:UpdateGlyph()
        autoButton.reason = not open and W.AH_CLOSED or nil
    end
end

local function build()
    -- As wide as its tables need; the height is the player's.
    f = W.Window("SalvagerLedgerFrame", "Salvager Ledger", "ledger", WIDTH, 480, WIDTH, MIN_H, "vertical")
    f.layoutName = "ledger"
    -- The footer, two lines: the ledger's totals (one short line of the whole width, all of them behind the chart
    -- button before it), and under them the view's actions or its bag space at the right.
    bars.footer = W.Bar(f, "footer"):PlaceBottom(8, 12, 24)
    bars.totals = W.Bar(f, "footer"):PlaceBottom(8 + W.BAR_H.footer + 4, 12, 24)
    local details = W.HelpButton(bars.totals, "Totals", function() return select(2, Window.Summary()) end, {
        glyph = "chart", left = true, up = true,
        tooltip = { "Totals", "Click to see every total of the ledger, one per line." } })
    bars.totals:Add(details, 22)
    summary = W.Label(bars.totals, "", "GameFontHighlightSmall")
    bars.totals:Add(summary, 300)
    summary:SetPoint("RIGHT", bars.totals, "RIGHT", -2, 0)
    summary:SetJustifyH("LEFT")
    summary:SetWordWrap(false)
    bars.tabs = W.Bar(f, "tabs"):Place(TABS_TOP, 12, 12)
    for _, t in ipairs({ { "sales", "Sales" }, { "purchases", "Purchases" }, { "accuracy", "Accuracy" } }) do
        local b = W.Tab(bars.tabs, t[2], function()
            Window.view = t[1]
            f.saved.view = t[1]
            list.offset = 0
            Window.Refresh()
        end)
        bars.tabs:Add(b, 90)
        tabs[t[1]] = b
    end
    W.Tooltip(tabs.accuracy, "Accuracy", "The average value when you bought, against the disenchant value of what you got, "
        .. "against the sold value. By band and by material.")
    W.Tooltip(tabs.purchases, "Purchases", "All gear you bought, by day (newest first), then not disenchanted and "
        .. "disenchanted. Under each one: what it was disenchanted into and what it was worth then. The Not picked up "
        .. "subtab has what still waits in the mail, with your bag space; Current batch what you picked up and have "
        .. "not disenchanted or not posted yet.")
    W.Tooltip(tabs.sales, "Sales", "Your open auctions, and what is sold with its money still to collect. The History "
        .. "subtab has the sales you have collected; Competition who undercuts you. Profit = what you get after the cut, minus what those "
        .. "materials cost you.")
    -- (Clear history is in the options, with the backups.)
    cancelButton = W.Button(bars.footer, "Cancel undercut (0)", 150, function() ns.Listings.CancelNext() end,
        "Cancels one undercut listing per click (the game wants a click for each). The materials come back by mail, "
        .. "and the auction house keeps its deposit. Needs the auction house open, and a check first.")
    -- The Sales view's actions, at the footer's right end; Cancel the last one (UI.md Actions 5).
    bars.footer:AddRight(cancelButton, 150)
    cancelButton:SetMotionScriptsWhileDisabled(true)
    cancelButton:HookScript("OnEnter", function(self)
        local why = self.reason
        if why then GameTooltip:AddLine(why, 1, 0.3, 0.3, true) GameTooltip:Show() end
    end)
    checkButton = W.Button(bars.footer, "Check undercuts (0)", 150, function() ns.Listings.Check() end,
        "Searches each material you still have for sale and compares your price with the lowest listing that is not "
        .. "yours. Auctions that are sold are not checked. The number is how many listings are still for sale. "
        .. "About one second per material. Needs the auction house open.")
    bars.footer:AddRight(checkButton, 150)
    W.ReasonTip(checkButton)
    -- Left of it: the check again and again (the user, 2026-11-27), one toggle: play while off, stop while on.
    autoButton = W.PlayToggle(bars.footer, 24, function()
        if not ns.Queue.open then return end
        ns.Listings.SetAuto(not ns.Listings.auto)
    end)
    autoButton:SetMotionScriptsWhileDisabled(true)
    autoButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        local every = ns.Listings.AUTO_INTERVAL
        if ns.Listings.auto then
            GameTooltip:SetText("Stop checking undercuts", 1, 1, 1)
            GameTooltip:AddLine(string.format("On: your listings are checked every %d seconds while the auction house "
                .. "is open. Click to stop.", every), 1, 0.82, 0, true)
        else
            GameTooltip:SetText("Check undercuts again and again", 1, 1, 1)
            GameTooltip:AddLine(string.format("Checks your listings now and again every %d seconds while the auction "
                .. "house is open, so you see an undercut after everything is posted. It waits while you buy and "
                .. "during a material scan. Off when the auction house closes. Cancel undercut stays a click.", every),
                1, 0.82, 0, true)
        end
        if self.reason then GameTooltip:AddLine(self.reason, 1, 0.3, 0.3, true) end
        GameTooltip:Show()
    end)
    autoButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    bars.footer:AddRight(autoButton, 24, 6)
    Window.autoButton, Window.checkButton, Window.cancelButton = autoButton, checkButton, cancelButton
    -- The bag space (the Purchases view), where the Sales actions are in that view.
    bagLabel = W.Label(bars.footer, "", "GameFontHighlightSmall")
    bagLabel:SetPoint("RIGHT", bars.footer, "RIGHT", -2, 0)
    bagLabel:SetJustifyH("RIGHT")
    bagArea = W.HelpArea(bars.footer, bagLabel, "Bag space", Window.BAG_HELP)
    bars.footer:Track(bagLabel, "R")
    bagLabel:Hide()
    bagArea:Hide()
    list = W.List(f, { rowHeight = 22 })
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -contentTop)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, FOOT)
    -- The Sales view: a title and a table for your auctions, a title and a table for the paid sales.
    local titleA = W.Label(f, "", "GameFontNormal")
    titleA:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -contentTop - 2)
    local listA = W.List(f, { rowHeight = 22 })
    listA:SetColumns(COLUMNS.listed, "listed")
    listA:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -contentTop - 20)
    listA:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -contentTop - 20)
    listA:SetHeight(120)
    local titleB = W.Label(f, "", "GameFontNormal")
    titleB:SetPoint("TOPLEFT", listA, "BOTTOMLEFT", 2, -6)
    local listB = W.List(f, { rowHeight = 22 })
    listB:SetColumns(COLUMNS.paid, "paid")
    listB:SetPoint("TOPLEFT", listA, "BOTTOMLEFT", 0, -24)
    listB:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, FOOT)
    -- A column shown or hidden with a table's chooser: the window fits its tables again.
    for _, l in ipairs({ list, listA, listB }) do l.onColumnsChanged = function() Window.Refresh() end end
    -- The bar between the two tables: drag it up or down to make one table taller and the other shorter.
    local bar = W.SplitBar(f, listA, salesRoom, function(part)
        if part then Window.SetSalesSplit(part) else f.saved.salesSplit = nil Window.Refresh() end
    end)
    salesParts = { titleA, listA, titleB, listB, bar }
    -- The subtabs of the Sales view: what is open and what is sold; and the history.
    bars.sales = W.Bar(f, "subtabs"):Place(TABS_TOP + W.BAR_H.tabs + 4, 12, 12)
    for _, t in ipairs({ { "open", "Open and sold", "Your open auctions, and what is sold with its money still to collect." },
        { "history", "History", "The sales whose money you have taken from the mail, newest first." },
        { "competition", "Competition", "Who undercuts you: each seller whose listing was under one of your auctions, "
            .. "the most seen first, with what it cost you. Click one to see each time." } }) do
        local b = W.Subtab(bars.sales, t[2], function()
            f.saved.salesTab = t[1]
            list.offset = 0
            Window.Refresh()
        end, t[3])
        bars.sales:Add(b, t[1] == "open" and 100 or t[1] == "competition" and 84 or 60)
        salesTabs[t[1]] = b
    end
    -- The subtabs of the Purchases view: every purchase; and what waits in the mail.
    bars.purchases = W.Bar(f, "subtabs"):Place(TABS_TOP + W.BAR_H.tabs + 4, 12, 12)
    for _, t in ipairs({ { "all", "All purchases", "All gear you bought, with what each piece was disenchanted into." },
        { "mail", "Not picked up", "The gear you bought with Buy whose \"Auction won\" mail you have not taken "
            .. "yet, the first bought first. The number is how many." },
        { "batch", "Current batch", "The gear you bought and have not disenchanted yet (in the mail or picked up), "
            .. "and what you disenchanted whose materials are not all posted yet: what the batch cost, its average "
            .. "value, and what it has made so far. A piece leaves when all its materials are posted. The number counts "
            .. "every piece, the ones in the mail too." } }) do
        local b = W.Subtab(bars.purchases, t[2], function()
            f.saved.purchaseTab = t[1] ~= "all" and t[1] or nil
            list.offset = 0
            Window.Refresh()
        end, t[3])
        bars.purchases:Add(b, t[1] == "all" and 90 or 120)
        purchaseTabs[t[1]] = b
    end
    bars.purchases:Hide()
    Window.purchaseTabs, Window.bagLabel = purchaseTabs, bagLabel   -- (the specs click and read them)
    Window.bars, Window.tabs, Window.salesTabs = bars, tabs, salesTabs
    Window.salesParts = salesParts
    -- The Purchases view: a search box, and filters by gear type, quality and item level band.
    do
        local pf = purchaseFilter()
        local function changed()
            list.offset = 0
            Window.Refresh()
        end
        -- The filter row: the search first, then the filters (UI.md Controls 6).
        local fbar = W.Bar(f, "filters")
        bars.purchaseFilters = fbar
        -- (The one search box of every window, Widgets.Search: the X and Escape clear it.)
        local SEARCH_HELP = "Shows the gear whose name has this text in it, in any case."
        local search = W.Search(fbar, 120, function() return pf.search or "" end, function(text)
            pf.search = text
            changed()
        end, SEARCH_HELP)
        fbar:AddFilter("Search", search, 120, SEARCH_HELP)
        purchaseControls = filterRow(fbar, pf, changed, false)
        -- Show: one choice, All gear first (UI.md Controls 5).
        local SHOW_HELP = "All gear you bought, only what is disenchanted, or only what is not disenchanted yet."
        local show
        show = W.Dropdown(fbar, 150, { { "all", "All gear" }, { "done", "Disenchanted" },
            { "waiting", "Not disenchanted" } },
            function(key) return purchaseFilter().show == key end,
            function(key)
                purchaseFilter().show = key
                show:Close()
                changed()
            end, SHOW_HELP, "Show")
        fbar:AddFilter("Show", show, 150, SHOW_HELP)
        purchaseControls[#purchaseControls + 1] = show
        fbar:Hide()
    end
    -- The Accuracy view: the filter row, Salvager too.
    do
        bars.accuracyFilters = W.Bar(f, "filters")
        accuracyControls = filterRow(bars.accuracyFilters, accuracyFilter(), function()
            salesParts[2].offset, salesParts[4].offset = 0, 0
            Window.Refresh()
        end, true)
        bars.accuracyFilters:Hide()
    end
    if VIEWS[f.saved.view] then Window.view = f.saved.view end
    f.onResize = Window.Refresh
    f:HookScript("OnShow", Window.Refresh)
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
end

-- The countdowns of the Sales view run: once a second while it shows, only their cells (list:RefreshLive; the whole
-- table each second took 2.4 ms at ten times the data). One that reaches 0 draws the view again.
local lastCount = 0
ns.OnTick(function()
    if f and f:IsShown() and Window.view == "sales" and GetTime() - lastCount >= 1 then
        lastCount = GetTime()
        local parts = Window.salesParts
        if not (parts and parts[2]:IsShown()) then return end
        local a, b = parts[2]:RefreshLive(), parts[4]:RefreshLive()
        if a or b then Window.Refresh() end
    end
end)

for _, e in ipairs({ "SALVAGER_LEDGER", "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS", "SALVAGER_LISTINGS",
    "SALVAGER_COMPETITION", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do
    ns.On(e, function() Window.Refresh() end)
end
-- The bag space of the Purchases view is live while it shows.
ns.On("BAG_UPDATE_DELAYED", function() if Window.view == "purchases" then Window.Refresh() end end)

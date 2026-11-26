-- Salvager: the Reports window. What the trading made, for a time you pick:
--   Gold       your gold: start, now, the money in the mail, each kind of change, every change
--   Profit     by quality and gear type, and by item level band under each
--   Materials  what each material gave, sold for and cost, and what is left
--   Items      by item: which ones paid
local _, ns = ...

local Ledger, W = ns.Ledger, ns.Widgets

local Reports = { view = "gold", range = "24h",
    -- The Profit and Items views' filters (kept in the window's saved data).
    filter = { classes = { [4] = true, [2] = true }, qualities = { [2] = true, [3] = true, [4] = true }, bandsOff = {},
        salvager = "all" } }
ns.Reports = Reports

local GREY, GOLD, GREEN, RED = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040"
local INDENT = 22
local FEW = 20   -- fewer disenchants than this: the numbers rest on few samples (grey)

local RANGES = {
    { "24h", "Last 24 hours", 86400 },
    { "7d", "Last 7 days", 7 * 86400 },
    { "30d", "Last 30 days", 30 * 86400 },
    { "all", "All", nil },
}
local ORDER = { "gold", "profit", "materials", "items" }
local TITLES = { gold = "Gold", profit = "Profit", materials = "Materials", items = "Items" }
local HELP = {
    gold = "Your gold: where it started, where it is, the money still in the mail, and every change by its kind.",
    profit = "What your disenchants made, by quality and gear type, and by item level band under each.",
    materials = "Each material: how many you got and sold, what they sold for and cost, and what is left.",
    items = "Each item you bought and disenchanted: which ones paid, best first.",
}

local function money(c) return c and ns.Money(c) or "-" end
local function signed(c)
    c = math.floor((c or 0) + 0.5)
    return (c >= 0 and (GREEN .. "+") or RED) .. ns.Money(c) .. "|r"
end
local function pct(part, whole)
    if not whole or whole == 0 then return GREY .. "-|r" end
    local p = math.floor(part / whole * 100 + 0.5)
    return (p >= 0 and (GREEN .. "+") or RED) .. p .. "%|r"
end
local function note(text) return { cells = { GREY .. text .. "|r" } } end
local function count(n) return (n < FEW and GREY or "") .. n .. (n < FEW and "|r" or "") end

--- The start of the time picked (nil = all), and its name.
function Reports.From()
    for _, r in ipairs(RANGES) do
        if r[1] == Reports.range then return r[3] and (time() - r[3]) or nil, r[2] end
    end
    return nil, "All"
end

local COLUMNS = {
    goldSum = { { "Gold", 200 }, { "Amount", 90, "RIGHT" },
        { "Times", 50, "RIGHT", help = { "Times", "How many changes of gold of this kind." } } },
    goldLog = { { "What", 200 }, { "Time", 90 }, { "Change", 90, "RIGHT" },
        { "Kind", 140, "LEFT", help = { "Kind", "What the change was: told by what the addon did (a purchase, a "
            .. "deposit, a mail taken), else by the window open then (vendor, mailbox, trade)." } },
        { "Gold after", 90, "RIGHT" } },
    profit = { { "Band", 190 }, { "Items", 44, "RIGHT", help = { "Items", "Disenchants of items whose price is "
            .. "known. Grey: fewer than 20, too few to trust." } },
        { "With Salvager", 60, "RIGHT", help = { "With Salvager", "How many of them had the Arcane Salvager's bonus." } },
        { "Paid", 80, "RIGHT" },
        { "Disenchant value", 90, "RIGHT", help = { "Disenchant value", "What the materials were worth when you "
            .. "disenchanted, after the cut." } },
        { "Sold value", 90, "RIGHT", help = { "Sold value", "The materials at what one unit really sold for on "
            .. "average, after the cut (at their disenchant value while that material has not sold yet)." } },
        { "Profit", 80, "RIGHT", help = { "Profit", "Sold value minus Paid." } },
        { "Return", 50, "RIGHT", help = { "Return", "Profit as a share of Paid." } },
        { "Profit each", 70, "RIGHT" } },
    materials = { { "Material", 170 },
        { "Got", 44, "RIGHT", help = { "Got", "Units your disenchants gave in this time." } },
        { "Sold", 44, "RIGHT" },
        { "Sold for", 80, "RIGHT", help = { "Sold for", "What the sales brought, after the cut." } },
        { "Cost of sold", 80, "RIGHT", help = { "Cost of sold", "The part of what you paid for the gear that went to "
            .. "the units sold." } },
        { "Deposits lost", 70, "RIGHT", help = { "Deposits lost", "Deposits of auctions that were cancelled or ran out." } },
        { "Profit", 80, "RIGHT", help = { "Profit", "Sold for, minus the cost of the units with a known cost, minus "
            .. "the deposits lost." } },
        { "Held", 44, "RIGHT", help = { "Held", "Units in your bags and your bank now." } },
        { "Listed", 44, "RIGHT", help = { "Listed", "Units on the auction house now, not sold yet (as of the last "
            .. "time the addon read your auctions)." } },
        { "Value", 80, "RIGHT", help = { "Value", "Held and listed units at the price now, after the cut." } } },
    items = { { "Item", 220 }, { "Items", 44, "RIGHT" }, { "Paid each", 70, "RIGHT" },
        { "Sold value each", 80, "RIGHT" }, { "Profit", 80, "RIGHT" }, { "Return", 50, "RIGHT" } },
}

--- Does a disenchant pass the filters? (Gear type, quality, item level band, with or without the Salvager.)
function Reports.Keep(r)
    local x = Reports.filter
    if not x.classes[r.classID] or not x.qualities[r.quality] then return false end
    if x.salvager == "with" and not r.salvager then return false end
    if x.salvager == "without" and r.salvager then return false end
    local ilvl = r.ilvl or r.band or 0
    for _, b in ipairs(ns.LevelBands()) do
        if ilvl <= b.up then return not x.bandsOff[b.up] end
    end
    return true
end

------------------------------------------------------------------ rows

--- The Gold view: the sums of the time picked, and every change of gold in it, newest first.
function Reports.GoldRows()
    local from = Reports.From()
    local hours = (time() - (from or 0)) / 3600
    local s = ns.Gold.Period(hours)
    if not s then
        local none = note("No gold recorded yet: every change of your gold is recorded from now on.")
        return { none }, { none }
    end
    local sums = {
        { cells = { "At the start", ns.Money(s.start), "" } },
        { cells = { "Now", ns.Money(s.finish), "" } },
        { cells = { "Change", signed(s.change), "" } },
    }
    if s.mailSales > 0 then
        sums[#sums + 1] = { cells = { "In the mail (sold, not collected)", ns.Money(s.mail), tostring(s.mailSales) } }
        sums[#sums + 1] = { cells = { "After you collect it", ns.Money(s.finish + s.mail), "" } }
        sums[#sums + 1] = { cells = { "Change after you collect it", signed(s.change + s.mail), "" } }
    end
    for _, k in ipairs(ns.Journal.KINDS) do
        local x = s.kinds[k[1]]
        if x then sums[#sums + 1] = { cells = { GREY .. k[2] .. "|r", signed(x.gain + x.loss), tostring(x.n) } } end
    end
    if #s.losses > 0 then
        sums[#sums + 1] = { cells = { "Buys that lost", signed(s.lost), tostring(#s.losses) } }
        if s.lostWrong < 0 then
            sums[#sums + 1] = { cells = { RED .. "  of it valued wrong|r", signed(s.lostWrong), "" } }
        end
    end
    local log = {}
    for i = #s.entries, 1, -1 do
        local e = s.entries[i]
        if e.k ~= "start" then
            log[#log + 1] = { cells = { e.r or GREY .. "-|r", date("%m-%d %H:%M", e.t), signed(e.d),
                ns.Journal.KIND_NAME[e.k] or e.k, ns.Money(e.b) }, link = e.r and e.r:match("|Hitem:[^|]+|h") and e.r }
        end
    end
    if #log == 0 then log[1] = note("No change of gold in this time.") end
    return sums, log
end

local function profitCells(x, name)
    local profit = math.floor(x.sold + 0.5) - x.paid
    return { name, count(x.n), tostring(x.salvager), money(x.paid), money(x.value), money(math.floor(x.sold + 0.5)),
        signed(profit), pct(profit, x.paid), x.n > 0 and signed(profit / x.n) or "-" }
end

--- By gear type (a heading with its totals), by quality under it (with its totals), and by item level band
--- under each quality (the range only).
function Reports.ProfitRows()
    local p = Ledger.Profits(ns.db.ledger, (Reports.From()), Reports.Keep)
    if p.total.n == 0 then
        return { note("No disenchant of an item with a known price in this time and these filters. Buy from the "
            .. "Deals tab, then disenchant.") }
    end
    local rows = { { group = true, cells = profitCells(p.total, GOLD .. "All|r") } }
    local bands = {}
    for _, g in ipairs(p.groups) do for _, b in ipairs(g.bands) do bands[#bands + 1] = b end end
    local function sum(of)
        local t = { n = 0, paid = 0, value = 0, sold = 0, salvager = 0 }
        for _, b in ipairs(of) do for k in pairs(t) do t[k] = t[k] + b[k] end end
        return t
    end
    for _, r in ipairs(ns.GroupedRows(bands, function(b) return { cells = profitCells(b, "") } end,
        function(of, label) return { group = true, cells = profitCells(sum(of), label) } end, INDENT)) do
        rows[#rows + 1] = r
    end
    return rows
end

--- Each material: what it gave in this time, and what is left now.
--- Units of a material in the bags and the bank, and on the auction house (not sold yet).
local function heldAndListed(id)
    local ok, n = pcall(ns.GetItemCount, id, true)
    local listed = 0
    for _, r in ipairs(ns.db.listings and ns.db.listings.rows or {}) do
        if r.itemID == id and not r.sold then listed = listed + (r.qty or 0) end
    end
    return ok and tonumber(n) or 0, listed
end
Reports.HeldAndListed = heldAndListed

function Reports.MaterialRows()
    local p = Ledger.Profits(ns.db.ledger, (Reports.From()))
    local keep = 1 - ns.Cut()
    local seen, list = {}, {}
    for _, m in ipairs(p.mats) do seen[m.id] = true list[#list + 1] = m end
    for _, mat in ipairs(ns.Data.MATERIALS) do
        local held, listed = heldAndListed(mat.id)
        if not seen[mat.id] and held + listed > 0 then
            list[#list + 1] = { id = mat.id, got = 0, sold = 0, net = 0, cost = 0, profit = 0, untracked = 0,
                depositsLost = 0 }
        end
    end
    if #list == 0 then return { note("No material got, sold, held or listed in this time.") } end
    local rows = {}
    local total = { got = 0, sold = 0, net = 0, cost = 0, profit = 0, depositsLost = 0, held = 0, listed = 0, value = 0 }
    for _, m in ipairs(list) do
        local held, listed = heldAndListed(m.id)
        local value = math.floor((ns.PriceOf(m.id) or 0) * (held + listed) * keep)
        for k, v in pairs({ got = m.got, sold = m.sold, net = m.net, cost = m.cost, profit = m.profit,
            depositsLost = m.depositsLost, held = held, listed = listed, value = value }) do total[k] = total[k] + v end
        rows[#rows + 1] = { itemID = m.id, cells = { ns.MaterialName(m.id) or tostring(m.id), tostring(m.got),
            tostring(m.sold), money(m.net), money(m.cost), m.depositsLost > 0 and signed(-m.depositsLost) or "-",
            signed(m.profit), tostring(held), tostring(listed), money(value) } }
    end
    table.insert(rows, 1, { group = true, cells = { GOLD .. "All|r", tostring(total.got), tostring(total.sold),
        money(total.net), money(total.cost), total.depositsLost > 0 and signed(-total.depositsLost) or "-",
        signed(total.profit), tostring(total.held), tostring(total.listed), money(total.value) } })
    return rows
end

--- Each item, the best first.
function Reports.ItemRows()
    local p = Ledger.Profits(ns.db.ledger, (Reports.From()), Reports.Keep)
    if #p.items == 0 then return { note("No disenchant of an item with a known price in this time and these filters.") } end
    local rows = {}
    for _, it in ipairs(p.items) do
        local profit = math.floor(it.sold + 0.5) - it.paid
        rows[#rows + 1] = { itemID = it.itemID, link = it.link, cells = { it.link or tostring(it.itemID), count(it.n),
            money(it.paid / it.n), money(it.sold / it.n), signed(profit), pct(profit, it.paid) } }
    end
    return rows
end

------------------------------------------------------------------ window

local f, list, sumList, logList, sumTitle, logTitle, summary, rangeDrop
local tabs, filters = {}, {}
local FILTERED = { profit = true, items = true }   -- the views the filters apply to

local function show(l, cols, rows)
    l:SetColumns(cols)
    l:SetSource(#rows, function(i) return rows[i] end)
    l:Refresh()
end

function Reports.Refresh()
    if not f or not f:IsShown() then return end
    local gold = Reports.view == "gold"
    list:SetShown(not gold)
    for _, x in ipairs({ sumList, logList, sumTitle, logTitle }) do x:SetShown(gold) end
    local _, name = Reports.From()
    summary:SetText(GOLD .. name .. "|r" .. GREY .. "  " .. HELP[Reports.view] .. "|r")
    -- The Profit and Items views have their filters on that row instead.
    local filtered = FILTERED[Reports.view] or false
    summary:SetShown(not filtered)
    for _, x in ipairs(filters) do
        x:SetShown(filtered)
        if x.Update then x:Update() end
    end
    if gold then
        local sums, log = Reports.GoldRows()
        sumTitle:SetText(GOLD .. "Sums|r" .. GREY .. "  " .. tostring(ns.Gold.Char()) .. "|r")
        logTitle:SetText(GOLD .. "Changes|r" .. GREY .. "  newest first|r")
        -- The sums take what they need (at most half the room), the changes the rest.
        local room = (f:GetHeight() or 400) - 84 - 14 - 24
        sumList:SetHeight(math.max(80, math.min(room / 2, (#sums + 1) * 20 + 6)))
        show(sumList, COLUMNS.goldSum, sums)
        show(logList, COLUMNS.goldLog, log)
    elseif Reports.view == "profit" then
        show(list, COLUMNS.profit, Reports.ProfitRows())
    elseif Reports.view == "materials" then
        show(list, COLUMNS.materials, Reports.MaterialRows())
    else
        show(list, COLUMNS.items, Reports.ItemRows())
    end
    for key, b in pairs(tabs) do
        if key == Reports.view then b:LockHighlight() else b:UnlockHighlight() end
    end
    rangeDrop:Update()
end

local function build()
    f = W.Window("SalvagerReportsFrame", "Salvager reports", "reports", 860, 480, 760, 300)
    if TITLES[f.saved.view] then Reports.view = f.saved.view end
    for _, r in ipairs(RANGES) do if r[1] == f.saved.range then Reports.range = r[1] end end
    local x = 12
    for _, key in ipairs(ORDER) do
        local b = W.Button(f, TITLES[key], 90, function()
            Reports.view = key
            f.saved.view = key
            list.offset = 0
            Reports.Refresh()
        end, HELP[key])
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -30)
        tabs[key] = b
        x = x + 94
    end
    local options = {}
    for _, r in ipairs(RANGES) do options[#options + 1] = { r[1], r[2] } end
    rangeDrop = W.CheckDropdown(f, 130, options, function(key) return key == Reports.range end, function(key)
        Reports.range = key
        f.saved.range = key
        rangeDrop:Close()
        Reports.Refresh()
    end, "The time the reports cover.", "Time")
    rangeDrop:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -30)
    local timeLabel = W.Label(f, "Time", "GameFontHighlightSmall")
    timeLabel:SetPoint("RIGHT", rangeDrop, "LEFT", -6, 0)
    -- The filters of the Profit and Items views, on the row under the tabs.
    local x0 = f.saved.filter
    if type(x0) == "table" then
        for _, k in ipairs({ "classes", "qualities", "bandsOff" }) do
            if type(x0[k]) == "table" then Reports.filter[k] = x0[k] end
        end
        if x0.salvager then Reports.filter.salvager = x0.salvager end
    end
    f.saved.filter = Reports.filter
    local flt = Reports.filter
    local function changed()
        list.offset = 0
        Reports.Refresh()
    end
    -- A set where at least one stays ticked.
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
    local prev
    local function add(label, drop, help)
        local l = W.Label(f, label, "GameFontHighlightSmall")
        if prev then l:SetPoint("LEFT", prev, "RIGHT", 14, 0) else l:SetPoint("LEFT", f, "TOPLEFT", 14, -69) end
        drop:SetPoint("LEFT", l, "RIGHT", 6, 0)
        W.HelpArea(f, l, label, help)
        filters[#filters + 1] = l
        filters[#filters + 1] = drop
        prev = drop.Right and drop:Right() or drop
    end
    local gearGet, gearSet = setOf(flt.classes, false, { 4, 2 })
    add("Gear", W.CheckDropdown(f, 100, { { 4, "Armor" }, { 2, "Weapons" } }, gearGet, gearSet,
        "Which gear types count.", "Gear", allOr), "Armor, weapons, or both.")
    local qGet, qSet = setOf(flt.qualities, false, { 2, 3, 4 })
    add("Quality", W.CheckDropdown(f, 130, { { 2, "|cff1eff00Uncommon|r" }, { 3, "|cff0070ddRare|r" },
        { 4, "|cffa335eeEpic|r" } }, qGet, qSet, "Which qualities count.", "Quality", allOr), "Uncommon, Rare, Epic.")
    local bandOptions, bandKeys = {}, {}
    for _, b in ipairs(ns.LevelBands()) do
        bandOptions[#bandOptions + 1] = { b.up, b.label }
        bandKeys[#bandKeys + 1] = b.up
    end
    local bGet, bSet = setOf(flt.bandsOff, true, bandKeys)
    add("Bands", W.CheckDropdown(f, 130, bandOptions, bGet, bSet, "Which item level bands count.", "Bands",
        function(names, total)
            if #names == total then return "All" end
            if #names > 3 then return #names .. " bands" end
            return table.concat(names, ", ")
        end), "Item level bands: a band is a range of item levels that disenchants into the same materials.")
    local salvDrop
    salvDrop = W.CheckDropdown(f, 110, { { "all", "All" }, { "with", "With it" }, { "without", "Without it" } },
        function(key) return flt.salvager == key end,
        function(key)
            flt.salvager = key
            salvDrop:Close()
            changed()
        end, "Disenchants with the Arcane Salvager's bonus, without it, or all.", "Salvager")
    add("Salvager", salvDrop, "Disenchants with the Arcane Salvager's bonus, without it, or all.")
    summary = W.Label(f, "", "GameFontHighlightSmall")
    summary:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -62)
    summary:SetPoint("RIGHT", f, "RIGHT", -14, 0)
    summary:SetJustifyH("LEFT")
    summary:SetWordWrap(false)
    list = W.List(f, { rowHeight = 20 })
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -84)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    sumTitle = W.Label(f, "", "GameFontHighlightSmall")
    sumTitle:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -84)
    sumList = W.List(f, { rowHeight = 20 })
    sumList:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -100)
    sumList:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -100)
    logTitle = W.Label(f, "", "GameFontHighlightSmall")
    logTitle:SetPoint("TOPLEFT", sumList, "BOTTOMLEFT", 2, -6)
    logList = W.List(f, { rowHeight = 20 })
    logList:SetPoint("TOPLEFT", sumList, "BOTTOMLEFT", 0, -24)
    logList:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    f.onResize = Reports.Refresh
    f:SetScript("OnShow", Reports.Refresh)
end

function Reports.Toggle()
    if not f then build() end
    f.UserToggle()
end

function Reports.Show()
    if not f then build() end
    f.UserShow()
end

--- Opens the window again if it was open the last time.
function Reports.Restore()
    local saved = ns.db.windows.reports
    if not (saved and saved.open) then return end
    if not f then build() end
    f:Show()
end

for _, e in ipairs({ "SALVAGER_LEDGER", "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS", "SALVAGER_GOLD" }) do
    ns.On(e, function() Reports.Refresh() end)
end

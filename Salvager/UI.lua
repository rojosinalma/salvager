-- Salvager: the main window: the Gear and Materials tabs, the scan settings, and the footer with the other windows.
local _, ns = ...

local W = ns.Widgets

local UI = { view = "deals", offset = 0 }   -- (view "deals": the Gear tab)
ns.UI = UI

local MAX_ROWS, ROW_H = 40, 24
local MAX_COLS = 11
-- (940: the footer's row holds the window buttons, the gold, the bag space, Play, Stop and Buy Top, SDD 101a.)
local WIDTH, HEIGHT = 940, 560
local MIN_W, MIN_H = 940, 470
local LIST_MARGIN = 10 + 2 + 20 + 10   -- the window's width less the list's (inset and list anchors, below)
-- Under the title bar: the tabs (24 to 54 px), then the view: the Gear view's settings block, or the Materials
-- view's filter row; the list under it. The footer: two lines of text and the row of buttons (UI.md Controls 1).
local TABS_TOP, SETTINGS_TOP, SETTINGS_H, FILTERS_TOP, LIST_BOTTOM = 24, 58, 108, 58, 68
local ROWS = 15          -- rows that fit now (set from the list height)
local CLASS_NAME = { [2] = "Weapon", [4] = "Armor" }

local VIEWS = {
    deals = {
        id = "deals",   -- the column set: the columns hidden with the chooser are saved under it
        icon = true,
        indent = 46,
        actionTitle = "Buy",
        -- (Loss chance before Avg return: the risk next to the profit range, the user, 2026-11-28.)
        header = { "Gear", "Type", "Item level", "Buyout", "Profit: low - avg - high", "Loss chance", "Avg return" },
        sortable = { [5] = "profit", [7] = "return" },
        -- Shown when the mouse is over a column's title.
        help = {
            [4] = { "Buyout", "What this auction costs. \"!\" after it, on an orange row: an unusually high average "
                .. "return (from the percent set in the options): check the gear before you buy." },
            [5] = { "Profit: pessimistic - average - optimistic", "What one disenchant of this gear makes against its "
                .. "buyout. One disenchant gives whole units of one material, so there are three numbers: pessimistic "
                .. "(9 in 10 disenchants give this or more), the average over many pieces, and optimistic (1 in 10 "
                .. "gives this or more). Each is a material's value at the scanned price times its sell price ratio, "
                .. "after the 5% auction house cut, less the deposits you lose per unit sold. Green: a gain, red: a "
                .. "loss. A grey \"?\" after the optimistic one: not proven on Forever.\n\n"
                .. "Hover a value for every outcome of one disenchant. The average is over many pieces; one disenchant "
                .. "gives one of the outcomes.\n\nClick to list the deals by the average profit." },
            [6] = { "Loss chance", "The chance that ONE disenchant of this gear is worth less than its buyout, after the cut.\n\n"
                .. "Example: you pay 10s for a piece of gear. 3 times out of 4 it gives dust worth 5s: you lose 5s. 1 time "
                .. "out of 4 it gives an essence worth 30s: you gain 20s. Loss chance is 75%. Over many pieces you still "
                .. "gain: the average is 11s 25c per piece, so 1s 25c of profit each.\n\n"
                .. "Green: under 30%. Yellow: 30% or more. Red: 60% or more.\n\n"
                .. "A high Loss chance with a good average profit needs many pieces before the average shows. A low "
                .. "Loss chance is safe even for a few pieces." },
            [7] = { "Avg return", "The average profit as a share of the buyout: what each gold you pay brings back on top, "
                .. "on average over many pieces. When your gold is what limits you, buy the highest first.\n\n"
                .. "Click to list the deals by the average return." },
        },
        cols = { { 205, "LEFT" }, { 46, "CENTER" }, { 34, "CENTER" }, { 80, "RIGHT" }, { 240, "RIGHT" },
            { 54, "CENTER" }, { 44, "RIGHT" } },
    },
    materials = {
        id = "materials",   -- (the same set as the Materials window's list: one choice for both)
        icon = true,
        actionTitle = "Post",
        header = { "Material", "Price", "Age", "Bags", "Listed", "Sold", "Avg cost", "Break-even", "Profit",
            "Sell price ratio", "Time to sell" },
        cols = { { 160, "LEFT" }, { 80, "RIGHT" }, { 36, "CENTER" }, { 40, "CENTER" }, { 46, "CENTER" }, { 46, "CENTER" },
            { 85, "RIGHT" }, { 85, "RIGHT" }, { 85, "RIGHT" }, { 90, "RIGHT" }, { 80, "RIGHT" } },   -- (as Materials.COLUMNS)
        help = "materials",                        -- (the titles' help is Materials.HELP)
    },
}

local f, rows, headers, status, footer, minProfit, playButton, gearChoice, tabs =
    nil, {}, {}, nil, nil, nil, nil, nil, {}
local maxPrice, cautious, bandDrop, ilvlMin, ilvlMax, levelHint, materialsOnly, scanOwned, gold, maxChecks
local qualityDrop, popOut, minReturn, helpButton
local headerHelp = {}
local columnsButton, columnsView   -- the column chooser, and the view its menu was filled for
local actionHeader
local REFRESH_GAP, lastRefresh, refreshQueued = 0.25, 0, false
local spinner, bigSpinner, bigSpinnerText
local buyTop, topItem, footer2, bags
local P = {}   -- the window's rows and panels: footerBar, tabBar, settingsBox, materialsBar, inset

------------------------------------------------------------------ rows per view

local function dealName(d)
    return (d.link and d.link:match("%[(.-)%]")) or (ns.GetItemInfo(d.itemID)) or ("gear " .. d.itemID)
end

-- The average profit and return, with their sign: green when they gain, red when they lose (UI.md Tables 7).
local GREY, GREEN, RED, ORANGE = "|cff808080", "|cff40ff40", "|cffff4040", "|cffff8040"
local function driverColor(_, gain) return gain and GREEN or RED end
local function byReturn() return ns.db.settings.dealSort == "return" end
local function profitText(d)
    return driverColor(not byReturn(), d.profit >= 0) .. (d.profit >= 0 and "+" or "-") .. ns.Money(math.abs(d.profit))
        .. "|r"
end
local function returnText(d)
    local r = ns.Scanner.Return(d)
    return string.format("%s%+d%%|r", driverColor(byReturn(), r >= 0), math.floor(r * 100 + 0.5))
end
UI.ProfitText, UI.ReturnText = profitText, returnText

--- The deal's profit range: pessimistic - average - optimistic (SDD 116).
local function rangeText(d)
    local sp = d.spread
    return ns.RangeText(d.low and d.low - d.buyout, d.profit, d.high and d.high - d.buyout, sp and sp.unproven)
end
UI.RangeText = rangeText

--- Is the deal's average return unusually high (Options, "Highlight returns from (%)"; 0 = off)? SDD 116.
function UI.HighReturn(d)
    local from = tonumber(ns.db.settings.highlightReturn) or 0
    return from > 0 and d ~= nil and ns.Scanner.Return(d) >= from / 100
end
UI.HIGH_HELP = "Unusually high return (%d%% or more): check the gear, its item level and the rule behind its value "
    .. "before you buy (see the outcomes)."
local function highHelp() return string.format(UI.HIGH_HELP, tonumber(ns.db.settings.highlightReturn) or 0) end

--- The values a Gear row sorts by: the name's text, then numbers (the range by its average, UI.md Tables 1). A group
--- of auctions sorts by its best one (as the scan's order does).
local function dealSort(d)
    return { nil, nil, d.ilvl, d.buyout, d.profit, d.lose, ns.Scanner.Return(d) }
end
local function dealCells(d, label)
    return { label, CLASS_NAME[d.classID or ns.ClassOf(d.itemID)] or "", tostring(d.ilvl or ""),
        ns.Money(d.buyout) .. (UI.HighReturn(d) and (" " .. ORANGE .. "!|r") or ""), rangeText(d), ns.LoseText(d.lose),
        returnText(d) }
end

--- The Gear tab's rows: auctions grouped by the gear's name, best profit first. A group with more than one auction
--- is a heading row (its numbers: the cheapest one) that opens and closes (ns.HeadingToggle, remembered; it starts
--- closed) to show each auction.
local function dealRows()
    local groups, order = {}, {}
    for _, d in ipairs(ns.Scanner.deals) do
        local name = dealName(d)
        local g = groups[name]
        if not g then
            g = { name = name, deals = {} }
            groups[name] = g
            order[#order + 1] = g
        end
        g.deals[#g.deals + 1] = d
    end
    for _, g in ipairs(order) do
        table.sort(g.deals, function(a, b) return a.buyout < b.buyout end)
        for _, d in ipairs(g.deals) do if not g.best or ns.Scanner.Better(d, g.best) then g.best = d end end
    end
    table.sort(order, function(a, b) return ns.Scanner.Better(a.best, b.best) end)
    local out = {}
    for _, g in ipairs(order) do
        -- The row's numbers are those of the auction its Buy button buys: the cheapest not being bought.
        local first = ns.Scanner.Cheapest(g.deals) or g.deals[1]
        if #g.deals == 1 then
            out[#out + 1] = { cells = dealCells(first, first.link or g.name), link = first.link, itemID = first.itemID,
                deal = first, high = UI.HighReturn(first), sort = dealSort(first) }
        else
            -- (A heading takes the highlight when any auction under it has it.)
            local high = false
            for _, d in ipairs(g.deals) do high = high or UI.HighReturn(d) end
            local head = { cells = dealCells(first, (first.link or g.name) .. " |cffffd100x" .. #g.deals .. "|r"),
                link = first.link, itemID = first.itemID, group = g, high = high, sort = dealSort(g.best) }
            out[#out + 1] = head
            if ns.HeadingToggle(head, ns.GroupState("main.gear"), g.name, function() UI.Refresh() end, true) then
                for _, d in ipairs(g.deals) do
                    out[#out + 1] = { cells = dealCells(d, "   " .. (d.link or g.name)), link = d.link, itemID = d.itemID,
                        deal = d, child = true, high = UI.HighReturn(d), sort = dealSort(d) }
                end
            end
        end
    end
    return out
end

local SOURCES = { deals = dealRows, materials = function() return ns.Materials.Rows() end,
    limits = function() return ns.LimitsWindow.Rows() end }   -- (Limits: its own window, LimitsWindow.lua)

local sortOf   -- (below: the column a view is sorted by)

--- The rows sorted by the column picked (Widgets.SortRows): the Gear tab's groups each with their auctions under
--- them (the group by its own numbers, the auctions inside it sorted too).
local function sorted(name, data)
    if not VIEWS[name] then return data end
    local i, desc = sortOf(VIEWS[name])
    if not i or #data < 2 then return data end
    if name ~= "deals" then return W.SortRows(data, i, desc) end
    local units = {}
    for _, r in ipairs(data) do
        if r.child and #units > 0 then table.insert(units[#units].kids, r)
        else units[#units + 1] = { cells = r.cells, sort = r.sort, row = r, kids = {} } end
    end
    local out = {}
    for _, u in ipairs(W.SortRows(units, i, desc)) do
        out[#out + 1] = u.row
        for _, k in ipairs(W.SortRows(u.kids, i, desc)) do out[#out + 1] = k end
    end
    return out
end
local unsorted = SOURCES
SOURCES = {}
for name, fn in pairs(unsorted) do SOURCES[name] = function() return sorted(name, fn()) end end
UI.Unsorted = function(name) return unsorted[name]() end

--- The rows of a tab of the main window, or of the Limits window (for the tests).
function UI.Rows(view) return SOURCES[view]() end

------------------------------------------------------------------ drawing

local statusText

--- Shows the status text. `changed` = only when the text changed (each tick while Play runs: the Live countdown).
function UI.SetStatus(changed)
    if not status then return end
    local text = statusText()
    if changed and text == status:GetText() then return end
    status:SetText(text)
    -- As wide as its text (never cut): the footer's texts wrap in what it leaves (UI.layoutFooter).
    local before = tonumber((status:GetWidth())) or 0
    local sw = tonumber((status:GetStringWidth())) or 0
    status:SetWidth(math.max(1, sw + 2))
    -- (A tick's new width: the footer's texts wrap again; the list is drawn again only when its bottom moves.)
    if changed and math.abs(before - (sw + 2)) >= 1 and UI.reflowFooter then UI.reflowFooter() end
end

function statusText()
    local parts = {}
    if ns.Prices.scanning then parts[#parts + 1] = string.format("Materials %d/%d", ns.Prices.done, ns.Prices.total) end
    local s = ns.Scanner
    if s.state == "browsing" then
        parts[#parts + 1] = string.format("Browsing %s (%d gear listings)", s.passName or "", s.browsed)
    elseif s.state == "checking" then parts[#parts + 1] = string.format("Checking %d/%d", s.checked, s.toCheck)
    elseif s.state == "looking" or s.state == "searching" then parts[#parts + 1] = ns.Live.Status()
    elseif ns.scanBothPending and not ns.Prices.scanning then parts[#parts + 1] = "Starting gear scan"
    elseif s.state == "idle" and not ns.Prices.scanning and ns.Live.Status() then parts[#parts + 1] = ns.Live.Status()
    end
    if s.paused then table.insert(parts, 1, "|cffffd100Paused|r") end
    if #parts == 0 then parts[1] = ns.Queue.open and (s.auto and "Waiting for the next scan" or "Ready")
        or "Auction house closed" end
    return table.concat(parts, "  ·  ")
end

--- The two lines under the list: what the last scan found, then the gear closest to its limit.
--- (What the columns mean is behind the "?" button.)
local function footerText()
    if UI.view == "deals" then
        local sum = ns.Scanner.summary
        local text, closest = string.format("%d deals.", #ns.Scanner.deals), ""
        if sum then
            text = text .. string.format(" Last scan: %d gear listings in %.0fs, %d under their limit.", sum.browsed,
                sum.seconds or 0, sum.candidates)
            if (sum.levelOut or 0) > 0 then
                text = text .. string.format(" %d outside your level filter.", sum.levelOut)
            end
            if (sum.learning or 0) > 0 then
                text = text .. string.format(" %d skipped while their item level loads (next scan has them).", sum.learning)
            end
            if sum.best then
                local b = sum.best
                local room = b.room or (b.margin or 0)
                closest = string.format("Closest: %s at %s, buy limit %s (%s).",
                    (ns.GetItemInfo(b.itemID)) or ("gear " .. b.itemID), ns.Money(b.price),
                    ns.Money(b.limit or b.value), room >= 0 and (ns.Money(room) .. " under it")
                        or (ns.Money(-room) .. " over it"))
            end
        else
            text = text .. " No gear scan yet: click Play, or Scan once: Both."
        end
        -- A limit that hides gear says so, most of all when the list is empty.
        local cap = ns.db.settings.maxPrice
        if cap > 0 then
            text = text .. string.format(" |cffff8040Max price %s is on: dearer gear is never listed.|r", ns.Money(cap))
        end
        return text, closest
    end
    return "", ""
end

--- Which of two auctions "Buy Top" buys first: the active sort's number (Expected profit or Return), then the
--- other one, then the lower buyout, then the auction ID (so the pick is stable).
local function topBetter(a, b)
    local pa, pb, ra, rb = a.profit, b.profit, ns.Scanner.Return(a), ns.Scanner.Return(b)
    if ns.db.settings.dealSort == "return" then pa, pb, ra, rb = ra, rb, pa, pb end
    if pa ~= pb then return pa > pb end
    if ra ~= rb then return ra > rb end
    if a.buyout ~= b.buyout then return a.buyout < b.buyout end
    return (a.auctionID or 0) < (b.auctionID or 0)
end

--- The auction the "Buy Top" button buys: of every auction in the Gear tab not being bought already, the
--- one with the best number of the active sort (`topBetter`), whatever its row. When the gold is short for that
--- one, the best one the gold covers.
--- @return table|nil deal, string|nil why, table|nil skipped  (why: the reason there is none, for the button's
--- tooltip; skipped: the best auction, left out for the gold)
local function topDeal()
    if not ns.Queue.open then return nil, "Open the auction house first." end
    if #ns.Scanner.deals == 0 then
        if not ns.Scanner.summary then return nil, "No gear scan yet: click Play, or Scan once: Gear." end
        return nil, "The Gear list is empty: the next scan fills it."
    end
    local money = GetMoney() or 0
    local best, affordable
    for _, d in ipairs(ns.Scanner.deals) do
        -- A click that waits for the auction house, or its "Buy now", comes first: the next click is for it.
        if (d.wait or d.buyNow) and not d.pending then return d end
    end
    for _, d in ipairs(ns.Scanner.deals) do
        if not d.pending then
            if not best or topBetter(d, best) then best = d end
            if d.buyout <= money and (not affordable or topBetter(d, affordable)) then affordable = d end
        end
    end
    if not best then return nil, "Every auction in the list is being bought already." end
    if not affordable then
        return nil, string.format("Not enough gold for %s (%s).", dealName(best), ns.Money(best.buyout))
    end
    return affordable, nil, affordable ~= best and best or nil
end
UI.TopDeal = topDeal

--- What the list's columns and marks mean, one line each (for the "?" button).
local function helpLines()
    if UI.view == "materials" then return ns.Materials.HelpLines() end
    local cut = math.floor(ns.Cut() * 100 + 0.5) .. "%"
    local by = ns.db.settings.dealSort == "return" and "the average return" or "the average profit"
    return {
                "A click on a title sorts the list by it (the arrow), again the other way round. Each scan checks the gear by "
            .. by .. " (a click on Profit or Avg return picks it), and Buy Top buys in that order.",
        "Arcane Salvager (Scan settings): ticked, the gear is valued with the Salvager's bonus.",
        "The other windows open from the mini panel (Shift + click the minimap button shows or hides it); the gear "
            .. "icon in the title bar opens the options.",
        "One disenchant gives whole units of one material: hover the profit for every outcome and its chance.",
        "Profit: pessimistic (9 in 10 give this or more) - average (over many pieces) - optimistic (1 in 10), "
            .. "after the " .. cut .. " cut.",
        "A grey ? after the optimistic profit: that outcome rests on a rule not measured on Forever.",
        "Avg return: the average profit as a share of the buyout.",
        "Loss chance: the chance that one disenchant is worth less than its buyout.",
        "An orange row with ! after its buyout: an unusually high average return. Check it before you buy.",
        "A name with x3 stands for three auctions of the same gear. Its numbers and its Buy are for the cheapest one.",
        "Click such a row to open or close it (the arrow shows which); it stays as you left it.",
        "Click an auction's row to see its Gear details: every outcome of one disenchant, your history with it.",
        "Buy needs one click per auction. After a purchase that gear is searched again.",
        "A Buy that is on buys with one click. It is off for the moment the auction house answers a request (your last "
            .. "purchase or the scan) and comes back by itself.",
        "For a second after each Buy click the scan sends nothing, so a quick next click finds the auction house free.",
        string.format("Each scan searches and shows the top %d gear candidates, the best by the sort first (Show top, in the "
            .. "Scan settings).",
            ns.db.settings.maxChecks),
        "Hover a column title for more about that column.",
    }
end

--- Column widths: the first column takes the room the window has over its default width.
--- Every column is as wide as its widest text (title or cell), and no wider. The columns with input
--- boxes keep the width of their boxes. Where the client cannot measure text, the widths given are used
--- and the first column takes the room the window has over its default width.
--- A title as it shows: the one the list is ordered by has the arrow (so the column is measured with it).
-- (Every column sorts by a click, Widgets.SortRows, the order saved per view: "main.deals", and the Materials list's
-- "materials" shared with the Materials window. With none saved, the Gear tab is in the order of the scan's sort,
-- dealSort: the average profit or the average return, highest first.)
function sortOf(view)
    local st = W.SortState(view.id == "deals" and "main.deals" or view.id)
    local cols = {}
    for i, t in ipairs(view.header) do cols[i] = { t } end
    local i = st and W.SortColumn(cols, st)
    if i then return i, st.desc and true or false end
    if view.sortable then
        for c, key in pairs(view.sortable) do if key == ns.db.settings.dealSort then return c, true end end
    end
    return nil
end
UI.SortOf = function(name) return sortOf(VIEWS[name]) end
UI.SortOfView = sortOf
local function shownTitle(view, i, title)
    local by, desc = sortOf(view)
    return W.SortTitle(title, i, by, desc)
end

--- Does column i of a view show? The first always does; the others unless hidden with the chooser.
local function colShown(view, i)
    return i == 1 or not view.id or W.ColumnShown(view.id, view.header[i])
end

-- The space after column i of a view: the next shown column's text NORMAL_GAP from its own (Widgets.ColumnGap);
-- 0 after the last one.
local function gapAfter(view, i)
    for n = i + 1, #view.cols do
        if colShown(view, n) then return W.ColumnGap(view.cols[i][2], view.cols[n][2]) end
    end
    return 0
end

local function widths(view, data)
    local titles = {}
    for i, title in ipairs(view.measure or view.header) do titles[i] = shownTitle(view, i, title) end
    -- (A column of live values is as wide as its widest possible value: the Materials tab's Age.)
    local samples = view.samples
    if view.help == "materials" then
        samples = {}
        for i, col in ipairs(ns.Materials.COLUMNS) do samples[i] = col.sample end
    end
    local need, text
    if data then need, text = W.FitColumns(titles, #data, function(r) return data[r].cells end, nil, samples) end
    UI.textNeed = text   -- (the widest text of each column in the data: the self-check places it in the box)
    local w = {}
    if need then
        for i = 1, #view.cols do w[i] = need[i] end
        -- The width authority (SDD 120): every column its text's width, COL_GAP apart; the first column takes only
        -- what the window has over that (a window its controls make wider), so the buttons' column ends at the
        -- list's right edge (UI.md Tables 2).
        local used = view.indent or (view.icon and 30 or 4)
        for i = 1, #view.cols do if colShown(view, i) then used = used + w[i] + gapAfter(view, i) end end
        if view.actionTitle then used = used + 22 + 64 end   -- (the warning sign and the button, as `layout` puts them)
        local room = tonumber((UI.list and UI.list:GetWidth())) or 0
        UI.tableNeed = used   -- (the list's width that shows every column in full: the window widens to it)
        if room > used + 4 then
            w[1] = w[1] + math.floor(room - used - 4)
        elseif room > 0 and used + 4 > room then
            -- Narrower than its columns (the screen is too small): the first column gives way, down to 90 px, and its
            -- text ends with "..." (the full name on hover).
            w[1] = math.max(90, w[1] - math.ceil(used + 4 - room))
        end
        return w
    end
    local extra = math.max(0, math.floor((f:GetWidth() or WIDTH) - WIDTH))
    for i, col in ipairs(view.cols) do w[i] = col[1] + (i == 1 and extra or 0) end
    return w
end

local groupTitles, dividers, titleBand = {}, {}, nil

--- The room a view takes over its column titles: one more row for titles over groups of columns.
local function topOf(view) return view.groupHeader and ROW_H or 0 end


local function layout(view, data)
    local x = view.indent or (view.icon and 30 or 4)
    local w = widths(view, data)
    local top = topOf(view)
    local xs = {}
    if titleBand then titleBand:SetHeight(ROW_H + top) end
    for r, row in ipairs(rows) do
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", UI.list, "TOPLEFT", 0, -r * ROW_H - top)
        row:SetPoint("RIGHT", UI.list, "RIGHT", 0, 0)
    end
    for i = 1, MAX_COLS do
        local col = view.cols[i]
        xs[i] = x
        headers[i]:ClearAllPoints()
        headers[i]:SetPoint("TOPLEFT", headers[i]:GetParent(), "TOPLEFT", x, -top)
        for _, row in ipairs(rows) do
            row.cells[i]:ClearAllPoints()
            row.cells[i]:SetPoint("LEFT", row, "LEFT", x, 0)
        end
        if col and colShown(view, i) then x = x + w[i] + gapAfter(view, i) end
    end
    xs[#view.cols + 1] = x
    if helpButton then
        helpButton:ClearAllPoints()
        helpButton:SetPoint("TOPLEFT", UI.list, "TOPLEFT", 3, -top - 2)
    end
    -- Titles over groups of columns (Limits: Armor, Weapons), and vertical lines between groups.
    for i, gh in ipairs(view.groupHeader or {}) do
        local t = groupTitles[i]
        if not t then
            t = UI.list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            t:SetHeight(ROW_H)
            t:SetJustifyH("CENTER")
            groupTitles[i] = t
        end
        t:ClearAllPoints()
        t:SetPoint("TOPLEFT", UI.list, "TOPLEFT", xs[gh[1]], 0)
        t:SetWidth(math.max(10, xs[gh[2] + 1] - xs[gh[1]] - W.COL_GAP))   -- (a group's title: over its columns)
        t:SetText(gh[3])
        t:Show()
    end
    for i = #(view.groupHeader or {}) + 1, #groupTitles do groupTitles[i]:Hide() end
    for i, after in ipairs(view.dividers or {}) do
        local d = dividers[i]
        if not d then
            d = UI.list:CreateTexture(nil, "ARTWORK")
            d:SetColorTexture(1, 1, 1, 0.18)
            d:SetWidth(1)
            dividers[i] = d
        end
        d:ClearAllPoints()
        d:SetPoint("TOPLEFT", UI.list, "TOPLEFT", xs[after + 1] - 4, 0)
        d:SetPoint("BOTTOMLEFT", UI.list, "BOTTOMLEFT", xs[after + 1] - 4, 0)
        d:Show()
    end
    for i = #(view.dividers or {}) + 1, #dividers do dividers[i]:Hide() end
    -- The buttons' column (Buy, Post) is a column like the others: right after the last one, as wide as its
    -- warning sign and its button. (Where text cannot be measured, it stays at the right edge.)
    if view.actionTitle and W.TextWidth("x") then
        actionHeader:ClearAllPoints()
        actionHeader:SetPoint("TOPLEFT", actionHeader:GetParent(), "TOPLEFT", x + 22, 0)
        for _, row in ipairs(rows) do
            row.warn:ClearAllPoints()
            row.warn:SetPoint("LEFT", row, "LEFT", x, 0)
            row.buy:ClearAllPoints()
            row.buy:SetPoint("LEFT", row, "LEFT", x + 22, 0)
        end
    end
    return w
end

--- Rows that fit in the list now.
local function fitRows()
    local h = (UI.list and UI.list:GetHeight() or 0) - topOf(VIEWS[UI.view] or {})
    return math.max(1, math.min(MAX_ROWS, math.floor(h / ROW_H) - 1))
end

function UI.UpdateScrollBar(total)
    if UI.bar then UI.bar:Update(UI.offset, total - ROWS) end
end

--- Does a scan run (Play's auto scan, paused or not, or a scan once)? The toggle then shows Stop.
function UI.Running()
    return (ns.Scanner.auto or ns.Busy()) and true or false
end

--- The run toggle: play arrow while no scan runs, stop square while one does; off with the reason while the auction
--- house is closed. The Scan once buttons are off then too (UI.md Actions 3).
function UI.UpdatePlay()
    if not playButton then return end
    local open = ns.Queue.open
    playButton:SetEnabled(open)
    playButton:SetRunning(open and UI.Running())
    playButton:UpdateGlyph()
    playButton.reason = not open and W.AH_CLOSED or nil
    for _, b in ipairs(UI.scanButtons or {}) do
        b:SetEnabled(open)
        b.reason = not open and W.AH_CLOSED or nil
    end
end

--- What a Buy button (a row's, Buy Top, Gear Details) shows for the auction it buys (SDD 105): "Buy"; "..." and off
--- while the purchase is on its way or waits for the auction house (the reason in `b.reason`); "Buy now", lit, when
--- the auction house is ready for the click a waiting purchase needs.
function UI.BuyLook(b, d, label)
    -- A Buy that is on always buys with one click (0.4.0, the user): it is off for the fraction of a second the
    -- auction house is answering a request (the last purchase or a scan's), and lights again by itself.
    local busy = d and ns.Queue.open and not ns.Scanner.Ready()
    local why = not d and "Every auction of this row is being bought." or d.pending and "This auction is being bought."
        or d.wait == "search" and "Searching this gear again first (a scan browse came after its search): Buy comes "
            .. "back in a moment."
        or busy and "The auction house is answering a request (your last purchase or the scan): Buy comes back in a "
            .. "moment by itself." or nil
    b:SetEnabled(why == nil)
    b.reason = why
    b:SetText((why and not busy) and "..." or label)
    b:UnlockHighlight()
end

--- A deal's numbers in a tooltip: Item level, Buyout (and the high return note), every outcome of one disenchant in
--- whole units with its chance, value and profit against the buyout, lowest first; then the range (pessimistic,
--- optimistic, each a real outcome) and the averages, labelled as averages; Avg return, Loss chance, Time to sell, Avg
--- return per day (SDD 116). One function for a Gear row, its profit cell, the gear above "Buy Top" and the Buy Top
--- button, so they always match.
function UI.AddDealLines(tip, d)
    local function line(label, value) tip:AddDoubleLine(label, value, 1, 0.82, 0, 1, 1, 1) end
    tip:AddLine(" ")
    line("Item level", tostring(d.ilvl or "-"))
    line("Buyout", ns.Money(d.buyout))
    if UI.HighReturn(d) then tip:AddLine(ORANGE .. "! |r" .. highHelp(), 1, 0.5, 0.25, true) end
    local sp = d.spread
    if sp and #sp.list > 0 then
        tip:AddLine(" ")
        tip:AddDoubleLine("Chance   What one disenchant gives", "Value   Profit", 1, 0.82, 0, 1, 0.82, 0)
        for _, x in ipairs(sp.list) do
            tip:AddDoubleLine(string.format("%3d%%   %s", math.floor(x.chance * 100 + 0.5), ns.OutcomeWhat(x)),
                (x.missing and (GREY .. "no price|r") or ns.Money(x.value)) .. "   " .. ns.SignedShort(x.value - d.buyout),
                1, 1, 1, 1, 1, 1)
        end
        tip:AddLine(" ")
        local function outcome(label, x, note)
            if not x then return end
            line(label, ns.OutcomeWhat(x) .. ": " .. ns.Money(x.value) .. ", profit " .. ns.SignedShort(x.value - d.buyout)
                .. (note and (GREY .. " (" .. note .. ")|r") or ""))
        end
        outcome("Pessimistic (9 in 10 get this or more)", sp.low)
        outcome("Optimistic (1 in 10 gets this or more)", sp.high, sp.unproven and ns.NOT_PROVEN or nil)
    end
    line("Average value (over many pieces)", ns.Money(d.value))
    line("Average profit (over many pieces)", profitText(d))
    line("Loss chance", ns.LoseText(d.lose))
    line("Avg return", returnText(d))
    -- Return per day (SDD 100): in the tooltip, not a column, while it equals Return for nearly every deal.
    local perDay = ns.Scanner.ReturnPerDay(d)
    local few = d.daysFew and " (few sales)" or ""
    line("Time to sell (its materials)", d.days and (ns.DurationText(d.sellSeconds)
        .. string.format(", counted as %.1f %s", d.days, d.days == 1 and "day" or "days") .. few) or "not known yet")
    line("Avg return per day", perDay and (string.format("%s%+.1f%%|r", GREY, perDay * 100) .. few) or "not known yet")
    if sp then
        tip:AddLine("Rule: " .. ns.EVIDENCE_TEXT[sp.evidence], 0.5, 0.5, 0.5, true)
        tip:AddLine("Rests on " .. ns.WeightedResultsText(sp.weight, sp.few) .. " of this band (recent ones weigh "
            .. "more)", 0.5, 0.5, 0.5, true)
    end
    tip:AddLine("An average is over many pieces; one disenchant gives one of the outcomes listed.", 0.5, 0.5, 0.5, true)
end

--- The tooltip of a deal's profit cell: the gear, then its deal lines (the outcomes first of all).
function UI.RangeTooltip(owner, d)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(d.link or dealName(d), 1, 1, 1)
    UI.AddDealLines(GameTooltip, d)
    GameTooltip:Show()
end

--- The "Buy Top" button's tooltip: what the click buys now, or why it is off.
local function buyTopTooltip(self)
    local d, why, skipped = topDeal()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Buy Top", 1, 1, 1)
    if d and (d.wait or (not d.pending and ns.Scanner.BuyBusy())) then
        GameTooltip:AddLine(buyTop.reason or "", 1, 0.3, 0.3, true)
        GameTooltip:AddLine(d.link or dealName(d), 1, 1, 1)
    elseif d then
        W.AddHelp(GameTooltip, nil, "Buys the auction with the highest " .. (byReturn() and "average return" or "average profit")
            .. " in the Gear tab (the sort), from any row. Each click buys the next best one.")
        if skipped then
            GameTooltip:AddLine(string.format("The best one, %s (%s), is skipped: not enough gold.", dealName(skipped),
                ns.Money(skipped.buyout)), 1, 0.3, 0.3, true)
        end
        GameTooltip:AddLine(d.link or dealName(d), 1, 1, 1)
        UI.AddDealLines(GameTooltip, d)
    else
        GameTooltip:AddLine(why, 1, 0.3, 0.3, true)
    end
    GameTooltip:Show()
end

--- The "Buy Top" button: on while there is a deal to buy; its tooltip follows the list while it shows.
local function updateBuyTop()
    local d, why = topDeal()
    UI.BuyLook(buyTop, d, "Buy Top")
    if not d then buyTop.reason = why buyTop:SetText("Buy Top") end
    -- The auction house is busy (mostly: still answering the last purchase): a click now would lose the purchase,
    -- so Buy Top is off with the reason until it is ready (its name stays), and a click meanwhile does nothing.
    local busy = d and not d.pending and not d.wait and ns.Scanner.BuyBusy()
    if busy then
        buyTop:SetEnabled(false)
        buyTop.reason = busy
        buyTop:SetText("Buy Top")
        buyTop:UnlockHighlight()
    end
    -- Above the button: the gear the next click buys, as wide as its name. Nothing when the button is off: the
    -- reason is in its tooltip.
    topItem.link = d and (d.link or ("item:" .. d.itemID)) or nil
    topItem.deal = d
    topItem.text:SetText(d and (d.link or dealName(d)) or "")
    local icon = d and W.IconOf(d.itemID)
    if icon then topItem.icon:SetTexture(icon) topItem.icon:Show() else topItem.icon:Hide() end
    local tw = tonumber((topItem.text:GetStringWidth())) or 0
    local w = math.max(1, tw + 2)   -- (as wide as its name, never cut: the footer's texts wrap in what is left)
    topItem.text:SetWidth(w)
    topItem:SetWidth(w + (icon and 17 or 0))   -- the icon (14) and its gap (3)
    topItem:SetShown(d ~= nil)
    if buyTop.hover then buyTopTooltip(buyTop) end
end

--- The footer's two texts wrap in the room left of the status (and its spinner) and the gear Buy Top buys; the list
--- ends above their lines. @return number  the list's bottom (px above the window's bottom)
local function layoutFooter()
    local right = 0
    if (status:GetText() or "") ~= "" then right = (tonumber((status:GetWidth())) or 0) + 24 end
    if topItem:IsShown() then right = math.max(right, tonumber((topItem:GetWidth())) or 0) end
    local w = math.max(120, (tonumber((f:GetWidth())) or 0) - 14 - 24 - 16 - right)
    local h = 0
    for _, fs in ipairs({ footer2, footer }) do
        fs:SetWidth(w)
                -- (As tall as its lines, so the client never cuts it.)
        local fh = (fs:GetText() or "") == "" and 0 or math.ceil(tonumber((fs:GetStringHeight())) or 12) + 1
        fs:SetHeight(math.max(1, fh))
        h = h + fh
    end
    return math.max(LIST_BOTTOM, 36 + h + 4)
end

--- The status's width changed between refreshes (the Live countdown): the footer's texts wrap again.
function UI.reflowFooter()
    if not f or not f:IsShown() or UI.refooting then return end
    if layoutFooter() ~= (UI.listBottom or LIST_BOTTOM) then UI.RequestRefresh() end
end

function UI.Refresh()
    if not f or not f:IsShown() then return end
    -- The materials list is in its own window: this window does not show it too.
    if not VIEWS[UI.view] then UI.view, UI.offset = "deals", 0 end   -- (Limits was a tab before 0.3.128)
    local out = ns.Materials.IsPoppedOut()
    if out and UI.view == "materials" then UI.view, UI.offset = "deals", 0 end
    tabs.materials:SetAlpha(out and 0.5 or 1)
    if out then popOut:LockHighlight() else popOut:UnlockHighlight() end
    gold:SetText(ns.Money(GetMoney() or 0))
    bags:SetText(ns.LedgerWindow.BagText())
    UI.fitReadouts()
    -- The view under the tabs: Gear has the settings block, Materials its filter row; the list starts under it.
    local materials = UI.view == "materials"
    P.settingsBox:SetShown(not materials)
    P.materialsBar:SetShown(materials)
    P.inset:ClearAllPoints()
    P.inset:SetPoint("TOPLEFT", f, "TOPLEFT", 10,
        -(materials and (FILTERS_TOP + W.BAR_H.filters + 4) or (SETTINGS_TOP + SETTINGS_H + 6)))
    P.inset:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, UI.listBottom or LIST_BOTTOM)
    materialsOnly:SetChecked(ns.db.settings.materialsDataOnly)
    local view = VIEWS[UI.view]
    ROWS = fitRows()
    -- (Texts the width is measured from, before the fit.)
    levelHint:SetText((ns.db.settings.ilvlMin > 0 or ns.db.settings.ilvlMax > 0) and "" or "0 = any")
    local data = SOURCES[UI.view]()
    UI.tableNeed = nil
    local w = layout(view, data)
    -- A fixed width (0.3.149, the user): as wide as the view's table needs, never narrower than MIN_W, up to the
    -- screen; only the height can be changed. The width follows the view on show, wider or narrower.
    if not UI.fitting then
        -- (The window's width around the list is fixed: the inset 10 px in from each side, the list 2 px in from its
        -- left and 20 px from its right. Read live, the list's width lags its new anchors for a frame after a tab
        -- change, and the window then took the whole screen: 0.3.143.)
        -- (At least as wide as the footer's buttons and readouts at their widest, 10 + 24 px around them: at 940 the
        -- gold overlapped Log, 0.3.151.)
        -- (The width authority, SDD 120: the rows of controls on show (footer, tabs, the Materials view's filter row)
        -- and the Gear view's settings, measured; or the table's columns; nothing else.)
        local least = W.ControlsWidth(f)
        UI.leastWidth = least
        local want = math.min(math.floor(W.ScreenWidth()),
            math.max(least, UI.tableNeed and math.ceil(UI.tableNeed + 4 + LIST_MARGIN) or least))
        f.contentNeed = want
        if want ~= f.minWidth then
            f.minWidth = want
            if f.SetResizeBounds then f:SetResizeBounds(want, MIN_H, want, UIParent:GetHeight())
            elseif f.SetMinResize then
                f:SetMinResize(want, MIN_H)
                if f.SetMaxResize then f:SetMaxResize(want, UIParent:GetHeight()) end
            end
        end
        if math.abs((tonumber((f:GetWidth())) or 0) - want) >= 1 then
            UI.fitting = true
            f:SetWidth(want)
            UI.fitting = false
            w = layout(view, data)
        end
    end
    UI.offset = math.max(0, math.min(UI.offset, #data - ROWS))
    UI.UpdateScrollBar(#data)
    if columnsView ~= UI.view then columnsButton.Close() columnsView = UI.view end
    columnsButton:SetShown(view.id ~= nil)
    for i, h in ipairs(headers) do
        local col = view.cols[i] and colShown(view, i) and view.cols[i]
        if col then
            local title = shownTitle(view, i, view.header[i] or "")
            h:SetWidth(w[i]) h:SetJustifyH(col[2]) h:SetText(title) h:Show()
        else
            h:Hide()
        end
        local help = view.help == "materials" and ns.Materials.HELP or view.help
        headerHelp[i].help = col and help and help[i] or nil
        headerHelp[i].sortKey = col and view.sortable and view.sortable[i] or nil
        headerHelp[i].sortCol = col and i or nil   -- (every column sorts)
        headerHelp[i].title = view.header[i]
        headerHelp[i]:SetShown(headerHelp[i].help ~= nil or headerHelp[i].sortCol ~= nil)
    end
    actionHeader:SetText(view.actionTitle or "")
    for r = ROWS + 1, MAX_ROWS do rows[r]:Hide() end
    for r = 1, ROWS do
        local row, item = rows[r], data[r + UI.offset]
        row.item = item
        for i, fs in ipairs(row.cells) do
            local col = view.cols[i]
            if col and item and colShown(view, i) then
                fs:SetWidth(w[i]) fs:SetJustifyH(col[2]) fs:SetText(W.CellText(item.cells[i])) fs:Show()
            else
                fs:Hide()
            end
        end
        local deals = UI.view == "deals" and item ~= nil
        row.tint:SetShown(deals and item.high and true or false)
        row.rangeArea:SetShown(deals and colShown(view, 5))
        row.buyoutArea:SetShown(deals and colShown(view, 4))
        local icon = item and view.icon and W.IconOf(item.itemID)
        row.icon:ClearAllPoints()
        row.icon:SetPoint("LEFT", row, "LEFT", (view.indent and 22 or 4) + (item and item.child and 10 or 0), 0)
        if icon then row.icon:SetTexture(icon) row.icon:Show() else row.icon:Hide() end
        if item and item.group then
            W.GroupArrow(row.toggle, item.open)
            row.toggle:Show()
        else
            row.toggle:Hide()
        end
        local s = item and item.suggest
        row.warn:SetShown((item and item.post and s and s.below) and true or false)
        if item and item.post then
            local loading = ns.Post.loading[item.itemID]
            row.buy:Show()
            row.buy:SetEnabled(ns.Queue.open and item.canPost and not loading)
            row.buy:SetText(loading and "..." or "Post")
            row.buy.reason = (not ns.Queue.open and W.AH_CLOSED)
                or (not item.canPost and "None of it in your bags.") or nil
            row.buy:UnlockHighlight()
        elseif item and (item.deal or item.group) then
            local d = item.deal or ns.Scanner.Cheapest(item.group.deals)
            row.buy:Show()
            UI.BuyLook(row.buy, d, "Buy")
        else
            row.buy:Hide()
        end
        row:SetShown(item ~= nil)
    end
    for name, b in pairs(tabs) do
        b:SetSelected(name == UI.view)
    end
    UI.SetStatus(false)
    if ns.Busy() then spinner:Start() else spinner:Stop() end
    local dealsBusy = UI.view == "deals" and (ns.Scanner.state ~= "idle" or ns.scanBothPending)
    if dealsBusy and #data == 0 then
        bigSpinner:Start()
        bigSpinnerText:SetText(statusText():match("^[^·]+") or "Scanning")
        bigSpinnerText:Show()
    else
        bigSpinner:Stop()
        bigSpinnerText:Hide()
    end
    UI.UpdatePlay()
    minProfit:Set(ns.db.settings.minProfit)
    if not minReturn:HasFocus() then minReturn:SetText(tostring(ns.db.settings.minReturn)) end
    maxPrice:Set(ns.db.settings.maxPrice)

    cautious:SetChecked(ns.db.settings.cautious)
    P.salvager:SetChecked(ns.SalvagerForBuy())
    bandDrop:Update()
    local st = ns.db.settings
    if not ilvlMin:HasFocus() then ilvlMin:SetText(tostring(st.ilvlMin)) end
    if not ilvlMax:HasFocus() then ilvlMax:SetText(tostring(st.ilvlMax)) end
    levelHint:SetText((st.ilvlMin > 0 or st.ilvlMax > 0) and "" or "0 = any")
    if not maxChecks:HasFocus() then maxChecks:SetText(tostring(st.maxChecks)) end
    gearChoice:Update()
    qualityDrop:Update()
    local line1, line2 = footerText()
    footer:SetText(line1)
    footer2:SetText(line2)
    updateBuyTop()
    lastRefresh = GetTime()
    -- (Lines that need more room move the list's bottom up: drawn again once with it.)
    local bottom = layoutFooter()
    if bottom ~= (UI.listBottom or LIST_BOTTOM) and not UI.refooting then
        UI.listBottom = bottom
        UI.refooting = true
        UI.Refresh()
        UI.refooting = false
        return
    end
    -- The self-check (SDD 120): no wider than the content, normal gaps.
    if not UI.fitting then W.CheckLayout(f, { UI.mainTable }, UI.view) end
end

--- The main window's own table as the self-check reads it (Widgets.CheckLayout): its columns on screen, its need.
UI.mainTable = {
    IsShown = function() return f ~= nil and f:IsShown() end,
    columnsOf = function()
        local view, cols, need = VIEWS[UI.view], {}, UI.textNeed or {}
        for i, h in ipairs(headers) do
            if h:IsShown() and view.cols[i] then
                local cells = {}
                for _, row in ipairs(rows) do if row:IsShown() then cells[#cells + 1] = row.cells[i] end end
                cols[#cols + 1] = { title = view.header[i], header = h, cells = cells, need = need[i] }
            end
        end
        return cols
    end,
}
setmetatable(UI.mainTable, { __index = function(_, k)
    if k == "neededWidth" then return UI.tableNeed and (UI.tableNeed + 4) end
    if k == "margin" then return LIST_MARGIN end
end })

--- Redraws soon, at most four times a second (for events that come in bursts during a scan).
function UI.RequestRefresh()
    if not f or not f:IsShown() or refreshQueued then return end
    local wait = REFRESH_GAP - (GetTime() - lastRefresh)
    if wait <= 0 then UI.Refresh() return end
    refreshQueued = true
    C_Timer.After(wait, function()
        refreshQueued = false
        UI.Refresh()
    end)
end

------------------------------------------------------------------ building

--- Pins the window by its top left corner where it is now, so resizing
--- from the bottom right corner moves only that corner.
local function anchorTopLeft()
    local left, top = f:GetLeft(), f:GetTop()
    if not (left and top) then return end
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
end

local function savePosition()
    local point, _, rel, x, y = f:GetPoint()
    local win = ns.db.window
    win.point, win.rel, win.x, win.y = point, rel, x, y
end


local function rowTooltip(self)
    local item = self.item
    local link = item and (item.link or (item.itemID and ("item:" .. item.itemID)))
    if not link then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetHyperlink(link)
    local hint = UI.view == "materials" and ns.RowHint(item)
    if hint then GameTooltip:AddLine(hint, 0.5, 0.8, 1) end
    W.AddExactLines(GameTooltip, VIEWS[UI.view] and VIEWS[UI.view].header, item)
    local d = UI.view == "deals" and (item.deal or (item.group and ns.Scanner.Cheapest(item.group.deals)))
    if d then
        UI.AddDealLines(GameTooltip, d)
        GameTooltip:AddLine(item.group and "Click: open or close the group" or "Click: Gear details of this auction",
            0.5, 0.8, 1)
    end
    GameTooltip:Show()
end

local function build()
    f = CreateFrame("Frame", "SalvagerFrame", UIParent, "BasicFrameTemplateWithInset")
    f.minWidth = MIN_W
    f.layoutName = "main"
    -- The Gear view's settings block is content too (Widgets.ControlsWidth): its rows, plus its 10 px insets.
    f.extraNeed = function()
        if not (P.settingsBox and P.settingsBox:IsShown() and P.settingsNeed) then return 0 end
        return P.settingsNeed() + 20
    end
    local saved = ns.db.window
    f:SetSize(WIDTH, math.max(MIN_H, saved.h or HEIGHT))   -- (the width follows the view: Refresh)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    W.ClampToTitle(f)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        anchorTopLeft()
        savePosition()
    end)
    -- The default place: 200 px right of the center, less where the screen is too narrow for the window there.
    local function defaultPlace()
        local room = ((UIParent:GetWidth() or 0) - (f:GetWidth() or WIDTH)) / 2
        f:SetPoint("CENTER", UIParent, "CENTER", math.max(0, math.min(200, math.floor(room))), 0)
    end
    local pos = ns.db.window
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.rel or pos.point, pos.x or 0, pos.y or 0)
    else
        defaultPlace()
    end
    W.windows[#W.windows + 1] = { frame = f, reset = function()
        local win = ns.db.window
        win.point, win.rel, win.x, win.y = nil, nil, nil, nil
        f:ClearAllPoints()
        defaultPlace()
    end }
    local title = f.TitleText
    if type(title) ~= "table" then
        title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", f, "TOP", 0, -5)
    end
    title:SetText("Salvager")
    W.TitleVersion(f, title, MIN_W)
    tinsert(UISpecialFrames, "SalvagerFrame")

    ---------------------------------------------------------------- footer: the other windows; run and buy
    -- (UI.md Controls 1 and 7: nothing but the tabs under the title bar. The buttons that open the other windows are
    -- one group at the left of the footer, away from the tabs; the run buttons and "Buy Top", the main action, at
    -- its right end, left of the resize grip.)
    P.footerBar = W.Bar(f, "footer"):PlaceBottom(6, 10, 24)
    UI.footerBar = P.footerBar
    -- Play and Stop are one toggle (the user, 2026-11-27): the play arrow while no scan runs, the stop square while
    -- one does (Play's auto scan, or a scan once); its tooltip says what the click does.
    playButton = W.PlayToggle(P.footerBar, 24, function()
        if not ns.Queue.open then return end
        if UI.Running() then ns.Scanner.Stop() else ns.Scanner.Play() end
    end)
    playButton:SetMotionScriptsWhileDisabled(true)
    playButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if UI.Running() then
            GameTooltip:SetText("Stop", 1, 1, 1)
            W.AddHelp(GameTooltip, nil, "Ends auto scanning and cancels the scan that is running. The gear found so far stays "
                .. "in the list.")
        else
            GameTooltip:SetText("Play", 1, 1, 1)
            local s = ns.db.settings
            local every = s.priceRescan
            if ns.Live.Usable() then
                W.AddHelp(GameTooltip, nil, "Live scan: each short round looks at the cheapest listings of a few qualities, gear "
                    .. "types and item level bands, searches only the gear that changed, and makes the top deals current "
                    .. "again; then it rests " .. s.liveInterval .. " seconds, so the auction house is free when you click "
                    .. "Buy. Nothing is sent for 3 seconds after a Buy click.")
                W.AddHelp(GameTooltip, nil, "If the auction house does not sort the listings by price, Play scans full rounds "
                    .. "(every page) every " .. s.autoInterval .. " seconds instead, for this session; the status says so.")
            else
                W.AddHelp(GameTooltip, nil, "Full rounds this session (the auction house did not sort the listings by price): "
                    .. "scans every page of the gear now and again every " .. s.autoInterval .. " seconds.")
            end
            W.AddHelp(GameTooltip, nil, (every > 0 and ("Material prices are scanned again when they are older than " .. every
                .. " minutes. ") or "Material prices are not scanned again (see the options). ")
                .. "You still click Buy yourself. Click again to stop.")
        end
        if self.reason then GameTooltip:AddLine(self.reason, 1, 0.3, 0.3, true) end
        GameTooltip:Show()
    end)
    playButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UI.playButton = playButton   -- (the specs click it)
    spinner = W.Spinner(f, 18)   -- (with the status, under the list)

    -- (No window buttons here since 0.4.0, the user: the other windows open from the mini panel, always on, SDD 127.
    -- The footer holds the status, the gold, the bags, Play and Buy Top; Options is a gear icon in the title bar.)
    -- At the bottom right, left of the resize grip: "Buy Top" buys the best auction of the list (the click is the
    -- hardware event the purchase needs). Left of it, what the addon is doing now (scanning, searching), the
    -- spinner before it; the footer takes the room on the left.
    -- (Its global name: the "Salvager Buy" macro clicks it, /click SalvagerBuyTopButton, SDD 127. With the main
    -- window hidden or the button off, a click does nothing.)
    buyTop = W.Button(P.footerBar, "Buy Top", 80, function(self)
        if not (f:IsVisible() and self:IsEnabled()) then return end
        local d = topDeal()
        if d and not d.wait then ns.Scanner.Buy(d, true) end
    end, nil, "SalvagerBuyTopButton")
    P.footerBar:AddRight(buyTop, 80)
    P.footerBar:AddRight(playButton, 24, 12)
    -- Left of Play: the bag space, and your gold right next to it (one group: gold, bags, Play), readouts (not
    -- buttons, UI.md Controls 7 and 11); the bag space as the Ledger's Purchases view shows it. Each box is as wide as
    -- the text it shows (UI.fitReadouts, each refresh), measured by its own font string with its coin icons at their
    -- real size; the footer keeps room for their widest values. (Until 0.3.151 the gold sat in a fixed box sized
    -- from the small font's meter, which the client's coin icons outgrew: the gold was cut, far from the bags.)
    local function measure(label, text)
        local before = label:GetText()
        label:SetWidth(0)
        label:SetText(text)
        local m = label.GetUnboundedStringWidth or label.GetStringWidth
        local w = tonumber((m(label))) or W.TextWidth(text)
        label:SetText(before)
        return w
    end
    bags = W.Label(P.footerBar, "", "GameFontHighlightSmall")
    bags:SetJustifyH("RIGHT")
    bags:SetWordWrap(false)
    bags.uiKind = "readout"
    local bagW = math.ceil(measure(bags, ns.LedgerWindow.BagText()) or 60) + 4
    bags:SetWidth(bagW)
    P.footerBar:AddRight(bags, bagW, 12)
    W.HelpArea(P.footerBar, bags, "Bag space", ns.LedgerWindow.BAG_HELP)
    gold = W.Label(P.footerBar, "", "GameFontHighlightSmall")
    gold:SetJustifyH("RIGHT")
    gold:SetWordWrap(false)
    gold.uiKind = "readout"
    -- (As wide as the gold it shows now, UI.fitReadouts; the footer's need is measured from it, bar:Need.)
    local goldW = math.ceil(measure(gold, ns.Money(GetMoney() or 0)) or 60) + 4
    gold:SetWidth(goldW)
    P.footerBar:AddRight(gold, goldW, 8)
    W.HelpArea(P.footerBar, gold, "Gold", "The gold you have now.")
    function UI.fitReadouts()
        for _, r in ipairs({ bags, gold }) do
            local text = r:GetText() or ""
            r:SetWidth(text == "" and 1 or math.ceil(measure(r, text) or 0) + 4)
        end
    end
    UI.gold, UI.bags = gold, bags   -- (the specs read them)
    buyTop:SetMotionScriptsWhileDisabled(true)
    buyTop:SetScript("OnEnter", function(self)
        self.hover = true
        buyTopTooltip(self)
    end)
    buyTop:SetScript("OnLeave", function(self)
        self.hover = false
        GameTooltip:Hide()
    end)
    UI.buyTop = buyTop
    -- Above "Buy Top", right-aligned to it: the icon and the name of the gear the next click buys, on the
    -- footer's lower line of text (36 to 50 px above the window's bottom, over the buttons' top at 34).
    topItem = CreateFrame("Button", nil, f)
    topItem:SetHeight(14)
    topItem:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 36)
    topItem.text = topItem:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    topItem.text:SetPoint("RIGHT", topItem, "RIGHT", 0, 0)
    topItem.text:SetJustifyH("RIGHT")
    topItem.text:SetWordWrap(false)
    topItem.icon = topItem:CreateTexture(nil, "ARTWORK")
    topItem.icon:SetSize(14, 14)
    topItem.icon:SetPoint("RIGHT", topItem.text, "LEFT", -3, 0)
    topItem:SetWidth(1)   -- set from the text in updateBuyTop (anchoring it to its own icon is a loop the client refuses)
    -- Its hover: the game's tooltip of the gear, then the same deal lines as its Gear row (UI.AddDealLines); a
    -- click opens its Gear Details, as a click on its row does.
    topItem:SetScript("OnEnter", function(self)
        if not self.link then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetHyperlink(self.link)
        if self.deal then UI.AddDealLines(GameTooltip, self.deal) end
        GameTooltip:AddLine("Click: Gear Details", 0.5, 0.8, 1)
        GameTooltip:Show()
    end)
    topItem:SetScript("OnClick", function(self)
        if self.deal then ns.GearWindow.Open(self.deal) end
    end)
    topItem:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UI.topItem = topItem
    -- The upper line of text, at the right: what the addon is doing now (the spinner before it). (The gold is in the
    -- row of buttons, left of Play.)
    status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("RIGHT", f, "BOTTOMRIGHT", -24, 58)
    status:SetJustifyH("RIGHT")
    status:SetWordWrap(false)
    spinner:SetPoint("RIGHT", status, "LEFT", -6, 0)

    ---------------------------------------------------------------- settings box: what to scan, what to pay
    -- One bounded block with its heading (UI.md Controls 10): settings, not filters of the list. It belongs to the
    -- Gear view (what the scan looks for and what a deal is), under the tabs; the Materials view has none.
    local box = W.Panel(f, 1, 1, 1, 0.05)
    box.uiKind = "settings"
    box:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -(SETTINGS_TOP))
    box:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -(SETTINGS_TOP))
    box:SetHeight(SETTINGS_H)
    P.settingsBox = box
    local heading = W.Label(box, "Scan settings", "GameFontNormal")
    heading:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -6)
    W.HelpArea(box, heading, "Scan settings", "What the scan looks at and what counts as a deal. They apply to Play and "
        .. "to every scan, and set the buy limits (the Limits window).")
    local CAPTION_W = 46
    local function caption(text, y)
        local l = W.Label(box, text, "GameFontNormal")
        l:SetPoint("TOPLEFT", box, "TOPLEFT", 10, y)
        l:SetWidth(CAPTION_W)
        l:SetJustifyH("LEFT")
        return l
    end

    -- Row "Scan": which gear, which quality; on the right the one-off scans.
    local scanCaption = caption("Scan", -26)
    local gearLabel = W.Label(box, "Gear", "GameFontHighlightSmall")
    gearLabel:SetPoint("LEFT", scanCaption, "RIGHT", 6, 0)
    gearChoice = W.Dropdown(box, 140, { { "weapons", "Weapons" }, { "armor", "Armor" } },
        ns.GearTypeOn, ns.SetGearType,
        "Which gear the scan looks at. Armor gives mostly dust, weapons mostly essence. The Limits window shows the buy limits.",
        "Gear")
    gearChoice:SetPoint("LEFT", gearLabel, "RIGHT", 6, 0)
    local qLabel = W.Label(box, "Quality", "GameFontHighlightSmall")
    qLabel:SetPoint("LEFT", gearChoice, "RIGHT", 14, 0)
    qualityDrop = W.Dropdown(box, 180, {
        { 2, "|cff1eff00Uncommon|r" }, { 3, "|cff0070ddRare|r" }, { 4, "|cffa335eeEpic|r" },
    }, function(q) return ns.db.settings.qualities[q] end, function(q, on)
        local qs = ns.db.settings.qualities
        qs[q] = on
        if not (qs[2] or qs[3] or qs[4]) then
            qs[q] = true
            ns.Print("at least one quality must stay on")
        end
        ns.Log("quality %d = %s", q, tostring(qs[q]))
        ns.Fire("SALVAGER_SETTINGS")
    end, "Which gear qualities the scan looks at. Uncommon gives dust and essence, rare one shard, epic 2-4 shards "
        .. "or Nexus Crystals.", "Quality")
    qualityDrop:SetPoint("LEFT", qLabel, "RIGHT", 6, 0)

    -- Left to right: Gear, Materials, Both (the user's order, 0.3.129).
    local scanBoth = W.Button(box, "Both", 58, function() ns.ScanBoth(true) end,
        "Once: scans the material prices first, then the gear.")
    scanBoth:SetPoint("TOPRIGHT", box, "TOPRIGHT", -8, -22)
    local scanMats = W.Button(box, "Materials", 84, function() ns.Prices.Scan() end,
        "Once: searches each disenchanting material (about 20 seconds) and stores its price.")
    scanMats:SetPoint("RIGHT", scanBoth, "LEFT", -4, 0)
    local scanGear = W.Button(box, "Gear", 58, function() ns.Scanner.Scan(true) end,
        "Once: lists the gear on the auction house and checks each one that is below its buy limit.")
    scanGear:SetPoint("RIGHT", scanMats, "LEFT", -4, 0)
    UI.scanButtons = { scanGear, scanMats, scanBoth }   -- (the specs read them)
    for _, b in ipairs(UI.scanButtons) do W.ReasonTip(b) end
    local onceLabel = W.Label(box, "Scan once", "GameFontHighlightSmall")
    onceLabel:SetPoint("RIGHT", scanGear, "LEFT", -8, 0)
    W.HelpArea(box, onceLabel, "Scan once", "A single scan by hand. Play does all of this by itself, again and again.")

    -- Row "Buy": the least profit, the most to pay.
    local buyCaption = caption("Buy", -54)
    local mpLabel = W.Label(box, "Min profit", "GameFontHighlightSmall")
    mpLabel:SetPoint("LEFT", buyCaption, "RIGHT", 6, 0)
    W.HelpArea(box, mpLabel, "Min profit", "The least profit a piece of gear must make on average: it is a deal when it "
        .. "costs no more than its disenchant value minus this.")
    minProfit = W.Money(box, function(copper)
        ns.db.settings.minProfit = copper
        ns.Log("min profit set to %s", ns.Money(copper))
        ns.Fire("SALVAGER_SETTINGS")
    end)
    minProfit:SetPoint("LEFT", mpLabel, "RIGHT", 4, 0)
    local mrLabel = W.Label(box, "Min return", "GameFontHighlightSmall")
    mrLabel:SetPoint("LEFT", minProfit:Right(), "RIGHT", 16, 0)
    W.HelpArea(box, mrLabel, "Min return", "The least return a piece of gear must make as well, in percent of its price: "
        .. "15 = each 1g you pay must bring 1g 15s back on average. Both rules hold: cheap gear needs the return, "
        .. "expensive gear the profit. 0 = off.")
    minReturn = W.Edit(box, 30, true)
    minReturn:SetMaxLetters(3)
    minReturn:SetJustifyH("RIGHT")
    minReturn:SetTextInsets(2, 4, 0, 0)
    minReturn:SetPoint("LEFT", mrLabel, "RIGHT", 6, 0)
    minReturn:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    minReturn:SetScript("OnEditFocusLost", function(self)
        local n = math.max(0, math.floor(tonumber(self:GetText()) or 0))
        if ns.db.settings.minReturn ~= n then
            ns.db.settings.minReturn = n
            ns.Log("min return set to %d%%", n)
            ns.Fire("SALVAGER_SETTINGS")
        end
    end)
    local pctLabel = W.Label(box, "%", "GameFontHighlightSmall")
    pctLabel:SetPoint("LEFT", minReturn, "RIGHT", 3, 0)
    local capLabel = W.Label(box, "Max price", "GameFontHighlightSmall")
    capLabel:SetPoint("LEFT", pctLabel, "RIGHT", 16, 0)
    W.HelpArea(box, capLabel, "Max price", "The most you pay for one piece of gear, whatever it is worth. Gear above "
        .. "this is never listed. All zeroes = no limit.")
    maxPrice = W.Money(box, function(copper)
        ns.db.settings.maxPrice = copper
        ns.Log("max price set to %s", copper > 0 and ns.Money(copper) or "none")
        ns.Fire("SALVAGER_SETTINGS")
    end)
    maxPrice:SetPoint("LEFT", capLabel, "RIGHT", 4, 0)
    -- (No "no limit" text after the boxes: at the narrowest window it ran into Cautious. Its help says it.)
    cautious = W.Check(box, "Cautious", "Cautious pricing: the buy limit counts every material at its lowest amount "
        .. "(1 dust, not the average 1.5) and no Arcane Salvager bonus. You see fewer deals, and they lose less often. "
        .. "Value and Profit still show the average.", function(on)
        ns.db.settings.cautious = on
        ns.Log("cautious pricing %s", on and "on" or "off")
        ns.Fire("SALVAGER_SETTINGS")
    end)
    cautious:SetPoint("TOPRIGHT", box, "TOPRIGHT", -78, -50)

    -- Row "Levels": which item levels the scan looks at, by band or by a range of your own.
    local levelCaption = caption("Levels", -82)
    local bandLabel = W.Label(box, "Bands", "GameFontHighlightSmall")
    bandLabel:SetPoint("LEFT", levelCaption, "RIGHT", 6, 0)
    local bandOptions = {}
    for _, band in ipairs(ns.LevelBands()) do bandOptions[#bandOptions + 1] = { band.up, band.label } end
    bandDrop = W.Dropdown(box, 200, bandOptions,
        function(up) return not ns.db.settings.levelBandsOff[up] end,
        function(up, on)
            local off = ns.db.settings.levelBandsOff
            off[up] = (not on) or nil
            local any = false
            for _, band in ipairs(ns.LevelBands()) do if not off[band.up] then any = true end end
            if not any then
                off[up] = nil
                ns.Print("at least one band must stay on")
            end
            ns.Log("level band %s = %s", tostring(up), tostring(not off[up]))
            ns.Fire("SALVAGER_SETTINGS")
        end,
        "Which item level bands the scan looks at. A band is a range of item levels that disenchants into the same "
            .. "materials. The Limits window and the Reports' Odds tab list them.", "Bands",
        function(names, total)
            if #names == total then return "All" end
            if #names > 3 then return #names .. " bands" end
            return table.concat(names, ", ")
        end)
    bandDrop:SetPoint("LEFT", bandLabel, "RIGHT", 6, 0)

    local function levelBox(key)
        local e = W.Edit(box, 34, true)
        e:SetMaxLetters(3)
        e:SetJustifyH("RIGHT")
        e:SetTextInsets(2, 4, 0, 0)
        e:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
        e:SetScript("OnEditFocusLost", function(self)
            local n = math.max(0, math.floor(tonumber(self:GetText()) or 0))
            if ns.db.settings[key] ~= n then
                ns.db.settings[key] = n
                ns.Log("%s = %d", key, n)
                ns.Fire("SALVAGER_SETTINGS")
            end
        end)
        return e
    end
    local rangeLabel = W.Label(box, "or item level from", "GameFontHighlightSmall")
    rangeLabel:SetPoint("LEFT", bandDrop, "RIGHT", 18, 0)
    W.HelpArea(box, rangeLabel, "Item level range", "A range of your own, on top of the bands: the scan only lists "
        .. "gear whose item level is inside it. 0 = no limit on that side. Gear must pass both the bands and the range.")
    ilvlMin = levelBox("ilvlMin")
    ilvlMin:SetPoint("LEFT", rangeLabel, "RIGHT", 10, 0)
    local toLabel = W.Label(box, "to", "GameFontHighlightSmall")
    toLabel:SetPoint("LEFT", ilvlMin, "RIGHT", 8, 0)
    ilvlMax = levelBox("ilvlMax")
    ilvlMax:SetPoint("LEFT", toLabel, "RIGHT", 10, 0)
    -- At the right end of the row: how many gear searches one scan makes.
    maxChecks = W.Edit(box, 34, true)
    maxChecks:SetMaxLetters(3)
    maxChecks:SetJustifyH("RIGHT")
    maxChecks:SetTextInsets(2, 4, 0, 0)
    maxChecks:SetPoint("TOPRIGHT", box, "TOPRIGHT", -10, -79)
    maxChecks:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    maxChecks:SetScript("OnEditFocusLost", function(self)
        local n = math.max(1, math.floor(tonumber(self:GetText()) or 0))
        if ns.db.settings.maxChecks ~= n then
            ns.db.settings.maxChecks = n
            ns.Log("maxChecks = %d", n)
        end
        ns.Fire("SALVAGER_SETTINGS")
    end)
        -- ("Show top" since 0.4.0, was "Gear checks"; the setting stays maxChecks.)
    local checksLabel = W.Label(box, "Show top", "GameFontHighlightSmall")
    checksLabel:SetPoint("RIGHT", maxChecks, "LEFT", -8, 0)
        W.HelpArea(box, checksLabel, "Show top", "How many of the best gear candidates each scan searches and shows (the best "
        .. "by the sort first). Each one is one auction house search (about 0.7 s), and the Gear list holds at most this many.")
        -- Left of Show top (the row with room): the Arcane Salvager's bonus in the buy prices, a setting of the scan
    -- (UI.md Controls 10; it left the Options, Layout 1, and replaced the footer's "Arcane Salvager bonus included",
    -- 0.4.0).
    P.salvager = W.Check(box, "Arcane Salvager", nil, function(on)
        ns.SetSalvagerForBuy(on)
    end)
    W.Tooltip(P.salvager, "Arcane Salvager", ns.SALVAGER_BOX_HELP)
    local salvW = math.ceil(tonumber((P.salvager.label:GetStringWidth())) or 0)
    P.salvager:SetPoint("RIGHT", checksLabel, "LEFT", -(2 + salvW + 16), 0)
    levelHint = W.Label(box, "", "GameFontDisableSmall")
    levelHint:SetPoint("LEFT", ilvlMax, "RIGHT", 8, 0)
    levelHint:SetPoint("RIGHT", P.salvager, "LEFT", -8, 0)
    levelHint:SetJustifyH("LEFT")
    levelHint:SetWordWrap(false)
    -- What the settings need (the width authority, SDD 120): per row, its controls from the left to the right end of
    -- the last one, 24 px, its controls at the right end; measured where they are drawn.
    local settingsRows = {
        { left = function() return qualityDrop:GetRight() end, right = onceLabel },
        { left = function() return maxPrice:Right():GetRight() end, right = cautious },
        { left = function()
            local r = ilvlMax:GetRight()
            local hint = tonumber((levelHint:GetStringWidth())) or 0
            return r and (r + (hint > 0 and 8 + hint or 0))
        end, right = P.salvager },
    }
    function P.settingsNeed()
        local l, r = box:GetLeft(), box:GetRight()
        if not (l and r) then return 0 end
        local most = 0
        for _, row in ipairs(settingsRows) do
            local a = row.left()
            local b = row.right:GetLeft()
            if row.right.GetObjectType and row.right:GetObjectType() == "FontString" then
                local rr = row.right:GetRight()
                if rr then b = rr - (tonumber((row.right:GetStringWidth())) or 0) end
            end
            if a and b then most = math.max(most, (a - l) + 24 + (r - b)) end
        end
        return math.ceil(most)
    end

    ---------------------------------------------------------------- tabs, right under the title bar
    -- The row holds the tabs only (UI.md Controls 3): the pop-out, the materials' filter and Scan owned are on the
    -- Materials view's filter row, the gold in the footer.
    P.tabBar = W.Bar(f, "tabs"):Place(TABS_TOP)
    UI.tabBar = P.tabBar
    for _, t in ipairs({ { "deals", "Gear" }, { "materials", "Materials" } }) do
        local b = W.Tab(P.tabBar, t[2], function()
            -- The Materials tab, while its list is in its own window: put it back here.
            if t[1] == "materials" then ns.Materials.PutBack() end
            UI.view = t[1]
            ns.db.window.view = t[1]
            UI.offset = 0
            UI.Refresh()
        end)
        tabs[t[1]] = b
        P.tabBar:Add(b, 90)
    end
    W.Tooltip(tabs.deals, "Gear", "The gear on the auction house that costs no more than its buy limit, best profit "
        .. "first, with the scan settings. Click a row for its Gear details.")
    W.Tooltip(tabs.materials, "Materials", "Prices, stock and break-even of the disenchanting materials. "
        .. "While the list is in its own window (Pop out), a click here puts it back.")

    -- The Materials view's filter row: the filter at the left, its actions at the right end.
    P.materialsBar = W.Bar(f, "filters"):Place(FILTERS_TOP)
    UI.materialsBar = P.materialsBar
    materialsOnly = ns.Materials.DataOnlyCheck(P.materialsBar)
    P.materialsBar:AddCheck(materialsOnly)
    -- The list in a window of its own, and back.
    popOut = W.IconButton(P.materialsBar, 22, function()
        if ns.Materials.IsPoppedOut() then ns.Materials.PutBack() else ns.Materials.PopOut() end
    end)
    popOut:SetPopOutGlyph()
    popOut:SetScript("OnEnter", function(self)
        local out = ns.Materials.IsPoppedOut()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(out and "Put the materials list back" or "Pop out the materials list", 1, 1, 1)
        W.AddHelp(GameTooltip, nil, out and "Closes its window and shows the list in the Materials tab again."
            or "Moves the materials list to a window of its own, so you can watch it next to the gear. "
                .. "Scans keep running. Click again, or close that window, to put it back.")
        GameTooltip:Show()
    end)
    popOut:SetScript("OnLeave", function() GameTooltip:Hide() end)
    P.materialsBar:AddRight(popOut, 22)
    scanOwned = ns.Materials.ScanOwnedButton(P.materialsBar)
    P.materialsBar:AddRight(scanOwned, 96)
    P.materialsBar:Hide()

    ---------------------------------------------------------------- the list, in its own sunken panel
    -- (Its top follows the view: under the settings block or the filter row. Its bottom leaves room for the
    -- footer's two lines and its row of buttons.)
    P.inset = W.Panel(f, 0, 0, 0, 0.5)
    UI.listArea = P.inset   -- (the specs put the mouse on it)
    P.inset:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -(SETTINGS_TOP + SETTINGS_H + 6))
    P.inset:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, UI.listBottom or LIST_BOTTOM)
    titleBand = P.inset:CreateTexture(nil, "BACKGROUND", nil, 1)
    titleBand:SetPoint("TOPLEFT", P.inset, "TOPLEFT", 1, -1)
    titleBand:SetPoint("TOPRIGHT", P.inset, "TOPRIGHT", -1, -1)
    titleBand:SetHeight(ROW_H)
    titleBand:SetColorTexture(1, 1, 1, 0.07)

    local list = CreateFrame("Frame", nil, P.inset)
    list:SetPoint("TOPLEFT", P.inset, "TOPLEFT", 2, -1)
    list:SetPoint("BOTTOMRIGHT", P.inset, "BOTTOMRIGHT", -20, 2)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        UI.offset = math.max(0, UI.offset - delta * 3)
        UI.Refresh()
    end)
    UI.list = list
    if list.SetClipsChildren then list:SetClipsChildren(true) end
    -- What the list's columns and marks mean: the first thing on the row of column titles.
    helpButton = W.HelpButton(list, function()
        return UI.view == "materials" and "Materials" or "Gear"
    end, helpLines, { left = true })
    helpButton:SetSize(20, 20)

    -- Scroll bar on the right, inside the panel.
    local bar = W.ScrollBar(P.inset, function(value)
        if value ~= UI.offset then
            UI.offset = value
            UI.Refresh()
        end
    end)
    bar:SetPoint("TOPRIGHT", P.inset, "TOPRIGHT", -3, -ROW_H - 3)
    bar:SetPoint("BOTTOMRIGHT", P.inset, "BOTTOMRIGHT", -3, 3)
    bar:EnableMouseWheel(true)
    bar:SetScript("OnMouseWheel", list:GetScript("OnMouseWheel"))
    UI.bar = bar
    -- The column chooser: at the right end of the title band, over the scroll bar (the list ends before it).
    columnsButton = W.ColumnChooser(P.inset, function()
        local view, entries = VIEWS[UI.view], {}
        for i, name in ipairs(view.header) do entries[i] = { key = name, locked = i == 1 and W.FIRST_COLUMN_REASON or nil } end
        if view.actionTitle then entries[#entries + 1] = { key = view.actionTitle, locked = W.ACTION_COLUMN_REASON } end
        return view.id, entries
    end, function() UI.Refresh() end)
    columnsButton:SetPoint("TOPRIGHT", P.inset, "TOPRIGHT", -3, -4)
    UI.columnsButton = columnsButton
    UI.headers = headers
    -- The title over the rows' buttons (Buy, Post).
    actionHeader = list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    actionHeader:SetHeight(ROW_H)
    actionHeader:SetWidth(64)
    actionHeader:SetJustifyH("CENTER")
    actionHeader:SetPoint("TOPRIGHT", list, "TOPRIGHT", -4, 0)
    UI.actionHeader, UI.rows = actionHeader, rows   -- (the fit spec measures them)
    -- (The checks outside the addon read the table from its frame: the sim gate, the layout dump.)
    list.tableParts = { headers = headers, rows = rows, action = actionHeader }
    for i = 1, MAX_COLS do
        local h = list:CreateFontString(nil, "OVERLAY", W.TITLE_FONT)
        h.measureFont = W.TITLE_FONT
        h:SetHeight(ROW_H)
        h:SetWordWrap(true)   -- (a long title takes two lines)
        headers[i] = h
        -- An invisible area over the title, for its help text.
        local area = CreateFrame("Frame", nil, list)
        area:SetAllPoints(h)
        area:EnableMouse(true)
        area:SetScript("OnEnter", function(self)
            local help, col = rawget(self, "help"), rawget(self, "sortCol")
            if not (help or col) then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            W.AddHelp(GameTooltip, help and help[1] or tostring(rawget(self, "title") or ""), help and help[2])
            if col then W.AddHelp(GameTooltip, nil, W.SORT_HINT, 0.5, 0.8, 1) end
            GameTooltip:Show()
        end)
        area:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- A click on a title sorts the list by it (Widgets.SortClick), again the other way round. Profit and Avg
        -- return also set the scan's order (dealSort: what each scan checks first and Buy Top buys first).
        area:SetScript("OnMouseUp", function(self)
            local col, sortKey = rawget(self, "sortCol"), rawget(self, "sortKey")
            if not col then return end
            local view = VIEWS[UI.view]
            local id = view.id == "deals" and "main.deals" or view.id
            local st = W.SortState(id, true)
            local by, desc = UI.SortOfView(view)
            if st.key == nil and by then st.key, st.desc = view.header[by], desc end
            local cols = {}
            for n, t in ipairs(view.header) do cols[n] = { t } end
            local plain = {}   -- (a Gear group row is not a heading here: it sorts with its auctions)
            for _, r in ipairs(UI.Unsorted(UI.view)) do plain[#plain + 1] = { cells = r.cells, sort = r.sort } end
            W.SortClick(st, cols, col, plain)
            if sortKey and ns.db.settings.dealSort ~= sortKey then
                ns.db.settings.dealSort = sortKey
                ns.Scanner.Sort()
            end
            ns.Log("%s listed by %s", UI.view == "deals" and "deals" or "materials", tostring(view.header[col]))
            UI.offset = 0
            UI.Refresh()
        end)
        area:Hide()
        headerHelp[i] = area
    end
    for r = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -r * ROW_H)
        row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        if r % 2 == 0 then
            -- Every second row a shade lighter, so the list reads as lines.
            local stripe = row:CreateTexture(nil, "BACKGROUND")
            stripe:SetAllPoints()
            stripe:SetColorTexture(1, 1, 1, 0.035)
        end
        -- An unusually high average return (UI.HighReturn): an orange tint over the row, with "!" after its buyout.
        row.tint = row:CreateTexture(nil, "BACKGROUND", nil, 1)
        row.tint:SetAllPoints()
        row.tint:SetColorTexture(1, 0.5, 0.15, 0.16)
        row.tint:Hide()
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.cells = {}
        for i = 1, MAX_COLS do
            local fs = row:CreateFontString(nil, "OVERLAY", W.CELL_FONT)
            fs.measureFont = W.CELL_FONT
            fs:SetHeight(ROW_H)
            fs:SetWordWrap(false)
            if i == 1 then fs.canCut = true end   -- (the label gives way on a narrow screen: "...", the name on hover)
            row.cells[i] = fs
        end
        -- Over the profit cell, the deal's outcomes; over a highlighted buyout, why it is highlighted (SDD 116). The
        -- rest of the row keeps the item's tooltip. A click on them is a click on the row.
        local function cellArea(i, show)
            local a = CreateFrame("Button", nil, row)
            a:SetAllPoints(row.cells[i])
            a:SetScript("OnEnter", function(self)
                row:LockHighlight()
                if not show(self, row.item) then rowTooltip(row) end
            end)
            a:SetScript("OnLeave", function()
                row:UnlockHighlight()
                GameTooltip:Hide()
            end)
            a:SetScript("OnClick", function() local fn = row:GetScript("OnClick") if fn then fn(row) end end)
            a:Hide()
            return a
        end
        local function itemDeal(item)
            return UI.view == "deals" and item and (item.deal or (item.group and ns.Scanner.Cheapest(item.group.deals)))
        end
        row.rangeArea = cellArea(5, function(self, item)
            local d = itemDeal(item)
            if not d then return false end
            UI.RangeTooltip(self, d)
            return true
        end)
        row.buyoutArea = cellArea(4, function(self, item)
            if not (itemDeal(item) and item.high) then return false end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Unusually high return", 1, 0.5, 0.25)
            W.AddHelp(GameTooltip, nil, highHelp())
            GameTooltip:Show()
            return true
        end)
        row.buy = W.Button(row, "Buy", 64, function()
            local item = row.item
            if not item then return end
            if item.post then ns.Post.Open(item.itemID) return end
            local deal = item.deal or (item.group and ns.Scanner.Cheapest(item.group.deals))
            if deal then ns.Scanner.Buy(deal) end
        end)
        -- Off, the reason shows on hover.
        row.buy:SetMotionScriptsWhileDisabled(true)
        row.buy:HookScript("OnEnter", function(self)
            if not self.reason then return end
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText(self:GetText() or "", 1, 1, 1)
            GameTooltip:AddLine(self.reason, 1, 0.3, 0.3, true)
            GameTooltip:Show()
        end)
        row.buy:HookScript("OnLeave", function() GameTooltip:Hide() end)
        row.warn = CreateFrame("Frame", nil, row)
        row.warn:SetSize(18, 18)
        row.warn:SetPoint("RIGHT", row.buy, "LEFT", -4, 0)
        local warnIcon = row.warn:CreateTexture(nil, "ARTWORK")
        warnIcon:SetAllPoints()
        warnIcon:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
        row.warn:EnableMouse(true)
        row.warn:SetScript("OnEnter", function(self)
            local sug = row.item and row.item.suggest
            if not sug then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText("Below your break-even", 1, 0.3, 0.3)
            W.AddHelp(GameTooltip, nil, ns.Materials.WarnText(sug))
            GameTooltip:Show()
        end)
        row.warn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.warn:Hide()
        row.toggle = row:CreateTexture(nil, "ARTWORK")
        row.toggle:SetSize(14, 14)
        row.toggle:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.toggle:Hide()
        -- A group heading opens and closes; an auction's row shows its Gear details; a material its breakdown.
        row:SetScript("OnClick", function(self)
            local item = self.item
            if item and item.onClick then
                item.onClick()
            elseif item and item.deal then
                ns.GearWindow.Open(item.deal)
            elseif item and UI.view == "materials" then
                ns.RowClick(item)
            end
        end)
        row.buy:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row:SetScript("OnEnter", rowTooltip)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[r] = row
    end
    bigSpinner = W.Spinner(list, 64)
    bigSpinner:SetPoint("CENTER", list, "CENTER", 0, 10)
    bigSpinnerText = list:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    bigSpinnerText:SetPoint("TOP", bigSpinner, "BOTTOM", 0, -6)

    -- Two texts under the list, over the footer's row: what the last scan found, then the gear closest to its limit.
    -- Never cut (0.4.0, the user: "no truncated text"): each wraps in the room left of the status and the gear Buy
    -- Top buys, and the list's bottom moves up to make room for their lines (UI.layoutFooter, UI.md Layout 6).
    footer2 = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer2:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 36)
    footer2:SetJustifyH("LEFT")
    footer2:SetWordWrap(true)
    footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", footer2, "TOPLEFT", 0, 2)
    footer:SetJustifyH("LEFT")
    footer:SetWordWrap(true)
    UI.footerLines = { footer, footer2 }

    -- Resize from the bottom right corner, the height only (the width is fixed: Refresh sets it and its bounds).
    f:SetResizable(true)
    local maxH = UIParent:GetHeight()
    if f.SetResizeBounds then
        f:SetResizeBounds(MIN_W, MIN_H, MIN_W, maxH)
    elseif f.SetMinResize then
        f:SetMinResize(MIN_W, MIN_H)
        if f.SetMaxResize then f:SetMaxResize(MIN_W, maxH) end
    end
    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -4, 4)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function()
        anchorTopLeft()
        f:StartSizing("BOTTOMRIGHT", true)
    end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        ns.db.window.w, ns.db.window.h = nil, math.floor(f:GetHeight())
        savePosition()
        UI.Refresh()
    end)
    f:SetScript("OnSizeChanged", function()
        W.ClampToTitle(f)
        UI.Refresh()
    end)

    if VIEWS[ns.db.window.view] then UI.view = ns.db.window.view end
    f:SetScript("OnShow", function()
        ns.SettleSalvager()
        UI.Refresh()
        UI.RestoreWindows()
    end)
    -- The main window closes (X, Escape, the Auction house button): every window it opened goes with it (what was
    -- open is still remembered, and comes back with the main window). Minimize keeps them.
    f:SetScript("OnHide", function()
        if not UI.minimizing then UI.HideOthers() end
    end)
    -- Minimize: left of the close button, the game's minimize look (the condense arrow) where the client has it.
    local mini = CreateFrame("Button", nil, f)
    mini:SetSize(24, 24)
    local close = f.CloseButton
    -- (Right next to it, not over it: 4 px over the close button in the client's layout dump, 0.4.0.)
    if type(close) == "table" then mini:SetPoint("RIGHT", close, "LEFT", 0, 0)
    else mini:SetPoint("TOPRIGHT", f, "TOPRIGHT", -24, 0) end
    local atlas = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("RedButton-Condense")
    if atlas and mini.SetNormalAtlas then
        mini:SetNormalAtlas("RedButton-Condense")
        mini:SetPushedAtlas("RedButton-Condense-Pressed")
        mini:SetHighlightAtlas("RedButton-Highlight", "ADD")
    else
        local glyph = mini:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        glyph:SetPoint("CENTER", mini, "CENTER", 0, 3)
        glyph:SetText("_")
        local hl = mini:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.12)
    end
    mini.uiKind = "minimize"
    mini:SetScript("OnClick", function() UI.Minimize() end)
    W.Tooltip(mini, "Minimize", "Hides this window and shows the Salvager mini panel: a small window with a button for "
        .. "each Salvager window. The other windows stay open. Scans go on.")
    UI.minimizeButton = mini   -- (the specs click it)
    -- Options: a gear icon in the title bar, left of Minimize (it left the footer, 0.4.0).
    local options = W.IconButton(f, 20, function() ns.Options.Open() end)
    options:SetIcon("Interface\\Buttons\\UI-OptionsButton", 14, 14)
    options:SetPoint("RIGHT", mini, "LEFT", -2, 0)
    options.uiKind = "titlebutton"
    W.Tooltip(options, "Options", "Opens the addon's options.")
    UI.optionsButton = options   -- (the specs click it)
    f:Hide()
end

--- Minimize: the main window hides, the other windows stay, the mini panel shows (scans go on).
function UI.Minimize()
    if not f then return end
    UI.minimizing = true
    f:Hide()
    UI.minimizing = false
    ns.MiniPanel.Show()
    ns.Log("main window minimized")
end

--- Who opens a window now (Widgets.Window keeps it as the window's owner): the mini panel while one of its buttons
--- runs, else the main window while it shows, else nobody (the window stays on its own).
function W.Opener()
    if W.opening then return W.opening end
    return (f and f:IsShown()) and "main" or "panel"
end

--- Hides the windows the main window opened (owner "main"), without changing what is remembered as open. The ones
--- opened from the mini panel stay. Each on its own: one that fails does not keep the others open.
function UI.HideOthers()
    local n = 0
    for _, w in ipairs(W.windows) do
        local x = w.frame
        if x ~= f and not rawget(x, "launcher") and x:IsShown() and rawget(x, "owner") ~= "panel" then
            local ok, err = pcall(x.Hide, x)
            if ok then n = n + 1 else ns.Log("ERROR closing %s: %s", tostring(x:GetName()), tostring(err)) end
        end
    end
    if n > 0 then ns.Log("main window closed: %d windows closed with it", n) end
end

--- The windows that were open last time, again (with the main window, when the setting is on).
function UI.RestoreWindows()
    if not ns.db.settings.restoreWindows then return end
    ns.LedgerWindow.Restore()
    ns.LogWindow.Restore()
    ns.Materials.Restore()
    ns.Market.Restore()
    ns.Reports.Restore()
    ns.Odds.Restore()
    ns.LimitsWindow.Restore()
end

--- Only the auction house window (the game's, or another addon's): the Salvager windows close, scans and
--- checks go on. (The auction house window is open already: it is not shown here, another addon may keep
--- the game's one out of sight on purpose.)
function UI.ToAuctionHouse()
    if f then f:Hide() end
end

-- On the auction house window: a button that brings the Salvager windows back. On the game's window and on
-- ForeverForge's (which hides the game's), above the top right corner: the space under the window holds the
-- game's tabs and other addons' buttons. It can be dragged anywhere around the window; the place is kept.
local AH_WINDOWS = { "AuctionHouseFrame", "ForeverForgeAuctionFrame" }
local ahButtons = {}

local function placeAhButton(b, host)
    b:ClearAllPoints()
    local p = ns.db.windows.ahButton
    if type(p) == "table" and tonumber(p.x) and tonumber(p.y) then
        b:SetPoint("BOTTOMRIGHT", host, "TOPRIGHT", p.x, p.y)
    else
        b:SetPoint("BOTTOMRIGHT", host, "TOPRIGHT", -30, 2)
    end
end

local function addAuctionHouseButtons()
    for _, name in ipairs(AH_WINDOWS) do
        local host = _G[name]
        if host and not ahButtons[name] then
            local b = W.Button(host, "Salvager", 90, function() UI.Toggle() end,
                "Opens the Salvager windows over the auction house (and closes them again). Drag it to move it; "
                .. "it stays where you put it.")
            if b.SetFrameLevel and host.GetFrameLevel then b:SetFrameLevel((host:GetFrameLevel() or 0) + 50) end
            b:SetMovable(true)
            b:RegisterForDrag("LeftButton")
            b:SetScript("OnDragStart", function(self) self:StartMoving() end)
            b:SetScript("OnDragStop", function(self)
                self:StopMovingOrSizing()
                -- Kept as an offset from the window's top right corner, for both windows.
                local right, top = host:GetRight(), host:GetTop()
                local bRight, bBottom = self:GetRight(), self:GetBottom()
                if right and top and bRight and bBottom then
                    ns.db.windows.ahButton = { x = math.floor(bRight - right + 0.5), y = math.floor(bBottom - top + 0.5) }
                end
                for n, other in pairs(ahButtons) do placeAhButton(other, _G[n]) end
            end)
            placeAhButton(b, host)
            ahButtons[name] = b
        end
    end
end

function UI.Frame() return f end

-- A build that fails leaves a half-made window: the error goes to the Log too, not only to the game's error box.
local function ensure()
    if f then return end
    local ok, err = pcall(build)
    if not ok then
        ns.Log("ERROR building the main window: %s", tostring(err))
        error(err, 0)
    end
end

function UI.Toggle()
    ensure()
    f:SetShown(not f:IsShown())
end

function UI.Show()
    ensure()
    f:Show()
end

for _, e in ipairs({ "SALVAGER_PRICES", "SALVAGER_PRICES_DONE", "SALVAGER_SCAN", "SALVAGER_DEALS", "SALVAGER_LISTINGS",
    "SALVAGER_LEDGER", "SALVAGER_SETTINGS" }) do
    ns.On(e, function() UI.RequestRefresh() end)
end

ns.On("AUCTION_HOUSE_SHOW", function()
    ns.SettleSalvager()
    addAuctionHouseButtons()
    -- (Another addon may build its auction window a moment after this event.)
    C_Timer.After(0.5, addAuctionHouseButtons)
    C_Timer.After(2, addAuctionHouseButtons)
    if ns.db.settings.autoOpen then
        UI.Show()
        -- The layout of last time: the windows that were open, and the tab that was showing. (Also when the
        -- main window was open already: then it gets no OnShow.)
        UI.RestoreWindows()
    end
    UI.Refresh()
end)
ns.On("AUCTION_HOUSE_CLOSED", function() UI.Refresh() end)
-- Bag counts (the Bags column, the Post buttons) follow the bags.
ns.On("BAG_UPDATE_DELAYED", function() UI.RequestRefresh() end)
ns.On("PLAYER_MONEY", function() UI.RequestRefresh() end)

-- Where the mouse is holds nothing: the scan goes on under it (0.3.142, the user; SDD 105b). Only the search of the
-- deal under the mouse goes ahead when a browse made it stale (`Scanner.Prefetch`), so the click that comes buys.
--- The deal a click would buy now: the Gear row under the mouse (a group: the auction its Buy buys), Buy Top's, or
--- the one Gear Details shows. Its gear is searched again first when a browse made its search stale (Prefetch).
local function dealUnderMouse()
    if f and f:IsVisible() and UI.view == "deals" then
        if buyTop:IsMouseOver() or (topItem:IsShown() and topItem:IsMouseOver()) then return (topDeal()) end
        for _, row in ipairs(rows or {}) do
            local item = row:IsShown() and row:IsMouseOver() and row.item
            if item then return item.deal or (item.group and ns.Scanner.Cheapest(item.group.deals)) end
        end
    end
    local g = ns.GearWindow and ns.GearWindow.Frame()
    if g and g:IsVisible() and g:IsMouseOver() then return ns.GearWindow.deal end
end

local wasBusy = false
local statusAt = 0

ns.OnTick(function()
    -- (Anywhere over a row, Buy Top or Gear Details: the search goes ahead of the click, past every hold.)
    ns.Scanner.Prefetch(dealUnderMouse())
    -- (The Live countdown in the status, twice a second while Play runs.)
    if ns.Scanner.auto and f and f:IsVisible() and GetTime() - statusAt >= 0.5 then
        statusAt = GetTime()
        UI.SetStatus(true)
    end

    -- Every Buy follows the auction house: off while it is busy, on the moment it is ready (one click buys).
    local busy = ns.Scanner.BuyBusy() ~= nil
    if busy ~= wasBusy then
        if buyTop and f and f:IsVisible() then updateBuyTop() UI.RequestRefresh() end
        if ns.GearWindow and ns.GearWindow.Frame() and ns.GearWindow.Frame():IsVisible() then ns.GearWindow.Refresh() end
    end
    wasBusy = busy
end)

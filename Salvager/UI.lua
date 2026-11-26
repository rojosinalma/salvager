-- Salvager: the main window (Deals, Materials, Limits) and the Log panel attached to its right side.
local _, ns = ...

local Data, W = ns.Data, ns.Widgets

local UI = { view = "deals", offset = 0, expanded = {} }
ns.UI = UI

local MAX_ROWS, ROW_H = 40, 24
local MAX_COLS = 10
local WIDTH, HEIGHT = 800, 560
local MIN_W, MIN_H = 800, 470
local ROWS = 15          -- rows that fit now (set from the list height)
local CLASS_NAME = { [2] = "Weapon", [4] = "Armor" }

local VIEWS = {
    deals = {
        icon = true,
        indent = 46,
        actionTitle = "Buy",
        header = { "Item", "Type", "Item level", "Buyout", "Expected value", "Expected profit", "Return", "Loss chance" },
        sortable = { [6] = "profit", [7] = "return" },
        -- Shown when the mouse is over a column's title.
        help = {
            [5] = { "Expected value", "What one disenchant of this item is worth on average over many disenchants, at the "
                .. "scanned material prices, after the 5% auction house cut. One disenchant gives less or more than this." },
            [6] = { "Expected profit", "Expected value minus the buyout: the average profit per item over many disenchants. "
                .. "It is not what one item will give.\n\nClick to list the deals by Expected profit." },
            [7] = { "Return", "Expected profit as a share of the buyout: what each gold you pay brings back on top. "
                .. "When your gold is what limits you, buy the highest Return first.\n\nClick to list the deals by Return." },
            [8] = { "Loss chance", "The chance that ONE disenchant of this item is worth less than its buyout, after the cut.\n\n"
                .. "Example: you pay 10s for an item. 3 times out of 4 it gives dust worth 5s: you lose 5s. 1 time "
                .. "out of 4 it gives an essence worth 30s: you gain 20s. Loss chance is 75%. Over many items you still "
                .. "gain: the average is 11s 25c per item, so 1s 25c of profit each.\n\n"
                .. "Green: under 30%. Yellow: 30% or more. Red: 60% or more.\n\n"
                .. "A high Loss chance with a good Profit needs many items before the average shows. A low Loss chance is safe "
                .. "even for a few items." },
        },
        cols = { { 205, "LEFT" }, { 46, "CENTER" }, { 34, "CENTER" }, { 80, "RIGHT" }, { 80, "RIGHT" }, { 80, "RIGHT" },
            { 44, "RIGHT" }, { 54, "CENTER" } },
    },
    materials = {
        icon = true,
        actionTitle = "Post",
        header = { "Material", "Price", "Age", "Bags", "Listed", "Sold", "Avg cost", "Break-even", "Profit" },
        cols = { { 160, "LEFT" }, { 80, "RIGHT" }, { 36, "CENTER" }, { 40, "CENTER" }, { 46, "CENTER" }, { 46, "CENTER" },
            { 85, "RIGHT" }, { 85, "RIGHT" }, { 85, "RIGHT" } },   -- (the same as Materials.COLUMNS)
        help = "materials",                        -- (the titles' help is Materials.HELP)
    },
    limits = {
        icon = false,
        -- Two halves, Armor and Weapons, each with its title over its two columns; the rows are the bands,
        -- every quality (whatever the scan looks at), by quality, then the range.
        header = { "Item level", "Recommended price threshold", "Override price threshold",
            "Recommended price threshold", "Override price threshold" },
        groupHeader = { { 2, 3, "Armor" }, { 4, 5, "Weapons" } },
        -- The long titles wrap to two lines: the columns are measured by their longest word.
        measure = { "Item level", "Recommended", "Override", "Recommended", "Override" },
        dividers = { 1, 3 },   -- vertical lines after these columns
        help = {
            [2] = { "Recommended price threshold", "The most to pay for one armor item of this band: its value after "
                .. "the cut, less the min profit, or less the min return when that asks for more. A % after the "
                .. "amount: the min return sets it." },
            [3] = { "Override price threshold", "The most the scan pays for one armor item of this band. Type your "
                .. "own (yellow); the X button next to it goes back to the recommended one. Grey: the scan does not "
                .. "look at armor, or at this quality." },
            [4] = { "Recommended price threshold", "The same for weapons." },
            [5] = { "Override price threshold", "The same for weapons." },
        },
        -- (The override columns are as wide as their gold, silver and copper boxes, title centered.)
        cols = { { 64, "LEFT" }, { 100, "RIGHT" }, { 184, "CENTER" }, { 100, "RIGHT" }, { 184, "CENTER" } },
        edit = { [3] = "armor", [5] = "weapon" },
        indent = 28,   -- (room for the help button before the first title)
    },
}

local f, rows, headers, status, footer, minProfit, playButton, stopButton, gearChoice, tabs =
    nil, {}, {}, nil, nil, nil, nil, nil, nil, {}
local maxPrice, cautious, bandDrop, ilvlMin, ilvlMax, levelHint, materialsOnly, scanOwned, gold, maxChecks
local qualityDrop, popOut, minReturn, ahButton, helpButton
local headerHelp = {}
local actionHeader
local REFRESH_GAP, lastRefresh, refreshQueued = 0.25, 0, false
local spinner, bigSpinner, bigSpinnerText
local buyTop, topItem, footer2

------------------------------------------------------------------ rows per view

local function dealName(d)
    return (d.link and d.link:match("%[(.-)%]")) or (ns.GetItemInfo(d.itemID)) or ("item " .. d.itemID)
end

local function dealCells(d, label)
    return { label, CLASS_NAME[d.classID or ns.ClassOf(d.itemID)] or "", tostring(d.ilvl or ""), ns.Money(d.buyout),
        ns.Money(d.value), (d.profit >= 0 and "|cff40ff40+" or "|cffff4040") .. ns.Money(d.profit) .. "|r",
        string.format("%s%d%%|r", d.profit >= 0 and "|cff40ff40+" or "|cffff4040",
            math.floor(ns.Scanner.Return(d) * 100 + 0.5)), ns.LoseText(d.lose) }
end

--- Deals grouped by item name, best profit first. A group with more than one
--- auction is one row (cheapest first) that opens to show each auction.
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
                deal = first }
        else
            local open = UI.expanded[g.name]
            local head = dealCells(first, (first.link or g.name) .. " |cffffd100x" .. #g.deals .. "|r")
            out[#out + 1] = { cells = head, link = first.link, itemID = first.itemID, group = g, open = open }
            if open then
                for _, d in ipairs(g.deals) do
                    out[#out + 1] = { cells = dealCells(d, "   " .. (d.link or g.name)), link = d.link, itemID = d.itemID,
                        deal = d, child = true }
                end
            end
        end
    end
    return out
end

local function recommendedText(x, dim)
    if not x then return "-" end
    local t = ns.Money(x.recommended)
    if x.missing then t = t .. "?" end
    if x.rule == "return" then t = t .. " %" end   -- (set by the min return, not the min profit)
    if dim then return "|cff808080" .. t .. "|r" end
    return t
end

local function limitRows()
    local out = {}
    local classes, qualities = ns.GearClasses(), ns.db.settings.qualities
    local last
    for _, r in ipairs(ns.Limits(true)) do
        if r.quality ~= last then
            last = r.quality
            out[#out + 1] = { cells = { ns.QualityText(r.quality), "", "", "", "" }, head = true }
        end
        -- Grey where the scan does not look: that gear type, or that quality.
        local off = not qualities[r.quality]
        local dimA, dimW = off or not classes[Data.CLASS_ARMOR], off or not classes[Data.CLASS_WEAPON]
        out[#out + 1] = {
            cells = { "   " .. ns.BandRange(r.quality, r.up), recommendedText(r.armor, dimA), "",
                recommendedText(r.weapon, dimW), "" },
            limits = { armor = r.armor, weapon = r.weapon },
            dim = { armor = dimA, weapon = dimW },
        }
    end
    return out
end

local SOURCES = { deals = dealRows, materials = function() return ns.Materials.Rows() end, limits = limitRows }

--- The rows of a tab of the main window (for the tests).
function UI.Rows(view) return SOURCES[view]() end

------------------------------------------------------------------ drawing

local function statusText()
    local parts = {}
    if ns.Prices.scanning then parts[#parts + 1] = string.format("Materials %d/%d", ns.Prices.done, ns.Prices.total) end
    local s = ns.Scanner
    if s.state == "browsing" then
        parts[#parts + 1] = string.format("Browsing %s (%d items)", s.passName or "", s.browsed)
    elseif s.state == "checking" then parts[#parts + 1] = string.format("Checking %d/%d", s.checked, s.toCheck)
    elseif ns.scanBothPending and not ns.Prices.scanning then parts[#parts + 1] = "Starting gear scan"
    end
    if s.paused then table.insert(parts, 1, "|cffffd100Paused|r") end
    if #parts == 0 then parts[1] = ns.Queue.open and (s.auto and "Waiting for the next scan" or "Ready")
        or "Auction house closed" end
    if ns.SalvagerForBuy() then parts[#parts + 1] = "|cff40ff40Arcane Salvager bonus included|r" end
    return table.concat(parts, "  ·  ")
end

--- The two lines under the list: what the last scan found, then the item closest to its limit.
--- (What the columns mean is behind the "?" button.)
local function footerText()
    if UI.view == "deals" then
        local sum = ns.Scanner.summary
        local text, closest = string.format("%d deals.", #ns.Scanner.deals), ""
        if sum then
            text = text .. string.format(" Last scan: %d items in %.0fs, %d under their limit.", sum.browsed,
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
                    (ns.GetItemInfo(b.itemID)) or ("item " .. b.itemID), ns.Money(b.price),
                    ns.Money(b.limit or b.value), room >= 0 and (ns.Money(room) .. " under it")
                        or (ns.Money(-room) .. " over it"))
            end
        else
            text = text .. " No gear scan yet: click Play, or Scan once: Both."
        end
        -- A limit that hides items says so, most of all when the list is empty.
        local cap = ns.db.settings.maxPrice
        if cap > 0 then
            text = text .. string.format(" |cffff8040Max price %s is on: dearer items are never listed.|r", ns.Money(cap))
        end
        return text, closest
    elseif UI.view == "limits" and ns.db.settings.cautious then
        return "Cautious pricing is on.", ""
    end
    return "", ""
end

--- Which of two auctions "Buy top" buys first: the active sort's number (Expected profit or Return), then the
--- other one, then the lower buyout, then the auction ID (so the pick is stable).
local function topBetter(a, b)
    local pa, pb, ra, rb = a.profit, b.profit, ns.Scanner.Return(a), ns.Scanner.Return(b)
    if ns.db.settings.dealSort == "return" then pa, pb, ra, rb = ra, rb, pa, pb end
    if pa ~= pb then return pa > pb end
    if ra ~= rb then return ra > rb end
    if a.buyout ~= b.buyout then return a.buyout < b.buyout end
    return (a.auctionID or 0) < (b.auctionID or 0)
end

--- The auction the "Buy top" button buys: of every auction in the Deals list not being bought already, the
--- one with the best number of the active sort (`topBetter`), whatever its row. When the gold is short for that
--- one, the best one the gold covers.
--- @return table|nil deal, string|nil why, table|nil skipped  (why: the reason there is none, for the button's
--- tooltip; skipped: the best auction, left out for the gold)
local function topDeal()
    if not ns.Queue.open then return nil, "Open the auction house first." end
    if #ns.Scanner.deals == 0 then
        if not ns.Scanner.summary then return nil, "No gear scan yet: click Play, or Scan once: Gear." end
        return nil, "The Deals list is empty: the next scan fills it."
    end
    local money = GetMoney() or 0
    local best, affordable
    for _, d in ipairs(ns.Scanner.deals) do
        if not d.pending then
            if not best or topBetter(d, best) then best = d end
            if d.buyout <= money and (not affordable or topBetter(d, affordable)) then affordable = d end
        end
    end
    if not best then return nil, "Every deal in the list is being bought already." end
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
    if UI.view == "limits" then
        return {
            "Armor and Weapons: each half has its own two columns. The rows are the bands of every quality.",
            ns.db.settings.cautious and ("Recommended price threshold: the value with every material at its lowest "
                .. "amount, after the " .. cut .. " cut, minus your min profit (cautious pricing is on).")
                or ("Recommended price threshold: the disenchant value after the " .. cut .. " cut, minus your min "
                    .. "profit, or minus your min return when that asks for more (a % after the amount)."),
            "Override price threshold: the limit in use. Type gold, silver and copper to set your own; it then shows "
                .. "in yellow. x: back to the recommended one.",
            "Grey: a gear type or a quality the scan does not look at.",
            "?: a material of that band has no price yet.",
            "Max price, when set, still applies on top of these limits.",
        }
    end
    local by = ns.db.settings.dealSort == "return" and "Return" or "Expected profit"
    return {
        "Sorted by: " .. by .. ", highest first (the title with the arrow). Click the Return or the Expected profit "
            .. "title to sort by it. Each scan checks the items in this order too.",
        "Expected value: what one disenchant of the item is worth on average over many, after the " .. cut .. " cut.",
        "Expected profit: Expected value minus the buyout. An average, not what one item gives.",
        "Return: Expected profit as a share of the buyout.",
        "Loss chance: the chance that one disenchant is worth less than its buyout.",
        "A name with x3 stands for three auctions of one item. Its numbers and its Buy are for the cheapest one.",
        "Click such a row to open it and see each auction.",
        "Buy needs one click per item. After a purchase the item is searched again.",
        string.format("Each scan checks the %d best items (Item checks, in the Levels row).", ns.db.settings.maxChecks),
        "Hover a column title for more about that column.",
    }
end

--- Column widths: the first column takes the room the window has over its default width.
--- Every column is as wide as its widest text (title or cell), and no wider. The columns with input
--- boxes keep the width of their boxes. Where the client cannot measure text, the widths given are used
--- and the first column takes the room the window has over its default width.
local function widths(view, data)
    local need = data and W.FitColumns(view.measure or view.header, #data, function(r) return data[r].cells end)
    local w = {}
    if need then
        for i, col in ipairs(view.cols) do w[i] = (view.edit and view.edit[i]) and col[1] or need[i] end
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
            local which = view.edit and view.edit[i]
            if which then
                local e = row.edits[which]
                e:ClearAllPoints()
                e:SetPoint("LEFT", row, "LEFT", x + 4, 0)
            end
        end
        if col then x = x + w[i] + 6 end
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
        t:SetWidth(math.max(10, xs[gh[2] + 1] - xs[gh[1]] - 6))
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

--- Shows one buy-limit box: yellow when set by hand, white for the recommended limit.
local function showEdit(e, x, dim)
    e.limit = x
    if not x then e:Hide() e.reset:Hide() return end
    e:Show()
    e.reset:SetShown(x.manual)
    e:Set(x.limit)
    if dim then e:SetTextColor(0.5, 0.5, 0.5)
    elseif x.manual then e:SetTextColor(1, 0.82, 0)
    else e:SetTextColor(1, 1, 1) end
end

--- Rows that fit in the list now.
local function fitRows()
    local h = (UI.list and UI.list:GetHeight() or 0) - topOf(VIEWS[UI.view] or {})
    return math.max(1, math.min(MAX_ROWS, math.floor(h / ROW_H) - 1))
end

function UI.UpdateScrollBar(total)
    if UI.bar then UI.bar:Update(UI.offset, total - ROWS) end
end

--- Play shows while not auto scanning (or paused); Pause shows while auto scanning.
function UI.UpdatePlay()
    if not playButton then return end
    local s = ns.Scanner
    if s.auto and not s.paused then
        playButton:SetIcon("Interface\\TimeManager\\PauseButton", 16, 16)
    else
        playButton:SetIcon("Interface\\ChatFrame\\ChatFrameExpandArrow", 14, 14)
    end
    stopButton:SetEnabled(s.auto or ns.Busy())
    stopButton:UpdateGlyph()
    -- (The auction house button needs the auction house open; its tooltip says why it is off.)
    if ahButton then
        ahButton:SetEnabled(ns.Queue.open)
        ahButton.reason = not ns.Queue.open and "Open the auction house first." or nil
    end
end

--- The "Buy top" button's tooltip: what the click buys now, or why it is off.
local function buyTopTooltip(self)
    local d, why, skipped = topDeal()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText("Buy top", 1, 1, 1)
    if d then
        local byReturn = ns.db.settings.dealSort == "return"
        GameTooltip:AddLine("Buys the auction with the highest " .. (byReturn and "Return" or "Expected profit")
            .. " in the Deals list (the sort), from any row. Each click buys the next best one.", 1, 0.82, 0, true)
        if skipped then
            GameTooltip:AddLine(string.format("The best one, %s (%s), is skipped: not enough gold.", dealName(skipped),
                ns.Money(skipped.buyout)), 1, 0.3, 0.3, true)
        end
        GameTooltip:AddLine(d.link or dealName(d), 1, 1, 1)
        GameTooltip:AddDoubleLine("Buyout", ns.Money(d.buyout), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Expected profit", (d.profit >= 0 and "+" or "") .. ns.Money(d.profit), 1, 0.82, 0,
            d.profit >= 0 and 0.25 or 1, d.profit >= 0 and 1 or 0.25, 0.25)
        GameTooltip:AddDoubleLine("Return", string.format("%+d%%", math.floor(ns.Scanner.Return(d) * 100 + 0.5)),
            1, 0.82, 0, d.profit >= 0 and 0.25 or 1, d.profit >= 0 and 1 or 0.25, 0.25)
    else
        GameTooltip:AddLine(why, 1, 0.3, 0.3, true)
    end
    GameTooltip:Show()
end

--- The "Buy top" button: on while there is a deal to buy; its tooltip follows the list while it shows.
local function updateBuyTop()
    local d = topDeal()
    buyTop:SetEnabled(d ~= nil)
    -- Above the button: the item the next click buys, as wide as its name, at most half the room left of the
    -- button (cut there, one line). Nothing when the button is off: the reason is in its tooltip.
    topItem.link = d and (d.link or ("item:" .. d.itemID)) or nil
    topItem.text:SetText(d and (d.link or dealName(d)) or "")
    local icon = d and W.IconOf(d.itemID)
    if icon then topItem.icon:SetTexture(icon) topItem.icon:Show() else topItem.icon:Hide() end
    local tw = tonumber((topItem.text:GetStringWidth())) or 0
    topItem.text:SetWidth(math.max(1, math.min(tw + 2, ((f:GetWidth() or 800) - 150) / 2)))
    topItem:SetShown(d ~= nil)
    if buyTop.hover then buyTopTooltip(buyTop) end
end

function UI.Refresh()
    if not f or not f:IsShown() then return end
    -- The materials list is in its own window: this window does not show it too.
    local out = ns.Materials.IsPoppedOut()
    if out and UI.view == "materials" then UI.view, UI.offset = "deals", 0 end
    tabs.materials:SetAlpha(out and 0.5 or 1)
    if out then popOut:LockHighlight() else popOut:UnlockHighlight() end
    gold:SetText(ns.Money(GetMoney() or 0))
    materialsOnly:SetShown(UI.view == "materials")
    scanOwned:SetShown(UI.view == "materials")
    materialsOnly:SetChecked(ns.db.settings.materialsDataOnly)
    local view = VIEWS[UI.view]
    ROWS = fitRows()
    local data = SOURCES[UI.view]()
    local w = layout(view, data)
    UI.offset = math.max(0, math.min(UI.offset, #data - ROWS))
    UI.UpdateScrollBar(#data)
    for i, h in ipairs(headers) do
        local col = view.cols[i]
        if col then
            -- The title the list is ordered by has a mark.
            local sortKey = view.sortable and view.sortable[i]
            local title = view.header[i] or ""
            if sortKey and sortKey == ns.db.settings.dealSort then
                title = title .. " |TInterface\\Buttons\\Arrow-Down-Up:10|t"   -- the order of the list, highest first
            end
            h:SetWidth(w[i]) h:SetJustifyH(col[2]) h:SetText(title) h:Show()
        else
            h:Hide()
        end
        local help = view.help == "materials" and ns.Materials.HELP or view.help
        headerHelp[i].help = col and help and help[i] or nil
        headerHelp[i].sortKey = col and view.sortable and view.sortable[i] or nil
        headerHelp[i]:SetShown(headerHelp[i].help ~= nil)
    end
    actionHeader:SetText(view.actionTitle or "")
    for r = ROWS + 1, MAX_ROWS do rows[r]:Hide() end
    for r = 1, ROWS do
        local row, item = rows[r], data[r + UI.offset]
        row.item = item
        for i, fs in ipairs(row.cells) do
            local col = view.cols[i]
            if col and item then
                fs:SetWidth(w[i]) fs:SetJustifyH(col[2]) fs:SetText(item.cells[i] or "") fs:Show()
            else
                fs:Hide()
            end
        end
        for which, e in pairs(row.edits) do
            if item and item.limits then showEdit(e, item.limits[which], item.dim[which]) else e:Hide() end
        end
        local icon = item and view.icon and W.IconOf(item.itemID)
        row.icon:ClearAllPoints()
        row.icon:SetPoint("LEFT", row, "LEFT", (view.indent and 22 or 4) + (item and item.child and 10 or 0), 0)
        if icon then row.icon:SetTexture(icon) row.icon:Show() else row.icon:Hide() end
        if item and item.group then
            row.toggle:SetTexture(item.open and "Interface\\Buttons\\UI-MinusButton-Up" or "Interface\\Buttons\\UI-PlusButton-Up")
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
        elseif item and (item.deal or item.group) then
            local pending = item.deal and item.deal.pending
            if item.group then pending = ns.Scanner.Cheapest(item.group.deals) == nil end
            row.buy:Show()
            row.buy:SetEnabled(not pending)
            row.buy:SetText(pending and "..." or "Buy")
        else
            row.buy:Hide()
        end
        row:SetShown(item ~= nil)
    end
    for name, b in pairs(tabs) do
        if name == UI.view then b:LockHighlight() else b:UnlockHighlight() end
    end
    status:SetText(statusText())
    -- As wide as its text, at most half the room left of "Buy top": the footer keeps the rest.
    local sw = tonumber((status:GetStringWidth())) or 0
    status:SetWidth(math.max(1, math.min(sw + 2, ((f:GetWidth() or 800) - 150) / 2)))
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
end

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
    GameTooltip:Show()
end

local function build()
    f = CreateFrame("Frame", "SalvagerFrame", UIParent, "BasicFrameTemplateWithInset")
    local saved = ns.db.window
    f:SetSize(math.max(MIN_W, saved.w or WIDTH), math.max(MIN_H, saved.h or HEIGHT))
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function()
        f:StopMovingOrSizing()
        anchorTopLeft()
        savePosition()
    end)
    local pos = ns.db.window
    if pos and pos.point then
        f:SetPoint(pos.point, UIParent, pos.rel or pos.point, pos.x or 0, pos.y or 0)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 200, 0)
    end
    local title = f.TitleText
    if type(title) ~= "table" then
        title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", f, "TOP", 0, -5)
    end
    title:SetText("Salvager")
    W.TitleVersion(f, title, MIN_W)
    tinsert(UISpecialFrames, "SalvagerFrame")

    ---------------------------------------------------------------- top bar: run, status, windows
    playButton = W.IconButton(f, 24, function()
        local s = ns.Scanner
        if s.auto and not s.paused then s.Pause() else s.Play() end
    end)
    playButton:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -29)
    playButton:SetScript("OnEnter", function(self)
        local s = ns.Scanner
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if s.auto and not s.paused then
            GameTooltip:SetText("Pause", 1, 1, 1)
            GameTooltip:AddLine("Holds every search where it is. Play continues from there.", 1, 0.82, 0, true)
        else
            GameTooltip:SetText(s.paused and "Resume" or "Play", 1, 1, 1)
            local every = ns.db.settings.priceRescan
            GameTooltip:AddLine("Scans the gear now and again every " .. ns.db.settings.autoInterval
                .. " seconds while the auction house is open, so new cheap listings show up by themselves. "
                .. (every > 0 and ("Material prices are scanned again when they are older than " .. every .. " minutes. ")
                    or "Material prices are not scanned again (see the options). ")
                .. "You still click Buy yourself.", 1, 0.82, 0, true)
        end
        GameTooltip:Show()
    end)
    playButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    stopButton = W.IconButton(f, 24, function() ns.Scanner.Stop() end)
    stopButton:SetPoint("LEFT", playButton, "RIGHT", 4, 0)
    stopButton:SetStopGlyph()
    W.Tooltip(stopButton, "Stop", "Ends auto scanning and drops the scan that is running. Deals found so far stay in the list.")
    spinner = W.Spinner(f, 22)   -- (placed at the bottom, with the status, under the list)

    local options = W.IconButton(f, 22, function() ns.Options.Open() end)
    options:SetIcon("Interface\\Buttons\\UI-OptionsButton", 16, 16)
    options:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -30)
    W.Tooltip(options, "Options", "Opens the addon's options.")
    local log = W.Button(f, "Log", 80, function() ns.LogWindow.Toggle() end,
        "Opens the log in its own window: what the addon did, and any error. For debugging.")
    log:SetPoint("RIGHT", options, "LEFT", -6, 0)
    local ledger = W.Button(f, "Ledger", 80, function() ns.LedgerWindow.Toggle() end,
        "Opens the ledger in its own window: what you bought, what each item was disenchanted into, "
        .. "your sales and their profit.")
    ledger:SetPoint("RIGHT", log, "LEFT", -6, 0)
    local market = W.Button(f, "Market", 80, function() ns.Market.Toggle() end,
        "Opens the market charts in their own window: the price of each material over time, from your scans.")
    market:SetPoint("RIGHT", ledger, "LEFT", -6, 0)
    ahButton = W.Button(f, "Auction house", 104, function() UI.ToAuctionHouse() end,
        "Closes the Salvager windows: only the auction house window stays. Scans keep running. The Salvager button "
        .. "above the auction house window brings them back.")
    local reports = W.Button(f, "Reports", 80, function() ns.Reports.Toggle() end,
        "Opens the reports in their own window: your gold, and the profit by quality, band, material and item.")
    reports:SetPoint("RIGHT", market, "LEFT", -6, 0)
    ahButton:SetPoint("RIGHT", reports, "LEFT", -6, 0)
    ahButton:SetMotionScriptsWhileDisabled(true)
    ahButton:HookScript("OnEnter", function(self)
        if self.reason then GameTooltip:AddLine(self.reason, 1, 0.3, 0.3, true) GameTooltip:Show() end
    end)
    -- At the bottom right, left of the resize grip: "Buy top" buys the best auction of the list (the click is the
    -- hardware event the purchase needs). Left of it, what the addon is doing now (scanning, searching), the
    -- spinner before it; the footer takes the room on the left.
    buyTop = W.Button(f, "Buy top", 80, function()
        local d = topDeal()
        if d then ns.Scanner.Buy(d) end
    end)
    buyTop:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 9)
    buyTop:SetMotionScriptsWhileDisabled(true)
    buyTop:SetScript("OnEnter", function(self)
        self.hover = true
        buyTopTooltip(self)
        -- The mouse on a Buy button holds the scan, so the auction house is free when the click comes.
        if self:IsEnabled() then ns.Scanner.Aim(true) end
    end)
    buyTop:SetScript("OnLeave", function(self)
        self.hover = false
        ns.Scanner.Aim(false)
        GameTooltip:Hide()
    end)
    UI.buyTop = buyTop
    -- Above "Buy top", right-aligned to it: the icon and the name of the item the next click buys. It sits
    -- between the button's top (31 px above the window's bottom) and the list's bottom (54 px): 37 to 51 px,
    -- over the footer's first line (26 to 36 px), so it touches nothing whatever its width.
    topItem = CreateFrame("Button", nil, f)
    topItem:SetHeight(14)
    topItem:SetPoint("BOTTOMRIGHT", buyTop, "TOPRIGHT", 0, 6)
    topItem.text = topItem:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    topItem.text:SetPoint("RIGHT", topItem, "RIGHT", 0, 0)
    topItem.text:SetJustifyH("RIGHT")
    topItem.text:SetWordWrap(false)
    topItem.icon = topItem:CreateTexture(nil, "ARTWORK")
    topItem.icon:SetSize(14, 14)
    topItem.icon:SetPoint("RIGHT", topItem.text, "LEFT", -3, 0)
    topItem:SetPoint("LEFT", topItem.icon, "LEFT", 0, 0)
    topItem:SetScript("OnEnter", function(self)
        if not self.link then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetHyperlink(self.link)
        GameTooltip:Show()
    end)
    topItem:SetScript("OnLeave", function() GameTooltip:Hide() end)
    UI.topItem = topItem
    status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("RIGHT", buyTop, "LEFT", -10, 0)
    status:SetJustifyH("RIGHT")
    status:SetWordWrap(false)
    spinner:SetPoint("RIGHT", status, "LEFT", -6, 0)

    ---------------------------------------------------------------- settings box: what to scan, what to pay
    local box = W.Panel(f, 1, 1, 1, 0.04)
    box:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -60)
    box:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -60)
    box:SetHeight(92)
    local CAPTION_W = 46
    local function caption(text, y)
        local l = W.Label(box, text, "GameFontNormal")
        l:SetPoint("TOPLEFT", box, "TOPLEFT", 10, y)
        l:SetWidth(CAPTION_W)
        l:SetJustifyH("LEFT")
        return l
    end

    -- Row "Scan": which gear, which quality; on the right the one-off scans.
    local scanCaption = caption("Scan", -10)
    local gearLabel = W.Label(box, "Gear", "GameFontHighlightSmall")
    gearLabel:SetPoint("LEFT", scanCaption, "RIGHT", 6, 0)
    gearChoice = W.CheckDropdown(box, 140, { { "weapons", "Weapons" }, { "armor", "Armor" } },
        ns.GearTypeOn, ns.SetGearType,
        "Which gear the scan looks at. Armor gives mostly dust, weapons mostly essence. The Limits tab shows the buy limits.",
        "Gear")
    gearChoice:SetPoint("LEFT", gearLabel, "RIGHT", 6, 0)
    local qLabel = W.Label(box, "Quality", "GameFontHighlightSmall")
    qLabel:SetPoint("LEFT", gearChoice, "RIGHT", 14, 0)
    qualityDrop = W.CheckDropdown(box, 160, {
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

    local scanBoth = W.Button(box, "Both", 58, function() ns.ScanBoth(true) end,
        "Once: scans the material prices first, then the gear.")
    scanBoth:SetPoint("TOPRIGHT", box, "TOPRIGHT", -8, -6)
    local scanGear = W.Button(box, "Gear", 58, function() ns.Scanner.Scan(true) end,
        "Once: lists the gear on the auction house and checks each item that is below its buy limit.")
    scanGear:SetPoint("RIGHT", scanBoth, "LEFT", -4, 0)
    local scanMats = W.Button(box, "Materials", 84, function() ns.Prices.Scan() end,
        "Once: searches each disenchanting material (about 20 seconds) and stores its price.")
    scanMats:SetPoint("RIGHT", scanGear, "LEFT", -4, 0)
    local onceLabel = W.Label(box, "Scan once", "GameFontHighlightSmall")
    onceLabel:SetPoint("RIGHT", scanMats, "LEFT", -8, 0)
    W.HelpArea(box, onceLabel, "Scan once", "A single scan by hand. Play does all of this by itself, again and again.")

    -- Row "Buy": the least profit, the most to pay.
    local buyCaption = caption("Buy", -38)
    local mpLabel = W.Label(box, "Min profit", "GameFontHighlightSmall")
    mpLabel:SetPoint("LEFT", buyCaption, "RIGHT", 6, 0)
    W.HelpArea(box, mpLabel, "Min profit", "The least profit an item must make on average: an item is a deal when it "
        .. "costs no more than its disenchant value minus this.")
    minProfit = W.Money(box, function(copper)
        ns.db.settings.minProfit = copper
        ns.Log("min profit set to %s", ns.Money(copper))
        ns.Fire("SALVAGER_SETTINGS")
    end)
    minProfit:SetPoint("LEFT", mpLabel, "RIGHT", 4, 0)
    local mrLabel = W.Label(box, "Min return", "GameFontHighlightSmall")
    mrLabel:SetPoint("LEFT", minProfit:Right(), "RIGHT", 16, 0)
    W.HelpArea(box, mrLabel, "Min return", "The least return an item must make as well, in percent of its price: "
        .. "15 = each 1g you pay must bring 1g 15s back on average. Both rules hold: a cheap item needs the return, "
        .. "an expensive one the profit. 0 = off.")
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
    W.HelpArea(box, capLabel, "Max price", "The most you pay for one item, whatever it is worth. An item above this "
        .. "is never listed. All zeroes = no limit.")
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
    cautious:SetPoint("TOPRIGHT", box, "TOPRIGHT", -78, -34)

    -- Row "Levels": which item levels the scan looks at, by band or by a range of your own.
    local levelCaption = caption("Levels", -66)
    local bandLabel = W.Label(box, "Bands", "GameFontHighlightSmall")
    bandLabel:SetPoint("LEFT", levelCaption, "RIGHT", 6, 0)
    local bandOptions = {}
    for _, band in ipairs(ns.LevelBands()) do bandOptions[#bandOptions + 1] = { band.up, band.label } end
    bandDrop = W.CheckDropdown(box, 200, bandOptions,
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
            .. "materials. The Limits tab and the Ledger's Odds view list them.", "Bands",
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
        .. "items whose item level is inside it. 0 = no limit on that side. An item must pass both the bands and the range.")
    ilvlMin = levelBox("ilvlMin")
    ilvlMin:SetPoint("LEFT", rangeLabel, "RIGHT", 10, 0)
    local toLabel = W.Label(box, "to", "GameFontHighlightSmall")
    toLabel:SetPoint("LEFT", ilvlMin, "RIGHT", 8, 0)
    ilvlMax = levelBox("ilvlMax")
    ilvlMax:SetPoint("LEFT", toLabel, "RIGHT", 10, 0)
    -- At the right end of the row: how many items one scan checks.
    maxChecks = W.Edit(box, 34, true)
    maxChecks:SetMaxLetters(3)
    maxChecks:SetJustifyH("RIGHT")
    maxChecks:SetTextInsets(2, 4, 0, 0)
    maxChecks:SetPoint("TOPRIGHT", box, "TOPRIGHT", -10, -63)
    maxChecks:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    maxChecks:SetScript("OnEditFocusLost", function(self)
        local n = math.max(1, math.floor(tonumber(self:GetText()) or 0))
        if ns.db.settings.maxChecks ~= n then
            ns.db.settings.maxChecks = n
            ns.Log("maxChecks = %d", n)
        end
        ns.Fire("SALVAGER_SETTINGS")
    end)
    local checksLabel = W.Label(box, "Item checks", "GameFontHighlightSmall")
    checksLabel:SetPoint("RIGHT", maxChecks, "LEFT", -8, 0)
    W.HelpArea(box, checksLabel, "Item checks per scan", "How many items one scan checks, the best candidates first. "
        .. "Each check is one auction house search (about 0.7 s), and the Deals list holds at most this many items.")
    levelHint = W.Label(box, "", "GameFontDisableSmall")
    levelHint:SetPoint("LEFT", ilvlMax, "RIGHT", 8, 0)
    levelHint:SetPoint("RIGHT", checksLabel, "LEFT", -8, 0)
    levelHint:SetJustifyH("LEFT")
    levelHint:SetWordWrap(false)

    ---------------------------------------------------------------- tabs, above the list they switch
    local x = 12
    for _, t in ipairs({ { "deals", "Deals" }, { "materials", "Materials" }, { "limits", "Limits" } }) do
        local b = W.Button(f, t[2], 96, function()
            -- The Materials tab, while its list is in its own window: put it back here.
            if t[1] == "materials" then ns.Materials.PutBack() end
            UI.view = t[1]
            ns.db.window.view = t[1]
            UI.offset = 0
            UI.Refresh()
        end)
        tabs[t[1]] = b
        if t[1] == "limits" then
            -- Limits is a setting more than a list: it sits at the right end of the row.
            b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -159)
        else
            b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -159)
            x = x + 98
        end
        if t[1] == "materials" then
            -- Right next to the Materials tab: its list in a window of its own, and back.
            popOut = W.IconButton(f, 22, function()
                if ns.Materials.IsPoppedOut() then ns.Materials.PutBack() else ns.Materials.PopOut() end
            end)
            popOut:SetPoint("LEFT", b, "RIGHT", 0, 0)
            popOut:SetPopOutGlyph()
            popOut:SetScript("OnEnter", function(self)
                local out = ns.Materials.IsPoppedOut()
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(out and "Put the materials list back" or "Pop out the materials list", 1, 1, 1)
                GameTooltip:AddLine(out and "Closes its window and shows the list in the Materials tab again."
                    or "Moves the materials list to a window of its own, so you can watch it next to the deals. "
                        .. "Scans keep running. Click again, or close that window, to put it back.", 1, 0.82, 0, true)
                GameTooltip:Show()
            end)
            popOut:SetScript("OnLeave", function() GameTooltip:Hide() end)
            x = x + 26
        end
    end
    W.Tooltip(tabs.deals, "Deals", "The auctions that cost no more than their buy limit, best profit first.")
    W.Tooltip(tabs.materials, "Materials", "Prices, stock and break-even of the disenchanting materials. "
        .. "While the list is in its own window (Pop out), a click here puts it back.")
    W.Tooltip(tabs.limits, "Limits", "The most the addon lets you pay per item level band, for armor and for weapons. "
        .. "You can set your own.")

    -- At the right end of the tab row, before the Limits tab: the gold you have now.
    gold = W.Label(f, "", "GameFontHighlight")
    gold:SetPoint("RIGHT", tabs.limits, "LEFT", -12, 0)
    gold:SetJustifyH("RIGHT")
    -- In the Materials tab, after the tabs.
    scanOwned = ns.Materials.ScanOwnedButton(f)
    scanOwned:SetPoint("TOPLEFT", f, "TOPLEFT", x + 10, -159)
    scanOwned:Hide()
    materialsOnly = ns.Materials.DataOnlyCheck(f)
    materialsOnly:SetPoint("LEFT", scanOwned, "RIGHT", 8, 0)
    materialsOnly:Hide()

    ---------------------------------------------------------------- the list, in its own sunken panel
    local inset = W.Panel(f, 0, 0, 0, 0.5)
    inset:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -184)
    -- (Its bottom leaves room for the two footer lines and the "Buy top" button.)
    inset:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 54)
    titleBand = inset:CreateTexture(nil, "BACKGROUND", nil, 1)
    titleBand:SetPoint("TOPLEFT", inset, "TOPLEFT", 1, -1)
    titleBand:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -1, -1)
    titleBand:SetHeight(ROW_H)
    titleBand:SetColorTexture(1, 1, 1, 0.07)

    local list = CreateFrame("Frame", nil, inset)
    list:SetPoint("TOPLEFT", inset, "TOPLEFT", 2, -1)
    list:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -20, 2)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        UI.offset = math.max(0, UI.offset - delta * 3)
        UI.Refresh()
    end)
    UI.list = list
    if list.SetClipsChildren then list:SetClipsChildren(true) end
    -- What the list's columns and marks mean: the first thing on the row of column titles.
    helpButton = W.HelpButton(list, function()
        return UI.view == "materials" and "Materials" or UI.view == "limits" and "Limits" or "Deals"
    end, helpLines, { left = true })
    helpButton:SetSize(20, 20)

    -- Scroll bar on the right, inside the panel.
    local bar = W.ScrollBar(inset, function(value)
        if value ~= UI.offset then
            UI.offset = value
            UI.Refresh()
        end
    end)
    bar:SetPoint("TOPRIGHT", inset, "TOPRIGHT", -3, -ROW_H - 3)
    bar:SetPoint("BOTTOMRIGHT", inset, "BOTTOMRIGHT", -3, 3)
    bar:EnableMouseWheel(true)
    bar:SetScript("OnMouseWheel", list:GetScript("OnMouseWheel"))
    UI.bar = bar
    -- The title over the rows' buttons (Buy, Post).
    actionHeader = list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    actionHeader:SetHeight(ROW_H)
    actionHeader:SetWidth(64)
    actionHeader:SetJustifyH("CENTER")
    actionHeader:SetPoint("TOPRIGHT", list, "TOPRIGHT", -4, 0)
    for i = 1, MAX_COLS do
        local h = list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetHeight(ROW_H)
        h:SetWordWrap(true)   -- (a long title takes two lines)
        headers[i] = h
        -- An invisible area over the title, for its help text.
        local area = CreateFrame("Frame", nil, list)
        area:SetAllPoints(h)
        area:EnableMouse(true)
        area:SetScript("OnEnter", function(self)
            if not self.help then return end
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(self.help[1], 1, 1, 1)
            GameTooltip:AddLine(self.help[2], 1, 0.82, 0, true)
            GameTooltip:Show()
        end)
        area:SetScript("OnLeave", function() GameTooltip:Hide() end)
        -- A title that orders the list: a click orders it by that column.
        area:SetScript("OnMouseUp", function(self)
            if not self.sortKey or ns.db.settings.dealSort == self.sortKey then return end
            ns.db.settings.dealSort = self.sortKey
            ns.Log("deals listed by %s", self.sortKey)
            ns.Scanner.Sort()
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
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.cells = {}
        for i = 1, MAX_COLS do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetHeight(ROW_H)
            fs:SetWordWrap(false)
            row.cells[i] = fs
        end
        row.edits = {}
        for _, which in ipairs({ "armor", "weapon" }) do
            local e
            e = W.Money(row, function(copper)
                local lim = e.limit
                if not lim or copper == lim.limit then return end
                if copper == lim.recommended and lim.manual then
                    ns.SetLimitOverride(lim.quality, lim.classID, lim.band, nil)
                elseif copper ~= lim.recommended then
                    ns.SetLimitOverride(lim.quality, lim.classID, lim.band, copper)
                end
            end)
            e.reset = W.Button(e:Right(), "x", 20, function()
                local lim = e.limit
                if lim then ns.SetLimitOverride(lim.quality, lim.classID, lim.band, nil) end
            end, "Use the recommended price again.")
            e.reset:SetPoint("LEFT", e:Right(), "RIGHT", -6, 0)
            e.reset:Hide()
            e:Hide()
            row.edits[which] = e
        end
        row.buy = W.Button(row, "Buy", 64, function()
            local item = row.item
            if not item then return end
            if item.post then ns.Post.Open(item.itemID) return end
            local deal = item.deal or (item.group and ns.Scanner.Cheapest(item.group.deals))
            if deal then ns.Scanner.Buy(deal) end
        end)
        -- The mouse on a Buy button holds the scan, so the auction house is free when the click comes.
        row.buy:HookScript("OnEnter", function() if row.item and not row.item.post then ns.Scanner.Aim(true) end end)
        row.buy:HookScript("OnLeave", function() ns.Scanner.Aim(false) end)
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
            GameTooltip:AddLine(ns.Materials.WarnText(sug), 1, 0.82, 0, true)
            GameTooltip:Show()
        end)
        row.warn:SetScript("OnLeave", function() GameTooltip:Hide() end)
        row.warn:Hide()
        row.toggle = row:CreateTexture(nil, "ARTWORK")
        row.toggle:SetSize(14, 14)
        row.toggle:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.toggle:Hide()
        row:SetScript("OnClick", function(self)
            local item = self.item
            if item and item.group then
                UI.expanded[item.group.name] = not UI.expanded[item.group.name] or nil
                UI.Refresh()
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

    -- Two lines under the list, each one line cut at the spinner: what the last scan found, then the item
    -- closest to its limit. (Left and right ends on one height: the spinner's middle is the button's, 20 px
    -- above the window's bottom; line 2 sits 3 px under it, line 1 14 px above line 2.)
    footer2 = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer2:SetPoint("LEFT", f, "BOTTOMLEFT", 14, 17)
    footer2:SetPoint("RIGHT", spinner, "LEFT", -12, -3)
    footer2:SetJustifyH("LEFT")
    footer2:SetWordWrap(false)
    footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("LEFT", f, "BOTTOMLEFT", 14, 31)
    footer:SetPoint("RIGHT", spinner, "LEFT", -12, 11)
    footer:SetJustifyH("LEFT")
    footer:SetWordWrap(false)
    UI.footerLines = { footer, footer2 }

    -- Resize from the bottom right corner.
    f:SetResizable(true)
    local maxW, maxH = UIParent:GetWidth(), UIParent:GetHeight()
    if f.SetResizeBounds then
        f:SetResizeBounds(MIN_W, MIN_H, maxW, maxH)
    elseif f.SetMinResize then
        f:SetMinResize(MIN_W, MIN_H)
        if f.SetMaxResize then f:SetMaxResize(maxW, maxH) end
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
        ns.db.window.w, ns.db.window.h = math.floor(f:GetWidth()), math.floor(f:GetHeight())
        savePosition()
        UI.Refresh()
    end)
    f:SetScript("OnSizeChanged", function() UI.Refresh() end)

    if VIEWS[ns.db.window.view] then UI.view = ns.db.window.view end
    f:SetScript("OnShow", function()
        UI.Refresh()
        UI.RestoreWindows()
    end)
    -- The main window closes: every Salvager window goes with it (what was open is still remembered, and
    -- comes back with the main window).
    f:SetScript("OnHide", function() UI.HideOthers() end)
    f:Hide()
end

-- Every window of the addon besides the main one.
local OTHERS = { "SalvagerLedgerFrame", "SalvagerLogFrame", "SalvagerMaterialsFrame", "SalvagerMarketFrame",
    "SalvagerReportsFrame", "SalvagerStandFrame",
    "SalvagerBreakdownFrame", "SalvagerOddsFrame", "SalvagerPostFrame", "SalvagerOptionsFrame" }

--- Hides the other windows, without changing what is remembered as open.
function UI.HideOthers()
    for _, name in ipairs(OTHERS) do
        local w = _G[name]
        if w and w:IsShown() then w:Hide() end
    end
end

--- The windows that were open last time, again (with the main window, when the setting is on).
function UI.RestoreWindows()
    if not ns.db.settings.restoreWindows then return end
    ns.LedgerWindow.Restore()
    ns.LogWindow.Restore()
    ns.Materials.Restore()
    ns.Market.Restore()
    ns.Reports.Restore()
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

function UI.Toggle()
    if not f then build() end
    f:SetShown(not f:IsShown())
end

function UI.Show()
    if not f then build() end
    f:Show()
end

for _, e in ipairs({ "SALVAGER_PRICES", "SALVAGER_PRICES_DONE", "SALVAGER_SCAN", "SALVAGER_DEALS", "SALVAGER_LISTINGS",
    "SALVAGER_LEDGER", "SALVAGER_SETTINGS" }) do
    ns.On(e, function() UI.RequestRefresh() end)
end

ns.On("AUCTION_HOUSE_SHOW", function()
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

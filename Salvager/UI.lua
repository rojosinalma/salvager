-- Salvager: the main window (Deals, Materials, Limits) and the Log panel attached to its right side.
local _, ns = ...

local Ledger, Data, W = ns.Ledger, ns.Data, ns.Widgets

local UI = { view = "deals", offset = 0, expanded = {} }
ns.UI = UI

local MAX_ROWS, ROW_H = 40, 24
local MAX_COLS = 8
local WIDTH, HEIGHT = 800, 560
local MIN_W, MIN_H = 800, 380
local ROWS = 15          -- rows that fit now (set from the list height)
local QUALITY_COLOR = { [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee" }
local CLASS_NAME = { [2] = "Weapon", [4] = "Armor" }

local VIEWS = {
    deals = {
        icon = true,
        indent = 46,
        header = { "Item", "Type", "iLvl", "Buyout", "Value", "Profit" },
        cols = { { 205, "LEFT" }, { 50, "CENTER" }, { 34, "CENTER" }, { 88, "RIGHT" }, { 88, "RIGHT" }, { 88, "RIGHT" } },
    },
    materials = {
        icon = true,
        header = { "Material", "Price", "Units", "Age", "Bags", "Stock", "Avg cost", "Break-even" },
        cols = { { 160, "LEFT" }, { 80, "RIGHT" }, { 45, "CENTER" }, { 36, "CENTER" }, { 40, "CENTER" }, { 40, "CENTER" },
            { 85, "RIGHT" }, { 85, "RIGHT" } },
    },
    limits = {
        icon = false,
        header = { "Item level", "Armor recommended", "Armor buy below", "Weapon recommended", "Weapon buy below" },
        cols = { { 64, "LEFT" }, { 100, "RIGHT" }, { 210, "RIGHT" }, { 100, "RIGHT" }, { 210, "RIGHT" } },
        edit = { [3] = "armor", [5] = "weapon" },
    },
}

local f, rows, headers, status, footer, minProfit, playButton, stopButton, gearChoice, tabs =
    nil, {}, {}, nil, nil, nil, nil, nil, nil, {}
local qualityDrop
local REFRESH_GAP, lastRefresh, refreshQueued = 0.25, 0, false
local spinner, bigSpinner, bigSpinnerText

local function ago(seconds)
    if not seconds then return "-" end
    if seconds < 60 then return "now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
    return math.floor(seconds / 3600) .. "h"
end

------------------------------------------------------------------ rows per view

local function dealName(d)
    return (d.link and d.link:match("%[(.-)%]")) or (ns.GetItemInfo(d.itemID)) or ("item " .. d.itemID)
end

local function dealCells(d, label)
    return { label, CLASS_NAME[d.classID or ns.ClassOf(d.itemID)] or "", tostring(d.ilvl or ""), ns.Money(d.buyout),
        ns.Money(d.value), "|cff40ff40" .. ns.Money(d.profit) .. "|r" }
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
        g.best = 0
        for _, d in ipairs(g.deals) do if d.profit > g.best then g.best = d.profit end end
    end
    table.sort(order, function(a, b) return a.best > b.best end)
    local out = {}
    for _, g in ipairs(order) do
        local first = g.deals[1]
        if #g.deals == 1 then
            out[#out + 1] = { cells = dealCells(first, first.link or g.name), link = first.link, itemID = first.itemID,
                deal = first }
        else
            local open = UI.expanded[g.name]
            local head = dealCells(first, (first.link or g.name) .. " |cffffd100x" .. #g.deals .. "|r")
            head[4] = "from " .. head[4]
            head[6] = "|cff40ff40up to " .. ns.Money(g.best) .. "|r"
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

local function materialRows()
    local out = {}
    local maxAge = ns.db.settings.priceMaxAge
    for _, m in ipairs(Data.MATERIALS) do
        local e = ns.db.prices[m.id]
        local price = ns.PriceOf(m.id)
        local age = e and e.t and (time() - e.t)
        local s = ns.db.ledger.stock[m.id]
        local avg = Ledger.AvgCost(ns.db.ledger, m.id)
        local unknown = s and (s.unknown or 0) or 0
        local bags = ns.Post.BagCount(m.id)
        local suggest = bags > 0 and ns.Post.Suggest(m.id) or nil
        local be = Ledger.BreakEven(ns.db.ledger, m.id, ns.Cut())
        local priceText = price and ns.Money(price) or "-"
        if e and not e.p and e.last then
            priceText = "*" .. priceText
        elseif e and not e.p and price then
            priceText = "~" .. priceText
        end
        if price and be and price < be then priceText = "|cffff4040" .. priceText .. "|r" end
        local ageText = ago(age)
        if age and age > maxAge then ageText = "|cffff8040" .. ageText .. "|r" end
        out[#out + 1] = {
            cells = { ns.MaterialName(m.id), priceText,
                e and e.units and e.units > 0 and (e.units .. "/" .. e.listings) or "-",
                ageText, bags > 0 and tostring(bags) or "-", s and tostring(s.qty) or "-",
                avg and (ns.Money(avg) .. (unknown > 0 and " |cff808080+" .. unknown .. "?|r" or ""))
                    or (unknown > 0 and "|cff808080unknown|r" or "-"),
                be and ns.Money(be) or "-" },
            itemID = m.id, post = bags > 0, suggest = suggest,
        }
    end
    return out
end

local function recommendedText(x, dim)
    if not x then return "-" end
    local t = ns.Money(x.recommended)
    if x.missing then t = t .. "?" end
    if dim then return "|cff808080" .. t .. "|r" end
    return t
end

local function limitRows()
    local out = {}
    local classes = ns.GearClasses()
    for _, r in ipairs(ns.Limits()) do
        local up = r.up >= 999 and "+" or ("-" .. r.up)
        out[#out + 1] = {
            cells = { (QUALITY_COLOR[r.quality] or "") .. r.lo .. up .. "|r",
                recommendedText(r.armor, not classes[Data.CLASS_ARMOR]), "",
                recommendedText(r.weapon, not classes[Data.CLASS_WEAPON]), "" },
            limits = { armor = r.armor, weapon = r.weapon },
            dim = { armor = not classes[Data.CLASS_ARMOR], weapon = not classes[Data.CLASS_WEAPON] },
        }
    end
    return out
end

local SOURCES = { deals = dealRows, materials = materialRows, limits = limitRows }

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

local function footerText()
    if UI.view == "deals" then
        local sum = ns.Scanner.summary
        local text = string.format("%d deals.", #ns.Scanner.deals)
        if sum then
            text = text .. string.format(" Last scan: %d items in %.0fs, %d under their limit.", sum.browsed,
                sum.seconds or 0, sum.candidates)
            if (sum.learning or 0) > 0 then
                text = text .. string.format(" %d skipped while their item level loads (next scan has them).", sum.learning)
            end
            if sum.best then
                text = text .. string.format(" Closest: %s at %s, value %s (%s).",
                    (ns.GetItemInfo(sum.best.itemID)) or ("item " .. sum.best.itemID), ns.Money(sum.best.price),
                    ns.Money(sum.best.value), ns.Money(sum.best.margin))
            end
        else
            text = text .. " No gear scan yet: click Scan both."
        end
        return text
    elseif UI.view == "materials" then
        return string.format("Price = average of cheapest %d units. Red = below break-even. * = none listed, last price. "
            .. "~ = other essence form. Unknown / +n? = units with no recorded purchase (/salv stock sets them). "
            .. "Post = sell what is in your bags; the warning sign means the price is below your break-even.",
            ns.db.settings.priceUnits)
    end
    return "Recommended = disenchant value after the 5% cut, minus your minimum profit. Type gold, silver and copper in "
        .. "Buy below to set your own (yellow). x = back to the recommended price. Grey = type not scanned."
end

--- Column widths: the first column takes the room the window has over its default width.
local function widths(view)
    local extra = math.max(0, math.floor((f:GetWidth() or WIDTH) - WIDTH))
    local w = {}
    for i, col in ipairs(view.cols) do w[i] = col[1] + (i == 1 and extra or 0) end
    return w
end

local function layout(view)
    local x = view.indent or (view.icon and 30 or 4)
    local w = widths(view)
    for i = 1, MAX_COLS do
        local col = view.cols[i]
        headers[i]:ClearAllPoints()
        headers[i]:SetPoint("TOPLEFT", headers[i]:GetParent(), "TOPLEFT", x, 0)
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
    local h = UI.list and UI.list:GetHeight() or 0
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
end

function UI.Refresh()
    if not f or not f:IsShown() then return end
    local view = VIEWS[UI.view]
    ROWS = fitRows()
    local w = layout(view)
    local data = SOURCES[UI.view]()
    UI.offset = math.max(0, math.min(UI.offset, #data - ROWS))
    UI.UpdateScrollBar(#data)
    for i, h in ipairs(headers) do
        local col = view.cols[i]
        if col then
            h:SetWidth(w[i]) h:SetJustifyH(col[2]) h:SetText(view.header[i] or "") h:Show()
        else
            h:Hide()
        end
    end
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
            row.buy:SetEnabled(ns.Queue.open and not loading)
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
    gearChoice:Update()
    qualityDrop:Update()
    footer:SetText(footerText())
    lastRefresh = GetTime()
    if ns.LogPanel and not ns.Busy() then ns.LogPanel.Refresh() end
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
    tinsert(UISpecialFrames, "SalvagerFrame")

    -- Row 1: views, log, options.
    local x = 12
    for _, t in ipairs({ { "deals", "Deals" }, { "materials", "Materials" }, { "limits", "Limits" } }) do
        local b = W.Button(f, t[2], 90, function() UI.view = t[1] UI.offset = 0 UI.Refresh() end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -30)
        tabs[t[1]] = b
        x = x + 94
    end
    local options = W.Button(f, "Options", 80, function() ns.Options.Open() end)
    options:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -30)
    local log = W.Button(f, "Log", 80, function() ns.LogPanel.Toggle() end,
        "Opens the log panel: disenchant results, sales, and the activity log for debugging.")
    log:SetPoint("RIGHT", options, "LEFT", -6, 0)

    -- Row 2: scans.
    local scanMats = W.Button(f, "Scan materials", 115, function() ns.Prices.Scan() end,
        "Searches each disenchanting material once (about 20 seconds) and stores its price.")
    scanMats:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -58)
    local scanGear = W.Button(f, "Scan gear", 90, function() ns.Scanner.Scan() end,
        "Lists the gear on the auction house and checks each item that is below its buy limit.")
    scanGear:SetPoint("LEFT", scanMats, "RIGHT", 6, 0)
    local scanBoth = W.Button(f, "Scan both", 90, function() ns.ScanBoth() end,
        "Scans the material prices first, then the gear.")
    scanBoth:SetPoint("LEFT", scanGear, "RIGHT", 6, 0)
    playButton = W.IconButton(f, 24, function()
        local s = ns.Scanner
        if s.auto and not s.paused then s.Pause() else s.Play() end
    end)
    playButton:SetPoint("LEFT", scanBoth, "RIGHT", 12, 0)
    playButton:SetScript("OnEnter", function(self)
        local s = ns.Scanner
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        if s.auto and not s.paused then
            GameTooltip:SetText("Pause", 1, 1, 1)
            GameTooltip:AddLine("Holds every search where it is. Play continues from there.", 1, 0.82, 0, true)
        else
            GameTooltip:SetText(s.paused and "Resume" or "Play", 1, 1, 1)
            GameTooltip:AddLine("Scans the gear now and again every " .. ns.db.settings.autoInterval
                .. " seconds while the auction house is open, so new cheap listings show up by themselves. "
                .. "Material prices are not rescanned: use Scan materials from time to time. You still click Buy yourself.",
                1, 0.82, 0, true)
        end
        GameTooltip:Show()
    end)
    playButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    stopButton = W.IconButton(f, 24, function() ns.Scanner.Stop() end)
    stopButton:SetPoint("LEFT", playButton, "RIGHT", 4, 0)
    stopButton:SetStopGlyph()
    W.Tooltip(stopButton, "Stop", "Ends auto scanning and drops the scan that is running. Deals found so far stay in the list.")
    spinner = W.Spinner(f, 22)
    spinner:SetPoint("LEFT", stopButton, "RIGHT", 12, 0)
    status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("LEFT", spinner, "RIGHT", 6, 0)
    status:SetPoint("RIGHT", f, "RIGHT", -14, 0)
    status:SetJustifyH("LEFT")

    -- Row 3: minimum profit and gear type.
    local mpLabel = W.Label(f, "Min profit")
    mpLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -92)
    minProfit = W.Money(f, function(copper)
        ns.db.settings.minProfit = copper
        ns.Log("min profit set to %s", ns.Money(copper))
        ns.Fire("SALVAGER_SETTINGS")
    end)
    minProfit:SetPoint("LEFT", mpLabel, "RIGHT", 10, 0)
    local gearLabel = W.Label(f, "Gear")
    gearLabel:SetPoint("LEFT", minProfit:Right(), "RIGHT", 30, 0)
    gearChoice = W.CheckDropdown(f, 150, { { "weapons", "Weapons" }, { "armor", "Armor" } },
        ns.GearTypeOn, ns.SetGearType,
        "Which gear the scan looks at. Armor gives mostly dust, weapons mostly essence. The Limits tab shows the buy limits.",
        "Gear")
    gearChoice:SetPoint("LEFT", gearLabel, "RIGHT", 8, 0)

    local qLabel = W.Label(f, "Quality")
    qLabel:SetPoint("LEFT", gearChoice, "RIGHT", 24, 0)
    qualityDrop = W.CheckDropdown(f, 170, {
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
    end, "Which gear qualities the scan looks at. Green gives dust and essence, blue one shard, epic 2-4 shards "
        .. "or Nexus Crystals.", "Quality")
    qualityDrop:SetPoint("LEFT", qLabel, "RIGHT", 8, 0)

    -- The list.
    local list = CreateFrame("Frame", nil, f)
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -116)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -30, 40)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        UI.offset = math.max(0, UI.offset - delta * 3)
        UI.Refresh()
    end)
    UI.list = list

    -- Scroll bar on the right of the list.
    local bar = W.ScrollBar(f, function(value)
        if value ~= UI.offset then
            UI.offset = value
            UI.Refresh()
        end
    end)
    bar:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -116 - ROW_H)
    bar:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 40)
    bar:EnableMouseWheel(true)
    bar:SetScript("OnMouseWheel", list:GetScript("OnMouseWheel"))
    UI.bar = bar
    for i = 1, MAX_COLS do
        local h = list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetHeight(ROW_H)
        headers[i] = h
    end
    for r = 1, MAX_ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW_H)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -r * ROW_H)
        row:SetPoint("RIGHT", list, "RIGHT", 0, 0)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
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
            GameTooltip:AddLine(string.format("The lowest listing is %s. Your break-even is %s. Posting now loses about %s each.",
                sug.lowest and ns.Money(sug.lowest) or "not known", ns.Money(sug.breakEven),
                ns.Money(sug.breakEven - sug.price)), 1, 0.82, 0, true)
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

    footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 10)
    footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 10)
    footer:SetJustifyH("LEFT")
    footer:SetWordWrap(true)

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

    f:SetScript("OnShow", function() UI.Refresh() end)
    f:SetScript("OnHide", function() if ns.LogPanel then ns.LogPanel.Hide() end end)
    f:Hide()
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

for _, e in ipairs({ "SALVAGER_PRICES", "SALVAGER_PRICES_DONE", "SALVAGER_SCAN", "SALVAGER_DEALS",
    "SALVAGER_LEDGER", "SALVAGER_SETTINGS" }) do
    ns.On(e, function() UI.RequestRefresh() end)
end

ns.On("AUCTION_HOUSE_SHOW", function()
    if ns.db.settings.autoOpen then UI.Show() end
    UI.Refresh()
end)
ns.On("AUCTION_HOUSE_CLOSED", function() UI.Refresh() end)

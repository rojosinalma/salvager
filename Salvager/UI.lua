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
local QUALITY_COLOR = ns.QUALITY_COLOR
local CLASS_NAME = { [2] = "Weapon", [4] = "Armor" }

local VIEWS = {
    deals = {
        icon = true,
        indent = 46,
        actionTitle = "Buy",
        header = { "Item", "Type", "iLvl", "Buyout", "Value", "Profit", "Lose %" },
        -- Shown when the mouse is over a column's title.
        help = {
            [5] = { "Value", "What one disenchant of this item is worth on average over many disenchants, at the "
                .. "scanned material prices, after the 5% auction house cut. One disenchant gives less or more than this." },
            [6] = { "Profit", "Value minus the buyout: the average profit per item over many disenchants. "
                .. "It is not what one item will give." },
            [7] = { "Lose %", "The chance that ONE disenchant of this item is worth less than its buyout, after the cut.\n\n"
                .. "Example: you pay 10s for an item. 3 times out of 4 it gives dust worth 5s: you lose 5s. 1 time "
                .. "out of 4 it gives an essence worth 30s: you gain 20s. Lose % is 75%. Over many items you still "
                .. "gain: the average is 11s 25c per item, so 1s 25c of profit each.\n\n"
                .. "Green: under 30%. Yellow: 30% or more. Red: 60% or more.\n\n"
                .. "A high Lose % with a good Profit needs many items before the average shows. A low Lose % is safe "
                .. "even for a few items." },
        },
        cols = { { 205, "LEFT" }, { 46, "CENTER" }, { 34, "CENTER" }, { 80, "RIGHT" }, { 80, "RIGHT" }, { 80, "RIGHT" },
            { 54, "CENTER" } },
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
        header = { "Item level", "Armor recommended", "Armor buy below", "Weapon recommended", "Weapon buy below" },
        -- (The two "buy below" columns are as wide as their gold, silver and copper boxes, title centered.)
        cols = { { 64, "LEFT" }, { 100, "RIGHT" }, { 184, "CENTER" }, { 100, "RIGHT" }, { 184, "CENTER" } },
        edit = { [3] = "armor", [5] = "weapon" },
    },
}

local f, rows, headers, status, footer, minProfit, playButton, stopButton, gearChoice, tabs =
    nil, {}, {}, nil, nil, nil, nil, nil, nil, {}
local maxPrice, capHint, cautious, bandDrop, ilvlMin, ilvlMax, levelHint, materialsOnly, scanOwned, gold, maxChecks
local qualityDrop, popOut
local headerHelp = {}
local actionHeader
local REFRESH_GAP, lastRefresh, refreshQueued = 0.25, 0, false
local spinner, bigSpinner, bigSpinnerText

------------------------------------------------------------------ rows per view

local function dealName(d)
    return (d.link and d.link:match("%[(.-)%]")) or (ns.GetItemInfo(d.itemID)) or ("item " .. d.itemID)
end

local function dealCells(d, label)
    return { label, CLASS_NAME[d.classID or ns.ClassOf(d.itemID)] or "", tostring(d.ilvl or ""), ns.Money(d.buyout),
        ns.Money(d.value), "|cff40ff40" .. ns.Money(d.profit) .. "|r", ns.LoseText(d.lose) }
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
            -- The row's numbers are those of its cheapest auction: the one its Buy button buys.
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

local SOURCES = { deals = dealRows, materials = function() return ns.Materials.Rows() end, limits = limitRows }

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

--- The line under the list: what the last scan found. (What the columns mean is behind the "?" button.)
local function footerText()
    if UI.view == "deals" then
        local sum = ns.Scanner.summary
        local text = string.format("%d deals.", #ns.Scanner.deals)
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
                text = text .. string.format(" Closest: %s at %s, buy limit %s (%s).",
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
        return text
    elseif UI.view == "limits" and ns.db.settings.cautious then
        return "Cautious pricing is on."
    end
    return ""
end

--- What the list's columns and marks mean, one line each (for the "?" button).
local function helpLines()
    if UI.view == "materials" then return ns.Materials.HelpLines() end
    if UI.view == "limits" then
        return {
            ns.db.settings.cautious and "Recommended: the value with every material at its lowest amount, after the 5% cut, "
                .. "minus your minimum profit (cautious pricing is on)."
                or "Recommended: the disenchant value after the 5% cut, minus your minimum profit.",
            "Buy below: the limit in use. Type gold, silver and copper to set your own; it then shows in yellow.",
            "x: back to the recommended price.",
            "Grey: a gear type the scan does not look at.",
            "?: a material of that band has no price yet.",
            "Max price, when set, still applies on top of these limits.",
        }
    end
    return {
        "Value: what one disenchant of the item is worth on average over many, after the 5% cut.",
        "Profit: Value minus the buyout. An average, not what one item gives.",
        "Lose %: the chance that one disenchant is worth less than its buyout.",
        "A name with x3 stands for three auctions of one item. Its numbers and its Buy are for the cheapest one.",
        "Click such a row to open it and see each auction.",
        "Buy needs one click per item. After a purchase the item is searched again.",
        string.format("The list keeps the %d best of each round (Item checks, in the Levels row).",
            ns.db.settings.maxChecks),
        "Hover a column title for more about that column.",
    }
end

--- Column widths: the first column takes the room the window has over its default width.
--- Every column is as wide as its widest text (title or cell), and no wider. The columns with input
--- boxes keep the width of their boxes. Where the client cannot measure text, the widths given are used
--- and the first column takes the room the window has over its default width.
local function widths(view, data)
    local need = data and W.FitColumns(view.header, #data, function(r) return data[r].cells end)
    local w = {}
    if need then
        for i, col in ipairs(view.cols) do w[i] = (view.edit and view.edit[i]) and col[1] or need[i] end
        return w
    end
    local extra = math.max(0, math.floor((f:GetWidth() or WIDTH) - WIDTH))
    for i, col in ipairs(view.cols) do w[i] = col[1] + (i == 1 and extra or 0) end
    return w
end

local function layout(view, data)
    local x = view.indent or (view.icon and 30 or 4)
    local w = widths(view, data)
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
            h:SetWidth(w[i]) h:SetJustifyH(col[2]) h:SetText(view.header[i] or "") h:Show()
        else
            h:Hide()
        end
        local help = view.help == "materials" and ns.Materials.HELP or view.help
        headerHelp[i].help = col and help and help[i] or nil
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
    maxPrice:Set(ns.db.settings.maxPrice)
    capHint:SetText(ns.db.settings.maxPrice > 0 and "" or "no limit")
    cautious:SetChecked(ns.db.settings.cautious)
    bandDrop:Update()
    local st = ns.db.settings
    if not ilvlMin:HasFocus() then ilvlMin:SetText(tostring(st.ilvlMin)) end
    if not ilvlMax:HasFocus() then ilvlMax:SetText(tostring(st.ilvlMax)) end
    levelHint:SetText((st.ilvlMin > 0 or st.ilvlMax > 0) and "" or "0 = any")
    if not maxChecks:HasFocus() then maxChecks:SetText(tostring(st.maxChecks)) end
    gearChoice:Update()
    qualityDrop:Update()
    footer:SetText(footerText())
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
    spinner = W.Spinner(f, 22)
    spinner:SetPoint("LEFT", stopButton, "RIGHT", 12, 0)

    local options = W.IconButton(f, 22, function() ns.Options.Open() end)
    options:SetIcon("Interface\\Buttons\\UI-OptionsButton", 16, 16)
    options:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -30)
    W.Tooltip(options, "Options", "Opens the addon's options.")
    -- Before it: what the list's columns and marks mean.
    local helpButton = W.HelpButton(f, function()
        return UI.view == "materials" and "Materials" or UI.view == "limits" and "Limits" or "Deals"
    end, helpLines)
    helpButton:SetPoint("RIGHT", options, "LEFT", -4, 0)
    local log = W.Button(f, "Log", 80, function() ns.LogWindow.Toggle() end,
        "Opens the log in its own window: what the addon did, and any error. For debugging.")
    log:SetPoint("RIGHT", helpButton, "LEFT", -6, 0)
    local ledger = W.Button(f, "Ledger", 80, function() ns.LedgerWindow.Toggle() end,
        "Opens the ledger in its own window: what you bought, what each item was disenchanted into, "
        .. "your sales and their profit.")
    ledger:SetPoint("RIGHT", log, "LEFT", -6, 0)
    local market = W.Button(f, "Market", 80, function() ns.Market.Toggle() end,
        "Opens the market charts in their own window: the price of each material over time, from your scans.")
    market:SetPoint("RIGHT", ledger, "LEFT", -6, 0)
    status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("LEFT", spinner, "RIGHT", 6, 0)
    status:SetPoint("RIGHT", market, "LEFT", -10, 0)
    status:SetJustifyH("LEFT")
    status:SetWordWrap(false)

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
    local capLabel = W.Label(box, "Max price", "GameFontHighlightSmall")
    capLabel:SetPoint("LEFT", minProfit:Right(), "RIGHT", 16, 0)
    W.HelpArea(box, capLabel, "Max price", "The most you pay for one item, whatever it is worth. An item above this "
        .. "is never listed. All zeroes = no limit.")
    maxPrice = W.Money(box, function(copper)
        ns.db.settings.maxPrice = copper
        ns.Log("max price set to %s", copper > 0 and ns.Money(copper) or "none")
        ns.Fire("SALVAGER_SETTINGS")
    end)
    maxPrice:SetPoint("LEFT", capLabel, "RIGHT", 4, 0)
    capHint = W.Label(box, "", "GameFontDisableSmall")
    capHint:SetPoint("LEFT", maxPrice:Right(), "RIGHT", 8, 0)
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
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -159)
        tabs[t[1]] = b
        x = x + 98
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

    -- At the right end of the tab row, over the list: the gold you have now.
    gold = W.Label(f, "", "GameFontHighlight")
    gold:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -164)
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
    inset:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 40)
    local titleBand = inset:CreateTexture(nil, "BACKGROUND", nil, 1)
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

    if VIEWS[ns.db.window.view] then UI.view = ns.db.window.view end
    f:SetScript("OnShow", function() UI.Refresh() end)
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

for _, e in ipairs({ "SALVAGER_PRICES", "SALVAGER_PRICES_DONE", "SALVAGER_SCAN", "SALVAGER_DEALS", "SALVAGER_LISTINGS",
    "SALVAGER_LEDGER", "SALVAGER_SETTINGS" }) do
    ns.On(e, function() UI.RequestRefresh() end)
end

ns.On("AUCTION_HOUSE_SHOW", function()
    if ns.db.settings.autoOpen then
        UI.Show()
        -- The layout of last time: the windows that were open, and the tab that was showing.
        if ns.db.settings.restoreWindows then
            ns.LedgerWindow.Restore()
            ns.LogWindow.Restore()
            ns.Materials.Restore()
            ns.Market.Restore()
        end
    end
    UI.Refresh()
end)
ns.On("AUCTION_HOUSE_CLOSED", function() UI.Refresh() end)
-- Bag counts (the Bags column, the Post buttons) follow the bags.
ns.On("BAG_UPDATE_DELAYED", function() UI.RequestRefresh() end)
ns.On("PLAYER_MONEY", function() UI.RequestRefresh() end)

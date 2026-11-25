-- Salvager: the main window (Deals, Materials, Limits) and the Log panel attached to its right side.
local _, ns = ...

local Ledger, Data, W = ns.Ledger, ns.Data, ns.Widgets

local UI = { view = "deals", offset = 0 }
ns.UI = UI

local ROWS, ROW_H = 15, 24
local WIDTH, HEIGHT = 720, 560
local QUALITY_COLOR = { [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee" }
local CLASS_NAME = { [2] = "Weapon", [4] = "Armor" }

local VIEWS = {
    deals = {
        icon = true,
        header = { "Item", "Type", "iLvl", "Buyout", "Value", "Profit" },
        cols = { { 205, "LEFT" }, { 50, "CENTER" }, { 34, "CENTER" }, { 88, "RIGHT" }, { 88, "RIGHT" }, { 88, "RIGHT" } },
    },
    materials = {
        icon = true,
        header = { "Material", "Price", "Units", "Age", "Stock", "Avg cost", "Break-even" },
        cols = { { 175, "LEFT" }, { 80, "RIGHT" }, { 50, "CENTER" }, { 40, "CENTER" }, { 45, "CENTER" },
            { 85, "RIGHT" }, { 85, "RIGHT" } },
    },
    limits = {
        icon = false,
        header = { "Item level", "Armor recommended", "Armor buy below", "Weapon recommended", "Weapon buy below" },
        cols = { { 64, "LEFT" }, { 100, "RIGHT" }, { 182, "RIGHT" }, { 100, "RIGHT" }, { 182, "RIGHT" } },
        edit = { [3] = "armor", [5] = "weapon" },
    },
}

local f, rows, headers, status, footer, minProfit, autoCheck, gearChoice, tabs = nil, {}, {}, nil, nil, nil, nil, nil, {}
local spinner, bigSpinner, bigSpinnerText

local function ago(seconds)
    if not seconds then return "-" end
    if seconds < 60 then return "now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
    return math.floor(seconds / 3600) .. "h"
end

------------------------------------------------------------------ rows per view

local function dealRows()
    local out = {}
    for _, d in ipairs(ns.Scanner.deals) do
        out[#out + 1] = {
            cells = { d.link or ("item " .. d.itemID), CLASS_NAME[d.classID or ns.ClassOf(d.itemID)] or "",
                tostring(d.ilvl or ""), ns.Money(d.buyout), ns.Money(d.value), "|cff40ff40" .. ns.Money(d.profit) .. "|r" },
            link = d.link, itemID = d.itemID, deal = d,
        }
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
                ageText, s and tostring(s.qty) or "-", avg and ns.Money(avg) or "-", be and ns.Money(be) or "-" },
            itemID = m.id,
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
    if s.state == "browsing" then parts[#parts + 1] = string.format("Browsing (%d items)", s.browsed)
    elseif s.state == "checking" and s.toCheck == 0 then
        parts[#parts + 1] = string.format("Valuing %d/%d", s.valuedSoFar or 0, s.browsed)
    elseif s.state == "checking" then parts[#parts + 1] = string.format("Checking %d/%d", s.checked, s.toCheck)
    elseif ns.scanBothPending and not ns.Prices.scanning then parts[#parts + 1] = "Starting gear scan"
    end
    if #parts == 0 then parts[1] = ns.Queue.open and "Ready" or "Auction house closed" end
    if ns.SalvagerForBuy() then parts[#parts + 1] = "|cff40ff40Arcane Salvager bonus included|r" end
    return table.concat(parts, "  ·  ")
end

local function footerText()
    if UI.view == "deals" then
        local sum = ns.Scanner.summary
        local text = string.format("%d deals.", #ns.Scanner.deals)
        if sum then
            text = text .. string.format(" Last scan: %d items seen, %d valued, %d under the limit.", sum.browsed, sum.valued,
                sum.candidates)
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
            .. "~ = other essence form.", ns.db.settings.priceUnits)
    end
    return "Recommended = disenchant value after the 5% cut, minus your minimum profit. Type gold, silver and copper in "
        .. "Buy below to set your own (yellow). x = back to the recommended price. Grey = type not scanned."
end

local function layout(view)
    local x = view.icon and 30 or 4
    for i = 1, 7 do
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
        if col then x = x + col[1] + 6 end
    end
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

function UI.Refresh()
    if not f or not f:IsShown() then return end
    local view = VIEWS[UI.view]
    layout(view)
    local data = SOURCES[UI.view]()
    UI.offset = math.max(0, math.min(UI.offset, #data - ROWS))
    for i, h in ipairs(headers) do
        local col = view.cols[i]
        if col then
            h:SetWidth(col[1]) h:SetJustifyH(col[2]) h:SetText(view.header[i] or "") h:Show()
        else
            h:Hide()
        end
    end
    for r = 1, ROWS do
        local row, item = rows[r], data[r + UI.offset]
        row.item = item
        for i, fs in ipairs(row.cells) do
            local col = view.cols[i]
            if col and item then
                fs:SetWidth(col[1]) fs:SetJustifyH(col[2]) fs:SetText(item.cells[i] or "") fs:Show()
            else
                fs:Hide()
            end
        end
        for which, e in pairs(row.edits) do
            if item and item.limits then showEdit(e, item.limits[which], item.dim[which]) else e:Hide() end
        end
        local icon = item and view.icon and W.IconOf(item.itemID)
        if icon then row.icon:SetTexture(icon) row.icon:Show() else row.icon:Hide() end
        if item and item.deal then
            row.buy:Show()
            row.buy:SetEnabled(not item.deal.pending)
            row.buy:SetText(item.deal.pending and "..." or "Buy")
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
    autoCheck:SetChecked(ns.Scanner.auto)
    minProfit:Set(ns.db.settings.minProfit)
    gearChoice:Set(ns.db.settings.gearClasses)
    footer:SetText(footerText())
    if ns.LogPanel then ns.LogPanel.Refresh() end
end

------------------------------------------------------------------ building

local function savePosition()
    local point, _, rel, x, y = f:GetPoint()
    ns.db.window = { point = point, rel = rel, x = x, y = y }
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
    f:SetSize(WIDTH, HEIGHT)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function() f:StopMovingOrSizing() savePosition() end)
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
    autoCheck = W.Check(f, "Auto", "Scans the gear again every " .. ns.db.settings.autoInterval
        .. " seconds while the auction house is open, so new cheap listings show up by themselves. "
        .. "Material prices are not rescanned: use Scan materials from time to time. You still click Buy yourself.",
        function(on) ns.Scanner.SetAuto(on) end)
    autoCheck:SetPoint("LEFT", scanBoth, "RIGHT", 10, 0)
    spinner = W.Spinner(f, 22)
    spinner:SetPoint("LEFT", autoCheck.label, "RIGHT", 14, 0)
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
    gearChoice = W.Choice(f, { { "weapons", "Weapons" }, { "armor", "Armor" }, { "both", "Both" } }, function(v)
        ns.db.settings.gearClasses = v
        ns.Log("gear type set to %s", v)
        ns.Fire("SALVAGER_SETTINGS")
    end, "Which gear the scan looks at. Armor gives mostly dust, weapons mostly essence. The Limits tab shows the buy limits.")
    gearChoice:SetPoint("LEFT", gearLabel, "RIGHT", 6, 0)

    -- The list.
    local list = CreateFrame("Frame", nil, f)
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -116)
    list:SetSize(WIDTH - 24, (ROWS + 1) * ROW_H)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        UI.offset = math.max(0, UI.offset - delta * 3)
        UI.Refresh()
    end)
    for i = 1, 7 do
        local h = list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetHeight(ROW_H)
        headers[i] = h
    end
    for r = 1, ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(WIDTH - 24, ROW_H)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -r * ROW_H)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(20, 20)
        row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.cells = {}
        for i = 1, 7 do
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
        row.buy = W.Button(row, "Buy", 56, function()
            local item = row.item
            if item and item.deal then ns.Scanner.Buy(item.deal) end
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
    ns.On(e, function() UI.Refresh() end)
end

ns.On("AUCTION_HOUSE_SHOW", function()
    if ns.db.settings.autoOpen then UI.Show() end
    UI.Refresh()
end)
ns.On("AUCTION_HOUSE_CLOSED", function() UI.Refresh() end)

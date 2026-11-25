-- Salvager: the window. Tabs: Deals (buy), Materials (prices, stock, break-even), Log (results).
local _, ns = ...

local Util, Ledger, Data = ns.Util, ns.Ledger, ns.Data

local UI = { view = "deals", offset = 0 }
ns.UI = UI

local ROWS, ROW_H = 16, 22
local W, H = 660, 520

local VIEWS = {
    deals = {
        header = { "Item", "iLvl", "Buyout", "Value", "Profit" },
        cols = { { 215, "LEFT" }, { 40, "CENTER" }, { 95, "RIGHT" }, { 95, "RIGHT" }, { 95, "RIGHT" } },
    },
    materials = {
        header = { "Material", "Price", "Units", "Age", "Stock", "Avg cost", "Break-even" },
        cols = { { 175, "LEFT" }, { 80, "RIGHT" }, { 50, "CENTER" }, { 50, "CENTER" }, { 50, "CENTER" },
            { 85, "RIGHT" }, { 85, "RIGHT" } },
    },
    log = { header = { "" }, cols = { { 620, "LEFT" } } },
}

local f, rows, headers, status, footer, minProfitBox, autoCheck, tabs = nil, {}, {}, nil, nil, nil, nil, {}

local function ago(seconds)
    if not seconds then return "-" end
    if seconds < 60 then return "now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
    return math.floor(seconds / 3600) .. "h"
end

------------------------------------------------------------------ data per view

local function dealRows()
    local out = {}
    for _, d in ipairs(ns.Scanner.deals) do
        out[#out + 1] = {
            cells = { d.link or ("item " .. d.itemID), tostring(d.ilvl or ""), ns.Money(d.buyout), ns.Money(d.value),
                "|cff40ff40" .. ns.Money(d.profit) .. "|r" },
            link = d.link, deal = d,
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
            priceText = "*" .. priceText                                    -- none listed now: last price seen
        elseif e and not e.p and price then
            priceText = "~" .. priceText                                    -- filled from the other essence form
        end
        if price and be and price < be then priceText = "|cffff4040" .. priceText .. "|r" end
        local ageText = ago(age)
        if age and age > maxAge then ageText = "|cffff8040" .. ageText .. "|r" end
        out[#out + 1] = {
            cells = { ns.MaterialName(m.id), priceText, e and e.units and e.units > 0 and (e.units .. "/" .. e.listings) or "-",
                ageText, s and tostring(s.qty) or "-", avg and ns.Money(avg) or "-", be and ns.Money(be) or "-" },
            itemID = m.id,
        }
    end
    return out
end

local function logRows()
    local out = {}
    local t = ns.Report.Totals()
    local add = function(text) out[#out + 1] = { cells = { text } } end
    add(string.format("|cffffd100%d disenchants|r: paid %s, materials worth %s now (after cut).",
        t.n, ns.Money(t.cost), ns.Money(t.value)))
    add(string.format("|cffffd100Sales|r: %d materials for %s after cut, profit %s.", t.sold, ns.Money(t.soldNet),
        ns.Money(t.soldProfit)))
    add(" ")
    add("|cffffd100Recent disenchants|r")
    local list = ns.db.ledger.disenchants
    for i = #list, math.max(1, #list - 9), -1 do
        local r = list[i]
        local parts = {}
        for id, qty in pairs(r.got or {}) do parts[#parts + 1] = qty .. "x " .. ns.MaterialName(id) end
        add(string.format("%s %s: %s = %s (planned %s%s)%s", date("%m-%d %H:%M", r.t), r.link or "?",
            table.concat(parts, ", "), ns.Money(r.value), ns.Money(r.planned),
            r.costKnown and (", paid " .. ns.Money(r.cost)) or "", r.salvager and " [Salvager]" or ""))
    end
    add(" ")
    add("|cffffd100By band|r (needs about 15+ disenchants per band to mean much)")
    for _, line in ipairs(ns.Report.Lines()) do add(line) end
    return out
end

local SOURCES = { deals = dealRows, materials = materialRows, log = logRows }

------------------------------------------------------------------ drawing

local function statusText()
    local parts = {}
    if ns.Prices.scanning then
        parts[#parts + 1] = string.format("Materials %d/%d", ns.Prices.done, ns.Prices.total)
    end
    local s = ns.Scanner
    if s.state == "browsing" then parts[#parts + 1] = string.format("Browsing (%d items)", s.browsed)
    elseif s.state == "checking" then parts[#parts + 1] = string.format("Checking %d/%d", s.checked, s.toCheck)
    end
    if #parts == 0 then parts[1] = ns.Queue.open and "Ready" or "Auction house closed" end
    parts[#parts + 1] = "Salvager " .. (ns.SalvagerForBuy() and "|cff40ff40on|r" or "off")
    return table.concat(parts, "  -  ")
end

function UI.Refresh()
    if not f or not f:IsShown() then return end
    local view = VIEWS[UI.view]
    local data = SOURCES[UI.view]()
    UI.data = data
    UI.offset = math.max(0, math.min(UI.offset, #data - ROWS))
    for i, h in ipairs(headers) do
        local col = view.cols[i]
        if col then
            h:SetWidth(col[1]); h:SetJustifyH(col[2]); h:SetText(view.header[i] or ""); h:Show()
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
                fs:SetWidth(col[1]); fs:SetJustifyH(col[2]); fs:SetText(item.cells[i] or ""); fs:Show()
            else
                fs:Hide()
            end
        end
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
    autoCheck:SetChecked(ns.Scanner.auto)
    if not minProfitBox:HasFocus() then minProfitBox:SetText(Util.FormatMoney(ns.db.settings.minProfit)) end
    if UI.view == "deals" then
        footer:SetText(string.format("%d deals. Buy limit = disenchant value after cut - minimum profit. Click Buy once per item.",
            #ns.Scanner.deals))
    elseif UI.view == "materials" then
        footer:SetText(string.format(
            "Price = average of cheapest %d units. Red = below break-even. * = none listed, last price. ~ = other essence form.",
            ns.db.settings.priceUnits))
    else
        footer:SetText("/salv report prints this in chat. /salv stock sets opening stock.")
    end
end

------------------------------------------------------------------ building

local function button(parent, text, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(text)
    b:SetScript("OnClick", onClick)
    return b
end

local function savePosition()
    local point, _, rel, x, y = f:GetPoint()
    ns.db.window = { point = point, rel = rel, x = x, y = y }
end

local function build()
    f = CreateFrame("Frame", "SalvagerFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(W, H)
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
        f:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    end
    local title = f.TitleText
    if type(title) ~= "table" then
        title = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", f, "TOP", 0, -5)
    end
    title:SetText("Salvager " .. ns.VERSION)
    tinsert(UISpecialFrames, "SalvagerFrame")

    local x = 12
    for _, t in ipairs({ { "deals", "Deals" }, { "materials", "Materials" }, { "log", "Log" } }) do
        local b = button(f, t[2], 90, function() UI.view = t[1] UI.offset = 0 UI.Refresh() end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -30)
        tabs[t[1]] = b
        x = x + 94
    end

    local scanMats = button(f, "Scan materials", 120, function() ns.Prices.Scan() end)
    scanMats:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -58)
    local scanGear = button(f, "Scan gear", 100, function() ns.Scanner.Scan() end)
    scanGear:SetPoint("LEFT", scanMats, "RIGHT", 6, 0)

    autoCheck = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    autoCheck:SetSize(24, 24)
    autoCheck:SetPoint("LEFT", scanGear, "RIGHT", 8, 0)
    autoCheck:SetScript("OnClick", function(self) ns.Scanner.SetAuto(self:GetChecked()) end)
    local autoLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    autoLabel:SetPoint("LEFT", autoCheck, "RIGHT", 0, 0)
    autoLabel:SetText("Auto")

    local mpLabel = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    mpLabel:SetPoint("LEFT", autoLabel, "RIGHT", 16, 0)
    mpLabel:SetText("Min profit")
    minProfitBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    minProfitBox:SetSize(70, 20)
    minProfitBox:SetAutoFocus(false)
    minProfitBox:SetPoint("LEFT", mpLabel, "RIGHT", 10, 0)
    minProfitBox:SetScript("OnEnterPressed", function(self)
        local c = Util.ParseMoney(self:GetText())
        if c then
            ns.db.settings.minProfit = c
            ns.Fire("SALVAGER_SETTINGS")
        end
        self:ClearFocus()
        UI.Refresh()
    end)
    minProfitBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() UI.Refresh() end)

    status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    status:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, -34)
    status:SetJustifyH("RIGHT")

    local list = CreateFrame("Frame", nil, f)
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -88)
    list:SetSize(W - 24, (ROWS + 1) * ROW_H)
    list:EnableMouseWheel(true)
    list:SetScript("OnMouseWheel", function(_, delta)
        UI.offset = math.max(0, UI.offset - delta * 3)
        UI.Refresh()
    end)

    local hx = 4
    for i = 1, 7 do
        local h = list:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        h:SetPoint("TOPLEFT", list, "TOPLEFT", hx, 0)
        h:SetHeight(ROW_H)
        headers[i] = h
    end

    for r = 1, ROWS do
        local row = CreateFrame("Button", nil, list)
        row:SetSize(W - 24, ROW_H)
        row:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -r * ROW_H)
        local hl = row:CreateTexture(nil, "HIGHLIGHT")
        hl:SetAllPoints()
        hl:SetColorTexture(1, 1, 1, 0.08)
        row.cells = {}
        for i = 1, 7 do
            local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetHeight(ROW_H)
            fs:SetWordWrap(false)
            row.cells[i] = fs
        end
        row.buy = button(row, "Buy", 56, function()
            local item = row.item
            if item and item.deal then ns.Scanner.Buy(item.deal) end
        end)
        row.buy:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row:SetScript("OnEnter", function(self)
            local item = self.item
            local link = item and (item.link or (item.itemID and ("item:" .. item.itemID)))
            if link then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(link)
                GameTooltip:Show()
            end
        end)
        row:SetScript("OnLeave", function() GameTooltip:Hide() end)
        rows[r] = row
    end

    footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 12)
    footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 12)
    footer:SetJustifyH("LEFT")

    f:SetScript("OnShow", function() UI.Refresh() end)
    f:Hide()
end

-- Column x positions follow the view's widths.
local function layout()
    local view = VIEWS[UI.view]
    local x = 4
    for i = 1, 7 do
        local col = view.cols[i]
        headers[i]:ClearAllPoints()
        headers[i]:SetPoint("TOPLEFT", headers[i]:GetParent(), "TOPLEFT", x, 0)
        for _, row in ipairs(rows) do
            row.cells[i]:ClearAllPoints()
            row.cells[i]:SetPoint("LEFT", row, "LEFT", x, 0)
        end
        if col then x = x + col[1] + 6 end
    end
end

local refresh = UI.Refresh
function UI.Refresh()
    if not f then return end
    layout()
    refresh()
end

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

-- Salvager: the Log panel, attached to the right side of the main window.
-- Results: totals, recent disenchants, observed odds by band. Activity: what the addon did (for debugging).
local _, ns = ...

local W = ns.Widgets

local LogPanel = { mode = "results", offset = 0 }
ns.LogPanel = LogPanel

local MAX_ROWS, ROW_H = 80, 15
local ROWS = 30           -- lines that fit now (set from the panel height)
local WIDTH = 560

local p, lines, modeButtons, countText = nil, {}, {}, nil

local function resultLines()
    local out = {}
    local t = ns.Report.Totals()
    out[#out + 1] = string.format("|cffffd100%d disenchants|r: paid %s, materials worth %s now (after cut).",
        t.n, ns.Money(t.cost), ns.Money(t.value))
    out[#out + 1] = string.format("|cffffd100Sales|r: %d materials for %s after cut, profit %s.", t.sold,
        ns.Money(t.soldNet), ns.Money(t.soldProfit))
    out[#out + 1] = " "
    out[#out + 1] = "|cffffd100Recent disenchants|r"
    local list = ns.db.ledger.disenchants
    if #list == 0 then out[#out + 1] = "   none yet" end
    for i = #list, math.max(1, #list - 14), -1 do
        local r = list[i]
        local parts = {}
        for id, qty in pairs(r.got or {}) do parts[#parts + 1] = qty .. "x " .. ns.MaterialName(id) end
        out[#out + 1] = string.format("%s %s: %s = %s (planned %s%s)%s", date("%m-%d %H:%M", r.t), r.link or "?",
            table.concat(parts, ", "), ns.Money(r.value), ns.Money(r.planned),
            r.costKnown and (", paid " .. ns.Money(r.cost)) or "", r.salvager and " [Salvager]" or "")
    end
    out[#out + 1] = " "
    out[#out + 1] = "|cffffd100By band|r (about 15+ disenchants per band before the odds mean much)"
    for _, line in ipairs(ns.Report.Lines()) do out[#out + 1] = line end
    local sales = ns.db.ledger.sales
    out[#out + 1] = " "
    out[#out + 1] = "|cffffd100Recent sales|r"
    if #sales == 0 then out[#out + 1] = "   none yet" end
    for i = #sales, math.max(1, #sales - 14), -1 do
        local s = sales[i]
        out[#out + 1] = string.format("%s %dx %s: %s after cut, cost %s, profit %s", date("%m-%d %H:%M", s.t), s.count,
            ns.MaterialName(s.id), ns.Money(s.net), ns.Money(s.cost), ns.Money(s.profit))
    end
    return out
end

local function activityLines()
    local out = {}
    local log = ns.db.log
    for i = #log, 1, -1 do
        local line = log[i]
        if line:find("ERROR", 1, true) then line = "|cffff4040" .. line .. "|r" end
        out[#out + 1] = line
    end
    if #out == 0 then out[1] = "nothing logged yet" end
    return out
end

function LogPanel.Refresh()
    if not p or not p:IsShown() then return end
    local h = LogPanel.area and LogPanel.area:GetHeight() or 0
    ROWS = math.max(1, math.min(MAX_ROWS, math.floor(h / ROW_H)))
    local data = LogPanel.mode == "results" and resultLines() or activityLines()
    LogPanel.offset = math.max(0, math.min(LogPanel.offset, #data - ROWS))
    for i = 1, MAX_ROWS do
        local text = i <= ROWS and data[i + LogPanel.offset] or nil
        lines[i]:SetText(text or "")
        lines[i]:SetShown(i <= ROWS)
    end
    for mode, b in pairs(modeButtons) do
        if mode == LogPanel.mode then b:LockHighlight() else b:UnlockHighlight() end
    end
    countText:SetText(LogPanel.mode == "activity"
        and string.format("%d lines, newest first. Saved to disk on /reload or logout.", #ns.db.log)
        or "Scroll with the mouse wheel.")
end

local function build()
    local main = ns.UI.Frame()
    p = CreateFrame("Frame", "SalvagerLogFrame", main, "BasicFrameTemplateWithInset")
    -- Same height as the main window, always: pinned to its top and bottom right corners.
    p:SetWidth(WIDTH)
    p:SetPoint("TOPLEFT", main, "TOPRIGHT", -2, 0)
    p:SetPoint("BOTTOMLEFT", main, "BOTTOMRIGHT", -2, 0)
    local title = p.TitleText
    if type(title) ~= "table" then
        title = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        title:SetPoint("TOP", p, "TOP", 0, -5)
    end
    title:SetText("Salvager log")

    local x = 12
    for _, m in ipairs({ { "results", "Results" }, { "activity", "Activity" } }) do
        local b = W.Button(p, m[2], 90, function() LogPanel.mode = m[1] LogPanel.offset = 0 LogPanel.Refresh() end)
        b:SetPoint("TOPLEFT", p, "TOPLEFT", x, -30)
        modeButtons[m[1]] = b
        x = x + 94
    end
    local clear = W.Button(p, "Clear activity", 110, function()
        wipe(ns.db.log)
        LogPanel.Refresh()
    end)
    clear:SetPoint("TOPRIGHT", p, "TOPRIGHT", -12, -30)

    local area = CreateFrame("Frame", nil, p)
    area:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -60)
    area:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -14, 28)
    LogPanel.area = area
    area:EnableMouseWheel(true)
    area:SetScript("OnMouseWheel", function(_, delta)
        LogPanel.offset = math.max(0, LogPanel.offset - delta * 5)
        LogPanel.Refresh()
    end)
    for i = 1, MAX_ROWS do
        local fs = area:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("TOPLEFT", area, "TOPLEFT", 0, -(i - 1) * ROW_H)
        fs:SetWidth(WIDTH - 28)
        fs:SetHeight(ROW_H)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        lines[i] = fs
    end
    countText = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    countText:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 14, 10)
    p:SetScript("OnShow", function() LogPanel.Refresh() end)
    p:SetScript("OnSizeChanged", function() LogPanel.Refresh() end)
    p:Hide()
end

function LogPanel.Toggle()
    if not ns.UI.Frame() then ns.UI.Show() end
    if not p then build() end
    p:SetShown(not p:IsShown())
end

function LogPanel.Hide()
    if p then p:Hide() end
end

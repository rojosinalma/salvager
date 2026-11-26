-- Salvager: tooltip lines for gear (disenchant value, buy limit) and materials (price, stock, break-even).
local _, ns = ...

local Data, Ledger = ns.Data, ns.Ledger

local COLOR = "|cff9370db"

local function addLines(tooltip, link)
    if not ns.db or not link then return end
    local id = ns.ItemID(link)
    if not id then return end
    if Data.MATERIAL_BY_ID[id] then
        local e = ns.db.prices[id]
        local price = ns.PriceOf(id)
        local age = e and e.t and math.floor((time() - e.t) / 60)
        tooltip:AddDoubleLine(COLOR .. "Salvager price|r",
            price and string.format("%s (%s min ago)", ns.Money(price), age or "?") or "not scanned", 1, 1, 1, 1, 1, 1)
        local s = ns.db.ledger.stock[id]
        if s and s.qty > 0 then
            local be = Ledger.BreakEven(ns.db.ledger, id, ns.Cut())
            tooltip:AddDoubleLine(COLOR .. "Salvager stock|r",
                string.format("%d at %s, break-even %s", s.qty, ns.Money(s.cost / s.qty), ns.Money(be)), 1, 1, 1, 1, 1, 1)
        end
        return
    end
    local classID = ns.ClassOf(link)
    if classID ~= Data.CLASS_WEAPON and classID ~= Data.CLASS_ARMOR then return end
    if ns.NoDisenchant(id) then
        tooltip:AddLine(COLOR .. "Salvager:|r cannot be disenchanted", 1, 1, 1)
        return
    end
    local v, outcomes = ns.ItemValue(link)
    if not v then return end
    local text = ns.Money(v.net)
    if #v.missing > 0 then text = text .. " (some prices missing)" end
    tooltip:AddDoubleLine(COLOR .. "Salvager disenchant value|r", text, 1, 1, 1, 1, 1, 1)
    tooltip:AddDoubleLine(COLOR .. "Salvager buy below|r",
        (function()
            local limit, manual = ns.BuyLimit(ns.QualityOf(link), classID, outcomes and outcomes.band, ns.LimitBasis(v))
            return ns.Money(limit) .. (manual and " (set by hand)" or "")
                .. (ns.SalvagerForBuy() and " (Arcane Salvager bonus)" or "")
        end)(),
        1, 1, 1, 1, 1, 1)
    if outcomes and IsShiftKeyDown() then
        for _, r in ipairs(outcomes.results) do
            local range = r.min == r.max and tostring(r.min) or (r.min .. "-" .. r.max)
            tooltip:AddDoubleLine("   " .. math.floor(r.chance * 100 + 0.5) .. "% " .. range .. "x " .. ns.MaterialName(r.id),
                ns.Money(ns.PriceOf(r.id)), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        end
    end
end

if TooltipDataProcessor and TooltipDataProcessor.AddTooltipPostCall and Enum.TooltipDataType then
    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tooltip, data)
        if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
        local link = data and data.hyperlink
        if not link and tooltip.GetItem then link = select(2, tooltip:GetItem()) end
        local ok, err = pcall(addLines, tooltip, link)
        if not ok and not ns.tooltipErrorShown then
            ns.tooltipErrorShown = true
            ns.Print("tooltip error: %s", tostring(err))
        end
    end)
end

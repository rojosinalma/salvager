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
        local r = ns.SellRatio(id)
        tooltip:AddDoubleLine(COLOR .. "Salvager sell price ratio|r", string.format("%s, %d %s (weight %s)%s",
            string.format("%.1f%%", r.ratio * 100), r.count or 0, r.count == 1 and "sale" or "sales",
            ns.WeightText(r.n), r.few and " (few sales)" or ""), 1, 1, 1, 1, 1, 1)
        local tts = ns.TimeToSell(id)
        tooltip:AddDoubleLine(COLOR .. "Salvager time to sell|r", tts.seconds and string.format("%s, %d %s (weight %s)%s",
            ns.DurationText(tts.seconds), tts.count or 0, tts.count == 1 and "sale" or "sales", ns.WeightText(tts.n),
            tts.few and " (few sales)" or "") or "no sale yet", 1, 1, 1, 1, 1, 1)
        local perUnit = ns.DepositPerUnit(id)
        tooltip:AddDoubleLine(COLOR .. "Salvager deposits lost per unit sold|r",
            string.format("%.2f copper", perUnit), 1, 1, 1, 1, 1, 1)
        local s = ns.db.ledger.stock[id]
        if s and s.qty > 0 then
            local avg = Ledger.AvgCost(ns.db.ledger, id)
            local be = Ledger.BreakEven(ns.db.ledger, id, ns.Cut())
            tooltip:AddDoubleLine(COLOR .. "Salvager stock|r", avg
                and string.format("%d at %s, break-even %s", s.qty, ns.Money(avg), ns.Money(be))
                or string.format("%d, cost unknown", s.qty), 1, 1, 1, 1, 1, 1)
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
    tooltip:AddDoubleLine(COLOR .. "Salvager avg disenchant value|r", text, 1, 1, 1, 1, 1, 1)
    -- The range of one disenchant: two real outcomes in whole units (SDD 116).
    local sp = outcomes and ns.Spread(outcomes)
    if sp and sp.low and sp.high then
        tooltip:AddDoubleLine(COLOR .. "Salvager low - high|r", string.format("%s %s - %s %s%s", ns.OutcomeWhat(sp.low),
            ns.Money(sp.low.value), ns.OutcomeWhat(sp.high), ns.Money(sp.high.value),
            sp.unproven and (" (" .. ns.NOT_PROVEN .. ")") or ""), 1, 1, 1, 1, 1, 1)
    end
    local basis = ns.LimitBasis(v, outcomes)
    local limit, manual = ns.BuyLimit(ns.QualityOf(link), classID, outcomes and outcomes.band, basis)
    tooltip:AddDoubleLine(COLOR .. "Salvager buy below|r", ns.Money(limit) .. (manual and " (set by hand)" or "")
        .. (ns.SalvagerForBuy() and " (Arcane Salvager bonus)" or ""), 1, 1, 1, 1, 1, 1)
    if outcomes and IsShiftKeyDown() then
        for _, x in ipairs(sp and sp.list or {}) do
            tooltip:AddDoubleLine("   " .. math.floor(x.chance * 100 + 0.5) .. "% " .. ns.OutcomeWhat(x),
                ns.Money(x.value), 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
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

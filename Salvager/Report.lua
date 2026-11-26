-- Salvager: reports from the ledger (chat and the Log tab).
local _, ns = ...

local Ledger, Model = ns.Ledger, ns.Model

local Report = {}
ns.Report = Report


--- Lines for the band summary: planned vs actual, cost, and observed odds vs the table.
function Report.Lines()
    local lines = {}
    local by = Ledger.Report(ns.db.ledger)
    local keys = {}
    for k in pairs(by) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local qa, ca, ba = Ledger.BandOf(a)
        local qb, cb, bb = Ledger.BandOf(b)
        -- Gear type first, quality under it, then the band (the one grouping, SDD 80).
        if ca ~= cb then return ca > cb end
        if qa ~= qb then return qa < qb end
        return ba < bb
    end)
    for _, k in ipairs(keys) do
        local b = by[k]
        local q, classID, band = Ledger.BandOf(k)
        local head = string.format("%s, %s %s: %d disenchants (%d with Salvager). Planned %s, got %s each",
            ns.CLASS_LABEL[classID] or "?", ns.QualityText(q), ns.BandRange(q, band),
            b.n, b.salvager, ns.Money(b.planned / b.n), ns.Money(b.value / b.n))
        if b.costKnown > 0 then head = head .. string.format(", paid %s", ns.Money(b.cost / b.costKnown)) end
        lines[#lines + 1] = head
        local outcomes = Model.Outcomes(q, classID, band)
        local expected = {}
        if outcomes then for _, r in ipairs(outcomes.results) do expected[r.id] = r end end
        for id, m in pairs(b.mats) do
            local e = expected[id]
            lines[#lines + 1] = string.format("   %s: %d%% of disenchants (table %s), %.2f each time",
                ns.MaterialName(id), math.floor(m.hits / b.n * 100 + 0.5),
                e and (math.floor(e.chance * 100 + 0.5) .. "%") or "not in table", m.qty / m.hits)
        end
    end
    return lines
end

--- Totals: disenchants, cost, value, and realised sales.
--- soldProfit counts only units with a known cost (and the deposits lost); the net of the other units
--- is in untrackedNet, the deposits lost in depositsLost.
function Report.Totals()
    local l = ns.db.ledger
    local t = { n = #l.disenchants, cost = 0, value = 0, sold = 0, soldNet = 0, soldProfit = 0, untracked = 0,
        untrackedNet = 0, depositsLost = 0 }
    for _, r in ipairs(l.disenchants) do
        t.cost = t.cost + (r.cost or 0)
        t.value = t.value + (r.value or 0)
    end
    for _, s in ipairs(l.sales) do
        if s.lost then
            t.depositsLost = t.depositsLost - s.net
        else
            t.sold = t.sold + s.count
            t.soldNet = t.soldNet + s.net
            t.untracked = t.untracked + (s.untracked or 0)
            t.untrackedNet = t.untrackedNet + (s.netUntracked or 0)
        end
        t.soldProfit = t.soldProfit + (s.profit or 0)
    end
    return t
end

function Report.Print()
    local t = Report.Totals()
    ns.Print("%d disenchants: paid %s, materials worth %s now. Sold %d materials for %s, profit %s.",
        t.n, ns.Money(t.cost), ns.Money(t.value), t.sold, ns.Money(t.soldNet), ns.Money(t.soldProfit))
    if t.untracked > 0 then
        ns.Print("Not in the profit: %d sold with no recorded cost, %s after the cut.", t.untracked,
            ns.Money(t.untrackedNet))
    end
    if t.depositsLost > 0 then ns.Print("Deposits lost (expired or cancelled): %s, in the profit.", ns.Money(t.depositsLost)) end
    for _, line in ipairs(Report.Lines()) do ns.Print(line) end
end

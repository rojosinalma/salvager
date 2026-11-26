-- Salvager: reports from the ledger (chat and the Log tab).
local _, ns = ...

local Ledger, Model = ns.Ledger, ns.Model

local Report = {}
ns.Report = Report

local QUALITY = { [2] = "uncommon", [3] = "rare", [4] = "epic" }

--- Lines for the band summary: planned vs actual, cost, and observed odds vs the table.
function Report.Lines()
    local lines = {}
    local by = Ledger.Report(ns.db.ledger)
    local keys = {}
    for k in pairs(by) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local qa, ca, ba = a:match("(%d+):(%a):(%d+)")
        local qb, cb, bb = b:match("(%d+):(%a):(%d+)")
        if qa ~= qb then return qa < qb end
        if ca ~= cb then return ca < cb end
        return tonumber(ba) < tonumber(bb)
    end)
    for _, k in ipairs(keys) do
        local b = by[k]
        local q, c, band = k:match("(%d+):(%a):(%d+)")
        q, band = tonumber(q), tonumber(band)
        local head = string.format("%s %s, item level up to %d: %d disenchants (%d with Salvager). Planned %s, got %s each",
            QUALITY[q] or ("quality " .. q), c == "w" and "weapons" or "armor", band, b.n, b.salvager,
            ns.Money(b.planned / b.n), ns.Money(b.value / b.n))
        if b.costKnown > 0 then head = head .. string.format(", paid %s", ns.Money(b.cost / b.costKnown)) end
        lines[#lines + 1] = head
        local outcomes = Model.Outcomes(q, c == "w" and 2 or 4, band)
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
function Report.Totals()
    local l = ns.db.ledger
    local t = { n = #l.disenchants, cost = 0, value = 0, sold = 0, soldNet = 0, soldProfit = 0 }
    for _, r in ipairs(l.disenchants) do
        t.cost = t.cost + (r.cost or 0)
        t.value = t.value + (r.value or 0)
    end
    for _, s in ipairs(l.sales) do
        t.sold = t.sold + s.count
        t.soldNet = t.soldNet + s.net
        t.soldProfit = t.soldProfit + s.profit
    end
    return t
end

function Report.Print()
    local t = Report.Totals()
    ns.Print("%d disenchants: paid %s, materials worth %s now. Sold %d materials for %s, profit %s.",
        t.n, ns.Money(t.cost), ns.Money(t.value), t.sold, ns.Money(t.soldNet), ns.Money(t.soldProfit))
    for _, line in ipairs(Report.Lines()) do ns.Print(line) end
end

-- Salvager: the ledger. Follows cost from purchase to disenchant to sale.
-- Pure functions on a state table (SalvagerDB.ledger), no game API.
--
-- state = {
--   purchases = { [itemID] = { { each, ev, t }, ... } }   -- oldest first (FIFO)
--   stock     = { [matID] = { qty, cost } }               -- cost = total copper
--   disenchants = { record, ... }, sales = { record, ... }
-- }
local _, ns = ...
ns = ns or {}

local Util = ns.Util
local Ledger = {}
ns.Ledger = Ledger

Ledger.MAX_PURCHASES_PER_ITEM = 50
Ledger.MAX_RECORDS = 5000

function Ledger.Init(state)
    state.purchases = state.purchases or {}
    state.stock = state.stock or {}
    state.disenchants = state.disenchants or {}
    state.sales = state.sales or {}
    return state
end

--- A purchase of `count` items for `total` copper. `ev` = expected net value each at that time.
function Ledger.AddPurchase(state, itemID, count, total, ev, t)
    count = math.max(1, count or 1)
    local list = state.purchases[itemID] or {}
    state.purchases[itemID] = list
    local each = math.floor(total / count + 0.5)
    for _ = 1, count do list[#list + 1] = { each = each, ev = ev, t = t } end
    Util.Cap(list, Ledger.MAX_PURCHASES_PER_ITEM)
end

--- The oldest recorded purchase of this item, removed. nil when none.
function Ledger.TakePurchase(state, itemID)
    local list = state.purchases[itemID]
    if not list or #list == 0 then return nil end
    local p = table.remove(list, 1)
    if #list == 0 then state.purchases[itemID] = nil end
    return p
end

--- Splits `cost` across the materials received, by their value now.
--- When no material has a price, splits by quantity.
--- @param got table  { [matID] = qty }
--- @return table  { [matID] = copper }
function Ledger.Allocate(cost, got, priceOf)
    local ids, weights, total = {}, {}, 0
    for id, qty in pairs(got) do
        local p = priceOf(id)
        ids[#ids + 1] = id
        weights[id] = (p or 0) * qty
        total = total + weights[id]
    end
    table.sort(ids)
    if total == 0 then
        for _, id in ipairs(ids) do weights[id] = got[id] end
        for _, id in ipairs(ids) do total = total + weights[id] end
    end
    local out, given, largest = {}, 0, nil
    for _, id in ipairs(ids) do
        out[id] = total > 0 and math.floor(cost * weights[id] / total) or 0
        given = given + out[id]
        if not largest or weights[id] > weights[largest] then largest = id end
    end
    if largest then out[largest] = out[largest] + (cost - given) end
    return out
end

function Ledger.AddStock(state, matID, qty, cost)
    local s = state.stock[matID] or { qty = 0, cost = 0 }
    state.stock[matID] = s
    s.qty = s.qty + qty
    s.cost = s.cost + cost
end

--- Sets the stock of a material by hand (opening stock).
function Ledger.SetStock(state, matID, qty, each)
    if qty <= 0 then state.stock[matID] = nil return end
    state.stock[matID] = { qty = qty, cost = qty * each }
end

--- Average cost each, or nil when none in stock.
function Ledger.AvgCost(state, matID)
    local s = state.stock[matID]
    if not s or s.qty <= 0 then return nil end
    return s.cost / s.qty
end

--- Lowest sale price each that does not lose money after the cut.
function Ledger.BreakEven(state, matID, cut)
    local avg = Ledger.AvgCost(state, matID)
    if not avg then return nil end
    return math.ceil(avg / (1 - (cut or 0.05)))
end

--- A sale of `count` units for `gross` copper with `cutPaid` taken by the house.
--- Removes the units at average cost. Units sold beyond the tracked stock count at zero cost.
--- @return table  sale record
function Ledger.Sell(state, matID, count, gross, cutPaid, t)
    local s = state.stock[matID]
    local tracked = s and math.min(s.qty, count) or 0
    local costBasis = 0
    if tracked > 0 then
        costBasis = math.floor(s.cost * tracked / s.qty + 0.5)
        s.qty = s.qty - tracked
        s.cost = s.cost - costBasis
        if s.qty <= 0 then state.stock[matID] = nil end
    end
    local net = gross - (cutPaid or 0)
    local rec = {
        t = t, id = matID, count = count, gross = gross, cut = cutPaid or 0, net = net,
        cost = costBasis, profit = net - costBasis, untracked = count - tracked,
    }
    state.sales[#state.sales + 1] = rec
    Util.Cap(state.sales, Ledger.MAX_RECORDS)
    return rec
end

--- Records a disenchant and adds its materials to stock.
--- @param rec table  { t, link, itemID, ilvl, quality, classID, band, salvager, got = {[id]=qty},
---                     planned = net EV now, evAtBuy = net EV at purchase or nil }
--- @param purchase table|nil  from Ledger.TakePurchase
function Ledger.Disenchant(state, rec, purchase, priceOf, cut)
    rec.cost = purchase and purchase.each or 0
    rec.costKnown = purchase ~= nil
    rec.evAtBuy = purchase and purchase.ev or nil
    local shares = Ledger.Allocate(rec.cost, rec.got, priceOf)
    for id, qty in pairs(rec.got) do Ledger.AddStock(state, id, qty, shares[id] or 0) end
    local value = 0
    for id, qty in pairs(rec.got) do value = value + (priceOf(id) or 0) * qty end
    rec.value = math.floor(value * (1 - (cut or 0.05)))
    state.disenchants[#state.disenchants + 1] = rec
    Util.Cap(state.disenchants, Ledger.MAX_RECORDS)
    return rec
end

--- Summary per disenchant band: counts, planned vs actual, observed odds.
--- @return table  { [key] = { n, planned, value, cost, mats = { [id] = { hits, qty } }, salvager = n } }
---                key = "<quality>:<a|w>:<band>"
function Ledger.Report(state, since)
    local out = {}
    for _, r in ipairs(state.disenchants) do
        if not since or (r.t or 0) >= since then
            local key = string.format("%d:%s:%d", r.quality or 0, r.classID == 2 and "w" or "a", r.band or 0)
            local b = out[key]
            if not b then
                b = { n = 0, planned = 0, value = 0, cost = 0, costKnown = 0, salvager = 0, mats = {} }
                out[key] = b
            end
            b.n = b.n + 1
            b.planned = b.planned + (r.planned or 0)
            b.value = b.value + (r.value or 0)
            if r.costKnown then b.costKnown = b.costKnown + 1 b.cost = b.cost + (r.cost or 0) end
            if r.salvager then b.salvager = b.salvager + 1 end
            for id, qty in pairs(r.got or {}) do
                local m = b.mats[id] or { hits = 0, qty = 0 }
                b.mats[id] = m
                m.hits = m.hits + 1
                m.qty = m.qty + qty
            end
        end
    end
    return out
end

return Ledger

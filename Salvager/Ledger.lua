-- Salvager: the ledger. Follows cost from purchase to disenchant to sale.
-- Pure functions on a state table (SalvagerDB.ledger), no game API.
--
-- state = {
--   purchases = { [itemID] = { { each, ev, t }, ... } }   -- oldest first (FIFO)
--   stock     = { [matID] = { qty, cost, unknown } }      -- cost = total copper of the known-cost units
--   bought    = { { itemID, each, t, mail } }             -- purchases seen at the auction house
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
    state.bought = state.bought or {}
    state.seenSold = state.seenSold or {}
    -- Stock from before 0.2.7 kept unknown costs as 0: mark those units unknown.
    for _, s in pairs(state.stock) do
        if s.unknown == nil then s.unknown = (s.cost == 0) and s.qty or 0 end
    end
    return state
end

--- A purchase of `count` items for `total` copper. `ev` = expected net value each at that time.
function Ledger.AddPurchase(state, itemID, count, total, ev, t, link)
    count = math.max(1, count or 1)
    local list = state.purchases[itemID] or {}
    state.purchases[itemID] = list
    local each = math.floor(total / count + 0.5)
    for _ = 1, count do list[#list + 1] = { each = each, ev = ev, t = t, link = link } end
    Util.Cap(list, Ledger.MAX_PURCHASES_PER_ITEM)
end

--- A purchase seen at the auction house. The "Auction won" mail for it comes later
--- and is matched by Ledger.MailPurchase, so nothing counts twice.
function Ledger.AuctionPurchase(state, itemID, total, ev, t, link)
    Ledger.AddPurchase(state, itemID, 1, total, ev, t, link)
    state.bought[#state.bought + 1] = { itemID = itemID, each = total, t = t }
    Util.Cap(state.bought, Ledger.MAX_RECORDS)
end

--- An "Auction won" mail. Returns false when the purchase was already recorded at the auction house.
function Ledger.MailPurchase(state, itemID, count, total, ev, t, link)
    for _, b in ipairs(state.bought) do
        if not b.mail and b.itemID == itemID and b.each * count == total then
            b.mail = true
            return false
        end
    end
    Ledger.AddPurchase(state, itemID, count, total, ev, t, link)
    return true
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

--- Adds units to stock. `cost` nil = units whose cost is not known.
function Ledger.AddStock(state, matID, qty, cost)
    local s = state.stock[matID] or { qty = 0, cost = 0, unknown = 0 }
    state.stock[matID] = s
    s.unknown = s.unknown or 0
    s.qty = s.qty + qty
    if cost then s.cost = s.cost + cost else s.unknown = s.unknown + qty end
end

--- Units in stock with a known cost.
function Ledger.KnownQty(state, matID)
    local s = state.stock[matID]
    if not s then return 0 end
    return s.qty - (s.unknown or 0)
end

--- Sets the stock of a material by hand (opening stock).
function Ledger.SetStock(state, matID, qty, each)
    if qty <= 0 then state.stock[matID] = nil return end
    state.stock[matID] = { qty = qty, cost = qty * each, unknown = 0 }
end

--- Average cost each of the units with a known cost, or nil when there are none.
function Ledger.AvgCost(state, matID)
    local s = state.stock[matID]
    local known = Ledger.KnownQty(state, matID)
    if not s or known <= 0 then return nil end
    return s.cost / known
end

--- Lowest sale price each that does not lose money after the cut.
function Ledger.BreakEven(state, matID, cut)
    local avg = Ledger.AvgCost(state, matID)
    if not avg then return nil end
    return math.ceil(avg / (1 - (cut or 0.05)))
end

--- A sale of `count` units for `gross` copper with `cutPaid` taken by the house.
--- Removes known-cost units first, at average cost. Units with no known cost, and units
--- beyond the stock, count at zero cost and as "untracked".
--- @return table  sale record
function Ledger.Sell(state, matID, count, gross, cutPaid, t)
    local s = state.stock[matID]
    local known = Ledger.KnownQty(state, matID)
    local tracked = math.min(known, count)
    local costBasis = 0
    if s and tracked > 0 then
        costBasis = math.floor(s.cost * tracked / known + 0.5)
        s.cost = s.cost - costBasis
    end
    if s then
        local fromUnknown = math.min(s.unknown or 0, count - tracked)
        s.unknown = (s.unknown or 0) - fromUnknown
        s.qty = s.qty - tracked - fromUnknown
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

--- Essences changed form (three lesser into one greater, or back): `fromQty` units of one material
--- became `toQty` of another. Their cost goes with them. Units with a known cost go first.
--- When some of them had no known cost, the new units still count as known, at the cost that was known.
--- @return number cost moved, number units that had no known cost
function Ledger.Convert(state, fromID, fromQty, toID, toQty)
    local s = state.stock[fromID]
    local known = Ledger.KnownQty(state, fromID)
    local tracked = math.min(known, fromQty)
    local cost = 0
    if s and tracked > 0 then
        cost = math.floor(s.cost * tracked / known + 0.5)
        s.cost = s.cost - cost
    end
    if s then
        local fromUnknown = math.min(s.unknown or 0, fromQty - tracked)
        s.unknown = (s.unknown or 0) - fromUnknown
        s.qty = s.qty - tracked - fromUnknown
        if s.qty <= 0 then state.stock[fromID] = nil end
    end
    Ledger.AddStock(state, toID, toQty, tracked > 0 and cost or nil)
    return cost, fromQty - tracked
end

--- A sale seen on the auction house (the listing shows as sold; its money comes by mail later).
--- It is booked now, at the average cost of this moment. `unpaid` counts the units whose mail has not
--- been taken yet, so that mail does not book them again (Ledger.SalePaid).
function Ledger.SaleSeen(state, matID, count, each, cutRate, t)
    local gross = count * each
    local rec = Ledger.Sell(state, matID, count, gross, math.floor(gross * (cutRate or 0.05) + 0.5), t)
    rec.each, rec.unpaid = each, count
    return rec
end

--- An "Auction successful" mail was taken: `count` units for `gross`, `cutPaid` kept by the house.
--- One mail can cover several part sales of a listing. Units already booked when they were seen as sold
--- (same material, same price each) are marked paid; only the rest is booked as a new sale.
--- @return table|nil the new sale record (nil when everything was booked before), number units matched
function Ledger.SalePaid(state, matID, count, gross, cutPaid, t)
    local each = gross / count
    local left = count
    for _, rec in ipairs(state.sales) do
        if left <= 0 then break end
        if rec.id == matID and (rec.unpaid or 0) > 0 and rec.each and math.abs(rec.each - each) < 1 then
            local take = math.min(rec.unpaid, left)
            rec.unpaid = rec.unpaid - take
            if rec.unpaid == 0 then rec.paidAt = t end
            left = left - take
        end
    end
    if left <= 0 then return nil, count end
    local part = left / count
    local rec = Ledger.Sell(state, matID, left, math.floor(gross * part + 0.5), math.floor((cutPaid or 0) * part + 0.5), t)
    rec.each, rec.paidAt = each, t
    return rec, count - left
end

--- Which of the sold auctions on screen are new. A listing sells in parts, and its parts share the
--- listing's auction ID, so a part is known by (auction ID, quantity). The time its money is due only
--- tells two parts of the same size apart: the game reports it loosely (it was seen to move by 36 s
--- between two reads), so it is never used to decide that a part is new.
--- A part stays known while it is on screen, and for a while after its money was due.
--- @param rows table  { { auctionID, qty, due (clock time the money arrives), ... }, ... }
--- @return table  the rows not seen before
function Ledger.NewSold(state, rows, now)
    local KEEP = 600
    local seen = state.seenSold
    local used, fresh = {}, {}
    for _, row in ipairs(rows) do
        local match
        for i, s in ipairs(seen) do
            if not used[i] and s.auctionID == row.auctionID and s.qty == row.qty
                and (not match or math.abs(s.due - row.due) < math.abs(seen[match].due - row.due)) then
                match = i
            end
        end
        if match then
            used[match] = true
            seen[match].due = row.due
        else
            fresh[#fresh + 1] = row
        end
    end
    -- Parts no longer on screen: forgotten once their money has been due for a while.
    for i = #seen, 1, -1 do
        if not used[i] and seen[i].due < now - KEEP then table.remove(seen, i) end
    end
    for _, row in ipairs(fresh) do
        seen[#seen + 1] = { auctionID = row.auctionID, qty = row.qty, due = row.due }
    end
    return fresh
end

--- Repairs what versions before 0.3.40 did: a sold part whose due time moved was booked a second time.
--- Removes the second sale of each such pair and gives its units back to the stock. Runs once.
--- @return number  sales removed
function Ledger.DropDoubleSales(state)
    if state.doubleSalesFixed then return 0 end
    state.doubleSalesFixed = true
    local seen, removed = state.seenSold, 0
    for i = #seen, 2, -1 do
        for j = i - 1, 1, -1 do
            if seen[i] and seen[j].auctionID == seen[i].auctionID and seen[j].qty == seen[i].qty
                and math.abs(seen[j].due - seen[i].due) <= 600 then
                local qty = seen[i].qty
                table.remove(seen, i)
                -- The second of two unpaid sales of that size and price.
                local first
                for k, rec in ipairs(state.sales) do
                    if rec.count == qty and rec.unpaid == qty and rec.each then
                        if first and first.id == rec.id and first.each == rec.each then
                            local tracked = rec.count - (rec.untracked or 0)
                            if tracked > 0 then Ledger.AddStock(state, rec.id, tracked, rec.cost) end
                            table.remove(state.sales, k)
                            removed = removed + 1
                            break
                        end
                        first = first or rec
                    end
                end
                break
            end
        end
    end
    return removed
end

--- Records a disenchant and adds its materials to stock.
--- @param rec table  { t, link, itemID, ilvl, quality, classID, band, salvager, got = {[id]=qty},
---                     planned = net EV now, evAtBuy = net EV at purchase or nil }
--- @param purchase table|nil  from Ledger.TakePurchase
function Ledger.Disenchant(state, rec, purchase, priceOf, cut)
    rec.cost = purchase and purchase.each or 0
    rec.costKnown = purchase ~= nil
    rec.evAtBuy = purchase and purchase.ev or nil
    rec.boughtAt = purchase and purchase.t or nil
    local shares = purchase and Ledger.Allocate(rec.cost, rec.got, priceOf) or {}
    for id, qty in pairs(rec.got) do Ledger.AddStock(state, id, qty, purchase and (shares[id] or 0) or nil) end
    rec.shares = purchase and shares or nil
    -- What each material was worth then, after the cut.
    local keep = 1 - (cut or 0.05)
    local value = 0
    rec.vals = {}
    for id, qty in pairs(rec.got) do
        local v = (priceOf(id) or 0) * qty
        rec.vals[id] = math.floor(v * keep + 0.5)
        value = value + v
    end
    rec.value = math.floor(value * keep)
    state.disenchants[#state.disenchants + 1] = rec
    Util.Cap(state.disenchants, Ledger.MAX_RECORDS)
    return rec
end

--- Clears the history: disenchants, sales and the record of auction purchases. The material stock and
--- its costs stay. Purchases not disenchanted yet stay too, so their cost still follows them, except
--- those for which drop(itemID) is true (items that can never be disenchanted).
--- @return number  entries removed
function Ledger.ClearHistory(state, drop)
    -- What a later mail still needs stays, so that mail does not book it a second time: purchases made
    -- at the auction house whose "Auction won" mail has not come, and sales whose money is still due.
    local bought, sales = {}, {}
    for _, b in ipairs(state.bought) do if not b.mail then bought[#bought + 1] = b end end
    for _, s in ipairs(state.sales) do if (s.unpaid or 0) > 0 then sales[#sales + 1] = s end end
    local n = #state.disenchants + #state.sales - #sales
    state.disenchants, state.sales, state.bought = {}, sales, bought
    -- (seenSold stays: the sold auctions still on screen must not be booked again.)
    for itemID, list in pairs(state.purchases) do
        if drop and drop(itemID) then
            n = n + #list
            state.purchases[itemID] = nil
        end
    end
    return n
end

--- Every item bought or disenchanted, newest first: one entry per item, with what it gave.
--- @return table  entries {
---   t, itemID, link, paid (nil = no purchase recorded), expected (value expected when bought, or at the
---   disenchant), done (disenchanted), got (value of what it gave), result (got - paid), salvager,
---   mats = { { id, qty, share (cost given to it), value }, ... }  best first }
function Ledger.History(state)
    local out = {}
    for itemID, list in pairs(state.purchases) do
        for _, p in ipairs(list) do
            out[#out + 1] = { t = p.t or 0, itemID = itemID, link = p.link, paid = p.each, expected = p.ev, done = false }
        end
    end
    for _, r in ipairs(state.disenchants) do
        local mats = {}
        for id, qty in pairs(r.got or {}) do
            mats[#mats + 1] = { id = id, qty = qty, share = r.shares and r.shares[id] or nil, value = r.vals and r.vals[id] or nil }
        end
        table.sort(mats, function(a, b)
            if (a.value or 0) ~= (b.value or 0) then return (a.value or 0) > (b.value or 0) end
            return a.id < b.id
        end)
        local paid = r.costKnown and r.cost or nil
        out[#out + 1] = {
            t = r.t or 0, boughtAt = r.boughtAt, itemID = r.itemID, link = r.link, paid = paid,
            expected = r.evAtBuy or r.planned, done = true, got = r.value, result = paid and ((r.value or 0) - paid) or nil,
            salvager = r.salvager, mats = mats,
        }
    end
    table.sort(out, function(a, b) return a.t > b.t end)
    return out
end

--- Where a material came from: which items and which bands gave it, and what it cost from each.
--- @return table {
---   units, knownUnits (from disenchants with a recorded purchase), cost (the part of those purchases given to it),
---   items = { source, ... }, bands = { source, ... } }
--- source = {
---   itemID, link (items) or quality, classID, band (bands),
---   gave (disenchants that gave this material), all (all disenchants of that item or band),
---   units, knownUnits, cost            -- of this material, from that source
---   paid, got, known                   -- the source as a whole: what its disenchants cost and gave (all materials),
---                                      -- over the `known` disenchants that have a recorded purchase
--- }
function Ledger.Breakdown(state, matID)
    local out = { units = 0, knownUnits = 0, cost = 0, items = {}, bands = {} }
    local byItem, byBand = {}, {}
    local function source(map, list, key, make)
        local s = map[key]
        if not s then
            s = make()
            s.gave, s.all, s.units, s.knownUnits, s.cost, s.paid, s.got, s.known = 0, 0, 0, 0, 0, 0, 0, 0
            map[key] = s
            list[#list + 1] = s
        end
        return s
    end
    for _, r in ipairs(state.disenchants) do
        local qty = r.got and r.got[matID]
        local item = source(byItem, out.items, r.itemID or 0, function() return { itemID = r.itemID, link = r.link } end)
        local band = source(byBand, out.bands, string.format("%d:%d:%d", r.quality or 0, r.classID or 0, r.band or 0),
            function() return { quality = r.quality, classID = r.classID, band = r.band } end)
        for _, s in ipairs({ item, band }) do
            s.all = s.all + 1
            if r.costKnown then
                s.known = s.known + 1
                s.paid = s.paid + (r.cost or 0)
                s.got = s.got + (r.value or 0)
            end
            if qty then
                s.gave = s.gave + 1
                s.units = s.units + qty
                if r.costKnown then
                    s.knownUnits = s.knownUnits + qty
                    s.cost = s.cost + ((r.shares and r.shares[matID]) or 0)
                end
            end
        end
        if qty then
            out.units = out.units + qty
            if r.costKnown then
                out.knownUnits = out.knownUnits + qty
                out.cost = out.cost + ((r.shares and r.shares[matID]) or 0)
            end
        end
    end
    -- Only the sources that gave this material.
    for _, key in ipairs({ "items", "bands" }) do
        local kept = {}
        for _, s in ipairs(out[key]) do if s.gave > 0 then kept[#kept + 1] = s end end
        out[key] = kept
    end
    return out
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

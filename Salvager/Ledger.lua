-- Salvager: the ledger. Follows cost from purchase to disenchant to sale.
-- Pure functions on a state table (SalvagerDB.ledger), no game API.
--
-- state = {
--   purchases = { [itemID] = { { each, ev, t, link, j = judged }, ... } }   -- oldest first (FIFO)
--   stock     = { [matID] = { qty, cost, unknown } }      -- cost = total copper of the known-cost units
--   pools     = { [bandKey] = { cost, mats = { [matID] = { qty, value, cost } } } }
--   bought    = { { itemID, each, t, mail } }             -- purchases seen at the auction house
--   disenchants = { record, ... }, sales = { record, ... }
-- }
--
-- Joint cost (SDD 4): the known-cost units a band's disenchants gave and that are not sold yet sit in that
-- band's pool, with their value at the disenchants. The pool's cost (what those disenchants cost, less what
-- sales and conversions took) is shared over its materials by that value (by units when nothing has a value),
-- so every material of a band carries the same cost per copper of value. A pool material's `cost` is its part,
-- and it is counted in stock[matID].cost. The rest of a material's known units and cost (opening stock,
-- conversions, units given back) sit outside the pools: stock minus what the pools hold.
local _, ns = ...
ns = ns or {}

local Util, Data, Model = ns.Util, ns.Data, ns.Model
local Ledger = {}
ns.Ledger = Ledger

Ledger.MAX_PURCHASES_PER_ITEM = 50
Ledger.MAX_RECORDS = 5000

--- Profit counts only the units with a known cost: their part of the net, minus their cost.
--- The net of the other units is kept apart (netUntracked).
local function splitNet(rec)
    local tracked = rec.count - (rec.untracked or 0)
    local netKnown = rec.count > 0 and math.floor(rec.net * tracked / rec.count + 0.5) or 0
    rec.netUntracked = rec.net - netKnown
    rec.profit = netKnown - (rec.cost or 0)
end

--- Same key as ns.BandKey: "<quality>:<a|w>:<band>".
function Ledger.BandKey(quality, classID, band)
    return string.format("%d:%s:%d", quality or 0, classID == Data.CLASS_WEAPON and "w" or "a", band or 0)
end

--- quality, classID, band from a Ledger.BandKey.
function Ledger.BandOf(key)
    local q, c, band = tostring(key):match("^(%d+):(%a):(%d+)$")
    if not q then return nil end
    return tonumber(q), c == "w" and Data.CLASS_WEAPON or Data.CLASS_ARMOR, tonumber(band)
end

Ledger.JOINT_COST = 1   -- state.jointCost is this once the costs are shared per band (Ledger.Recost)

function Ledger.Init(state)
    -- A new ledger has no double sales from old versions to repair, and no costs to share again.
    if next(state) == nil then
        state.doubleSalesFixed = Ledger.DOUBLES_REPAIR
        state.jointCost = Ledger.JOINT_COST
    end
    state.purchases = state.purchases or {}
    state.stock = state.stock or {}
    state.pools = state.pools or {}
    state.disenchants = state.disenchants or {}
    state.sales = state.sales or {}
    state.bought = state.bought or {}
    state.seenSold = state.seenSold or {}
    -- Older sales counted the net of units with no known cost as profit: count it apart.
    for _, rec in ipairs(state.sales) do
        if rec.netUntracked == nil and not rec.lost and rec.net and rec.count then splitNet(rec) end
    end
    -- Stock from before 0.2.7 kept unknown costs as 0: mark those units unknown.
    for _, s in pairs(state.stock) do
        if s.unknown == nil then s.unknown = (s.cost == 0) and s.qty or 0 end
    end
    return state
end

--- A purchase of `count` items for `total` copper. `ev` = expected net value each at that time.
--- `judged` = what the item was valued as: { q = quality, cls = class, band, ilvl, v = addon version } or nil.
function Ledger.AddPurchase(state, itemID, count, total, ev, t, link, judged)
    count = math.max(1, count or 1)
    local list = state.purchases[itemID] or {}
    state.purchases[itemID] = list
    local each = math.floor(total / count + 0.5)
    for _ = 1, count do list[#list + 1] = { each = each, ev = ev, t = t, link = link, j = judged } end
    Util.Cap(list, Ledger.MAX_PURCHASES_PER_ITEM)
end

--- A purchase seen at the auction house. The "Auction won" mail for it comes later
--- and is matched by Ledger.MailPurchase, so nothing counts twice.
function Ledger.AuctionPurchase(state, itemID, total, ev, t, link, judged)
    Ledger.AddPurchase(state, itemID, 1, total, ev, t, link, judged)
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

--- The purchases seen at the auction house whose "Auction won" mail has not been taken yet, oldest first.
--- Each one has its link, expected value and judged data from the matching purchase record when it is
--- still there (same item, time and price).
--- @return table  { { itemID, each, t, link, ev, j }, ... }
function Ledger.NotPickedUp(state)
    local used, out = {}, {}
    for _, b in ipairs(state.bought) do
        if not b.mail then
            local row = { itemID = b.itemID, each = b.each, t = b.t }
            for _, p in ipairs(state.purchases[b.itemID] or {}) do
                if not used[p] and p.t == b.t and p.each == b.each then
                    used[p] = true
                    row.link, row.ev, row.j = p.link, p.ev, p.j
                    break
                end
            end
            out[#out + 1] = row
        end
    end
    -- (state.bought is in purchase order; a stable sort keeps two of the same second in that order.)
    for i, r in ipairs(out) do r.index = i end
    table.sort(out, function(a, b)
        if (a.t or 0) ~= (b.t or 0) then return (a.t or 0) < (b.t or 0) end
        return a.index < b.index
    end)
    for _, r in ipairs(out) do r.index = nil end
    return out
end

--- The oldest recorded purchase of this item, removed. nil when none.
function Ledger.TakePurchase(state, itemID)
    local list = state.purchases[itemID]
    if not list or #list == 0 then return nil end
    local p = table.remove(list, 1)
    if #list == 0 then state.purchases[itemID] = nil end
    return p
end

--- Splits `total` copper by `weight[key]` over `keys` so that the parts add up to it: each part rounded down,
--- the copper left over going to the largest remainders (ties to the earlier key). The weights must add up to
--- more than 0.
local function split(total, keys, weight)
    local sum = 0
    for _, k in ipairs(keys) do sum = sum + weight[k] end
    local out, given, rest = {}, 0, {}
    for i, k in ipairs(keys) do
        local exact = total * weight[k] / sum
        out[k] = math.floor(exact)
        given = given + out[k]
        rest[i] = { k = k, i = i, f = exact - out[k] }
    end
    table.sort(rest, function(a, b)
        if a.f ~= b.f then return a.f > b.f end
        return a.i < b.i
    end)
    for i = 1, total - given do
        local r = rest[(i - 1) % #rest + 1]
        out[r.k] = out[r.k] + 1
    end
    return out
end

--- Shares a band pool's cost over its materials by their value at the disenchants (by units when none has a
--- value), and moves each material's change of part into its stock cost. An empty pool goes.
local function refresh(state, key)
    local p = state.pools[key]
    if not p then return end
    local ids, weight, sum = {}, {}, 0
    for id, m in pairs(p.mats) do
        ids[#ids + 1] = id
        weight[id] = m.value
        sum = sum + m.value
    end
    if #ids == 0 then
        state.pools[key] = nil
        return
    end
    table.sort(ids)
    if sum <= 0 then for _, id in ipairs(ids) do weight[id] = p.mats[id].qty end end
    local part = split(p.cost, ids, weight)
    for _, id in ipairs(ids) do
        local m, s = p.mats[id], state.stock[id]
        if s then s.cost = s.cost + part[id] - m.cost end
        m.cost = part[id]
    end
end

--- Where the known-cost units of a material sit: one source per band pool that holds some (in band key
--- order), then the units outside the pools (stock minus the pools), last.
--- @return table  { { key, qty, cost, m (the pool's material) }, ... }
local function sources(state, matID)
    local s = state.stock[matID]
    local list, inPools, poolCost = {}, 0, 0
    for key, p in pairs(state.pools) do
        local m = p.mats[matID]
        if m and m.qty > 0 then
            list[#list + 1] = { key = key, qty = m.qty, cost = m.cost, m = m }
            inPools, poolCost = inPools + m.qty, poolCost + m.cost
        end
    end
    table.sort(list, function(a, b) return a.key < b.key end)
    local outside = Ledger.KnownQty(state, matID) - inPools
    if outside > 0 then list[#list + 1] = { qty = outside, cost = math.max(0, (s and s.cost or 0) - poolCost) } end
    return list
end

--- Takes `n` known-cost units of a material out of where they sit, at the material's average cost: the cost
--- leaves each source in proportion to its cost, the units in proportion to its units (rounded to whole
--- units), so each source gives up the same share of its units, value and cost. A source that gives up its
--- last unit gives up all its cost. A band pool loses the value and cost with them, and its other units are
--- shared again. The stock's count is left to the caller.
--- @return number  the cost of the units taken
local function takeKnown(state, matID, n)
    if n <= 0 then return 0 end
    local s = state.stock[matID]
    local list = sources(state, matID)
    local keys, qty, costs, known, total = {}, {}, {}, 0, 0
    for i, src in ipairs(list) do
        keys[i], qty[i], costs[i] = i, src.qty, src.cost
        known, total = known + src.qty, total + src.cost
    end
    if known <= 0 then return 0 end
    n = math.min(n, known)
    local units = split(n, keys, qty)
    local parts = total > 0 and split(math.floor(total * n / known + 0.5), keys, costs) or {}
    local cost, touched = 0, {}
    for i, src in ipairs(list) do
        local u = units[i]
        local all = u == src.qty
        local c = all and src.cost or (parts[i] or 0)
        cost = cost + c
        if src.m and (u > 0 or c > 0) then
            local p = state.pools[src.key]
            local v = all and src.m.value or math.min(src.m.value, math.floor(src.m.value * n / known + 0.5))
            src.m.qty, src.m.value, src.m.cost = src.m.qty - u, src.m.value - v, src.m.cost - c
            p.cost = p.cost - c
            if src.m.qty <= 0 then p.mats[matID] = nil end   -- (its cost went with its last units)
            touched[#touched + 1] = src.key
        end
    end
    -- All the known units: all their cost, to the copper.
    if n == known then cost = s.cost end
    s.cost = s.cost - cost
    for _, key in ipairs(touched) do refresh(state, key) end
    return cost
end

--- Takes `count` units out of stock: known-cost units first, at their cost, then units of unknown cost.
--- @return number cost of the known units taken, number known units taken
local function withdraw(state, matID, count)
    local s = state.stock[matID]
    if not s then return 0, 0 end
    local tracked = math.min(Ledger.KnownQty(state, matID), count)
    local cost = takeKnown(state, matID, tracked)
    local fromUnknown = math.min(s.unknown or 0, count - tracked)
    s.unknown = (s.unknown or 0) - fromUnknown
    s.qty = s.qty - tracked - fromUnknown
    if s.qty <= 0 then state.stock[matID] = nil end
    return cost, tracked
end

--- Puts what a disenchant with a known cost gave into its band's pool: its cost, its units and their value
--- (`vals`, after the cut). The band's unsold units are shared again with it.
local function pool(state, key, cost, got, vals)
    if not next(got) then return end
    local p = state.pools[key] or { cost = 0, mats = {} }
    state.pools[key] = p
    p.cost = p.cost + cost
    for id, qty in pairs(got) do
        Ledger.AddStock(state, id, qty, 0)   -- known units; their cost comes from the pool
        local m = p.mats[id] or { qty = 0, value = 0, cost = 0 }
        p.mats[id] = m
        m.qty, m.value = m.qty + qty, m.value + ((vals and vals[id]) or 0)
    end
    refresh(state, key)
end

--- Adds units to stock outside the band pools. `cost` nil = units whose cost is not known.
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

--- Sets the stock of a material by hand (opening stock). It replaces what the band pools held of it: those
--- units and their part of the pools' cost go (the other materials of those bands keep their parts).
function Ledger.SetStock(state, matID, qty, each)
    local touched = {}
    for key, p in pairs(state.pools) do
        local m = p.mats[matID]
        if m then
            p.cost = p.cost - m.cost
            p.mats[matID] = nil
            touched[#touched + 1] = key
        end
    end
    for _, key in ipairs(touched) do refresh(state, key) end
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
--- Removes known-cost units first, at the average cost of this moment (SDD 5), from each band pool in
--- proportion to its units. Units with no known cost, and units beyond the stock, are "untracked": their net
--- is in netUntracked, not in the profit. A booked cost never changes afterwards.
--- @return table  sale record
function Ledger.Sell(state, matID, count, gross, cutPaid, t)
    local costBasis, tracked = withdraw(state, matID, count)
    local net = gross - (cutPaid or 0)
    local rec = {
        t = t, id = matID, count = count, gross = gross, cut = cutPaid or 0, net = net,
        cost = costBasis, untracked = count - tracked,
    }
    splitNet(rec)
    state.sales[#state.sales + 1] = rec
    Util.Cap(state.sales, Ledger.MAX_RECORDS)
    return rec
end

--- Essences changed form (three lesser into one greater, or back): `fromQty` units of one material
--- became `toQty` of another. Their cost goes with them: out of the band pools, into units of the new form
--- outside the pools. Units with a known cost go first.
--- The new units have a known cost in the same share as the old ones (rounded up, so the cost always
--- has units to sit on); the rest stay of unknown cost.
--- @return number cost moved, number units that had no known cost
function Ledger.Convert(state, fromID, fromQty, toID, toQty)
    local cost, tracked = withdraw(state, fromID, fromQty)
    local knownTo = math.min(toQty, math.ceil(toQty * tracked / fromQty))
    if knownTo > 0 then Ledger.AddStock(state, toID, knownTo, cost) end
    if toQty > knownTo then Ledger.AddStock(state, toID, toQty - knownTo, nil) end
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
--- `back` (optional): the deposit the mail gave back with the money, kept on the first record it pays
--- (`back`, `backAt`) so the statement can tell it from the sale.
--- @return table|nil the new sale record (nil when everything was booked before), number units matched
function Ledger.SalePaid(state, matID, count, gross, cutPaid, t, back)
    local each = gross / count
    local left = count
    local function keepBack(rec)
        if back and back > 0 then
            rec.back, rec.backAt = (rec.back or 0) + back, t
            back = nil
        end
    end
    for _, rec in ipairs(state.sales) do
        if left <= 0 then break end
        if rec.id == matID and (rec.unpaid or 0) > 0 and rec.each and math.abs(rec.each - each) < 1 then
            local take = math.min(rec.unpaid, left)
            rec.unpaid = rec.unpaid - take
            keepBack(rec)
            -- The cut was estimated when the sale was seen: the mail has the real one.
            rec.paidCut = (rec.paidCut or 0) + (cutPaid or 0) * take / count
            if rec.unpaid == 0 then
                rec.paidAt = t
                rec.cut = math.floor(rec.paidCut + 0.5)
                rec.net = rec.gross - rec.cut
                rec.paidCut = nil
                splitNet(rec)
            end
            left = left - take
        end
    end
    if left <= 0 then return nil, count end
    local part = left / count
    local rec = Ledger.Sell(state, matID, left, math.floor(gross * part + 0.5), math.floor((cutPaid or 0) * part + 0.5), t)
    rec.each, rec.paidAt = each, t
    keepBack(rec)
    return rec, count - left
end

--- Which of the sold auctions on screen are new. A listing sells in parts, and its parts share the
--- listing's auction ID, so a part is known by (auction ID, quantity). The time its money is due only
--- tells two parts of the same size apart: the game reports it loosely (it was seen to move by 36 s
--- between two reads, and by 150 s in the read just after a post, 2026-11-26 06:24), so it is never used
--- to decide that a part is new.
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

Ledger.DOUBLES_REPAIR = 2   -- the repair below has run when state.doubleSalesFixed is this

--- Repairs sold parts that were booked twice because their due time moved: versions before 0.3.40, and
--- 0.3.79 to 0.3.84 (which took a part whose due time moved by 2 minutes for a new one). For each part
--- that is known twice, the later of its two sales goes and its units go back to the stock. Runs once.
--- @return number  sales removed
function Ledger.DropDoubleSales(state)
    if state.doubleSalesFixed == Ledger.DOUBLES_REPAIR then return 0 end
    state.doubleSalesFixed = Ledger.DOUBLES_REPAIR
    local NEAR = 600
    local seen, sales, removed = state.seenSold, state.sales, 0
    local function near(a, b) return math.abs((a.due or a.t or 0) - (b.due or b.t or 0)) <= NEAR end
    -- The later of two sales of this size, of one material at one price, that are due close together.
    local function double(qty)
        for k = #sales, 2, -1 do
            local rec = sales[k]
            if rec.count == qty and rec.unpaid == qty and rec.each and not rec.lost then
                for m = k - 1, 1, -1 do
                    local o = sales[m]
                    if o.id == rec.id and o.count == qty and o.each == rec.each and not o.lost and near(o, rec) then
                        return k
                    end
                end
            end
        end
    end
    for i = #seen, 2, -1 do
        for j = i - 1, 1, -1 do
            if seen[i] and seen[j].auctionID == seen[i].auctionID and seen[j].qty == seen[i].qty
                and math.abs(seen[j].due - seen[i].due) <= NEAR then
                local k = double(seen[i].qty)
                table.remove(seen, i)
                if k then
                    local rec = sales[k]
                    local tracked = rec.count - (rec.untracked or 0)
                    if tracked > 0 then Ledger.AddStock(state, rec.id, tracked, rec.cost) end
                    table.remove(sales, k)
                    removed = removed + 1
                end
                break
            end
        end
    end
    return removed
end

--- Records a disenchant and adds its materials to stock. With a known cost they go into the band's pool
--- (SDD 4): the band's cost is shared again over all its unsold units by their value at the disenchants.
--- @param rec table  { t, link, itemID, ilvl, quality, classID, band, salvager, got = {[id]=qty},
---                     planned = net EV now, evAtBuy = net EV at purchase or nil }
--- @param purchase table|nil  from Ledger.TakePurchase
function Ledger.Disenchant(state, rec, purchase, priceOf, cut)
    rec.cost = purchase and purchase.each or 0
    rec.costKnown = purchase ~= nil
    rec.evAtBuy = purchase and purchase.ev or nil
    rec.boughtAt = purchase and purchase.t or nil
    rec.judged = purchase and purchase.j or nil
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
    if purchase then
        pool(state, Ledger.BandKey(rec.quality, rec.classID, rec.band), rec.cost, rec.got, rec.vals)
    else
        for id, qty in pairs(rec.got) do Ledger.AddStock(state, id, qty, nil) end
    end
    state.disenchants[#state.disenchants + 1] = rec
    Util.Cap(state.disenchants, Ledger.MAX_RECORDS)
    return rec
end

--- Whether the costs still have to be shared per band once (a ledger from before 0.3.120).
function Ledger.NeedsRecost(state)
    return state.jointCost ~= Ledger.JOINT_COST
end

--- Shares the costs per band once, for a ledger from before 0.3.120 (which split each item's price over what
--- that one disenchant gave). Replays the disenchants with a known cost and the sales in time order (a
--- disenchant before a sale of the same second) into new band pools:
---   - each sale's cost is booked again: its known units from the pools at the average of that moment, as far
---     as the pools hold them; the rest (units from opening stock or conversions, which have no record) keep
---     their old cost each. Its profit follows.
---   - then the stock is matched: the units the pools hold beyond a material's known units left without a
---     record (conversions, stock set by hand, records dropped) and go with their cost; the known units the
---     pools do not hold stay outside them at the material's old average cost.
--- The stock's counts (known and unknown) do not change. Disenchant records lose `shares`.
--- @return number disenchants pooled, number sales booked again
function Ledger.Recost(state)
    local old = state.stock
    local work = { stock = {}, pools = {} }
    local events = {}
    for i, r in ipairs(state.disenchants) do
        r.shares = nil
        if r.costKnown and r.got then events[#events + 1] = { t = r.t or 0, kind = 0, i = i, r = r } end
    end
    for i, s in ipairs(state.sales) do
        if not s.lost and (s.count or 0) > 0 then events[#events + 1] = { t = s.t or 0, kind = 1, i = i, r = s } end
    end
    table.sort(events, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        if a.kind ~= b.kind then return a.kind < b.kind end
        return a.i < b.i
    end)
    local nd, nsales = 0, 0
    for _, e in ipairs(events) do
        local r = e.r
        if e.kind == 0 then
            pool(work, Ledger.BandKey(r.quality, r.classID, r.band), r.cost or 0, r.got, r.vals)
            nd = nd + 1
        else
            local tracked = r.count - (r.untracked or 0)
            if tracked > 0 then
                local fromPools, n = withdraw(work, r.id, tracked)
                local rest = tracked - n
                r.cost = fromPools + math.floor((r.cost or 0) * rest / tracked + 0.5)
                if r.net then splitNet(r) end
                nsales = nsales + 1
            end
        end
    end
    -- Match the stock: units the pools hold beyond the known units go, with their cost.
    for id in pairs(work.stock) do
        local s = old[id]
        local known = s and (s.qty - (s.unknown or 0)) or 0
        local extra = Ledger.KnownQty(work, id) - math.max(0, known)
        if extra > 0 then withdraw(work, id, extra) end
    end
    -- The known units outside the pools keep the material's old average cost.
    for id, s in pairs(old) do
        local known = s.qty - (s.unknown or 0)
        local w = work.stock[id]
        local inPools, poolCost = w and w.qty or 0, w and w.cost or 0
        local outside = known - inPools
        s.cost = poolCost + (known > 0 and math.floor((s.cost or 0) * outside / known + 0.5) or 0)
    end
    state.pools = work.pools
    state.jointCost = Ledger.JOINT_COST
    return nd, nsales
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

--- A new, empty ledger for `/salv reset ledger`. What the auction house still shows as sold stays
--- known (seenSold), so those sales are not booked again on the next read.
function Ledger.Reset(state)
    local fresh = Ledger.Init({})
    fresh.seenSold = state and state.seenSold or {}
    return fresh
end

Ledger.EXPIRE_AFTER = 30 * 86400

--- Drops what waits for something that will not come any more, `EXPIRE_AFTER` after it was booked:
--- purchases whose "Auction won" mail never matched, purchases never disenchanted (sold or kept as
--- they were), and sales whose money was never seen taken (they count as paid).
--- @return number bought, number purchases, number sales
function Ledger.Expire(state, now)
    local cutoff = now - Ledger.EXPIRE_AFTER
    local nb, np, ns_ = 0, 0, 0
    for i = #state.bought, 1, -1 do
        local b = state.bought[i]
        if not b.mail and (b.t or 0) < cutoff then table.remove(state.bought, i) nb = nb + 1 end
    end
    for itemID, list in pairs(state.purchases) do
        for i = #list, 1, -1 do
            if (list[i].t or 0) < cutoff then table.remove(list, i) np = np + 1 end
        end
        if #list == 0 then state.purchases[itemID] = nil end
    end
    for _, s in ipairs(state.sales) do
        if (s.unpaid or 0) > 0 and (s.t or 0) < cutoff then
            s.unpaid, s.unpaidExpired = 0, true
            ns_ = ns_ + 1
        end
    end
    return nb, np, ns_
end

--- The deposit of an auction that expired or was cancelled: the auction house keeps it.
--- Booked as a sale record of no units with the deposit as its loss (`lost` = "expired" | "cancelled"),
--- so the sales history, the totals and the Profit view count it. Accuracy leaves it out.
function Ledger.DepositLost(state, matID, qty, amount, why, t)
    local rec = { t = t, id = matID, count = 0, qty = qty, gross = 0, cut = 0, net = -amount, cost = 0,
        untracked = 0, netUntracked = 0, profit = -amount, lost = why, paidAt = t }
    state.sales[#state.sales + 1] = rec
    Util.Cap(state.sales, Ledger.MAX_RECORDS)
    return rec
end

-- The forecast learns from your own sales of the last FORECAST_DAYS; a material with fewer than
-- FORECAST_MIN_SALES sales leans on all materials together, and with none at all on the default (SDD 3, 96).
Ledger.FORECAST_DAYS = 30
Ledger.FORECAST_MIN_SALES = 5

local function recentSales(state, now, days)
    local since = (now or 0) - (days or Ledger.FORECAST_DAYS) * 86400
    local out = {}
    for _, s in ipairs(state.sales) do
        if (s.t or 0) >= since then out[#out + 1] = s end
    end
    return out
end

--- The sell price ratio per material: what one unit really sold for (the sale price, before the cut) against
--- the material's value (SDD 3) when it was posted. The median of your recent sales, by units; a material with
--- few sales is pulled toward the median of all materials, and that one toward 1 while it has few sales.
--- @param valueAt function(sale) -> the material's value when that sale was posted (or at the sale), or nil;
---   used when the sale has no `val` of its own
--- @param opts table|nil { days, minSales }
--- @return table { [id] = { ratio, n (sales), units, measured (its own median), few }, all = { ratio, n } }
function Ledger.SellRatios(state, valueAt, now, opts)
    opts = opts or {}
    local floor = opts.minSales or Ledger.FORECAST_MIN_SALES
    local per, all = {}, {}
    for _, s in ipairs(recentSales(state, now, opts.days)) do
        if not s.lost and (s.count or 0) > 0 and (s.gross or 0) > 0 then
            local v = s.val or (valueAt and valueAt(s))
            if v and v > 0 then
                local each = s.each or (s.gross / s.count)
                local x = { r = each / v, w = s.count }
                per[s.id] = per[s.id] or {}
                table.insert(per[s.id], x)
                all[#all + 1] = x
            end
        end
    end
    local prior = Model.Blend(Model.WeightedMedian(all), #all, 1, floor)
    local out = { all = { ratio = prior, n = #all } }
    for id, list in pairs(per) do
        local units = 0
        for _, x in ipairs(list) do units = units + x.w end
        local measured = Model.WeightedMedian(list)
        out[id] = { ratio = Model.Blend(measured, #list, prior, floor), n = #list, units = units, measured = measured,
            few = #list < floor }
    end
    return out
end

--- Deposits lost per unit sold, per material, as a share of the deposit of one post (`k`): k = lost deposits ÷
--- (units sold × deposit of one unit). A material with few sales is pulled toward all materials together, and that
--- toward 1 (one post's deposit lost per unit sold) while it has few sales.
--- @param unitDeposit function(id) -> the deposit of one unit in one post, copper, or nil when not known
--- @param opts table|nil { days, minSales }
--- @return table { [id] = { k, perUnit (copper per unit sold), lost, sold, n, few }, all = { k, n } }
function Ledger.DepositRates(state, unitDeposit, now, opts)
    opts = opts or {}
    local floor = opts.minSales or Ledger.FORECAST_MIN_SALES
    local per, nAll, lostAll, expAll = {}, 0, 0, 0
    local function mat(id)
        local m = per[id] or { lost = 0, sold = 0, n = 0 }
        per[id] = m
        return m
    end
    for _, s in ipairs(recentSales(state, now, opts.days)) do
        if s.lost then
            local m = mat(s.id)
            m.lost = m.lost - (s.net or 0)
        elseif (s.count or 0) > 0 then
            local m = mat(s.id)
            m.sold, m.n = m.sold + s.count, m.n + 1
        end
    end
    for id, m in pairs(per) do
        m.d = unitDeposit(id)
        if m.d and m.d > 0 then
            lostAll = lostAll + m.lost
            expAll = expAll + m.sold * m.d
            nAll = nAll + m.n
        end
    end
    local prior = Model.Blend(expAll > 0 and lostAll / expAll or nil, nAll, 1, floor)
    local out = { all = { k = prior, n = nAll } }
    for id, m in pairs(per) do
        local own = (m.d and m.d > 0 and m.sold > 0) and m.lost / (m.sold * m.d) or nil
        local k = Model.Blend(own, m.n, prior, floor)
        out[id] = { k = k, perUnit = k * (m.d or 0), lost = m.lost, sold = m.sold, n = m.n, few = m.n < floor }
    end
    return out
end

--- What the trading made from `from` on (nil = all of it), to report it by quality and gear type, by band,
--- by item and by material. Only disenchants with a known cost count in the first three.
---   sold value of a disenchant = its materials at what one unit really sold for on average (after the cut),
---   or at their disenchant value when that material has not sold yet.
--- @return table {
---   total = sums, groups = { { quality, classID, bands = { sums with band }, sums... } },
---   items = { sums with itemID, link }, mats = { id, got, sold, net, cost, profit, untracked, depositsLost } }
---   sums = { n, paid, value (disenchant value), sold (sold value), salvager (disenchants with it) }
--- `keep(record)` (optional): only the disenchants it says yes to count (filters by gear type, quality, ...).
--- `to` (optional): the end of the time (included); nil = up to now.
function Ledger.Profits(state, from, keep, to)
    from = from or 0
    local function inTime(t) t = t or 0 return t >= from and (not to or t <= to) end
    local each = {}
    for _, s in ipairs(state.sales) do
        if not s.lost and s.count > 0 then
            local e = each[s.id] or { units = 0, net = 0 }
            each[s.id] = e
            e.units, e.net = e.units + s.count, e.net + s.net
        end
    end
    local function sums(extra)
        extra = extra or {}
        extra.n, extra.paid, extra.value, extra.sold, extra.salvager = 0, 0, 0, 0, 0
        return extra
    end
    local out = { total = sums(), groups = {}, items = {}, mats = {} }
    local groups, bands, items, mats = {}, {}, {}, {}
    local function mat(id)
        local m = mats[id]
        if not m then
            m = { id = id, got = 0, sold = 0, net = 0, cost = 0, profit = 0, untracked = 0, depositsLost = 0 }
            mats[id] = m
            out.mats[#out.mats + 1] = m
        end
        return m
    end
    for _, r in ipairs(state.disenchants) do
        if inTime(r.t) and (not keep or keep(r)) then
            for id, qty in pairs(r.got or {}) do mat(id).got = mat(id).got + qty end
            if r.costKnown then
                local soldValue = 0
                for id, qty in pairs(r.got or {}) do
                    local e = each[id]
                    soldValue = soldValue + ((e and e.units > 0) and (qty * e.net / e.units) or (r.vals and r.vals[id] or 0))
                end
                local gkey = (r.quality or 0) .. ":" .. (r.classID or 0)
                local g = groups[gkey]
                if not g then
                    g = sums({ quality = r.quality, classID = r.classID, bands = {} })
                    groups[gkey] = g
                    out.groups[#out.groups + 1] = g
                end
                local bkey = Ledger.BandKey(r.quality, r.classID, r.band)
                local b = bands[bkey]
                if not b then
                    b = sums({ quality = r.quality, classID = r.classID, band = r.band })
                    bands[bkey] = b
                    g.bands[#g.bands + 1] = b
                end
                local it = items[r.itemID or 0]
                if not it then
                    it = sums({ itemID = r.itemID, link = r.link })
                    items[r.itemID or 0] = it
                    out.items[#out.items + 1] = it
                end
                for _, x in ipairs({ out.total, g, b, it }) do
                    x.n = x.n + 1
                    x.paid = x.paid + (r.cost or 0)
                    x.value = x.value + (r.value or 0)
                    x.sold = x.sold + soldValue
                    if r.salvager then x.salvager = x.salvager + 1 end
                end
            end
        end
    end
    for _, s in ipairs(state.sales) do
        if inTime(s.t) then
            local m = mat(s.id)
            if s.lost then
                m.depositsLost = m.depositsLost - (s.net or 0)
            else
                m.sold = m.sold + (s.count or 0)
                m.net = m.net + (s.net or 0)
                m.cost = m.cost + (s.cost or 0)
                m.untracked = m.untracked + (s.untracked or 0)
            end
            m.profit = m.profit + (s.profit or 0)
        end
    end
    table.sort(out.groups, function(a, c)
        if a.quality ~= c.quality then return (a.quality or 0) < (c.quality or 0) end
        return (a.classID or 0) > (c.classID or 0)
    end)
    for _, g in ipairs(out.groups) do table.sort(g.bands, function(a, c) return (a.band or 0) < (c.band or 0) end) end
    table.sort(out.items, function(a, c) return (a.sold - a.paid) > (c.sold - c.paid) end)
    table.sort(out.mats, function(a, c) return a.net > c.net end)
    return out
end

--- The part of a band's cost that falls on each material of each disenchant, by the same rule as the pools
--- (SDD 4) over the band's whole record: what the band's disenchants with a known cost were paid, shared by
--- the value of what they gave at the disenchants (by units when nothing had a value).
--- @return function(rec, matID) -> copper (not rounded), or nil when the disenchant's cost is not known
local function bandShares(state)
    local bands = {}
    for _, r in ipairs(state.disenchants) do
        if r.costKnown then
            local key = Ledger.BandKey(r.quality, r.classID, r.band)
            local b = bands[key] or { paid = 0, value = 0, units = 0 }
            bands[key] = b
            b.paid = b.paid + (r.cost or 0)
            for id, qty in pairs(r.got or {}) do
                b.value = b.value + ((r.vals and r.vals[id]) or 0)
                b.units = b.units + qty
            end
        end
    end
    return function(r, id)
        if not r.costKnown then return nil end
        local b = bands[Ledger.BandKey(r.quality, r.classID, r.band)]
        local qty = r.got and r.got[id] or 0
        if b.value > 0 then return ((r.vals and r.vals[id]) or 0) * b.paid / b.value end
        return b.units > 0 and qty * b.paid / b.units or 0
    end
end

--- Every item bought or disenchanted, newest first: one entry per item, with what it gave.
--- @return table  entries {
---   t, itemID, link, paid (nil = no purchase recorded), expected (value expected when bought, or at the
---   disenchant), done (disenchanted), got (value of what it gave), result (got - paid), salvager,
---   mats = { { id, qty, share (its part of the band's cost, SDD 4), value }, ... }  best first }
function Ledger.History(state)
    local shareOf = bandShares(state)
    local out = {}
    for itemID, list in pairs(state.purchases) do
        for _, p in ipairs(list) do
            local j = p.j or {}
            out[#out + 1] = { t = p.t or 0, itemID = itemID, link = p.link, paid = p.each, expected = p.ev, done = false,
                quality = j.q, classID = j.cls, ilvl = j.ilvl, band = j.band }
        end
    end
    for _, r in ipairs(state.disenchants) do
        local mats = {}
        for id, qty in pairs(r.got or {}) do
            local share = shareOf(r, id)
            mats[#mats + 1] = { id = id, qty = qty, share = share and math.floor(share + 0.5) or nil,
                value = r.vals and r.vals[id] or nil }
        end
        table.sort(mats, function(a, b)
            if (a.value or 0) ~= (b.value or 0) then return (a.value or 0) > (b.value or 0) end
            return a.id < b.id
        end)
        local paid = r.costKnown and r.cost or nil
        out[#out + 1] = {
            t = r.t or 0, boughtAt = r.boughtAt, itemID = r.itemID, link = r.link, paid = paid,
            expected = r.evAtBuy or r.planned, done = true, got = r.value, result = paid and ((r.value or 0) - paid) or nil,
            salvager = r.salvager, mats = mats, quality = r.quality, classID = r.classID, ilvl = r.ilvl, band = r.band,
        }
    end
    table.sort(out, function(a, b) return a.t > b.t end)
    return out
end

--- Where a material came from: which items and which bands gave it, and what it cost from each.
--- @return table {
---   units, knownUnits (from disenchants with a recorded purchase), cost (its part of those bands' cost, SDD 4),
---   items = { source, ... }, bands = { source, ... } }
--- source = {
---   itemID, link (items) or quality, classID, band (bands),
---   gave (disenchants that gave this material), all (all disenchants of that item or band),
---   units, knownUnits, cost            -- of this material, from that source
---   paid, got, known                   -- the source as a whole: what its disenchants cost and gave (all materials),
---                                      -- over the `known` disenchants that have a recorded purchase
--- }
function Ledger.Breakdown(state, matID)
    local shareOf = bandShares(state)
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
        local band = source(byBand, out.bands, Ledger.BandKey(r.quality, r.classID, r.band),
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
                    s.cost = s.cost + shareOf(r, matID)
                end
            end
        end
        if qty then
            out.units = out.units + qty
            if r.costKnown then
                out.knownUnits = out.knownUnits + qty
                out.cost = out.cost + shareOf(r, matID)
            end
        end
    end
    -- Only the sources that gave this material; costs to the copper.
    out.cost = math.floor(out.cost + 0.5)
    for _, key in ipairs({ "items", "bands" }) do
        local kept = {}
        for _, s in ipairs(out[key]) do
            s.cost = math.floor(s.cost + 0.5)
            if s.gave > 0 then kept[#kept + 1] = s end
        end
        out[key] = kept
    end
    return out
end

--- How well the promise held, in three steps: what the Deals list promised at the purchase, what the
--- materials were worth at the disenchant, and what materials really sold for.
--- Only disenchants with a recorded purchase count.
--- @return table {
---   bands = { { quality, classID, band, n, paid, promised (value shown when bought), got (value of the
---               materials at the disenchant, after the cut), sold (the same materials at the average price
---               each material really sold for, after the cut; at the disenchant's price where none sold yet),
---               units, soldUnits (units of materials that have a real sale price) }, ... },
---   total = the same fields over all bands,
---   mats = { { id, units (from these disenchants), valued (their value at the disenchants, after the cut),
---              soldUnits, soldNet (all your sales of it) }, ... } }
--- `keep(record)` (optional): only the disenchants it says yes to count.
function Ledger.Accuracy(state, keep)
    -- What one unit of each material really sold for, after the cut.
    local sold = {}
    for _, s in ipairs(state.sales) do
        if not s.lost then
            local m = sold[s.id] or { units = 0, net = 0 }
            sold[s.id] = m
            m.units, m.net = m.units + s.count, m.net + s.net
        end
    end
    local function blank(extra)
        local b = extra or {}
        b.n, b.paid, b.promised, b.got, b.sold, b.units, b.soldUnits = 0, 0, 0, 0, 0, 0, 0
        return b
    end
    local out = { bands = {}, total = blank(), mats = {} }
    local byBand, byMat = {}, {}
    for _, r in ipairs(state.disenchants) do
        if r.costKnown and (not keep or keep(r)) then
            local key = Ledger.BandKey(r.quality, r.classID, r.band)
            local b = byBand[key]
            if not b then
                b = blank({ quality = r.quality, classID = r.classID, band = r.band })
                byBand[key] = b
                out.bands[#out.bands + 1] = b
            end
            local soldValue, units, soldUnits = 0, 0, 0
            for id, qty in pairs(r.got or {}) do
                local at = r.vals and r.vals[id] or 0
                local m = byMat[id]
                if not m then
                    m = { id = id, units = 0, valued = 0, soldUnits = sold[id] and sold[id].units or 0,
                        soldNet = sold[id] and sold[id].net or 0 }
                    byMat[id] = m
                    out.mats[#out.mats + 1] = m
                end
                m.units, m.valued = m.units + qty, m.valued + at
                units = units + qty
                if sold[id] and sold[id].units > 0 then
                    soldValue = soldValue + qty * sold[id].net / sold[id].units
                    soldUnits = soldUnits + qty
                else
                    soldValue = soldValue + at
                end
            end
            for _, x in ipairs({ b, out.total }) do
                x.n = x.n + 1
                x.paid = x.paid + (r.cost or 0)
                x.promised = x.promised + (r.evAtBuy or r.planned or 0)
                x.got = x.got + (r.value or 0)
                x.sold = x.sold + soldValue
                x.units, x.soldUnits = x.units + units, x.soldUnits + soldUnits
            end
        end
    end
    table.sort(out.bands, function(a, b)
        if a.quality ~= b.quality then return (a.quality or 0) < (b.quality or 0) end
        if a.classID ~= b.classID then return (a.classID or 0) > (b.classID or 0) end
        return (a.band or 0) < (b.band or 0)
    end)
    table.sort(out.mats, function(a, b) return a.valued > b.valued end)
    return out
end

--- Summary per disenchant band: counts, planned vs actual, observed odds.
--- @return table  { [key] = { n, planned, value, cost, mats = { [id] = { hits, qty } }, salvager = n } }
---                key = "<quality>:<a|w>:<band>"
--- `keep(record)` (optional): only the disenchants it says yes to count.
function Ledger.Report(state, since, keep)
    local out = {}
    for _, r in ipairs(state.disenchants) do
        if (not since or (r.t or 0) >= since) and (not keep or keep(r)) then
            local key = Ledger.BandKey(r.quality, r.classID, r.band)
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

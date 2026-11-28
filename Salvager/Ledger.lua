-- Salvager: the ledger. Follows cost from purchase to disenchant to sale.
-- Pure functions on a state table (SalvagerDB.ledger), no game API.
--
-- state = {
--   purchases = { [itemID] = { { each, ev, t, link, j = judged }, ... } }   -- oldest first (FIFO)
--   stock     = { [matID] = { qty, cost, unknown } }      -- cost = total copper of the known-cost units
--   pools     = { [bandKey] = { cost, mats = { [matID] = { qty, value, cost } } } }
--   bought    = { { itemID, each, t, mail } }             -- purchases seen at the auction house
--   matBuys   = { { t, id, qty, cost } }                   -- materials bought (SDD 128), FULL_DAYS; matBuysOld = older cost
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

-- Purchases not disenchanted keep at most this many over all items, the oldest dropped first, with a Log line
-- (Util.Dropped); they also go after Ledger.EXPIRE_AFTER. Disenchants, sales and posts are rolled up instead
-- (Ledger.Archive, SDD 126); auction-house purchases seen go after EXPIRE_AFTER, at most Ledger.MAX_FULL.
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
local bandKeys = {}   -- (made once each: every list of records asks per record)
function Ledger.BandKey(quality, classID, band)
    local kind = classID == Data.CLASS_WEAPON and "w" or "a"
    local id = tostring(quality or 0) .. kind .. tostring(band or 0)
    local key = bandKeys[id]
    if not key then
        key = string.format("%d:%s:%d", quality or 0, kind, band or 0)
        bandKeys[id] = key
    end
    return key
end

--- quality, classID, band from a Ledger.BandKey.
function Ledger.BandOf(key)
    local q, c, band = tostring(key):match("^(%d+):(%a):(%d+)$")
    if not q then return nil end
    return tonumber(q), c == "w" and Data.CLASS_WEAPON or Data.CLASS_ARMOR, tonumber(band)
end

Ledger.JOINT_COST = 1   -- state.jointCost is this once the costs are shared per band (Ledger.Recost)

-- The archive (SDD 126): records older than FULL_DAYS (or past MAX_FULL of their kind) rolled up per day.
--   d = { bucket of disenchants: one day (or, past DAY_DAYS, one 30-day period), band, Salvager or not, item }
--   s = { bucket of sales: one day (or period), material, kind (a sale, or the deposit lost: `lost`) }
--   head = { [matID] = units }: units of rolled-up disenchants no post or sale took yet (Ledger.Batch takes them first)
--   upTo = time: every disenchant, sale and post before it is rolled up (posts dropped)
function Ledger.NewArchive() return { d = {}, s = {}, head = {}, upTo = 0 } end

-- A record's weight by age as a number that does not change with time (`e`): 2^((t - EPOCH) / half-life). Times
-- decayNow(now) it is the record's weight now: Model.Decay continuous (half a day added: within 1.2 % of it).
local DECAY_EPOCH = 1700000000
local function eOf(t) return 2 ^ (((t or 0) - DECAY_EPOCH) / (Model.HALF_LIFE_DAYS * 86400)) end
local function decayNow(now)
    return 2 ^ (-((now or 0) - DECAY_EPOCH) / (Model.HALF_LIFE_DAYS * 86400) + 0.5 / Model.HALF_LIFE_DAYS)
end
local function archived(state, kind) return state.archive and state.archive[kind] or {} end

function Ledger.Init(state)
    -- A new ledger has no double sales from old versions to repair, and no costs to share again.
    if next(state) == nil then
        state.doubleSalesFixed = Ledger.DOUBLES_REPAIR
        state.jointCost = Ledger.JOINT_COST
        state.other = 0
    end
    state.purchases = state.purchases or {}
    state.stock = state.stock or {}
    state.pools = state.pools or {}
    state.disenchants = state.disenchants or {}
    state.sales = state.sales or {}
    state.bought = state.bought or {}
    state.matBuys = state.matBuys or {}
    state.seenSold = state.seenSold or {}
    state.archive = state.archive or Ledger.NewArchive()
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
    Ledger.CapPurchases(state)
end

--- Keeps at most Ledger.MAX_RECORDS purchases over all items: past it the oldest go (each item's list is oldest
--- first), reported (Util.Dropped). @return number purchases dropped
function Ledger.CapPurchases(state)
    local n = 0
    for _, list in pairs(state.purchases) do n = n + #list end
    local extra = n - Ledger.MAX_RECORDS
    if extra <= 0 then return 0 end
    for _ = 1, extra do
        local oldest
        for itemID, list in pairs(state.purchases) do
            local p = list[1]
            if p and (not oldest or (p.t or 0) < (state.purchases[oldest][1].t or 0)
                or ((p.t or 0) == (state.purchases[oldest][1].t or 0) and itemID < oldest)) then
                oldest = itemID
            end
        end
        Ledger.TakePurchase(state, oldest)
    end
    Util.Dropped("purchases not disenchanted", extra, Ledger.MAX_RECORDS)
    return extra
end

--- A purchase seen at the auction house. The "Auction won" mail for it comes later
--- and is matched by Ledger.MailPurchase, so nothing counts twice.
function Ledger.AuctionPurchase(state, itemID, total, ev, t, link, judged)
    Ledger.AddPurchase(state, itemID, 1, total, ev, t, link, judged)
    state.bought[#state.bought + 1] = { itemID = itemID, each = total, t = t }
    Util.Cap(state.bought, Ledger.MAX_FULL, "auction-house purchases seen")
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
--- The purchases seen at the auction house whose "Auction won" mail is not taken yet, and the purchase records they
--- match ({ [record] = true }).
local function inMail(state)
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
    return out, used
end

function Ledger.NotPickedUp(state)
    local out = inMail(state)
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

--- Materials bought at the auction house (SDD 128): `qty` units for `cost` copper in all enter stock at that cost,
--- outside the band pools (they come from no disenchant). The record stays Ledger.FULL_DAYS; older ones keep only
--- their cost (`matBuysOld`), so the books' check (Ledger.Books) still counts them. @return table the record
function Ledger.BuyMaterial(state, matID, qty, cost, t)
    Ledger.AddStock(state, matID, qty, cost)
    local list = state.matBuys or {}
    state.matBuys = list
    local rec = { t = t, id = matID, qty = qty, cost = cost }
    list[#list + 1] = rec
    local cutoff = (t or 0) - Ledger.FULL_DAYS * 86400
    while list[1] and (list[1].t or 0) < cutoff do
        state.matBuysOld = (state.matBuysOld or 0) + (table.remove(list, 1).cost or 0)
    end
    return rec
end

--- What was paid for every material bought (Ledger.BuyMaterial), the old ones too.
function Ledger.MaterialsBought(state)
    local n = state.matBuysOld or 0
    for _, r in ipairs(state.matBuys or {}) do n = n + (r.cost or 0) end
    return n
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
    -- (The books: the change of this material's cost came from outside the records.)
    local before = state.stock[matID] and state.stock[matID].cost or 0
    if state.other then state.other = state.other + math.max(0, qty) * (each or 0) - before end
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
---   - the books are kept: the units no record explains (the rest of the sales, the stock outside the pools) carry
---     what the books held beyond the pools, so the sales' and the stock's cost add up to `target` (default: what
---     they added up to before), to the copper (SDD 125; up to 0.4.0 this step was missing and the 0.3.120 replay
---     made 13s 51c of cost on the user's data). Their parts are shared by their cost, largest remainder.
--- The stock's counts (known and unknown) do not change. Disenchant records lose `shares`.
--- @return number disenchants pooled, number sales booked again, number cost that found no unit to sit on (the
---   books' `other` takes it), table moved: { { i = sale index | id = material, d = copper moved by the keep step } }
-- Each material's known units outside the band pools, and their cost: { [matID] = { qty, cost } }.
local function outsideOf(state)
    local out = {}
    for id, s in pairs(state.stock) do
        local qty, cost = s.qty - (s.unknown or 0), s.cost or 0
        for _, p in pairs(state.pools) do
            local m = p.mats[id]
            if m then qty, cost = qty - m.qty, cost - m.cost end
        end
        out[id] = { qty = qty, cost = cost }
    end
    return out
end

--- `outside` (optional): the known units outside the pools before the replay and their cost (outsideOf); by default
--- as the ledger is now. Outside units keep that cost (all of it while as many are left; a ledger with no pools yet
--- has all its known units outside: the old average).
function Ledger.Recost(state, outside, target)
    outside = outside or outsideOf(state)
    target = target or Ledger.Booked(state)
    local old = state.stock
    local parts = {}   -- the units no record explains: { { sale | id, c } }
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
                local restCost = math.floor((r.cost or 0) * rest / tracked + 0.5)
                r.cost = fromPools + restCost
                if rest > 0 then parts[#parts + 1] = { i = e.i, r = r, c = restCost, u = rest } end
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
    -- The known units outside the pools keep the cost they had outside them (the old average).
    for id, s in pairs(old) do
        local known = s.qty - (s.unknown or 0)
        local w = work.stock[id]
        local inPools, poolCost = w and w.qty or 0, w and w.cost or 0
        local out, o = known - inPools, outside[id]
        local kept = 0
        if o and o.qty > 0 and out > 0 then
            kept = out >= o.qty and o.cost or math.floor(o.cost * out / o.qty + 0.5)
        end
        s.cost = poolCost + kept
        if out > 0 then parts[#parts + 1] = { id = id, s = s, c = kept, u = out } end
    end
    state.pools = work.pools
    state.jointCost = Ledger.JOINT_COST
    -- Keep the books: what the replay booked over or under `target` moves onto the units no record explains.
    local diff, moved = target - Ledger.Booked(state), {}
    if diff ~= 0 and #parts > 0 then
        local keys, weight, sum, units = {}, {}, 0, 0
        for k, x in ipairs(parts) do keys[k], sum, units = k, sum + x.c, units + x.u end
        for k, x in ipairs(parts) do weight[k] = sum > 0 and x.c or x.u end
        if sum + diff >= 0 then
            local share = split(sum + diff, keys, weight)
            for k, x in ipairs(parts) do
                local d = share[k] - x.c
                if d ~= 0 then
                    if x.r then
                        x.r.cost = x.r.cost + d
                        if x.r.net then splitNet(x.r) end
                    else
                        x.s.cost = x.s.cost + d
                    end
                    moved[#moved + 1] = { i = x.i, id = x.id, d = d }
                end
            end
            diff = 0
        end
    end
    return nd, nsales, -diff, moved
end

--- What the books hold: the cost of every booked sale (rolled up ones too) plus the cost of the stock.
function Ledger.Booked(state)
    local n = 0
    for _, s in ipairs(state.sales) do n = n + (s.cost or 0) end
    for _, b in ipairs(state.archive and state.archive.s or {}) do n = n + (b.cost or 0) end
    for _, s in pairs(state.stock) do n = n + (s.cost or 0) end
    return n
end

--- What the disenchants with a known cost were paid (rolled up ones too).
function Ledger.Paid(state)
    local n = 0
    for _, r in ipairs(state.disenchants) do if r.costKnown then n = n + (r.cost or 0) end end
    for _, b in ipairs(state.archive and state.archive.d or {}) do n = n + (b.paid or 0) end
    return n
end

--- The books' check (SDD 125): what was paid for the gear disenchanted, plus what was paid for materials bought
--- (`bought`, SDD 128), plus `other` (the cost of known units that came or went outside the records: opening stock, a
--- cleared history, units gone with no record), is the cost of every booked sale plus the cost of the stock, to the
--- copper. `off` = what is not explained (0 when they hold).
--- @return table { paid, bought, other, sold (booked sale cost), stock, off }
function Ledger.Books(state)
    local sold, stock = 0, 0
    for _, x in ipairs(state.sales) do sold = sold + (x.cost or 0) end
    for _, b in ipairs(state.archive and state.archive.s or {}) do sold = sold + (b.cost or 0) end
    for _, x in pairs(state.stock) do stock = stock + (x.cost or 0) end
    local paid, bought, other = Ledger.Paid(state), Ledger.MaterialsBought(state), state.other or 0
    return { paid = paid, bought = bought, other = other, sold = sold, stock = stock,
        off = paid + bought + other - sold - stock }
end

--- Opens the books' `other` once on a ledger from before it was kept: what the books hold beyond what was paid
--- (known units from before the records). @return number|nil the amount, nil when it was kept already
function Ledger.OpenBooks(state)
    if state.other ~= nil then return nil end
    state.other = Ledger.Booked(state) - Ledger.Paid(state)
    return state.other
end

--- Repairs, once, what the 0.3.120 replay (Ledger.Recost before 0.4.0) booked too much or too little on the sales of
--- units no record explains: `backup` is the ledger copied before that replay; the replay with the keep step is run
--- on a copy of it, and each sale it moves, still as that replay left it in `state` (same time, material, units and
--- cost), moves the same. @return number sales repaired, number copper moved, number moves not applied
function Ledger.FixRecost(state, backup)
    local copy = Ledger.Init(Util.Copy(backup))
    if not Ledger.NeedsRecost(copy) then return 0, 0, 0 end
    local _, _, _, moved = Ledger.Recost(copy)
    local n, sum, missed = 0, 0, 0
    for _, m in ipairs(moved) do
        local a, b = m.i and copy.sales[m.i], m.i and state.sales[m.i]
        if a and b and a.t == b.t and a.id == b.id and a.count == b.count and b.cost == a.cost - m.d then
            b.cost = a.cost
            if b.net then splitNet(b) end
            n, sum = n + 1, sum + m.d
        else
            missed = missed + 1
        end
    end
    return n, sum, missed
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
    -- (The books: the stock stays with its cost, the records of where it came from go.)
    local paid, booked = Ledger.Paid(state), Ledger.Booked(state)
    state.disenchants, state.sales, state.bought = {}, sales, bought
    state.archive = Ledger.NewArchive()
    if state.other then state.other = state.other + paid - (booked - Ledger.Booked(state)) end
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
--- they were), and sales whose money was never seen taken (they count as paid); and the record of auction-house
--- purchases whose mail matched (kept that long for the repair of 0.4.0, SDD 124).
--- @return number bought, number purchases, number sales, number bought records whose mail matched
function Ledger.Expire(state, now)
    local cutoff = now - Ledger.EXPIRE_AFTER
    local nb, np, ns_ = 0, 0, 0
    local nm = 0
    for i = #state.bought, 1, -1 do
        local b = state.bought[i]
        if (b.t or 0) < cutoff then
            table.remove(state.bought, i)
            if b.mail then nm = nm + 1 else nb = nb + 1 end
        end
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
    return nb, np, ns_, nm
end

--- Per item, the purchases the auction house record (`bought`) has that no record accounts for: not in `purchases`
--- (same time and price each) and not taken by a disenchant with a known cost (its purchase's time and price; one
--- with neither takes the oldest left bought at or before it). Versions up to 0.4.0 kept 50 purchases per item and
--- dropped the older ones without a word. Only those of the last EXPIRE_AFTER count. Then, first in, first out as
--- TakePurchase would have, which disenchants of no known cost of that item they pay for (each made at or after its
--- purchase), and the ones left (not disenchanted). `skip(itemID)` (optional): items left out (ClearHistory's `drop`:
--- their purchases went on purpose).
--- @return table { { itemID, missing, give = { { r = disenchant, b = bought }, ... }, left = { bought, ... },
---   fallback (disenchants matched by count) }, ... } by item ID
function Ledger.DroppedPurchases(state, now, skip)
    -- (The repair replays the records: not once some are rolled up.)
    if state.archive and #state.archive.d > 0 then return {} end
    local cutoff = now - Ledger.EXPIRE_AFTER
    local function order(a, c)
        if (a.x.t or 0) ~= (c.x.t or 0) then return (a.x.t or 0) < (c.x.t or 0) end
        return a.i < c.i
    end
    local bought, dis = {}, {}
    for i, b in ipairs(state.bought) do
        if b.itemID and b.each and not (skip and skip(b.itemID)) then
            bought[b.itemID] = bought[b.itemID] or {}
            table.insert(bought[b.itemID], { x = b, i = i })
        end
    end
    for i, r in ipairs(state.disenchants) do
        if r.itemID and bought[r.itemID] then
            dis[r.itemID] = dis[r.itemID] or {}
            table.insert(dis[r.itemID], { x = r, i = i })
        end
    end
    local out = {}
    for itemID, list in pairs(bought) do
        table.sort(list, order)
        local used = {}
        local function take(match)
            for k, e in ipairs(list) do
                if not used[k] and match(e.x) then used[k] = true return true end
            end
            return false
        end
        for _, p in ipairs(state.purchases[itemID] or {}) do
            take(function(b) return b.t == p.t and b.each == p.each end)
        end
        local mine = dis[itemID] or {}
        table.sort(mine, order)
        local unmatched, unknown = {}, {}
        for _, e in ipairs(mine) do
            local r = e.x
            if not r.costKnown then
                unknown[#unknown + 1] = r
            elseif not take(function(b) return b.t == r.boughtAt and b.each == r.cost end) then
                unmatched[#unmatched + 1] = r
            end
        end
        for _, r in ipairs(unmatched) do take(function(b) return (b.t or 0) <= (r.t or 0) end) end
        local missing = {}
        for k, e in ipairs(list) do
            if not used[k] and (e.x.t or 0) >= cutoff then missing[#missing + 1] = e.x end
        end
        if #missing > 0 then
            local give, k = {}, 1
            for _, r in ipairs(unknown) do
                local b = missing[k]
                if b and (b.t or 0) <= (r.t or 0) then
                    give[#give + 1] = { r = r, b = b }
                    k = k + 1
                end
            end
            local left = {}
            for j = k, #missing do left[#left + 1] = missing[j] end
            out[#out + 1] = { itemID = itemID, missing = #missing, give = give, left = left, fallback = #unmatched }
        end
    end
    table.sort(out, function(a, b) return a.itemID < b.itemID end)
    return out
end

--- Restores the purchases Ledger.DroppedPurchases finds, once (SDD 124): each disenchant it pays for gets its cost
--- (`costRestored`), its units become units of known cost (a later sale that sold units of no known cost of that
--- material sold these first, oldest first: its untracked units become tracked), the purchases left go back into
--- `purchases`; then every cost is shared per band again (Ledger.Recost): stock costs, break-evens and every booked
--- sale's cost follow (SDD 4: booked sales are booked again only in such a one-time repair).
--- @return table { items = { { itemID, link, restored, costed, back, cost } }, restored, costed, back, cost,
---   shifted (sale units now tracked), gone (units no longer in stock: their cost went with them), sales (sales whose
---   cost changed), profitBefore, profitAfter }
function Ledger.RestorePurchases(state, now, skip)
    local plan = Ledger.DroppedPurchases(state, now, skip)
    local rep = { items = {}, restored = 0, costed = 0, back = 0, cost = 0, shifted = 0, gone = 0, sales = 0,
        profitBefore = 0, profitAfter = 0 }
    if #plan == 0 then return rep end
    local before = {}
    for i, s in ipairs(state.sales) do
        before[i] = s.cost
        rep.profitBefore = rep.profitBefore + (s.profit or 0)
    end
    local outside = outsideOf(state)   -- (before any unit changes)
    -- The replay of the books as they are (A): the repair's effect on each sale and material is what the replay with
    -- it (B) books more or less than A, so whatever the replay does not reproduce of the live books (records long
    -- gone, a cost booked by an older rule) stays as booked.
    local A = Util.Copy({ stock = state.stock, pools = state.pools, disenchants = state.disenchants, sales = state.sales })
    Ledger.Recost(A, outside)
    local paid0, booked0 = Ledger.Paid(state), Ledger.Booked(state)
    local liveSales, liveStock = {}, {}
    for i, s in ipairs(state.sales) do liveSales[i] = s.cost or 0 end
    for id, s in pairs(state.stock) do liveStock[id] = s.cost or 0 end
    local known = {}                   -- [matID] = { { t, qty }, ... }: the units that now have a known cost
    for _, it in ipairs(plan) do
        local link
        for _, r in ipairs(state.disenchants) do if r.itemID == it.itemID and r.link then link = r.link break end end
        local row = { itemID = it.itemID, link = link, restored = it.missing, costed = #it.give, back = #it.left, cost = 0 }
        for _, g in ipairs(it.give) do
            local r = g.r
            r.cost, r.costKnown, r.boughtAt, r.costRestored = g.b.each, true, g.b.t, true
            row.cost = row.cost + g.b.each
            for id, qty in pairs(r.got or {}) do
                known[id] = known[id] or {}
                table.insert(known[id], { t = r.t or 0, qty = qty })
            end
        end
        local list = state.purchases[it.itemID] or {}
        state.purchases[it.itemID] = list
        for _, b in ipairs(it.left) do list[#list + 1] = { each = b.each, t = b.t, link = link } end
        table.sort(list, function(a, b) return (a.t or 0) < (b.t or 0) end)
        if #list == 0 then state.purchases[it.itemID] = nil end
        rep.items[#rep.items + 1] = row
        rep.restored, rep.costed, rep.back, rep.cost = rep.restored + row.restored, rep.costed + row.costed,
            rep.back + row.back, rep.cost + row.cost
    end
    for id, units in pairs(known) do
        table.sort(units, function(a, b) return a.t < b.t end)
        local total = 0
        for _, u in ipairs(units) do total = total + u.qty end
        local sales = {}
        for i, s in ipairs(state.sales) do
            if s.id == id and not s.lost and (s.untracked or 0) > 0 then sales[#sales + 1] = { s = s, i = i } end
        end
        table.sort(sales, function(a, b)
            if (a.s.t or 0) ~= (b.s.t or 0) then return (a.s.t or 0) < (b.s.t or 0) end
            return a.i < b.i
        end)
        local k, avail, shifted = 1, 0, 0
        for _, e in ipairs(sales) do
            while units[k] and units[k].t <= (e.s.t or 0) do avail, k = avail + units[k].qty, k + 1 end
            local n = math.min(avail, e.s.untracked)
            e.s.untracked, avail, shifted = e.s.untracked - n, avail - n, shifted + n
        end
        local s = state.stock[id]
        local flip = math.min(total - shifted, s and s.unknown or 0)
        if s then s.unknown = s.unknown - flip end
        rep.shifted, rep.gone = rep.shifted + shifted, rep.gone + (total - shifted - flip)
    end
    Ledger.CapPurchases(state)
    -- (What the replay with the repair must book: the books as they were, plus the cost the repair found.)
    Ledger.Recost(state, outside, booked0 + rep.cost)
    for i, s in ipairs(state.sales) do
        s.cost = liveSales[i] + (s.cost or 0) - (A.sales[i].cost or 0)
        if s.net and not s.lost then splitNet(s) end
        if s.cost ~= before[i] then rep.sales = rep.sales + 1 end
        rep.profitAfter = rep.profitAfter + (s.profit or 0)
    end
    rep.replayed = true   -- the replay of the books as they were matched them (stock costs)
    for id, s in pairs(state.stock) do
        local a = A.stock[id] and A.stock[id].cost or 0
        if a ~= liveStock[id] then rep.replayed = false end
        s.cost = liveStock[id] + s.cost - a
    end
    -- (The books: cost that found no unit to sit on, units gone from stock with no record.)
    if state.other then state.other = state.other + (Ledger.Booked(state) - booked0) - (Ledger.Paid(state) - paid0) end
    return rep
end

--- The deposit of an auction that expired or was cancelled: the auction house keeps it.
--- Booked as a sale record of no units with the deposit as its loss (`lost` = "expired" | "cancelled"),
--- so the sales history, the totals and the Profit view count it. Accuracy leaves it out.
function Ledger.DepositLost(state, matID, qty, amount, why, t)
    local rec = { t = t, id = matID, count = 0, qty = qty, gross = 0, cut = 0, net = -amount, cost = 0,
        untracked = 0, netUntracked = 0, profit = -amount, lost = why, paidAt = t }
    state.sales[#state.sales + 1] = rec
    return rec
end

-- The forecast learns from your own sales, each weighted by its age (Model.Decay: half after 30 days, SDD 118); a
-- material whose sales weigh less than FORECAST_MIN_SALES leans on all materials together, and with none at all on
-- the default (SDD 3, 96).
Ledger.FORECAST_MIN_SALES = 5

-- Every sale with its weight by age.
local function weightedSales(state, now)
    local out = {}
    for _, s in ipairs(state.sales) do
        out[#out + 1] = { s = s, w = Model.Decay((now or 0) - (s.t or 0)) }
    end
    return out
end

--- The sell price ratio per material: what one unit really sold for (the sale price, before the cut) against
--- the material's value (SDD 3) when it was posted. The median of your recent sales, by units; a material with
--- few sales is pulled toward the median of all materials, and that one toward 1 while it has few sales.
--- @param valueAt function(sale) -> the material's value when that sale was posted (or at the sale), or nil;
---   used when the sale has no `val` of its own
--- Each sale weighs its units × its weight by age (Model.Decay); `n` is the weight of the sales (a sale today counts
--- 1, a month old 0.5), `count` the sales themselves.
--- @param opts table|nil { minSales }
--- @return table { [id] = { ratio, n (weight of its sales), count, units, measured (its own median), few },
---   all = { ratio, n, count } }
function Ledger.SellRatios(state, valueAt, now, opts)
    opts = opts or {}
    local floor = opts.minSales or Ledger.FORECAST_MIN_SALES
    local per, all, nAll = {}, {}, 0
    for _, e in ipairs(weightedSales(state, now)) do
        local s = e.s
        if not s.lost and (s.count or 0) > 0 and (s.gross or 0) > 0 then
            local v = s.val or (valueAt and valueAt(s))
            if v and v > 0 then
                local each = s.each or (s.gross / s.count)
                local x = { r = each / v, w = s.count * e.w, units = s.count, age = e.w }
                per[s.id] = per[s.id] or {}
                table.insert(per[s.id], x)
                all[#all + 1] = x
                nAll = nAll + e.w
            end
        end
    end
    -- The rolled-up sales: one sample per ratio of each day (`k` sales).
    local D = decayNow(now)
    for _, b in ipairs(archived(state, "s")) do
        for _, x in pairs(b.ratios or {}) do
            local one = { r = x.r, w = x.eu * D, units = x.u, age = x.e * D, k = x.n }
            per[b.id] = per[b.id] or {}
            table.insert(per[b.id], one)
            all[#all + 1] = one
            nAll = nAll + one.age
        end
    end
    local function count(list)
        local n = 0
        for _, x in ipairs(list) do n = n + (x.k or 1) end
        return n
    end
    local prior = Model.Blend(Model.WeightedMedian(all), nAll, 1, floor)
    local out = { all = { ratio = prior, n = nAll, count = count(all) } }
    for id, list in pairs(per) do
        local units, n = 0, 0
        for _, x in ipairs(list) do units, n = units + x.units, n + x.age end
        local measured = Model.WeightedMedian(list)
        out[id] = { ratio = Model.Blend(measured, n, prior, floor), n = n, count = count(list), units = units,
            measured = measured, few = n < floor }
    end
    return out
end

--- Deposits lost per unit sold, per material, as a share of the deposit of one post (`k`): k = lost deposits ÷
--- (units sold × deposit of one unit). A material with few sales is pulled toward all materials together, and that
--- toward 1 (one post's deposit lost per unit sold) while it has few sales.
--- @param unitDeposit function(id) -> the deposit of one unit in one post, copper, or nil when not known
--- Lost deposits, units sold and sales weigh their weight by age (Model.Decay); `n` is the weight of the sales.
--- @param opts table|nil { minSales }
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
    for _, e in ipairs(weightedSales(state, now)) do
        local s = e.s
        if s.lost then
            local m = mat(s.id)
            m.lost = m.lost - (s.net or 0) * e.w
        elseif (s.count or 0) > 0 then
            local m = mat(s.id)
            m.sold, m.n = m.sold + s.count * e.w, m.n + e.w
        end
    end
    local D = decayNow(now)
    for _, b in ipairs(archived(state, "s")) do
        local m = mat(b.id)
        if b.lost then
            m.lost = m.lost + (b.elost or 0) * D
        elseif (b.count or 0) > 0 then
            m.sold, m.n = m.sold + (b.eu or 0) * D, m.n + (b.e or 0) * D
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

--- Your results per band and Salvager state, for the blend with the table (SDD 99, Model.Blended). Each disenchant
--- weighs its weight by age (Model.Decay, SDD 118): `n`, `hits` and `qty` are weights, `count` the disenchants.
--- @return table { [bandKey] = { on = seen, off = seen } },
---   seen = { n, count, mats = { [id] = { hits, qty = { [q] = weight } } } }
function Ledger.Results(state, now)
    local out = {}
    for _, r in ipairs(state.disenchants) do
        if r.got and next(r.got) and r.quality and r.classID and r.band then
            local w = Model.Decay((now or 0) - (r.t or 0))
            local key = Ledger.BandKey(r.quality, r.classID, r.band)
            local b = out[key] or { on = { n = 0, count = 0, mats = {} }, off = { n = 0, count = 0, mats = {} } }
            out[key] = b
            local seen = r.salvager and b.on or b.off
            seen.n, seen.count = seen.n + w, seen.count + 1
            for id, qty in pairs(r.got) do
                local m = seen.mats[id] or { hits = 0, qty = {} }
                seen.mats[id] = m
                m.hits = m.hits + w
                m.qty[qty] = (m.qty[qty] or 0) + w
            end
        end
    end
    local D = decayNow(now)
    for _, a in ipairs(archived(state, "d")) do
        if (a.ng or 0) > 0 and a.quality and a.classID and a.band then
            local key = Ledger.BandKey(a.quality, a.classID, a.band)
            local b = out[key] or { on = { n = 0, count = 0, mats = {} }, off = { n = 0, count = 0, mats = {} } }
            out[key] = b
            local seen = a.salvager and b.on or b.off
            seen.n, seen.count = seen.n + a.eg * D, seen.count + a.ng
            for id, am in pairs(a.mats) do
                local m = seen.mats[id] or { hits = 0, qty = {} }
                seen.mats[id] = m
                for qty, e in pairs(am.eq) do
                    m.hits = m.hits + e * D
                    m.qty[qty] = (m.qty[qty] or 0) + e * D
                end
            end
        end
    end
    return out
end

--- Your results per material kind and Salvager state, at their place in the table's range of their band (SDD 118,
--- Model.LearnedShape): a result of a material the band's table gives with m values (lo..hi) is at position
--- quantity − lo, from 0 to m (one more than the table at the top; more than that counts as one more). Weighted by
--- age (Model.Decay). A material the band's table does not have is left out.
--- @return table { on = { [kind] = { n (weight), count, cells = { [m] = { [position] = weight } } } }, off = same }
function Ledger.Shapes(state, now)
    local out = { on = {}, off = {} }
    local tables = {}   -- (each band's table once: Model.Outcomes builds a new one per call)
    for _, r in ipairs(state.disenchants) do
        local o
        if r.got and r.quality and r.classID and r.band then
            local key = r.quality .. ":" .. r.classID .. ":" .. r.band
            if tables[key] == nil then tables[key] = Model.Outcomes(r.quality, r.classID, r.band) or false end
            o = tables[key] or nil
        end
        if o then
            local w = Model.Decay((now or 0) - (r.t or 0))
            local side = out[r.salvager and "on" or "off"]
            for id, qty in pairs(r.got) do
                local res
                for _, x in ipairs(o.results) do if x.id == id then res = x end end
                local mat = Data.MATERIAL_BY_ID[id]
                if res and mat then
                    local m = res.max - res.min + 1
                    local j = math.min(m, math.max(0, qty - res.min))
                    local k = side[mat.kind] or { n = 0, count = 0, cells = {} }
                    side[mat.kind] = k
                    k.cells[m] = k.cells[m] or {}
                    k.cells[m][j] = (k.cells[m][j] or 0) + w
                    k.n, k.count = k.n + w, k.count + 1
                end
            end
        end
    end
    -- The rolled-up disenchants: each quantity of each material with its weight and count.
    local D = decayNow(now)
    for _, a in ipairs(archived(state, "d")) do
        local o
        if a.quality and a.classID and a.band then
            local key = a.quality .. ":" .. a.classID .. ":" .. a.band
            if tables[key] == nil then tables[key] = Model.Outcomes(a.quality, a.classID, a.band) or false end
            o = tables[key] or nil
        end
        if o then
            local side = out[a.salvager and "on" or "off"]
            for id, am in pairs(a.mats) do
                local res
                for _, x in ipairs(o.results) do if x.id == id then res = x end end
                local mat = Data.MATERIAL_BY_ID[id]
                if res and mat then
                    local m = res.max - res.min + 1
                    local k = side[mat.kind] or { n = 0, count = 0, cells = {} }
                    side[mat.kind] = k
                    k.cells[m] = k.cells[m] or {}
                    for qty, e in pairs(am.eq) do
                        local j = math.min(m, math.max(0, qty - res.min))
                        k.cells[m][j] = (k.cells[m][j] or 0) + e * D
                        k.n, k.count = k.n + e * D, k.count + am.nq[qty]
                    end
                end
            end
        end
    end
    return out
end

Ledger.MAIL_DELAY = 3600   -- a sold auction's money comes about this long after the sale (SDD 97c)

--- The posts of each material, in the order of `posted` (postTime reads one material's only).
local function postsByItem(posted)
    local by = {}
    for _, p in ipairs(posted or {}) do
        if p.itemID then
            by[p.itemID] = by[p.itemID] or {}
            by[p.itemID][#by[p.itemID] + 1] = p
        end
    end
    return by
end

--- The post a sale came from: its `postedAt`, else the last post of that material at that price each made at or
--- before the sale. `byItem`: postsByItem(posted). @return number|nil the time of the post
local function postTime(s, byItem, soldAt)
    if s.postedAt then return s.postedAt end
    local each = s.each or (s.gross / s.count)
    local mine = byItem[s.id] or {}
    for i = #mine, 1, -1 do
        local p = mine[i]
        if p.each and math.abs(p.each - each) < 1 and (p.t or 0) <= soldAt then return p.t end
    end
    return nil
end

--- Time to sell per material (SDD 100): from the post to the sale, the median of your sales by units × their weight
--- by age (Model.Decay, SDD 118); `n` is the weight of the sales, `count` the sales. The sale is at its money's due
--- time less the mail delay when that is known, else when it was booked.
--- A material with few sales is pulled toward all materials together (as the sell price ratio, SDD 3).
--- Only sales of posts made through Salvager count (`SalvagerDB.posted`).
--- @param opts table|nil { minSales, mailDelay }
--- @return table { [id] = { seconds, n (weight of its sales), count, measured (its own median), few },
---   all = { seconds, n, count, few } (seconds nil without a sale) }
function Ledger.TimesToSell(state, posted, now, opts)
    opts = opts or {}
    local floor = opts.minSales or Ledger.FORECAST_MIN_SALES
    local delay = opts.mailDelay or Ledger.MAIL_DELAY
    local per, all, nAll = {}, {}, 0
    local byItem = postsByItem(posted)
    for _, e in ipairs(weightedSales(state, now)) do
        local s = e.s
        if not s.lost and (s.count or 0) > 0 and (s.gross or 0) > 0 then
            local soldAt = s.t or 0
            if s.due then soldAt = math.min(soldAt, s.due - delay) end
            local at = postTime(s, byItem, soldAt)
            if at then
                local x = { r = math.max(0, soldAt - at), w = s.count * e.w, age = e.w }
                per[s.id] = per[s.id] or {}
                table.insert(per[s.id], x)
                all[#all + 1] = x
                nAll = nAll + e.w
            end
        end
    end
    local D = decayNow(now)
    for _, b in ipairs(archived(state, "s")) do
        for _, x in pairs(b.times or {}) do
            local one = { r = x.r, w = x.eu * D, age = x.e * D, k = x.n }
            per[b.id] = per[b.id] or {}
            table.insert(per[b.id], one)
            all[#all + 1] = one
            nAll = nAll + one.age
        end
    end
    local function count(list)
        local n = 0
        for _, x in ipairs(list) do n = n + (x.k or 1) end
        return n
    end
    local allMedian = Model.WeightedMedian(all)
    local out = { all = { seconds = allMedian, n = nAll, count = count(all), few = nAll < floor } }
    for id, list in pairs(per) do
        local n = 0
        for _, x in ipairs(list) do n = n + x.age end
        local measured = Model.WeightedMedian(list)
        out[id] = { seconds = Model.Blend(measured, n, allMedian or measured, floor), n = n, count = count(list),
            measured = measured, few = n < floor }
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
    for _, s in ipairs(archived(state, "s")) do
        if not s.lost and (s.count or 0) > 0 then
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
    -- A disenchant record, or a rolled-up day of them (`a`: n, known, paid, kvalue, mats).
    local function add(r, a)
        if a then
            for id, m in pairs(a.mats) do mat(id).got = mat(id).got + m.u end
        else
            for id, qty in pairs(r.got or {}) do mat(id).got = mat(id).got + qty end
        end
        if (a and a.known > 0) or (not a and r.costKnown) then
            local soldValue = 0
            if a then
                for id, m in pairs(a.mats) do
                    local e = each[id]
                    soldValue = soldValue + ((e and e.units > 0) and (m.ku * e.net / e.units) or m.kv)
                end
            else
                for id, qty in pairs(r.got or {}) do
                    local e = each[id]
                    soldValue = soldValue + ((e and e.units > 0) and (qty * e.net / e.units) or (r.vals and r.vals[id] or 0))
                end
            end
            local n, paid, value = 1, r.cost or 0, r.value or 0
            if a then n, paid, value = a.known, a.paid, a.kvalue end
            local quality, classID = r.quality, r.classID
            local gkey = (quality or 0) .. ":" .. (classID or 0)
            local g = groups[gkey]
            if not g then
                g = sums({ quality = quality, classID = classID, bands = {} })
                groups[gkey] = g
                out.groups[#out.groups + 1] = g
            end
            local bkey = Ledger.BandKey(quality, classID, r.band)
            local b = bands[bkey]
            if not b then
                b = sums({ quality = quality, classID = classID, band = r.band })
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
                x.n = x.n + n
                x.paid = x.paid + paid
                x.value = x.value + value
                x.sold = x.sold + soldValue
                if r.salvager then x.salvager = x.salvager + n end
            end
        end
    end
    for _, r in ipairs(state.disenchants) do
        if inTime(r.t) and (not keep or keep(r)) then add(r) end
    end
    for _, a in ipairs(archived(state, "d")) do
        if inTime(a.ts / a.n) and (not keep or keep(a)) then add(a, a) end
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
    for _, s in ipairs(archived(state, "s")) do
        if inTime(s.ts / s.n) then
            local m = mat(s.id)
            if s.lost then
                m.depositsLost = m.depositsLost - (s.net or 0)
            else
                m.sold, m.net, m.cost = m.sold + s.count, m.net + s.net, m.cost + s.cost
                m.untracked = m.untracked + s.untracked
            end
            m.profit = m.profit + s.profit
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
    for _, a in ipairs(archived(state, "d")) do
        if a.known > 0 then
            local key = Ledger.BandKey(a.quality, a.classID, a.band)
            local b = bands[key] or { paid = 0, value = 0, units = 0 }
            bands[key] = b
            b.paid = b.paid + a.paid
            for _, m in pairs(a.mats) do b.value, b.units = b.value + m.kv, b.units + m.ku end
        end
    end
    -- (`r`: a disenchant, or a rolled-up day of them: its known part.)
    return function(r, id)
        local a = r.mats and r
        if (a and a.known == 0) or (not a and not r.costKnown) then return nil end
        local b = bands[Ledger.BandKey(r.quality, r.classID, r.band)]
        local qty = a and (a.mats[id] and a.mats[id].ku or 0) or (r.got and r.got[id] or 0)
        local val = a and (a.mats[id] and a.mats[id].kv or 0) or ((r.vals and r.vals[id]) or 0)
        if b.value > 0 then return val * b.paid / b.value end
        return b.units > 0 and qty * b.paid / b.units or 0
    end
end

--- The current batch (SDD 107): the gear you bought and picked up that is not disenchanted yet, and the
--- disenchants of bought gear whose materials are not all posted yet.
--- Gone units: each post through Salvager (`posted`: itemID, qty, t), and each sale that came from no such post
--- (posted another way: at the sale), in time order, takes that material's units of the disenchants made at or
--- before it, first in, first out. Then `held` caps it: a material's units left, newest disenchant first, are at
--- most what you hold of it (converted, mailed, posted another way and not sold yet: gone too); a gear's purchases
--- left, newest first, at most the pieces you hold. A post that expires or is cancelled stays posted.
--- @param posted table|nil  SalvagerDB.posted
--- @param held function|nil  (itemID) -> units in the bags and the bank, or nil where not known (no cap)
--- `mail`: the purchases made with Buy whose "Auction won" mail is not taken yet (0.3.153, the user): part of the
--- batch, though not in the bags.
--- @return table { mail = { { itemID, link, each, ev, t, j }, ... }, waiting = { same }, done = { { rec,
---   left = { [id] = units }, units }, ... } }, each newest first
local goneEvents
function Ledger.Batch(state, posted, held)
    posted = posted or {}
    local mailList, mailed = inMail(state)
    local mail = {}
    for _, b in ipairs(mailList) do
        mail[#mail + 1] = { itemID = b.itemID, link = b.link, each = b.each, ev = b.ev, t = b.t or 0, j = b.j }
    end
    table.sort(mail, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return a.itemID < b.itemID
    end)
    local waiting = {}
    for itemID, list in pairs(state.purchases) do
        local mine = {}
        for _, p in ipairs(list) do if not mailed[p] then mine[#mine + 1] = p end end
        local cap = held and held(itemID)
        for i = (cap and math.max(1, #mine - cap + 1) or 1), #mine do
            local p = mine[i]
            waiting[#waiting + 1] = { itemID = itemID, link = p.link, each = p.each, ev = p.ev, t = p.t or 0, j = p.j }
        end
    end
    table.sort(waiting, function(a, b)
        if a.t ~= b.t then return a.t > b.t end
        return a.itemID < b.itemID
    end)
    -- Each material's disenchants, oldest first, with the units of it not gone yet.
    local left, byMat = {}, {}
    for i, r in ipairs(state.disenchants) do
        for id, qty in pairs(r.got or {}) do
            left[r] = left[r] or {}
            left[r][id] = qty
            byMat[id] = byMat[id] or {}
            byMat[id][#byMat[id] + 1] = { r = r, i = i }
        end
    end
    for _, list in pairs(byMat) do
        table.sort(list, function(a, b)
            if (a.r.t or 0) ~= (b.r.t or 0) then return (a.r.t or 0) < (b.r.t or 0) end
            return a.i < b.i
        end)
    end
    -- What is gone since the archive's end: the rolled-up disenchants' units no post or sale took yet go first.
    local gone = goneEvents(state.sales, posted, state.archive and state.archive.upTo or 0, math.huge)
    local head = {}
    for id, n in pairs(state.archive and state.archive.head or {}) do head[id] = n end
    -- (First in, first out: the disenchants used up are always the first of their material's list, so each
    -- material's next one is kept and the used ones are not walked again.)
    local first = {}
    for _, g in ipairs(gone) do
        local n, list = g.n, byMat[g.id] or {}
        local fromHead = math.min(n, head[g.id] or 0)
        head[g.id], n = (head[g.id] or 0) - fromHead, n - fromHead
        local i = first[g.id] or 1
        while list[i] and left[list[i].r][g.id] <= 0 do i = i + 1 end
        first[g.id] = i
        while n > 0 and list[i] and (list[i].r.t or 0) <= g.t do
            local x = list[i]
            local take = math.min(n, left[x.r][g.id])
            left[x.r][g.id], n = left[x.r][g.id] - take, n - take
            i = i + 1
        end
    end
    if held then
        for id, list in pairs(byMat) do
            local cap = held(id)
            if cap then
                for i = #list, 1, -1 do
                    local r = list[i].r
                    local keep = math.min(cap, left[r][id])
                    left[r][id], cap = keep, cap - keep
                end
            end
        end
    end
    local done = {}
    for _, r in ipairs(state.disenchants) do
        if r.costKnown and left[r] then
            local units = 0
            for _, n in pairs(left[r]) do units = units + n end
            if units > 0 then done[#done + 1] = { rec = r, left = left[r], units = units } end
        end
    end
    table.sort(done, function(a, b) return (a.rec.t or 0) > (b.rec.t or 0) end)
    return { mail = mail, waiting = waiting, done = done }
end

--- What is gone of each material from `from` to `to` (not included), in time order: every post made through Salvager
--- (`posted`: itemID, qty, t), and every sale that came from no such post (posted another way: at the sale).
--- @return table { { id, n, t }, ... }
function goneEvents(sales, posted, from, to)
    local gone = {}
    local function inTime(t) return t >= from and t < to end
    for _, p in ipairs(posted) do
        if p.itemID and p.qty and inTime(p.t or 0) then gone[#gone + 1] = { id = p.itemID, n = p.qty, t = p.t or 0 } end
    end
    local byItem = postsByItem(posted)
    for _, sale in ipairs(sales) do
        if not sale.lost and sale.id and (sale.count or 0) > 0 and inTime(sale.t or 0)
            and not postTime(sale, byItem, sale.t or 0) then
            gone[#gone + 1] = { id = sale.id, n = sale.count, t = sale.t or 0 }
        end
    end
    table.sort(gone, function(a, b) return a.t < b.t end)
    return gone
end

--- What Ledger.History counts, without its order or its materials: { { itemID, paid, done, got }, ... } (the
--- Ledger's summary line reads only these, and History sorts and shares every disenchant's cost).
function Ledger.HistoryTotals(state)
    local out = {}
    for itemID, list in pairs(state.purchases) do
        for _, p in ipairs(list) do out[#out + 1] = { itemID = itemID, paid = p.each, done = false } end
    end
    for _, r in ipairs(state.disenchants) do
        out[#out + 1] = { itemID = r.itemID, paid = r.costKnown and r.cost or nil, done = true, got = r.value }
    end
    -- A rolled-up day: `n` disenchants, `nPaid` of them with a known cost.
    for _, a in ipairs(archived(state, "d")) do
        out[#out + 1] = { itemID = a.itemID, paid = a.known > 0 and a.paid or nil, done = true, got = a.value, n = a.n,
            nPaid = a.known }
    end
    return out
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
    for _, a in ipairs(archived(state, "d")) do
        local m = a.mats[matID]
        local item = source(byItem, out.items, a.itemID or 0, function() return { itemID = a.itemID, link = a.link } end)
        local band = source(byBand, out.bands, Ledger.BandKey(a.quality, a.classID, a.band),
            function() return { quality = a.quality, classID = a.classID, band = a.band } end)
        local share = m and a.known > 0 and shareOf(a, matID) or 0
        for _, x in ipairs({ item, band, out }) do
            if x ~= out then
                x.all, x.known, x.paid, x.got = x.all + a.n, x.known + a.known, x.paid + a.paid, x.got + a.kvalue
                if m then x.gave = x.gave + m.h end
            end
            if m then x.units, x.knownUnits, x.cost = x.units + m.u, x.knownUnits + m.ku, x.cost + share end
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

--- How well the promise held, in three steps: what the Gear list promised at the purchase, what the
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
    for _, list in ipairs({ state.sales, archived(state, "s") }) do
        for _, s in ipairs(list) do
            if not s.lost then
                local m = sold[s.id] or { units = 0, net = 0 }
                sold[s.id] = m
                m.units, m.net = m.units + s.count, m.net + s.net
            end
        end
    end
    local function blank(extra)
        local b = extra or {}
        b.n, b.paid, b.promised, b.got, b.sold, b.units, b.soldUnits = 0, 0, 0, 0, 0, 0, 0
        return b
    end
    local out = { bands = {}, total = blank(), mats = {} }
    local byBand, byMat = {}, {}
    -- (A disenchant with a known cost, or the known part of a rolled-up day: its materials as { [id] = { qty, at } }.)
    local function add(r, n, paid, promised, got, gave)
        local key = Ledger.BandKey(r.quality, r.classID, r.band)
        local b = byBand[key]
        if not b then
            b = blank({ quality = r.quality, classID = r.classID, band = r.band })
            byBand[key] = b
            out.bands[#out.bands + 1] = b
        end
        local soldValue, units, soldUnits = 0, 0, 0
        for id, g in pairs(gave) do
            local qty, at = g[1], g[2]
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
            x.n = x.n + n
            x.paid = x.paid + paid
            x.promised = x.promised + promised
            x.got = x.got + got
            x.sold = x.sold + soldValue
            x.units, x.soldUnits = x.units + units, x.soldUnits + soldUnits
        end
    end
    for _, r in ipairs(state.disenchants) do
        if r.costKnown and (not keep or keep(r)) then
            local gave = {}
            for id, qty in pairs(r.got or {}) do gave[id] = { qty, r.vals and r.vals[id] or 0 } end
            add(r, 1, r.cost or 0, r.evAtBuy or r.planned or 0, r.value or 0, gave)
        end
    end
    for _, a in ipairs(archived(state, "d")) do
        if a.known > 0 and (not keep or keep(a)) then
            local gave = {}
            for id, m in pairs(a.mats) do if m.ku > 0 then gave[id] = { m.ku, m.kv } end end
            add(a, a.known, a.paid, a.promised, a.kvalue, gave)
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
    for _, a in ipairs(archived(state, "d")) do
        if (not since or a.ts / a.n >= since) and (not keep or keep(a)) then
            local key = Ledger.BandKey(a.quality, a.classID, a.band)
            local b = out[key]
            if not b then
                b = { n = 0, planned = 0, value = 0, cost = 0, costKnown = 0, salvager = 0, mats = {} }
                out[key] = b
            end
            b.n, b.planned, b.value = b.n + a.n, b.planned + a.planned, b.value + a.value
            b.costKnown, b.cost = b.costKnown + a.known, b.cost + a.paid
            if a.salvager then b.salvager = b.salvager + a.n end
            for id, am in pairs(a.mats) do
                local m = b.mats[id] or { hits = 0, qty = 0 }
                b.mats[id] = m
                m.hits, m.qty = m.hits + am.h, m.qty + am.u
            end
        end
    end
    return out
end

------------------------------------------------------------------ the archive (SDD 126)

Ledger.FULL_DAYS = 30       -- records (disenchants, sales, posts) kept in full this long
Ledger.MAX_FULL = 10000     -- and at most this many of each kind: past it the oldest are rolled up early
Ledger.DAY_DAYS = 60        -- rolled-up records kept per day (and per item) this long; then per 30 days and band
Ledger.PERIOD_DAYS = 30
Ledger.PERIOD_KEEP = 365    -- periods older than this merge into one bucket per band (their weight by age is < 0.03 %)

local function dayOf(t) return math.floor((t or 0) / 86400) end

-- Rounded for the rolled-up samples: a sell price ratio to 0.001 (0.01 per period), a time to sell to the second
-- under 10 minutes, to 10 s under an hour, to the minute under a day, else to 10 minutes.
local function ratioKey(r, coarse) return string.format(coarse and "%.2f" or "%.3f", r) end
local function secsOf(x)
    local step = x < 600 and 1 or x < 3600 and 10 or x < 86400 and 60 or 600
    return math.floor(x / step + 0.5) * step
end

local function newD(k, r)
    return { k = k, quality = r.quality, classID = r.classID, band = r.band, salvager = r.salvager and true or false,
        itemID = r.itemID, link = r.link, n = 0, ts = 0, ng = 0, eg = 0, known = 0, paid = 0, value = 0, kvalue = 0,
        planned = 0, promised = 0, mats = {} }
end
local function dKey(tier, r)
    return table.concat({ tier, tostring(r.quality), tostring(r.classID), tostring(r.band), r.salvager and "1" or "0",
        tier:sub(1, 1) == "d" and tostring(r.itemID) or "" }, "|")
end
local function mergeMat(into, m)
    into.u, into.h, into.ku, into.kv = into.u + m.u, into.h + m.h, into.ku + m.ku, into.kv + m.kv
    for q, c in pairs(m.nq) do into.nq[q] = (into.nq[q] or 0) + c end
    for q, e in pairs(m.eq) do into.eq[q] = (into.eq[q] or 0) + e end
end
local function newMat() return { u = 0, h = 0, ku = 0, kv = 0, nq = {}, eq = {} } end
local D_SUMS = { "n", "ts", "ng", "eg", "known", "paid", "value", "kvalue", "planned", "promised" }
local function mergeD(into, b)
    for _, f in ipairs(D_SUMS) do into[f] = into[f] + b[f] end
    for id, m in pairs(b.mats) do
        into.mats[id] = into.mats[id] or newMat()
        mergeMat(into.mats[id], m)
    end
end
-- One disenchant as a bucket of one.
local function oneD(r)
    local b, e = newD(nil, r), eOf(r.t)
    b.n, b.ts, b.value, b.planned = 1, r.t or 0, r.value or 0, r.planned or 0
    if r.got and next(r.got) then b.ng, b.eg = 1, e end
    local known = r.costKnown and true or false
    if known then
        b.known, b.paid, b.kvalue, b.promised = 1, r.cost or 0, r.value or 0, r.evAtBuy or r.planned or 0
    end
    for id, qty in pairs(r.got or {}) do
        local m = newMat()
        m.u, m.h, m.nq[qty], m.eq[qty] = qty, 1, 1, e
        if known then m.ku, m.kv = qty, (r.vals and r.vals[id]) or 0 end
        b.mats[id] = m
    end
    return b
end

local S_SUMS = { "n", "ts", "count", "gross", "cut", "net", "cost", "untracked", "netUntracked", "profit", "qty",
    "awayN", "awayNet", "awayCost", "back", "e", "eu", "elost" }
local function newS(k, s)
    local b = { k = k, id = s.id, lost = s.lost, ratios = {}, times = {} }
    for _, f in ipairs(S_SUMS) do b[f] = 0 end
    return b
end
local function sKey(tier, s) return tier .. "|" .. tostring(s.id) .. "|" .. tostring(s.lost or "sale") end
local function mergeSamples(into, from, key)
    for _, x in pairs(from) do
        local k = key(x.r)
        local y = into[k] or { r = tonumber(k), u = 0, n = 0, eu = 0, e = 0 }
        into[k] = y
        y.u, y.n, y.eu, y.e = y.u + x.u, y.n + x.n, y.eu + x.eu, y.e + x.e
    end
end
local function mergeS(into, b, coarse)
    for _, f in ipairs(S_SUMS) do into[f] = into[f] + b[f] end
    mergeSamples(into.ratios, b.ratios, function(r) return ratioKey(r, coarse) end)
    mergeSamples(into.times, b.times, function(r) return tostring(secsOf(r)) end)
end
-- One sale as a bucket of one, with its sell price ratio and time to sell when they are known.
local function oneS(s, ratio, secs)
    local b, e = newS(nil, s), eOf(s.t)
    local count = s.count or 0
    b.n, b.ts, b.count, b.gross, b.cut, b.net = 1, s.t or 0, count, s.gross or 0, s.cut or 0, s.net or 0
    b.cost, b.untracked, b.netUntracked, b.profit = s.cost or 0, s.untracked or 0, s.netUntracked or 0, s.profit or 0
    b.qty, b.back, b.e, b.eu = s.qty or 0, s.back or 0, e, count * e
    if s.lost then b.elost = -(s.net or 0) * e end
    if s.away then b.awayN, b.awayNet, b.awayCost = 1, s.net or 0, s.cost or 0 end
    if ratio then b.ratios[ratioKey(ratio)] = { r = tonumber(ratioKey(ratio)), u = count, n = 1, eu = count * e, e = e } end
    if secs then b.times[tostring(secsOf(secs))] = { r = secsOf(secs), u = count, n = 1, eu = count * e, e = e } end
    return b
end

-- Puts bucket `b` into `list` under key `k` (merged with the one there), `index` = { [k] = bucket }.
local function file(list, index, k, b, merge)
    local into = index[k]
    if into then
        merge(into, b)
    else
        b.k = k
        list[#list + 1] = b
        index[k] = b
    end
end

--- Rolls up what is older than FULL_DAYS (SDD 126), once at load and every hour: disenchants into one bucket per day,
--- band, Salvager or not and item (`archive.d`), settled sales into one per day, material and kind (`archive.s`), with
--- every total the Reports, the Accuracy, the Odds, the Breakdown and the statement read, and what the learning reads
--- (results per quantity, sell price ratios, times to sell, deposits lost) with their weight by age kept as `e`
--- (Model.Decay within 1.2 %). Posts (`opts.posted`) older than that go, as their part of the Current batch is in
--- `archive.head`; a sale whose post goes keeps the post's time (`postedAt`). Past MAX_FULL records of one kind the
--- oldest are rolled up early. Buckets older than DAY_DAYS are merged per PERIOD_DAYS and band (the item and the day
--- go). `opts.valueAt(sale)`: the material's value when the sale was posted (as Ledger.SellRatios).
--- @return table { disenchants, sales, posts, merged, upTo, early (true: the bound, not the age) }
function Ledger.Archive(state, now, opts)
    opts = opts or {}
    local posted = opts.posted or {}
    local A = state.archive or Ledger.NewArchive()
    state.archive = A
    local rep = { disenchants = 0, sales = 0, posts = 0, merged = 0 }
    local C = now - Ledger.FULL_DAYS * 86400
    for _, list in ipairs({ state.disenchants, state.sales, posted }) do
        if #list > Ledger.MAX_FULL then
            local ts = {}
            for i, r in ipairs(list) do ts[i] = r.t or 0 end
            table.sort(ts)
            if ts[#ts - Ledger.MAX_FULL + 1] > C then C, rep.early = ts[#ts - Ledger.MAX_FULL + 1], true end
        end
    end
    C = math.max(C, A.upTo or 0)
    local dIndex, sIndex = {}, {}
    for _, b in ipairs(A.d) do dIndex[b.k] = b end
    for _, b in ipairs(A.s) do sIndex[b.k] = b end
    if C > (A.upTo or 0) then
        -- The Current batch's part: the units of the disenchants rolled up, first in, first out against what went
        -- before C (since the last roll-up); what is left of them is the head the later posts and sales take first.
        local old, units = {}, {}
        for i, r in ipairs(state.disenchants) do if (r.t or 0) < C then old[#old + 1] = { r = r, i = i } end end
        table.sort(old, function(a, b)
            if (a.r.t or 0) ~= (b.r.t or 0) then return (a.r.t or 0) < (b.r.t or 0) end
            return a.i < b.i
        end)
        for _, x in ipairs(old) do
            for id, qty in pairs(x.r.got or {}) do
                units[id] = units[id] or {}
                table.insert(units[id], { t = x.r.t or 0, n = qty })
            end
        end
        local head = A.head
        for _, g in ipairs(goneEvents(state.sales, posted, A.upTo or 0, C)) do
            local n = g.n
            local h = math.min(n, head[g.id] or 0)
            head[g.id], n = (head[g.id] or 0) - h, n - h
            for _, u in ipairs(units[g.id] or {}) do
                if n <= 0 or u.t > g.t then break end
                local take = math.min(n, u.n)
                u.n, n = u.n - take, n - take
            end
        end
        for id, list in pairs(units) do
            for _, u in ipairs(list) do head[id] = (head[id] or 0) + u.n end
        end
        for id, n in pairs(head) do if n <= 0 then head[id] = nil end end
        -- The sales kept (also those whose money is still due) whose post goes keep its time.
        local byItem = postsByItem(posted)
        for _, s in ipairs(state.sales) do
            if not ((s.t or 0) < C and (s.unpaid or 0) == 0) and not s.lost and not s.postedAt then
                local at = postTime(s, byItem, s.t or 0)
                if at and at < C then s.postedAt = at end
            end
        end
        -- The disenchants.
        local keep = {}
        for _, r in ipairs(state.disenchants) do
            if (r.t or 0) < C then
                file(A.d, dIndex, dKey("d" .. dayOf(r.t), r), oneD(r), mergeD)
                rep.disenchants = rep.disenchants + 1
            else
                keep[#keep + 1] = r
            end
        end
        state.disenchants = keep
        -- The sales whose money is settled, with their sell price ratio and time to sell.
        keep = {}
        for _, s in ipairs(state.sales) do
            if (s.t or 0) < C and (s.unpaid or 0) == 0 then
                local ratio, secs
                if not s.lost and (s.count or 0) > 0 and (s.gross or 0) > 0 then
                    local v = s.val or (opts.valueAt and opts.valueAt(s))
                    if v and v > 0 then ratio = (s.each or (s.gross / s.count)) / v end
                    local soldAt = s.t or 0
                    if s.due then soldAt = math.min(soldAt, s.due - Ledger.MAIL_DELAY) end
                    local at = postTime(s, byItem, soldAt)
                    if at then secs = math.max(0, soldAt - at) end
                end
                file(A.s, sIndex, sKey("d" .. dayOf(s.t), s), oneS(s, ratio, secs), mergeS)
                rep.sales = rep.sales + 1
            else
                keep[#keep + 1] = s
            end
        end
        state.sales = keep
        -- The posts.
        for i = #posted, 1, -1 do
            if (posted[i].t or 0) < C then
                table.remove(posted, i)
                rep.posts = rep.posts + 1
            end
        end
        A.upTo = C
    end
    -- Past DAY_DAYS: one bucket per 30 days and band (no item, no day); past PERIOD_KEEP, one per band.
    local limit, limitAll = dayOf(now) - Ledger.DAY_DAYS, dayOf(now) - Ledger.PERIOD_KEEP
    for _, kind in ipairs({ "d", "s" }) do
        local out, index, old = {}, {}, {}
        for _, b in ipairs(A[kind]) do
            local day = tonumber(b.k:match("^d(%d+)|"))
            local period = tonumber(b.k:match("^p(%d+)|"))
            if day and day < limit then
                old[#old + 1] = { b = b, tier = "p" .. math.floor(day / Ledger.PERIOD_DAYS) }
            elseif period and (period + 1) * Ledger.PERIOD_DAYS <= limitAll then
                old[#old + 1] = { b = b, tier = "a" }
            else
                out[#out + 1] = b
                if b.k:sub(1, 1) ~= "d" then index[b.k] = b end
            end
        end
        -- (Days first: one that goes straight to "a" meets its band's bucket there.)
        for _, x in ipairs(old) do
            if x.tier ~= "a" and tonumber(x.tier:sub(2)) and (tonumber(x.tier:sub(2)) + 1) * Ledger.PERIOD_DAYS <= limitAll then
                x.tier = "a"
            end
        end
        for _, x in ipairs(old) do
            local b, tier = x.b, x.tier
            local k = kind == "d" and dKey(tier, b) or sKey(tier, b)
            local into = index[k]
            if not into then
                into = kind == "d" and newD(k, b) or newS(k, b)
                if kind == "d" then into.itemID, into.link = nil, nil end
                out[#out + 1] = into
                index[k] = into
            end
            if kind == "d" then mergeD(into, b) else mergeS(into, b, true) end
            rep.merged = rep.merged + 1
        end
        A[kind] = out
    end
    rep.upTo = A.upTo
    return rep
end

return Ledger

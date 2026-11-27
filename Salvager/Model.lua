-- Salvager: the disenchant model. Pure functions, no game API.
local _, ns = ...
ns = ns or {}

local Data = ns.Data
local Model = {}
ns.Model = Model

Model.DEFAULT_CUT = 0.05

local function bandOf(rows, ilvl)
    for _, row in ipairs(rows) do
        if ilvl <= row.up then return row end
    end
end

--- What an item disenchants into.
--- @param quality number  2 uncommon, 3 rare, 4 epic
--- @param classID number  2 weapon, 4 armor
--- @param ilvl number     item level
--- @return table|nil  { band = upper item level, results = { {id, chance (0-1), min, max, bonus} } }
---                    `bonus` marks results the Arcane Salvager can add to (dust, essence).
function Model.Outcomes(quality, classID, ilvl)
    if classID ~= Data.CLASS_WEAPON and classID ~= Data.CLASS_ARMOR then return nil end
    ilvl = tonumber(ilvl) or 0
    if ilvl < 1 then return nil end
    local weapon = classID == Data.CLASS_WEAPON
    if quality == 2 then
        local row = bandOf(Data.GREEN, ilvl)
        local dustP, essP, shardP = row.pct[1], row.pct[2], row.pct[3]
        if weapon then dustP, essP = essP, dustP end
        local ess = (weapon and Data.WEAPON_ESSENCE[row.up]) or row.ess
        local results = {
            { id = row.dust[1], chance = dustP / 100, min = row.dust[2], max = row.dust[3], bonus = true },
            { id = ess[1], chance = essP / 100, min = ess[2], max = ess[3], bonus = true },
        }
        if row.shard and shardP > 0 then
            results[3] = { id = row.shard[1], chance = shardP / 100, min = row.shard[2], max = row.shard[3], bonus = false }
        end
        return { band = row.up, results = results }
    elseif quality == 3 then
        local row = bandOf(Data.BLUE, ilvl)
        return { band = row.up, results = { { id = row.shard, chance = 1, min = 1, max = 1, bonus = false } } }
    elseif quality == 4 then
        local row = bandOf(Data.PURPLE, ilvl)
        return { band = row.up, inferred = row.inferred or nil,
            results = { { id = row.res[1], chance = 1, min = row.res[2], max = row.res[3], bonus = false } } }
    end
    return nil
end

--- A material's price, filled in from the other essence form when missing.
--- @param rawGet function(id) -> copper each or nil
function Model.PairPrice(id, rawGet)
    local p = rawGet(id)
    if p then return p, false end
    local pair = Data.ESSENCE_PAIR[id]
    if not pair then return nil, false end
    local other = rawGet(pair.other)
    if not other then return nil, false end
    return math.floor(other * pair.factor + 0.5), true
end

-- Your own results move the table's rates (SDD 99): the table counts as RESULT_PRIOR disenchants of its own. A
-- band with fewer of yours than that still leans more on the table ("few results", UI.md Data 2).
Model.RESULT_PRIOR = 50
Model.FEW_RESULTS = 50

--- The table's quantities of one result: min..max equally likely; a result the Salvager adds to (`bonus`) gets one
--- more with chance `bonusChance`.
--- @return table { [quantity] = chance (0-1) }
function Model.TableDist(r, bonusChance)
    local b = r.bonus and (bonusChance or 0) or 0
    local each, dist = 1 / (r.max - r.min + 1), {}
    for q = r.min, r.max do
        dist[q] = (dist[q] or 0) + each * (1 - b)
        if b > 0 then dist[q + 1] = (dist[q + 1] or 0) + each * b end
    end
    return dist
end

-- Recency (SDD 118): every observation weighs 0.5^(its age in whole days / HALF_LIFE_DAYS). Today's weigh 1, a month's
-- half, two months' a quarter. Nothing is deleted: old results only count less, so a change in the game shows within
-- weeks. Band rates and quantities, the Salvager shape, the sell price ratio, time to sell and deposits use it.
Model.HALF_LIFE_DAYS = 30

--- The weight of an observation `age` seconds old (whole days: one day's results weigh the same).
function Model.Decay(age)
    local days = math.floor(math.max(0, age or 0) / 86400)
    return 0.5 ^ (days / Model.HALF_LIFE_DAYS)
end

-- The Salvager shape (SDD 118). A result of the table with m values (lo..hi) can come at m + 1 positions with the
-- Salvager: lo..hi and one more at the top. Per material kind (dust, essence, shard, crystal) your results with the
-- Salvager give a shape over those positions, pooled over every band; the community rule (salvagerChance, 50%: one
-- more half of the time; never on shards and crystals) counts as SHAPE_PRIOR results of its own.
Model.SHAPE_PRIOR = 50

--- The community rule over the positions 0..m of a result with m values: each value 1/m, one more with `bonusChance`.
--- @return table { [position] = chance }
function Model.PriorShape(m, bonusChance)
    return Model.TableDist({ min = 0, max = m - 1, bonus = true }, bonusChance)
end

--- Your results of one kind, pooled over every width, read at width m. A result at position j of a band with m0
--- values covers [j, j + 1] / (m0 + 1) of the stretch lo..hi + 1 evenly; position k at width m takes its overlap with
--- [k, k + 1] / (m + 1). The same width is read as it is.
--- @param cells table { [m0] = { [j] = weight } }
--- @return table { [position 0..m] = share }, number the weight of the results
function Model.ShapeAt(cells, m)
    local dist, total = {}, 0
    for k = 0, m do dist[k] = 0 end
    for m0, row in pairs(cells or {}) do
        for j, w in pairs(row) do
            if w > 0 then
                if m0 == m then
                    dist[j] = dist[j] + w
                else
                    local a, b = j / (m0 + 1), (j + 1) / (m0 + 1)
                    for k = 0, m do
                        local lo, hi = math.max(a, k / (m + 1)), math.min(b, (k + 1) / (m + 1))
                        if hi > lo then dist[k] = dist[k] + w * (hi - lo) / (b - a) end
                    end
                end
                total = total + w
            end
        end
    end
    if total > 0 then for k = 0, m do dist[k] = dist[k] / total end end
    return dist, total
end

--- The Salvager shape of one material kind at width m: (K × the community rule + your weight × your shape) ÷
--- (K + your weight). With no results it is the community rule; your results take over as they grow.
--- @param learned table|nil { cells, n } (Ledger.Shapes, one kind)
--- @return table { dist = { [position] = chance }, n (the weight of your results), top (chance of one more), few }
function Model.LearnedShape(learned, m, bonusChance, K)
    K = K or Model.SHAPE_PRIOR
    local prior = Model.PriorShape(m, bonusChance)
    local mine, n = Model.ShapeAt(learned and learned.cells, m)
    local dist = {}
    for k = 0, m do dist[k] = (K * (prior[k] or 0) + n * (mine[k] or 0)) / (K + n) end
    return { dist = dist, n = n, top = dist[m], few = n < Model.FEW_RESULTS }
end

--- The quantities of result `r` with the Salvager by the learned shape of its kind: { [quantity] = chance }.
--- @param shapes table|nil { [kind] = { cells, n } } (Ledger.Shapes(...).on)
--- @param kindOf function(id) -> "dust" | "essence" | "shard" | "crystal" | nil
--- @return table|nil  nil when the material's kind is not known
function Model.ShapeDist(r, shapes, kindOf, bonusChance, K)
    local kind = kindOf(r.id)
    if not kind then return nil end
    local m = r.max - r.min + 1
    local s = Model.LearnedShape(shapes and shapes[kind], m, r.bonus and (bonusChance or 0.5) or 0, K)
    local dist = {}
    for k, p in pairs(s.dist) do
        if p > 0 then dist[r.min + k] = p end
    end
    return dist, s
end

local function sortedKeys(t)
    local keys = {}
    for k in pairs(t) do keys[#keys + 1] = k end
    table.sort(keys)
    return keys
end

--- The table's outcomes blended with your results of the same band and Salvager state (SDD 99). Each (material,
--- quantity) has a weight: prior × table chance × the table's chance of that quantity, plus the times you got it.
--- So a result's chance = (prior × table chance + your hits) ÷ (prior + your disenchants), and its quantities
--- follow the same counts (a Dirichlet with the table as its mean). A material the table does not have for the
--- band comes in with your hits only (`unexpected`).
--- @param seen table|nil  { n = disenchants, mats = { [id] = { hits, qty = { [quantity] = times } } } }
--- With the Salvager and `shapeOf`, a result's quantities in the table's part follow the learned Salvager shape of
--- its kind (Model.ShapeDist, SDD 118) in place of the fixed rule. `seen` counts are weighted by recency (Ledger.Results):
--- `n` is their weight, `count` the disenchants themselves.
--- @param opts table|nil  { salvager, salvagerChance = 0.5, prior = Model.RESULT_PRIOR,
---   shapeOf = function(result) -> { [quantity] = chance } | nil }
--- @return table  outcomes with `n` (the weight of your disenchants), `count`, `few`, `salvager`, and per result:
---   chance (blended), `dist` ({ [quantity] = chance }, the Salvager bonus in it), `mean`, `tableChance`, `hits`;
---   min and max stay the table's
function Model.Blended(outcomes, seen, opts)
    opts = opts or {}
    local K = opts.prior or Model.RESULT_PRIOR
    local bonusChance = opts.salvager and (opts.salvagerChance or 0.5) or 0
    local n = seen and seen.n or 0
    local mats = seen and seen.mats or {}
    local out = { band = outcomes.band, results = {}, n = n, count = seen and (seen.count or seen.n) or 0,
        few = n < Model.FEW_RESULTS, salvager = opts.salvager and true or false, inferred = outcomes.inferred }
    local function tableDist(base)
        local d = opts.salvager and opts.shapeOf and opts.shapeOf(base)
        return d or Model.TableDist(base, bonusChance)
    end
    local function add(base, mine)
        local w, total = {}, 0
        if base then
            for q, p in pairs(tableDist(base)) do w[q] = K * base.chance * p end
        end
        for q, c in pairs(mine and mine.qty or {}) do w[q] = (w[q] or 0) + c end
        for _, x in pairs(w) do total = total + x end
        if total <= 0 then return end
        local dist, mean, lo, hi = {}, 0, math.huge, -math.huge
        for _, q in ipairs(sortedKeys(w)) do
            dist[q] = w[q] / total
            mean = mean + q * dist[q]
            lo, hi = math.min(lo, q), math.max(hi, q)
        end
        out.results[#out.results + 1] = {
            id = base and base.id or mine.id, chance = total / (K + n), dist = dist, mean = mean,
            min = base and base.min or lo, max = base and base.max or hi, bonus = base and base.bonus or false,
            tableChance = base and base.chance or 0, hits = mine and mine.hits or 0, unexpected = base == nil,
            seenQty = mine and mine.qty or nil,   -- ({ [quantity] = times you got it }: Model.Spread marks them seen)
        }
    end
    local inTable = {}
    for _, r in ipairs(outcomes.results) do
        inTable[r.id] = true
        add(r, mats[r.id])
    end
    for _, id in ipairs(sortedKeys(mats)) do
        if not inTable[id] then
            local m = mats[id]
            add(nil, { id = id, hits = m.hits, qty = m.qty })
        end
    end
    return out
end

--- How many of a result come on average: its blended mean, else the table's middle (+ the bonus).
local function meanQty(r, bonusChance)
    if r.dist then return r.mean end
    local qty = (r.min + r.max) / 2
    if r.bonus then qty = qty + bonusChance end
    return qty
end

local function one() return 1 end
local function none() return 0 end

--- What one unit of a material is worth to the forecast (SDD 3, 96): its price × its sell price ratio, after the
--- cut, less the deposits lost per unit sold; never below 0. nil without a price. (opts as Model.Value)
function Model.UnitValue(id, priceOf, opts)
    opts = opts or {}
    local price = priceOf(id)
    if not price then return nil end
    local keep = 1 - (opts.cut or Model.DEFAULT_CUT)
    return math.max(0, price * (opts.ratio or one)(id) * keep - (opts.deposit or none)(id))
end

--- Expected value of one disenchant.
--- @param outcomes table  from Model.Outcomes
--- @param priceOf function(id) -> copper each or nil (the material's value, SDD 3)
--- @param opts table|nil  { salvager = bool, salvagerChance = 0.5, cut = 0.05,
---   ratio = function(id) -> what one unit sells for against its value (sell price ratio, 1 when nil),
---   deposit = function(id) -> deposits lost per unit sold, copper (0 when nil) }
--- A unit is worth price × ratio after the cut, less the deposit: net = gross × (1 − cut) − deposits.
--- Blended outcomes (Model.Blended) bring their own mean quantity, the Salvager bonus in it.
--- @return table  { gross (before the cut, with the ratio), net, low, deposits, missing = {ids}, parts = { {id, value} } }
function Model.Value(outcomes, priceOf, opts)
    opts = opts or {}
    local cut = opts.cut or Model.DEFAULT_CUT
    local ratioOf, depositOf = opts.ratio or one, opts.deposit or none
    local bonusChance = opts.salvager and (opts.salvagerChance or 0.5) or 0
    local gross, low, dep, lowDep, missing, parts = 0, 0, 0, 0, {}, {}
    for _, r in ipairs(outcomes.results) do
        local price = priceOf(r.id)
        if not price then
            missing[#missing + 1] = r.id
        else
            local qty = meanQty(r, bonusChance)
            local each, d = price * ratioOf(r.id), depositOf(r.id)
            local v = r.chance * qty * each
            gross = gross + v
            low = low + r.chance * r.min * each
            dep = dep + r.chance * qty * d
            lowDep = lowDep + r.chance * r.min * d
            parts[#parts + 1] = { id = r.id, value = v }
        end
    end
    -- net = the average over many disenchants. low = the same with every material at its lowest
    -- amount and no Salvager bonus (cautious pricing).
    return { gross = gross, net = math.floor(gross * (1 - cut) - dep + 0.5),
        low = math.floor(low * (1 - cut) - lowDep + 0.5), deposits = dep, missing = missing, parts = parts }
end

--- How the Expected value of one disenchant is built (the Gear details window): one row per result with its rate,
--- its mean quantity (the Salvager bonus in it), the value of one unit (price × sell price ratio, after the cut, less
--- the deposits lost per unit sold) and its part (rate × quantity × unit value). The parts add up to Model.Value's
--- net (before its rounding). A result without a price has no unit value and no part. (opts as Model.Value)
--- @return table  { rows = { { id, chance, qty, unit, part } }, total }
function Model.ValueBuild(outcomes, priceOf, opts)
    opts = opts or {}
    local keep = 1 - (opts.cut or Model.DEFAULT_CUT)
    local ratioOf, depositOf = opts.ratio or one, opts.deposit or none
    local bonusChance = opts.salvager and (opts.salvagerChance or 0.5) or 0
    local rows, total = {}, 0
    for _, r in ipairs(outcomes.results) do
        local price = priceOf(r.id)
        local qty = meanQty(r, bonusChance)
        local unit = price and (price * ratioOf(r.id) * keep - depositOf(r.id)) or nil
        local part = unit and r.chance * qty * unit or nil
        total = total + (part or 0)
        rows[#rows + 1] = { id = r.id, chance = r.chance, qty = qty, unit = unit, part = part }
    end
    return { rows = rows, total = total }
end

--- The chance that one disenchant is worth less than `paid`, after the cut (opts as Model.Value).
--- Each result's quantities are equally likely; with the Salvager, dust and essence get one more
--- with the given chance. Blended outcomes (Model.Blended) bring each quantity's chance. A material with no
--- price counts as worth nothing.
--- @return number  0 to 1
function Model.LossChance(outcomes, priceOf, opts, paid)
    opts = opts or {}
    local keep = 1 - (opts.cut or Model.DEFAULT_CUT)
    local ratioOf, depositOf = opts.ratio or one, opts.deposit or none
    local lose = 0
    for _, r in ipairs(outcomes.results) do
        local price = priceOf(r.id)
        -- What one unit brings: its value × the sell price ratio, after the cut, less the deposits lost.
        local unit = price and (price * ratioOf(r.id) * keep - depositOf(r.id)) or 0
        if r.dist then
            -- Blended outcomes (Model.Blended): each quantity has its own chance, the Salvager bonus in it.
            for qty, p in pairs(r.dist) do
                if qty * unit < paid then lose = lose + r.chance * p end
            end
        else
            local each = r.chance / (r.max - r.min + 1)
            local bonus = (opts.salvager and r.bonus) and (opts.salvagerChance or 0.5) or 0
            for qty = r.min, r.max do
                if qty * unit < paid then lose = lose + each * (1 - bonus) end
                if bonus > 0 and (qty + 1) * unit < paid then lose = lose + each * bonus end
            end
        end
    end
    return lose
end

-- One disenchant gives whole units of one material (the user, 2026-11-27: "we never get 1.5 materials"). The range
-- of a deal is two real outcomes: the pessimistic one (in 9 of 10 disenchants you get this or more) and the
-- optimistic one (1 in 10 gets this or more), SDD 116.
Model.P_LOW, Model.P_HIGH = 0.10, 0.90
-- A band whose rates rest on this many of your disenchants (the blend's K) is "observed"; below, the table speaks.
Model.OBSERVED = Model.RESULT_PRIOR
local EPS = 1e-9

--- Where a band's rule comes from (SDD 116): "observed" (at least Model.OBSERVED of your disenchants), "inferred"
--- (the rule is marked so in Data.lua and your disenchants are fewer: not measured on Forever), else "documented"
--- (the game's table).
function Model.Evidence(outcomes)
    if (outcomes.n or 0) >= Model.OBSERVED then return "observed" end
    if outcomes.inferred then return "inferred" end
    return "documented"
end

--- Every outcome of one disenchant in whole units: which material, how many, its chance and its value
--- (quantity × price × sell price ratio after the cut less the deposits lost per unit: the value Model.Value counts),
--- lowest value first (ties: the more likely first, then the materials' order). A material without a price is worth
--- 0 (`missing`). `seen` = you got exactly that in a disenchant of the band (blended outcomes only). Chances of 0 are
--- left out. (opts as Model.Value)
--- @return table  { { id, qty, chance, value, seen, missing }, ... }
function Model.Results(outcomes, priceOf, opts)
    opts = opts or {}
    local keep = 1 - (opts.cut or Model.DEFAULT_CUT)
    local ratioOf, depositOf = opts.ratio or one, opts.deposit or none
    local bonusChance = opts.salvager and (opts.salvagerChance or 0.5) or 0
    local list = {}
    for _, r in ipairs(outcomes.results) do
        local price = priceOf(r.id)
        local unit = price and (price * ratioOf(r.id) * keep - depositOf(r.id)) or 0
        for q, p in pairs(r.dist or Model.TableDist(r, bonusChance)) do
            local chance = r.chance * p
            if chance > EPS and q > 0 then
                list[#list + 1] = { id = r.id, qty = q, chance = chance, value = math.floor(q * unit + 0.5),
                    seen = ((r.seenQty and r.seenQty[q]) or 0) > 0, missing = price == nil }
            end
        end
    end
    table.sort(list, function(a, b)
        if a.value ~= b.value then return a.value < b.value end
        if math.abs(a.chance - b.chance) > EPS then return a.chance > b.chance end
        local ra, rb = Data.MaterialRank(a.id), Data.MaterialRank(b.id)
        if ra ~= rb then return ra < rb end
        return a.qty < b.qty
    end)
    return list
end

--- The range of one disenchant (SDD 116): every outcome (Model.Results), the pessimistic one (the 10th percentile:
--- the best outcome with at most 10% of the chance below it) and the optimistic one (the 90th: the worst with at most
--- 10% above it), the average (Σ chance × value: Model.Value's net before its rounding), the evidence
--- (Model.Evidence), and `unproven`: the optimistic outcome rests on a rule not measured on Forever and you never got it.
--- `weight`: the weight of your disenchants it rests on (by age, SDD 118), `few`: under Model.FEW_RESULTS.
--- @return table  { list, low, high, average, evidence, unproven, weight, few } (low and high are entries of list)
function Model.Spread(outcomes, priceOf, opts)
    local list = Model.Results(outcomes, priceOf, opts)
    local total, average = 0, 0
    for _, x in ipairs(list) do total, average = total + x.chance, average + x.chance * x.value end
    local low, high
    local below = 0
    for _, x in ipairs(list) do
        if below <= Model.P_LOW * total + EPS then low = x end
        below = below + x.chance
        if not high and below >= Model.P_HIGH * total - EPS then high = x end
    end
    local evidence = Model.Evidence(outcomes)
    return { list = list, low = low, high = high, average = average, evidence = evidence,
        unproven = evidence == "inferred" and high ~= nil and not high.seen, weight = outcomes.n or 0,
        few = outcomes.few and true or false }
end

--- Value of materials actually received, after the cut.
--- @param got table  { [itemID] = quantity }
function Model.ValueOf(got, priceOf, cut)
    cut = cut or Model.DEFAULT_CUT
    local gross, missing = 0, false
    for id, qty in pairs(got) do
        local p = priceOf(id)
        if p then gross = gross + p * qty else missing = true end
    end
    return math.floor(gross * (1 - cut)), missing
end

--- Highest price worth paying for an item with this net value.
--- The most to pay for an item worth `net`: it must make at least `minProfit` copper and, when
--- `minReturn` (percent of the price) is above 0, at least that return. Both rules hold.
--- @return number limit, string rule that sets it ("profit" | "return")
function Model.MaxBuy(net, minProfit, minReturn)
    local byProfit = math.max(0, net - (minProfit or 0))
    if not minReturn or minReturn <= 0 then return byProfit, "profit" end
    local byReturn = math.max(0, math.floor(net / (1 + minReturn / 100)))
    if byReturn < byProfit then return byReturn, "return" end
    return byProfit, "profit"
end

Model.DAY = 86400

--- How long the materials of one disenchant take to sell (SDD 100): each material's time to sell weighted by its
--- part of the value, in days, at least 1 day. Materials with no time to sell are left out.
--- @param parts table  { { id, value }, ... } (Model.Value parts)
--- @param timeOf function(id) -> seconds or nil, boolean few
--- @return number|nil days (nil: no material has a time), boolean few (a material of it rests on few sales),
---   number|nil seconds (the weighted time itself, before the 1 day floor)
function Model.DaysToSell(parts, timeOf)
    local sum, weight, few = 0, 0, false
    for _, p in ipairs(parts or {}) do
        local secs, f = timeOf(p.id)
        if secs and (p.value or 0) > 0 then
            sum, weight = sum + secs * p.value, weight + p.value
            few = few or f and true or false
        end
    end
    if weight <= 0 then return nil, false, nil end
    return math.max(1, sum / weight / Model.DAY), few, sum / weight
end

--- Expected profit ÷ buyout ÷ days until the materials sell (SDD 100). nil without days or a buyout.
function Model.ReturnPerDay(profit, buyout, days)
    if not days or not buyout or buyout <= 0 then return nil end
    return profit / buyout / days
end

--- The median of weighted samples: the value at which half the weight lies below.
--- @param samples table  { { r = value, w = weight (> 0) }, ... }
--- @return number|nil  nil when there is no weight
function Model.WeightedMedian(samples)
    local list, total = {}, 0
    for _, x in ipairs(samples) do
        if x.r and (x.w or 0) > 0 then list[#list + 1] = x total = total + x.w end
    end
    if total <= 0 then return nil end
    table.sort(list, function(a, b) return a.r < b.r end)
    local acc = 0
    for i, x in ipairs(list) do
        acc = acc + x.w
        -- Exactly half: the middle of the two values around it.
        if acc == total / 2 and list[i + 1] then return (x.r + list[i + 1].r) / 2 end
        if acc > total / 2 then return x.r end
    end
    return list[#list].r
end

--- A measured value that rests on `n` samples, pulled toward `prior` while n is under `floor`:
--- (n × value + (floor − n) × prior) ÷ floor. No value: the prior.
function Model.Blend(value, n, prior, floor)
    if not value or n <= 0 then return prior end
    if n >= floor then return value end
    return (n * value + (floor - n) * prior) / floor
end

return Model

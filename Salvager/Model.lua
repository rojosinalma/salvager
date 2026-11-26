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
        return { band = row.up, results = { { id = row.res[1], chance = 1, min = row.res[2], max = row.res[3], bonus = false } } }
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
            local qty = (r.min + r.max) / 2
            if r.bonus then qty = qty + bonusChance end
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

--- The chance that one disenchant is worth less than `paid`, after the cut (opts as Model.Value).
--- Each result's quantities are equally likely; with the Salvager, dust and essence get one more
--- with the given chance. A material with no price counts as worth nothing.
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
        local each = r.chance / (r.max - r.min + 1)
        local bonus = (opts.salvager and r.bonus) and (opts.salvagerChance or 0.5) or 0
        for qty = r.min, r.max do
            if qty * unit < paid then lose = lose + each * (1 - bonus) end
            if bonus > 0 and (qty + 1) * unit < paid then lose = lose + each * bonus end
        end
    end
    return lose
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

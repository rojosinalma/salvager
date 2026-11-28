-- Salvager: the Arcane Salvager's recipe in money (SDD 128). Pure functions, no game API: the prices, the stock's
-- costs and the recipe come in as arguments.
--   cost to craft one = each reagent × its quantity, at the stock's average cost when you hold enough known-cost
--   units of it, else at its price now (each part says which); the tool is not used up and costs nothing per craft.
--   price to buy one crafted = the Arcane Salvager's price now; cheaper = craft or buy, by how much.
--   profit for crafting and selling one = its price now after the cut - the cost to craft (and per stack of 20).
--   Blueprint payback = how many crafted-and-sold salvagers pay the Blueprint's price back.
local _, ns = ...
ns = ns or {}

local Data = ns.Data
local Craft = {}
ns.Craft = Craft

--- The cost to craft one. `opts`: priceOf(id) = price each now (nil: not known), avgCostOf(id) = the stock's average
--- cost each of the known-cost units (nil: none), knownOf(id) = the known-cost units held, recipe (default
--- Data.SALVAGER_RECIPE).
--- @return table { total (nil when a reagent has no cost at all), parts = { { id, qty, each, source } }, source =
---   "stock" | "price" | "mixed" (nil when nothing is known), missing = { id, ... } }
function Craft.Cost(opts)
    local recipe = opts.recipe or Data.SALVAGER_RECIPE
    local out = { parts = {}, missing = {} }
    local total, sources = 0, {}
    for _, r in ipairs(recipe.reagents) do
        local held = opts.knownOf and opts.knownOf(r.id) or 0
        local avg = opts.avgCostOf and opts.avgCostOf(r.id)
        local each, source
        if avg and held >= r.qty then
            each, source = avg, "stock"
        else
            each = opts.priceOf and opts.priceOf(r.id)
            source = each and "price" or nil
        end
        out.parts[#out.parts + 1] = { id = r.id, qty = r.qty, each = each, source = source }
        if each then
            total = total + each * r.qty
            sources[source] = true
        else
            out.missing[#out.missing + 1] = r.id
        end
    end
    if #out.missing == 0 then out.total = math.floor(total + 0.5) end
    if sources.stock and sources.price then out.source = "mixed" else out.source = next(sources) end
    return out
end

--- Craft or buy: "craft" when crafting costs less than buying one, "buy" when buying does, "same" when equal; nil when
--- either is not known. @return string|nil, number|nil by how much (copper, 0 or more)
function Craft.Cheaper(cost, buy)
    if not cost or not buy then return nil end
    if cost < buy then return "craft", buy - cost end
    if buy < cost then return "buy", cost - buy end
    return "same", 0
end

--- Profit for crafting and selling one: the sale price after the cut, less the cost to craft. nil when unknown.
function Craft.Profit(sale, cost, cut)
    if not sale or not cost then return nil end
    return math.floor(sale * (1 - (cut or 0)) + 0.5) - cost
end

--- How many crafted-and-sold salvagers pay back `price` (the Blueprint's): nil when the price or the profit is not
--- known, or a craft makes no profit (it never pays back).
function Craft.Payback(price, profit)
    if not price or not profit or profit <= 0 then return nil end
    return math.max(1, math.ceil(price / profit))
end

--- Everything the Arcane Salvager tab's statement shows. `opts` as Craft.Cost, plus cut and known (the recipe is
--- known).
--- @return table { known, cost (Craft.Cost), buy (price to buy one crafted), cheaper, by, sale (after the cut),
---   profit, profitStack, stack, blueprint (its price now), payback }
function Craft.Summary(opts)
    local recipe = opts.recipe or Data.SALVAGER_RECIPE
    local priceOf = opts.priceOf or function() return nil end
    local s = { known = opts.known and true or false, stack = recipe.stack }
    s.cost = Craft.Cost(opts)
    s.buy = priceOf(recipe.result)
    s.cheaper, s.by = Craft.Cheaper(s.cost.total, s.buy)
    s.sale = s.buy and math.floor(s.buy * (1 - (opts.cut or 0)) + 0.5) or nil
    s.profit = Craft.Profit(s.buy, s.cost.total, opts.cut)
    s.profitStack = s.profit and s.profit * recipe.made * recipe.stack or nil
    s.blueprint = priceOf(Data.SALVAGER_BLUEPRINT)
    s.payback = Craft.Payback(s.blueprint, s.profit)
    return s
end

return Craft

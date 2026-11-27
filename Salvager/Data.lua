-- Salvager: static game data. Disenchanting materials and the disenchant table.
--
-- The table is Classic's, by ITEM LEVEL (the true driver; required level is
-- only a rough guide). It reproduces the community spreadsheet values for
-- WoW Forever when combined with the Arcane Salvager rule in Model.lua.
local _, ns = ...
ns = ns or {}

local Data = {}
ns.Data = Data

local DUST = { strange = 10940, soul = 11083, vision = 11137, dream = 11176, illusion = 16204 }
local ESS = {
    lmagic = 10938, gmagic = 10939, lastral = 10998, gastral = 11082, lmystic = 11134,
    gmystic = 11135, lnether = 11174, gnether = 11175, leternal = 16202, geternal = 16203,
}
local SHARD = {
    sglim = 10978, lglim = 11084, sglow = 11138, lglow = 11139, srad = 11177,
    lrad = 11178, sbril = 14343, lbril = 14344, nexus = 20725,
}
Data.DUST, Data.ESS, Data.SHARD = DUST, ESS, SHARD

-- Every material the addon prices, in display order. `name` is a fallback
-- until the client has the item's own (localised) name.
Data.MATERIALS = {
    { id = DUST.strange, name = "Strange Dust", kind = "dust" },
    { id = DUST.soul, name = "Soul Dust", kind = "dust" },
    { id = DUST.vision, name = "Vision Dust", kind = "dust" },
    { id = DUST.dream, name = "Dream Dust", kind = "dust" },
    { id = DUST.illusion, name = "Illusion Dust", kind = "dust" },
    { id = ESS.lmagic, name = "Lesser Magic Essence", kind = "essence" },
    { id = ESS.gmagic, name = "Greater Magic Essence", kind = "essence" },
    { id = ESS.lastral, name = "Lesser Astral Essence", kind = "essence" },
    { id = ESS.gastral, name = "Greater Astral Essence", kind = "essence" },
    { id = ESS.lmystic, name = "Lesser Mystic Essence", kind = "essence" },
    { id = ESS.gmystic, name = "Greater Mystic Essence", kind = "essence" },
    { id = ESS.lnether, name = "Lesser Nether Essence", kind = "essence" },
    { id = ESS.gnether, name = "Greater Nether Essence", kind = "essence" },
    { id = ESS.leternal, name = "Lesser Eternal Essence", kind = "essence" },
    { id = ESS.geternal, name = "Greater Eternal Essence", kind = "essence" },
    { id = SHARD.sglim, name = "Small Glimmering Shard", kind = "shard" },
    { id = SHARD.lglim, name = "Large Glimmering Shard", kind = "shard" },
    { id = SHARD.sglow, name = "Small Glowing Shard", kind = "shard" },
    { id = SHARD.lglow, name = "Large Glowing Shard", kind = "shard" },
    { id = SHARD.srad, name = "Small Radiant Shard", kind = "shard" },
    { id = SHARD.lrad, name = "Large Radiant Shard", kind = "shard" },
    { id = SHARD.sbril, name = "Small Brilliant Shard", kind = "shard" },
    { id = SHARD.lbril, name = "Large Brilliant Shard", kind = "shard" },
    { id = SHARD.nexus, name = "Nexus Crystal", kind = "crystal" },
}
Data.MATERIAL_BY_ID = {}
for _, m in ipairs(Data.MATERIALS) do Data.MATERIAL_BY_ID[m.id] = m end

-- The one order of materials in every list (the Materials window's): dust, then essences, then shards, each from
-- the lowest level up (the order of Data.MATERIALS). Every other material list sorts with Data.SortMaterials.
local RANK = {}
for i, m in ipairs(Data.MATERIALS) do RANK[m.id] = i end

--- A material's place in the order (1 = first); an id that is not a material comes after them all.
function Data.MaterialRank(id) return RANK[id] or (#Data.MATERIALS + 1) end

--- Sorts `list` in place in the materials' order; `idOf(entry)` gives an entry's material id (default: the entry
--- itself). Ties keep their order.
function Data.SortMaterials(list, idOf)
    idOf = idOf or function(x) return x end
    for i, x in ipairs(list) do list[i] = { x = x, i = i } end
    table.sort(list, function(a, b)
        local ra, rb = Data.MaterialRank(idOf(a.x)), Data.MaterialRank(idOf(b.x))
        if ra ~= rb then return ra < rb end
        return a.i < b.i
    end)
    for i, e in ipairs(list) do list[i] = e.x end
    return list
end

-- Three lesser essences combine into one greater, and one greater splits into
-- three lesser. Used only to fill in a price that is missing.
Data.ESSENCE_PAIR = {}
for _, p in ipairs({
    { ESS.lmagic, ESS.gmagic }, { ESS.lastral, ESS.gastral }, { ESS.lmystic, ESS.gmystic },
    { ESS.lnether, ESS.gnether }, { ESS.leternal, ESS.geternal },
}) do
    Data.ESSENCE_PAIR[p[1]] = { other = p[2], factor = 1 / 3 }
    Data.ESSENCE_PAIR[p[2]] = { other = p[1], factor = 3 }
end

-- Uncommon (green) gear, by upper item level of the band:
-- dust, essence, shard as { itemID, min, max }; then the ARMOR chances in
-- percent (dust, essence, shard). Weapons swap the dust and essence chances.
Data.GREEN = {
    { up = 15, dust = { DUST.strange, 1, 2 }, ess = { ESS.lmagic, 1, 2 }, shard = nil, pct = { 80, 20, 0 } },
    { up = 20, dust = { DUST.strange, 2, 3 }, ess = { ESS.gmagic, 1, 2 }, shard = { SHARD.sglim, 1, 1 }, pct = { 75, 20, 5 } },
    { up = 25, dust = { DUST.strange, 4, 6 }, ess = { ESS.lastral, 1, 2 }, shard = { SHARD.sglim, 1, 1 }, pct = { 75, 15, 10 } },
    { up = 30, dust = { DUST.soul, 1, 2 }, ess = { ESS.gastral, 1, 2 }, shard = { SHARD.lglim, 1, 1 }, pct = { 75, 20, 5 } },
    { up = 35, dust = { DUST.soul, 2, 5 }, ess = { ESS.lmystic, 1, 2 }, shard = { SHARD.sglow, 1, 1 }, pct = { 75, 20, 5 } },
    { up = 40, dust = { DUST.vision, 1, 2 }, ess = { ESS.gmystic, 1, 2 }, shard = { SHARD.lglow, 1, 1 }, pct = { 75, 20, 5 } },
    { up = 45, dust = { DUST.vision, 2, 5 }, ess = { ESS.lnether, 1, 2 }, shard = { SHARD.srad, 1, 1 }, pct = { 75, 20, 5 } },
    { up = 50, dust = { DUST.dream, 1, 2 }, ess = { ESS.gnether, 1, 2 }, shard = { SHARD.lrad, 1, 1 }, pct = { 75, 20, 5 } },
    { up = 55, dust = { DUST.dream, 2, 5 }, ess = { ESS.leternal, 1, 2 }, shard = { SHARD.sbril, 1, 1 }, pct = { 75, 20, 5 } },
    { up = 60, dust = { DUST.illusion, 1, 2 }, ess = { ESS.geternal, 1, 2 }, shard = { SHARD.lbril, 1, 1 }, pct = { 75, 20, 5 } },
    { up = 999, dust = { DUST.illusion, 2, 5 }, ess = { ESS.geternal, 2, 3 }, shard = { SHARD.lbril, 1, 1 }, pct = { 75, 20, 5 } },
}

-- Green weapons of item level 21-30 give Greater Magic Essence, not an astral
-- one (Wowhead Classic's recorded results); dust and shard follow the band.
Data.WEAPON_ESSENCE = { [25] = { ESS.gmagic, 1, 2 }, [30] = { ESS.gmagic, 1, 2 } }

-- Rare (blue) gear always gives one shard.
Data.BLUE = {
    { up = 25, shard = SHARD.sglim }, { up = 30, shard = SHARD.lglim }, { up = 35, shard = SHARD.sglow },
    { up = 40, shard = SHARD.lglow }, { up = 45, shard = SHARD.srad }, { up = 50, shard = SHARD.lrad },
    { up = 55, shard = SHARD.sbril }, { up = 999, shard = SHARD.lbril },
}

-- Epic (purple) gear. `inferred`: the rule is Classic's, not measured on Forever (SDD 116): Epic 56+ gives Nexus
-- Crystals there; whether Forever gives 2 as often as 1 is not seen yet. Its buy limit rests on its pessimistic value.
Data.PURPLE = {
    { up = 45, res = { SHARD.srad, 2, 4 } }, { up = 50, res = { SHARD.lrad, 2, 4 } },
    { up = 55, res = { SHARD.sbril, 2, 4 } }, { up = 60, res = { SHARD.nexus, 1, 1 }, inferred = true },
    { up = 999, res = { SHARD.nexus, 1, 2 }, inferred = true },
}

Data.DISENCHANT_SPELL = 13262
Data.SALVAGER_RECIPE_SPELL = 1263056
Data.SALVAGER_ITEM = 279985
-- The buff near a placed Arcane Salvager (wowhead.com/forever/spell=1283701): "Disenchanting boosted from time
-- spent near Arcane Salvager. While near Arcane Salvager, chance of bonus disenchanting output is increased."
Data.SALVAGER_AURA = 1283701
Data.SALVAGER_AURA_NAME = "Boosted Disenchanting"
Data.CLASS_WEAPON, Data.CLASS_ARMOR = 2, 4

return Data

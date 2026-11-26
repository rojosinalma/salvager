-- Salvager: catches each disenchant, what it gave, and books it in the ledger.
local _, ns = ...

local Data, Ledger, Model = ns.Data, ns.Ledger, ns.Model

local Disenchant = {}
ns.Disenchant = Disenchant

local WINDOW = 15          -- seconds from the cast to the loot window
local SNAPSHOTS = 30       -- aura snapshots kept to find the Salvager's spell ID
local pending

------------------------------------------------------------------ Salvager aura

local function helpfulAuras()
    local out = {}
    if not (C_UnitAuras and C_UnitAuras.GetAuraDataByIndex) then return out end
    for i = 1, 60 do
        local a = C_UnitAuras.GetAuraDataByIndex("player", i, "HELPFUL")
        if not a then break end
        out[#out + 1] = { name = a.name, id = a.spellId }
    end
    return out
end

--- Is an Arcane Salvager effect on the player? Matches by name (English client),
--- and remembers the spell IDs it sees, so the ID can replace the name later.
function Disenchant.SalvagerActive()
    local found = false
    for _, a in ipairs(helpfulAuras()) do
        if a.name and a.name:find("Salvager", 1, true) then
            found = true
            if a.id then ns.db.auraSeen[a.id] = a.name end
        end
    end
    return found
end

function Disenchant.PrintAuras()
    local list = helpfulAuras()
    if #list == 0 then ns.Print("no buffs") return end
    for _, a in ipairs(list) do ns.Print("%s (spell %s)", tostring(a.name), tostring(a.id)) end
    for id, name in pairs(ns.db.auraSeen) do ns.Print("seen during a disenchant: %s (spell %d)", name, id) end
end

local function snapshot()
    local snaps = ns.db.auraSnapshots
    if #snaps >= SNAPSHOTS then return end
    local names = {}
    for _, a in ipairs(helpfulAuras()) do names[#names + 1] = tostring(a.name) .. ":" .. tostring(a.id) end
    snaps[#snaps + 1] = { t = time(), auras = table.concat(names, ", ") }
end

------------------------------------------------------------------ the disenchant

local function book(p, got)
    local link = p.link
    local itemID = ns.ItemID(link)
    local quality, classID = ns.QualityOf(link), ns.ClassOf(link)
    local ilvl = ns.ItemLevelOf(link)
    local _, _, _, _, reqLevel = ns.GetItemInfo(link)
    local outcomes = quality and classID and ilvl and Model.Outcomes(quality, classID, ilvl)
    local planned
    if outcomes then
        local v = Model.Value(outcomes, ns.PriceOf, {
            salvager = p.salvager, salvagerChance = ns.db.settings.salvagerChance, cut = ns.Cut(),
        })
        planned = v.net
    end
    local rec = {
        t = time(), link = link, itemID = itemID, ilvl = ilvl, req = reqLevel, quality = quality,
        classID = classID, band = outcomes and outcomes.band, salvager = p.salvager, got = got, planned = planned,
    }
    local purchase = itemID and Ledger.TakePurchase(ns.db.ledger, itemID)
    Ledger.Disenchant(ns.db.ledger, rec, purchase, ns.PriceOf, ns.Cut())
    local parts = {}
    for id, qty in pairs(got) do parts[#parts + 1] = qty .. "x " .. ns.MaterialName(id) end
    local msg = string.format("%s gave %s, worth %s", link, table.concat(parts, ", "), ns.Money(rec.value))
    if rec.costKnown then msg = msg .. string.format(" (paid %s)", ns.Money(rec.cost)) end
    ns.Print(msg)
    ns.Fire("SALVAGER_LEDGER")
end

ns.On("UNIT_SPELLCAST_SENT", function(unit, _, _, spellID)
    if unit == "player" and spellID == Data.DISENCHANT_SPELL then
        pending = { t = GetTime(), salvager = Disenchant.SalvagerActive() }
        snapshot()
    end
end)

local function cancel(unit, _, spellID)
    if unit == "player" and spellID == Data.DISENCHANT_SPELL then pending = nil end
end
ns.On("UNIT_SPELLCAST_FAILED", cancel)
ns.On("UNIT_SPELLCAST_INTERRUPTED", cancel)

-- The game locks the item the spell is aimed at.
ns.On("ITEM_LOCK_CHANGED", function(bag, slot)
    if not pending or pending.link or not bag or not slot or bag < 0 then return end
    local link = C_Container.GetContainerItemLink(bag, slot)
    if not link then return end
    local classID = ns.ClassOf(link)
    if classID == Data.CLASS_WEAPON or classID == Data.CLASS_ARMOR then
        pending.link = link
        -- The item's GUID, to check that the loot comes from it (when the client tells the loot's source).
        local GetItemGUID = C_Item and C_Item.GetItemGUID
        if GetItemGUID and ItemLocation then
            local ok, guid = pcall(GetItemGUID, ItemLocation:CreateFromBagAndSlot(bag, slot))
            if ok then pending.guid = guid end
        end
    end
end)

--- Does loot slot `i` come from another source than the item disenchanted? Only when the client says so
--- (GetLootSourceInfo may not exist on Forever); unknown = it does not.
local function otherSource(i, guid)
    local GetLootSourceInfo = _G.GetLootSourceInfo
    if not (guid and GetLootSourceInfo) then return false end
    local ok, source = pcall(GetLootSourceInfo, i)
    return ok and type(source) == "string" and source ~= guid
end

ns.On("LOOT_READY", function()
    local p = pending
    pending = nil
    if not (p and p.link and GetTime() - p.t < WINDOW) then return end
    -- Only disenchanting materials, from the item itself: other loot open at the same time is not its result.
    local got, any = {}, false
    for i = 1, GetNumLootItems() do
        local link = GetLootSlotLink(i)
        local id = ns.ItemID(link)
        local _, _, qty = GetLootSlotInfo(i)
        if id and qty and qty > 0 and Data.MATERIAL_BY_ID[id] and not otherSource(i, p.guid) then
            got[id] = (got[id] or 0) + qty
            any = true
        end
    end
    if any then
        book(p, got)
    else
        ns.Log("disenchant of %s: the loot holds no disenchanting material, not booked", p.link)
    end
end)

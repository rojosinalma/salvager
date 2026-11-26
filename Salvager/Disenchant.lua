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
        out[#out + 1] = { name = a.name, id = a.spellId, stacks = a.applications }
    end
    return out
end

--- Is the Arcane Salvager's buff (Boosted Disenchanting) on the player? By its spell ID; by its name as well,
--- in case the game gives it another ID. Its stacks are returned too: the buff grows with the time spent near
--- the Salvager, and the stacks may tell how much.
--- @return boolean, number|nil stacks
function Disenchant.SalvagerActive()
    for _, a in ipairs(helpfulAuras()) do
        if a.id == Data.SALVAGER_AURA or a.name == Data.SALVAGER_AURA_NAME
            or (a.name and a.name:find("Salvager", 1, true)) then
            if a.id then ns.db.auraSeen[a.id] = a.name end
            return true, a.stacks
        end
    end
    return false
end

function Disenchant.PrintAuras()
    local list = helpfulAuras()
    if #list == 0 then ns.Print("no buffs") return end
    for _, a in ipairs(list) do ns.Print("%s (spell %s)", tostring(a.name), tostring(a.id)) end
    for id, name in pairs(ns.db.auraSeen) do ns.Print("seen during a disenchant: %s (spell %d)", name, id) end
end

-- The newest snapshots stay (the Salvager came long after the first disenchants).
local function snapshot()
    local snaps = ns.db.auraSnapshots
    local names = {}
    for _, a in ipairs(helpfulAuras()) do
        names[#names + 1] = tostring(a.name) .. ":" .. tostring(a.id) .. ((a.stacks or 0) > 1 and ("x" .. a.stacks) or "")
    end
    snaps[#snaps + 1] = { t = time(), auras = table.concat(names, ", ") }
    ns.Util.Cap(snaps, SNAPSHOTS)
end

--- Did this disenchant have the Salvager bonus? Yes when its effect was seen on the player, when the player
--- says every disenchant has it (`/salv salvager on`), or when the result proves it: more units of a
--- material than the table gives without the bonus.
--- @return boolean, string|nil how it is known ("aura" | "setting" | "result")
function Disenchant.HadSalvager(seen, outcomes, got)
    if seen then return true, "aura" end
    for _, o in ipairs(outcomes and outcomes.results or {}) do
        local q = o.id and got[o.id]
        if q and o.bonus and o.max and q > o.max then return true, "result" end
    end
    if ns.db.settings.salvager == "on" then return true, "setting" end
    return false
end

------------------------------------------------------------------ the disenchant

local function book(p, got)
    local link = p.link
    local itemID = ns.ItemID(link)
    local quality, classID = ns.QualityOf(link), ns.ClassOf(link)
    local ilvl = ns.ItemLevelOf(link)
    local _, _, _, _, reqLevel = ns.GetItemInfo(link)
    local outcomes = quality and classID and ilvl and Model.Outcomes(quality, classID, ilvl)
    local salvager, how = Disenchant.HadSalvager(p.salvager, outcomes, got)
    local planned
    if outcomes then
        -- (The forecast's outcomes: the table blended with your results, SDD 99.)
        local v = Model.Value(ns.Outcomes(quality, classID, ilvl, salvager) or outcomes, ns.PriceOf,
            ns.ValueOptions(salvager))
        planned = v.net
    end
    local rec = {
        t = time(), link = link, itemID = itemID, ilvl = ilvl, req = reqLevel, quality = quality,
        classID = classID, band = outcomes and outcomes.band, salvager = salvager, salvagerBy = how,
        salvagerStacks = p.stacks, got = got, planned = planned,
    }
    local purchase = itemID and Ledger.TakePurchase(ns.db.ledger, itemID)
    Ledger.Disenchant(ns.db.ledger, rec, purchase, ns.PriceOf, ns.Cut())
    local parts = {}
    for id, qty in pairs(got) do parts[#parts + 1] = qty .. "x " .. ns.MaterialName(id) end
    local msg = string.format("%s gave %s, worth %s", link, table.concat(parts, ", "), ns.Money(rec.value))
    if rec.costKnown then msg = msg .. string.format(" (paid %s)", ns.Money(rec.cost)) end
    ns.Print(msg)
    ns.Log("disenchant: %s%s", msg, salvager and (" [Salvager: " .. how .. "]") or "")
    ns.Fire("SALVAGER_LEDGER")
end

ns.On("UNIT_SPELLCAST_SENT", function(unit, _, _, spellID)
    if unit == "player" and spellID == Data.DISENCHANT_SPELL then
        local on, stacks = Disenchant.SalvagerActive()
        pending = { t = GetTime(), salvager = on, stacks = stacks }
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

-- The first batch at the Salvager (2026-11-26 06:14:42 to 06:17:12, 36 disenchants) was made before the addon
-- knew the buff's name, and was booked without it. The player was at the Salvager for all of it.
ns.On("SALVAGER_READY", function()
    if ns.db.firstSalvagerBatchFixed then return end
    ns.db.firstSalvagerBatchFixed = true
    local n = 0
    for _, r in ipairs(ns.db.ledger.disenchants) do
        if not r.salvager and (r.t or 0) >= 1795670082 and r.t <= 1795670232 then
            r.salvager, r.salvagerBy = true, "player"
            n = n + 1
        end
    end
    if n > 0 then ns.Log("disenchants: %d of the first Salvager batch now count as with the Salvager", n) end
end)

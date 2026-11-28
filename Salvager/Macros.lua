-- Salvager: two macros the player can drag to his bars and bind to keys (SDD 127, the user 2026-11-28):
--   "Salvager Buy"  /click SalvagerBuyTopButton                  the main window's Buy Top
--   "Salvager DE"   /click SalvagerDisenchantButton LeftButton   the Disenchant panel's secure button
-- A key press runs a macro in a hardware event, and `/click` passes it on to the button's click (the game's
-- SlashCommands.lua, branch forever: `button:Click(mouseButton, down)`), so Buy Top's C_AuctionHouse.PlaceBid
-- (HasRestrictions: a hardware event, not a secure-only call) goes through, and the secure button casts Disenchant.
-- Account-wide macros, made once (the first login with this version), out of combat, only where no macro of that
-- name exists (one the player edited is never overwritten), and only with free account macro slots. The Options'
-- "Create the macros again" (and /salv macros) makes a deleted one again.
-- Icons (SDD 136): CreateMacro and EditMacro take a file ID or the bare texture name, never a path (the game's
-- IconDataProvider.lua, branch forever, GetIconForSaving strips "INTERFACE\ICONS\" before saving); 0.4.1 passed
-- paths and its macros had no icon, so every load (and the Options' button) repairs those whose text is still ours.
local _, ns = ...

local Macros = {}
ns.Macros = Macros

local DISENCHANT = 13262                       -- the Disenchant spell's ID (its icon is the DE macro's)
local QUESTION_MARK = "INV_MISC_QUESTIONMARK"  -- the game's "no icon" texture name (the last resort)
local QUESTION_MARK_ID = 134400                -- its file ID (IconDataProvider.lua, QuestionMarkIconFileDataID)

-- icon: the bare texture name (a valid form); spell: a spell whose icon file ID is better where the API has it.
Macros.LIST = {
    { name = "Salvager Buy", icon = "INV_Misc_Coin_01", body = "/click SalvagerBuyTopButton" },
    { name = "Salvager DE", icon = "INV_Enchant_Disenchant", spell = DISENCHANT,
        body = "/click SalvagerDisenchantButton LeftButton" },
}

local waiting = false         -- a creation that waits for the fight to end
local repairWaiting = false   -- a repair that waits for the fight to end

--- The icon to save for macro `m`: a file ID where the client gives one, else the bare texture name, else the
--- question mark; never a path. @return number|string
function Macros.Icon(m)
    if m.spell then
        local id = _G.C_Spell and _G.C_Spell.GetSpellTexture and _G.C_Spell.GetSpellTexture(m.spell)
        if type(id) ~= "number" and _G.GetSpellTexture then id = _G.GetSpellTexture(m.spell) end
        if type(id) == "number" and id > 0 then return id end
    end
    local name = m.icon and tostring(m.icon):match("([^\\/]+)$")
    if name and name ~= "" then
        local id = _G.GetFileIDFromPath and _G.GetFileIDFromPath("Interface\\Icons\\" .. name)
        if type(id) == "number" and id > 0 then return id end
        return name
    end
    return QUESTION_MARK
end

-- No icon: nothing, 0, the question mark (as a file ID, a name or a path), or a path (never a saved form: 0.4.1's).
local function iconless(icon)
    if icon == nil or icon == 0 or icon == "" or icon == QUESTION_MARK_ID then return true end
    if type(icon) == "string" then
        return icon:upper():find(QUESTION_MARK, 1, true) ~= nil or icon:find("[\\/]") ~= nil
    end
    return false
end

local function maxAccount()
    local c = _G.Constants and _G.Constants.MacroConsts
    return (c and c.MAX_ACCOUNT_MACROS) or _G.MAX_ACCOUNT_MACROS or 120
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

--- Gives an icon to each Salvager macro that has none and whose text is still the addon's (one the player edited
--- is never touched). Out of combat only: in a fight it waits for the end. @return number  how many it repaired
function Macros.Repair()
    if not (GetMacroIndexByName and GetMacroInfo and _G.EditMacro) then return 0 end
    if InCombatLockdown and InCombatLockdown() then
        repairWaiting = true
        return 0
    end
    repairWaiting = false
    local n = 0
    for _, m in ipairs(Macros.LIST) do
        local index = GetMacroIndexByName(m.name) or 0
        if index > 0 then
            local _, icon, body = GetMacroInfo(index)
            if trim(body) == m.body and iconless(icon) then
                local new = Macros.Icon(m)
                local ok, err = pcall(_G.EditMacro, index, nil, new)
                if ok then
                    n = n + 1
                    ns.Log("INFO", "ui", string.format("macro %s: had no icon (%s): icon %s set", m.name,
                        tostring(icon), tostring(new)), { macro = m.name, icon = new })
                else
                    ns.Log("ERROR", "ui", string.format("Lua error setting the icon of the macro %s: %s", m.name,
                        tostring(err)), { macro = m.name })
                end
            end
        end
    end
    return n
end

--- Makes the macros that are missing. `byHand`: the player asked (Options, /salv macros): it says what it did either
--- way. @return number  how many it made
function Macros.Create(byHand)
    if not (GetMacroIndexByName and CreateMacro and GetNumMacros) then return 0 end
    if InCombatLockdown and InCombatLockdown() then
        if not waiting and byHand then ns.Print("the macros are made when the fight ends") end
        waiting = true
        return 0
    end
    waiting = false
    Macros.Repair()
    local missing = {}
    for _, m in ipairs(Macros.LIST) do
        local index = GetMacroIndexByName(m.name) or 0
        if index == 0 then
            missing[#missing + 1] = m
        else
            local _, _, body = GetMacroInfo(index)
            if trim(body) ~= m.body then
                ns.Log("INFO", "ui", string.format("macro %s: its text is not the addon's (%s): left as it is", m.name,
                    trim(body):sub(1, 60)), { macro = m.name })
            end
        end
    end
    ns.db.macrosMade = true
    if #missing == 0 then
        if byHand then ns.Print("the macros Salvager Buy and Salvager DE are there already (/macro)") end
        return 0
    end
    local free = maxAccount() - (GetNumMacros() or 0)
    if free < #missing then
        ns.Print("no room for the macros: free %d account macro slot%s in /macro, then Options, Create the macros again",
            #missing - free, #missing - free == 1 and "" or "s")
        return 0
    end
    local names = {}
    for _, m in ipairs(missing) do
        local ok, err = pcall(CreateMacro, m.name, Macros.Icon(m), m.body, false)
        if ok then
            names[#names + 1] = m.name
        else
            ns.Log("ERROR", "ui", string.format("Lua error creating the macro %s: %s", m.name, tostring(err)),
                { macro = m.name })
        end
    end
    if #names > 0 then
        ns.Print("macro%s %s created: drag %s from /macro to your bars", #names == 1 and "" or "s",
            table.concat(names, " and "), #names == 1 and "it" or "them")
        ns.Log("INFO", "ui", "macros created: " .. table.concat(names, ", "), { created = #names })
    end
    return #names
end

-- The first login with this version makes them; after that only the player's click does (a deleted one stays gone).
-- Every load repairs the icons. A fight waits for its end (Create repairs too).
ns.On("PLAYER_ENTERING_WORLD", function()
    if not ns.db.macrosMade then Macros.Create(false) else Macros.Repair() end
end)
ns.On("PLAYER_REGEN_ENABLED", function()
    if waiting then Macros.Create(false) elseif repairWaiting then Macros.Repair() end
end)

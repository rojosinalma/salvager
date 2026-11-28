-- Salvager: two macros the player can drag to his bars and bind to keys (SDD 127, the user 2026-11-28):
--   "Salvager Buy"  /click SalvagerBuyTopButton                  the main window's Buy Top
--   "Salvager DE"   /click SalvagerDisenchantButton LeftButton   the Disenchant panel's secure button
-- A key press runs a macro in a hardware event, and `/click` passes it on to the button's click (the game's
-- SlashCommands.lua, branch forever: `button:Click(mouseButton, down)`), so Buy Top's C_AuctionHouse.PlaceBid
-- (HasRestrictions: a hardware event, not a secure-only call) goes through, and the secure button casts Disenchant.
-- Account-wide macros, made once (the first login with this version), out of combat, only where no macro of that
-- name exists (one the player edited is never overwritten), and only with free account macro slots. The Options'
-- "Create the macros again" (and /salv macros) makes a deleted one again.
local _, ns = ...

local Macros = {}
ns.Macros = Macros

Macros.LIST = {
    { name = "Salvager Buy", icon = "Interface\\Icons\\INV_Misc_Coin_01", body = "/click SalvagerBuyTopButton" },
    { name = "Salvager DE", icon = "Interface\\Icons\\INV_Enchant_Disenchant",
        body = "/click SalvagerDisenchantButton LeftButton" },
}

local waiting = false   -- a creation that waits for the fight to end

local function maxAccount()
    local c = _G.Constants and _G.Constants.MacroConsts
    return (c and c.MAX_ACCOUNT_MACROS) or _G.MAX_ACCOUNT_MACROS or 120
end

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

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
    local missing = {}
    for _, m in ipairs(Macros.LIST) do
        local index = GetMacroIndexByName(m.name) or 0
        if index == 0 then
            missing[#missing + 1] = m
        else
            local _, _, body = GetMacroInfo(index)
            if trim(body) ~= m.body then
                ns.Log("macro %s: its text is not the addon's (%s): left as it is", m.name, trim(body):sub(1, 60))
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
        local ok, err = pcall(CreateMacro, m.name, m.icon, m.body, false)
        if ok then names[#names + 1] = m.name else ns.Log("ERROR creating the macro %s: %s", m.name, tostring(err)) end
    end
    if #names > 0 then
        ns.Print("macro%s %s created: drag %s from /macro to your bars", #names == 1 and "" or "s",
            table.concat(names, " and "), #names == 1 and "it" or "them")
        ns.Log("macros created: %s", table.concat(names, ", "))
    end
    return #names
end

-- The first login with this version makes them; after that only the player's click does (a deleted one stays gone).
ns.On("PLAYER_ENTERING_WORLD", function()
    if not ns.db.macrosMade then Macros.Create(false) end
end)
ns.On("PLAYER_REGEN_ENABLED", function()
    if waiting then Macros.Create(false) end
end)

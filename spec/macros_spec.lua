-- The two macros (SDD 127, the user 2026-11-28): "Salvager Buy" (/click SalvagerBuyTopButton) and "Salvager DE"
-- (/click SalvagerDisenchantButton LeftButton), account-wide, made once, out of combat, never over one the player
-- edited, and only with free slots.
local wow = require("spec.wow")

describe("The Salvager macros", function()
    local env, ns
    local function load(pre)
        env = wow.install()
        if pre then pre(env) end
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
    end
    local function said(text)
        for _, m in ipairs(env.chat) do if m:find(text, 1, true) then return true end end
        return false
    end

    it("makes both at the first login, says so once, and never again by itself", function()
        load()
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
        assert.are.equal(2, #env.macros)
        assert.are.same({ "Salvager Buy", "/click SalvagerBuyTopButton" }, { env.macros[1].name, env.macros[1].body })
        assert.are.same({ "Salvager DE", "/click SalvagerDisenchantButton LeftButton" },
            { env.macros[2].name, env.macros[2].body })
        assert.is_true(said("macros Salvager Buy and Salvager DE created: drag them from /macro to your bars"))
        local lines = #env.chat
        table.remove(env.macros, 2)                                -- the player deletes one
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
        assert.are.equal(1, #env.macros)                           -- not made again by itself
        assert.are.equal(lines, #env.chat)
        ns.Macros.Create(true)                                     -- Options, "Create the macros again"
        assert.are.equal(2, #env.macros)
        assert.are.equal("Salvager DE", env.macros[2].name)
        -- The button Buy Top has the name the macro clicks.
        ns.UI.Show()
        assert.are.equal(ns.UI.buyTop, _G.SalvagerBuyTopButton)
    end)

    it("leaves a macro of that name the player edited as it is", function()
        load(function(e) e.macros[1] = { name = "Salvager Buy", icon = "x", body = "/click SalvagerBuyTopButton\n/cheer" } end)
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
        assert.are.equal(2, #env.macros)
        assert.are.equal("/click SalvagerBuyTopButton\n/cheer", env.macros[1].body)
        local logged = false
        for _, l in ipairs(ns.db.log) do
            if ns.LogText(l):find("macro Salvager Buy: its text is not the addon's", 1, true) then logged = true end
        end
        assert.is_true(logged)
    end)

    it("waits for the fight to end", function()
        load(function(e) e.combat = true end)
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
        assert.are.equal(0, #env.macros)
        env.combat = false
        wow.fire(ns, "PLAYER_REGEN_ENABLED")
        assert.are.equal(2, #env.macros)
    end)

    it("says how many slots to free when the account's macros are full", function()
        load(function(e)
            e.macroMax = 120
            for i = 1, 119 do e.macros[i] = { name = "m" .. i, body = "" } end
        end)
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
        assert.are.equal(119, #env.macros)
        assert.is_true(said("no room for the macros: free 1 account macro slot in /macro"))
    end)

    -- SDD 136: an icon is a file ID or a bare texture name, never a path (0.4.1's macros had none).
    local function validIcon(icon)
        return type(icon) == "number" or (type(icon) == "string" and icon ~= "" and not icon:find("[\\/]"))
    end
    local function logged(text)
        for _, l in ipairs(ns.db.log) do if ns.LogText(l):find(text, 1, true) then return true end end
        return false
    end

    it("makes them with a valid icon: the Disenchant spell's file ID, the coin's bare name", function()
        load()
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
        assert.is_true(validIcon(env.macros[1].icon) and validIcon(env.macros[2].icon))
        assert.are.equal("INV_Misc_Coin_01", env.macros[1].icon)
        assert.are.equal(136244, env.macros[2].icon)
    end)

    it("falls back to the bare name, then to the question mark, never a path", function()
        load(function(e) e.spellIcons = {} end)
        assert.are.equal("INV_Enchant_Disenchant", ns.Macros.Icon(ns.Macros.LIST[2]))
        _G.GetFileIDFromPath = function(path) return path == "Interface\\Icons\\INV_Misc_Coin_01" and 133784 or nil end
        assert.are.equal(133784, ns.Macros.Icon(ns.Macros.LIST[1]))
        _G.GetFileIDFromPath = nil
        assert.are.equal("INV_Misc_Coin_01", ns.Macros.Icon({ icon = "Interface\\Icons\\INV_Misc_Coin_01" }))
        assert.are.equal("INV_MISC_QUESTIONMARK", ns.Macros.Icon({}))
    end)

    it("gives an icon at load to the old icon-less macros, and logs each repair", function()
        load(function(e)
            e.macros[1] = { name = "Salvager Buy", icon = 134400, body = "/click SalvagerBuyTopButton" }
            e.macros[2] = { name = "Salvager DE", icon = nil, body = "/click SalvagerDisenchantButton LeftButton" }
        end)
        ns.db.macrosMade = true                                    -- made by 0.4.1
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
        assert.are.same({ "INV_Misc_Coin_01", 136244 }, { env.macros[1].icon, env.macros[2].icon })
        assert.is_true(logged("macro Salvager Buy: had no icon (134400): icon INV_Misc_Coin_01 set"))
        assert.is_true(logged("macro Salvager DE: had no icon (nil): icon 136244 set"))
        local edits = env.macroEdits
        wow.fire(ns, "PLAYER_ENTERING_WORLD")                      -- with icons now: nothing more
        assert.are.equal(edits, env.macroEdits)
    end)

    it("repairs a path icon and the question mark name too, and Create the macros again repairs", function()
        load(function(e)
            e.macros[1] = { name = "Salvager Buy", icon = "Interface\\Icons\\INV_Misc_Coin_01",
                body = "/click SalvagerBuyTopButton" }
            e.macros[2] = { name = "Salvager DE", icon = "INV_MISC_QUESTIONMARK",
                body = "/click SalvagerDisenchantButton LeftButton" }
        end)
        ns.db.macrosMade = true
        env.combat = true                                          -- load in a fight: Repair waits
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
        env.combat = false
        ns.Macros.Create(true)                                     -- Options, "Create the macros again"
        assert.are.same({ "INV_Misc_Coin_01", 136244 }, { env.macros[1].icon, env.macros[2].icon })
        assert.are.equal(2, #env.macros)
    end)

    it("never touches a macro of that name whose text the player changed", function()
        load(function(e)
            e.macros[1] = { name = "Salvager Buy", icon = 134400, body = "/click SalvagerBuyTopButton\n/cheer" }
        end)
        ns.db.macrosMade = true
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
        ns.Macros.Create(true)
        assert.are.equal(134400, env.macros[1].icon)
        assert.are.equal("/click SalvagerBuyTopButton\n/cheer", env.macros[1].body)
    end)

    it("repairs in a fight only when the fight ends, and does not make a deleted one again", function()
        load(function(e)
            e.combat = true
            e.macros[1] = { name = "Salvager DE", body = "/click SalvagerDisenchantButton LeftButton" }
        end)
        ns.db.macrosMade = true                                    -- Salvager Buy was deleted by the player
        wow.fire(ns, "PLAYER_ENTERING_WORLD")
        assert.is_nil(env.macros[1].icon)
        env.combat = false
        wow.fire(ns, "PLAYER_REGEN_ENABLED")
        assert.are.equal(136244, env.macros[1].icon)
        assert.are.equal(1, #env.macros)
    end)
end)

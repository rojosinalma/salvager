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
end)

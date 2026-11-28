-- The main window of 0.4.0 (the user, 2026-11-28): the "Arcane Salvager" box on the Scan settings (it replaced the
-- Options' "Bonus in buy prices" and the footer's "Arcane Salvager bonus included"), the footer without window buttons,
-- Options in the title bar.
local wow = require("spec.wow")

local function load(settings, env0)
    local env = wow.install({ layout = true })
    if env0 then env0(env) end
    _G.SalvagerDB = settings and { settings = settings } or nil
    local ns = wow.loadAddon()
    wow.fire(ns, "ADDON_LOADED", "Salvager")
    return env, ns
end

describe("The Arcane Salvager box (0.4.0)", function()
    it("takes the old setting once: on checked, off unchecked, auto as the player can use it now", function()
        for _, case in ipairs({ { "on", false, true }, { "off", true, false }, { "auto", false, false },
            { "auto", true, true } }) do
            local _, ns = load({ salvager = case[1] }, function(env)
                if case[2] then env.bags[279985] = 1 end   -- (Data.SALVAGER_ITEM)
            end)
            wow.fire(ns, "AUCTION_HOUSE_SHOW")
            local s = ns.db.settings
            assert.are.equal(case[3], s.salvagerBuy, case[1] .. (case[2] and " with one in the bags" or ""))
            assert.is_nil(s.salvager)
            -- Then the box is the source: the Salvager in the bags no longer changes it.
            assert.are.equal(case[3], ns.SalvagerForBuy())
        end
    end)

    it("is a check box on the Scan settings, checked = buys valued with the bonus, with its help; the footer has no text of it", function()
        local env, ns = load()
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        ns.UI.Show()
        local box
        for _, fr in ipairs(env.frames) do
            if rawget(fr, "uiKind") == "check" and fr.label and fr.label.text == "Arcane Salvager" then box = fr end
        end
        assert.is_table(box)
        assert.are.equal("settings", rawget(box.parent, "uiKind"))   -- (in the Scan settings block)
        box:SetChecked(true)
        box.scripts.OnClick(box)
        assert.is_true(ns.db.settings.salvagerBuy)
        assert.is_true(ns.ValueOptions().salvager)
        box:SetChecked(false)
        box.scripts.OnClick(box)
        assert.is_false(ns.db.settings.salvagerBuy)
        assert.is_false(ns.ValueOptions().salvager and true or false)
        -- No "bonus included" in the footer any more, in either state.
        for _, on in ipairs({ true, false }) do
            ns.db.settings.salvagerBuy = on
            ns.UI.Refresh()
            for _, fr in ipairs(env.frames) do
                for _, t in ipairs(fr._regions or {}) do
                    assert.is_nil(tostring(rawget(t, "text") or ""):find("bonus included", 1, true))
                end
            end
        end
        -- The Options have no choice of it.
        ns.Options.Open()
        for _, fr in ipairs(env.frames) do
            for _, t in ipairs(fr._regions or {}) do
                assert.is_nil(tostring(rawget(t, "text") or ""):find("Bonus in buy prices", 1, true))
            end
        end
    end)

    it("has no window buttons in the main window's footer, and Options as a gear left of Minimize", function()
        local _, ns = load()
        wow.fire(ns, "AUCTION_HOUSE_SHOW")
        ns.UI.Show()
        local bar = ns.UI.footerBar
        for _, c in ipairs(bar._children) do
            local t = rawget(c, "text") or (rawget(c, "_fs") and c._fs.text)
            for _, name in ipairs({ "Auction house", "Ledger", "Reports", "Market", "Charts", "Disenchant", "Limits", "Log" }) do
                assert.are_not.equal(name, t)
            end
        end
        local o, m = ns.UI.optionsButton, ns.UI.minimizeButton
        assert.is_true(o:IsShown())
        assert.is_true(o:GetRight() <= m:GetLeft() + 0.01)
        assert.is_true(math.abs((o:GetTop() + o:GetBottom()) / 2 - (m:GetTop() + m:GetBottom()) / 2) < 0.5)
    end)
end)

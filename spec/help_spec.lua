-- Every hover help and "?" box (UI.md Words 4, the user 2026-11-28): a title, then each explanation on its own line,
-- one empty line between them, none after the last; one builder (Widgets.AddHelp, Widgets.Explanations).
local wow = require("spec.wow")

describe("Help, one explanation per line", function()
    local env, ns, lines
    setup(function()
        env = wow.install()
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        local tip = _G.GameTooltip
        tip.SetText = function(_, t) lines = { t } end
        tip.AddLine = function(_, t) table.insert(lines, t) end
        tip.NumLines = function() return #lines end
    end)

    it("renders title, line, blank, line, blank, line for three explanations", function()
        ns.Widgets.AddHelp(_G.GameTooltip, "Title", { "One.", "Two.", "Three." })
        assert.are.same({ "Title", "One.", " ", "Two.", " ", "Three." }, lines)
    end)

    it("cuts a text into its sentences and paragraphs, the words kept", function()
        local e = ns.Widgets.Explanations("Green: under 30%. Yellow: 30% or more.\n\nRed: 60% or more. 0.5 stays (e.g. 1.5).")
        assert.are.same({ "Green: under 30%.", "Yellow: 30% or more.", "Red: 60% or more. 0.5 stays (e.g. 1.5)." }, e)
    end)

    it("does it in a widget's tooltip and in a table title's help", function()
        local f = CreateFrame("Frame", nil, UIParent)
        ns.Widgets.Tooltip(f, "Gold", "The gold you have now. It updates live.")
        f.scripts.OnEnter(f)
        assert.are.same({ "Gold", "The gold you have now.", " ", "It updates live." }, lines)
        -- A help added after a tooltip's own lines: a blank line before it.
        _G.GameTooltip:SetText("Disenchant")
        _G.GameTooltip:AddLine("Casts it.")
        ns.Widgets.AddHelp(_G.GameTooltip, nil, "A key does the same.")
        assert.are.same({ "Disenchant", "Casts it.", " ", "A key does the same." }, lines)
        assert.is_table(env)
    end)
end)

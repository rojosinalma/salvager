-- Text widths as the game client measures them (SDD 123). spec/fixtures/text_widths.lua holds what the client drew
-- (GetUnboundedStringWidth in the layout dump of 2026-11-28): per text its font object and width. The stand-in's
-- model (spec/wow.lua) must give those widths per font, and the width authority (Widgets.TextWidth, FitColumns) must
-- make each column the client's drawn width + CELL_PAD: a measure that drifts from what the client draws (a model
-- with one share for every size, a meter in another font than the cells') fails here, not in the game.
local wow = require("spec.wow")
local FACTS = dofile("spec/fixtures/text_widths.lua")

local TOL_PX, TOL_SHARE = 2.5, 0.05   -- (the model is a fit: within 2 px of every sample)

local function near(model, drawn) return math.abs(model - drawn) <= math.max(TOL_PX, drawn * TOL_SHARE) end

describe("Text widths as the client draws them (SDD 123)", function()
    local ns
    setup(function()
        wow.install({ layout = true })
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
    end)

    it("has facts for the titles', the cells' and the larger font", function()
        local fonts = {}
        for _, f in ipairs(FACTS) do fonts[f[1]] = (fonts[f[1]] or 0) + 1 end
        assert.is_true((fonts.GameFontNormalSmall or 0) >= 15, "titles")
        assert.is_true((fonts.GameFontHighlightSmall or 0) >= 40, "cells")
        assert.is_true((fonts.GameFontNormal or 0) + (fonts.GameFontHighlight or 0) + (fonts.GameFontDisable or 0) >= 15,
            "12 pt")
    end)

    it("draws each text as wide as the client did, in its own font (the stand-in's model)", function()
        local bad = {}
        for _, f in ipairs(FACTS) do
            local fs = UIParent:CreateFontString(nil, "OVERLAY", f[1])
            fs:SetText(f[2])
            local w = fs:GetUnboundedStringWidth()
            if not near(w, f[3]) then bad[#bad + 1] = string.format("%s %q: %.1f, the client %.1f", f[1], f[2], w, f[3]) end
        end
        assert.are.equal("", table.concat(bad, "\n"))
    end)

    it("measures with the font the text is drawn in: titles, cells and totals each in their own", function()
        local W = ns.Widgets
        local bad = {}
        for _, f in ipairs(FACTS) do
            local fs = UIParent:CreateFontString(nil, "OVERLAY", f[1])
            fs:SetText(f[2])
            local m = W.TextWidth(f[2], f[1])
            if math.abs(m - fs:GetUnboundedStringWidth()) > 0.01 then bad[#bad + 1] = f[1] .. " " .. f[2] end
        end
        assert.are.equal("", table.concat(bad, "\n"))
        -- A total (BOLD_FONT, 12 pt) is wider than the same text in a row (CELL_FONT, 10 pt) by the client's ratio
        -- (1.17 to 1.20 in the dump: "Gear" 26.1 and 30.9, "Materials" 49.4 and 57.6, "Buy" 20.6 and 24.7).
        for _, t in ipairs({ { "Gear", 26.1, 30.9 }, { "Materials", 49.4, 57.6 }, { "Buy", 20.6, 24.7 } }) do
            assert.is_true(near(W.TextWidth(t[1], W.CELL_FONT), t[2]), t[1] .. " in a row")
            assert.is_true(near(W.TextWidth(t[1], W.BOLD_FONT), t[3]), t[1] .. " in a total")
        end
    end)

    it("makes a column the client's drawn width + CELL_PAD (the width authority)", function()
        local W = ns.Widgets
        local bad = {}
        local function want(sw) return math.ceil(sw) + W.CELL_PAD end
        for _, f in ipairs(FACTS) do
            local need
            if f[1] == W.TITLE_FONT then
                need = W.FitColumns({ f[2] }, 0, function() return nil end)
            elseif f[1] == W.CELL_FONT or f[1] == W.BOLD_FONT then
                need = W.FitColumns({ "" }, 1, function() return { f[2] }, 0, f[1] end)
            end
            if need and math.abs(need[1] - want(f[3])) > math.max(3, f[3] * TOL_SHARE) then
                bad[#bad + 1] = string.format("%s %q: column %d, the client's text needs %d", f[1], f[2], need[1], want(f[3]))
            end
        end
        assert.are.equal("", table.concat(bad, "\n"))
    end)
end)

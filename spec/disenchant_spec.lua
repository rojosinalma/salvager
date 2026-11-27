-- The Disenchant panel (0.3.146, the user, 2026-11-27; SDD 112): it opens by itself on new purchased gear in the bags,
-- lists the Current batch's pieces in the bags and its disenchants, and its secure button casts Disenchant on the
-- next piece, one cast a click.
local wow = require("spec.wow")

describe("The Disenchant panel", function()
    local env, ns, P
    local GEAR, OWN, NODE, DUST = 6001, 6002, 4614, 10940
    local function link(id) return "|cff1eff00|Hitem:" .. id .. "::::::::30:::::|h[" .. env.items[id].name .. "]|h|r" end

    local function settle() wow.tick(ns, 0.5) end
    local function bagUpdate()
        wow.fire(ns, "BAG_UPDATE_DELAYED")
        settle()
    end
    --- Puts gear in a bag slot (the game's item count follows).
    local function put(bag, slot, id)
        env.bagItems[bag .. ":" .. slot] = id
        env.bagLinks[bag .. ":" .. slot] = id and link(id) or nil
        local n = 0
        for _, v in pairs(env.bagItems) do if v == GEAR then n = n + 1 end end
        env.bags[GEAR] = n
    end
    local function buy(n, t) ns.Ledger.AddPurchase(ns.db.ledger, GEAR, n, 500 * n, 900, t or env.clock, link(GEAR)) end
    --- A disenchant of the piece in bag 0, slot `slot`, as the client sends it; the piece leaves the bags.
    local function disenchant(slot, qty)
        wow.fire(ns, "UNIT_SPELLCAST_SENT", "player", nil, "guid", 13262)
        wow.fire(ns, "UNIT_SPELLCAST_START", "player", "guid", 13262)
        wow.fire(ns, "ITEM_LOCK_CHANGED", 0, slot)
        wow.fire(ns, "LOOT_OPENED")
        env.loot = { { id = DUST, qty = qty } }
        wow.fire(ns, "LOOT_READY")
        wow.fire(ns, "UNIT_SPELLCAST_SUCCEEDED", "player", "guid", 13262)
        put(0, slot, nil)
        env.bags[DUST] = (env.bags[DUST] or 0) + qty   -- (the loot is in the bags)
        wow.fire(ns, "LOOT_CLOSED")
        bagUpdate()
    end
    local function frame() return ns.DisenchantPanel.Frame() end

    setup(function()
        env = wow.install()
        env.items[GEAR] = { name = "Test Bracers", quality = 2, ilvl = 25, req = 20, classID = 4 }
        env.items[OWN] = { name = "My Own Cloak", quality = 2, ilvl = 25, req = 20, classID = 4 }
        env.items[NODE] = { name = "Unbreakable Gloves", quality = 2, ilvl = 25, req = 20, classID = 4 }
        env.items[DUST] = { name = "Strange Dust", quality = 1, ilvl = 1, classID = 7 }
        env.bagSize = { [0] = 8, [1] = 8 }
        env.bagItems, env.bagLinks = {}, {}
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        P = ns.DisenchantPanel
        ns.db.prices[DUST] = { p = 100, t = env.clock }
    end)

    it("opens by itself on new purchased gear in the bags, once per piece, never for other gear, not in combat", function()
        assert.is_falsy(frame():IsShown())
        -- Your own gear and gear the game will not disenchant: never offered, and no opening.
        put(0, 5, OWN)
        ns.Ledger.AddPurchase(ns.db.ledger, NODE, 1, 100, 200, env.clock, link(NODE))
        env.bagItems["0:6"], env.bags[NODE] = NODE, 1
        bagUpdate()
        assert.is_false(frame():IsShown())
        assert.are.equal(0, #P.Pieces())
        -- Two purchased pieces land (the mail taken): it opens.
        buy(2)
        put(0, 1, GEAR)
        put(0, 2, GEAR)
        bagUpdate()
        assert.is_true(frame():IsShown())
        local pieces = P.Pieces()
        assert.are.equal(2, #pieces)
        assert.are.same({ 0, 1 }, { pieces[1].bag, pieces[1].slot })
        -- Closed, it stays closed while nothing new comes.
        frame().UserHide()
        bagUpdate()
        wow.fire(ns, "SALVAGER_LEDGER")
        settle()
        assert.is_false(frame():IsShown())
        -- A fight: new gear does not open it; the end of the fight does.
        wow.fire(ns, "PLAYER_REGEN_DISABLED")
        env.combat = true
        buy(1)
        put(0, 3, GEAR)
        bagUpdate()
        assert.is_false(frame():IsShown())
        env.combat = false
        wow.fire(ns, "PLAYER_REGEN_ENABLED")
        assert.is_true(frame():IsShown())
        assert.are.equal(3, #P.Pieces())
    end)

    it("aims its secure button at the next piece and moves on after each bag update", function()
        local b = _G.SalvagerDisenchantButton
        assert.are.equal(P.button, b)
        assert.is_true(b.secure)
        assert.are.same({ "spell", 13262, 0, 1 }, { b:GetAttribute("type"), b:GetAttribute("spell"),
            b:GetAttribute("target-bag"), b:GetAttribute("target-slot") })
        assert.is_true(b:IsEnabled())
        assert.are.equal("3 left", P.leftLabel:GetText())
        assert.truthy(P.nextLabel:GetText():find("Test Bracers", 1, true))
        -- A click casts on bag 0, slot 1.
        b:Click("LeftButton")
        assert.are.same({ spell = 13262, bag = 0, slot = 1 }, env.casts[#env.casts])
        -- While it casts: off, with the reason; a click (or the key) does nothing.
        wow.fire(ns, "UNIT_SPELLCAST_START", "player", "guid", 13262)
        assert.is_false(b:IsEnabled())
        assert.are.equal("Disenchanting...", b.reason)
        local casts = #env.casts
        b:Click("LeftButton")
        assert.are.equal(casts, #env.casts)
        wow.fire(ns, "UNIT_SPELLCAST_STOP", "player", "guid", 13262)
        -- The loot window open: off too.
        wow.fire(ns, "LOOT_OPENED")
        assert.is_false(b:IsEnabled())
        assert.truthy(b.reason:find("loot window", 1, true))
        wow.fire(ns, "LOOT_CLOSED")
        assert.is_true(b:IsEnabled())
        -- The disenchant ends; the bags change: it aims at the next piece.
        disenchant(1, 3)
        assert.are.same({ 0, 2 }, { b:GetAttribute("target-bag"), b:GetAttribute("target-slot") })
        assert.are.equal("2 left", P.leftLabel:GetText())
        -- A piece moved between two updates: the click aims again first (PreClick), never at another item.
        put(0, 2, nil)
        put(1, 4, GEAR)
        b:Click("LeftButton")
        assert.are.same({ spell = 13262, bag = 0, slot = 3 }, env.casts[#env.casts])
        bagUpdate()
        -- In a fight: no aim, off with the reason, the panel closes; after it, all back.
        wow.fire(ns, "PLAYER_REGEN_DISABLED")
        env.combat = true
        assert.is_nil(b:GetAttribute("type"))
        assert.is_false(b:IsEnabled())
        assert.truthy(b.reason:find("combat", 1, true))
        assert.is_false(frame():IsShown())
        casts = #env.casts
        b:Click("LeftButton")
        assert.are.equal(casts, #env.casts)
        bagUpdate()                                  -- (no attribute change in combat: the stand-in would fail)
        env.combat = false
        wow.fire(ns, "PLAYER_REGEN_ENABLED")
        assert.is_true(frame():IsShown())
        assert.are.equal("spell", b:GetAttribute("type"))
        assert.is_true(b:IsEnabled())
    end)

    it("builds both tables from the batch, the results newest first with their totals", function()
        env.clock = env.clock + 60
        disenchant(3, 5)
        local top, bottom, pieces = P.Rows()
        assert.are.equal(#pieces, #top)
        assert.are.equal(1, #pieces)                               -- (bag 1, slot 4)
        -- The same cells as the Ledger's Current batch (one builder).
        local LW = ns.LedgerWindow
        local batch = LW.Batch()
        local ledgerRow = LW.BatchWaitingRow(pieces[1].p)
        for i, key in ipairs({ "gear", "ilvl", "paid", "ev", "ep" }) do
            assert.are.equal(ledgerRow.cells[LW.BATCH[key]], top[1].cells[i], key)
        end
        -- Results: the last disenchant first (5 dust), then the one before (3), then the totals.
        assert.are.equal(3, #bottom)
        assert.truthy(bottom[1].cells[3]:find("5x", 1, true))
        assert.truthy(bottom[2].cells[3]:find("3x", 1, true))
        assert.are.equal("total", bottom[3].rule)
        assert.truthy(bottom[3].cells[1]:find("2 pieces", 1, true))
        assert.are.equal(ns.Money(1000), bottom[3].cells[2])       -- paid: 2 x 500
        assert.are.equal(LW.BatchDoneRow(batch.done[1]).cells[LW.BATCH.dv], bottom[1].cells[4])
        -- The Auto Loot note shows only while it is off.
        env.cvars.autoLootDefault = false
        P.Refresh()
        assert.is_true(P.lootNote:IsShown())
        env.cvars.autoLootDefault = true
        P.Refresh()
        assert.is_false(P.lootNote:IsShown())
    end)

    it("offers only the gear the Options' filter lets in: quality, gear type, item level (SDD 112b)", function()
        local n = #P.Pieces()
        assert.is_true(n >= 1)
        local x = ns.db.settings.disenchantFilter
        x.qualities[2] = false                                   -- the test gear is Uncommon: out
        assert.are.equal(0, #P.Pieces())
        x.qualities[2] = true
        x.classes[ns.ClassOf(GEAR) or 4] = false                 -- its gear type: out
        assert.are.equal(0, #P.Pieces())
        x.classes[ns.ClassOf(GEAR) or 4] = true
        x.minIlvl = 26                                           -- item level 25: under the range
        assert.are.equal(0, #P.Pieces())
        x.minIlvl, x.maxIlvl = 20, 25                            -- inside it
        assert.are.equal(n, #P.Pieces())
        x.minIlvl, x.maxIlvl = 0, 24                             -- over it
        assert.are.equal(0, #P.Pieces())
        x.maxIlvl = 0
        assert.are.equal(n, #P.Pieces())
    end)

    it("is off with nothing left, and opens from the mini panel, the main window and /salv disenchant", function()
        local b = P.button
        put(1, 4, nil)
        bagUpdate()
        assert.are.equal(0, #P.Pieces())
        assert.is_false(b:IsEnabled())
        assert.is_nil(b:GetAttribute("type"))
        assert.truthy(b.reason:find("Nothing left", 1, true))
        local casts = #env.casts
        b:Click("LeftButton")
        assert.are.equal(casts, #env.casts)
        -- The empty table says why and what fills it.
        local top = P.Rows()
        assert.truthy(top[1].cells[1]:find("No gear you bought", 1, true))
        frame().UserHide()
        SlashCmdList.SALVAGER("disenchant")
        assert.is_true(frame():IsShown())
        SlashCmdList.SALVAGER("disenchant")
        assert.is_false(frame():IsShown())
        ns.MiniPanel.Show()
        ns.MiniPanel.buttons.Disenchant:Click()
        assert.is_true(frame():IsShown())
        assert.are.equal("panel", rawget(frame(), "owner"))
        -- The key binding: its name, on the button the binding clicks.
        assert.are.equal("Disenchant next piece", _G["BINDING_NAME_CLICK SalvagerDisenchantButton:LeftButton"])
        local xml = io.open("Salvager/Bindings.xml"):read("*a")
        assert.truthy(xml:find("CLICK SalvagerDisenchantButton:LeftButton", 1, true))
        -- Escape closes it.
        local found = false
        for _, name in ipairs(UISpecialFrames) do if name == "SalvagerDisenchantFrame" then found = true end end
        assert.is_true(found)
    end)
end)

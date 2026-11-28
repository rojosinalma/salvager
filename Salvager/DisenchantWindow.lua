-- Salvager: the Disenchant panel ("Salvager Disenchant", SDD 112). The Current batch in a small window: the gear you
-- bought and picked up that is in your bags, the next piece first, and the disenchants of the batch, the newest first.
-- Its Disenchant button (a secure action button: the game casts only from a click or a key) casts Disenchant on the
-- next piece; each click or key press is one cast. It opens by itself when new purchased gear lands in the bags.
-- Only purchased gear is ever aimed at: the player's own gear is never in the list.
local _, ns = ...

local Data, W = ns.Data, ns.Widgets

local Panel = {}
ns.DisenchantPanel = Panel

local GREY, GOLD = "|cff808080", "|cffffd100"
local BUTTON = "SalvagerDisenchantButton"
local W0, H0, MIN_W, MIN_H = 640, 440, 520, 320   -- the size it opens with (Widgets.FitTables sets the width)
local TOP, TITLE_H, FOOT = 28, 20, 44              -- under the title bar; a table's title; over the footer
local BUTTON_W, CLOSE_W = 120, 64

-- The key binding (Bindings.xml): Key Bindings, AddOns, Salvager.
_G.BINDING_HEADER_SALVAGER = "Salvager"
_G["BINDING_NAME_CLICK " .. BUTTON .. ":LeftButton"] = "Disenchant next piece"

local f, button, bags, results, bagsTitle, resultsTitle, lootNote, nextLabel, leftLabel
local state = { casting = false, loot = false, wasOpen = false, pendingOpen = false }
Panel.state = state

local function combat() return InCombatLockdown and InCombatLockdown() or false end

------------------------------------------------------------------ the pieces

--- Is this gear one the game disenchants? (Armor or weapons, Uncommon to Epic, not in the "no disenchant" list.)
local function disenchantable(itemID, link)
    if ns.NoDisenchant(itemID) then return false end
    local classID = ns.ClassOf(link or itemID)
    if classID and classID ~= Data.CLASS_ARMOR and classID ~= Data.CLASS_WEAPON then return false end
    local q = ns.QualityOf(link or itemID)
    return q == nil or (q >= 2 and q <= 4)
end

--- Does the Options' Disenchant panel filter let this gear in? (Quality, gear type, item level; what is not known
--- passes.) SDD 112b.
function Panel.Passes(itemID, link, p)
    local x = ns.db.settings.disenchantFilter
    if not x then return true end
    local j = p and p.j or {}
    local q = ns.QualityOf(link or itemID) or j.q
    if q and x.qualities and not x.qualities[q] then return false end
    local cls = ns.ClassOf(link or itemID) or j.cls
    if cls and x.classes and not x.classes[cls] then return false end
    local ilvl = ns.ItemLevelOf(link or itemID) or j.ilvl
    if ilvl then
        if (x.minIlvl or 0) > 0 and ilvl < x.minIlvl then return false end
        if (x.maxIlvl or 0) > 0 and ilvl > x.maxIlvl then return false end
    end
    return true
end

--- The pieces of the Current batch in the bags (not the bank, not worn), in bag order: the next one first. Each is
--- paired with a purchase of the batch of the same gear, the oldest first (the one a disenchant books, Ledger.TakePurchase).
--- @return table { { bag, slot, itemID, link, p = the batch's purchase entry }, ... }, table batch (Ledger.Batch)
function Panel.Pieces()
    local batch = ns.LedgerWindow.Batch()
    local byItem = {}
    for i = #batch.waiting, 1, -1 do   -- (waiting is newest first)
        local p = batch.waiting[i]
        byItem[p.itemID] = byItem[p.itemID] or {}
        table.insert(byItem[p.itemID], p)
    end
    local out = {}
    if not next(byItem) then return out, batch end
    for bag = 0, (NUM_BAG_SLOTS or 4) do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            local id = C_Container.GetContainerItemID(bag, slot)
            local list = id and byItem[id]
            if list and #list > 0 then
                local link = C_Container.GetContainerItemLink(bag, slot)
                if disenchantable(id, link) and Panel.Passes(id, link, list[1]) then
                    local p = table.remove(list, 1)
                    out[#out + 1] = { bag = bag, slot = slot, itemID = id, link = link or p.link, p = p }
                end
            end
        end
    end
    return out, batch
end

--- Why the Disenchant button is off now, or nil when it casts on the next piece; and the same in a few words, for
--- the footer (the full reason is in the button's tooltip; the long one was cut at the count, 0.3.151).
function Panel.Reason(pieces)
    if combat() then return "In combat: Disenchant waits until the fight ends.", "In combat" end
    if state.casting then return "Disenchanting...", "Disenchanting..." end
    if state.loot then return "The loot window is open: take the loot first.", "Take the loot first" end
    if #pieces == 0 then return "Nothing left to disenchant: no gear of your purchases is in your bags.",
        "Nothing left to disenchant" end
    return nil
end

------------------------------------------------------------------ the secure button

--- Points the button at the next piece (type "spell", spell 13262, target-bag and target-slot: the game casts the
--- spell, then uses the bag slot as its target, SecureTemplates.lua), or at nothing. Only out of combat: the client
--- refuses attribute changes in combat.
function Panel.Aim(piece)
    if not button or combat() then return false end
    if piece then
        button:SetAttribute("type", "spell")
        button:SetAttribute("spell", Data.DISENCHANT_SPELL)
        button:SetAttribute("target-bag", piece.bag)
        button:SetAttribute("target-slot", piece.slot)
    else
        button:SetAttribute("type", nil)
        button:SetAttribute("spell", nil)
        button:SetAttribute("target-bag", nil)
        button:SetAttribute("target-slot", nil)
    end
    button.piece = piece
    return true
end

local function buttonText(piece)
    local icon = piece and W.IconOf(piece.itemID)
    return (icon and ("|T" .. icon .. ":16:16|t ") or "") .. "Disenchant"
end

--- The button's state after a bag change, a cast, the loot window or the end of a fight. `pieces`: Panel.Pieces()
--- when the caller has it (else read now). @return table|nil the pieces
function Panel.Update(pieces)
    if not button then return end
    pieces = pieces or Panel.Pieces()
    local reason, short = Panel.Reason(pieces)
    button.reason = reason
    if not combat() then
        Panel.Aim(not reason and pieces[1] or nil)
        button:SetEnabled(reason == nil)
        button:SetText(buttonText(pieces[1]))
    end
    if nextLabel then
        local p = pieces[1]
        nextLabel:SetText(reason and (GREY .. short .. "|r")
            or ("Next: " .. (p.link or ns.GetItemInfo(p.itemID) or ("item " .. p.itemID))))
        leftLabel:SetText(#pieces .. " left")
    end
    return pieces
end

local function buildButton(parent)
    button = CreateFrame("Button", BUTTON, parent, "SecureActionButtonTemplate,UIPanelButtonTemplate")
    button.uiKind = "button"
    button:SetSize(BUTTON_W, 22)
    button:SetText("Disenchant")
    -- A click on the mouse and a key press both cast, whichever way the game's "cast on key down" is set.
    button:RegisterForClicks("AnyUp", "AnyDown")
    -- Before the secure click: the slot must still hold the piece it aims at (bags can change between two updates).
    -- Out of combat the aim can still change here; in combat the click does nothing (no aim), and says why.
    button:SetScript("PreClick", function(self)
        local piece = self.piece
        if combat() then
            ns.Print("in combat: Disenchant waits until the fight ends")
            return
        end
        if piece and C_Container.GetContainerItemID(piece.bag, piece.slot) ~= piece.itemID then
            local pieces = Panel.Pieces()
            Panel.Aim(not Panel.Reason(pieces) and pieces[1] or nil)
        end
        if self.piece then ns.Log("disenchant panel: casting on %s (bag %d, slot %d)", tostring(self.piece.link),
            self.piece.bag, self.piece.slot) end
    end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Disenchant", 1, 1, 1)
        local p = self.piece
        if p then GameTooltip:AddLine("Casts Disenchant on " .. tostring(p.link) .. ", the first piece of In your bags.",
            1, 0.82, 0, true) end
        GameTooltip:AddLine("Each click is one cast; then it aims at the next piece. A key does the same: Key Bindings, "
            .. "AddOns, Salvager, Disenchant next piece (a mouse wheel notch too); each press is one cast.", 1, 0.82, 0, true)
        if self.reason then GameTooltip:AddLine(self.reason, 1, 0.3, 0.3, true) end
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)
    if button.SetMotionScriptsWhileDisabled then button:SetMotionScriptsWhileDisabled(true) end
    Panel.button = button
    return button
end

------------------------------------------------------------------ the tables

-- The columns: those of the Ledger's Current batch (one name, one help), picked by name.
local function columns(names, titles)
    local LW = ns.LedgerWindow
    local out = {}
    for i, key in ipairs(names) do
        local c = LW.BATCH_COLUMNS[LW.BATCH[key]]
        out[i] = { (titles and titles[key]) or c[1], c[2], c[3], key = key, help = c.help and { (titles and titles[key])
            or c.help[1], c.help[2] } or nil }
    end
    return out, names
end
local BAG_COLS, BAG_KEYS = columns({ "gear", "ilvl", "paid", "ev", "ep" }, { ev = "Avg value" })
local RESULT_COLS, RESULT_KEYS = columns({ "gear", "paid", "got", "dv", "profit", "dvev" })
Panel.BAG_COLS, Panel.RESULT_COLS = BAG_COLS, RESULT_COLS

local function pick(cells, keys)
    local LW, out = ns.LedgerWindow, {}
    for i, key in ipairs(keys) do out[i] = cells[LW.BATCH[key]] end
    return out
end
local function note(text, n)
    local cells = { GREY .. text .. "|r" }
    for i = 2, n do cells[i] = "" end
    return { cells = cells, span = true }
end

--- The rows of the two tables: In your bags (the next piece first), and Results (the disenchants of the batch, the
--- newest first, with their totals last). Built with the Ledger's batch row builders, so both always agree.
function Panel.Rows(pieces, batch)
    local LW = ns.LedgerWindow
    if not pieces then pieces, batch = Panel.Pieces() end
    local top = {}
    for i, piece in ipairs(pieces) do
        local row = LW.BatchWaitingRow(piece.p)
        row.indent, row.link = nil, piece.link
        row.cells = pick(row.cells, BAG_KEYS)
        if i == 1 then row.group = true end   -- (the next piece: the highlight band)
        top[#top + 1] = row
    end
    if #top == 0 then
        top[1] = note("No gear you bought is in your bags. Take its \"Auction won\" mail: it shows here.", #BAG_COLS)
    end
    local bottom = {}
    local d = { n = 0, paid = 0, ev = 0, got = 0 }
    for _, x in ipairs(batch.done) do
        local row = LW.BatchDoneRow(x)
        d.n, d.paid, d.ev, d.got = d.n + 1, d.paid + row.paid, d.ev + row.ev, d.got + row.got
        row.indent = nil
        row.cells = pick(row.cells, RESULT_KEYS)
        bottom[#bottom + 1] = row
    end
    if #bottom == 0 then
        bottom[1] = note("No disenchant in this batch yet: each one shows here, the last one first.", #RESULT_COLS)
    else
        local cells = pick(LW.BatchTotals("Total: " .. d.n .. (d.n == 1 and " piece" or " pieces"),
            { paid = 0, ev = 0 }, d), RESULT_KEYS)
        cells[2] = ns.Money(d.paid)
        bottom[#bottom + 1] = { bold = true, rule = "total", cells = cells, tip = { "Results", "The disenchants of the "
            .. "Current batch (their materials not all posted yet): Paid, Disenchant value, Profit so far and DV/EV % of "
            .. "all of them. The Ledger's Purchases, Current batch has the rest." } }
    end
    return top, bottom, pieces
end

local function autoLootOff()
    if not GetCVarBool then return false end
    local ok, on = pcall(GetCVarBool, "autoLootDefault")
    return ok and on == false
end

local shown = { top = {}, bottom = {}, pieces = {} }   -- the rows on show (Panel.Refresh), for Panel.Layout

--- Builds the rows again (the bags, the batch) and lays the panel out. After a bag change, a cast, a booked purchase.
function Panel.Refresh()
    -- (The bags and the batch read once, for the button and the rows.)
    local pieces, batch = Panel.Pieces()
    Panel.Update(pieces)
    if not f or not f:IsShown() then return end
    local top, bottom
    top, bottom, pieces = Panel.Rows(pieces, batch)
    shown.top, shown.bottom, shown.pieces = top, bottom, pieces
    for _, x in ipairs({ { bags, BAG_COLS, top, "disenchant.bags" }, { results, RESULT_COLS, bottom, "disenchant.results" } }) do
        x[1]:SetColumns(x[2], x[4])
        x[1]:SetSource(#x[3], function(i) return x[3][i] end)
    end
    Panel.Layout()
end

--- Places the tables in the panel's size, from the rows on show: on every size change and while the bar is dragged.
--- No rows are built here (0.3.151: each step of a drag read the bags and the whole batch again, and the corner and
--- the bar lagged the pointer).
function Panel.Layout()
    if not f or not f:IsShown() then return end
    local top, pieces = shown.top, shown.pieces
    Panel.layouts = (Panel.layouts or 0) + 1   -- (the specs count them)
    -- From the top: the Auto Loot note (only while it is off), the bags table with its title, the results table.
    local y = TOP
    local off = autoLootOff()
    lootNote:SetShown(off)
    if off then y = y + 18 end
    local room = math.max(0, (tonumber((f:GetHeight())) or H0) - y - FOOT - 2 * TITLE_H - 8)
    Panel.room = room
    -- The top table as tall as its rows, up to 45% of the room; the bar between the tables moves it (SDD 113).
    local hTop = f.saved.split and W.SplitHeight(room, f.saved.split)
        or math.max(W.TABLE_MIN, math.min(W.SplitHeight(room, 0.45), (#top + 1) * 22 + 6))
    bagsTitle:SetText(GOLD .. "In your bags|r" .. GREY .. "  " .. #pieces .. (#pieces == 1 and " piece" or " pieces")
        .. ", the next one first|r")
    -- (Anchored again only where the Auto Loot note came or went: the anchors follow the size by themselves.)
    if Panel.anchoredY ~= y then
        Panel.anchoredY = y
        bagsTitle:ClearAllPoints()
        bagsTitle:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -y)
        bagsTitle:SetPoint("RIGHT", f, "RIGHT", -40, 0)   -- (cut before the "?", which is level with the title)
        bags:ClearAllPoints()
        bags:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -(y + TITLE_H))
        bags:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -(y + TITLE_H))
        resultsTitle:ClearAllPoints()
        resultsTitle:SetPoint("TOPLEFT", bags, "BOTTOMLEFT", 2, -6)
        results:ClearAllPoints()
        results:SetPoint("TOPLEFT", bags, "BOTTOMLEFT", 0, -6 - TITLE_H)
        results:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, FOOT)
    end
    bags:SetHeight(hTop)
    bags:Refresh()
    results:Refresh()
    W.FitTables(f, { bags, results }, "disenchant")
end

------------------------------------------------------------------ the window

local function build()
    f = W.Window("SalvagerDisenchantFrame", "Salvager Disenchant", "disenchant", W0, H0, MIN_W, MIN_H)
    f.layoutName = "disenchant"
    lootNote = W.Label(f, GREY .. "Auto Loot is off: after each disenchant, the loot window needs a click (Options, "
        .. "Controls, Auto Loot).|r", "GameFontHighlightSmall")
    lootNote:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -TOP)
    lootNote:SetPoint("RIGHT", f, "RIGHT", -40, 0)
    lootNote:SetJustifyH("LEFT")
    lootNote:SetWordWrap(false)
    lootNote.canCut = true   -- (one line, cut at the window's edge; UI.md Layout 6)
    local help = W.HelpButton(f, "Disenchant", function()
        return { "Disenchant",
            "In your bags: the gear you bought with Salvager and picked up, in your bags (not the bank, not what you "
                .. "wear). Your own gear never shows here.",
            "Disenchant (bottom right): each click is one cast on the first piece; then it aims at the next one.",
            "A key: Key Bindings, AddOns, Salvager, Disenchant next piece. A mouse wheel notch works too. Each press is "
                .. "one cast.",
            "Results: what each disenchant of this batch gave, the last one at the top, against what you paid.",
            "It opens by itself when new gear of your purchases lands in your bags (not in a fight). Closed, it stays "
                .. "closed until more arrives.",
            "In a fight the panel closes (the game locks the button) and comes back after it." }
    end)
    help:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -(TOP - 2))
    bagsTitle = W.Label(f, "", "GameFontNormal")
    bagsTitle:SetJustifyH("LEFT")
    bagsTitle:SetWordWrap(false)
    bagsTitle.canCut = true
    bags = W.List(f, { rowHeight = 22 })
    resultsTitle = W.Label(f, GOLD .. "Results|r" .. GREY .. "  the disenchants of this batch, the last one at the top|r",
        "GameFontNormal")
    results = W.List(f, { rowHeight = 22 })
    for _, l in ipairs({ bags, results }) do l.onColumnsChanged = function() Panel.Refresh() end end
    Panel.splitBar = W.SplitBar(f, bags, function() return Panel.room or 0 end, function(part)
        f.saved.split = part
        Panel.Layout()
    end)
    -- The footer: the next piece and how many are left at the left; Disenchant (the main action), then Close.
    local footer = W.Bar(f, "footer"):PlaceBottom(10, 12, 24)
    local close = W.Button(footer, "Close", CLOSE_W, function() f.UserHide() end, "Closes the panel. It opens again "
        .. "by itself when more gear of your purchases lands in your bags.")
    footer:AddRight(close, CLOSE_W)
    footer:AddRight(buildButton(footer), BUTTON_W)
    leftLabel = W.Label(footer, "", "GameFontHighlightSmall")
    leftLabel:SetJustifyH("RIGHT")
    local leftW = math.ceil(W.TextWidth("999 left") or 50) + 4   -- (as wide as its widest count: nothing moves)
    leftLabel:SetWidth(leftW)
    leftLabel.uiKind = "readout"
    footer:AddRight(leftLabel, leftW, 10)
    nextLabel = W.Label(footer, "", "GameFontHighlightSmall")
    footer:Add(nextLabel, 120)
    nextLabel:SetPoint("RIGHT", leftLabel, "LEFT", -10, 0)
    nextLabel:SetJustifyH("LEFT")
    nextLabel:SetWordWrap(false)
    nextLabel.canCut = true   -- (one line cut at the count; the full name is on the first row)
    Panel.bars = { footer = footer }   -- (the specs read them)
    -- The Results title is content too (SDD 120); the bags' title and the Auto Loot note may be cut.
    f.extraNeed = function() return math.ceil(14 + (tonumber((resultsTitle:GetStringWidth())) or 0) + 14) end
    Panel.bags, Panel.results, Panel.lootNote, Panel.nextLabel, Panel.leftLabel = bags, results, lootNote, nextLabel,
        leftLabel
    f.onResize = Panel.Layout
    f:HookScript("OnShow", Panel.Refresh)
end

--- Builds the panel (hidden) so its button and key binding work from the start. Out of combat only.
function Panel.Ensure()
    if not f and not combat() then build() end
    return f ~= nil
end

local function show(opener)
    if combat() then
        state.pendingOpen = true
        ns.Print("in combat: the Disenchant panel opens when the fight ends")
        return
    end
    if not Panel.Ensure() then return end
    W.opening = opener
    f.UserShow()
    W.opening = nil
end

function Panel.Show() show(nil) end

function Panel.Toggle()
    if f and f:IsShown() then f.UserHide() else show(nil) end
end

function Panel.Frame() return f end

------------------------------------------------------------------ opens by itself

--- After a bag change or a booked purchase: new pieces of the batch in the bags open the panel, once per piece
--- (SalvagerDB.disenchantSeen: the pieces of each gear seen in the bags). Not in combat: then it opens after.
function Panel.Check()
    local pieces = Panel.Update() or Panel.Pieces()
    local counts = {}
    for _, p in ipairs(pieces) do counts[p.itemID] = (counts[p.itemID] or 0) + 1 end
    ns.db.disenchantSeen = ns.db.disenchantSeen or {}
    local seen, new = ns.db.disenchantSeen, false
    for id, n in pairs(counts) do if n > (seen[id] or 0) then new = true end end
    for id in pairs(seen) do if not counts[id] then seen[id] = nil end end
    for id, n in pairs(counts) do seen[id] = n end
    if new and not (f and f:IsShown()) then
        if combat() then
            state.pendingOpen = true
        else
            ns.Log("disenchant panel: opened by itself (%d pieces of your purchases in your bags)", #pieces)
            show("panel")
        end
    end
    if f and f:IsShown() then Panel.Refresh() end
end

local REFRESH_GAP = 0.2
local queued = false
local function later()
    if queued then return end
    queued = true
    C_Timer.After(REFRESH_GAP, function()
        queued = false
        Panel.Check()
    end)
end

-- (At load the bags may not be read yet: the first check waits for the first bag update, so a /reload does not
-- count what was in the bags as new.)
ns.On("SALVAGER_READY", function()
    Panel.Ensure()
    Panel.Update()
end)
ns.On("BAG_UPDATE_DELAYED", later)
ns.On("SALVAGER_LEDGER", later)
ns.On("UNIT_SPELLCAST_START", function(unit, _, spellID)
    if unit ~= "player" or spellID ~= Data.DISENCHANT_SPELL then return end
    state.casting = true
    Panel.Update()
end)
local function castEnd(unit, _, spellID)
    if unit ~= "player" or spellID ~= Data.DISENCHANT_SPELL or not state.casting then return end
    state.casting = false
    Panel.Update()
end
for _, e in ipairs({ "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_FAILED", "UNIT_SPELLCAST_INTERRUPTED",
    "UNIT_SPELLCAST_SUCCEEDED" }) do
    ns.On(e, castEnd)
end
ns.On("LOOT_OPENED", function() state.loot = true Panel.Update() end)
ns.On("LOOT_CLOSED", function()
    state.loot = false
    Panel.Update()
    if f and f:IsShown() then Panel.Refresh() end
end)
-- A fight: the game locks secure buttons (and the windows that hold one). Just before, the button lets go of its
-- aim and the panel closes; after it, the aim and the panel come back.
ns.On("PLAYER_REGEN_DISABLED", function()
    if not button then return end
    Panel.Aim(nil)
    button:SetEnabled(false)
    button.reason = "In combat: Disenchant waits until the fight ends."
    if f and f:IsShown() then
        state.wasOpen = true
        f:Hide()
    end
end)
ns.On("PLAYER_REGEN_ENABLED", function()
    Panel.Ensure()
    local reopen = state.wasOpen or state.pendingOpen
    state.wasOpen, state.pendingOpen = false, false
    if reopen and f and not f:IsShown() then show("panel") end
    Panel.Update()
    if f and f:IsShown() then Panel.Refresh() end
end)
ns.On("CVAR_UPDATE", function() if f and f:IsShown() then Panel.Refresh() end end)

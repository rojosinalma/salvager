-- Salvager: the Odds view (SDD 114). Per gear type, quality and item level band: what the game's table says each
-- disenchant gives, against what your disenchants gave, with or without the Arcane Salvager. A tab of the Reports
-- window, and a window of its own when popped out from there ("Salvager Odds").
local _, ns = ...

local Ledger, Data, Model, W = ns.Ledger, ns.Data, ns.Model, ns.Widgets

local Odds = {}
ns.Odds = Odds

local GREY, RED = "|cff808080", "|cffff4040"
local INDENT = 12   -- each level of the cards (gear type, quality, band) sits in this much

--- The filters (saved with the Odds window: Gear, Quality, Bands, Salvager, "Only bands with my data", "Show with and
--- without the Salvager", the closed headings). Before 0.3.148 they were kept with the Ledger window.
function Odds.Filter()
    ns.db.windows.odds = ns.db.windows.odds or {}
    local saved = ns.db.windows.odds
    if not saved.filter then
        local old = ns.db.windows.ledger or {}
        saved.filter = old.oddsFilter or { qualities = old.oddsQuality, bandsOff = old.oddsBandsOff,
            dataOnly = old.oddsDataOnly }
        old.oddsFilter, old.oddsQuality, old.oddsBandsOff, old.oddsDataOnly, old.oddsTab = nil, nil, nil, nil, nil
    end
    return ns.LedgerWindow.FilterSet(saved.filter)
end

--- Is a band of item levels lo..up inside one of the ticked item level ranges? The ranges are the
--- scan's level bands; a rare or epic band, which is wider, shows when it overlaps a ticked one.
local function levelShown(lo, up, off)
    local from = 1
    for _, range in ipairs(ns.LevelBands()) do
        if not off[range.up] and lo <= range.up and up >= from then return true end
        from = range.up + 1
    end
    return false
end

local function pct(x) return math.floor(x * 100 + 0.5) .. "%" end
local function grey(t) return GREY .. t .. "|r" end
-- A value with the Salvager in its color; grey ("none", "too few") stays grey.
local SALV = ns.SALVAGER_COLOR
local function salv(t) return (t == "" or t:find(GREY, 1, true) == 1) and t or (SALV .. t .. "|r") end

-- One material's observed cells from a band of Ledger.Report: hits, rate, average quantity.
local function seen(band, id)
    local n = band and band.n or 0
    local m = band and band.mats[id]
    if n == 0 then return grey("0"), grey("-"), grey("-") end
    return m and tostring(m.hits) or grey("0"), pct((m and m.hits or 0) / n),
        m and string.format("%.2f", m.qty / m.hits) or grey("-")
end

--- Every item level band of every quality and gear type that the filters show: the game's table and what your
--- disenchants gave. With "Show with and without the Salvager" on, the observed columns are the disenchants
--- without it, and the materials it adds to (dust, essence) have the rate and quantity with it too.
--- @return table bands  { quality, classID, band, n, nWith, both, value, limit, lose, average, outcomes, rows }
function Odds.Bands()
    local x = Odds.Filter()
    local both = x.both and true or false
    local filtered = Ledger.Report(ns.db.ledger, nil, function(r)
        return ns.LedgerWindow.FilterPasses(x, nil, nil, nil, r.salvager and true or false)
    end)
    local all = Ledger.Report(ns.db.ledger)
    local without = both and Ledger.Report(ns.db.ledger, nil, function(r) return not r.salvager end) or nil
    local with = both and Ledger.Report(ns.db.ledger, nil, function(r) return r.salvager and true or false end) or nil
    local opts = ns.ValueOptions()
    local bands = {}
    for _, q in ipairs({ { 2, Data.GREEN }, { 3, Data.BLUE }, { 4, Data.PURPLE } }) do
        for _, classID in ipairs({ Data.CLASS_ARMOR, Data.CLASS_WEAPON }) do
            local lo = 1
            for _, b in ipairs((x.qualities[q[1]] and x.classes[classID]) and q[2] or {}) do
                local quality, up = q[1], b.up
                local inRange = levelShown(lo, up, x.bandsOff)
                lo = up + 1
                local key = Ledger.BandKey(quality, classID, up)
                local mine, mineWith = filtered[key], nil
                if both then mine, mineWith = without[key], with[key] end
                local n, nWith = mine and mine.n or 0, mineWith and mineWith.n or 0
                if inRange and (n + nWith > 0 or not x.dataOnly) then
                    -- The rates used (SDD 99): the table blended with your results of the band, with or without the
                    -- Salvager as buying counts it (not the filter's): Buy below and the loss chance rest on them.
                    local outcomes = ns.Outcomes(quality, classID, up, opts.salvager)
                    local v = Model.Value(outcomes, ns.PriceOf, opts)
                    local limit = ns.BuyLimit(quality, classID, up, (ns.LimitBasis(v, outcomes)))
                    local everything = all[key]
                    local entry = { quality = quality, classID = classID, band = up, n = n, nWith = nWith, both = both,
                        value = v, limit = limit, outcomes = outcomes, rows = {},
                        lose = limit > 0 and Model.LossChance(outcomes, ns.PriceOf, opts, limit) or nil,
                        average = everything and everything.n > 0 and everything.value / everything.n or nil,
                        allN = everything and everything.n or 0 }
                    local inTable = {}
                    local function row(id, r)
                        local hits, rate, qty = seen(mine, id)
                        local cells = { ns.MaterialName(id),
                            r and (r.unexpected and (RED .. "not expected|r") or pct(r.tableChance)) or (RED .. "not expected|r"),
                            (r and not r.unexpected) and (r.min == r.max and tostring(r.min) or (r.min .. "-" .. r.max)) or "",
                            hits, rate, qty }
                        if both then
                            -- Only the materials the Salvager adds to; the game has no table of it.
                            if r and r.bonus and not r.unexpected then
                                local _, wRate, wQty = seen(mineWith, id)
                                cells[7], cells[8] = salv(wRate), salv(wQty)
                            else
                                cells[7], cells[8] = "", ""
                            end
                        end
                        entry.rows[#entry.rows + 1] = { itemID = id, cells = cells, price = ns.PriceOf(id) }
                    end
                    for _, r in ipairs(outcomes.results) do
                        inTable[r.id] = true
                        row(r.id, r)
                    end
                    -- What came that the table does not have for this band.
                    for _, part in ipairs({ mine, mineWith }) do
                        for id in pairs(part and part.mats or {}) do
                            if not inTable[id] then
                                inTable[id] = true
                                row(id, nil)
                            end
                        end
                    end
                    bands[#bands + 1] = entry
                end
            end
        end
    end
    return bands
end

local function note()
    return Odds.Filter().dataOnly and "No disenchants yet in the selected bands. Untick \"Only bands with my data\" "
        .. "to see the tables." or "Nothing selected: pick a quality and an item level band above."
end

--- The columns: the game's table, a line, then yours (with the Salvager's when both show). Two titles read "Result
--- rate": their keys tell them apart in the column chooser.
local TABLE_HELP = "By the game's disenchant table the addon uses (Classic's table; not confirmed for Forever)."
local COLUMNS = {
    { "Material", 150, help = { "Material", "What a disenchant in this band can give: the game's table, and what came "
        .. "in yours that the table does not have (\"not expected\"). Click one: where yours came from." } },
    { "Result rate", 60, "CENTER", key = "Result rate (table)", help = { "Result rate (the game's table)",
        "How often this material comes from one disenchant in this band. " .. TABLE_HELP } },
    { "Quantity", 56, "CENTER", key = "Quantity (table)", help = { "Quantity (the game's table)",
        "How many come when a disenchant gives it. " .. TABLE_HELP } },
    { "Results", 50, "CENTER", sep = true, help = { "Results (your disenchants)", "How many of your disenchants in "
        .. "this band gave this material (as the Salvager filter says; without the Salvager while \"Show with and "
        .. "without the Salvager\" is on)." } },
    { "Result rate", 60, "CENTER", key = "Result rate (yours)", help = { "Result rate (your disenchants)",
        "How often it came in your disenchants in this band: Results ÷ Disenchants." } },
    { "Avg quantity", 70, "CENTER", help = { "Avg quantity (your disenchants)", "How many came on average "
        .. "when a disenchant of yours gave it: an average of whole units (one disenchant gives a whole number)." } },
}
-- The Salvager's columns: after a line of their own, in the Salvager's color (titles and values; grey still says
-- "too few" or "none"). Their keys stay the plain titles (the column chooser's saved choices).
local COLOR_HELP = "In the Salvager's color (light blue): with the Salvager, observed only."
local SALVAGER_COLUMNS = {
    { SALV .. "Rate with Salvager|r", 70, "CENTER", key = "Rate with Salvager", sep = true, help = {
        "Rate with Salvager (your disenchants)", "How often it came in your disenchants with the Arcane Salvager's "
        .. "bonus. Only dust and essence: the Salvager adds to them, not to shards. The game has no table of it.",
        COLOR_HELP } },
    { SALV .. "Avg quantity with Salvager|r", 80, "CENTER", key = "Quantity with Salvager", help = {
        "Avg quantity with Salvager (your disenchants)", "How many came on average with the Salvager's bonus, when a "
        .. "disenchant gave it (an average of whole units).", COLOR_HELP } },
}
Odds.SALVAGER_COLUMNS = SALVAGER_COLUMNS
function Odds.Columns()
    local cols = {}
    for i, c in ipairs(COLUMNS) do cols[i] = c end
    if Odds.Filter().both then for _, c in ipairs(SALVAGER_COLUMNS) do cols[#cols + 1] = c end end
    return cols
end

local DISENCHANTS_HELP = { "Disenchants", "How many of your disenchants are in this band (as the Salvager filter "
    .. "says). With \"Show with and without the Salvager\" on: without the Salvager, then with it." }
local WEIGHT_HELP = { "Weighted results", "The weight of your disenchants of this band that the rates, the range and "
    .. "Loss chance use (with or without the Salvager as buying counts it): each counts 0.5^(its age in days / 30), so "
    .. "today's count 1 and a month old 0.5. \"few results\" under " .. Model.FEW_RESULTS .. ": the table weighs more." }
local LOSS_HELP = { "Loss chance", "The chance that one disenchant is worth less than Buy below (the most the addon "
    .. "lets you pay), so the risk when you pay the full limit. \"-\" when the limit is 0. The \"?\" has the rest." }

--- The range of one disenchant of the band at today's prices: its pessimistic and optimistic outcomes (SDD 116).
local function rangeLine(band)
    local sp = ns.Spread(band.outcomes)
    if not (sp.low and sp.high) then return "Range now: -" end
    return string.format("Range now: %s %s (pessimistic: 9 in 10 get this or more) to %s %s (optimistic: 1 in 10)%s.",
        ns.OutcomeWhat(sp.low), ns.Money(sp.low.value), ns.OutcomeWhat(sp.high), ns.Money(sp.high.value),
        sp.unproven and (", " .. ns.NOT_PROVEN) or "")
end

--- The "?" of a band's card: the rest of its facts, one line each.
local function moreLines(band)
    local o, v = band.outcomes, band.value
    local lines = { "Band " .. ns.QualityText(band.quality) .. " " .. (ns.CLASS_LABEL[band.classID] or "") .. " "
        .. ns.BandRange(band.quality, band.band),
        "Avg value now: " .. ns.Money(v.net) .. (#v.missing > 0 and grey(" (a material has no price)") or "")
            .. ". What one disenchant is worth on average over many pieces at today's prices, after the cut; one "
            .. "disenchant gives one of its outcomes.",
        rangeLine(band),
        "Rule: " .. ns.EVIDENCE_TEXT[Model.Evidence(o)] .. ".",
        "Buy below: " .. ns.Money(band.limit) .. ". Avg value now minus your minimum profit (the pessimistic value "
            .. "for a rule not measured on Forever), or the limit you set in the Limits window.",
        "Your average: " .. (band.average and ns.Money(band.average) or "-") .. ". What your " .. band.allN
            .. " disenchants of this band gave on average, at the prices of the moment.",
        "Rates used from: " .. ns.WeightedResultsText(o.n, o.few) .. " (" .. (o.count or 0)
            .. (o.salvager and " disenchants with the Salvager" or " disenchants without the Salvager")
            .. ", as buying counts it): Avg value now, Buy below and Loss chance rest on the table blended with them.",
        ns.LEARNING_LINES[1], ns.LEARNING_LINES[2] }
    -- The learned Salvager shape each material of the band starts from with the Salvager (SDD 118): dust and essence.
    do
        for _, r in ipairs(o.results) do
            if r.bonus and not r.unexpected then
                local dist, shape = ns.SalvagerShape(r)
                if dist then
                    local parts = {}
                    for q = r.min, r.max + 1 do
                        if (dist[q] or 0) > 0 then parts[#parts + 1] = q .. ": " .. pct(dist[q]) end
                    end
                    lines[#lines + 1] = "Salvager shape, " .. ns.MaterialName(r.id) .. ": " .. table.concat(parts, ", ")
                        .. " (its kind in all bands: " .. ns.WeightedResultsText(shape.n, shape.few) .. "; the band's "
                        .. "own results refine it)"
                end
            end
        end
    end
    for _, r in ipairs(band.rows) do
        lines[#lines + 1] = "Price now, " .. tostring(r.cells[1]) .. ": " .. (r.price and ns.Money(r.price) or "no price")
    end
    return lines
end

--- The cards: a heading per gear type, a heading per quality under it (both open and close, remembered), and a
--- card per band under those, two per row where they fit, titled with the band's range.
function Odds.Cards()
    local x = Odds.Filter()
    local bands = Odds.Bands()
    local byKey = {}
    for _, band in ipairs(bands) do byKey[Ledger.BandKey(band.quality, band.classID, band.band)] = band end
    local rows = ns.GroupedRows(bands, function(band)
        return { key = Ledger.BandKey(band.quality, band.classID, band.band), cells = { "" } }
    end, nil, INDENT, { collapsed = x.collapsed, changed = function() Odds.Refresh() end })
    local cards = {}
    for _, r in ipairs(rows) do
        if r.head then
            cards[#cards + 1] = { heading = true, title = r.cells[1], open = r.open, onClick = r.onClick, indent = r.indent }
        else
            local band = byKey[r.key]
            local count = band.both and (tostring(band.n) .. GREY .. " without, |r" .. band.nWith .. GREY .. " with the "
                .. "Salvager|r") or (band.n > 0 and tostring(band.n) or grey("0"))
            cards[#cards + 1] = { title = r.cells[1], indent = r.indent, pair = true, rows = band.rows, band = band,
                facts = { { GREY .. "Disenchants|r " .. count, help = DISENCHANTS_HELP },
                    { GREY .. "Weighted|r " .. ns.WeightText(band.outcomes.n) .. (band.outcomes.few and grey(" few results")
                        or ""), help = WEIGHT_HELP },
                    { GREY .. "Loss chance|r " .. (band.lose and ns.LoseText(band.lose) or grey("-")), help = LOSS_HELP } },
                more = function() return moreLines(band) end }
        end
    end
    if #cards == 0 then cards[1] = { title = grey(note()), rows = {} } end
    return cards
end

--- The same as one flat list (the specs read it): each band's facts, then its material rows.
function Odds.Rows()
    local rows = {}
    for _, band in ipairs(Odds.Bands()) do
        rows[#rows + 1] = { band = band, cells = { ns.QualityText(band.quality) .. " " .. ns.BandRange(band.quality, band.band),
            tostring(band.n), band.lose and ns.LoseText(band.lose) or "-" } }
        for _, r in ipairs(band.rows) do rows[#rows + 1] = r end
    end
    return rows
end

------------------------------------------------------------------ the view

local views = {}         -- every Odds view (the Reports' tab, the pop-out)
local oddsFrame, oddsOut -- the pop-out window and its view

--- Is the Odds view in its window of its own now?
function Odds.PoppedOut() return oddsFrame ~= nil and oddsFrame:IsShown() end

local POP_TIP = { "Pop out the odds", "Moves the odds to a window of their own. Close that window, or click this in "
    .. "it, to put them back in the Reports' Odds tab." }
local BACK_TIP = { "Put the odds back", "Closes this window and shows the odds in the Reports' Odds tab again." }

--- An Odds view on `parent`: its filter row(s) and the stack of cards. `bar`: its filter row; `checkBar`: a second
--- filter row for the two checks where the first is full (nil: they end the first). `poppedOut`: the view of the
--- pop-out window (its button puts the odds back).
function Odds.NewView(parent, bar, checkBar, poppedOut)
    local view = { bar = bar, checkBar = checkBar }
    local x = Odds.Filter()
    local function changed()
        view.stack.offset = 0
        Odds.Refresh()
    end
    -- The filter row, as everywhere: Gear, Quality, Bands, Salvager; then the two checks; the pop-out at the right.
    view.controls = ns.LedgerWindow.FilterRow(bar, x, changed, true)
    view.salvagerDrop = view.controls[#view.controls]
    W.ReasonTip(view.salvagerDrop)
    local row = checkBar or bar
    view.dataOnly = W.Check(row, "Only bands with my data",
        "Lists only the item level bands you have disenchanted in. Untick it to see the table of every band.",
        function(on)
            Odds.Filter().dataOnly = on or nil
            changed()
        end)
    row:AddCheck(view.dataOnly)
    view.both = W.Check(row, "Show with and without the Salvager",
        "Your results without the Arcane Salvager in the usual columns, and two columns more for the dust and essence "
            .. "with it: Rate with Salvager and Avg quantity with Salvager. The Salvager filter has no effect meanwhile.",
        function(on)
            Odds.Filter().both = on or nil
            changed()
        end)
    row:AddCheck(view.both)
    view.pop = W.IconButton(bar, 22, function()
        if poppedOut then Odds.PutBack() else Odds.PopOut() end
    end)
    view.pop:SetPopOutGlyph()
    W.Tooltip(view.pop, (poppedOut and BACK_TIP or POP_TIP)[1], (poppedOut and BACK_TIP or POP_TIP)[2])
    bar:AddRight(view.pop, 22)
    view.stack = W.CardList(parent)
    view.stack.onColumnsChanged = function() Odds.Refresh() end
    function view:SetShown(on)
        self.bar:SetShown(on)
        if self.checkBar then self.checkBar:SetShown(on) end
        self.stack:SetShown(on)
    end
    function view:Refresh()
        local f0 = Odds.Filter()
        self.dataOnly:SetChecked(f0.dataOnly and true or false)
        self.both:SetChecked(f0.both and true or false)
        for _, c in ipairs(self.controls) do if c.Update then c:Update() end end
        -- (While both show, the Salvager filter does nothing: off, with the reason, UI.md Actions 3.)
        self.salvagerDrop:SetEnabled(not f0.both)
        self.salvagerDrop.reason = f0.both and "\"Show with and without the Salvager\" is on: the columns show both."
            or nil
        self.stack:SetColumns(Odds.Columns(), f0.both and "odds.salvager" or "odds")
        self.stack:SetCards(Odds.Cards())
        self.stack:Refresh()
    end
    views[#views + 1] = view
    return view
end

--- Draws every Odds view on show: the Reports' tab (through the Reports) and the pop-out.
function Odds.Refresh()
    if ns.Reports and ns.Reports.Refresh then ns.Reports.Refresh() end
    if oddsFrame and oddsFrame:IsShown() then Odds.RefreshOut() end
end

-- The pop-out window: no tabs, the filter rows right under the title bar. As wide as two cards per row; it can be
-- made narrower down to one per row (SDD 113, 114).
local OUT_TOP = 28
local OUT_MIN_W = 760   -- the width it opens with, before its content is measured (Widgets.FitTables sets it)
local OUT_CONTENT = OUT_TOP + 2 * (W.BAR_H.filters + 2) + 6

function Odds.RefreshOut()
    if not (oddsFrame and oddsFrame:IsShown()) then return end
    oddsOut:Refresh()
    W.FitTables(oddsFrame, { oddsOut.stack }, "odds")
end

-- A size change: only the cards are laid out again in the new width (the cards are not built again).
local function resizedOut()
    if not (oddsFrame and oddsFrame:IsShown()) then return end
    oddsOut.stack:Refresh()
    W.FitTables(oddsFrame, { oddsOut.stack }, "odds")
end

local function buildOut()
    oddsFrame = W.Window("SalvagerOddsFrame", "Salvager Odds", "odds", OUT_MIN_W, 520, OUT_MIN_W,
        OUT_CONTENT + W.TABLE_MIN + 14)
    oddsFrame.onResize = resizedOut
    oddsFrame.layoutName = "odds"
    oddsOut = Odds.NewView(oddsFrame, W.Bar(oddsFrame, "filters"):Place(OUT_TOP, 12, 12),
        W.Bar(oddsFrame, "filters"):Place(OUT_TOP + W.BAR_H.filters + 2, 12, 12), true)
    oddsOut.stack:SetPoint("TOPLEFT", oddsFrame, "TOPLEFT", 12, -OUT_CONTENT)
    oddsOut.stack:SetPoint("BOTTOMRIGHT", oddsFrame, "BOTTOMRIGHT", -12, 14)
    oddsOut.stack.widthOf = function() return (tonumber((oddsFrame:GetWidth())) or 0) - 24 end   -- (12 px each side)
    oddsFrame:HookScript("OnShow", Odds.Refresh)
    oddsFrame:HookScript("OnHide", function() if ns.Reports.Refresh then ns.Reports.Refresh() end end)
    Odds.out = oddsOut   -- (the specs read it)
end

--- Moves the odds to their own window (from the Reports' Odds tab).
function Odds.PopOut()
    if not oddsFrame then buildOut() end
    oddsFrame.UserShow()
    ns.Log("odds popped out")
end

--- Puts the odds back in the Reports' Odds tab, and shows it.
function Odds.PutBack()
    if Odds.PoppedOut() then
        oddsFrame.UserHide()
        ns.Log("odds put back")
    end
    if ns.Reports.ShowView then ns.Reports.ShowView("odds") end
end

--- Opens the pop-out again if it was open the last time.
function Odds.Restore()
    local saved = ns.db.windows.odds
    if saved and saved.open then
        if not oddsFrame then buildOut() end
        oddsFrame:Show()
    end
end

for _, e in ipairs({ "SALVAGER_LEDGER", "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS" }) do
    ns.On(e, function() Odds.RefreshOut() end)
end

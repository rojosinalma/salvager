-- Salvager: the Ledger window. A window of its own (move it, resize it), with three views:
--   Purchases: every item bought, and under it what it was disenchanted into.
--   Sales:     every material sale, with its profit against what the materials cost you.
--   Odds:      per item level band, what your disenchants gave against the table.
local _, ns = ...

local Ledger, Data, Model, W = ns.Ledger, ns.Data, ns.Model, ns.Widgets

local Window = { view = "purchases" }
ns.LedgerWindow = Window

local GREY, GOLD, GREEN, RED = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040"
local INDENT = 22
local QUALITY_NAME = { [2] = "Green", [3] = "Blue", [4] = "Epic" }

local COLUMNS = {
    purchases = { { "Item", 220 }, { "Bought", 82 }, { "Paid", 84, "RIGHT" }, { "Expected", 84, "RIGHT" },
        { "Got", 96, "RIGHT" }, { "Result", 84, "RIGHT" } },
    sales = { { "Material", 190 }, { "Sold", 82 }, { "Price", 84, "RIGHT" }, { "Cut", 70, "RIGHT" },
        { "You got", 84, "RIGHT" }, { "Cost", 96, "RIGHT" }, { "Profit", 84, "RIGHT" } },
    odds = { { "Band / material", 230 }, { "Count", 50, "CENTER" }, { "Planned", 84, "RIGHT" }, { "Got", 84, "RIGHT" },
        { "Table", 56, "CENTER" }, { "Yours", 56, "CENTER" }, { "Each", 50, "CENTER" } },
}

local f, list, summary, tabs = nil, nil, nil, {}

local function when(t) return (t and t > 0) and date("%m-%d %H:%M", t) or "-" end
local function money(c) return c and ns.Money(c) or "-" end
local function signed(c)
    if not c then return "" end
    return (c >= 0 and GREEN or RED) .. ns.Money(c) .. "|r"
end
local function itemName(itemID, link)
    return link or (ns.GetItemInfo(itemID)) or ("item " .. tostring(itemID))
end
local function note(text) return { cells = { GREY .. text .. "|r" } } end

------------------------------------------------------------------ rows

--- Purchases: one row per item, its materials indented under it.
function Window.PurchaseRows()
    local rows = {}
    for _, e in ipairs(Ledger.History(ns.db.ledger)) do
        local name = itemName(e.itemID, e.link) .. (e.salvager and "  |cff9370db[Salvager]|r" or "")
        rows[#rows + 1] = {
            itemID = e.itemID, link = e.link,
            cells = {
                name, when(e.boughtAt or (not e.done and e.t) or nil),
                e.paid and ns.Money(e.paid) or (GREY .. "not recorded|r"), money(e.expected),
                e.done and money(e.got)
                    or (GREY .. (ns.NoDisenchant(e.itemID) and "cannot be disenchanted" or "not disenchanted") .. "|r"),
                signed(e.result),
            },
        }
        for _, m in ipairs(e.mats or {}) do
            local value = m.value
            if not value then
                local p = ns.PriceOf(m.id)
                value = p and math.floor(p * m.qty * (1 - ns.Cut()) + 0.5) or nil
            end
            rows[#rows + 1] = {
                itemID = m.id, indent = INDENT,
                cells = { m.qty .. "x " .. ns.MaterialName(m.id), "", m.share and ns.Money(m.share) or "", "", money(value), "" },
            }
        end
    end
    if #rows == 0 then
        rows[1] = note("Nothing yet. Buy from the Deals tab, or take your \"Auction won\" mail, then disenchant.")
    end
    return rows
end

--- Sales, newest first. Profit = what you got after the cut - what those materials cost you.
function Window.SaleRows()
    local rows = {}
    local sales = ns.db.ledger.sales
    for i = #sales, 1, -1 do
        local s = sales[i]
        local tracked = s.count - (s.untracked or 0)
        local cost, profit
        if tracked <= 0 then
            cost, profit = GREY .. "not known|r", GREY .. "not known|r"
        else
            cost = ns.Money(s.cost) .. ((s.untracked or 0) > 0 and (GREY .. " +" .. s.untracked .. "?|r") or "")
            profit = signed(s.profit)
        end
        rows[#rows + 1] = {
            itemID = s.id,
            cells = { s.count .. "x " .. ns.MaterialName(s.id), when(s.t), ns.Money(s.gross), ns.Money(s.cut), ns.Money(s.net),
                cost, profit },
        }
    end
    if #rows == 0 then rows[1] = note("No sales yet. Sales are recorded when you take the \"Auction successful\" mail.") end
    return rows
end

local function bandRange(quality, up)
    local bands = quality == 2 and Data.GREEN or quality == 3 and Data.BLUE or Data.PURPLE
    local lo = 1
    for _, row in ipairs(bands) do
        if row.up == up then break end
        lo = row.up + 1
    end
    return lo .. (up >= 999 and "+" or ("-" .. up))
end

--- Odds: per band, what your disenchants gave against the table.
function Window.OddsRows()
    local rows = {}
    local by = Ledger.Report(ns.db.ledger)
    local keys = {}
    for k in pairs(by) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        local qa, ca, ba = a:match("(%d+):(%a):(%d+)")
        local qb, cb, bb = b:match("(%d+):(%a):(%d+)")
        if qa ~= qb then return qa < qb end
        if ca ~= cb then return ca < cb end
        return tonumber(ba) < tonumber(bb)
    end)
    for _, k in ipairs(keys) do
        local b = by[k]
        local q, c, up = k:match("(%d+):(%a):(%d+)")
        q, up = tonumber(q), tonumber(up)
        local classID = c == "w" and Data.CLASS_WEAPON or Data.CLASS_ARMOR
        rows[#rows + 1] = {
            cells = { GOLD .. (QUALITY_NAME[q] or "?") .. (c == "w" and " weapons, " or " armor, ") .. "item level "
                .. bandRange(q, up) .. "|r", tostring(b.n), ns.Money(b.planned / b.n), ns.Money(b.value / b.n), "", "", "" },
        }
        local expected = {}
        local outcomes = Model.Outcomes(q, classID, math.min(up, 70))
        if outcomes then for _, r in ipairs(outcomes.results) do expected[r.id] = r end end
        local mats = {}
        for id, m in pairs(b.mats) do mats[#mats + 1] = { id = id, hits = m.hits, qty = m.qty } end
        table.sort(mats, function(x, y) return x.hits > y.hits end)
        for _, m in ipairs(mats) do
            local e = expected[m.id]
            rows[#rows + 1] = {
                itemID = m.id, indent = INDENT,
                cells = { ns.MaterialName(m.id), tostring(m.hits), "", "",
                    e and (math.floor(e.chance * 100 + 0.5) .. "%") or (RED .. "none|r"),
                    math.floor(m.hits / b.n * 100 + 0.5) .. "%", string.format("%.2f", m.qty / m.hits) },
            }
        end
    end
    if #rows == 0 then rows[1] = note("No disenchants yet.") end
    return rows
end

--- The two lines above the list.
function Window.Summary()
    local bought, spent, done, got, waiting, waitingCost = 0, 0, 0, 0, 0, 0
    for _, e in ipairs(Ledger.History(ns.db.ledger)) do
        if e.paid then bought, spent = bought + 1, spent + e.paid end
        if e.done then
            done, got = done + 1, got + (e.got or 0)
        else
            waiting, waitingCost = waiting + 1, waitingCost + (e.paid or 0)
        end
    end
    local t = ns.Report.Totals()
    local line1 = string.format("%sBought|r %d items for %s    %sDisenchanted|r %d, materials worth %s after the cut",
        GOLD, bought, ns.Money(spent), GOLD, done, ns.Money(got))
    if waiting > 0 then
        line1 = line1 .. string.format("    %sNot disenchanted yet|r %d (%s)", GOLD, waiting, ns.Money(waitingCost))
    end
    local line2 = string.format("%sSold|r %d materials for %s after the cut    %sProfit on sales|r %s",
        GOLD, t.sold, ns.Money(t.soldNet), GOLD, signed(t.soldProfit))
    return line1, line2
end

local SOURCES = { purchases = Window.PurchaseRows, sales = Window.SaleRows, odds = Window.OddsRows }

------------------------------------------------------------------ the window

function Window.Refresh()
    if not f or not f:IsShown() then return end
    local rows = SOURCES[Window.view]()
    list:SetColumns(COLUMNS[Window.view])
    list:SetSource(#rows, function(i) return rows[i] end)
    list:Refresh()
    local a, b = Window.Summary()
    summary[1]:SetText(a)
    summary[2]:SetText(b)
    for name, button in pairs(tabs) do
        if name == Window.view then button:LockHighlight() else button:UnlockHighlight() end
    end
end

local function build()
    f = W.Window("SalvagerLedgerFrame", "Salvager ledger", "ledger", 780, 480, 700, 260)
    summary = {}
    for i = 1, 2 do
        local l = W.Label(f, "", "GameFontHighlightSmall")
        l:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -14 - i * 16)
        l:SetPoint("RIGHT", f, "RIGHT", -14, 0)
        l:SetJustifyH("LEFT")
        l:SetWordWrap(false)
        summary[i] = l
    end
    local x = 12
    for _, t in ipairs({ { "purchases", "Purchases" }, { "sales", "Sales" }, { "odds", "Odds" } }) do
        local b = W.Button(f, t[2], 96, function()
            Window.view = t[1]
            f.saved.view = t[1]
            list.offset = 0
            Window.Refresh()
        end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -68)
        tabs[t[1]] = b
        x = x + 100
    end
    W.Tooltip(tabs.purchases, "Purchases", "Every item you bought, newest first. Under each one: what it was disenchanted "
        .. "into, the part of its price given to each material, and what each was worth then.")
    W.Tooltip(tabs.sales, "Sales", "Every material sale. Profit = what you got after the cut, minus what those materials cost you.")
    W.Tooltip(tabs.odds, "Odds", "For each item level band: how often each material came, against the table the addon uses.")
    local clear = W.Button(f, "Clear history", 110, function() StaticPopup_Show("SALVAGER_CLEAR_LEDGER") end,
        "Removes the list of purchases, disenchants and sales, and with them the Odds. Your material stock and its "
        .. "costs stay, and so do purchases you have not disenchanted yet. It asks first.")
    clear:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -68)
    list = W.List(f, { rowHeight = 22 })
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -98)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    if SOURCES[f.saved.view] then Window.view = f.saved.view end
    f.onResize = Window.Refresh
    f:SetScript("OnShow", Window.Refresh)
end

StaticPopupDialogs["SALVAGER_CLEAR_LEDGER"] = {
    text = "Clear the Salvager ledger history?\n\nThis removes the list of purchases, disenchants and sales, and the Odds "
        .. "learned from them. Your material stock and its costs stay, and so do purchases you have not disenchanted yet.",
    button1 = "Clear history",
    button2 = "Cancel",
    OnAccept = function()
        local n = Ledger.ClearHistory(ns.db.ledger, ns.NoDisenchant)
        ns.Print("ledger history cleared (%d entries)", n)
        ns.Log("ledger history cleared (%d entries)", n)
        ns.Fire("SALVAGER_LEDGER")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

function Window.Toggle()
    if not f then build() end
    f.UserToggle()
end

function Window.Show()
    if not f then build() end
    f.UserShow()
end

--- Opens the window again if it was open the last time (the auction house opened).
function Window.Restore()
    local saved = ns.db.windows.ledger
    if not (saved and saved.open) then return end
    if not f then build() end
    f:Show()
end

for _, e in ipairs({ "SALVAGER_LEDGER", "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS" }) do
    ns.On(e, function() Window.Refresh() end)
end

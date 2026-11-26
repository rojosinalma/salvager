-- Salvager: the Ledger window. A window of its own (move it, resize it), with three views:
--   Purchases: every item bought, and under it what it was disenchanted into.
--   Sales:     every material sale, with its profit against what the materials cost you.
--   Odds:      per item level band, what your disenchants gave against the table, the buy limit and its risk.
local _, ns = ...

local Ledger, Data, Model, W = ns.Ledger, ns.Data, ns.Model, ns.Widgets

local Window = { view = "sales" }
ns.LedgerWindow = Window

local GREY, GOLD, GREEN, RED = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040"
local PROFIT_HELP = { "Profit", "What you got after the cut minus what the materials cost you, for the units with a "
    .. "known cost only. \"+3?\" in Cost = 3 units with no recorded cost, left out. An auction that expired or was "
    .. "cancelled shows the deposit the auction house kept, as a loss." }
local INDENT = 22
-- The longest countdown (an auction runs up to 48 hours): the Time columns keep this width while they count.
local COUNTDOWN_MAX = "00:00:00"

local COLUMNS = {
    purchases = { { "Item", 220 }, { "Bought", 82 }, { "Paid", 84, "RIGHT" },
        { "Expected value", 84, "RIGHT", help = { "Expected value", "The value the Deals list showed when you "
            .. "bought: the average disenchant value at the prices of that moment, after the auction house cut." } },
        { "Disenchant value", 96, "RIGHT", help = { "Disenchant value", "The market value of the materials you got, "
            .. "at the prices of the moment you disenchanted, after the auction house cut." } },
        { "Profit", 84, "RIGHT", help = { "Profit", "Disenchant value minus Paid." } } },
    -- The Accuracy view is two tables: by band, and by material.
    accBands = { { "Band", 170 }, { "Items", 44, "CENTER", help = { "Items", "How many disenchants with a recorded "
            .. "purchase are in the row. Grey = fewer than 20: too few to judge, one lucky shard moves it a lot." } },
        { "Paid", 70, "RIGHT" },
        { "Expected value", 70, "RIGHT", help = { "Expected value", "The Value the Deals list showed when you bought: "
            .. "the average disenchant value at the material prices of that moment, after the auction house cut." } },
        { "Disenchant value", 70, "RIGHT", help = { "Disenchant value", "The market value of the materials you got, "
            .. "at the prices of the moment you disenchanted, after the auction house cut." } },
        { "Diff", 46, "RIGHT", help = { "Disenchant value against Expected value", "How far the disenchant value is "
            .. "from the expected value. The gap is drop luck, or drop rates that are not what the addon assumes." } },
        { "Sold value", 70, "RIGHT", help = { "Sold value", "The same materials at the average price each one really "
            .. "sold for, after the auction house cut. Materials you have not sold yet count at their disenchant value." } },
        { "Diff", 46, "RIGHT", help = { "Sold value against Disenchant value", "How far the sold value is from the "
            .. "disenchant value. The gap is prices that moved, and undercutting. * = more than half of the row's "
            .. "materials are not sold yet, so most of it is still the disenchant value." } },
        { "Expected profit", 70, "RIGHT", help = { "Expected profit", "Expected value minus Paid." } },
        { "Actual profit", 70, "RIGHT", help = { "Actual profit", "Sold value minus Paid." } } },
    accMats = { { "Material", 170 }, { "Units", 44, "CENTER" },
        { "Disenchant value each", 80, "RIGHT", help = { "Disenchant value each", "The average market price of one "
            .. "unit at the moment you disenchanted, after the auction house cut." } },
        { "Sold value each", 80, "RIGHT", help = { "Sold value each", "The average of what one unit really brought "
            .. "in your sales, after the auction house cut." } },
        { "Difference", 80, "RIGHT", help = { "Difference", "Sold value each minus Disenchant value each." } },
        { "Diff", 46, "RIGHT", help = { "Difference in percent", "The same difference as a share of the disenchant value." } },
        { "Units sold", 70, "CENTER" } },
    -- The Gold view: the period in sums, then every change of gold, newest first.
    goldSum = { { "Gold", 170 }, { "Amount", 90, "RIGHT" },
        { "Times", 50, "RIGHT", help = { "Times", "How many changes of gold of this kind." } } },
    goldLog = { { "What", 200 }, { "Time", 90 }, { "Change", 90, "RIGHT" },
        { "Kind", 140, "LEFT", help = { "Kind", "What the change was: told by what the addon did (a purchase, a "
            .. "deposit, a mail taken), else by the window open then (vendor, mailbox, trade)." } },
        { "Gold after", 90, "RIGHT" } },
    -- The Sales view is two tables: your auctions, and the sales already paid.
    listed = { { "Material", 150 }, { "Status", 110 },
        { "Time", 62, "RIGHT", sample = COUNTDOWN_MAX, help = { "Time", "A sold auction: the time until its money arrives by mail. "
            .. "An auction still for sale: the time until it ends. It counts down from the last time the addon read "
            .. "your auctions (see \"as of\" above)." } },
        { "Each", 64, "RIGHT" }, { "Price", 76, "RIGHT" },
        { "You get", 76, "RIGHT" }, { "Cost", 84, "RIGHT" }, { "Profit", 76, "RIGHT" } },
    history = { { "Material", 150 }, { "Sold", 110 },
        { "Collected", 110, "LEFT", help = { "Collected", "When you took the money of this sale from the mail." } },
        { "Each", 64, "RIGHT" }, { "Price", 76, "RIGHT" },
        { "You got", 76, "RIGHT" }, { "Cost", 84, "RIGHT" }, { "Profit", 76, "RIGHT", help = PROFIT_HELP } },
    paid = { { "Material", 150 }, { "Sold", 110 },
        { "Time", 62, "RIGHT", sample = COUNTDOWN_MAX, help = { "Time", "The time until the money of this sale arrives by mail." } },
        { "Each", 64, "RIGHT" }, { "Price", 76, "RIGHT" },
        { "You get", 76, "RIGHT" }, { "Cost", 84, "RIGHT" }, { "Profit", 76, "RIGHT", help = PROFIT_HELP } },
}

local f, list, summary, tabs = nil, nil, nil, {}
local newOddsView
local checkButton, cancelButton
local oddsView          -- the Odds view in the ledger window: its filters and one table per band
local oddsFrame, oddsOut -- the odds in a window of their own
local popOut            -- the button next to the Odds tab that moves them there and back
local salesParts = {}   -- title, table, title, table of the Sales view
local salesTabs = {}    -- the Sales view's subtabs: open and sold, history

--- Which bands the Odds view shows: { quality = { [2], [3], [4] }, type = { a, w } }, kept with the window.
local function oddsFilter()
    local saved = ns.db.windows.ledger or {}
    ns.db.windows.ledger = saved
    saved.oddsQuality = saved.oddsQuality or { [2] = true, [3] = true, [4] = true }
    -- The gear type is a subtab: armor or weapons, one at a time.
    if saved.oddsTab ~= "w" then saved.oddsTab = "a" end
    saved.oddsBandsOff = saved.oddsBandsOff or {}   -- item level ranges not shown, by their upper level
    return saved.oddsQuality, { [saved.oddsTab] = true }, saved
end

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
            itemID = e.itemID, link = e.link, group = #(e.mats or {}) > 0,
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

--- A countdown: "44:05", or "23:10:42" from one hour up.
local function countdown(seconds)
    if not seconds then return GREY .. "?|r" end
    seconds = math.max(0, math.floor(seconds))
    local h, m, sec = math.floor(seconds / 3600), math.floor(seconds % 3600 / 60), seconds % 60
    if h > 0 then return string.format("%d:%02d:%02d", h, m, sec) end
    return string.format("%d:%02d", m, sec)
end

Window.GOLD_HOURS = 24

--- The Gold view: the sums of the last GOLD_HOURS hours, and every change of gold in them, newest first.
function Window.GoldRows()
    local s = ns.Gold.Period(Window.GOLD_HOURS)
    if not s then
        local none = note("No gold recorded yet: every change of your gold is recorded from now on.")
        return { none }, { none }
    end
    local sums = {
        { cells = { "At the start", ns.Money(s.start), "" } },
        { cells = { "Now", ns.Money(s.finish), "" } },
        { cells = { "Change", signed(s.change), "" } },
    }
    if s.mailSales > 0 then
        sums[#sums + 1] = { cells = { "In the mail (sold, not collected)", ns.Money(s.mail), tostring(s.mailSales) } }
        sums[#sums + 1] = { cells = { "After you collect it", ns.Money(s.finish + s.mail), "" } }
        sums[#sums + 1] = { cells = { "Change after you collect it", signed(s.change + s.mail), "" } }
    end
    for _, k in ipairs(ns.Journal.KINDS) do
        local x = s.kinds[k[1]]
        if x then sums[#sums + 1] = { cells = { GREY .. k[2] .. "|r", signed(x.gain + x.loss), tostring(x.n) } } end
    end
    if #s.losses > 0 then
        sums[#sums + 1] = { cells = { "Buys that lost", signed(s.lost), tostring(#s.losses) } }
        if s.lostWrong < 0 then
            sums[#sums + 1] = { cells = { RED .. "  of it valued wrong|r", signed(s.lostWrong), "" } }
        end
    end
    local log = {}
    for i = #s.entries, 1, -1 do
        local e = s.entries[i]
        if e.k ~= "start" then
            log[#log + 1] = { cells = { e.r or GREY .. "-|r", date("%m-%d %H:%M", e.t), signed(e.d),
                ns.Journal.KIND_NAME[e.k] or e.k, ns.Money(e.b) }, link = e.r and e.r:match("|Hitem:[^|]+|h") and e.r }
        end
    end
    if #log == 0 then log[1] = note("No change of gold in this time.") end
    return sums, log
end

--- Your auctions as last read: what is listed, what is sold and waiting for its money.
function Window.ListingRows()
    local rows = {}
    local l = ns.db.listings
    local mine = l.rows or {}
    if #mine == 0 then
        rows[1] = note(l.t and "Nothing listed." or "Not read yet: open the auction house.")
        return rows
    end
    -- Only the auctions still for sale. (The game keeps a sold auction in its list until the money is
    -- mailed; those show in the table of sold auctions, as sales.)
    for _, r in ipairs(mine) do
      if not r.sold then
        local gross = r.qty * r.each
        local net = math.floor(gross * (1 - ns.Cut()) + 0.5)
        local avg = Ledger.AvgCost(ns.db.ledger, r.itemID)
        local cost = avg and math.floor(avg * r.qty + 0.5) or nil
        local left = ns.Listings.TimeLeft(r)
        local status
        local under, lowest = ns.Listings.Undercut(r), ns.Listings.Lowest(r)
        if under then
            status = RED .. "undercut by " .. ns.Money(under) .. "|r"
        elseif lowest == false then
            status = GREEN .. "only yours|r"
        elseif lowest then
            status = GREEN .. "lowest|r"
        else
            status = "listed"
        end
        rows[#rows + 1] = {
            itemID = r.itemID, link = r.link,
            cells = { r.qty .. "x " .. ((r.link and r.link:match("%[(.-)%]")) or ns.MaterialName(r.itemID)), status,
                countdown(left),
                ns.Money(r.each), ns.Money(gross), ns.Money(net), cost and ns.Money(cost) or (GREY .. "not known|r"),
                cost and signed(net - cost) or "" },
        }
      end
    end
    if #rows == 0 then rows[1] = note("No open auctions.") end
    return rows
end

--- Every sale, newest first. Profit = what you get after the cut - what those materials cost you.
--- A sale is booked when its listing is seen as sold; Time counts down to its money, "paid" = mail taken.
--- @param history boolean  true = the sales whose money you have taken; false = the ones still to collect
function Window.SoldRows(history)
    local rows = {}
    local sales = ns.db.ledger.sales
    -- A sale booked before the due time was kept: its time is the one of the sold auction it came from.
    local used = {}
    local function dueOf(s)
        if s.due then return s.due - time() end
        for _, r in ipairs(ns.db.listings.rows or {}) do
            if not used[r] and r.sold and r.itemID == s.id and r.qty == s.count and s.each and math.abs(s.each - r.each) < 1 then
                used[r] = true
                return ns.Listings.TimeLeft(r)
            end
        end
    end
    for i = #sales, 1, -1 do
      local s = sales[i]
      local due = (s.unpaid or 0) > 0
      if due ~= history then
        local tracked = s.count - (s.untracked or 0)
        if s.lost then
            -- An auction that expired or was cancelled: the deposit the auction house kept.
            rows[#rows + 1] = {
                itemID = s.id,
                cells = { (s.qty or 0) .. "x " .. ns.MaterialName(s.id), when(s.t),
                    GREY .. (s.lost == "cancelled" and "cancelled" or "expired") .. "|r", "", "",
                    signed(s.net), "", signed(s.profit) },
            }
        else
            local cost, profit
            if tracked <= 0 then
                cost, profit = GREY .. "not known|r", GREY .. "not known|r"
            else
                -- "+3?" = units with no known cost: they are left out of the profit.
                cost = ns.Money(s.cost) .. ((s.untracked or 0) > 0 and (GREY .. " +" .. s.untracked .. "?|r") or "")
                profit = signed(s.profit)
            end
            rows[#rows + 1] = {
                itemID = s.id,
                cells = { s.count .. "x " .. ns.MaterialName(s.id),
                    when(s.t),
                    due and (GOLD .. countdown(dueOf(s)) .. "|r") or (s.paidAt and when(s.paidAt) or (GREY .. "-|r")),
                    ns.Money(math.floor(s.gross / s.count + 0.5)),
                    ns.Money(s.gross), ns.Money(s.net), cost, profit },
            }
        end
      end
    end
    if #rows == 0 then
        rows[1] = note(history and "No sale collected yet. A sale comes here when you take its mail."
            or "No sale is waiting for its money.")
    end
    return rows
end

--- "+5%" in green, "-3%" in red: how far `part` is from `whole`.
local function share(part, whole)
    if not whole or whole == 0 then return GREY .. "-|r" end
    local pct = math.floor((part - whole) / whole * 100 + 0.5)
    return (pct > 0 and (GREEN .. "+") or pct < 0 and RED or GREY) .. pct .. "%|r"
end

--- Accuracy, by band: what was promised, what the disenchants gave, what the sales brought.
function Window.AccuracyBandRows()
    local acc = Ledger.Accuracy(ns.db.ledger)
    local rows = {}
    local function row(b, name, group)
        local few = b.n < 20
        rows[#rows + 1] = { group = group, cells = { name, (few and GREY or "") .. b.n .. (few and "|r" or ""),
            ns.Money(b.paid), ns.Money(b.promised), ns.Money(b.got), share(b.got, b.promised), ns.Money(b.sold),
            share(b.sold, b.got) .. ((b.units > 0 and b.soldUnits < b.units / 2) and (GREY .. "*|r") or ""),
            signed(b.promised - b.paid), signed(math.floor(b.sold + 0.5) - b.paid) } }
    end
    if acc.total.n == 0 then
        rows[1] = note("Nothing to compare yet: it needs items you bought and then disenchanted.")
        return rows
    end
    row(acc.total, GOLD .. "All bands|r", true)
    -- One heading per quality and gear type, with its own totals; its bands under it, by item level only.
    local groups, order = {}, {}
    for _, b in ipairs(acc.bands) do
        local key = (b.quality or 0) .. ":" .. (b.classID or 0)
        local g = groups[key]
        if not g then
            g = { n = 0, paid = 0, promised = 0, got = 0, sold = 0, units = 0, soldUnits = 0, bands = {} }
            g.name = ns.BandName(b.quality, b.classID, b.band):match("^(.-|r)") or "?"
            groups[key] = g
            order[#order + 1] = g
        end
        for _, field in ipairs({ "n", "paid", "promised", "got", "sold", "units", "soldUnits" }) do
            g[field] = g[field] + b[field]
        end
        g.bands[#g.bands + 1] = b
    end
    for _, g in ipairs(order) do
        row(g, g.name, true)
        for _, b in ipairs(g.bands) do
            local range = ns.BandName(b.quality, b.classID, b.band):match("item level (.-)|r$") or tostring(b.band)
            row(b, range)
            rows[#rows].indent = INDENT
        end
    end
    return rows
end

--- Accuracy, by material: the price it was valued at when disenchanted against what it really sold for.
function Window.AccuracyMaterialRows()
    local rows = {}
    for _, m in ipairs(Ledger.Accuracy(ns.db.ledger).mats) do
        local valued = m.units > 0 and m.valued / m.units or nil
        local sold = m.soldUnits > 0 and m.soldNet / m.soldUnits or nil
        rows[#rows + 1] = { itemID = m.id, cells = { ns.MaterialName(m.id), tostring(m.units),
            valued and ns.Money(valued) or (GREY .. "-|r"), sold and ns.Money(sold) or (GREY .. "not sold yet|r"),
            (valued and sold) and signed(sold - valued) or "", (valued and sold) and share(sold, valued) or "",
            m.soldUnits > 0 and tostring(m.soldUnits) or (GREY .. "0|r") } }
    end
    if #rows == 0 then rows[1] = note("No disenchant with a recorded purchase yet.") end
    return rows
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

--- Odds: every item level band of every quality and gear type that the filters show, with the table
--- the addon uses and, where you have disenchanted, what you got.
--- @return table  bands { head = the band's row, rows = its material rows }, in the flat list's cell order
function Window.OddsBands()
    local bands = {}
    local by = Ledger.Report(ns.db.ledger)
    local s = ns.db.settings
    local opts = { salvager = ns.SalvagerForBuy(), salvagerChance = s.salvagerChance, cut = s.cut }
    local showQuality, showType, saved = oddsFilter()
    for _, q in ipairs({ { 2, Data.GREEN }, { 3, Data.BLUE }, { 4, Data.PURPLE } }) do
        for _, c in ipairs({ { Data.CLASS_ARMOR, "a", " armor" }, { Data.CLASS_WEAPON, "w", " weapons" } }) do
            local lo = 1
            for _, band in ipairs((showQuality[q[1]] and showType[c[2]]) and q[2] or {}) do
                local quality, classID, up = q[1], c[1], band.up
                local inRange = levelShown(lo, up, saved.oddsBandsOff)
                lo = up + 1
                local outcomes = Model.Outcomes(quality, classID, up)
                local mine = by[Ledger.BandKey(quality, classID, up)]
                local n = mine and mine.n or 0
                if inRange and (n > 0 or not saved.oddsDataOnly) then
                    local v = Model.Value(outcomes, ns.PriceOf, opts)
                    local limit = ns.BuyLimit(quality, classID, up, ns.LimitBasis(v))
                    local entry = { rows = {}, head = {
                        group = true,
                        cells = { ns.BandName(quality, classID, up),
                            n > 0 and tostring(n) or (GREY .. "0|r"), "", "",
                            ns.Money(v.net) .. (#v.missing > 0 and (GREY .. "?|r") or ""),
                            ns.Money(limit),
                            limit > 0 and ns.LoseText(Model.LossChance(outcomes, ns.PriceOf, opts, limit)) or (GREY .. "-|r"),
                            n > 0 and ns.Money(mine.value / n) or (GREY .. "-|r") },
                    } }
                    local inTable = {}
                    for _, r in ipairs(outcomes.results) do
                        inTable[r.id] = true
                        local m = mine and mine.mats[r.id]
                        local price = ns.PriceOf(r.id)
                        entry.rows[#entry.rows + 1] = {
                            itemID = r.id, indent = INDENT,
                            cells = { ns.MaterialName(r.id), m and tostring(m.hits) or (GREY .. "0|r"),
                                math.floor(r.chance * 100 + 0.5) .. "%",
                                r.min == r.max and tostring(r.min) or (r.min .. "-" .. r.max),
                                n > 0 and (math.floor((m and m.hits or 0) / n * 100 + 0.5) .. "%") or (GREY .. "-|r"),
                                m and string.format("%.2f", m.qty / m.hits) or (GREY .. "-|r"),
                                price and ns.Money(price) or (GREY .. "no price|r") },
                        }
                    end
                    -- What came that the table does not have for this band.
                    for id, m in pairs(mine and mine.mats or {}) do
                        if not inTable[id] then
                            entry.rows[#entry.rows + 1] = {
                                itemID = id, indent = INDENT,
                                cells = { ns.MaterialName(id), tostring(m.hits), RED .. "not expected|r", "",
                                    math.floor(m.hits / n * 100 + 0.5) .. "%", string.format("%.2f", m.qty / m.hits),
                                    "" },
                            }
                        end
                    end
                    bands[#bands + 1] = entry
                end
            end
        end
    end
    return bands
end

local function oddsNote()
    local _, _, saved = oddsFilter()
    return saved.oddsDataOnly and "No disenchants yet in the selected bands. Untick \"Only bands with my data\" "
        .. "to see the tables." or "Nothing selected: pick a quality and an item level band above."
end

--- The same as one flat list: each band's row, then its material rows.
function Window.OddsRows()
    local rows = {}
    for _, band in ipairs(Window.OddsBands()) do
        rows[#rows + 1] = band.head
        for _, r in ipairs(band.rows) do rows[#rows + 1] = r end
    end
    if #rows == 0 then rows[1] = note(oddsNote()) end
    return rows
end

-- The Odds view shows each band as a table of its own.
local ODDS_COLUMNS = {
    { "Material", 150 },
    { "Drops", 50, "CENTER", help = { "Drops", "How many of your own disenchants in this band gave this material." } },
    { "Drop rate", 64, "CENTER", help = { "Drop rate", "How often this material comes from one disenchant in this "
        .. "band, by the table the addon uses (Classic's table; not confirmed for Forever)." } },
    { "Quantity", 60, "CENTER", help = { "Quantity", "How many come when it drops, by the same table." } },
    { "Your drop rate", 84, "CENTER", help = { "Your drop rate", "How often it came in your own disenchants in "
        .. "this band." } },
    { "Your quantity", 84, "CENTER", help = { "Your quantity", "How many came on average when it dropped for you." } },
    { "Price now", 90, "RIGHT", help = { "Price now", "What one of this material costs on the auction house now, "
        .. "from your last material scan. Value now is worked out from these prices." } },
}
local BAND_HELP = { "This band", "Disenchants: how many of yours are in this band.\n\n"
    .. "Value now: what ONE disenchant is worth on average over many, at today's material prices, after the 5% cut. "
    .. "It is not the buy limit.\n\n"
    .. "Buy below: the most the addon lets you pay: Value now minus your minimum profit, or the limit you set in the "
    .. "Limits tab.\n\n"
    .. "Loss chance: the chance that one disenchant is worth less than Buy below, so the risk when you pay the full limit.\n\n"
    .. "Your average: what your own disenchants gave on average, at the prices of the moment. Compare it with Value now." }

--- One card per band for the Odds view.
function Window.OddsCards()
    local cards = {}
    local function fact(label, value) return GREY .. label .. "|r " .. value end
    for _, band in ipairs(Window.OddsBands()) do
        local c = band.head.cells
        cards[#cards + 1] = {
            title = c[1],
            facts = table.concat({ fact("Disenchants", c[2]), fact("Value now", c[5]), fact("Buy below", c[6]),
                fact("Loss chance", c[7]), fact("Your average", c[8]) }, "     "),
            factsHelp = BAND_HELP, rows = band.rows,
        }
    end
    if #cards == 0 then cards[1] = { title = GREY .. oddsNote() .. "|r", rows = {} } end
    return cards
end

--- The two lines above the list.
function Window.Summary()
    local bought, spent, done, got, waiting, waitingCost = 0, 0, 0, 0, 0, 0
    local waitingBy = {}
    for _, e in ipairs(Ledger.History(ns.db.ledger)) do
        if e.paid then bought, spent = bought + 1, spent + e.paid end
        if e.done then
            done, got = done + 1, got + (e.got or 0)
        else
            waiting, waitingCost = waiting + 1, waitingCost + (e.paid or 0)
            if e.itemID then waitingBy[e.itemID] = (waitingBy[e.itemID] or 0) + 1 end
        end
    end
    local t = ns.Report.Totals()
    local line1 = string.format("%sBought|r %d items for %s    %sDisenchanted|r %d, materials worth %s after the cut",
        GOLD, bought, ns.Money(spent), GOLD, done, ns.Money(got))
    if waiting > 0 then
        -- Where those items are: counted in the bags and the bank; the rest is taken to be in the mail.
        local bags, bank = 0, 0
        for id, n in pairs(waitingBy) do
            local okA, inBags = pcall(ns.GetItemCount, id)
            local okB, withBank = pcall(ns.GetItemCount, id, true)
            inBags = math.min(n, okA and tonumber(inBags) or 0)
            bags = bags + inBags
            bank = bank + math.min(n - inBags, math.max(0, (okB and tonumber(withBank) or 0) - inBags))
        end
        local where = {}
        if bags > 0 then where[#where + 1] = bags .. " in bags" end
        if bank > 0 then where[#where + 1] = bank .. " in bank" end
        if waiting - bags - bank > 0 then where[#where + 1] = (waiting - bags - bank) .. " in mail or gone" end
        line1 = line1 .. string.format("    %sBought, not disenchanted yet|r %d (%s): %s", GOLD, waiting,
            ns.Money(waitingCost), table.concat(where, ", "))
    end
    local line2 = string.format("%sSold|r %d materials for %s after the cut    %sProfit on sales|r %s",
        GOLD, t.sold, ns.Money(t.soldNet), GOLD, signed(t.soldProfit))
    if t.untracked > 0 then
        line2 = line2 .. string.format("    %sNo recorded cost|r %d units, %s after the cut (not in the profit)", GOLD,
            t.untracked, ns.Money(t.untrackedNet))
    end
    if t.depositsLost > 0 then
        line2 = line2 .. string.format("    %sDeposits lost|r %s", GOLD, signed(-t.depositsLost))
    end
    return line1, line2
end

local VIEWS = { sales = true, purchases = true, odds = true, accuracy = true, gold = true }

------------------------------------------------------------------ the window

--- The Odds view: the three filters and the stack of tables, one per band. The caller anchors its parts.
--- The ledger window has one, and the popped-out odds window has one.
function newOddsView(parent)
    local view = {}
    local function changed()
        view.stack.offset = 0
        Window.Refresh()
    end
    -- The subtabs: the odds of armor, and the odds of weapons.
    view.tabs = {}
    for _, t in ipairs({ { "a", "Armor", "The odds of armor: mostly dust." },
        { "w", "Weapons", "The odds of weapons: mostly essence." } }) do
        local b = W.Button(parent, t[2], 90, function()
            select(3, oddsFilter()).oddsTab = t[1]
            changed()
        end, t[3])
        if view.tabs.a then b:SetPoint("LEFT", view.tabs.a, "RIGHT", 4, 0) end
        view.tabs[t[1]] = b
    end
    view.qualityFilter = W.CheckDropdown(parent, 150, {
        { 2, "|cff1eff00Uncommon|r" }, { 3, "|cff0070ddRare|r" }, { 4, "|cffa335eeEpic|r" },
    }, function(q) return (oddsFilter())[q] end, function(q, on)
        (oddsFilter())[q] = on
        changed()
    end, "Which qualities the odds list.", "Quality")
    local bandOptions = {}
    for _, band in ipairs(ns.LevelBands()) do bandOptions[#bandOptions + 1] = { band.up, band.label } end
    view.bandFilter = W.CheckDropdown(parent, 150, bandOptions,
        function(up) return not select(3, oddsFilter()).oddsBandsOff[up] end,
        function(up, on)
            select(3, oddsFilter()).oddsBandsOff[up] = (not on) or nil
            changed()
        end, "Which item levels the odds list. A rare or epic band covers more levels than these: it shows when "
            .. "one of its levels is ticked.", "Bands",
        function(names, total)
            if #names == total then return "All" end
            if #names > 2 then return #names .. " bands" end
            return #names == 0 and "None" or table.concat(names, ", ")
        end)
    view.dataOnly = W.Check(parent, "Only bands with my data",
        "Lists only the item level bands you have disenchanted in. Untick it to see the table of every band.",
        function(on)
            select(3, oddsFilter()).oddsDataOnly = on
            changed()
        end)
    view.stack = W.CardList(parent)
    view.stack:SetColumns(ODDS_COLUMNS)
    function view:SetShown(on)
        self.tabs.a:SetShown(on)
        self.tabs.w:SetShown(on)
        self.qualityFilter:SetShown(on)
        self.bandFilter:SetShown(on)
        self.dataOnly:SetShown(on)
        self.stack:SetShown(on)
    end
    function view:Refresh()
        self.dataOnly:SetChecked(select(3, oddsFilter()).oddsDataOnly and true or false)
        self.qualityFilter:Update()
        self.bandFilter:Update()
        local tab = select(3, oddsFilter()).oddsTab
        for key, b in pairs(self.tabs) do
            if key == tab then b:LockHighlight() else b:UnlockHighlight() end
        end
        self.stack:SetCards(Window.OddsCards())
        self.stack:Refresh()
    end
    return view
end

-- The Sales view's two tables share the height under the tabs; the bar between them moves the border.
local SPLIT_DEFAULT, SPLIT_MIN, SPLIT_MAX, TABLE_MIN = 0.45, 0.1, 0.9, 66
local SUBTABS = 28   -- the height of a row of subtabs over the tables
local function salesRoom()
    return (f:GetHeight() or 0) - 98 - 14 - 2 * 20 - (Window.view == "sales" and SUBTABS or 0)
end

--- Sets how much of the room the upper Sales table takes (0.1 to 0.9), and remembers it.
function Window.SetSalesSplit(part)
    if not f then return end
    f.saved.salesSplit = math.max(SPLIT_MIN, math.min(SPLIT_MAX, part))
    Window.Refresh()
end

local ODDS_TOP = 86

function Window.Refresh()
    if oddsFrame and oddsFrame:IsShown() then oddsOut:Refresh() end
    if not f or not f:IsShown() then return end
    -- While the odds are in their own window, the ledger shows another view.
    if Window.view == "odds" and Window.OddsPoppedOut() then Window.view = "sales" end
    -- Sales (its first subtab) and Accuracy are two tables, each in its own panel; the other views are one.
    local accuracy = Window.view == "accuracy"
    local gold = Window.view == "gold"
    local sales = Window.view == "sales"
    local history = sales and f.saved.salesTab == "history"
    local split = (sales and not history) or accuracy or gold
    local odds = Window.view == "odds"
    list:SetShown(not split and not odds)
    -- The Sales view has a row of subtabs, and its tables start under it.
    local down = sales and SUBTABS or 0
    for key, b in pairs(salesTabs) do
        b:SetShown(sales)
        if (key == "history") == history then b:LockHighlight() else b:UnlockHighlight() end
    end
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -98 - down)
    salesParts[1]:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -100 - down)
    salesParts[2]:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -118 - down)
    salesParts[2]:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -118 - down)
    oddsView:SetShown(odds)
    for _, part in ipairs(salesParts) do part:SetShown(split) end
    if split then
        -- The upper table takes the share of the room that the bar between the tables was dragged to.
        local room = salesRoom()
        local share_ = f.saved.salesSplit or SPLIT_DEFAULT
        salesParts[2]:SetHeight(math.max(TABLE_MIN, math.min(room - TABLE_MIN, math.floor(room * share_))))
    end
    if gold then
        salesParts[1]:SetText(GOLD .. "Last " .. Window.GOLD_HOURS .. " hours|r" .. GREY .. "  " .. tostring(ns.Gold.Char())
            .. ", every change of gold by its kind|r")
        salesParts[3]:SetText(GOLD .. "Changes|r" .. GREY .. "  newest first|r")
        local sums, log = Window.GoldRows()
        salesParts[2]:SetColumns(COLUMNS.goldSum)
        salesParts[2]:SetSource(#sums, function(i) return sums[i] end)
        salesParts[2]:Refresh()
        salesParts[4]:SetColumns(COLUMNS.goldLog)
        salesParts[4]:SetSource(#log, function(i) return log[i] end)
        salesParts[4]:Refresh()
    elseif accuracy then
        salesParts[1]:SetText(GOLD .. "By band|r" .. GREY .. "  expected value, disenchant value, sold value|r")
        salesParts[3]:SetText(GOLD .. "By material|r" .. GREY .. "  disenchant value against sold value, per unit|r")
        local bands, mats = Window.AccuracyBandRows(), Window.AccuracyMaterialRows()
        salesParts[2]:SetColumns(COLUMNS.accBands)
        salesParts[2]:SetSource(#bands, function(i) return bands[i] end)
        salesParts[2]:Refresh()
        salesParts[4]:SetColumns(COLUMNS.accMats)
        salesParts[4]:SetSource(#mats, function(i) return mats[i] end)
        salesParts[4]:Refresh()
    elseif split then
        local l = ns.db.listings
        salesParts[1]:SetText(GOLD .. "Open auctions|r" .. (l.t and (GREY .. "  as of " .. date("%H:%M", l.t) .. "|r") or ""))
        salesParts[3]:SetText(GOLD .. "Sold|r" .. GREY .. "  the money is on its way, or waits in your mail|r")
        local listed, paid = Window.ListingRows(), Window.SoldRows(false)
        salesParts[2]:SetColumns(COLUMNS.listed)
        salesParts[4]:SetColumns(COLUMNS.paid)
        salesParts[2]:SetSource(#listed, function(i) return listed[i] end)
        salesParts[2]:Refresh()
        salesParts[4]:SetSource(#paid, function(i) return paid[i] end)
        salesParts[4]:Refresh()
    elseif odds then
        oddsView:Refresh()
    elseif history then
        local rows = Window.SoldRows(true)
        list:SetColumns(COLUMNS.history)
        list:SetSource(#rows, function(i) return rows[i] end)
        list:Refresh()
    else
        local rows = Window.PurchaseRows()
        list:SetColumns(COLUMNS.purchases)
        list:SetSource(#rows, function(i) return rows[i] end)
        list:Refresh()
    end
    local a, b = Window.Summary()
    summary[1]:SetText(a)
    summary[2]:SetText(b)
    for name, button in pairs(tabs) do
        if name == Window.view then button:LockHighlight() else button:UnlockHighlight() end
    end
    -- The pop-out button looks pressed while the odds are in their own window.
    if Window.OddsPoppedOut() then popOut:LockHighlight() else popOut:UnlockHighlight() end
    -- The two listing buttons belong to the Sales view.
    checkButton:SetShown(sales)
    cancelButton:SetShown(sales)
    if sales then
        local c, n = ns.Listings.checking, ns.Listings.CountUndercut()
        -- Only what is still for sale can be undercut: sold auctions are not checked.
        local unsold = ns.Listings.CountUnsold()
        checkButton:SetText(c and string.format("Checking %d/%d", c.done, c.total)
            or string.format("Check undercuts (%d)", unsold))
        checkButton:SetEnabled(ns.Queue.open and not c and unsold > 0)
        cancelButton:SetText(ns.Listings.Cancelling() and "Cancelling..." or string.format("Cancel undercut (%d)", n))
        -- CancelAuction needs the click itself: it cannot wait for a purchase, so the button is off meanwhile.
        local buying = ns.Scanner.Buying()
        cancelButton.reason = buying and "A purchase is on its way: Cancel comes back as soon as it is done." or nil
        cancelButton:SetEnabled(ns.Queue.open and n > 0 and not ns.Listings.Cancelling() and not buying)
    end
end

local function build()
    -- As wide as its tables need; the height is the player's.
    f = W.Window("SalvagerLedgerFrame", "Salvager ledger", "ledger", 860, 480, 860, 260, "vertical")
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
    for _, t in ipairs({ { "sales", "Sales" }, { "purchases", "Purchases" }, { "accuracy", "Accuracy" },
        { "odds", "Odds" }, { "gold", "Gold" } }) do
        local b = W.Button(f, t[2], 88, function()
            -- The Odds tab, while the odds are in their own window: put them back here.
            if t[1] == "odds" then Window.OddsPutBack() end
            Window.view = t[1]
            f.saved.view = t[1]
            list.offset = 0
            oddsView.stack.offset = 0
            Window.Refresh()
        end)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -68)
        tabs[t[1]] = b
        x = x + (t[1] == "odds" and 116 or 92)   -- (the Odds tab has its pop-out button after it)
    end
    W.Tooltip(tabs.gold, "Gold", "Your gold over the last 24 hours: where it started, where it is, the money still "
        .. "in the mail, and every change by its kind. /salv gold <hours> prints the same for any time.")
    W.Tooltip(tabs.accuracy, "Accuracy", "Expected value when you bought, against the disenchant value of what you got, "
        .. "against the sold value. By band and by material.")
    W.Tooltip(tabs.purchases, "Purchases", "Every item you bought, newest first. Under each one: what it was disenchanted "
        .. "into, the part of its price given to each material, and what each was worth then.")
    W.Tooltip(tabs.sales, "Sales", "Your open auctions, and what is sold with its money still to collect. The History "
        .. "subtab has the sales you have collected. Profit = what you get after the cut, minus what those "
        .. "materials cost you.")
    W.Tooltip(tabs.odds, "Odds", "Every item level band of every quality and gear type. Expected = how often each "
        .. "material comes and how many (the table the addon uses). You got = what your own disenchants gave. Value "
        .. "now = what one disenchant is worth on average at today's prices, after the cut. Buy below = the buy "
        .. "limit; Loss chance = the chance one disenchant is worth less than it. Point at a column title for more.")
    local clear = W.Button(f, "Clear history", 110, function() StaticPopup_Show("SALVAGER_CLEAR_LEDGER") end,
        "Removes the list of purchases, disenchants and sales, and with them the Odds. Your material stock and its "
        .. "costs stay, and so do purchases you have not disenchanted yet. It asks first.")
    clear:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -68)
    cancelButton = W.Button(f, "Cancel undercut (0)", 150, function() ns.Listings.CancelNext() end,
        "Cancels one undercut listing per click (the game wants a click for each). The materials come back by mail, "
        .. "and the auction house keeps its deposit. Needs the auction house open, and a check first.")
    -- On the row of the Sales subtabs, at the right: the row of the main tabs is full.
    cancelButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -98)
    cancelButton:SetMotionScriptsWhileDisabled(true)
    cancelButton:HookScript("OnEnter", function(self)
        local why = self.reason
        if why then GameTooltip:AddLine(why, 1, 0.3, 0.3, true) GameTooltip:Show() end
    end)
    checkButton = W.Button(f, "Check undercuts (0)", 150, function() ns.Listings.Check() end,
        "Searches each material you still have for sale and compares your price with the lowest listing that is not "
        .. "yours. Auctions that are sold are not checked. The number is how many listings are still for sale. "
        .. "About one second per material. Needs the auction house open.")
    checkButton:SetPoint("RIGHT", cancelButton, "LEFT", -6, 0)
    oddsView = newOddsView(f)
    oddsView.qualityFilter:SetPoint("RIGHT", clear, "LEFT", -6, 0)
    oddsView.bandFilter:SetPoint("RIGHT", oddsView.qualityFilter, "LEFT", -6, 0)
    oddsView.dataOnly:SetPoint("TOPRIGHT", f, "TOPRIGHT", -190, -38)
    oddsView.tabs.a:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -98)
    oddsView.stack:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -126)
    oddsView.stack:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    -- Right next to the Odds tab: the odds in a window of their own, and back.
    popOut = W.IconButton(f, 22, function()
        if Window.OddsPoppedOut() then Window.OddsPutBack() else Window.OddsPopOut() end
    end)
    popOut:SetPoint("LEFT", tabs.odds, "RIGHT", 0, 0)
    popOut:SetPopOutGlyph()
    popOut:SetScript("OnEnter", function(self)
        local out = Window.OddsPoppedOut()
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(out and "Put the odds back" or "Pop out the odds", 1, 1, 1)
        GameTooltip:AddLine(out and "Closes their window and shows them in the Odds tab again."
            or "Moves the odds to a window of their own. Click again, or close that window, to put them back.",
            1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    popOut:SetScript("OnLeave", function() GameTooltip:Hide() end)
    list = W.List(f, { rowHeight = 22 })
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -98)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    -- The Sales view: a title and a table for your auctions, a title and a table for the paid sales.
    local titleA = W.Label(f, "", "GameFontNormal")
    titleA:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -100)
    local listA = W.List(f, { rowHeight = 22 })
    listA:SetColumns(COLUMNS.listed)
    listA:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -118)
    listA:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -118)
    listA:SetHeight(120)
    local titleB = W.Label(f, "", "GameFontNormal")
    titleB:SetPoint("TOPLEFT", listA, "BOTTOMLEFT", 2, -6)
    local listB = W.List(f, { rowHeight = 22 })
    listB:SetColumns(COLUMNS.paid)
    listB:SetPoint("TOPLEFT", listA, "BOTTOMLEFT", 0, -24)
    listB:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    -- The bar between the two tables: drag it up or down to make one table taller and the other shorter.
    local bar = CreateFrame("Button", nil, f)
    bar:SetPoint("TOPLEFT", listA, "BOTTOMLEFT", 0, -1)
    bar:SetPoint("TOPRIGHT", listA, "BOTTOMRIGHT", 0, -1)
    bar:SetHeight(22)
    local handle = bar:CreateTexture(nil, "ARTWORK")
    handle:SetSize(60, 3)
    handle:SetPoint("TOP", bar, "TOP", 0, -2)
    handle:SetColorTexture(1, 0.82, 0, 0.45)
    local glow = bar:CreateTexture(nil, "HIGHLIGHT")
    glow:SetAllPoints()
    glow:SetColorTexture(1, 1, 1, 0.08)
    W.Tooltip(bar, "Resize", "Drag up or down to make one table taller and the other shorter. Right-click: back to "
        .. "the default.")
    bar:RegisterForClicks("RightButtonUp")
    bar:SetScript("OnClick", function()
        f.saved.salesSplit = nil
        Window.Refresh()
    end)
    bar:SetScript("OnMouseDown", function(self, button)
        if button ~= "LeftButton" then return end
        self:SetScript("OnUpdate", function()
            local top, room = listA:GetTop(), salesRoom()
            local _, y = GetCursorPosition()
            if type(top) ~= "number" or type(y) ~= "number" or room <= 0 then return end
            y = y / (f:GetEffectiveScale() or 1)
            Window.SetSalesSplit((top - y - 4) / room)
        end)
    end)
    bar:SetScript("OnMouseUp", function(self) self:SetScript("OnUpdate", nil) end)
    bar:SetScript("OnHide", function(self) self:SetScript("OnUpdate", nil) end)
    salesParts = { titleA, listA, titleB, listB, bar }
    -- The subtabs of the Sales view: what is open and what is sold; and the history.
    for _, t in ipairs({ { "open", "Open and sold", "Your open auctions, and what is sold with its money still to collect." },
        { "history", "History", "The sales whose money you have taken from the mail, newest first." } }) do
        local b = W.Button(f, t[2], t[1] == "open" and 120 or 90, function()
            f.saved.salesTab = t[1]
            list.offset = 0
            Window.Refresh()
        end, t[3])
        if salesTabs.open then
            b:SetPoint("LEFT", salesTabs.open, "RIGHT", 4, 0)
        else
            b:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -98)
        end
        salesTabs[t[1]] = b
    end
    if VIEWS[f.saved.view] then Window.view = f.saved.view end
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

local function buildOdds()
    -- As wide as its tables need; the height is the player's (the corner sizes it up and down only).
    oddsFrame = W.Window("SalvagerOddsFrame", "Salvager odds", "odds", 760, 520, 760, 200, "vertical")
    oddsFrame.onResize = Window.Refresh
    oddsOut = newOddsView(oddsFrame)
    oddsOut.dataOnly:SetPoint("TOPLEFT", oddsFrame, "TOPLEFT", 12, -29)
    oddsOut.qualityFilter:SetPoint("TOPRIGHT", oddsFrame, "TOPRIGHT", -12, -30)
    oddsOut.bandFilter:SetPoint("RIGHT", oddsOut.qualityFilter, "LEFT", -6, 0)
    oddsOut.tabs.a:SetPoint("TOPLEFT", oddsFrame, "TOPLEFT", 12, -58)
    oddsOut.stack:SetPoint("TOPLEFT", oddsFrame, "TOPLEFT", 12, -ODDS_TOP)
    oddsOut.stack:SetPoint("BOTTOMRIGHT", oddsFrame, "BOTTOMRIGHT", -12, 14)
    oddsFrame:SetScript("OnShow", Window.Refresh)
    oddsFrame:SetScript("OnHide", Window.Refresh)
end

function Window.OddsPoppedOut()
    return oddsFrame ~= nil and oddsFrame:IsShown()
end

--- Moves the odds to their own window.
function Window.OddsPopOut()
    if not oddsFrame then buildOdds() end
    oddsFrame.UserShow()
    ns.Log("odds popped out")
end

--- Puts the odds back in the ledger window's tab.
function Window.OddsPutBack()
    if Window.OddsPoppedOut() then
        oddsFrame.UserHide()
        ns.Log("odds put back")
    end
end

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
    if saved and saved.open then
        if not f then build() end
        f:Show()
    end
    local odds = ns.db.windows.odds
    if odds and odds.open then
        if not oddsFrame then buildOdds() end
        oddsFrame:Show()
    end
end

-- The countdowns of the Sales view run: once a second while it shows.
local lastCount = 0
ns.OnTick(function()
    if f and f:IsShown() and Window.view == "sales" and GetTime() - lastCount >= 1 then
        lastCount = GetTime()
        Window.Refresh()
    end
end)

for _, e in ipairs({ "SALVAGER_LEDGER", "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS", "SALVAGER_LISTINGS", "SALVAGER_GOLD",
    "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do
    ns.On(e, function() Window.Refresh() end)
end

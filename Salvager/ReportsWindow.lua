-- Salvager: the Reports window. What the trading made, for a period you pick (this session, a past one, the last
-- hours or days, or all time):
--   Gold       Statement: the trading profit, the stock change, the total, gold not from trading, the check against
--              your gold, and the sessions of a longer period; All gold changes: every change, newest first
--   Profit     by quality and gear type, and by item level band under each
--   Materials  what each material gave, sold for and cost, and what is left
--   Items      by item: which ones paid
local _, ns = ...

local Ledger, W = ns.Ledger, ns.Widgets

local Reports = { view = "gold", range = "24h", goldTab = "statement",
    -- The Gear and Items views' filters (kept in the window's saved data).
    filter = { classes = { [4] = true, [2] = true }, qualities = { [2] = true, [3] = true, [4] = true }, bandsOff = {},
        salvager = "all" } }
ns.Reports = Reports

local GREY, GOLD, GREEN, RED, WARN = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040", "|cffff8000"
local INDENT = 22
local FEW = 20   -- fewer disenchants than this: the numbers rest on few samples (grey)

local RANGES = {
    { "session", "This session" },
    { "24h", "Last 24 hours", 86400 },
    { "7d", "Last 7 days", 7 * 86400 },
    { "30d", "Last 30 days", 30 * 86400 },
    { "all", "All time", nil },
}
Reports.MENU_SESSIONS = 15   -- past sessions in the Period menu (older ones: the Sessions part of All time)
local ORDER = { "gold", "profit", "materials", "items" }
local TITLES = { gold = "Gold", profit = "Gear", materials = "Materials", items = "Items" }
local HELP = {
    gold = "What the trading made and how much richer you are, checked against your gold; every change of your gold.",
    profit = "What your disenchants made, by quality and gear type, and by item level band under each.",
    materials = "Each material: how many you got and sold, what they sold for and cost, and what is left.",
    items = "Each item you bought and disenchanted: which ones paid, best first.",
}

-- Money in a column: every coin under the largest one with two digits, so the coins line up (UI.md Tables 9).
local function money(c) return c and ns.MoneyColumn(c) or "-" end
local function signed(c)
    c = math.floor((c or 0) + 0.5)
    if c == 0 then return ns.MoneyColumn(0) end
    return (c > 0 and (GREEN .. "+") or RED) .. ns.MoneyColumn(c) .. "|r"
end
local function pct(part, whole)
    if not whole or whole == 0 then return GREY .. "-|r" end
    local p = math.floor(part / whole * 100 + 0.5)
    return (p >= 0 and (GREEN .. "+") or RED) .. p .. "%|r"
end
local function note(text) return { cells = { GREY .. text .. "|r" } } end
local function count(n) return (n < FEW and GREY or "") .. n .. (n < FEW and "|r" or "") end

local function sessions() return ns.db.sessions end

--- A past session picked in the Period menu (range "s:<start>"), or nil.
local function picked()
    local start = tonumber(tostring(Reports.range):match("^s:(%d+)$"))
    return start and ns.Statement.Find(sessions(), ns.Gold.Char(true), start) or nil
end

--- "45 min", "2 h 05 min", "3 d 4 h".
function Reports.Length(sec)
    sec = math.max(0, math.floor(sec or 0))
    local m = math.floor(sec / 60)
    if m < 60 then return m .. " min" end
    local h = math.floor(m / 60)
    if h < 24 then return string.format("%d h %02d min", h, m % 60) end
    return string.format("%d d %d h", math.floor(h / 24), h % 24)
end
local function when(t) return date("%m-%d %H:%M", t) end

--- A session's name: its start and its length ("11-26 18:49, 1 h 10 min").
function Reports.SessionName(s)
    return when(s.start) .. ", " .. Reports.Length((s.stop or time()) - s.start)
end

--- The time picked: its start (nil = all), its name, and its end (nil = now).
function Reports.From()
    if Reports.range == "session" then
        local s = ns.Gold.Session()
        return s and s.start or time(), "This session", nil
    end
    local s = picked()
    if s then return s.start, "Session " .. Reports.SessionName(s), s.stop end
    for _, r in ipairs(RANGES) do
        if r[1] == Reports.range then return r[3] and (time() - r[3]) or nil, r[2], nil end
    end
    return nil, "All time", nil
end

--- The choices of the Period filter: this session, the past sessions kept (the newest MENU_SESSIONS), the last
--- 24 hours, 7 days, 30 days, and all time.
function Reports.PeriodOptions()
    local out = { { "session", "This session" } }
    local n = 0
    for _, s in ipairs(ns.Statement.Sessions(sessions(), ns.Gold.Char(true))) do
        if s.stop and n < Reports.MENU_SESSIONS then
            n = n + 1
            out[#out + 1] = { "s:" .. s.start, Reports.SessionName(s) }
        end
    end
    for i = 2, #RANGES do out[#out + 1] = { RANGES[i][1], RANGES[i][2] } end
    return out
end

local COLUMNS = {
    -- A statement: the labels take the free width, the amounts end at the right edge (UI.md Tables 8).
    statement = { { "What", 260 }, { "Amount", 90, "RIGHT", help = { "Amount", "Gold, silver and copper; + came in, "
            .. "- went out. Green and red only for gold you really gained or lost; grey for values at today's prices." } },
        statement = true },
    goldLog = { { "What", 200 }, { "Time", 90 }, { "Change", 90, "RIGHT" },
        { "Kind", 140, "LEFT", help = { "Kind", "What the change was: told by what the addon did (a purchase, a "
            .. "deposit, a mail taken), else by the window open then (vendor, mailbox, trade)." } },
        { "Gold after", 90, "RIGHT" } },
    profit = { { "Band", 190 }, { "Items", 44, "RIGHT", help = { "Items", "Disenchants of items whose price is "
            .. "known. Grey: fewer than 20, too few to trust." } },
        { "With Salvager", 60, "RIGHT", help = { "With Salvager", "How many of them had the Arcane Salvager's bonus." } },
        { "Paid", 80, "RIGHT" },
        { "Disenchant value", 90, "RIGHT", help = { "Disenchant value", "What the materials were worth when you "
            .. "disenchanted, after the cut." } },
        { "Sold value", 90, "RIGHT", help = { "Sold value", "The materials at what one unit really sold for on "
            .. "average, after the cut (at their disenchant value while that material has not sold yet)." } },
        { "Profit", 80, "RIGHT", help = { "Profit", "Sold value minus Paid." } },
        { "Return", 50, "RIGHT", help = { "Return", "Profit as a share of Paid." } },
        { "Profit each", 70, "RIGHT" } },
    materials = { { "Material", 170 },
        { "Got", 44, "RIGHT", help = { "Got", "Units your disenchants gave in this time." } },
        { "Sold", 44, "RIGHT" },
        { "Sold for", 80, "RIGHT", help = { "Sold for", "What the sales brought, after the cut." } },
        { "Cost of sold", 80, "RIGHT", help = { "Cost of sold", "The part of what you paid for the gear that went to "
            .. "the units sold." } },
        { "Deposits lost", 70, "RIGHT", help = { "Deposits lost", "Deposits of auctions that were cancelled or ran out." } },
        { "Profit", 80, "RIGHT", help = { "Profit", "Sold for, minus the cost of the units with a known cost, minus "
            .. "the deposits lost." } },
        { "Held", 44, "RIGHT", help = { "Held", "Units in your bags and your bank now." } },
        { "Listed", 44, "RIGHT", help = { "Listed", "Units on the auction house now, not sold yet (as of the last "
            .. "time the addon read your auctions)." } },
        { "Value", 80, "RIGHT", help = { "Value", "Held and listed units at what one unit is worth now: the price times "
            .. "its sell price ratio, after the cut, less the deposits lost per unit sold (as in the statement's stock)." } } },
    items = { { "Item", 220 }, { "Items", 44, "RIGHT" }, { "Paid each", 70, "RIGHT" },
        { "Sold value each", 80, "RIGHT" }, { "Profit", 80, "RIGHT" }, { "Return", 50, "RIGHT" } },
}

--- Does a disenchant pass the filters? (Gear type, quality, item level band, with or without the Salvager.)
function Reports.Keep(r)
    local x = Reports.filter
    if not x.classes[r.classID] or not x.qualities[r.quality] then return false end
    if x.salvager == "with" and not r.salvager then return false end
    if x.salvager == "without" and r.salvager then return false end
    local ilvl = r.ilvl or r.band or 0
    for _, b in ipairs(ns.LevelBands()) do
        if ilvl <= b.up then return not x.bandsOff[b.up] end
    end
    return true
end

------------------------------------------------------------------ rows

-- Amounts. flow: + or - and the coins, no color. real: the same in green (gain) or red (loss), for real gold.
-- est: grey, for values at today's prices (never green or red).
local function flow(c)
    c = math.floor((c or 0) + 0.5)
    return (c > 0 and "+" or "") .. ns.MoneyColumn(c)
end
local function real(c)
    c = math.floor((c or 0) + 0.5)
    return (c > 0 and GREEN or c < 0 and RED or "") .. flow(c) .. ((c ~= 0) and "|r" or "")
end
local function est(c) return GREY .. flow(c) .. "|r" end

-- A statement's lines (UI.md Statements): a section heading without an amount, its lines one step in, its total at
-- the heading's level with a rule over the amount (the bottom line: a double rule under it too), in bold.
-- Every amount has its sign: + came in, - went out.
local SUB = 14   -- the lines under a heading
local function line(label, amount, tip, extra)
    local r = { cells = { label, amount }, tip = tip, indent = SUB }
    for k, v in pairs(extra or {}) do r[k] = v end
    return r
end
local function heading(label, tip) return { cells = { GOLD .. label .. "|r", "" }, tip = tip, group = true } end
local function totalLine(label, amount, tip, final)
    return { cells = { label, amount }, tip = tip, rule = final and "final" or "total", bold = true }
end
local GAP_ROW = { cells = { "", "" } }

--- The sessions of this character in a period longer than a session (from .. to, nil = all, now), newest first.
local function sessionsIn(from, to)
    local out = {}
    for _, s in ipairs(ns.Statement.Sessions(sessions(), ns.Gold.Char(true))) do
        if (s.stop or time()) >= (from or 0) and s.start <= (to or time()) then out[#out + 1] = s end
    end
    return out
end

--- One line per session of the period: its start and length, and how much richer it made you. A click shows it.
local function sessionLines(rows, from, to)
    rows[#rows + 1] = GAP_ROW
    rows[#rows + 1] = heading("Sessions: how much richer each one made you", { "Sessions", "Each session of this "
        .. "period, from login to logout, newest first, with its Total: how much richer it made you. Click one to see "
        .. "its statement." })
    local list = sessionsIn(from, to)
    if #list == 0 then
        rows[#rows + 1] = line(GREY .. "None recorded in this time: a session runs from login to logout.|r", "")
        return
    end
    for _, s in ipairs(list) do
        local sum = ns.Gold.SessionSums(s)
        local open = not s.stop
        local name = Reports.SessionName(s)
        rows[#rows + 1] = line(name .. (open and (GREY .. " (now)|r") or ""), real(sum.total), { name,
            "Trading profit: " .. real(sum.trading), "Total, how much richer you are: " .. real(sum.total),
            "Click: show its statement." }, { onClick = function()
                Reports.range = open and "session" or ("s:" .. s.start)
                Reports.Save()
                Reports.Refresh()
            end })
    end
end

--- The Statement: one table that reads top to bottom, for the period picked. Every total is the sum of the lines
--- above it since the heading of its section.
function Reports.StatementRows()
    local from, name, to = Reports.From()
    local st = ns.Gold.Statement(from or 0, to)
    local rows = {}
    -- What it is, for whom, for which time.
    local span = from and (when(from) .. " to " .. (to and when(to) or "now") .. " ("
        .. Reports.Length((to or time()) - from) .. ")") or "every record kept"
    rows[1] = { cells = { "Gold statement of " .. ns.Gold.Char(true), "" }, bold = true, tip = { "Gold statement",
        "What your trading made and how much richer you are, for this character, checked against your gold." } }
    rows[2] = { cells = { GREY .. name .. ": " .. span .. "|r", "" } }
    -- What the trading made.
    rows[#rows + 1] = GAP_ROW
    rows[#rows + 1] = heading("Trading", { "Trading", "What your sales brought, minus what the things sold cost you." })
    rows[#rows + 1] = line("Sales, after the auction house cut", flow(st.sales), { "Sales, after the auction house cut",
        string.format("What your materials sold for in this time, after the auction house cut: %d sales, each counted "
            .. "when it showed as sold (or when its mail was taken, if the addon did not see it sold).", st.salesN) })
    rows[#rows + 1] = line("Cost of what you sold", flow(-st.cost), { "Cost of what you sold", "What the sold units cost "
        .. "you: their part of what you paid for the gear they came from (shared per band by value). Units with no "
        .. "recorded cost count at no cost." })
    rows[#rows + 1] = line("Deposits lost (expired or cancelled)", flow(-st.depositsLost), { "Deposits lost",
        "The deposits of your auctions that ran out or that you cancelled: the auction house keeps them." })
    rows[#rows + 1] = line("Cancel fees", flow(st.cancel), { "Cancel fees", "What cancelling auctions cost on top of "
        .. "the deposit, from the record of your gold." })
    rows[#rows + 1] = totalLine("Trading profit", real(st.trading), { "Trading profit", "Sales, minus the cost "
        .. "of what you sold, minus the deposits lost, minus the cancel fees." })
    -- How much richer: the trading profit carried down, with what is not this time's trading.
    rows[#rows + 1] = GAP_ROW
    rows[#rows + 1] = heading("How much richer you are", { "How much richer you are", "The trading profit, plus what "
        .. "sold while you were away, plus the change in what your stock is worth." })
    rows[#rows + 1] = line("Trading profit, from above", flow(st.trading), { "Trading profit", "The total of the "
        .. "Trading part above." })
    if st.away.n > 0 then
        rows[#rows + 1] = line("Sold while you were away, less its cost", flow(st.away.profit), {
            "Sold while you were away", string.format("%d sales made before this session started and found now (their "
                .. "mail, or your auctions): %s after the cut, minus their cost %s. Not counted as this session's "
                .. "trading.", st.away.n, ns.Money(st.away.net), ns.Money(st.away.cost)) })
    end
    local sk = st.stock
    if sk then
        local tip = { "Change in your stock's value", "Your unsold materials and the gear you have not disenchanted yet: "
            .. "what they are worth minus what they cost, at the end, minus the same at the start.",
            string.format("At the end: worth %s, cost %s. At the start: worth %s, cost %s.", ns.Money(sk.v1),
                ns.Money(sk.c1), ns.Money(sk.v0), ns.Money(sk.c0)),
            "Materials at their price now times their sell price ratio, after the cut, less the deposits lost per unit "
                .. "sold; gear at its expected value. Grey: it rests on prices, not on gold you have." }
        local label = "Change in your stock's value, at today's prices"
        if not sk.known then
            label = "Change in your stock's value since " .. when(sk.since) .. ", at today's prices"
            tip[#tip + 1] = "The stock's value at the start of this time is not known: it is counted from " .. when(sk.since)
                .. ", the first record of it."
        end
        rows[#rows + 1] = line(label, est(sk.change), tip)
    else
        rows[#rows + 1] = line("Change in your stock's value: not known yet", GREY .. "-|r", {
            "Change in your stock's value", "Not known yet: the addon records what your stock is worth at each login "
                .. "and logout." })
    end
    rows[#rows + 1] = totalLine("Total: how much richer you are", real(st.total), {
        "Total: how much richer you are", "Trading profit" .. (st.away.n > 0 and ", plus Sold while you were away" or "")
            .. ", plus the change in your stock's value." }, true)
    -- Gold not from trading.
    rows[#rows + 1] = GAP_ROW
    rows[#rows + 1] = heading("Gold not from trading", { "Gold not from trading", "Gold that came or went for other "
        .. "reasons than trading, by kind, from the record of every change of your gold." })
    for _, o in ipairs(st.other) do
        rows[#rows + 1] = line(o.name, flow(o.amount), { o.name, string.format("%d changes of your gold.", o.n) })
    end
    if #st.other == 0 then rows[#rows + 1] = line(GREY .. "None in this time|r", "") end
    rows[#rows + 1] = totalLine("Total gold not from trading", real(st.otherSum), {
        "Total gold not from trading", "The sum of the lines above." })
    -- The check against the gold: what the gold and the mail did, what the records explain, and the gap.
    rows[#rows + 1] = GAP_ROW
    rows[#rows + 1] = heading("Check against your gold", { "Check against your gold", "Your gold and the money in "
        .. "your mail must change by what the records explain. What is left is Not explained: near 0 when every "
        .. "change has its record." })
    local c = st.check
    if not c.g0 then
        rows[#rows + 1] = line(GREY .. "No gold recorded in this time|r", "")
    else
        local live = to == nil
        local MAIL = "Money from sales that waits in your mail (sold, not collected yet)."
        for _, x in ipairs({
            { live and "Gold now" or "Gold at the end", c.g1, "Your gold at the end of this time." },
            { live and "Money in the mail now" or "Money in the mail at the end", c.m1, MAIL },
            { "Less gold at the start", -c.g0, "Your gold when this time started, taken off." },
            { "Less money in the mail at the start", -c.m0, MAIL .. " At the start of this time, taken off." },
        }) do
            rows[#rows + 1] = line(x[1], flow(x[2]), { x[1], x[3] })
        end
        rows[#rows + 1] = totalLine("Change in gold and mail", real(c.change), { "Change in gold and mail",
            "Gold and mail at the end, minus gold and mail at the start." })
        rows[#rows + 1] = GAP_ROW
        rows[#rows + 1] = heading("What your records explain", { "What your records explain", "Each change of gold and "
            .. "mail that has its record: sales, purchases, deposits, fees and gold not from trading." })
        local parts = {
            { "Sales, after the cut", c.sales, "Every sale in this time (also those made while you were away): its money "
                .. "went into your gold or your mail." },
            { "Deposits given back with sales", c.back, "The deposit the auction house gave back in the mail of a sale." },
            { "Gear bought", c.buy, "What you paid for gear, from the record of your gold." },
            { "Deposits paid", c.deposit, "Deposits paid when you posted, from the record of your gold." },
            { "Cancel fees", c.cancel, "What cancelling auctions cost, from the record of your gold." },
            { "Other auction house", c.auction, "Changes of gold at the auction house that the addon did not make (an "
                .. "other addon's purchase, for example)." },
            { "Gold not from trading", c.other, "The total of that part above." },
        }
        for i, x in ipairs(parts) do
            if x[2] ~= 0 or i == 1 or i == 3 or i == 7 then
                rows[#rows + 1] = line(x[1], flow(x[2]), { x[1], x[3] })
            end
        end
        rows[#rows + 1] = totalLine("Explained by the records", flow(c.explained), {
            "Explained by the records", "The sum of the lines above: what your records say your gold and mail did." })
        rows[#rows + 1] = GAP_ROW
        rows[#rows + 1] = heading("Not explained", { "Not explained", "The change in gold and mail that no record "
            .. "explains. Near 0 when every change of your gold has its record." })
        rows[#rows + 1] = line("Change in gold and mail, from above", flow(c.change), { "Change in gold and mail",
            "The total of the first part of the check." })
        rows[#rows + 1] = line("Less explained by the records", flow(-c.explained), { "Explained by the records",
            "The total of What your records explain, taken off." })
        if c.ok then
            rows[#rows + 1] = totalLine("Not explained: none", GREY .. flow(c.missing) .. "|r", { "Not explained",
                "Change in gold and mail, minus Explained by the records. Near 0 (1s or less): every change of your "
                    .. "gold has its record." }, true)
        else
            rows[#rows + 1] = totalLine(WARN .. "Not explained: a record is missing|r", WARN .. flow(c.missing) .. " !|r",
                { "Not explained", string.format("Change in gold and mail, minus Explained by the records, is %s: a "
                    .. "record is probably missing. A sale or a purchase the addon did not see (another addon, another "
                    .. "character), or money taken from the mail that was not booked.", flow(c.missing)) }, true)
        end
    end
    -- A period longer than a session: one line per session in it.
    if not (Reports.range == "session" or picked()) then sessionLines(rows, from, to) end
    return rows
end

--- Every change of gold in the time picked, newest first.
function Reports.ChangeRows()
    local from, _, to = Reports.From()
    local s = ns.Journal.Summary(ns.db.money, ns.Gold.Char(true), from or 0, to or time())
    local log = {}
    for i = #s.entries, 1, -1 do
        local e = s.entries[i]
        if e.k ~= "start" then
            log[#log + 1] = { cells = { e.r or GREY .. "-|r", date("%m-%d %H:%M", e.t), real(e.d),
                ns.Journal.KIND_NAME[e.k] or e.k, ns.MoneyColumn(e.b) }, link = e.r and e.r:match("|Hitem:[^|]+|h") and e.r }
        end
    end
    if #log == 0 then log[1] = note("No change of gold in this time: every change of your gold is recorded.") end
    return log
end

local function profitCells(x, name)
    local profit = math.floor(x.sold + 0.5) - x.paid
    return { name, count(x.n), tostring(x.salvager), money(x.paid), money(x.value), money(math.floor(x.sold + 0.5)),
        signed(profit), pct(profit, x.paid), x.n > 0 and signed(profit / x.n) or "-" }
end

--- By gear type (a heading with its totals), by quality under it (with its totals), and by item level band
--- under each quality (the range only).
function Reports.ProfitRows()
    local from, _, to = Reports.From()
    local p = Ledger.Profits(ns.db.ledger, from, Reports.Keep, to)
    if p.total.n == 0 then
        return { note("No disenchant of an item with a known price in this time and these filters. Buy from the "
            .. "Deals tab, then disenchant.") }
    end
    local rows = {}
    local bands = {}
    for _, g in ipairs(p.groups) do for _, b in ipairs(g.bands) do bands[#bands + 1] = b end end
    local function sum(of)
        local t = { n = 0, paid = 0, value = 0, sold = 0, salvager = 0 }
        for _, b in ipairs(of) do for k in pairs(t) do t[k] = t[k] + b[k] end end
        return t
    end
    for _, r in ipairs(ns.GroupedRows(bands, function(b) return { cells = profitCells(b, "") } end,
        function(of, label) return { group = true, cells = profitCells(sum(of), label) } end, INDENT)) do
        rows[#rows + 1] = r
    end
    -- The totals row is the last one, with a line over it (UI.md Tables 13).
    rows[#rows + 1] = { rule = "total", bold = true, cells = profitCells(p.total, "Total") }
    return rows
end

--- Each material: what it gave in this time, and what is left now.
--- Units of a material in the bags and the bank, and on the auction house (not sold yet).
local function heldAndListed(id)
    local ok, n = pcall(ns.GetItemCount, id, true)
    local listed = 0
    for _, r in ipairs(ns.db.listings and ns.db.listings.rows or {}) do
        if r.itemID == id and not r.sold then listed = listed + (r.qty or 0) end
    end
    return ok and tonumber(n) or 0, listed
end
Reports.HeldAndListed = heldAndListed

function Reports.MaterialRows()
    local from, _, to = Reports.From()
    local p = Ledger.Profits(ns.db.ledger, from, nil, to)
    local seen, list = {}, {}
    for _, m in ipairs(p.mats) do seen[m.id] = true list[#list + 1] = m end
    for _, mat in ipairs(ns.Data.MATERIALS) do
        local held, listed = heldAndListed(mat.id)
        if not seen[mat.id] and held + listed > 0 then
            list[#list + 1] = { id = mat.id, got = 0, sold = 0, net = 0, cost = 0, profit = 0, untracked = 0,
                depositsLost = 0 }
        end
    end
    if #list == 0 then return { note("No material got, sold, held or listed in this time.") } end
    local rows = {}
    local total = { got = 0, sold = 0, net = 0, cost = 0, profit = 0, depositsLost = 0, held = 0, listed = 0, value = 0 }
    for _, m in ipairs(list) do
        local held, listed = heldAndListed(m.id)
        local value = math.floor((ns.UnitValue(m.id) or 0) * (held + listed))
        for k, v in pairs({ got = m.got, sold = m.sold, net = m.net, cost = m.cost, profit = m.profit,
            depositsLost = m.depositsLost, held = held, listed = listed, value = value }) do total[k] = total[k] + v end
        rows[#rows + 1] = { itemID = m.id, cells = { ns.MaterialName(m.id) or tostring(m.id), tostring(m.got),
            tostring(m.sold), money(m.net), money(m.cost), m.depositsLost > 0 and signed(-m.depositsLost) or "-",
            signed(m.profit), tostring(held), tostring(listed), money(value) } }
    end
    rows[#rows + 1] = { rule = "total", bold = true, cells = { "Total", tostring(total.got), tostring(total.sold),
        money(total.net), money(total.cost), total.depositsLost > 0 and signed(-total.depositsLost) or "-",
        signed(total.profit), tostring(total.held), tostring(total.listed), money(total.value) } }
    return rows
end

--- Each item, the best first.
function Reports.ItemRows()
    local from, _, to = Reports.From()
    local p = Ledger.Profits(ns.db.ledger, from, Reports.Keep, to)
    if #p.items == 0 then return { note("No disenchant of an item with a known price in this time and these filters.") } end
    local rows = {}
    for _, it in ipairs(p.items) do
        local profit = math.floor(it.sold + 0.5) - it.paid
        rows[#rows + 1] = { itemID = it.itemID, link = it.link, cells = { it.link or tostring(it.itemID), count(it.n),
            money(it.paid / it.n), money(it.sold / it.n), signed(profit), pct(profit, it.paid) } }
    end
    return rows
end

------------------------------------------------------------------ window

local f, list, filterRow, rangeDrop
local tabs, filters, goldTabs = {}, {}, {}
local GOLD_TABS = {
    { "statement", "Statement", "What the trading made and how much richer you are, then the check against your gold." },
    { "changes", "All gold changes", "Every change of your gold, newest first, with its kind." },
}
-- The rows from the top (UI.md Controls 1): the tabs, the subtabs (Gold only), the filter row, the content.
local TABS_TOP = 24
local bars = {}   -- tabs, gold (the Gold view's subtabs), filters

--- Keeps the time and the Gold subtab with the window.
function Reports.Save()
    if f then f.saved.range, f.saved.goldTab = Reports.range, Reports.goldTab end
end
local FILTERED = { profit = true, items = true }   -- the views the filters apply to

local function show(l, cols, rows, setId)
    l:SetColumns(cols, setId)
    l:SetSource(#rows, function(i) return rows[i] end)
    l:Refresh()
end

function Reports.Refresh()
    if not f or not f:IsShown() then return end
    local gold = Reports.view == "gold"
    -- The filter row: under the Gold view's subtabs, else right under the tabs; the content under it.
    local top = TABS_TOP + W.BAR_H.tabs + 4
    bars.gold:SetShown(gold)
    if gold then top = top + W.BAR_H.subtabs + 4 end
    filterRow:Place(top, 12, 12)
    list:ClearAllPoints()
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -(top + W.BAR_H.filters + 4))
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    -- The Gear and Items views have their own filters after the period.
    local filtered = FILTERED[Reports.view] or false
    for _, x in ipairs(filters) do
        x:SetShown(filtered)
        if x.Update then x:Update() end
    end
    for key, b in pairs(goldTabs) do b:SetSelected(key == Reports.goldTab) end
    if gold then
        if Reports.goldTab == "changes" then
            show(list, COLUMNS.goldLog, Reports.ChangeRows(), "reports.goldLog")
        else
            show(list, COLUMNS.statement, Reports.StatementRows(), "reports.statement")
        end
    elseif Reports.view == "profit" then
        show(list, COLUMNS.profit, Reports.ProfitRows(), "reports.profit")
    elseif Reports.view == "materials" then
        show(list, COLUMNS.materials, Reports.MaterialRows(), "reports.materials")
    else
        show(list, COLUMNS.items, Reports.ItemRows(), "reports.items")
    end
    for key, b in pairs(tabs) do b:SetSelected(key == Reports.view) end
    rangeDrop:SetOptions(Reports.PeriodOptions(), 190)
    rangeDrop:Update()
end

local function build()
    f = W.Window("SalvagerReportsFrame", "Salvager reports", "reports", 900, 480, 890, 300)
    if TITLES[f.saved.view] then Reports.view = f.saved.view end
    for _, r in ipairs(RANGES) do if r[1] == f.saved.range then Reports.range = r[1] end end
    if tostring(f.saved.range):match("^s:%d+$") then Reports.range = f.saved.range end
    for _, t in ipairs(GOLD_TABS) do if t[1] == f.saved.goldTab then Reports.goldTab = t[1] end end
    bars.tabs = W.Bar(f, "tabs"):Place(TABS_TOP, 12, 12)
    for _, key in ipairs(ORDER) do
        local b = W.Tab(bars.tabs, TITLES[key], function()
            Reports.view = key
            f.saved.view = key
            list.offset = 0
            Reports.Refresh()
        end, HELP[key])
        bars.tabs:Add(b, 90)
        tabs[key] = b
    end
    -- The filter row: the period for every view, then the Profit and Items views' own filters.
    filterRow = W.Bar(f, "filters")
    bars.filters = filterRow
    rangeDrop = W.Dropdown(filterRow, 170, Reports.PeriodOptions(), function(key) return key == Reports.range end,
        function(key)
            Reports.range = key
            Reports.Save()
            rangeDrop:Close()
            list.offset = 0
            Reports.Refresh()
        end, "The period every report covers: this session (from login to logout; a /reload keeps it), a past "
            .. "session (its start and length), the last 24 hours, 7 or 30 days, or all time.", "Period",
        function(names)
            if #names > 0 then return names[1] end
            local s = picked()
            return s and Reports.SessionName(s) or "All time"
        end)
    filterRow:AddFilter("Period", rangeDrop, 170, "The time the reports cover.")
    local x0 = f.saved.filter
    if type(x0) == "table" then
        for _, k in ipairs({ "classes", "qualities", "bandsOff" }) do
            if type(x0[k]) == "table" then Reports.filter[k] = x0[k] end
        end
        if x0.salvager then Reports.filter.salvager = x0.salvager end
    end
    f.saved.filter = Reports.filter
    local flt = Reports.filter
    local function changed()
        list.offset = 0
        Reports.Refresh()
    end
    -- A set where at least one stays ticked.
    local function setOf(tbl, invert, all)
        return function(key) if invert then return not tbl[key] end return tbl[key] and true or false end,
            function(key, on)
                if invert then tbl[key] = (not on) or nil else tbl[key] = on or nil end
                local any = false
                for _, k in ipairs(all) do if (invert and not tbl[k]) or (not invert and tbl[k]) then any = true end end
                if not any then
                    if invert then tbl[key] = nil else tbl[key] = true end
                    ns.Print("at least one must stay ticked")
                end
                changed()
            end
    end
    local function allOr(names, total) return #names == total and "All" or table.concat(names, ", ") end
    local function add(label, drop, help)
        local l, area = filterRow:AddFilter(label, drop, drop.maxWidth, help)
        -- (The help area hides with its label, so it never covers another view's content.)
        filters[#filters + 1] = l
        filters[#filters + 1] = area
        filters[#filters + 1] = drop
    end
    local gearGet, gearSet = setOf(flt.classes, false, { 4, 2 })
    add("Gear", W.Dropdown(filterRow, 100, { { 4, "Armor" }, { 2, "Weapons" } }, gearGet, gearSet,
        "Which gear types count.", "Gear", allOr), "Armor, weapons, or both.")
    local qGet, qSet = setOf(flt.qualities, false, { 2, 3, 4 })
    add("Quality", W.Dropdown(filterRow, 120, { { 2, "|cff1eff00Uncommon|r" }, { 3, "|cff0070ddRare|r" },
        { 4, "|cffa335eeEpic|r" } }, qGet, qSet, "Which qualities count.", "Quality", allOr), "Uncommon, Rare, Epic.")
    local bandOptions, bandKeys = {}, {}
    for _, b in ipairs(ns.LevelBands()) do
        bandOptions[#bandOptions + 1] = { b.up, b.label }
        bandKeys[#bandKeys + 1] = b.up
    end
    local bGet, bSet = setOf(flt.bandsOff, true, bandKeys)
    add("Bands", W.Dropdown(filterRow, 110, bandOptions, bGet, bSet, "Which item level bands count.", "Bands",
        function(names, total)
            if #names == total then return "All" end
            if #names > 3 then return #names .. " bands" end
            return table.concat(names, ", ")
        end), "Item level bands: a band is a range of item levels that disenchants into the same materials.")
    local salvDrop
    salvDrop = W.Dropdown(filterRow, 100, { { "all", "All" }, { "with", "With it" }, { "without", "Without it" } },
        function(key) return flt.salvager == key end,
        function(key)
            flt.salvager = key
            salvDrop:Close()
            changed()
        end, "Disenchants with the Arcane Salvager's bonus, without it, or all.", "Salvager")
    add("Salvager", salvDrop, "Disenchants with the Arcane Salvager's bonus, without it, or all.")
    -- The Gold view's subtabs, on the row under the tabs (subtabs only).
    bars.gold = W.Bar(f, "subtabs"):Place(TABS_TOP + W.BAR_H.tabs + 4, 12, 12)
    for _, t in ipairs(GOLD_TABS) do
        local b = W.Subtab(bars.gold, t[2], function()
            Reports.goldTab = t[1]
            Reports.Save()
            list.offset = 0
            Reports.Refresh()
        end, t[3])
        bars.gold:Add(b, t[1] == "changes" and 110 or 70)
        goldTabs[t[1]] = b
    end
    Reports.bars = bars   -- (the specs read them)
    list = W.List(f, { rowHeight = 22 })
    Reports.list = list
    f.onResize = Reports.Refresh
    f:SetScript("OnShow", Reports.Refresh)
end

function Reports.Toggle()
    if not f then build() end
    f.UserToggle()
end

function Reports.Show()
    if not f then build() end
    f.UserShow()
end

--- Opens the window again if it was open the last time.
function Reports.Restore()
    local saved = ns.db.windows.reports
    if not (saved and saved.open) then return end
    if not f then build() end
    f:Show()
end

for _, e in ipairs({ "SALVAGER_LEDGER", "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS", "SALVAGER_GOLD" }) do
    ns.On(e, function() Reports.Refresh() end)
end

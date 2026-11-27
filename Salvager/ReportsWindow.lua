-- Salvager: the Reports window. What the trading made, for a period you pick (this session, a past one, the last
-- hours or days, or all time):
--   Gold       Statement: the trading profit, the stock change, the total, gold not from trading, the check against
--              your gold, and the sessions of a longer period; All gold changes: every change, newest first
--   Gear       Bands: the profit by gear type, quality and item level band; History: every piece of gear you bought
--              and disenchanted, best first
--   Materials  what each material gave, sold for and cost, and what is left
local _, ns = ...

local Ledger, W = ns.Ledger, ns.Widgets

local Reports = { view = "gold", range = "24h", goldTab = "statement", gearTab = "bands",
    -- The Gear view's filters (kept in the window's saved data).
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
local ORDER = { "gold", "gear", "materials", "competition" }
local TITLES = { gold = "Gold", gear = "Gear", materials = "Materials", competition = "Competition" }
local HELP = {
    gold = "What the trading made and how much richer you are, checked against your gold; every change of your gold.",
    gear = "What the gear you bought and disenchanted made: by band, and piece by piece.",
    materials = "Each material: how many you got and sold, what they sold for and cost, and what is left.",
    competition = "Who undercut your auctions in this period, what it cost you, and how you answered: per competitor "
        .. "and per material. The Ledger's Sales, Competition subtab is the live list.",
}
-- The views before 0.3.129: the Gear tab ("profit") and the Items tab are the Gear view's two subtabs now.
local OLD_VIEW = { profit = { "gear", "bands" }, items = { "gear", "history" } }

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
local function lostCol(c)   -- money lost: red with its "-" (UI.md Tables 7)
    c = math.floor((c or 0) + 0.5)
    return c > 0 and (RED .. "-" .. ns.MoneyColumn(c) .. "|r") or ns.MoneyColumn(0)
end
local function gapCol(g) return g and (RED .. "-" .. ns.MoneyColumn(math.floor(g + 0.5)) .. "|r") or "-" end
local function gapPctCol(p) return p and string.format("%s-%.1f%%|r", RED, p) or "-" end

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
local function when(t) return ns.Date("%m-%d %H:%M", t) end

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
    goldLog = { { "What", 200 }, { "Time", 90, help = ns.TimeHelp("Time", "When your gold changed.") }, { "Change", 90, "RIGHT" },
        { "Kind", 140, "LEFT", help = { "Kind", "What the change was: told by what the addon did (a purchase, a "
            .. "deposit, a mail taken), else by the window open then (vendor, mailbox, trade)." } },
        { "Gold after", 90, "RIGHT" } },
    profit = { { "Band", 190 }, { "Disenchanted", 70, "RIGHT", help = { "Disenchanted", "Disenchants of gear whose "
            .. "price is known. Grey: fewer than 20, too few to trust." } },
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
    -- Competition (SDD 109): the summary is a statement; then one table per competitor, one per material.
    compNames = { { "Name", 140, help = { "Name", "The seller whose listing was under the price of one of your "
            .. "auctions, as the auction house names them (Unknown seller: no name given). Click to open it: per "
            .. "material." } },
        { "Undercuts", 54, "RIGHT", help = { "Undercuts", "Price lines of theirs seen under one of your auctions in "
            .. "this period: once per line, not again while the line stays the same." } },
        { "Share", 44, "RIGHT", help = { "Share", "Their part of all undercuts in this period." } },
        { "Materials", 120, help = { "Materials", "Which of your materials they undercut, the most often first." } },
        { "Typical gap", 70, "RIGHT", help = { "Typical gap", "How far under your price each: the median, in coins." } },
        { "Typical gap %", 50, "RIGHT", help = { "Typical gap %", "The same in percent of your price each." } },
        { "Lowest price", 70, "RIGHT", help = { "Lowest price", "Their lowest price each seen under yours." } },
        { "First seen", 76, help = ns.TimeHelp("First seen", "Their first undercut in this period.") },
        { "Last seen", 76, help = ns.TimeHelp("Last seen", "Their last undercut in this period.") },
        { "Active hours", 70, help = ns.TimeHelp("Active hours", "The hours of the day they undercut you most (from that "
            .. "hour to the next).") },
        { "Trend", 44, "RIGHT", help = { "Trend", "Undercuts against the period before, of the same length: green "
            .. "when fewer (+ more, - fewer). \"-\" for All time." } },
        { "Profit lost to them", 84, "RIGHT", help = { "Profit lost to them", "Cancel fees and deposits of your "
            .. "undercut auctions you cancelled, the deposits of the reposts, and the lower price your reposted units "
            .. "sold at against your first price. Split evenly when several were under you. The parts are in the "
            .. "row's tooltip." } } },
    compMats = { { "Material", 150 },
        { "Undercuts", 54, "RIGHT" },
        { "Competitors", 64, "RIGHT", help = { "Competitors", "How many sellers undercut you on it." } },
        { "Main competitor", 110, help = { "Main competitor", "The one seen under you most often on it." } },
        { "Typical gap", 70, "RIGHT", help = { "Typical gap", "How far under your price each: the median, in coins." } },
        { "Typical gap %", 50, "RIGHT", help = { "Typical gap %", "The same in percent of your price each." } } },
    items = { { "Gear", 220 }, { "Disenchanted", 70, "RIGHT", help = { "Disenchanted", "Pieces of this gear you "
            .. "bought and disenchanted, with a known price. Grey: fewer than 20, too few to trust." } },
        { "Paid each", 70, "RIGHT" }, { "Sold value each", 80, "RIGHT" }, { "Profit", 80, "RIGHT" },
        { "Return", 50, "RIGHT" } },
}

-- The search of each view (UI.md Controls 6), remembered per view: its key is the view and its subtab
-- ("gear.bands"). The Gold statement has none (a statement reads as a whole).
Reports.search = {}
local NO_SEARCH = { ["gold.statement"] = true }

--- The key of the view shown, for its search: "gold.changes", "gear.bands", "gear.history", "materials",
--- "competition"; nil where the view has no search.
function Reports.SearchKey()
    local key = Reports.view
    if key == "gold" then key = "gold." .. Reports.goldTab end
    if key == "gear" then key = "gear." .. Reports.gearTab end
    if NO_SEARCH[key] then return nil end
    return key
end

--- The text searched in the view shown ("" = none).
function Reports.SearchText()
    local key = Reports.SearchKey()
    return key and Reports.search[key] or ""
end

local function matches(name) return W.Matches(name, Reports.SearchText()) end

--- Does a disenchant pass the filters? (Gear type, quality, item level band, with or without the Salvager.)
function Reports.Keep(r)
    local x = Reports.filter
    if not x.classes[r.classID] or not x.qualities[r.quality] then return false end
    if x.salvager == "with" and not r.salvager then return false end
    if x.salvager == "without" and r.salvager then return false end
    local ilvl = r.ilvl or r.band or 0
    for _, b in ipairs(ns.LevelBands()) do
        if ilvl <= b.up then
            if x.bandsOff[b.up] then return false end
            break
        end
    end
    -- The search: the gear's name.
    return matches(r.link or (r.itemID and ns.GetItemInfo(r.itemID)) or "")
end

------------------------------------------------------------------ rows

-- Amounts. flow: + or - and the coins, no color. real: the same in green (gain) or red (loss), for real gold.
-- est: values at today's prices, green or red like gold (UI.md Tables 7).
local function flow(c)
    c = math.floor((c or 0) + 0.5)
    return (c > 0 and "+" or "") .. ns.MoneyColumn(c)
end
local function real(c)
    c = math.floor((c or 0) + 0.5)
    return (c > 0 and GREEN or c < 0 and RED or "") .. flow(c) .. ((c ~= 0) and "|r" or "")
end
local function est(c) return real(c) end   -- a value at today's prices: green or red like gold (UI.md Tables 7)

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
        .. Reports.Length((to or time()) - from) .. "), times in " .. ns.TimesName()) or "every record kept"
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
        if e.k ~= "start" and matches(e.r) then
            log[#log + 1] = { cells = { e.r or GREY .. "-|r", ns.Date("%m-%d %H:%M", e.t), real(e.d),
                ns.Journal.KIND_NAME[e.k] or e.k, ns.MoneyColumn(e.b) }, link = e.r and e.r:match("|Hitem:[^|]+|h") and e.r }
        end
    end
    if #log == 0 and Reports.SearchText() ~= "" then log[1] = note(W.NoMatch(Reports.SearchText())) end
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
        if Reports.SearchText() ~= "" then return { note(W.NoMatch(Reports.SearchText())) } end
        return { note("No disenchant of gear with a known price in this time and these filters. Buy from the "
            .. "main window's Gear tab, then disenchant.") }
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
        function(of, label) return { group = true, cells = profitCells(sum(of), label) } end, INDENT,
        { collapsed = ns.GroupState("reports.bands"), changed = function() Reports.Refresh() end })) do
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
    for _, m in ipairs(p.mats) do
        seen[m.id] = true
        if matches(ns.MaterialName(m.id)) then list[#list + 1] = m end
    end
    for _, mat in ipairs(ns.Data.MATERIALS) do
        local held, listed = heldAndListed(mat.id)
        if not seen[mat.id] and held + listed > 0 and matches(ns.MaterialName(mat.id)) then
            list[#list + 1] = { id = mat.id, got = 0, sold = 0, net = 0, cost = 0, profit = 0, untracked = 0,
                depositsLost = 0 }
        end
    end
    if #list == 0 and Reports.SearchText() ~= "" then return { note(W.NoMatch(Reports.SearchText())) } end
    if #list == 0 then return { note("No material got, sold, held or listed in this time.") } end
    ns.Data.SortMaterials(list, function(m) return m.id end)   -- (the materials' order, as every material list)
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

--- Each piece of gear, the best first (the Gear view's History).
function Reports.ItemRows()
    local from, _, to = Reports.From()
    local p = Ledger.Profits(ns.db.ledger, from, Reports.Keep, to)
    if #p.items == 0 and Reports.SearchText() ~= "" then return { note(W.NoMatch(Reports.SearchText())) } end
    if #p.items == 0 then return { note("No disenchant of gear with a known price in this time and these filters.") } end
    local rows = {}
    for _, it in ipairs(p.items) do
        local profit = math.floor(it.sold + 0.5) - it.paid
        rows[#rows + 1] = { itemID = it.itemID, link = it.link, cells = { it.link or tostring(it.itemID), count(it.n),
            money(it.paid / it.n), money(it.sold / it.n), signed(profit), pct(profit, it.paid) } }
    end
    return rows
end

------------------------------------------------------------------ competition (SDD 109)

--- The material picked in the Material filter (nil = all).
local function compMaterial() return tonumber(Reports.compMaterial) end

local function hoursText(order)
    local out = {}
    for i = 1, math.min(2, #order) do out[#out + 1] = string.format("%02d h", order[i].h) end
    return table.concat(out, ", ")
end

local function matNames(order)
    local out = {}
    for i, m in ipairs(order) do
        if i > 3 then out[#out] = out[#out] .. ", ..." break end
        out[#out + 1] = ns.MaterialName(m.id) or tostring(m.id)
    end
    return table.concat(out, ", ")
end

local function share(n, total)
    if not total or total == 0 then return GREY .. "-|r" end
    return math.floor(n / total * 100 + 0.5) .. "%"
end

--- The period before this one, of the same length (nil for All time).
local function previous(from, to)
    if not from then return nil end
    local stop = to or time()
    return from - (stop - from), from - 1
end

--- The summary, a statement (UI.md Statements): what the undercuts were, what they cost, what is at stake now, and
--- how you answered.
function Reports.CompetitionSummaryRows()
    local from, name, to = Reports.From()
    local state, id = ns.db.competition, compMaterial()
    local list, total = ns.Competition.Competitors(state, from, to, id)
    local mats = ns.Competition.Materials(state, from, to, id)
    local lost = ns.Competition.Lost(state, from, to, id)
    local answers = ns.Competition.Answers(state, from, to, id)
    local live = {}
    for _, r in ipairs(ns.db.listings.rows or {}) do
        if not r.sold and (not id or r.itemID == id) then
            live[#live + 1] = { auctionID = r.auctionID, id = r.itemID, qty = r.qty, each = r.each }
        end
    end
    local stake, undercut, lowered = ns.Competition.AtStake(state, live, time())
    local span = from and (when(from) .. " to " .. (to and when(to) or "now") .. " (" .. Reports.Length((to or time()) - from)
        .. "), times in " .. ns.TimesName()) or "every record kept"
    local rows = {}
    rows[1] = { cells = { "Undercuts of your auctions" .. (id and (", " .. (ns.MaterialName(id) or "")) or ""), "" },
        bold = true, tip = { "Competition", "Who listed under the price of your auctions, what it cost you and how you "
            .. "answered. Every material search counts: Check undercuts, the Post window, a material scan." } }
    rows[2] = { cells = { GREY .. name .. ": " .. span .. "|r", "" } }
    rows[#rows + 1] = GAP_ROW
    rows[#rows + 1] = heading("Undercuts", { "Undercuts", "Price lines of others seen under one of your auctions: once "
        .. "per line and owner, not again while the line stays the same." })
    rows[#rows + 1] = line("Undercuts seen", tostring(total), { "Undercuts seen", "Every one in this period." })
    rows[#rows + 1] = line("Competitors", tostring(#list), { "Competitors", "Sellers seen under you (Unknown seller "
        .. "counts as one)." })
    local top = mats[1]
    rows[#rows + 1] = line("Material most undercut", top and string.format("%s (%d)", ns.MaterialName(top.key) or "?",
        top.n) or "-", { "Material most undercut", "The material with the most undercuts, and how many." })
    rows[#rows + 1] = GAP_ROW
    rows[#rows + 1] = heading("Profit lost to competitors", { "Profit lost to competitors", "What their undercuts "
        .. "cost you in this period, in three parts." })
    rows[#rows + 1] = line("Cancel fees and deposits of undercut auctions you cancelled", flow(-lost.cancel), {
        "Cancel fees and deposits", "Each cancel of an auction of yours while it was undercut: the fee and the deposit "
            .. "the auction house kept." })
    rows[#rows + 1] = line("Deposits of the reposts", flow(-lost.repost), { "Deposits of the reposts", "The deposit "
        .. "of each post that replaced an undercut auction you cancelled (within an hour)." })
    rows[#rows + 1] = line("Lower sale prices of reposted units", flow(-lost.price), { "Lower sale prices",
        "Units that sold after you lowered your price because of an undercut: your first price minus the price they "
            .. "sold at, times the units (first in, first out, along cancel and repost)." })
    rows[#rows + 1] = totalLine("Profit lost to competitors", real(-lost.total), { "Profit lost to competitors",
        "The sum of the three lines above. Units not sold yet are not in it: they are at stake (below)." }, true)
    rows[#rows + 1] = GAP_ROW
    rows[#rows + 1] = heading("At stake now (not sold yet)", { "At stake now", "Not lost yet: what your auctions on "
        .. "the auction house now stand to lose to the listings under them." })
    rows[#rows + 1] = line("Undercut auctions: your units × the gap", flow(-undercut), { "Undercut auctions",
        "Your auctions with a cheaper listing of others in the last search of their material (30 minutes at most): "
            .. "units times the gap to the cheapest." })
    rows[#rows + 1] = line("Reposted units under their first price", flow(-lowered), { "Reposted units",
        "Units you reposted lower after an undercut: units times your first price minus the price now." })
    rows[#rows + 1] = totalLine("Gold at stake", real(-stake), { "Gold at stake", "The sum of the two lines above." })
    rows[#rows + 1] = GAP_ROW
    rows[#rows + 1] = heading("How you answered", { "How you answered", "What you did about the undercuts." })
    rows[#rows + 1] = line("Undercut auctions you cancelled", tostring(answers.cancels), { "Cancelled",
        "Cancels of your auctions while they were undercut." })
    rows[#rows + 1] = line("Reposted after an undercut", string.format("%d of %d", answers.reposts, answers.cancels), {
        "Reposted", "Posts that replaced an undercut auction you cancelled, of all such cancels." })
    rows[#rows + 1] = line("Typical time from the undercut to the repost", answers.delay
        and Reports.Length(answers.delay) or "-", { "Time to repost", "The median time from the first undercut seen "
            .. "of the auction to the post that replaced it." })
    return rows
end

--- One heading row per competitor (the most undercuts first) that opens to its materials; the totals last.
function Reports.CompetitorRows()
    local from, _, to = Reports.From()
    local state, id = ns.db.competition, compMaterial()
    local list, total = ns.Competition.Competitors(state, from, to, id)
    if #list == 0 then
        return { note("No undercut in this period. Check undercuts, the Post window's search and a material scan "
            .. "record who lists under your price.") }
    end
    local lost = ns.Competition.Lost(state, from, to, id)
    local pf, pt = previous(from, to)
    local before = pf and ns.Competition.Counts(state, pf, pt, id)
    local groups, rows = ns.GroupState("reports.competitors"), {}
    local shownN, shownLost = 0, 0   -- (the totals of the rows shown: the search narrows them)
    for _, g in ipairs(list) do if matches(g.key) then
        local by = lost.by[g.key] or { total = 0, cancel = 0, repost = 0, price = 0, mats = {} }
        shownN, shownLost = shownN + g.n, shownLost + by.total
        local trend = GREY .. "-|r"
        if before then
            local d = g.n - (before[g.key] or 0)
            trend = d == 0 and "0" or ((d < 0 and GREEN or RED) .. (d > 0 and "+" or "") .. d .. "|r")
        end
        local head = { group = true, cells = { g.key, tostring(g.n), share(g.n, total), matNames(g.matOrder),
            gapCol(g.gap), gapPctCol(g.pct), money(g.lowest), when(g.first), when(g.last), hoursText(g.hourOrder), trend,
            lostCol(by.total) },
            tip = { g.key, "Profit lost to them: cancel fees and deposits " .. lostCol(by.cancel) .. ", deposits of the "
                .. "reposts " .. lostCol(by.repost) .. ", lower sale prices " .. lostCol(by.price) .. ".",
                string.format("Lowest price: %s each, on %s.", ns.Money(g.lowest), ns.MaterialName(g.lowestId) or "?"),
                "Click: open or close, per material." } }
        rows[#rows + 1] = head
        if ns.HeadingToggle(head, groups, g.key, function() Reports.Refresh() end, true) then
            local order = {}
            for i, m in ipairs(g.matOrder) do order[i] = m end
            for _, m in ipairs(ns.Data.SortMaterials(order, function(x) return x.id end)) do
                local x = g.byMat[m.id]
                rows[#rows + 1] = { indent = INDENT, itemID = m.id, cells = { ns.MaterialName(m.id) or tostring(m.id),
                    tostring(x.n), share(x.n, g.n), "", gapCol(x.gap), gapPctCol(x.pct), money(x.lowest), when(x.first),
                    when(x.last), hoursText(x.hourOrder), "", lostCol(by.mats[m.id]) } }
            end
        end
    end end
    if #rows == 0 then return { note(W.NoMatch(Reports.SearchText())) } end
    rows[#rows + 1] = { rule = "total", bold = true, cells = { "Total", tostring(shownN), share(shownN, total), "", "", "",
        "", "", "", "", "", lostCol(Reports.SearchText() == "" and lost.total or shownLost) } }
    return rows
end

--- One heading row per material (in the materials' order) that opens to its competitors.
function Reports.CompetitionMaterialRows()
    local from, _, to = Reports.From()
    local list = ns.Competition.Materials(ns.db.competition, from, to, compMaterial())
    if #list == 0 then return { note("No undercut in this period.") } end
    ns.Data.SortMaterials(list, function(g) return g.key end)
    local groups, rows = ns.GroupState("reports.compMaterials"), {}
    for _, g in ipairs(list) do if matches(ns.MaterialName(g.key)) then
        local main = g.nameOrder[1]
        local head = { group = true, itemID = g.key, cells = { ns.MaterialName(g.key) or tostring(g.key), tostring(g.n),
            tostring(#g.nameOrder), main and main.name or "-", gapCol(g.gap), gapPctCol(g.pct) } }
        rows[#rows + 1] = head
        if ns.HeadingToggle(head, groups, tostring(g.key), function() Reports.Refresh() end, true) then
            for _, o in ipairs(g.nameOrder) do
                local x = g.byName[o.name]
                rows[#rows + 1] = { indent = INDENT, cells = { o.name, tostring(x.n), "", "", gapCol(x.gap), gapPctCol(x.pct) } }
            end
        end
    end end
    if #rows == 0 then return { note(W.NoMatch(Reports.SearchText())) } end
    return rows
end

--- The Material filter's choices: All, then every material seen undercut (by name).
function Reports.MaterialOptions()
    local out, seen = { { "all", "All" } }, {}
    for _, e in ipairs(ns.db.competition.events or {}) do seen[e.id] = true end
    for _, m in ipairs(ns.Data.MATERIALS) do
        if seen[m.id] then out[#out + 1] = { tostring(m.id), m.name } end
    end
    return out
end

------------------------------------------------------------------ window

local f, list, filterRow, rangeDrop
local searchBox, searchParts, periodLabel = nil, {}, nil   -- the filter row's search, and the Period label after it
local SEARCH_W = 110
local tabs, filters, goldTabs, gearTabs = {}, {}, {}, {}
local comp = {}   -- the Competition view: its Material filter (label, help, dropdown), titles and its three tables
local GOLD_TABS = {
    { "statement", "Statement", "What the trading made and how much richer you are, then the check against your gold." },
    { "changes", "All gold changes", "Every change of your gold, newest first, with its kind." },
}
-- The Gear view's subtabs: Bands first (the main one), then History.
local GEAR_TABS = {
    { "bands", "Bands", "The profit by gear type, quality and item level band. A heading opens and closes." },
    { "history", "History", "Every piece of gear you bought and disenchanted, the best first." },
}
-- The rows from the top (UI.md Controls 1): the tabs, the subtabs (Gold and Gear), the filter row, the content.
local TABS_TOP = 24
local bars = {}   -- tabs, gold and gear (the views' subtabs), filters

--- Keeps the time and the subtabs with the window.
function Reports.Save()
    if f then
        f.saved.range, f.saved.goldTab, f.saved.gearTab = Reports.range, Reports.goldTab, Reports.gearTab
        f.saved.compMaterial = Reports.compMaterial
    end
end
local FILTERED = { gear = true }
local MIN_W = 1050   -- the smallest width: the longest filter row (Gear: Search, Period, Gear, Quality, Bands, Salvager)

local function show(l, cols, rows, setId)
    l:SetColumns(cols, setId)
    l:SetSource(#rows, function(i) return rows[i] end)
    l:Refresh()
end

--- The Competition view, from `top` down: the summary (a statement, as tall as its rows up to 45% of the room), then
--- the table per competitor and the table per material, each with its title, sharing the rest (60/40).
function Reports.LayoutCompetition(top)
    local summary, names, mats = Reports.CompetitionSummaryRows(), Reports.CompetitorRows(), Reports.CompetitionMaterialRows()
    local ROW, TITLE = 22, 20
    local room = math.max(0, (tonumber((f:GetHeight())) or 0) - top - 14 - 2 * TITLE)
    local hSum = math.max(2 * ROW, math.min(math.floor(room * 0.45), (#summary + 1) * ROW + 4))
    local rest = math.max(4 * ROW, room - hSum - 6)
    local hNames = math.floor(rest * 0.6)
    comp.summary:ClearAllPoints()
    comp.summary:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -top)
    comp.summary:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -top)
    comp.summary:SetHeight(hSum)
    comp.namesTitle:ClearAllPoints()
    comp.namesTitle:SetPoint("TOPLEFT", comp.summary, "BOTTOMLEFT", 2, -6)
    comp.names:ClearAllPoints()
    comp.names:SetPoint("TOPLEFT", comp.summary, "BOTTOMLEFT", 0, -6 - TITLE)
    comp.names:SetPoint("TOPRIGHT", comp.summary, "BOTTOMRIGHT", 0, -6 - TITLE)
    comp.names:SetHeight(hNames)
    comp.matsTitle:ClearAllPoints()
    comp.matsTitle:SetPoint("TOPLEFT", comp.names, "BOTTOMLEFT", 2, -4)
    comp.mats:ClearAllPoints()
    comp.mats:SetPoint("TOPLEFT", comp.names, "BOTTOMLEFT", 0, -4 - TITLE)
    comp.mats:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    show(comp.summary, COLUMNS.statement, summary, "reports.compSummary")
    show(comp.names, COLUMNS.compNames, names, "reports.compNames")
    show(comp.mats, COLUMNS.compMats, mats, "reports.compMats")
end

function Reports.Refresh()
    if not f or not f:IsShown() then return end
    local gold, gear = Reports.view == "gold", Reports.view == "gear"
    -- The filter row: under the view's subtabs (Gold, Gear), else right under the tabs; the content under it.
    local top = TABS_TOP + W.BAR_H.tabs + 4
    bars.gold:SetShown(gold)
    bars.gear:SetShown(gear)
    if gold or gear then top = top + W.BAR_H.subtabs + 4 end
    filterRow:Place(top, 12, 12)
    local contentTop = top + W.BAR_H.filters + 4
    list:ClearAllPoints()
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -contentTop)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    local competition = Reports.view == "competition"
    list:SetShown(not competition)
    for _, x in ipairs(comp.controls) do x:SetShown(competition) end
    for _, x in ipairs(comp.parts) do x:SetShown(competition) end
    -- The search first, where the view has one; the Period comes first where it has none.
    local searchable = Reports.SearchKey() ~= nil
    for _, x in ipairs(searchParts) do x:SetShown(searchable) end
    if searchable then searchBox:Update() end
    periodLabel:ClearAllPoints()
    if searchable then periodLabel:SetPoint("LEFT", searchBox, "RIGHT", 16, 0)
    else periodLabel:SetPoint("LEFT", filterRow, "LEFT", 2, 0) end
    -- The Gear and Items views have their own filters after the period.
    local filtered = FILTERED[Reports.view] or false
    for _, x in ipairs(filters) do
        x:SetShown(filtered)
        if x.Update then x:Update() end
    end
    for key, b in pairs(goldTabs) do b:SetSelected(key == Reports.goldTab) end
    for key, b in pairs(gearTabs) do b:SetSelected(key == Reports.gearTab) end
    if gold then
        if Reports.goldTab == "changes" then
            show(list, COLUMNS.goldLog, Reports.ChangeRows(), "reports.goldLog")
        else
            show(list, COLUMNS.statement, Reports.StatementRows(), "reports.statement")
        end
    elseif gear then
        -- (The column sets keep their names from before 0.3.129: the columns hidden with the chooser stay hidden.)
        if Reports.gearTab == "history" then
            show(list, COLUMNS.items, Reports.ItemRows(), "reports.items")
        else
            show(list, COLUMNS.profit, Reports.ProfitRows(), "reports.profit")
        end
    elseif competition then
        Reports.LayoutCompetition(contentTop)
    else
        show(list, COLUMNS.materials, Reports.MaterialRows(), "reports.materials")
    end
    -- As wide as the table's columns need, up to the screen (SDD 107).
    local shown = competition and { comp.summary, comp.names, comp.mats } or { list }
    if W.FitTables(f, MIN_W, shown) then for _, l in ipairs(shown) do l:Refresh() end end
    if competition then comp.drop:Update() end
    for key, b in pairs(tabs) do b:SetSelected(key == Reports.view) end
    rangeDrop:SetOptions(Reports.PeriodOptions(), 190)
    rangeDrop:Update()
end

local function build()
    f = W.Window("SalvagerReportsFrame", "Salvager Reports", "reports", MIN_W, 480, MIN_W, 300)
    local old = OLD_VIEW[f.saved.view]
    if old then f.saved.view, f.saved.gearTab = old[1], old[2] end
    if TITLES[f.saved.view] then Reports.view = f.saved.view end
    for _, t in ipairs(GEAR_TABS) do if t[1] == f.saved.gearTab then Reports.gearTab = t[1] end end
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
    -- The filter row: the search (UI.md Controls 6; not on the Gold statement), the period for every view, then the
    -- Gear view's own filters.
    filterRow = W.Bar(f, "filters")
    bars.filters = filterRow
    if type(f.saved.search) == "table" then Reports.search = f.saved.search end
    f.saved.search = Reports.search
    local SEARCH_HELP = "Shows the rows whose name has this text, in any case: the gear's name (Gear), the material's "
        .. "(Materials), the competitor's and the material's (Competition), what changed your gold (All gold changes). "
        .. "Each view keeps its own."
    searchBox = W.Search(filterRow, SEARCH_W, function() return Reports.SearchText() end, function(text)
        local key = Reports.SearchKey()
        if not key then return end
        Reports.search[key] = text ~= "" and text or nil
        list.offset = 0
        Reports.Refresh()
    end, SEARCH_HELP)
    local searchLabel, searchArea = filterRow:AddFilter("Search", searchBox, SEARCH_W, SEARCH_HELP)
    searchParts = { searchLabel, searchArea, searchBox }
    Reports.searchBox = searchBox   -- (the specs type in it)
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
    periodLabel = filterRow:AddFilter("Period", rangeDrop, 170, "The time the reports cover.")
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
    -- The Competition view's filter after the period: one material, or all.
    if f.saved.compMaterial then Reports.compMaterial = f.saved.compMaterial end
    local MAT_HELP = "One material's undercuts, or all."
    comp.drop = W.Dropdown(filterRow, 150, Reports.MaterialOptions(),
        function(key) return key == (Reports.compMaterial or "all") end,
        function(key)
            Reports.compMaterial = key ~= "all" and key or nil
            Reports.Save()
            comp.drop:Close()
            changed()
        end, MAT_HELP, "Material",
        function(names) return names[1] or "All" end)
    -- (Its options follow the materials seen: filled again at each refresh.)
    local oldUpdate = comp.drop.Update
    function comp.drop.Update(self)
        self:SetOptions(Reports.MaterialOptions(), 150)
        oldUpdate(self)
    end
    -- (In the place of the Gear view's filters, right after the period: only one of them shows.)
    local matLabel = W.Label(filterRow, "Material", "GameFontHighlightSmall")
    matLabel:SetPoint("LEFT", rangeDrop, "RIGHT", 16, 0)
    comp.drop:ClearAllPoints()
    comp.drop:SetPoint("LEFT", matLabel, "RIGHT", 6, 0)
    local matArea = W.HelpArea(filterRow, matLabel, "Material", MAT_HELP)
    comp.controls = { matLabel, matArea, comp.drop }
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
    -- The Gear view's subtabs: Bands, then History.
    bars.gear = W.Bar(f, "subtabs"):Place(TABS_TOP + W.BAR_H.tabs + 4, 12, 12)
    for _, t in ipairs(GEAR_TABS) do
        local b = W.Subtab(bars.gear, t[2], function()
            Reports.gearTab = t[1]
            Reports.Save()
            list.offset = 0
            Reports.Refresh()
        end, t[3])
        bars.gear:Add(b, 70)
        gearTabs[t[1]] = b
    end
    Reports.bars, Reports.tabs, Reports.gearTabs = bars, tabs, gearTabs   -- (the specs read them)
    list = W.List(f, { rowHeight = 22 })
    Reports.list = list
    -- The Competition view's three tables (UI.md Tables 3: one inset per section), the last two with a title.
    comp.summary = W.List(f, { rowHeight = 22 })
    comp.namesTitle = W.Label(f, GOLD .. "Per competitor|r" .. GREY .. "  the most undercuts first; click one for its "
        .. "materials|r", "GameFontNormal")
    comp.names = W.List(f, { rowHeight = 22 })
    comp.matsTitle = W.Label(f, GOLD .. "Per material|r" .. GREY .. "  in the materials' order; click one for its "
        .. "competitors|r", "GameFontNormal")
    comp.mats = W.List(f, { rowHeight = 22 })
    comp.parts = { comp.summary, comp.namesTitle, comp.names, comp.matsTitle, comp.mats }
    Reports.comp = comp   -- (the specs read it)
    for _, l in ipairs({ comp.summary, comp.names, comp.mats }) do
        l.onColumnsChanged = function() Reports.Refresh() end
        l:Hide()
    end
    f.onResize = Reports.Refresh
    f:HookScript("OnShow", Reports.Refresh)
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

for _, e in ipairs({ "SALVAGER_LEDGER", "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS", "SALVAGER_GOLD",
    "SALVAGER_COMPETITION", "SALVAGER_LISTINGS" }) do
    ns.On(e, function() Reports.Refresh() end)
end

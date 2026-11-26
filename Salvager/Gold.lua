-- Salvager: keeps the gold journal (Journal.lua) up to date, and the /salv gold report.
-- Every change of gold is recorded with its cause: what the addon itself did (a purchase, a deposit, a mail
-- taken) is known exactly; the rest is told by the window that is open (vendor, mailbox, trade, trainer).
local _, ns = ...

local Journal, Util = ns.Journal, ns.Util

local Gold = {}
ns.Gold = Gold

local expected = {}   -- what the addon knows is coming (Journal.Expect)
local opened = {}     -- [window] = time it opened, while it shows
local closed = {}     -- [window] = time it closed
local char

local function db() return ns.db.money end

-- Before 0.3.82 the realm could be empty at login ("Name-"): those records move to the full name.
local function adopt(name, full)
    local m = db()
    local old = name .. "-"
    if old ~= full and m.chars[old] then
        if not m.chars[full] or (m.chars[full].t or 0) < (m.chars[old].t or 0) then m.chars[full] = m.chars[old] end
        m.chars[old] = nil
        for _, e in ipairs(m.entries) do if e.c == old then e.c = full end end
        ns.Log("gold: the records of %s are now under %s", old, full)
    end
end

--- "Name-Realm" of the character played. nil while the game does not tell the realm yet (just after login);
--- with `anyway`, the name alone when it never does.
function Gold.Char(anyway)
    if not char then
        local name = UnitName and UnitName("player")
        if not name then return nil end
        local realm = (GetRealmName and GetRealmName()) or ""
        if realm == "" and GetNormalizedRealmName then realm = GetNormalizedRealmName() or "" end
        if realm == "" and not anyway then return nil end
        char = realm == "" and name or (name .. "-" .. realm)
        if ns.db then adopt(name, char) end
    end
    return char
end

--- The addon is about to change the gold: `amount` (negative = paid) or, when unknown, `sign`.
function Gold.Expect(kind, amount, ref, ttl, sign)
    if amount == 0 then return end
    Journal.Expect(expected, { k = kind, a = amount, sign = sign, r = ref }, GetTime(), ttl)
end

-- A change that comes just after a window closed still belongs to it.
local AFTER_CLOSE = 2
local KIND_OF = { trade = "trade", mail = "mail", taxi = "flight", trainer = "training", auction = "auction" }

-- What an unexplained change is: the window opened last of those that show (the game does not always say
-- that a window closed when another one opens), else one that closed just now.
local function byWindow(d)
    local best, at
    for w, t in pairs(opened) do
        if not at or t > at then best, at = w, t end
    end
    if not best then
        for w, t in pairs(closed) do
            if GetTime() - t <= AFTER_CLOSE and (not at or t > at) then best, at = w, t end
        end
    end
    if best == "merchant" then return d > 0 and "vendor" or "merchant" end
    return KIND_OF[best] or "other"
end

-- One window at a time: opening one closes the others.
local function show(w)
    for other, t in pairs(opened) do
        if other ~= w then opened[other], closed[other] = nil, t and GetTime() end
    end
    opened[w], closed[w] = GetTime(), nil
end
local function hide(w)
    if opened[w] then closed[w] = GetTime() end
    opened[w] = nil
end

local function seen(kindIfChanged)
    local c, balance = Gold.Char(), GetMoney and GetMoney()
    if not c or not balance or not ns.db then return end
    local last = db().chars[c]
    local d = last and (balance - last.b) or 0
    local kind, ref = kindIfChanged, nil
    if d ~= 0 and not kind then
        kind, ref = Journal.Match(expected, d, GetTime())
        kind = kind or byWindow(d)
    end
    local e = Journal.Seen(db(), c, balance, time(), kind, ref)
    if e then
        ns.Log("gold: %s%s %s%s, now %s", e.d > 0 and "+" or "", ns.Money(e.d), Journal.KIND_NAME[e.k] or e.k,
            e.r and (" (" .. e.r .. ")") or "", ns.Money(e.b))
        ns.Fire("SALVAGER_GOLD")
    end
end

local sessionStart
-- The session starts when the game tells the character's realm: at login, or a moment later.
local function start(anyway)
    if sessionStart or not Gold.Char(anyway) or not GetMoney then return false end
    seen("unseen")
    sessionStart = GetMoney()
    ns.Log("session: %s logged in with %s (Salvager %s)", Gold.Char(), ns.Money(sessionStart), ns.VERSION)
    return true
end
ns.On("PLAYER_ENTERING_WORLD", function()
    if sessionStart then seen() return end   -- (a loading screen, not a login)
    if start() then return end
    local tries = 0
    local function again()
        tries = tries + 1
        if not start(tries >= 30) and tries < 30 then C_Timer.After(1, again) end
    end
    C_Timer.After(1, again)
end)
ns.On("PLAYER_MONEY", function() if sessionStart or start() then seen() end end)
-- (At logout the game reports 0 gold: the balance is not read then, the last one seen is the one logged.)
ns.On("PLAYER_LOGOUT", function()
    local last = Gold.Char() and ns.db and db().chars[Gold.Char()]
    if sessionStart and last then
        ns.Log("session: logged out with %s (%s%s this session)", ns.Money(last.b), last.b >= sessionStart and "+" or "",
            ns.Money(last.b - sessionStart))
    end
end)

for _, w in ipairs({ { "merchant", "MERCHANT_SHOW", "MERCHANT_CLOSED" }, { "mail", "MAIL_SHOW", "MAIL_CLOSED" },
    { "trade", "TRADE_SHOW", "TRADE_CLOSED" }, { "taxi", "TAXIMAP_OPENED", "TAXIMAP_CLOSED" },
    { "trainer", "TRAINER_SHOW", "TRAINER_CLOSED" }, { "auction", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" } }) do
    ns.On(w[2], function() show(w[1]) end)
    ns.On(w[3], function() hide(w[1]) end)
end
-- This client opens and closes its windows through the interaction manager (Enum.PlayerInteractionType).
local INTERACTION = { [1] = "trade", [5] = "merchant", [6] = "taxi", [7] = "trainer", [17] = "mail", [21] = "auction" }
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", function(kind) if INTERACTION[kind] then show(INTERACTION[kind]) end end)
ns.On("PLAYER_INTERACTION_MANAGER_FRAME_HIDE", function(kind) if INTERACTION[kind] then hide(INTERACTION[kind]) end end)

-- Mail money: its amount is known before it is taken. An auction sale is a sale; other money is "mail".
local function mailTaken(index)
    if type(index) ~= "number" or not GetInboxHeaderInfo then return end
    local _, _, _, subject, money = GetInboxHeaderInfo(index)
    if not money or money <= 0 then return end
    local invoiceType, itemName
    if GetInboxInvoiceInfo then invoiceType, itemName = GetInboxInvoiceInfo(index) end
    if invoiceType == "seller" then
        Gold.Expect("sale", money, itemName, 10)
    else
        Gold.Expect("mail", money, subject, 10)
    end
end

if hooksecurefunc then
    hooksecurefunc("TakeInboxMoney", function(index) pcall(mailTaken, index) end)
    hooksecurefunc("AutoLootMailItem", function(index) pcall(mailTaken, index) end)
    if _G.RepairAllItems then
        hooksecurefunc("RepairAllItems", function() Gold.Expect("repair", nil, nil, 5, -1) end)
    end
end

------------------------------------------------------------------ report

local HOUR = 3600

--- The sales sold and not collected yet: their money is on its way by mail.
--- @return number copper, number sales, number|nil time the last one arrives
function Gold.InMail()
    local total, n, last = 0, 0, nil
    for _, s in ipairs(ns.db.ledger.sales or {}) do
        if (s.unpaid or 0) > 0 and not s.paidAt then
            total = total + math.floor((s.net or 0) * s.unpaid / math.max(1, s.count or 1) + 0.5)
            n = n + 1
            local due = s.due or ((s.t or 0) + HOUR)
            if not last or due > last then last = due end
        end
    end
    return total, n, last
end

--- The buys disenchanted since `from` that gave less than they cost, worst first.
--- `misjudged` = the item was not what it was valued as when bought (quality, gear type or band).
function Gold.Losses(from)
    local list = {}
    for _, r in ipairs(ns.db.ledger.disenchants or {}) do
        if r.costKnown and (r.boughtAt or r.t or 0) >= from and (r.value or 0) < (r.cost or 0) then
            local j = r.judged
            list[#list + 1] = { link = r.link, cost = r.cost, value = r.value or 0, loss = (r.value or 0) - r.cost,
                misjudged = j and (j.q ~= r.quality or j.cls ~= r.classID or j.band ~= r.band) or false }
        end
    end
    table.sort(list, function(a, b) return a.loss < b.loss end)
    return list
end

local function signed(c) return (c > 0 and "+" or "") .. ns.Money(c) end

--- What happened to this character's gold in the last `hours` hours: Journal.Summary plus the money in
--- the mail (mail, mailSales, mailLast) and the buys that lost (losses, lost, lostWrong). nil before any record.
function Gold.Period(hours)
    seen()
    local c = Gold.Char()
    local now = time()
    local from = now - hours * HOUR
    local s = Journal.Summary(db(), c, from, now)
    if s.start == nil then return nil end
    s.char, s.hours = c, hours
    s.mail, s.mailSales, s.mailLast = Gold.InMail()
    s.losses, s.lost, s.lostWrong = Gold.Losses(from), 0, 0
    for _, l in ipairs(s.losses) do
        s.lost = s.lost + l.loss
        if l.misjudged then s.lostWrong = s.lostWrong + l.loss end
    end
    return s
end

--- Prints what happened to this character's gold in the last `hours` hours.
function Gold.Report(hours)
    hours = hours or 24
    local s = Gold.Period(hours)
    if not s then ns.Print("no gold recorded yet for %s", tostring(Gold.Char())) return end
    ns.Print("gold of %s, last %d h:", s.char, hours)
    ns.Print("  at the start: %s; now: %s (%s)", ns.Money(s.start), ns.Money(s.finish), signed(s.change))
    if s.mailSales > 0 then
        ns.Print("  in the mail: %s from %d sales (the last one at %s); after you take it: %s (%s)", ns.Money(s.mail),
            s.mailSales, date("%H:%M", s.mailLast), ns.Money(s.finish + s.mail), signed(s.change + s.mail))
    end
    for _, k in ipairs(Journal.KINDS) do
        local x = s.kinds[k[1]]
        if x then ns.Print("  %s: %s (%d)", k[2], signed(x.gain + x.loss), x.n) end
    end
    if #s.losses > 0 then
        ns.Print("  buys that lost: %d, %s in all%s", #s.losses, ns.Money(s.lost),
            s.lostWrong < 0 and string.format(", %s of it on items valued as something they were not",
                ns.Money(s.lostWrong)) or "")
        for i = 1, math.min(3, #s.losses) do
            local l = s.losses[i]
            ns.Print("    %s: paid %s, gave %s%s", l.link or "?", ns.Money(l.cost), ns.Money(l.value),
                l.misjudged and " (valued wrong)" or "")
        end
    end
end

ns.On("SALVAGER_READY", function()
    Journal.Init(ns.db.money)
    Util.Cap(ns.db.money.entries, Journal.MAX)
end)

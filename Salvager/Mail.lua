-- Salvager: reads auction house mail.
--   "Auction won" (buyer invoice): records what you paid for gear, for the ledger.
--   "Auction successful" (seller invoice): books a material sale at average cost.
--
-- A mail is booked when its item or money really leaves the mailbox, taken by any window or
-- addon. Mails have no ID, and two purchases of the same item at the same price are identical
-- mails, so the booking goes by count: when a take is asked for, the addon counts the mails
-- of that kind that still hold their item or money, and books one for each that is gone
-- when the mailbox next updates. Asking twice for the same mail books it once; two
-- identical mails are booked twice.
local _, ns = ...

local Data, Ledger = ns.Data, ns.Ledger

local Mail = {}
ns.Mail = Mail

local watch = {}   -- [key] = { info, holding = mails of this kind that still hold their item/money, asked, booked }

-- Material by name: the English name and the client's own. Built once; built again on a miss,
-- since the client's names come in as its item data loads.
local nameToMaterial
local function buildNames()
    nameToMaterial = {}
    for _, m in ipairs(Data.MATERIALS) do
        nameToMaterial[m.name] = m.id
        local local_ = ns.MaterialName(m.id)
        if local_ then nameToMaterial[local_] = m.id end
    end
end
local function materialByName(name)
    if not name then return nil end
    if not nameToMaterial then buildNames() end
    if not nameToMaterial[name] then buildNames() end
    return nameToMaterial[name]
end

local function attachment(index)
    for a = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
        local link = GetInboxItemLink(index, a)
        if link then return ns.ItemID(link), link end
    end
end

--- What kind of auction mail this is. Returns nil for other mail.
--- @return string key, boolean holds (its item or money is still in it), table info
local function describe(index)
    local invoiceType, itemName, _, bid, _, _, consignment, _, _, _, count = GetInboxInvoiceInfo(index)
    if invoiceType ~= "buyer" and invoiceType ~= "seller" then return nil end
    local _, _, sender, subject, money, _, _, itemCount = GetInboxHeaderInfo(index)
    local holds
    if invoiceType == "buyer" then holds = (itemCount or 0) > 0 else holds = (money or 0) > 0 end
    count = (count and count > 0) and count or 1
    local key = table.concat({ invoiceType, tostring(sender), tostring(subject), tostring(itemName), tostring(bid),
        tostring(count) }, "|")
    return key, holds, { type = invoiceType, itemName = itemName, bid = bid or 0, cut = consignment or 0, count = count }
end

--- How many mails of each kind still hold their item or money: one pass over the inbox.
local function holdingAll()
    local out = {}
    for i = 1, (GetInboxNumItems() or 0) do
        local k, holds = describe(i)
        if k and holds then out[k] = (out[k] or 0) + 1 end
    end
    return out
end

local function book(info)
    if info.type == "buyer" then
        local v = ns.ItemValue(info.link or info.itemID)
        local added = Ledger.MailPurchase(ns.db.ledger, info.itemID, info.count, info.bid, v and v.net, time(), info.link)
        ns.Log("mail: bought %s for %s%s", info.link or info.itemID, ns.Money(info.bid),
            added and "" or " (already recorded at the auction house)")
    else
        local rec, matched = Ledger.SalePaid(ns.db.ledger, info.matID, info.count, info.bid, info.cut, time())
        if matched > 0 then
            ns.Log("mail: money for %dx %s (%d already booked when they sold)", info.count, ns.MaterialName(info.matID),
                matched)
        end
        if rec then
            ns.Log("mail: sold %dx %s for %s, profit %s", rec.count, ns.MaterialName(info.matID), ns.Money(rec.net),
                ns.Money(rec.profit))
            ns.Print("sold %dx %s: %s after cut, profit %s%s", rec.count, ns.MaterialName(info.matID), ns.Money(rec.net),
                ns.Money(rec.profit), rec.untracked > 0 and string.format(" (%d had no recorded cost)", rec.untracked) or "")
        end
    end
    ns.Fire("SALVAGER_LEDGER")
end

--- A take was asked for mail `index`: start watching its kind.
local function asked(index)
    if type(index) ~= "number" or not GetInboxInvoiceInfo then return end
    local key, holds, info = describe(index)
    if not key or not holds then return end
    if info.type == "buyer" then
        info.itemID, info.link = attachment(index)
        if not info.itemID then return end
        local classID = ns.ClassOf(info.itemID)
        if classID ~= Data.CLASS_WEAPON and classID ~= Data.CLASS_ARMOR then return end
    else
        info.matID = materialByName(info.itemName)
        if not info.matID then return end
    end
    local w = watch[key]
    if not w then
        w = { holding = holdingAll()[key] or 0, asked = 0, booked = 0 }
        watch[key] = w
    end
    w.info = info
    w.asked = w.asked + 1
end

--- The mailbox changed: book the watched mails that no longer hold their item or money.
local function settle()
    if not next(watch) then return end
    local counts = holdingAll()
    for key, w in pairs(watch) do
        local now = counts[key] or 0
        local gone = math.min(w.holding - now, w.asked - w.booked)
        for _ = 1, gone do
            book(w.info)
            w.booked = w.booked + 1
        end
        w.holding = now
        if now == 0 or w.booked >= w.asked then watch[key] = nil end
    end
end

local function safe(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        ns.Print("mail error: %s", tostring(err))
        ns.Log("ERROR mail: %s", tostring(err))
    end
end

-- Hooks run right after the call, while the mail still holds its item or money.
if hooksecurefunc then
    hooksecurefunc("TakeInboxItem", function(index) safe(asked, index) end)
    hooksecurefunc("TakeInboxMoney", function(index) safe(asked, index) end)
    hooksecurefunc("AutoLootMailItem", function(index) safe(asked, index) end)
end

ns.On("MAIL_INBOX_UPDATE", function() safe(settle) end)

-- Old records that wait for a mail or a disenchant that will not come (Ledger.Expire), once per login.
ns.On("ADDON_LOADED", function(name)
    if name ~= ns.NAME or not ns.db then return end
    local bought, purchases, sales = Ledger.Expire(ns.db.ledger, time())
    if bought + purchases + sales > 0 then
        ns.Log("ledger: dropped after %d days: %d purchases with no mail, %d never disenchanted; %d sales counted "
            .. "as paid", Ledger.EXPIRE_AFTER / 86400, bought, purchases, sales)
    end
end)
ns.On("MAIL_CLOSED", function()
    for _, w in pairs(watch) do
        if w.asked > w.booked then
            ns.Log("mail: the mailbox closed before %d take(s) of %s showed as done: not booked", w.asked - w.booked,
                tostring(w.info and w.info.itemName))
        end
    end
    wipe(watch)
end)

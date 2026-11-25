-- Salvager: reads auction house mail.
--   "Auction won" (buyer invoice): records what you paid for gear, for the ledger.
--   "Auction successful" (seller invoice): books a material sale at average cost.
-- A mail is read when you take its item or money, by any window or addon.
local _, ns = ...

local Data, Ledger = ns.Data, ns.Ledger

local Mail = {}
ns.Mail = Mail

local seen = {}   -- mails already booked this session

local function fingerprint(index)
    local _, _, sender, subject, money, _, daysLeft = GetInboxHeaderInfo(index)
    return table.concat({ tostring(sender), tostring(subject), tostring(money), string.format("%.3f", daysLeft or 0) }, "|")
end

local nameToMaterial
local function materialByName(name)
    if not nameToMaterial then
        nameToMaterial = {}
        for _, m in ipairs(Data.MATERIALS) do nameToMaterial[m.name] = m.id end
    end
    for _, m in ipairs(Data.MATERIALS) do
        local local_ = ns.MaterialName(m.id)
        if local_ then nameToMaterial[local_] = m.id end
    end
    return nameToMaterial[name]
end

local function attachmentID(index)
    for a = 1, (ATTACHMENTS_MAX_RECEIVE or 16) do
        local link = GetInboxItemLink(index, a)
        if link then return ns.ItemID(link), link end
    end
end

local function readMail(index)
    if type(index) ~= "number" or not GetInboxInvoiceInfo then return end
    local invoiceType, itemName, _, bid, _, _, consignment, _, _, _, count = GetInboxInvoiceInfo(index)
    if invoiceType ~= "buyer" and invoiceType ~= "seller" then return end
    local fp = fingerprint(index)
    if seen[fp] then return end
    count = (count and count > 0) and count or 1
    if invoiceType == "buyer" then
        local itemID, link = attachmentID(index)
        if not itemID then return end
        local classID = ns.ClassOf(itemID)
        if classID ~= Data.CLASS_WEAPON and classID ~= Data.CLASS_ARMOR then return end
        seen[fp] = true
        local v = ns.ItemValue(link or itemID)
        Ledger.AddPurchase(ns.db.ledger, itemID, count, bid or 0, v and v.net, time())
        ns.Fire("SALVAGER_LEDGER")
    else
        local matID = materialByName(itemName)
        if not matID then return end
        seen[fp] = true
        local rec = Ledger.Sell(ns.db.ledger, matID, count, bid or 0, consignment or 0, time())
        ns.Print("sold %dx %s: %s after cut, profit %s%s", count, ns.MaterialName(matID), ns.Money(rec.net),
            ns.Money(rec.profit), rec.untracked > 0 and string.format(" (%d had no recorded cost)", rec.untracked) or "")
        ns.Fire("SALVAGER_LEDGER")
    end
end

-- Hooks run right after the call, while the mail is still in the inbox.
local function safe(index)
    local ok, err = pcall(readMail, index)
    if not ok then ns.Print("mail error: %s", tostring(err)) end
end

if hooksecurefunc then
    hooksecurefunc("TakeInboxItem", function(index) safe(index) end)
    hooksecurefunc("TakeInboxMoney", function(index) safe(index) end)
    hooksecurefunc("AutoLootMailItem", function(index) safe(index) end)
end

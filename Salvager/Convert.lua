-- Salvager: follows essences that change form. Three lesser combine into one greater, and one greater
-- splits into three lesser, by a right-click in the bags. The addon sees it in the bag counts: one form
-- goes down and the other goes up by the matching amount in the same bag update. The cost in the
-- ledger then moves to the new form. A bag update that comes with loot, mail or a post is not read as
-- a conversion: those move essences too.
local _, ns = ...

local Data, Ledger = ns.Data, ns.Ledger

local Convert = {}
ns.Convert = Convert

local counts    -- [itemID] = units in the bags at the last look
local BUSY_HOLD = 2   -- seconds after loot, mail or a post in which bag changes are theirs
local busyUntil = 0

--- Loot, mail or a post is moving items: the next bag changes are not a conversion.
function Convert.Busy()
    busyUntil = GetTime() + BUSY_HOLD
end

local function look()
    local now = {}
    for id in pairs(Data.ESSENCE_PAIR) do now[id] = ns.Post.BagCount(id) end
    return now
end

--- Compares the bags with the last look and books the conversions.
function Convert.Check()
    local now = look()
    local before = counts
    counts = now
    if not before or GetTime() <= busyUntil then return end
    for id, pair in pairs(Data.ESSENCE_PAIR) do
        if pair.factor < 1 then   -- once per pair, from its lesser form
            local lesser, greater = id, pair.other
            local dl, dg = now[lesser] - before[lesser], now[greater] - before[greater]
            local from, fromQty, to, toQty
            if dg > 0 and dl == -3 * dg then
                from, fromQty, to, toQty = lesser, -dl, greater, dg
            elseif dg < 0 and dl == -3 * dg then
                from, fromQty, to, toQty = greater, -dg, lesser, dl
            end
            if from then
                local cost, unknown = Ledger.Convert(ns.db.ledger, from, fromQty, to, toQty)
                ns.Log("INFO", "ledger", string.format("converted %dx %s into %dx %s, cost moved %s%s", fromQty,
                    ns.MaterialName(from), toQty, ns.MaterialName(to), ns.Money(cost),
                    unknown > 0 and string.format(" (%d had no recorded cost)", unknown) or ""),
                    { from = from, fromQty = fromQty, to = to, toQty = toQty, cost = cost, unknown = unknown })
                ns.Print("%dx %s became %dx %s: their cost (%s) moved with them", fromQty, ns.MaterialName(from), toQty,
                    ns.MaterialName(to), ns.Money(cost))
                ns.Fire("SALVAGER_LEDGER")
            end
        end
    end
end

for _, e in ipairs({ "LOOT_READY", "LOOT_OPENED", "MAIL_INBOX_UPDATE", "AUCTION_HOUSE_AUCTION_CREATED" }) do
    ns.On(e, Convert.Busy)
end
if hooksecurefunc then
    for _, fn in ipairs({ "TakeInboxItem", "AutoLootMailItem" }) do hooksecurefunc(fn, Convert.Busy) end
end

ns.On("BAG_UPDATE_DELAYED", function()
    local ok, err = pcall(Convert.Check)
    if not ok then ns.Log("ERROR", "ledger", "Lua error following a conversion: " .. tostring(err)) end
end)

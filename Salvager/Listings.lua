-- Salvager: your own auctions (the "pending sales").
-- The list is read whenever the auction house reports your auctions (asked for by this addon or
-- by any other window), and kept in SalvagerDB.listings so the Ledger can show it with the
-- auction house closed, as it was at that time.
--   Check:  searches each listed material and remembers the lowest price that is not yours.
--   Cancel: cancels one undercut listing per click (the game wants a click for each).
local _, ns = ...

local AH = C_AuctionHouse
local Data = ns.Data

local Listings = { checking = nil, pending = nil }
ns.Listings = Listings

local CANCEL_WAIT = 8      -- seconds a cancel may take before it is given up (its answer is a read, see below)
local MAX_POSTED = 300     -- posts remembered (their unit prices are known for sure)
local LOWEST_MAX_AGE = 120 -- seconds a checked lowest price counts: older, the listing counts as not checked
local MAIL_DELAY = 3600    -- a sold auction stays in the list (as sold) about this long, until its money is mailed

local function db()
    local l = ns.db.listings
    l.rows = l.rows or {}
    l.lowest = l.lowest or {}
    return l
end

local function isCommodity(itemID)
    if Data.MATERIAL_BY_ID[itemID] then return true end
    if AH.GetItemCommodityStatus and Enum.ItemCommodityStatus then
        local ok, status = pcall(AH.GetItemCommodityStatus, itemID)
        if ok then return status == Enum.ItemCommodityStatus.Commodity end
    end
    return false
end

--- A post made through Salvager: its price each is known for sure, and so is its deposit.
function Listings.NotePost(auctionID, itemID, quantity, each, deposit)
    local posted = ns.db.posted
    -- `val` = the material's value now: a sale of this post is measured against it (sell price ratio, SDD 3).
    posted[#posted + 1] = { auctionID = auctionID, itemID = itemID, qty = quantity, each = each, t = time(),
        deposit = deposit, val = ns.PriceOf(itemID) }
    ns.Util.Cap(posted, MAX_POSTED)
    ns.ForecastChanged()
end

local function postedEntry(auctionID)
    for i = #ns.db.posted, 1, -1 do
        if ns.db.posted[i].auctionID == auctionID then return ns.db.posted[i] end
    end
end

local function postedPrice(auctionID)
    local p = postedEntry(auctionID)
    return p and p.each
end

--- The auction house keeps the deposit of an auction that expires or is cancelled: a loss in the ledger.
--- `qty` = the units that did not sell; the deposit counts in proportion. Booked once per auction.
--- `fallback` = what to book when the post was not made through Salvager (its deposit is not known).
local function depositLost(auctionID, itemID, qty, why, fallback)
    local p = postedEntry(auctionID)
    if p and p.lost then return end
    local amount = fallback
    if p and p.deposit then amount = math.floor(p.deposit * math.min(qty, p.qty) / math.max(1, p.qty) + 0.5) end
    if p then p.lost = why end
    if not amount or amount <= 0 or not Data.MATERIAL_BY_ID[itemID] then return end
    ns.Ledger.DepositLost(ns.db.ledger, itemID, qty, amount, why, time())
    ns.Log("listings: %dx %s %s, deposit lost %s", qty, ns.MaterialName(itemID), why, ns.Money(amount))
    ns.Fire("SALVAGER_LEDGER")
end

--- Auctions of ours that ended unsold between two reads: the previous read showed them for sale, and
--- now no row for sale is left, past their end time, and not all of it shows as sold. Only judged when
--- the reads are less than MAIL_DELAY apart: a part sold since then would still show as sold.
local function findExpired(prev, prevT, rows, now)
    if not prevT or now - prevT >= MAIL_DELAY then return end
    local open, soldNow, soldBefore = {}, {}, {}
    for _, r in ipairs(rows) do
        if r.sold then soldNow[r.auctionID] = (soldNow[r.auctionID] or 0) + r.qty else open[r.auctionID] = true end
    end
    for _, r in ipairs(prev) do
        if r.sold then soldBefore[r.auctionID] = (soldBefore[r.auctionID] or 0) + r.qty end
    end
    for _, r in ipairs(prev) do
        if not r.sold and not open[r.auctionID] and r.left and now >= prevT + r.left - 60 then
            local unsold = r.qty - math.max(0, (soldNow[r.auctionID] or 0) - (soldBefore[r.auctionID] or 0))
            if unsold > 0 then depositLost(r.auctionID, r.itemID, unsold, "expired") end
        end
    end
end

local findCancelled

--- Reads your auctions from the game into the saved list.
function Listings.Read()
    local l = db()
    local rows = {}
    local prev, prevT = l.rows, l.t
    for i = 1, (AH.GetNumOwnedAuctions() or 0) do
        local info = AH.GetOwnedAuctionInfo(i)
        if info and info.itemKey then
            local qty = info.quantity or 1
            local price = info.buyoutAmount or info.bidAmount or 0
            -- The game gives the price of one. A post of ours tells if this client gives the total instead.
            local known = postedPrice(info.auctionID)
            if known and qty > 1 and price ~= known and price == known * qty and not l.priceIsTotal then
                l.priceIsTotal = true
                ns.Log("listings: this client reports the total price of a listing, not the price each")
            end
            local each = known or (l.priceIsTotal and math.floor(price / qty + 0.5)) or price
            rows[#rows + 1] = {
                auctionID = info.auctionID, itemID = info.itemKey.itemID, link = info.itemLink, qty = qty, each = each,
                sold = info.status == Enum.AuctionStatus.Sold, left = info.timeLeftSeconds,
                commodity = isCommodity(info.itemKey.itemID),
            }
        end
    end
    l.rows, l.t = rows, time()
    findCancelled(prev, rows)
    findExpired(prev, prevT, rows, l.t)
    -- A sale is known as soon as its listing shows as sold: book it now, not when the mail is taken.
    local sold = {}
    for _, r in ipairs(rows) do
        if r.sold and Data.MATERIAL_BY_ID[r.itemID] then
            sold[#sold + 1] = { auctionID = r.auctionID, qty = r.qty, due = l.t + (r.left or 0), itemID = r.itemID,
                each = r.each, left = r.left }
        end
    end
    local booked = false
    for _, r in ipairs(ns.Ledger.NewSold(ns.db.ledger, sold, l.t)) do
        local rec = ns.Ledger.SaleSeen(ns.db.ledger, r.itemID, r.qty, r.each, ns.Cut(), l.t)
        rec.due = r.due   -- when its money arrives, for the countdown in the Ledger
        local post = postedEntry(r.auctionID)
        rec.val = post and post.val or nil   -- the value when it was posted (sell price ratio, SDD 3)
        rec.postedAt = post and post.t or nil   -- when it was posted (time to sell, SDD 100)
        -- Sold before this session started (not seen since then, its money due an hour after the sale): a sale
        -- made while you were away.
        local start = ns.Gold.SessionStart()
        if start and (not prevT or prevT < start) and r.due - ns.Gold.MAIL_DELAY < start then rec.away = true end
        booked = true
        ns.Log("sold %dx %s at %s each: %s after cut, profit %s (money in %d min)", r.qty, ns.MaterialName(r.itemID),
            ns.Money(r.each), ns.Money(rec.net), ns.Money(rec.profit), math.floor((r.left or 0) / 60 + 0.5))
        ns.Print("sold %dx %s: %s after cut, profit %s%s. The money comes by mail in about %d min.", r.qty,
            ns.MaterialName(r.itemID), ns.Money(rec.net), ns.Money(rec.profit),
            rec.untracked > 0 and string.format(" (%d had no recorded cost)", rec.untracked) or "",
            math.floor((r.left or 0) / 60 + 0.5))
    end
    if booked then ns.Fire("SALVAGER_LEDGER") end
    ns.Fire("SALVAGER_LISTINGS")
    -- Someone waits for this read (the queue answers before this list is read).
    local after = Listings.afterRead
    Listings.afterRead = nil
    if after then after(true) end
end

--- Asks the auction house for your auctions. `now` = ahead of everything else (the player asked).
--- `after(ok)` runs once the answer has been read into the list (ok = false: no answer, the last list stays).
function Listings.Refresh(now, after)
    if not ns.Queue.open then return false end
    if after then Listings.afterRead = after end
    ns.Queue.Add({ owned = true, once = true, onResult = function() end,
        onFail = function()
            ns.Log("listings: the auction house did not send your auctions")
            local cb = Listings.afterRead
            Listings.afterRead = nil
            if cb then cb(false) end
        end }, now)
    return true
end

--- Seconds left for a row now (it was read some time ago). nil when the game gave none.
function Listings.TimeLeft(row)
    if not row.left then return nil end
    return math.max(0, row.left - (time() - (db().t or time())))
end

local function freshLowest(itemID)
    local low = db().lowest[itemID]
    if not low or not low.t or time() - low.t > LOWEST_MAX_AGE then return nil end
    return low
end

--- What a cancel and a new post of a row cost: the deposit the auction house keeps (the cancel cost the
--- game names, else the deposit recorded at the post) and the deposit of the new post.
function Listings.RepostCost(row)
    local lost
    if AH.GetCancelCost then
        local ok, c = pcall(AH.GetCancelCost, row.auctionID)
        if ok then lost = tonumber(c) end
    end
    if not lost then
        local p = postedEntry(row.auctionID)
        lost = p and p.deposit and math.floor(p.deposit * row.qty / math.max(1, p.qty) + 0.5)
    end
    local again
    if AH.CalculateCommodityDeposit then
        local ok, d = pcall(AH.CalculateCommodityDeposit, row.itemID, ns.db.settings.postDuration, row.qty)
        if ok then again = tonumber(d) end
    end
    return (lost or 0) + (again or 0)
end

--- How far a row is undercut: copper each below your price, or nil (not undercut, not checked in the last
--- LOWEST_MAX_AGE seconds, or undercut by less in all than a cancel and a new post would cost in deposits).
function Listings.Undercut(row)
    if row.sold or not row.commodity then return nil end
    local low = freshLowest(row.itemID)
    if not (low and low.lo) or low.lo >= row.each then return nil end
    local gap = row.each - low.lo
    if gap * row.qty < Listings.RepostCost(row) then return nil end
    return gap
end

--- "checked" state of a row: nil = not checked (or too long ago), false = nobody else lists it, number = lowest
--- other price.
function Listings.Lowest(row)
    local low = freshLowest(row.itemID)
    if not low then return nil end
    return low.lo or false
end

--- How many listings are still for sale (not sold).
function Listings.CountUnsold()
    local n = 0
    for _, row in ipairs(db().rows) do if not row.sold and row.commodity then n = n + 1 end end
    return n
end

function Listings.CountUndercut()
    local n = 0
    for _, row in ipairs(db().rows) do if Listings.Undercut(row) then n = n + 1 end end
    return n
end

--- Searches every listed commodity for its lowest price that is not yours. Your auctions are read
--- first; the searches go out once that answer is in.
function Listings.Check()
    if not ns.Queue.open then ns.Print("open the auction house first") return end
    if Listings.checking then return end
    if ns.Prices.scanning then
        ns.Defer("check", function() return not ns.Prices.scanning end, Listings.Check, "The undercut check",
            "the material scan is done")
        return
    end
    local check = { done = 0, total = 0 }
    Listings.checking = check
    ns.Fire("SALVAGER_LISTINGS")
    Listings.Refresh(true, function() Listings.CheckRows(check) end)
end

--- The searches of a check, from the rows just read.
function Listings.CheckRows(check)
    if Listings.checking ~= check then return end   -- stopped meanwhile
    local ids, seen = {}, {}
    for _, row in ipairs(db().rows) do
        if not row.sold and row.commodity and not seen[row.itemID] then
            seen[row.itemID] = true
            ids[#ids + 1] = row.itemID
        end
    end
    if #ids == 0 then
        Listings.checking = nil
        ns.Print("nothing listed to check")
        ns.Fire("SALVAGER_LISTINGS")
        return
    end
    check.total = #ids
    ns.Log("listings: checking %d listed materials for undercuts", #ids)
    local function step()
        local c = Listings.checking
        if c ~= check then return end
        c.done = c.done + 1
        if c.done >= c.total then
            Listings.checking = nil
            local n = Listings.CountUndercut()
            ns.Log("listings: check done, %d undercut", n)
            ns.Print(n > 0 and "%d of your listings are undercut" or "none of your listings is undercut", n)
        end
        ns.Fire("SALVAGER_LISTINGS")
    end
    for _, itemID in ipairs(ids) do
        ns.Queue.Add({
            commodity = itemID,
            onResult = function()
                local e = ns.Prices.ReadCommodity(itemID, 1)
                db().lowest[itemID] = { lo = e and e.lo or nil, t = time() }
                if Data.MATERIAL_BY_ID[itemID] then ns.Prices.Store(itemID) end
                step()
            end,
            onFail = step,
        })
    end
    ns.Fire("SALVAGER_LISTINGS")
end

--- Is a cancel on its way? (Searches wait for it.)
function Listings.Cancelling()
    local p = Listings.pending
    if not p then return false end
    if GetTime() - p.t < CANCEL_WAIT then return true end
    Listings.pending = nil
    ns.Log("listings: the cancel of %s got no answer", ns.MaterialName(p.row.itemID))
    return false
end

--- Cancels the next undercut listing. Must run from a click. Returns true when one was sent.
function Listings.CancelNext()
    if not ns.Queue.open then ns.Print("open the auction house first") return false end
    if Listings.Cancelling() then return false end
    -- (The button is off while a purchase is on its way: CancelAuction needs the click, it cannot wait.)
    if ns.Scanner.Buying() then return false end
    for _, row in ipairs(db().rows) do
        if Listings.Undercut(row) then
            local ok, can = pcall(AH.CanCancelAuction, row.auctionID)
            if ok and can then
                local cost
                if AH.GetCancelCost then
                    local okCost, c = pcall(AH.GetCancelCost, row.auctionID)
                    cost = okCost and c or nil
                end
                Listings.pending = { row = row, t = GetTime(), cost = cost }
                if cost and cost > 0 then ns.Gold.Expect("cancel", -cost, ns.MaterialName(row.itemID), 15) end
                ns.NoteRequest("cancel")
                AH.CancelAuction(row.auctionID)
                ns.Log("listings: cancelling %dx %s at %s each%s", row.qty, ns.MaterialName(row.itemID), ns.Money(row.each),
                    cost and (", cost " .. ns.Money(cost)) or "")
                ns.Fire("SALVAGER_LISTINGS")
                return true
            end
        end
    end
    ns.Print("no undercut listing that can be cancelled")
    return false
end

-- This client sends AUCTION_CANCELED when an auction sells, and nothing when it is cancelled (measured
-- 2026-11-26: every sale came as a cancel; the cancels at 03:15 and 06:28 got no event). So a cancel is known
-- from the list of your auctions: an auction a cancel was asked for (by this addon or any window) that is
-- gone from it, unsold. AUCTION_CANCELED for such an auction counts too, in case a client sends it.
local askedCancel = {}   -- [auctionID] = time a cancel was asked
local CANCEL_ANSWER = 60
if hooksecurefunc and AH and AH.CancelAuction then
    hooksecurefunc(AH, "CancelAuction", function(auctionID)
        if not auctionID then return end
        askedCancel[auctionID] = GetTime()
        -- The answer is the next read of your auctions.
        C_Timer.After(1, function() Listings.Refresh(true) end)
    end)
end

--- An auction a cancel was asked for is gone: book its deposit as lost. `rows` = the list it was in.
local function cancelDone(auctionID, rows)
    local asked = askedCancel[auctionID]
    askedCancel[auctionID] = nil
    if not (asked and GetTime() - asked <= CANCEL_ANSWER) then return false end
    local p = Listings.pending
    local mine = p and p.row.auctionID == auctionID
    for _, r in ipairs(rows) do
        if r.auctionID == auctionID and not r.sold then
            depositLost(auctionID, r.itemID, r.qty, "cancelled", mine and p.cost or nil)
        end
    end
    if mine then
        Listings.pending = nil
        ns.Print("cancelled %dx %s (it comes back by mail)%s", p.row.qty, ns.MaterialName(p.row.itemID),
            (p.cost and p.cost > 0) and (", cost " .. ns.Money(p.cost)) or "")
        ns.Log("listings: cancelled %dx %s", p.row.qty, ns.MaterialName(p.row.itemID))
    end
    return true
end

--- After a read: the auctions a cancel was asked for that are no longer for sale.
function findCancelled(prev, rows)
    local open = {}
    for _, r in ipairs(rows) do if not r.sold then open[r.auctionID] = true end end
    for auctionID in pairs(askedCancel) do
        if not open[auctionID] then cancelDone(auctionID, prev) end
    end
end

ns.On("AUCTION_CANCELED", function(auctionID)
    local rows = db().rows
    if cancelDone(auctionID, rows) then
        for i = #rows, 1, -1 do if rows[i].auctionID == auctionID and not rows[i].sold then table.remove(rows, i) end end
        ns.Fire("SALVAGER_LISTINGS")
    else
        -- Sold, or gone for another reason: the next read of your auctions says which.
        Listings.Refresh()
    end
end)

-- An auction that ran out while the auction house is open.
ns.On("AUCTION_HOUSE_AUCTIONS_EXPIRED", function(auctionID)
    for _, r in ipairs(db().rows) do
        if r.auctionID == auctionID and not r.sold then depositLost(auctionID, r.itemID, r.qty, "expired") end
    end
end)

-- The auction house's one error event: ours only when the last request was a cancel.
ns.On("AUCTION_HOUSE_SHOW_ERROR", function()
    local p = Listings.pending
    if not p or not ns.ErrorIs("cancel") then return end
    Listings.pending = nil
    ns.Print("could not cancel %s", ns.MaterialName(p.row.itemID))
    ns.Log("listings: could not cancel %s", ns.MaterialName(p.row.itemID))
    ns.Fire("SALVAGER_LISTINGS")
end)

-- Your auctions, whoever asked for them.
ns.On("OWNED_AUCTIONS_UPDATED", function()
    local ok, err = pcall(Listings.Read)
    if not ok then ns.Log("ERROR reading your auctions: %s", tostring(err)) end
end)

ns.On("AUCTION_HOUSE_SHOW", function() Listings.Refresh() end)
ns.On("AUCTION_HOUSE_CLOSED", function()
    Listings.checking, Listings.pending, Listings.afterRead = nil, nil, nil
end)

-- 0.3.79 to 0.3.83 booked every sale as a cancel first (see AUCTION_CANCELED above): those "deposit lost"
-- records go, once. (No real cancel was made with those versions.)
ns.On("SALVAGER_READY", function()
    if ns.db.falseCancelsDropped then return end
    ns.db.falseCancelsDropped = true
    local sales, n = ns.db.ledger.sales, 0
    for i = #sales, 1, -1 do
        if sales[i].lost == "cancelled" then
            table.remove(sales, i)
            n = n + 1
        end
    end
    for _, p in ipairs(ns.db.posted or {}) do
        if p.lost == "cancelled" then p.lost = nil end
    end
    if n > 0 then ns.Log("ledger: removed %d lost deposits that were sales, not cancels", n) end
end)

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

local CANCEL_WAIT = 5      -- seconds a cancel may take before it is given up
local MAX_POSTED = 300     -- posts remembered (their unit prices are known for sure)

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

--- A post made through Salvager: its price each is known for sure.
function Listings.NotePost(auctionID, itemID, quantity, each)
    local posted = ns.db.posted
    posted[#posted + 1] = { auctionID = auctionID, itemID = itemID, qty = quantity, each = each, t = time() }
    ns.Util.Cap(posted, MAX_POSTED)
end

local function postedPrice(auctionID)
    for i = #ns.db.posted, 1, -1 do
        if ns.db.posted[i].auctionID == auctionID then return ns.db.posted[i].each end
    end
end

--- Reads your auctions from the game into the saved list.
function Listings.Read()
    local l = db()
    local rows = {}
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
    ns.Fire("SALVAGER_LISTINGS")
end

--- Asks the auction house for your auctions. `now` = ahead of everything else (the player asked).
function Listings.Refresh(now)
    if not ns.Queue.open then return false end
    ns.Queue.Add({ owned = true, once = true, onResult = function() end,
        onFail = function() ns.Log("listings: the auction house did not send your auctions") end }, now)
    return true
end

--- Seconds left for a row now (it was read some time ago). nil when the game gave none.
function Listings.TimeLeft(row)
    if not row.left then return nil end
    return math.max(0, row.left - (time() - (db().t or time())))
end

--- How far a row is undercut: copper each below your price, or nil (not undercut, or not checked).
function Listings.Undercut(row)
    if row.sold or not row.commodity then return nil end
    local low = db().lowest[row.itemID]
    if not (low and low.lo) then return nil end
    if low.lo < row.each then return row.each - low.lo end
    return nil
end

--- "checked" state of a row: nil = not checked, false = nobody else lists it, number = lowest other price.
function Listings.Lowest(row)
    local low = db().lowest[row.itemID]
    if not low then return nil end
    return low.lo or false
end

function Listings.CountUndercut()
    local n = 0
    for _, row in ipairs(db().rows) do if Listings.Undercut(row) then n = n + 1 end end
    return n
end

--- Searches every listed commodity for its lowest price that is not yours.
function Listings.Check()
    if not ns.Queue.open then ns.Print("open the auction house first") return end
    if Listings.checking then return end
    if ns.Prices.scanning then ns.Print("wait for the material scan to finish") return end
    Listings.Refresh(true)
    local ids, seen = {}, {}
    for _, row in ipairs(db().rows) do
        if not row.sold and row.commodity and not seen[row.itemID] then
            seen[row.itemID] = true
            ids[#ids + 1] = row.itemID
        end
    end
    if #ids == 0 then
        ns.Print("nothing listed to check (if you just posted, try again in a moment)")
        return
    end
    Listings.checking = { done = 0, total = #ids }
    ns.Log("listings: checking %d listed materials for undercuts", #ids)
    local function step()
        local c = Listings.checking
        if not c then return end
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

ns.On("AUCTION_CANCELED", function(auctionID)
    local p = Listings.pending
    local rows = db().rows
    for i = #rows, 1, -1 do
        if rows[i].auctionID == auctionID then table.remove(rows, i) end
    end
    if p and p.row.auctionID == auctionID then
        Listings.pending = nil
        ns.Print("cancelled %dx %s (it comes back by mail)%s", p.row.qty, ns.MaterialName(p.row.itemID),
            (p.cost and p.cost > 0) and (", cost " .. ns.Money(p.cost)) or "")
        ns.Log("listings: cancelled %dx %s", p.row.qty, ns.MaterialName(p.row.itemID))
    end
    ns.Fire("SALVAGER_LISTINGS")
end)

ns.On("AUCTION_HOUSE_SHOW_ERROR", function()
    local p = Listings.pending
    if not p then return end
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
    Listings.checking, Listings.pending = nil, nil
end)

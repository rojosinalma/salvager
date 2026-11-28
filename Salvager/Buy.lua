-- Salvager: buying from a price list (the Buy tab of the market window, SDD 128): materials and the Arcane Salvager
-- tab's items. One purchase at a time, never while a gear purchase is on its way (Scanner.Buying), and the scan and
-- every search wait for it (Scanner.HoldReason).
--   Commodities: StartCommoditiesPurchase in the click (it needs one); the auction house answers with its quote
--   (COMMODITY_PRICE_UPDATED); ConfirmCommoditiesPurchase when the quote came within Buy.QUOTE_WAIT and its total is
--   not over the ceiling (the total the last search showed + Buy.CEILING); else CancelCommoditiesPurchase, said.
--   Single auctions (the Blueprint): PlaceBid in the click on the cheapest auction of a current search (SDD 105: a
--   browse after the search, or a search older than Buy.FRESH, and it is searched again first).
-- Books: a material bought enters stock at what it cost ("bought materials", Ledger.BuyMaterial); everything bought
-- goes into the gold journal as auction house money.
local _, ns = ...

local AH = C_AuctionHouse
local Data = ns.Data

local Buy = {}
ns.Buy = Buy

Buy.QUOTE_WAIT = 2        -- seconds the quote may take after the click; a later one is cancelled (FFA's measured 2 s)
Buy.CEILING = 0.05        -- the quote may be this share over the total of the last search; more and it is cancelled
Buy.ANSWER_WAIT = 10      -- seconds for the answer to a confirmed commodity purchase before it is said and let go
Buy.BID_WAIT = 3          -- seconds for the answer to a PlaceBid (as a gear purchase, SDD 105g)
Buy.FRESH = 60            -- seconds an item search is current enough to buy from
Buy.LATE = 60             -- seconds a purchase let go is still booked when its answer comes after all

local pending             -- the purchase on its way: { kind = "commodity" | "item", itemID, qty, expected, ceiling, ... }
local late                -- the last one let go without an answer (its answer may still come)
local searched = {}       -- [itemID] = { at, epoch }: the item search answered last (non-commodities)
local searching = {}      -- [itemID] = true: a click's search is on its way

local function name(id) return ns.MaterialName(id) end
local function changed() ns.Fire("SALVAGER_BUY") end

--- Is a purchase of this module on its way? (Scanner.HoldReason holds everything else for it.)
function Buy.Busy() return pending ~= nil end

--- The purchase on its way (a copy of its fields), or nil.
function Buy.Pending()
    if not pending then return nil end
    return { kind = pending.kind, itemID = pending.itemID, qty = pending.qty, state = pending.state,
        expected = pending.expected, ceiling = pending.ceiling }
end

--- The highest total a commodity purchase may be confirmed at, for an expected total.
function Buy.Ceiling(expected) return math.floor(expected * (1 + Buy.CEILING) + 0.5) end

--- Is an item search of a non-commodity current enough to buy from (no browse since, younger than Buy.FRESH)?
function Buy.Current(itemID)
    local s = searched[itemID]
    return s ~= nil and s.epoch >= (ns.Scanner.browseEpoch or 0) and GetTime() - s.at <= Buy.FRESH
end

--- What `qty` units (a commodity) or one auction (a non-commodity) would cost now, from the client's last search.
--- @return table|nil { commodity, qty (units that can be bought, at most `qty`), short (fewer listed than asked),
---   total, each (average), top (the highest unit price in it), auctionID (non-commodity) }
function Buy.Plan(itemID, qty)
    qty = math.max(1, math.floor(qty or 1))
    if not ns.Prices.IsCommodity(itemID) then
        local e = ns.Prices.ReadItem(itemID)
        if not e then return nil end
        return { commodity = false, qty = e.qty, total = e.buyout, each = e.p, top = e.p, auctionID = e.auctionID }
    end
    local need, total, got, top = qty, 0, 0, nil
    for i = 1, (AH.GetNumCommoditySearchResults(itemID) or 0) do
        local r = AH.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice and r.unitPrice > 0 then
            local n = math.min((r.quantity or 0) - (r.numOwnerItems or 0), need)
            if n > 0 then
                total, got, need, top = total + n * r.unitPrice, got + n, need - n, r.unitPrice
                if need <= 0 then break end
            end
        end
    end
    if got == 0 then return nil end
    return { commodity = true, qty = got, short = got < qty, total = total, each = math.floor(total / got + 0.5), top = top }
end

--- Can a Buy click buy `qty` of this item now? Off while anything else is on its way or the auction house is busy
--- (the one-click rule, SDD 105m): on again the moment it is ready.
--- @return boolean ok, string|nil why not (a tooltip line), table|nil the plan (Buy.Plan)
function Buy.Can(itemID, qty)
    local x = Data.SALVAGER_ITEM_BY_ID[itemID]
    if x and x.auction == false then
        return false, string.format("%s binds when picked up: it is not sold at the auction house.", x.name)
    end
    if not ns.Queue.open then return false, "Open the auction house first." end
    if pending then
        return false, string.format("Your purchase of %s is on its way: Buy is on again when it is answered.",
            name(pending.itemID))
    end
    if searching[itemID] then return false, string.format("Searching %s again first: Buy is on in a moment.", name(itemID)) end
    if ns.Scanner.Buying() then return false, "A purchase is on its way: Buy is on again when it is answered." end
    if not ns.Scanner.Ready() then
        return false, "The auction house is answering a request: Buy is on again the moment it is ready."
    end
    local plan = Buy.Plan(itemID, qty)
    if not plan then return false, string.format("No %s listed in the last search: Scan first.", name(itemID)) end
    if plan.short then
        return false, string.format("Only %d %s listed by others in the last search.", plan.qty, name(itemID)), plan
    end
    if GetMoney() < plan.total then return false, "Not enough gold.", plan end
    return true, nil, plan
end

--- Searches an item again when its last search is not current (the Buy tab calls it when it shows the item or the
--- mouse is on Buy), so the click that follows buys at once. `forBuy` = for a click: past every hold.
function Buy.Prefetch(itemID, forBuy)
    if not ns.Queue.open or searching[itemID] then return end
    local commodity = ns.Prices.IsCommodity(itemID)
    if commodity and (AH.GetNumCommoditySearchResults(itemID) or 0) > 0 and not forBuy then return end
    if not commodity and Buy.Current(itemID) then return end
    searching[itemID] = true
    ns.Prices.Refresh(itemID, function(ok)
        searching[itemID] = nil
        if ok and not commodity then searched[itemID] = { at = GetTime(), epoch = ns.Scanner.browseEpoch or 0 } end
        if forBuy then
            ns.Log(ok and "INFO" or "WARN", "buy", string.format("%s searched again%s", name(itemID),
                ok and ", Buy is on" or ", no answer"), { item = itemID, answered = ok and true or false })
            if not ok then ns.Print("the search of %s got no answer: click Buy again", name(itemID)) end
        end
        changed()
    end, forBuy)
end

local function finish(how)
    if pending then
        pending.how = how
        if how == "no answer" then late = pending end
    end
    pending = nil
    changed()
end

--- Books a purchase that went through: a material into stock at its cost, and a Log and chat line.
local function book(p)
    local total = p.paid or p.expected
    local each = math.floor(total / math.max(1, p.qty) + 0.5)
    if Data.MATERIAL_BY_ID[p.itemID] then
        ns.Ledger.BuyMaterial(ns.db.ledger, p.itemID, p.qty, total, time())
        ns.Fire("SALVAGER_LEDGER")
    end
    local material = Data.MATERIAL_BY_ID[p.itemID] ~= nil
    ns.Log("INFO", "buy", string.format("bought %dx %s for %s (%s each)%s", p.qty, name(p.itemID), ns.Money(total),
        ns.Money(each), material and ", into stock as bought materials" or ""), { item = p.itemID, qty = p.qty,
        paid = total, each = each, auction = p.auctionID, material = material or nil })
    ns.Print("bought %dx %s for %s", p.qty, name(p.itemID), ns.Money(total))
end

--- A Buy click: buys `qty` units of a commodity (start now, confirm on the quote), or the cheapest auction of a
--- non-commodity. Must run from the click (the server needs a hardware event).
--- @return boolean sent, string|nil why not
function Buy.Click(itemID, qty)
    local ok, why, plan = Buy.Can(itemID, qty)
    ns.Log("INFO", "buy", string.format("Buy click on %s x%d: %s", name(itemID), qty or 1,
        ok and "sent" or tostring(why)), { item = itemID, qty = qty or 1, sent = ok and true or false })
    if not ok then return false, why end
    if not plan.commodity then
        if not Buy.Current(itemID) then
            ns.Print("%s: searching it again first (its last search is not current); Buy is on in a moment", name(itemID))
            Buy.Prefetch(itemID, true)
            changed()
            return false, "searching"
        end
        pending = { kind = "item", itemID = itemID, qty = plan.qty, expected = plan.total, auctionID = plan.auctionID,
            state = "bid", sentAt = GetTime() }
        ns.Gold.Expect("auction", -plan.total, name(itemID), 30)
        ns.NoteRequest("buy")
        AH.PlaceBid(plan.auctionID, plan.total)
        changed()
        return true
    end
    pending = { kind = "commodity", itemID = itemID, qty = plan.qty, expected = plan.total,
        ceiling = Buy.Ceiling(plan.total), state = "quote", sentAt = GetTime() }
    ns.NoteRequest("buycommodity")
    AH.StartCommoditiesPurchase(itemID, plan.qty)
    changed()
    return true
end

local function cancel(why, print_)
    local p = pending
    pcall(AH.CancelCommoditiesPurchase)
    ns.Log("WARN", "buy", string.format("purchase of %dx %s cancelled: %s", p.qty, name(p.itemID), why),
        { item = p.itemID, qty = p.qty, expected = p.expected, ceiling = p.ceiling })
    ns.Print("purchase of %dx %s cancelled: %s", p.qty, name(p.itemID), print_ or why)
    finish("cancelled")
end

ns.On("COMMODITY_PRICE_UPDATED", function(unit, total)
    local p = pending
    if not p or p.kind ~= "commodity" or p.state ~= "quote" then return end
    local waited = GetTime() - p.sentAt
    if waited > Buy.QUOTE_WAIT then
        return cancel(string.format("the price came after %.1fs (at most %ds)", waited, Buy.QUOTE_WAIT))
    end
    if not total or total > p.ceiling then
        return cancel(string.format("the price is %s, over %s (%s from the last search + %d%%)", ns.Money(total or 0),
            ns.Money(p.ceiling), ns.Money(p.expected), Buy.CEILING * 100))
    end
    if GetMoney() < total then return cancel("not enough gold for " .. ns.Money(total)) end
    p.state, p.paid, p.unit, p.confirmedAt = "confirm", total, unit, GetTime()
    ns.Gold.Expect("auction", -total, name(p.itemID), 30)
    ns.NoteRequest("buycommodity")
    AH.ConfirmCommoditiesPurchase(p.itemID, p.qty)
    ns.Log("INFO", "buy", string.format("purchase of %dx %s: price %s (%s each) in %.1fs, confirmed", p.qty,
        name(p.itemID), ns.Money(total), ns.Money(unit or 0), waited), { item = p.itemID, qty = p.qty, total = total,
        each = unit, expected = p.expected, ceiling = p.ceiling, seconds = math.floor(waited * 10 + 0.5) / 10 })
    changed()
end)

ns.On("COMMODITY_PRICE_UNAVAILABLE", function()
    if pending and pending.kind == "commodity" and pending.state == "quote" then
        cancel("the auction house has no price for it now", "nothing listed for it now")
    end
end)

local function succeeded()
    local p = pending
    if p and p.kind == "commodity" and p.state == "confirm" then
        book(p)
        finish("bought")
    elseif late and late.kind == "commodity" and late.confirmedAt and GetTime() - late.confirmedAt <= Buy.LATE then
        ns.Log("WARN", "buy", string.format("purchase of %dx %s: its answer came late, booked", late.qty,
            name(late.itemID)), { item = late.itemID, qty = late.qty })
        book(late)
        late = nil
        changed()
    end
end
ns.On("COMMODITY_PURCHASE_SUCCEEDED", succeeded)

ns.On("COMMODITY_PURCHASE_FAILED", function()
    local p = pending
    if not p or p.kind ~= "commodity" then return end
    ns.Log("ERROR", "buy", string.format("purchase of %dx %s failed (the auction house said so)", p.qty,
        name(p.itemID)), { item = p.itemID, qty = p.qty })
    ns.Print("could not buy %dx %s", p.qty, name(p.itemID))
    finish("failed")
end)

ns.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
    local p = pending
    if p and p.kind == "item" and p.auctionID == auctionID then
        book(p)
        searched[p.itemID] = nil   -- (the auction is gone: the next click searches first)
        finish("bought")
    elseif late and late.kind == "item" and late.auctionID == auctionID and GetTime() - late.sentAt <= Buy.LATE then
        ns.Log("WARN", "buy", string.format("purchase of %s: its answer came late, booked", name(late.itemID)),
            { item = late.itemID, auction = late.auctionID })
        book(late)
        late = nil
        changed()
    end
end)

ns.On("AUCTION_HOUSE_SHOW_ERROR", function()
    local p = pending
    if not p then return end
    if p.kind == "item" and ns.ErrorIs("buy") then
        ns.Log("ERROR", "buy", string.format("could not buy %s for %s", name(p.itemID), ns.Money(p.expected)),
            { item = p.itemID, auction = p.auctionID, buyout = p.expected })
        ns.Print("could not buy %s (sold or changed)", name(p.itemID))
        searched[p.itemID] = nil
        finish("failed")
    elseif p.kind == "commodity" and ns.ErrorIs("buycommodity") then
        ns.Log("ERROR", "buy", string.format("purchase of %dx %s: the auction house reported an error", p.qty,
            name(p.itemID)), { item = p.itemID, qty = p.qty })
        ns.Print("could not buy %dx %s", p.qty, name(p.itemID))
        if p.state == "quote" then pcall(AH.CancelCommoditiesPurchase) end
        finish("failed")
    end
end)

-- The clocks: a quote that does not come in time is cancelled; a purchase with no answer is said and let go.
ns.OnTick(function()
    local p = pending
    if not p then return end
    local now = GetTime()
    if p.state == "quote" and now - p.sentAt > Buy.QUOTE_WAIT then
        cancel(string.format("no price from the auction house in %ds", Buy.QUOTE_WAIT))
    elseif p.state == "confirm" and now - p.confirmedAt > Buy.ANSWER_WAIT then
        ns.Log("WARN", "buy", string.format("purchase of %dx %s got no answer in %ds", p.qty, name(p.itemID),
            Buy.ANSWER_WAIT), { item = p.itemID, qty = p.qty, seconds = Buy.ANSWER_WAIT })
        ns.Print("no answer yet for %dx %s: see your bags and mail before you buy again", p.qty, name(p.itemID))
        finish("no answer")
    elseif p.state == "bid" and now - p.sentAt > Buy.BID_WAIT then
        ns.Log("WARN", "buy", string.format("purchase of %s got no answer in %ds", name(p.itemID), Buy.BID_WAIT),
            { item = p.itemID, auction = p.auctionID, seconds = Buy.BID_WAIT })
        ns.Print("no answer yet for %s: click Buy again if it is still listed", name(p.itemID))
        searched[p.itemID] = nil
        finish("no answer")
    end
end)

-- An item search answered: its auctions are current (a non-commodity can be bought from it).
ns.On("ITEM_SEARCH_RESULTS_UPDATED", function(key)
    local id = type(key) == "table" and key.itemID
    if id and Data.SALVAGER_ITEM_BY_ID[id] and not ns.Prices.IsCommodity(id) then
        searched[id] = { at = GetTime(), epoch = ns.Scanner.browseEpoch or 0 }
    end
end)

ns.On("AUCTION_HOUSE_CLOSED", function()
    if pending and pending.kind == "commodity" and pending.state == "quote" then pcall(AH.CancelCommoditiesPurchase) end
    pending, late = nil, nil
    wipe(searched)
    wipe(searching)
end)

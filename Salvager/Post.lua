-- Salvager: posting a material on the auction house from the Materials tab.
-- Post asks the auction house for the material's price right now, then opens a small
-- window with the price (1 copper under the lowest listing), the quantity in your bags,
-- your break-even and what the sale brings. Posting itself needs your click.
local _, ns = ...

local AH = C_AuctionHouse
local Ledger, Data, W = ns.Ledger, ns.Data, ns.Widgets

local Post = { loading = {} }
ns.Post = Post

local DURATION_LABELS = { "Short", "Medium", "Long" }

------------------------------------------------------------------ logic

--- How many of a material are in the bags (not the bank).
function Post.BagCount(itemID)
    local ok, n = pcall(ns.GetItemCount, itemID)
    return ok and n or 0
end

--- The first bag slot that holds the item, as an ItemLocation.
function Post.FindLocation(itemID)
    local last = _G.NUM_TOTAL_EQUIPPED_BAG_SLOTS or _G.NUM_BAG_SLOTS or 4
    for bag = 0, last do
        for slot = 1, (C_Container.GetContainerNumSlots(bag) or 0) do
            if C_Container.GetContainerItemID(bag, slot) == itemID then
                return ItemLocation:CreateFromBagAndSlot(bag, slot)
            end
        end
    end
end

--- The price Post suggests for one unit, and what it rests on.
--- @return table { price, lowest, breakEven, below }
---   lowest = the cheapest listing that is not yours (nil when none is known)
---   below = the suggested price is under your break-even
function Post.Suggest(itemID)
    local e = ns.db.prices[itemID]
    local lowest = e and e.lo
    local breakEven = Ledger.BreakEven(ns.db.ledger, itemID, ns.Cut())
    local price
    if lowest then
        price = math.max(1, lowest - 1)
    else
        price = (e and (e.p or e.last)) or breakEven or 0
    end
    return { price = price, lowest = lowest, breakEven = breakEven, below = breakEven ~= nil and price < breakEven }
end

--- The other sellers' listings of a material, as the client holds them now (after a search), cheapest
--- first. The game shows the auctions of one price as one line, so a "listing" here is a price line.
--- @return table { rows = { { price, qty, mine (your own units at that price) }, ... }, units, listings,
---                 partial (the game holds only the first results) }
function Post.Market(itemID)
    local out = { rows = {}, units = 0, listings = 0, partial = false }
    for i = 1, (AH.GetNumCommoditySearchResults(itemID) or 0) do
        local r = AH.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice and r.unitPrice > 0 then
            local mine = r.numOwnerItems or 0
            local qty = (r.quantity or 0) - mine
            if qty > 0 then
                out.rows[#out.rows + 1] = { price = r.unitPrice, qty = qty, mine = mine }
                out.units = out.units + qty
                out.listings = out.listings + 1
            end
        end
    end
    table.sort(out.rows, function(a, b) return a.price < b.price end)
    if AH.HasFullCommoditySearchResults then
        local ok, full = pcall(AH.HasFullCommoditySearchResults, itemID)
        out.partial = ok and full == false
    end
    return out
end

--- The market against a price and a break-even: what is ahead of you, and what is under your cost.
--- @return table rows for the list (with a line for your price and one for your break-even), table counts
---   counts = { ahead, aheadListings (units and listings at or under your price: they sell before you),
---              under, underListings (units and listings under your break-even) }
function Post.MarketRows(market, price, breakEven)
    local rows, c = {}, { ahead = 0, aheadListings = 0, under = 0, underListings = 0 }
    local GREY, GOLD, RED = "|cff808080", "|cffffd100", "|cffff6060"
    local total, didPrice, didEven = 0, false, false
    local function evenMark(nextPrice)
        if breakEven and not didEven and (not nextPrice or nextPrice >= breakEven) then
            didEven = true
            rows[#rows + 1] = { group = true, cells = { GOLD .. "Your break-even|r", ns.Money(breakEven), "" } }
        end
    end
    local function priceMark(nextPrice)
        if price > 0 and not didPrice and (not nextPrice or nextPrice > price) then
            didPrice = true
            rows[#rows + 1] = { group = true, cells = { GOLD .. "Your price|r", ns.Money(price), "" } }
        end
    end
    -- The two lines go in before the first listing that is dearer, the lower of the two first.
    local function marks(nextPrice)
        if breakEven and breakEven <= price then
            evenMark(nextPrice)
            priceMark(nextPrice)
        else
            priceMark(nextPrice)
            evenMark(nextPrice)
        end
    end
    for _, r in ipairs(market.rows) do
        marks(r.price)
        total = total + r.qty
        local ahead = price > 0 and r.price <= price
        local under = breakEven ~= nil and r.price < breakEven
        if ahead then c.ahead, c.aheadListings = c.ahead + r.qty, c.aheadListings + 1 end
        if under then c.under, c.underListings = c.under + r.qty, c.underListings + 1 end
        local color = under and RED or (ahead and "" or GREY)
        rows[#rows + 1] = { cells = {
            color .. ns.Money(r.price) .. (color ~= "" and "|r" or ""),
            color .. r.qty .. (color ~= "" and "|r" or "") .. (r.mine > 0 and (GREY .. " +" .. r.mine .. " yours|r") or ""),
            color .. total .. (color ~= "" and "|r" or "") } }
    end
    marks(nil)
    if #market.rows == 0 then
        rows[#rows + 1] = { cells = { GREY .. "Nobody else lists it.|r", "", "" } }
    end
    return rows, c
end

--- An essence has two forms: three lesser combine into one greater, and one greater splits into three
--- lesser (a right-click in the bags, free). Which form sells for more now?
--- @return table|nil { other (item ID of the other form), lesser (this one is the lesser form),
---   mine (price each of this form), same (what one of these is worth in the other form: a third of a
---   greater, or three lesser), gain (same - mine, per one of these), better (the other form pays more) }
---   nil when the material is not an essence or a price is missing.
function Post.Convert(itemID)
    local pair = Data.ESSENCE_PAIR[itemID]
    if not pair then return nil end
    local mine, other = Post.Suggest(itemID).price, Post.Suggest(pair.other).price
    if not (ns.db.prices[itemID] and ns.db.prices[pair.other]) or mine <= 0 or other <= 0 then return nil end
    local same = other * pair.factor
    return { other = pair.other, lesser = pair.factor < 1, mine = mine, same = same, gain = same - mine,
        better = same - mine >= 1 }
end

--- The line of the Post window that says it.
function Post.ConvertText(itemID, quantity)
    local c = Post.Convert(itemID)
    if not c then return "" end
    local otherName = ns.MaterialName(c.other)
    if not c.better then
        return "|cff808080This form pays more than " .. otherName .. " now: keep it as it is.|r"
    end
    local pct = math.floor(c.gain / c.mine * 100 + 0.5)
    if c.lesser then
        local n = math.floor(quantity / 3)
        return string.format("|cff40ff40Better: combine 3 into 1 %s.|r One sells for %s, three of these for %s "
            .. "(+%d%%).%s", otherName, ns.Money(c.same * 3), ns.Money(c.mine * 3), pct,
            n > 0 and string.format(" Your %d make %d.", quantity, n) or " You need 3.")
    end
    return string.format("|cff40ff40Better: split each into 3 %s.|r Three sell for %s, one of these for %s (+%d%%).",
        otherName, ns.Money(c.same), ns.Money(c.mine), pct)
end

--- What a post brings: after the cut, and against your cost.
--- @return table { gross, net, cost (nil when unknown), profit (nil when unknown), deposit }
function Post.Outcome(itemID, quantity, unitPrice, duration)
    local gross = quantity * unitPrice
    local net = math.floor(gross * (1 - ns.Cut()) + 0.5)
    local avg = Ledger.AvgCost(ns.db.ledger, itemID)
    local cost = avg and math.floor(avg * quantity + 0.5) or nil
    local deposit
    if AH.CalculateCommodityDeposit then
        local ok, d = pcall(AH.CalculateCommodityDeposit, itemID, duration, quantity)
        if ok then deposit = d end
    end
    return { gross = gross, net = net, cost = cost, profit = cost and (net - cost) or nil, deposit = deposit }
end

--- Sends the post. Must run from a click. Returns true when the auction house took it,
--- "confirm" when it wants a second click (its low-price warning), or false and why.
function Post.Send(itemID, quantity, unitPrice, duration, confirmed)
    if not ns.Queue.open then return false, "the auction house is closed" end
    if quantity < 1 or unitPrice < 1 then return false, "quantity and price must be at least 1" end
    local loc = Post.FindLocation(itemID)
    if not loc then return false, "none in your bags" end
    local fn = confirmed and AH.ConfirmPostCommodity or AH.PostCommodity
    local ok, needsConfirm = pcall(fn, loc, duration, quantity, unitPrice)
    if not ok then
        ns.Log("ERROR posting %s: %s", ns.MaterialName(itemID), tostring(needsConfirm))
        return false, tostring(needsConfirm)
    end
    Post.pending = { itemID = itemID, quantity = quantity, unitPrice = unitPrice, t = GetTime() }
    ns.Log("post sent: %dx %s at %s each, duration %d%s", quantity, ns.MaterialName(itemID), ns.Money(unitPrice),
        duration, confirmed and " (confirmed)" or "")
    if not confirmed and needsConfirm then return "confirm" end
    return true
end

ns.On("AUCTION_HOUSE_AUCTION_CREATED", function(auctionID)
    local p = Post.pending
    if not p then return end
    Post.pending = nil
    if auctionID then ns.Listings.NotePost(auctionID, p.itemID, p.quantity, p.unitPrice) end
    ns.Listings.Refresh()
    ns.Print("posted %dx %s at %s each", p.quantity, ns.MaterialName(p.itemID), ns.Money(p.unitPrice))
    ns.Log("posted %dx %s at %s each", p.quantity, ns.MaterialName(p.itemID), ns.Money(p.unitPrice))
    ns.Fire("SALVAGER_LEDGER")
end)

local function postFailed(why)
    local p = Post.pending
    if not p or GetTime() - p.t > 10 then return end
    Post.pending = nil
    ns.Print("could not post %s (%s)", ns.MaterialName(p.itemID), why)
    ns.Log("post failed: %s (%s)", ns.MaterialName(p.itemID), why)
end
ns.On("AUCTION_HOUSE_POST_ERROR", function() postFailed("the auction house refused it") end)
ns.On("AUCTION_HOUSE_SHOW_ERROR", function(err) postFailed("auction house error " .. tostring(err)) end)

------------------------------------------------------------------ the window

local d    -- the dialog frame, built on first use

local function durationLabels()
    return {
        _G.AUCTION_DURATION_ONE or DURATION_LABELS[1], _G.AUCTION_DURATION_TWO or DURATION_LABELS[2],
        _G.AUCTION_DURATION_THREE or DURATION_LABELS[3],
    }
end

local function quantityOf()
    return math.floor(tonumber(d.qty:GetText()) or 0)
end

--- Fills the lines under the inputs from what is typed now.
local function recalc()
    if not d or not d.itemID then return end
    local id, bags = d.itemID, Post.BagCount(d.itemID)
    local qty, price = quantityOf(), d.price:Get()
    local s = Post.Suggest(id)
    local o = Post.Outcome(id, qty, price, ns.db.settings.postDuration)
    d.bags:SetText("of " .. bags .. " in your bags")
    d.lines[1]:SetText("Lowest listing now: " .. (s.lowest and ns.Money(s.lowest) or "none listed")
        .. (d.stale and "  |cffff8040(price not refreshed)|r" or ""))
    d.lines[2]:SetText("Your break-even: " .. (s.breakEven and ns.Money(s.breakEven) or "|cff808080cost not known|r"))
    d.lines[3]:SetText("You get after the 5% cut: " .. ns.Money(o.net))
    if o.profit then
        d.lines[4]:SetText("Profit: " .. (o.profit >= 0 and "|cff40ff40" or "|cffff4040") .. ns.Money(o.profit) .. "|r")
    else
        d.lines[4]:SetText("Profit: |cff808080cost not known|r")
    end
    d.lines[5]:SetText("Deposit: " .. (o.deposit and ns.Money(o.deposit) or "-") .. " (returned when it sells)")
    d.convert:SetText(Post.ConvertText(id, qty))
    if s.breakEven and price < s.breakEven then
        d.warn:SetText("|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:16|t Below your break-even: you lose "
            .. ns.Money(s.breakEven - price) .. " on each one.")
    else
        d.warn:SetText("")
    end
    -- The other sellers: how much is listed, how much of it sells before you, how much is under your cost.
    local market = d.market or { rows = {}, units = 0, listings = 0 }
    local rows, c = Post.MarketRows(market, price, s.breakEven)
    d.marketLines[1]:SetText(string.format("|cffffd100Others list|r %d units in %d listings%s", market.units,
        market.listings, market.partial and " |cff808080(the first results only)|r" or ""))
    d.marketLines[2]:SetText(string.format("|cffffd100Ahead of your price|r %d units in %d%s", c.ahead, c.aheadListings,
        s.breakEven and string.format("    |cffffd100Under your break-even|r %d units in %d", c.under, c.underListings)
            or ""))
    d.list:SetSource(#rows, function(i) return rows[i] end)
    d.list:Refresh()
    d.toEven:SetEnabled(s.breakEven ~= nil)
    d.toLowest:SetEnabled(s.lowest ~= nil)
    d.post:SetEnabled(ns.Queue.open and qty >= 1 and qty <= bags and price >= 1)
    d.post:SetText(d.confirm and "Confirm" or "Post")
end

local function build()
    -- A window of its own: drag it where you want it, and it opens there the next time.
    d = W.Window("SalvagerPostFrame", "Post on the auction house", "post", 760, 370, 760, 370, true)
    d:SetFrameStrata("DIALOG")

    d.icon = d:CreateTexture(nil, "ARTWORK")
    d.icon:SetSize(28, 28)
    d.icon:SetPoint("TOPLEFT", d, "TOPLEFT", 16, -34)
    d.name = W.Label(d, "", "GameFontNormalLarge")
    d.name:SetPoint("LEFT", d.icon, "RIGHT", 8, 0)

    local qLabel = W.Label(d, "Quantity")
    qLabel:SetPoint("TOPLEFT", d, "TOPLEFT", 16, -76)
    d.qty = W.Edit(d, 56, true)
    d.qty:SetJustifyH("RIGHT")
    d.qty:SetTextInsets(2, 4, 0, 0)
    d.qty:SetPoint("LEFT", qLabel, "LEFT", 80, 0)
    d.qty:SetScript("OnTextChanged", function(_, user) if user then d.confirm = nil recalc() end end)
    d.qty:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    d.bags = W.Label(d, "", "GameFontHighlightSmall")
    d.bags:SetPoint("LEFT", d.qty, "RIGHT", 10, 0)

    local pLabel = W.Label(d, "Price each")
    pLabel:SetPoint("TOPLEFT", qLabel, "BOTTOMLEFT", 0, -16)
    d.price = W.Money(d, function() recalc() end)
    d.price:SetPoint("LEFT", pLabel, "LEFT", 74, 0)
    d.price.onTyping = function() d.confirm = nil recalc() end

    local dLabel = W.Label(d, "Duration")
    dLabel:SetPoint("TOPLEFT", pLabel, "BOTTOMLEFT", 0, -16)
    local labels = durationLabels()
    d.duration = W.Choice(d, { { 1, labels[1] }, { 2, labels[2] }, { 3, labels[3] } }, function(v)
        ns.db.settings.postDuration = v
        d.confirm = nil
        recalc()
    end)
    d.duration:SetPoint("LEFT", dLabel, "LEFT", 76, 0)

    d.lines = {}
    for i = 1, 5 do
        local l = W.Label(d, "", "GameFontHighlightSmall")
        l:SetPoint("TOPLEFT", dLabel, "BOTTOMLEFT", 0, -14 - (i - 1) * 16)
        d.lines[i] = l
    end
    -- An essence: is its other form (three lesser = one greater) worth more?
    d.convert = W.Label(d, "", "GameFontHighlightSmall")
    d.convert:SetPoint("TOPLEFT", d.lines[5], "BOTTOMLEFT", 0, -8)
    d.convert:SetWidth(350)
    d.convert:SetJustifyH("LEFT")
    d.warn = W.Label(d, "", "GameFontHighlightSmall")
    d.warn:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 16, 44)
    d.warn:SetTextColor(1, 0.3, 0.3)
    d.warn:SetWidth(350)
    d.warn:SetJustifyH("LEFT")

    -- On the right: the other sellers' listings, cheapest first, with your price and your break-even
    -- in their place among them.
    d.marketLines = {}
    for i = 1, 2 do
        local l = W.Label(d, "", "GameFontHighlightSmall")
        l:SetPoint("TOPLEFT", d, "TOPLEFT", 384, -16 - i * 16)
        d.marketLines[i] = l
    end
    d.list = W.List(d, { rowHeight = 20 })
    d.list:SetColumns({
        { "Price each", 120, help = { "Price each", "The other sellers' listings, cheapest first. The game shows the "
            .. "auctions of one price as one line. Red = under your break-even. Grey = dearer than your price." } },
        { "Units", 110, "CENTER" },
        { "Units up to here", 110, "CENTER", help = { "Units up to here", "How many units are listed at this price or "
            .. "cheaper. The number on the last line above \"Your price\" is what must sell before yours does." } },
    })
    d.list:SetPoint("TOPLEFT", d, "TOPLEFT", 382, -70)
    d.list:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -14, 44)
    d.toLowest = W.Button(d, "Undercut lowest", 120, function()
        local s = Post.Suggest(d.itemID)
        if s.lowest then d.price:Set(math.max(1, s.lowest - 1)) d.confirm = nil recalc() end
    end, "Sets the price to 1 copper under the cheapest listing: yours sells first.")
    d.toLowest:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 382, 12)
    d.toEven = W.Button(d, "Break-even", 100, function()
        local s = Post.Suggest(d.itemID)
        if s.breakEven then d.price:Set(s.breakEven) d.confirm = nil recalc() end
    end, "Sets the price to your break-even: no loss, but everything cheaper sells before yours.")
    d.toEven:SetPoint("LEFT", d.toLowest, "RIGHT", 6, 0)

    d.post = W.Button(d, "Post", 100, function()
        local result, why = Post.Send(d.itemID, quantityOf(), d.price:Get(), ns.db.settings.postDuration, d.confirm)
        if result == "confirm" then
            d.confirm = true
            ns.Print("the auction house asks you to confirm this price: click Confirm")
            recalc()
        elseif result then
            d:Hide()
        else
            ns.Print("could not post: %s", tostring(why))
        end
    end)
    d.post:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -14, 12)
    local cancel = W.Button(d, "Cancel", 90, function() d:Hide() end)
    cancel:SetPoint("RIGHT", d.post, "LEFT", -6, 0)
    d:Hide()
end

local function show(itemID, stale)
    if not d then build() end
    local s = Post.Suggest(itemID)
    d.itemID, d.stale, d.confirm = itemID, stale, nil
    d.market = Post.Market(itemID)
    d.icon:SetTexture(W.IconOf(itemID))
    d.name:SetText(ns.MaterialName(itemID))
    d.qty:SetText(tostring(Post.BagCount(itemID)))
    d.price:Set(s.price)
    d.duration:Set(ns.db.settings.postDuration)
    d:Show()
    recalc()
end

--- The Post button of a material: gets its price now, then opens the window.
function Post.Open(itemID)
    if not Data.MATERIAL_BY_ID[itemID] then return end
    if not ns.Queue.open then ns.Print("open the auction house first") return end
    if Post.BagCount(itemID) < 1 then ns.Print("no %s in your bags", ns.MaterialName(itemID)) return end
    if Post.loading[itemID] then return end
    Post.loading[itemID] = true
    ns.Log("post: getting the price of %s", ns.MaterialName(itemID))
    ns.Fire("SALVAGER_LEDGER")
    ns.Prices.Refresh(itemID, function(ok)
        Post.loading[itemID] = nil
        if not ok then ns.Log("post: no fresh price for %s, using the last one", ns.MaterialName(itemID)) end
        show(itemID, not ok)
        ns.Fire("SALVAGER_LEDGER")
        -- An essence: get the price of its other form too, for the "combine or split" line.
        local pair = Data.ESSENCE_PAIR[itemID]
        if pair then
            ns.Prices.Refresh(pair.other, function()
                if d and d:IsShown() and d.itemID == itemID then recalc() end
            end)
        end
    end)
end

ns.On("AUCTION_HOUSE_CLOSED", function()
    wipe(Post.loading)
    if d then d:Hide() end
end)

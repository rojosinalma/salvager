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
local PENDING_WAIT = 10   -- seconds a post may take before it is given up

-- A listing much cheaper than the market and too small to matter is not followed down:
-- under THIN_PRICE of the average of the cheapest N units, with fewer than THIN_SHARE of N units.
Post.THIN_PRICE = 0.7
Post.THIN_SHARE = 0.1

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

--- The first listing with real volume: listings far under the average of the cheapest N units, with
--- only a few units, are skipped (one cheap unit should not pull the price down).
--- @param rows table  Post.Market(...).rows, cheapest first
--- @return table|nil the listing to undercut, table the listings skipped
function Post.Floor(rows, n)
    n = n or ns.db.settings.priceUnits or 20
    local units, sum = 0, 0
    for _, r in ipairs(rows) do
        local take = math.min(r.qty, n - units)
        units, sum = units + take, sum + take * r.price
        if units >= n then break end
    end
    if units == 0 then return nil, {} end
    local avg, skipped = sum / units, {}
    for _, r in ipairs(rows) do
        if r.price >= Post.THIN_PRICE * avg or r.qty >= Post.THIN_SHARE * n then return r, skipped end
        skipped[#skipped + 1] = r
    end
    return nil, skipped
end

--- The price Post suggests for one unit, and what it rests on.
--- @return table { price, lowest, breakEven, below, skipped }
---   lowest = the cheapest listing that is not yours with real volume (nil when none is known)
---   skipped = the cheaper listings left out (Post.Floor), when the client holds the search
---   below = the suggested price is under your break-even
function Post.Suggest(itemID)
    local e = ns.db.prices[itemID]
    local lowest = e and e.lo
    local skipped
    -- When the client holds the search the lowest price came from, its thin outliers are skipped.
    local rows = Post.Market(itemID).rows
    if lowest and rows[1] and rows[1].price == lowest then
        local floor, left = Post.Floor(rows)
        if floor and #left > 0 then lowest, skipped = floor.price, left end
    end
    local breakEven = Ledger.BreakEven(ns.db.ledger, itemID, ns.Cut())
    local price
    if lowest then
        price = math.max(1, lowest - 1)
    else
        price = (e and (e.p or e.last)) or breakEven or 0
    end
    return { price = price, lowest = lowest, breakEven = breakEven, below = breakEven ~= nil and price < breakEven,
        skipped = skipped }
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
            rows[#rows + 1] = { group = true, pick = breakEven,
                cells = { GOLD .. "Your break-even|r", ns.Money(breakEven), "" } }
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
        -- A listing at exactly your price or your break-even carries that mark itself, on its own line.
        local tag = ""
        if price > 0 and r.price == price then didPrice, tag = true, tag .. GOLD .. "  Your price|r" end
        if breakEven and r.price == breakEven then didEven, tag = true, tag .. GOLD .. "  Your break-even|r" end
        marks(r.price)
        total = total + r.qty
        local ahead = price > 0 and r.price <= price
        local under = breakEven ~= nil and r.price < breakEven
        if ahead then c.ahead, c.aheadListings = c.ahead + r.qty, c.aheadListings + 1 end
        if under then c.under, c.underListings = c.under + r.qty, c.underListings + 1 end
        local color = under and RED or (ahead and "" or GREY)
        -- (pick = the price a click on the line sets: exactly the line's price.)
        rows[#rows + 1] = { pick = r.price, group = tag ~= "", cells = {
            color .. ns.Money(r.price) .. (color ~= "" and "|r" or "") .. tag,
            color .. r.qty .. (color ~= "" and "|r" or "") .. (r.mine > 0 and (GREY .. " +" .. r.mine .. " yours|r") or ""),
            color .. total .. (color ~= "" and "|r" or "") } }
    end
    marks(nil)
    if #market.rows == 0 then
        rows[#rows + 1] = { cells = { GREY .. "Nobody else lists it.|r", "", "" } }
    end
    return rows, c
end

--- How many units the other sellers list close to the lowest price (within 10% of it): what a new
--- post at the lowest price competes with.
function Post.Near(market)
    local rows = market and market.rows or {}
    if #rows == 0 then return 0 end
    local n, limit = 0, rows[1].price * 1.1
    for _, r in ipairs(rows) do
        if r.price <= limit then n = n + r.qty end
    end
    return n
end

Post.CONVERT_MIN_GAIN = 0.03    -- a smaller gain is not worth the clicks
Post.CONVERT_SURE_GAIN = 0.20   -- from this gain up, a crowded market does not hold the advice back
Post.CONVERT_ROOM = 60          -- a market with fewer units than this near its lowest price (counted as
                                -- lesser essences) is never "crowded"

--- An essence has two forms: three lesser combine into one greater, and one greater splits into three
--- lesser (a right-click in the bags, free). Which form is the better one to sell now?
--- It looks at the price in each form (1 copper under the lowest listing) and at how much is listed
--- close to that price in each form. Combining needs three in the bags.
--- @param bags number  how many of this form are in the bags
--- @param market table|nil, otherMarket table|nil  Post.Market of this form and of the other one
--- @return table|nil {
---   other (item ID of the other form), lesser (this one is the lesser form), mine (price each of this
---   form), same (what one of these sells for in the other form), gain (same - mine), pct (gain as a share),
---   near, otherNear (units listed close to the lowest price, in each form),
---   verdict = "convert" | "crowded" (the other form pays more, but far more is listed there) | "keep" }
---   nil when it does not apply: not an essence, a price is missing, or fewer than three to combine.
function Post.Convert(itemID, bags, market, otherMarket)
    local pair = Data.ESSENCE_PAIR[itemID]
    if not pair then return nil end
    local lesser = pair.factor < 1
    if lesser and (bags or 0) < 3 then return nil end
    local mine, other = Post.Suggest(itemID).price, Post.Suggest(pair.other).price
    if not (ns.db.prices[itemID] and ns.db.prices[pair.other]) or mine <= 0 or other <= 0 then return nil end
    local same = other * pair.factor
    local c = { other = pair.other, lesser = lesser, mine = mine, same = same, gain = same - mine,
        pct = (same - mine) / mine, near = Post.Near(market), otherNear = Post.Near(otherMarket) }
    -- Both markets counted in lesser essences, so they compare.
    local nearEq, otherEq = c.near * (lesser and 1 or 3), c.otherNear * (lesser and 3 or 1)
    if c.pct < Post.CONVERT_MIN_GAIN then
        c.verdict = "keep"
    elseif c.pct < Post.CONVERT_SURE_GAIN and otherEq > math.max(2 * nearEq, Post.CONVERT_ROOM) then
        c.verdict = "crowded"
    else
        c.verdict = "convert"
    end
    return c
end

--- The line of the Post window that says it.
function Post.ConvertText(itemID, bags, market, otherMarket)
    local c = Post.Convert(itemID, bags, market, otherMarket)
    if not c then return "" end
    local otherName = ns.MaterialName(c.other)
    local pct = math.floor(c.pct * 100 + 0.5)
    -- One line each: the verdict, the prices, how much is listed.
    local listed = string.format("\nListed near the lowest price: %d there, %d here.", c.otherNear, c.near)
    if c.verdict == "keep" then
        return "|cff808080" .. otherName .. " does not pay more now: keep this form.|r"
    elseif c.verdict == "crowded" then
        return string.format("|cffffd100Keep this form.|r Far more is listed in the other one.\n%s pays +%d%%: %s "
            .. "against %s here.%s", otherName, pct, ns.Money(c.same * (c.lesser and 3 or 1)),
            ns.Money(c.mine * (c.lesser and 3 or 1)), listed)
    elseif c.lesser then
        return string.format("|cff40ff40Better: combine 3 into 1 %s (+%d%%).|r Your %d make %d.\nOne sells for %s, "
            .. "three of these for %s.%s", otherName, pct, bags, math.floor(bags / 3), ns.Money(c.same * 3),
            ns.Money(c.mine * 3), listed)
    end
    return string.format("|cff40ff40Better: split each into 3 %s (+%d%%).|r\nThree sell for %s, one of these for %s.%s",
        otherName, pct, ns.Money(c.same), ns.Money(c.mine), listed)
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

--- The post on its way, or nil. One older than PENDING_WAIT got no answer and is dropped.
function Post.Pending()
    local p = Post.pending
    if p and GetTime() - p.t > PENDING_WAIT then
        Post.pending = nil
        ns.Log("post: no answer for %dx %s", p.quantity, ns.MaterialName(p.itemID))
        return nil
    end
    return p
end

--- Why the Post button cannot post now, or nil. (PostCommodity needs the click itself, so a post
--- cannot wait for a purchase and go out later: the button is off while one is on its way.)
function Post.Blocked()
    if not ns.Queue.open then return "The auction house is closed." end
    if ns.Scanner.Buying() then return "A purchase is on its way: Post comes back as soon as it is done." end
    if Post.Pending() then return "Your post is on its way." end
    return nil
end

--- Sends the post. Must run from a click. Returns true when the auction house took it,
--- "confirm" when it wants a second click (its low-price warning), or false and why.
function Post.Send(itemID, quantity, unitPrice, duration, confirmed)
    local blocked = Post.Blocked()
    if blocked then return false, blocked end
    if quantity < 1 or unitPrice < 1 then return false, "quantity and price must be at least 1" end
    local loc = Post.FindLocation(itemID)
    if not loc then return false, "none in your bags" end
    local fn = confirmed and AH.ConfirmPostCommodity or AH.PostCommodity
    ns.NoteRequest("post")
    local ok, needsConfirm = pcall(fn, loc, duration, quantity, unitPrice)
    if not ok then
        ns.Log("ERROR posting %s: %s", ns.MaterialName(itemID), tostring(needsConfirm))
        return false, tostring(needsConfirm)
    end
    -- The low-price warning: nothing was posted, the game waits for the second click.
    if not confirmed and needsConfirm then
        ns.Log("post: the auction house asks to confirm %dx %s at %s each", quantity, ns.MaterialName(itemID),
            ns.Money(unitPrice))
        return "confirm"
    end
    local deposit = Post.Outcome(itemID, quantity, unitPrice, duration).deposit
    Post.pending = { itemID = itemID, quantity = quantity, unitPrice = unitPrice, t = GetTime(), deposit = deposit }
    ns.Gold.Expect("deposit", deposit and -deposit or nil, ns.MaterialName(itemID), 15, -1)
    if ns.Convert then ns.Convert.Busy() end
    ns.Log("post sent: %dx %s at %s each, duration %d%s", quantity, ns.MaterialName(itemID), ns.Money(unitPrice),
        duration, confirmed and " (confirmed)" or "")
    return true
end

local d    -- the dialog frame, built on first use

ns.On("AUCTION_HOUSE_AUCTION_CREATED", function(auctionID)
    local p = Post.Pending()
    if not p then return end
    Post.pending = nil
    if auctionID then ns.Listings.NotePost(auctionID, p.itemID, p.quantity, p.unitPrice, p.deposit) end
    ns.Listings.Refresh()
    ns.Print("posted %dx %s at %s each", p.quantity, ns.MaterialName(p.itemID), ns.Money(p.unitPrice))
    ns.Log("posted %dx %s at %s each%s", p.quantity, ns.MaterialName(p.itemID), ns.Money(p.unitPrice),
        p.deposit and (", deposit " .. ns.Money(p.deposit)) or "")
    if d and d:IsShown() and d.itemID == p.itemID then d:Hide() end
    ns.Fire("SALVAGER_LEDGER")
end)

local function postFailed(why)
    local p = Post.Pending()
    if not p then return end
    Post.pending = nil
    ns.Print("could not post %s (%s)", ns.MaterialName(p.itemID), why)
    ns.Log("post failed: %s (%s)", ns.MaterialName(p.itemID), why)
end
ns.On("AUCTION_HOUSE_POST_ERROR", function() postFailed("the auction house refused it") end)
-- The auction house's one error event: ours only when the last request was a post.
ns.On("AUCTION_HOUSE_SHOW_ERROR", function(err)
    if ns.ErrorIs("post") then postFailed("auction house error " .. tostring(err)) end
end)

------------------------------------------------------------------ the window

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
    local skipped = 0
    for _, r in ipairs(s.skipped or {}) do skipped = skipped + r.qty end
    d.lines[1]:SetText("Lowest listing now: " .. (s.lowest and ns.Money(s.lowest) or "none listed")
        .. (d.stale and "  |cffff8040(price not refreshed)|r" or "")
        .. (skipped > 0 and string.format("  |cff808080(%d cheaper left out: too few)|r", skipped) or ""))
    d.lines[2]:SetText("Your break-even: " .. (s.breakEven and ns.Money(s.breakEven) or "|cff808080cost not known|r"))
    d.lines[3]:SetText("You get after the 5% cut: " .. ns.Money(o.net))
    if o.profit then
        d.lines[4]:SetText("Profit: " .. (o.profit >= 0 and "|cff40ff40" or "|cffff4040") .. ns.Money(o.profit) .. "|r")
    else
        d.lines[4]:SetText("Profit: |cff808080cost not known|r")
    end
    d.lines[5]:SetText("Deposit: " .. (o.deposit and ns.Money(o.deposit) or "-") .. " (returned when it sells)")
    d.convert:SetText(Post.ConvertText(id, bags, d.market, d.otherMarket))
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
    -- A click on a line sets the price to exactly that line's price (Undercut lowest is a button).
    for _, row in ipairs(rows) do
        if row.pick then
            row.onClick = function()
                d.price:Set(row.pick)
                d.confirm = nil
                recalc()
            end
        end
    end
    d.list:SetSource(#rows, function(i) return rows[i] end)
    d.list:Refresh()
    d.toEven:SetEnabled(s.breakEven ~= nil)
    d.toLowest:SetEnabled(s.lowest ~= nil)
    local blocked = Post.Blocked()
    d.post.reason = blocked
    d.post:SetEnabled(not blocked and qty >= 1 and qty <= bags and price >= 1)
    d.post:SetText(d.confirm and "Confirm" or "Post")
end

local function build()
    -- A window of its own: drag it where you want it, and it opens there the next time.
    d = W.Window("SalvagerPostFrame", "Post on the auction house", "post", 730, 400, 730, 400, true)
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
        { "Price each", 190, help = { "Price each", "The other sellers' listings, cheapest first. The game shows the "
            .. "auctions of one price as one line. Red = under your break-even. Grey = dearer than your price.\n\n"
            .. "Click a line to set your price to exactly that price." } },
        { "Units", 84, "CENTER" },
        { "Units up to here", 96, "CENTER", help = { "Units up to here", "How many units are listed at this price or "
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
            -- The window closes when the auction house says the auction is created.
            recalc()
        else
            ns.Print("could not post: %s", tostring(why))
        end
    end)
    -- Under the left column; the two price buttons have the right side, under the table.
    -- Cancel is always the last button of its group.
    local cancel = W.Button(d, "Cancel", 90, function() d:Hide() end)
    cancel:SetPoint("BOTTOMRIGHT", d, "BOTTOMLEFT", 366, 12)
    d.post:SetPoint("RIGHT", cancel, "LEFT", -6, 0)
    -- A switched-off Post button says why.
    d.post:SetMotionScriptsWhileDisabled(true)
    d.post:SetScript("OnEnter", function(self)
        if not self.reason then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("Post", 1, 1, 1)
        GameTooltip:AddLine(self.reason, 1, 0.82, 0, true)
        GameTooltip:Show()
    end)
    d.post:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- A post not answered yet is no longer followed once the window is gone.
    d:HookScript("OnHide", function() Post.pending = nil end)
    d:Hide()
end

-- The Post button follows a purchase on its way, and a post that got no answer.
local lastBlocked
ns.OnTick(function()
    if not (d and d:IsShown()) then return end
    local blocked = Post.Blocked()
    if blocked ~= lastBlocked then
        lastBlocked = blocked
        recalc()
    end
end)

local function show(itemID, stale)
    if not d then build() end
    local s = Post.Suggest(itemID)
    d.itemID, d.stale, d.confirm = itemID, stale, nil
    d.market, d.otherMarket = Post.Market(itemID), nil
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
            ns.Prices.Refresh(pair.other, function(got)
                if d and d:IsShown() and d.itemID == itemID then
                    d.otherMarket = got and Post.Market(pair.other) or nil
                    recalc()
                end
            end)
        end
    end)
end

ns.On("AUCTION_HOUSE_CLOSED", function()
    wipe(Post.loading)
    if d then d:Hide() end
end)

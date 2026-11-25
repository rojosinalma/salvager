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
    if s.breakEven and price < s.breakEven then
        d.warn:SetText("|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:16|t Below your break-even: you lose "
            .. ns.Money(s.breakEven - price) .. " on each one.")
    else
        d.warn:SetText("")
    end
    d.post:SetEnabled(ns.Queue.open and qty >= 1 and qty <= bags and price >= 1)
    d.post:SetText(d.confirm and "Confirm" or "Post")
end

local function build()
    -- A window of its own: drag it where you want it, and it opens there the next time.
    d = W.Window("SalvagerPostFrame", "Post on the auction house", "post", 380, 300, 380, 300, true)
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
    d.warn = W.Label(d, "", "GameFontHighlightSmall")
    d.warn:SetPoint("BOTTOMLEFT", d, "BOTTOMLEFT", 16, 44)
    d.warn:SetTextColor(1, 0.3, 0.3)

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
    end)
end

ns.On("AUCTION_HOUSE_CLOSED", function()
    wipe(Post.loading)
    if d then d:Hide() end
end)

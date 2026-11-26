-- Salvager: the materials list, and its own window.
-- The list lives in the main window's Materials tab. "Pop out" moves it to a window of its
-- own (move it, resize it); closing that window puts it back in the tab. Scans do not care
-- where the list is shown: they keep running.
local _, ns = ...

local Ledger, Data, W = ns.Ledger, ns.Data, ns.Widgets

local Materials = {}
ns.Materials = Materials

-- Shown when the mouse is over a column title, in the tab and in the window.
Materials.HELP = {
    [2] = { "Price", "The price of one, as the average of the cheapest units on the auction house (20 by default), "
        .. "without your own listings. Red = below your break-even. * = none listed now, the last price seen. "
        .. "~ = worked out from the other essence form." },
    [3] = { "Age", "How long ago this price was scanned. Orange = older than twice your rescan setting." },
    [4] = { "Bags", "How many you carry now. Post sells these." },
    [5] = { "Listed", "How many you have on the auction house that are not sold yet, as of the last time the addon "
        .. "read your auctions (the Ledger's Sales view shows when)." },
    [6] = { "Sold", "How many are sold and waiting for their money. The game pays about an hour after the sale. "
        .. "The sale is booked, and these leave the list, when you take that mail." },
    [7] = { "Avg cost", "What one cost you on average: the price of the items you disenchanted, shared out over the "
        .. "materials they gave. It covers what you carry, what is listed and what is sold but not paid yet. "
        .. "+2? = 2 more units with no recorded purchase." },
    [8] = { "Break-even", "The lowest price each at which a sale does not lose money: average cost with the 5% "
        .. "auction house cut added." },
    [9] = { "Profit", "What one unit brings if you sell it at the price now: the price after the 5% cut, minus its "
        .. "average cost. Red = a sale at this price loses money." },
}

Materials.COLUMNS = {
    { "Material", 160 }, { "Price", 80, "RIGHT" }, { "Age", 36, "CENTER" }, { "Bags", 40, "CENTER" },
    { "Listed", 46, "CENTER" }, { "Sold", 46, "CENTER" }, { "Avg cost", 85, "RIGHT" }, { "Break-even", 85, "RIGHT" },
    { "Profit", 85, "RIGHT" },
}
for i, help in pairs(Materials.HELP) do Materials.COLUMNS[i].help = help end

-- The window's own size: it fits its content and has no resize corner.
local WIDTH, TOP, BOTTOM, ROW_H = 800, 58, 14, 24
local MIN_W = 620   -- the row of buttons over the list: Scan materials, Scan owned, the check box, help

local function ago(seconds)
    if not seconds then return "-" end
    if seconds < 60 then return "now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
    return math.floor(seconds / 3600) .. "h"
end

--- One row per material: { cells, itemID, post (it has a Post button), canPost (some in the bags),
--- suggest (Post.Suggest, when there is something to post) }.
function Materials.Rows()
    local out = {}
    local maxAge = ns.PriceOldAfter()
    -- Your auctions as last read: what is still listed, and what is sold and waiting for its money.
    local listed, waiting = {}, {}
    for _, r in ipairs(ns.db.listings.rows or {}) do
        local t = r.sold and waiting or listed
        t[r.itemID] = (t[r.itemID] or 0) + r.qty
    end
    -- "Only materials with my data": the ones you carry, have listed or sold, or ever got from a disenchant.
    local only = ns.db.settings.materialsDataOnly
    local seen = {}
    if only then
        for _, r in ipairs(ns.db.ledger.disenchants) do
            for id in pairs(r.got or {}) do seen[id] = true end
        end
        for _, sale in ipairs(ns.db.ledger.sales) do seen[sale.id] = true end
    end
    for _, m in ipairs(Data.MATERIALS) do
        local e = ns.db.prices[m.id]
        local price = ns.PriceOf(m.id)
        local age = e and e.t and (time() - e.t)
        local s = ns.db.ledger.stock[m.id]
        local avg = Ledger.AvgCost(ns.db.ledger, m.id)
        local unknown = s and (s.unknown or 0) or 0
        local bags = ns.Post.BagCount(m.id)
        local suggest = bags > 0 and ns.Post.Suggest(m.id) or nil
        local be = Ledger.BreakEven(ns.db.ledger, m.id, ns.Cut())
        local priceText = price and ns.Money(price) or "-"
        if e and not e.p and e.last then
            priceText = "*" .. priceText
        elseif e and not e.p and price then
            priceText = "~" .. priceText
        end
        if price and be and price < be then priceText = "|cffff4040" .. priceText .. "|r" end
        local ageText = ago(age)
        if age and age > maxAge then ageText = "|cffff8040" .. ageText .. "|r" end
        local gain = (price and avg) and (math.floor(price * (1 - ns.Cut()) + 0.5) - math.floor(avg + 0.5)) or 0
        local mine = bags > 0 or listed[m.id] or waiting[m.id] or (s and s.qty > 0) or seen[m.id]
        if not only or mine then out[#out + 1] = {
            cells = { ns.MaterialName(m.id), priceText, ageText, bags > 0 and tostring(bags) or "-",
                listed[m.id] and tostring(listed[m.id]) or "-",
                waiting[m.id] and ("|cffffd100" .. waiting[m.id] .. "|r") or "-",
                avg and (ns.Money(avg) .. (unknown > 0 and " |cff808080+" .. unknown .. "?|r" or ""))
                    or (unknown > 0 and "|cff808080unknown|r" or "-"),
                be and ns.Money(be) or "-",
                (price and avg) and ((gain >= 0 and "|cff40ff40" or "|cffff4040") .. ns.Money(gain) .. "|r") or "-" },
            itemID = m.id, post = true, canPost = bags > 0, suggest = suggest,
        } end
    end
    if #out == 0 then
        out[1] = { cells = { "|cff808080No material with your data yet. Untick \"Only materials with my data\" to see all.|r" } }
    end
    return out
end

--- The "Scan owned" button (the tab and the window each have one).
function Materials.ScanOwnedButton(parent)
    return W.Button(parent, "Scan owned", 96, function() ns.Prices.Scan(ns.Prices.Owned()) end,
        "Searches only the materials in your bags: a quick way to get fresh prices for what you can post.")
end

--- The "Only materials with my data" check box (the tab and the window each have one).
function Materials.DataOnlyCheck(parent)
    return W.Check(parent, "Only materials with my data",
        "Lists only the materials you carry, have listed or sold, or ever got from a disenchant. "
            .. "Untick it to see the price of every material.",
        function(on)
            ns.db.settings.materialsDataOnly = on
            ns.Log("materials: only with data %s", on and "on" or "off")
            ns.Fire("SALVAGER_SETTINGS")
        end)
end

--- What the list's marks mean, one line each (for the "?" button).
function Materials.HelpLines()
    return {
        string.format("Price: the average of the cheapest %d units on the auction house, without your own.",
            ns.db.settings.priceUnits),
        "A red price is below your break-even.",
        "* before a price: none is listed now, so it is the last price seen.",
        "~ before a price: worked out from the other essence form (3 lesser = 1 greater).",
        "Bags: how many you carry. Listed: on the auction house, not sold. Sold: sold, money on its way.",
        "Avg cost: what one cost you. \"unknown\" or \"+2?\": units with no recorded purchase (/salv stock sets them).",
        "Break-even: the lowest price each at which a sale does not lose money.",
        "Post: sells what is in your bags. The warning sign means the price is below your break-even.",
        "Click a material to see which items and bands it came from, and what pays.",
        "Hover a column title for more about that column.",
    }
end

--- The text of the below-break-even warning for a row's suggestion.
function Materials.WarnText(sug)
    return string.format("The lowest listing is %s. Your break-even is %s. Posting now loses about %s each.",
        sug.lowest and ns.Money(sug.lowest) or "not known", ns.Money(sug.breakEven), ns.Money(sug.breakEven - sug.price))
end

------------------------------------------------------------------ the window

local REFRESH_GAP = 0.25
local f, list, status, dataOnly
local lastRefresh, queued = 0, false

--- Is the list in its own window now?
function Materials.IsPoppedOut()
    return f ~= nil and f:IsShown()
end

function Materials.Refresh()
    if not Materials.IsPoppedOut() then return end
    lastRefresh = GetTime()
    local rows = Materials.Rows()
    for _, row in ipairs(rows) do
        if row.post then
            local loading = ns.Post.loading[row.itemID]
            row.action = { text = loading and "..." or "Post", enabled = ns.Queue.open and row.canPost and not loading,
                onClick = function() ns.Post.Open(row.itemID) end }
            if row.suggest and row.suggest.below then
                row.warn = { title = "Below your break-even", text = Materials.WarnText(row.suggest) }
            end
        end
    end
    -- The window is as tall as its rows need, up to the room on the screen; past that the list scrolls.
    local room = (UIParent:GetHeight() or 768) - 120
    local fit = math.max(1, math.min(#rows, math.floor((room - TOP - BOTTOM - ROW_H) / ROW_H)))
    f:SetHeight(TOP + ROW_H * (fit + 1) + BOTTOM)
    list:SetSource(#rows, function(i) return rows[i] end)
    list:Refresh()
    -- As wide as its columns need, no wider (the Post column ends with its button), and wide enough for the
    -- row of buttons above the list.
    local needed = rawget(list, "neededWidth")
    if type(needed) == "number" then
        local w = math.max(MIN_W, math.ceil(needed) + 24)
        if math.abs((f:GetWidth() or 0) - w) >= 1 then
            f:SetWidth(w)
            list:Refresh()
        end
    end
    dataOnly:SetChecked(ns.db.settings.materialsDataOnly)
    if ns.Prices.scanning then
        status:SetText(string.format("Scanning %d/%d", ns.Prices.done, ns.Prices.total))
    else
        status:SetText(ns.Queue.open and "" or "Auction house closed: Post and scans need it open")
    end
end

local function requestRefresh()
    if not Materials.IsPoppedOut() or queued then return end
    local wait = REFRESH_GAP - (GetTime() - lastRefresh)
    if wait <= 0 then Materials.Refresh() return end
    queued = true
    C_Timer.After(wait, function()
        queued = false
        Materials.Refresh()
    end)
end

local function build()
    f = W.Window("SalvagerMaterialsFrame", "Salvager materials", "materials", WIDTH, 520, WIDTH, 120, true)
    local scan = W.Button(f, "Scan materials", 115, function() ns.Prices.Scan() end,
        "Searches each disenchanting material once (about 20 seconds) and stores its price.")
    scan:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -30)
    local owned = Materials.ScanOwnedButton(f)
    owned:SetPoint("LEFT", scan, "RIGHT", 6, 0)
    -- On the right: the help, and the check box with its label on its left; the status between, cut there.
    local helpButton = W.HelpButton(f, "Materials", Materials.HelpLines)
    helpButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", -12, -30)
    dataOnly = Materials.DataOnlyCheck(f)
    dataOnly:SetPoint("RIGHT", helpButton, "LEFT", -8, 0)
    dataOnly.label:ClearAllPoints()
    dataOnly.label:SetPoint("RIGHT", dataOnly, "LEFT", -2, 0)
    status = W.Label(f, "", "GameFontHighlightSmall")
    status:SetPoint("LEFT", owned, "RIGHT", 10, 0)
    status:SetPoint("RIGHT", dataOnly.label, "LEFT", -10, 0)
    status:SetJustifyH("LEFT")
    status:SetWordWrap(false)
    list = W.List(f, { rowHeight = ROW_H, actionWidth = 96, actionTitle = "Post" })
    list:SetColumns(Materials.COLUMNS)
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -TOP)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, BOTTOM)
    f:SetScript("OnShow", function()
        Materials.Refresh()
        ns.Fire("SALVAGER_SETTINGS")   -- the main window gives up its Materials tab
    end)
    -- Closed: the list is back in the main window's Materials tab.
    f:SetScript("OnHide", function() ns.Fire("SALVAGER_SETTINGS") end)
end

--- Moves the list to its own window.
function Materials.PopOut()
    if not f then build() end
    f.UserShow()
    ns.Log("materials list popped out")
end

--- Puts the list back in the main window's tab.
function Materials.PutBack()
    if f and f:IsShown() then
        f.UserHide()
        ns.Log("materials list put back")
    end
end

--- Pops the list out again if it was out the last time (the auction house opened).
function Materials.Restore()
    local saved = ns.db.windows.materials
    if not (saved and saved.open) then return end
    if not f then build() end
    f:Show()
end

for _, e in ipairs({ "SALVAGER_PRICES", "SALVAGER_PRICES_DONE", "SALVAGER_LEDGER", "SALVAGER_SETTINGS", "SALVAGER_SCAN",
    "SALVAGER_LISTINGS",
    "BAG_UPDATE_DELAYED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do
    ns.On(e, requestRefresh)
end

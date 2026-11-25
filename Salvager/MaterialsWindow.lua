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
    [3] = { "Units", "What the price rests on, as units / listings. 20/1 = the 20 cheapest units all come from one "
        .. "listing. 20/8 = they come from 8 listings. A first number under 20, such as 9/4, means only 9 units are "
        .. "listed at all: a thin market, so the price can jump." },
    [4] = { "Age", "How long ago this price was scanned. Orange = older than twice your rescan setting." },
    [5] = { "Bags", "How many you carry now. Post sells these." },
    [6] = { "Stock", "How many the ledger counts as yours: what your disenchants gave, minus what you sold. "
        .. "It still counts the ones you have posted." },
    [7] = { "Avg cost", "What one cost you on average: the price of the items you disenchanted, shared out over the "
        .. "materials they gave. +2? = 2 more units with no recorded purchase." },
    [8] = { "Break-even", "The lowest price each at which a sale does not lose money: average cost with the 5% "
        .. "auction house cut added." },
}

Materials.COLUMNS = {
    { "Material", 160 }, { "Price", 80, "RIGHT" }, { "Units", 45, "CENTER" }, { "Age", 36, "CENTER" },
    { "Bags", 40, "CENTER" }, { "Stock", 40, "CENTER" }, { "Avg cost", 85, "RIGHT" }, { "Break-even", 85, "RIGHT" },
}
for i, help in pairs(Materials.HELP) do Materials.COLUMNS[i].help = help end

local function ago(seconds)
    if not seconds then return "-" end
    if seconds < 60 then return "now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
    return math.floor(seconds / 3600) .. "h"
end

--- One row per material: { cells, itemID, post (some in the bags), suggest (Post.Suggest) }.
function Materials.Rows()
    local out = {}
    local maxAge = ns.PriceOldAfter()
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
        out[#out + 1] = {
            cells = { ns.MaterialName(m.id), priceText,
                e and e.units and e.units > 0 and (e.units .. "/" .. e.listings) or "-",
                ageText, bags > 0 and tostring(bags) or "-", s and tostring(s.qty) or "-",
                avg and (ns.Money(avg) .. (unknown > 0 and " |cff808080+" .. unknown .. "?|r" or ""))
                    or (unknown > 0 and "|cff808080unknown|r" or "-"),
                be and ns.Money(be) or "-" },
            itemID = m.id, post = bags > 0, suggest = suggest,
        }
    end
    return out
end

--- The line under the list.
function Materials.Legend()
    return string.format("Price = average of cheapest %d units. Red = below break-even. * = none listed, last price. "
        .. "~ = other essence form. Unknown / +n? = units with no recorded purchase (/salv stock sets them). "
        .. "Post = sell what is in your bags; the warning sign means the price is below your break-even.",
        ns.db.settings.priceUnits)
end

--- The text of the below-break-even warning for a row's suggestion.
function Materials.WarnText(sug)
    return string.format("The lowest listing is %s. Your break-even is %s. Posting now loses about %s each.",
        sug.lowest and ns.Money(sug.lowest) or "not known", ns.Money(sug.breakEven), ns.Money(sug.breakEven - sug.price))
end

------------------------------------------------------------------ the window

local REFRESH_GAP = 0.25
local f, list, legend, status
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
            row.action = { text = loading and "..." or "Post", enabled = ns.Queue.open and not loading,
                onClick = function() ns.Post.Open(row.itemID) end }
            if row.suggest and row.suggest.below then
                row.warn = { title = "Below your break-even", text = Materials.WarnText(row.suggest) }
            end
        end
    end
    list:SetSource(#rows, function(i) return rows[i] end)
    list:Refresh()
    legend:SetText(Materials.Legend())
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
    f = W.Window("SalvagerMaterialsFrame", "Salvager materials", "materials", 760, 520, 560, 220)
    local scan = W.Button(f, "Scan materials", 115, function() ns.Prices.Scan() end,
        "Searches each disenchanting material once (about 20 seconds) and stores its price.")
    scan:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -30)
    status = W.Label(f, "", "GameFontHighlightSmall")
    status:SetPoint("LEFT", scan, "RIGHT", 10, 0)
    list = W.List(f, { rowHeight = 24, actionWidth = 96 })
    list:SetColumns(Materials.COLUMNS)
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -58)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 44)
    legend = W.Label(f, "", "GameFontDisableSmall")
    legend:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 10)
    legend:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -24, 10)
    legend:SetJustifyH("LEFT")
    legend:SetWordWrap(true)
    f.onResize = Materials.Refresh
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
    "BAG_UPDATE_DELAYED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" }) do
    ns.On(e, requestRefresh)
end

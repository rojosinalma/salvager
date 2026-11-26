-- Salvager: where one of your listings stands. A click on an auction of yours that is for sale (Ledger,
-- Sales) searches its material and shows the other sellers' listings, cheapest first, with your price and
-- your break-even in their place: how many units sell before yours, and whether a cancel and a new post
-- pays for itself, or waiting does.
local _, ns = ...

local Ledger, W = ns.Ledger, ns.Widgets

local Stand = {}
ns.Stand = Stand

local GREY, GOLD, GREEN, RED = "|cff808080", "|cffffd100", "|cff40ff40", "|cffff4040"

local COLUMNS = {
    { "Price each", 100, "RIGHT", help = { "Price each", "One price line of the other sellers. Red: under your "
        .. "break-even. Grey: dearer than yours, so it sells after yours." } },
    { "Units", 70, "RIGHT", help = { "Units", "The other sellers' units at that price (+ yours, when you list at it "
        .. "too)." } },
    { "Units up to here", 100, "RIGHT", help = { "Units up to here", "Every unit of the other sellers at this price "
        .. "or cheaper: what a buyer takes before reaching the next line." } },
}

local f, list, lines, title
Stand.row = nil       -- the listing shown
Stand.loading = false

--- The facts above the list: your listing, what is ahead of it, and what a cancel and a new post would cost.
--- @return table lines
function Stand.Facts(row, market)
    local breakEven = Ledger.BreakEven(ns.db.ledger, row.itemID, ns.Cut())
    local _, c = ns.Post.MarketRows(market, row.each, breakEven)
    local out = {}
    out[#out + 1] = string.format("%sYour listing|r %d at %s each%s", GOLD, row.qty, ns.Money(row.each),
        breakEven and string.format("    %sBreak-even|r %s", GOLD, ns.Money(breakEven)) or "")
    local cheaper = 0
    for _, r in ipairs(market.rows) do if r.price < row.each then cheaper = cheaper + r.qty end end
    out[#out + 1] = string.format("%sAhead of you|r %s units in %d price lines (cheaper than yours: %d)", GOLD,
        c.ahead, c.aheadListings, cheaper)
    local low = market.rows[1] and market.rows[1].price
    if low and low < row.each then
        local gap = row.each - low
        local cost = ns.Listings.RepostCost(row)
        local gain = gap * row.qty
        out[#out + 1] = string.format("%sTo be first again|r post at %s: %s less in all, and %s in deposits (the one you "
            .. "lose and the new one)", GOLD, ns.Money(low - 1), ns.Money(gain), ns.Money(cost))
        if breakEven and low - 1 < breakEven then
            out[#out + 1] = RED .. "That price is under your break-even: waiting loses nothing, a repost loses on each "
                .. "unit.|r"
        elseif cheaper <= row.qty then
            out[#out + 1] = GREEN .. "Few units ahead of yours: waiting is likely to sell soon.|r"
        else
            out[#out + 1] = string.format("%sMany units ahead (%d): a repost sells sooner, if the gap pays for its "
                .. "deposits.|r", GREY, cheaper)
        end
    elseif low then
        out[#out + 1] = GREEN .. "You are the cheapest.|r"
    else
        out[#out + 1] = GREEN .. "Nobody else lists it.|r"
    end
    if market.partial then out[#out + 1] = GREY .. "(The auction house sent only the first price lines.)|r" end
    return out
end

function Stand.Refresh()
    if not f or not f:IsShown() or not Stand.row then return end
    local row = Stand.row
    title:SetText(GOLD .. ((row.link and row.link:match("%[(.-)%]")) or ns.MaterialName(row.itemID)) .. "|r")
    local rows, facts
    if Stand.loading then
        facts = { GREY .. "Searching the auction house...|r" }
        rows = {}
    elseif not ns.Queue.open then
        facts = { GREY .. "Open the auction house to see the other listings.|r" }
        rows = {}
    else
        local market = ns.Post.Market(row.itemID)
        local breakEven = Ledger.BreakEven(ns.db.ledger, row.itemID, ns.Cut())
        rows = ns.Post.MarketRows(market, row.each, breakEven)
        facts = Stand.Facts(row, market)
    end
    for i, l in ipairs(lines) do l:SetText(facts[i] or "") end
    list:SetSource(#rows, function(i) return rows[i] end)
    list:Refresh()
end

local function build()
    f = W.Window("SalvagerStandFrame", "Where your listing stands", "stand", 460, 440, 460, 260, "vertical")
    title = W.Label(f, "", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -32)
    lines = {}
    for i = 1, 5 do
        local l = W.Label(f, "", "GameFontHighlightSmall")
        if i == 1 then l:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -8) else l:SetPoint("TOPLEFT", lines[i - 1], "BOTTOMLEFT", 0, -4) end
        l:SetWidth(432)
        l:SetJustifyH("LEFT")
        lines[i] = l
    end
    list = W.List(f, { rowHeight = 20 })
    list:SetColumns(COLUMNS)
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -150)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 14)
    f:SetScript("OnShow", Stand.Refresh)
end

--- Shows where `row` (an auction of yours for sale, a commodity) stands, after a search of its material.
function Stand.Show(row)
    if not f then build() end
    Stand.row = row
    f.UserShow()
    if not ns.Queue.open then Stand.Refresh() return end
    Stand.loading = true
    Stand.Refresh()
    ns.Prices.Refresh(row.itemID, function()
        Stand.loading = false
        Stand.Refresh()
    end)
end

function Stand.Restore()
    local saved = ns.db.windows.stand
    if saved and saved.open and Stand.row then
        if not f then build() end
        f:Show()
    end
end

for _, e in ipairs({ "SALVAGER_LISTINGS", "SALVAGER_LEDGER", "AUCTION_HOUSE_CLOSED" }) do
    ns.On(e, function() Stand.Refresh() end)
end

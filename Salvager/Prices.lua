-- Salvager: material prices from the auction house.
-- Price each = average unit price of the cheapest N units (your own listings left out).
local _, ns = ...

local AH = C_AuctionHouse
local Data = ns.Data

local Prices = { scanning = false, done = 0, total = 0 }
ns.Prices = Prices

--- Average price of the cheapest `units` units in the client's current results.
--- @return table|nil { p, units, listings }
function Prices.ReadCommodity(itemID, units)
    local n = AH.GetNumCommoditySearchResults(itemID) or 0
    local need, sum, got, listings = units, 0, 0, 0
    for i = 1, n do
        local r = AH.GetCommoditySearchResultInfo(itemID, i)
        if r and r.unitPrice and r.unitPrice > 0 then
            local qty = (r.quantity or 0) - (r.numOwnerItems or 0)
            if qty > 0 then
                local take = math.min(qty, need)
                sum = sum + take * r.unitPrice
                got = got + take
                need = need - take
                listings = listings + 1
                if need <= 0 then break end
            end
        end
    end
    if got == 0 then return nil end
    return { p = math.floor(sum / got + 0.5), units = got, listings = listings }
end

local function store(itemID)
    local e = Prices.ReadCommodity(itemID, ns.db.settings.priceUnits)
    ns.Log("price %s (%d): %s, %d results", ns.MaterialName(itemID), itemID,
        e and (ns.Money(e.p) .. " over " .. e.units .. " units") or "none listed",
        AH.GetNumCommoditySearchResults(itemID) or 0)
    if e then
        e.t = time()
        ns.db.prices[itemID] = e
    else
        local old = ns.db.prices[itemID]
        ns.db.prices[itemID] = { p = nil, units = 0, listings = 0, t = time(),
            last = old and (old.p or old.last), lastT = old and (old.p and old.t or old.lastT) }
    end
end

local function stepDone()
    Prices.done = Prices.done + 1
    ns.Fire("SALVAGER_PRICES", Prices.done, Prices.total)
    if Prices.done >= Prices.total then
        Prices.scanning = false
        ns.Print("material prices updated (%d)", Prices.total)
        ns.Fire("SALVAGER_PRICES_DONE")
    end
end

--- Searches every material once. Needs the auction house open.
function Prices.Scan()
    if not ns.Queue.open then ns.Print("open the auction house first") return end
    if Prices.scanning then return end
    if ns.Scanner.state ~= "idle" then
        ns.Print("wait for the gear scan to finish (or use Scan both)")
        return
    end
    Prices.scanning, Prices.done, Prices.total = true, 0, #Data.MATERIALS
    ns.Log("material scan started")
    for _, m in ipairs(Data.MATERIALS) do
        ns.Queue.Add({
            commodity = m.id,
            onResult = function() store(m.id) stepDone() end,
            onFail = function() stepDone() end,
        })
    end
    ns.Fire("SALVAGER_PRICES", 0, Prices.total)
end

--- Age in seconds of a material's price, or nil.
function Prices.Age(itemID)
    local e = ns.db.prices[itemID]
    return e and e.t and (time() - e.t) or nil
end

ns.On("AUCTION_HOUSE_CLOSED", function() Prices.scanning = false end)

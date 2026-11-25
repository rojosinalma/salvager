-- Salvager: namespace, saved data, settings, events, item helpers, slash commands.
local ADDON, ns = ...

local Util, Data, Model, Ledger = ns.Util, ns.Data, ns.Model, ns.Ledger

ns.NAME = ADDON
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "dev"

local DEFAULTS = {
    settings = {
        minProfit = 1000,          -- copper; deals below this profit are hidden
        salvager = "auto",         -- "auto" | "on" | "off": add the Arcane Salvager bonus when valuing buys
        salvagerChance = 0.5,      -- chance of one extra dust or essence with the Salvager
        cut = 0.05,                -- auction house cut on sales
        priceUnits = 20,           -- material price = average of the cheapest N units
        priceMaxAge = 6 * 3600,    -- seconds before a material price counts as old
        qualities = { [2] = true, [3] = false, [4] = false },
        gearClasses = "both",      -- "weapons" | "armor" | "both"
        minLevel = 0,              -- required-level filter for the gear scan (0 = none)
        maxLevel = 0,
        autoInterval = 20,         -- seconds between gear scans in auto mode
        maxChecks = 60,            -- item searches per gear scan (best candidates first)
        autoOpen = true,           -- open the window with the auction house
        minimap = { hide = false, angle = 215 },
        postDuration = 2,          -- auction length for Post: 1, 2 or 3 (the game's three choices)
        limitOverride = {},        -- ["<quality>:<a|w>:<band>"] = copper: buy limits set by hand
    },
    prices = {},                   -- [matID] = { p = copper each, units, listings, t }
    ledger = {},
    auraSeen = {},                 -- [spellID] = name, auras whose name mentions the Salvager
    auraSnapshots = {},            -- helpful auras at the first disenchants (to find the Salvager's ID)
    ilvl = {},                     -- [itemID] = item level, learned from the game (see Items.lua)
    log = {},                      -- what the addon did, newest last (written to disk on /reload or logout)
    window = {},
    windows = {},                  -- place and size of the Results and Activity windows
}

------------------------------------------------------------------ output

function ns.Print(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cff9370dbSalvager|r: " .. msg)
end

function ns.Money(copper) return Util.FormatMoney(copper, true) end

local LOG_MAX = 600

--- Adds a line to the activity log (SalvagerDB.log).
function ns.Log(fmt, ...)
    if not ns.db then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    msg = Util.PlainMoney(msg)
    local log = ns.db.log
    log[#log + 1] = date("%H:%M:%S") .. " " .. msg
    ns.logChanged = true
    Util.Cap(log, LOG_MAX)
end

------------------------------------------------------------------ events

local handlers = {}
local frame = CreateFrame("Frame")
ns.eventFrame = frame

function ns.On(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        if not event:match("^SALVAGER_") then pcall(frame.RegisterEvent, frame, event) end
    end
    table.insert(handlers[event], fn)
end

function ns.Fire(event, ...)
    local list = handlers[event]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, ...)
        if not ok then
            ns.Print("error in %s: %s", event, tostring(err))
            ns.Log("ERROR in %s: %s", event, tostring(err))
        end
    end
end

frame:SetScript("OnEvent", function(_, event, ...) ns.Fire(event, ...) end)

-- One ticker for everything that works in small steps (10 times a second).
local ticks, tickSum = {}, 0
function ns.OnTick(fn) ticks[#ticks + 1] = fn end
frame:SetScript("OnUpdate", function(_, elapsed)
    tickSum = tickSum + elapsed
    if tickSum < 0.1 then return end
    tickSum = 0
    for _, fn in ipairs(ticks) do
        local ok, err = pcall(fn)
        if not ok then ns.Log("ERROR in ticker: %s", tostring(err)) end
    end
end)

------------------------------------------------------------------ item helpers

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or _G.GetItemInfo
local GetItemInfoInstant = (C_Item and C_Item.GetItemInfoInstant) or _G.GetItemInfoInstant
local GetItemCount = (C_Item and C_Item.GetItemCount) or _G.GetItemCount
ns.GetItemInfo, ns.GetItemInfoInstant, ns.GetItemCount = GetItemInfo, GetItemInfoInstant, GetItemCount

function ns.ItemID(linkOrID)
    if type(linkOrID) == "number" then return linkOrID end
    if type(linkOrID) ~= "string" then return nil end
    return tonumber(linkOrID:match("item:(%d+)")) or tonumber(linkOrID)
end

function ns.ClassOf(linkOrID)
    local _, _, _, _, _, classID = GetItemInfoInstant(linkOrID)
    return classID
end

function ns.QualityOf(linkOrID)
    if C_Item and C_Item.GetItemQualityByID then
        local ok, q = pcall(C_Item.GetItemQualityByID, linkOrID)
        if ok and q then return q end
    end
    local _, _, q = GetItemInfo(linkOrID)
    return q
end

function ns.ItemLevelOf(linkOrID)
    if type(linkOrID) == "string" and C_Item and C_Item.GetDetailedItemLevelInfo then
        local ok, lvl = pcall(C_Item.GetDetailedItemLevelInfo, linkOrID)
        if ok and lvl and lvl > 0 then return lvl end
    end
    local _, _, _, lvl = GetItemInfo(linkOrID)
    return lvl
end

function ns.MaterialName(id)
    local name = (C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(id)) or GetItemInfo(id)
    if name then return name end
    local m = Data.MATERIAL_BY_ID[id]
    return m and m.name or ("item " .. id)
end

------------------------------------------------------------------ prices and value

-- The last price seen stays in use when a scan finds no listings.
local function rawPrice(id)
    local e = ns.db and ns.db.prices[id]
    return e and (e.p or e.last) or nil
end

--- Material price each (copper), filled from the other essence form when missing.
function ns.PriceOf(id)
    return (Model.PairPrice(id, rawPrice))
end

function ns.PriceEntry(id) return ns.db.prices[id] end

function ns.Cut() return ns.db.settings.cut end

--- Can the player use the Arcane Salvager now (recipe known or one in the bags)?
function ns.HasSalvager()
    if IsPlayerSpell then
        local ok, known = pcall(IsPlayerSpell, Data.SALVAGER_RECIPE_SPELL)
        if ok and known then return true end
    end
    local ok, n = pcall(GetItemCount, Data.SALVAGER_ITEM, true)
    return ok and (n or 0) > 0
end

--- Whether buy prices include the Salvager bonus.
function ns.SalvagerForBuy()
    local mode = ns.db.settings.salvager
    if mode == "on" then return true end
    if mode == "off" then return false end
    return ns.HasSalvager()
end

--- Expected value of disenchanting one item.
--- @return table|nil value (Model.Value), outcomes
function ns.ItemValue(linkOrID, ilvl, quality, classID, salvager)
    if ns.NoDisenchant(ns.ItemID(linkOrID)) then return nil end
    classID = classID or ns.ClassOf(linkOrID)
    quality = quality or ns.QualityOf(linkOrID)
    ilvl = ilvl or ns.ItemLevelOf(linkOrID)
    if not (classID and quality and ilvl) then return nil end
    local outcomes = Model.Outcomes(quality, classID, ilvl)
    if not outcomes then return nil end
    if salvager == nil then salvager = ns.SalvagerForBuy() end
    local s = ns.db.settings
    local v = Model.Value(outcomes, ns.PriceOf, { salvager = salvager, salvagerChance = s.salvagerChance, cut = s.cut })
    return v, outcomes
end

--- True when a material that makes up a big share of the value has no price.
function ns.MissingMajor(value, outcomes)
    if #value.missing == 0 then return false end
    for _, id in ipairs(value.missing) do
        for _, r in ipairs(outcomes.results) do
            if r.id == id and r.chance >= 0.15 then return true end
        end
    end
    return false
end

--- Is any scan running?
function ns.Busy()
    return (ns.Prices and ns.Prices.scanning) or (ns.Scanner and ns.Scanner.state ~= "idle") or ns.scanBothPending or false
end

--- Material prices first, then the gear scan.
function ns.ScanBoth()
    if not ns.Queue.open then ns.Print("open the auction house first") return end
    if ns.Busy() then return end
    ns.scanBothPending = true
    ns.Log("scan both: materials, then gear")
    ns.Prices.Scan()
    ns.Fire("SALVAGER_SCAN")
end

--- Is this gear type ("weapons" or "armor") scanned?
function ns.GearTypeOn(kind)
    local g = ns.db.settings.gearClasses
    return g == "both" or g == kind
end

--- Turns one gear type on or off. At least one stays on.
function ns.SetGearType(kind, on)
    local w = kind == "weapons" and on or (kind ~= "weapons" and ns.GearTypeOn("weapons"))
    local a = kind == "armor" and on or (kind ~= "armor" and ns.GearTypeOn("armor"))
    if not (w or a) then
        ns.Print("at least one gear type must stay on")
    else
        ns.db.settings.gearClasses = (w and a) and "both" or (w and "weapons" or "armor")
    end
    ns.Log("gear type set to %s", ns.db.settings.gearClasses)
    ns.Fire("SALVAGER_SETTINGS")
end

--- Which item classes the gear scan includes: { [2] = bool, [4] = bool }.
function ns.GearClasses()
    local g = ns.db.settings.gearClasses
    return { [Data.CLASS_WEAPON] = g ~= "armor", [Data.CLASS_ARMOR] = g ~= "weapons" }
end

ns.On("SALVAGER_PRICES_DONE", function()
    if ns.scanBothPending then
        ns.scanBothPending = false
        ns.Scanner.Scan()
    end
end)
ns.On("AUCTION_HOUSE_CLOSED", function() ns.scanBothPending = false end)

function ns.BandKey(quality, classID, band)
    return string.format("%d:%s:%d", quality, classID == Data.CLASS_WEAPON and "w" or "a", band)
end

--- The recommended buy limit: value after cut minus the minimum profit.
function ns.RecommendedLimit(net)
    return Model.MaxBuy(net, ns.db.settings.minProfit)
end

--- The buy limit in use: the one set by hand for this band, else the recommended one.
--- @return number copper, boolean manual
function ns.BuyLimit(quality, classID, band, net)
    local o = band and ns.db.settings.limitOverride[ns.BandKey(quality, classID, band)]
    if o then return o, true end
    return ns.RecommendedLimit(net), false
end

function ns.SetLimitOverride(quality, classID, band, copper)
    local key = ns.BandKey(quality, classID, band)
    ns.db.settings.limitOverride[key] = copper
    ns.Log("buy limit %s = %s", key, copper and ns.Money(copper) or "recommended")
    ns.Fire("SALVAGER_SETTINGS")
end

--- Buy limits per disenchant band, for the Limits tab.
--- @return table  rows { quality, lo, up, armor = {value, recommended, limit, manual, missing}, weapon = {...} }
function ns.Limits()
    local rows, s = {}, ns.db.settings
    local salv = ns.SalvagerForBuy()
    local function one(quality, classID, ilvl)
        local o = Model.Outcomes(quality, classID, ilvl)
        if not o then return nil end
        local v = Model.Value(o, ns.PriceOf, { salvager = salv, salvagerChance = s.salvagerChance, cut = s.cut })
        local limit, manual = ns.BuyLimit(quality, classID, o.band, v.net)
        return { value = v.net, recommended = ns.RecommendedLimit(v.net), limit = limit, manual = manual,
            missing = #v.missing > 0, blocked = ns.MissingMajor(v, o), quality = quality, classID = classID,
            band = o.band }
    end
    for _, q in ipairs({ { 2, Data.GREEN }, { 3, Data.BLUE }, { 4, Data.PURPLE } }) do
        if s.qualities[q[1]] then
            local lo = 1
            for _, row in ipairs(q[2]) do
                local ilvl = math.min(row.up, 70)
                rows[#rows + 1] = { quality = q[1], lo = lo, up = row.up,
                    armor = one(q[1], Data.CLASS_ARMOR, ilvl), weapon = one(q[1], Data.CLASS_WEAPON, ilvl) }
                lo = row.up + 1
            end
        end
    end
    return rows
end

------------------------------------------------------------------ load

ns.On("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    SalvagerDB = SalvagerDB or {}
    Util.Defaults(SalvagerDB, DEFAULTS)
    ns.db = SalvagerDB
    Ledger.Init(ns.db.ledger)
    ns.Log("loaded %s, salvager for buys: %s", ns.VERSION, tostring(ns.SalvagerForBuy()))
    ns.Fire("SALVAGER_READY")
end)

------------------------------------------------------------------ slash commands

local function parseItem(arg)
    if not arg then return nil end
    return ns.ItemID(arg)
end

local HELP = {
    "/salv - open or close the window",
    "/salv minprofit 20s - lowest profit a deal must make",
    "/salv salvager auto|on|off - Arcane Salvager bonus in buy prices",
    "/salv quality uncommon|rare|epic|both|all - which gear the scan looks at",
    "/salv gear weapons|armor|both - which item types the scan looks at",
    "/salv config - the options panel",
    "/salv levels 20 60 - required level range for the gear scan (0 0 = all)",
    "/salv interval 20 - seconds between gear scans in auto mode",
    "/salv stock <item> <quantity> <cost each> - opening stock, e.g. /salv stock 11137 40 6s",
    "/salv report - disenchant results by band",
    "/salv auras - list your buffs (to find the Salvager's)",
    "/salv results - the results window (purchases, sales, odds)",
    "/salv activity - the activity log window",
    "/salv log [n] - the last n lines of the activity log in chat (default 15)",
    "/salv reset ledger confirm - clear all purchases, stock and history",
}

SLASH_SALVAGER1, SLASH_SALVAGER2 = "/salv", "/salvager"
SlashCmdList.SALVAGER = function(msg)
    local s = ns.db.settings
    local args = {}
    for w in (msg or ""):gmatch("%S+") do args[#args + 1] = w end
    local cmd = (args[1] or ""):lower()
    if cmd == "" then
        if ns.UI then ns.UI.Toggle() end
    elseif cmd == "minprofit" then
        local c = Util.ParseMoney(table.concat(args, "", 2))
        if not c then ns.Print("usage: /salv minprofit 20s") return end
        s.minProfit = c
        ns.Print("minimum profit: %s", ns.Money(c))
        ns.Fire("SALVAGER_SETTINGS")
    elseif cmd == "salvager" then
        local m = (args[2] or ""):lower()
        if m ~= "auto" and m ~= "on" and m ~= "off" then ns.Print("usage: /salv salvager auto|on|off") return end
        s.salvager = m
        ns.Print("Salvager bonus in buy prices: %s (now %s)", m, ns.SalvagerForBuy() and "on" or "off")
        ns.Fire("SALVAGER_SETTINGS")
    elseif cmd == "quality" then
        local q = (args[2] or ""):lower()
        if q == "uncommon" then s.qualities = { [2] = true, [3] = false, [4] = false }
        elseif q == "rare" then s.qualities = { [2] = false, [3] = true, [4] = false }
        elseif q == "epic" then s.qualities = { [2] = false, [3] = false, [4] = true }
        elseif q == "both" then s.qualities = { [2] = true, [3] = true, [4] = false }
        elseif q == "all" then s.qualities = { [2] = true, [3] = true, [4] = true }
        else ns.Print("usage: /salv quality uncommon|rare|epic|both|all") return end
        ns.Print("gear scan quality: %s", q)
    elseif cmd == "gear" then
        local g = (args[2] or ""):lower()
        if g ~= "weapons" and g ~= "armor" and g ~= "both" then ns.Print("usage: /salv gear weapons|armor|both") return end
        s.gearClasses = g
        ns.Print("gear scan: %s", g)
        ns.Fire("SALVAGER_SETTINGS")
    elseif cmd == "config" or cmd == "options" then
        if ns.Options then ns.Options.Open() end
    elseif cmd == "levels" then
        local lo, hi = tonumber(args[2]), tonumber(args[3])
        if not lo or not hi then ns.Print("usage: /salv levels 20 60") return end
        s.minLevel, s.maxLevel = lo, hi
        ns.Print("gear scan required levels: %s", (lo == 0 and hi == 0) and "all" or (lo .. "-" .. hi))
    elseif cmd == "interval" then
        local n = tonumber(args[2])
        if not n or n < 5 then ns.Print("usage: /salv interval 20 (5 or more)") return end
        s.autoInterval = n
        ns.Print("auto scan every %d s", n)
    elseif cmd == "stock" then
        local id, qty, each = parseItem(args[2]), tonumber(args[3]), Util.ParseMoney(args[4])
        if not (id and qty and each) or not Data.MATERIAL_BY_ID[id] then
            ns.Print("usage: /salv stock <material id or link> <quantity> <cost each>, e.g. /salv stock 11137 40 6s")
            return
        end
        Ledger.SetStock(ns.db.ledger, id, qty, each)
        ns.Print("%s: %d at %s each", ns.MaterialName(id), qty, ns.Money(each))
        ns.Fire("SALVAGER_LEDGER")
    elseif cmd == "report" then
        if ns.Report then ns.Report.Print() end
    elseif cmd == "results" then
        ns.Results.Toggle()
    elseif cmd == "activity" then
        ns.Activity.Toggle()
    elseif cmd == "log" then
        local n = tonumber(args[2]) or 15
        local log = ns.db.log
        for i = math.max(1, #log - n + 1), #log do ns.Print(log[i]) end
    elseif cmd == "auras" then
        if ns.Disenchant then ns.Disenchant.PrintAuras() end
    elseif cmd == "reset" and args[2] == "ledger" and args[3] == "confirm" then
        ns.db.ledger = Ledger.Init({})
        ns.Print("ledger cleared")
        ns.Fire("SALVAGER_LEDGER")
    else
        for _, line in ipairs(HELP) do ns.Print(line) end
    end
end

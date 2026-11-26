-- Salvager: namespace, saved data, settings, events, item helpers, slash commands.
local ADDON, ns = ...

local Util, Data, Model, Ledger = ns.Util, ns.Data, ns.Model, ns.Ledger

ns.NAME = ADDON
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "dev"

local DEFAULTS = {
    settings = {
        minProfit = 1000,          -- copper; deals below this profit are hidden
        minReturn = 0,             -- percent of the price a deal must make as well (0 = off)
        dealSort = "profit",       -- Deals list order: "profit" | "return"
        maxPrice = 0,              -- copper; the most to pay for one item, whatever it is worth (0 = no limit)
        levelBandsOff = {},        -- item level bands NOT scanned: { [upper item level of the band] = true }
        ilvlMin = 0,               -- item level range for the scan (0 = no limit)
        ilvlMax = 0,
        materialsDataOnly = false, -- the materials list shows only the materials you hold, list, sold or got
        cautious = false,          -- buy limits count every material at its lowest amount (1 dust, not 1.5)
        salvager = "auto",         -- "auto" | "on" | "off": add the Arcane Salvager bonus when valuing buys
        salvagerChance = 0.5,      -- chance of one extra dust or essence with the Salvager
        cut = 0.05,                -- auction house cut on sales
        priceUnits = 20,           -- material price = average of the cheapest N units
        priceMaxAge = 6 * 3600,    -- seconds before a material price counts as old (when priceRescan is 0)
        priceRescan = 10,          -- minutes: Play scans the material prices again when they are older (0 = never)
        qualities = { [2] = true, [3] = false, [4] = false },
        gearClasses = "both",      -- "weapons" | "armor" | "both"
        minLevel = 0,              -- required-level filter for the gear scan (0 = none)
        maxLevel = 0,
        autoInterval = 20,         -- seconds between gear scans in auto mode
        maxChecks = 60,            -- item searches per gear scan (best candidates first)
        autoOpen = true,           -- open the window with the auction house
        restoreWindows = true,     -- and with it the Ledger, Log and Materials windows that were open last time
        minimap = { hide = false, angle = 215 },
        postDuration = 2,          -- auction length for Post: 1, 2 or 3 (the game's three choices)
        limitOverride = {},        -- ["<quality>:<a|w>:<band>"] = copper: buy limits set by hand
    },
    prices = {},                   -- [matID] = { p = copper each, units, listings, t }
    history = {},                  -- [matID] = { { t, p, lo, n }, ... }: the price at each scan (History.lua)
    ledger = {},
    auraSeen = {},                 -- [spellID] = name, auras whose name mentions the Salvager
    auraSnapshots = {},            -- helpful auras at the first disenchants (to find the Salvager's ID)
    ilvl = {},                     -- [itemID] = item level, learned from the game (see Items.lua)
    quality = {},                  -- [itemID] = quality, learned with the item level
    log = {},                      -- what the addon did, newest last (written to disk on /reload or logout)
    window = {},
    windows = {},                  -- place and size of the Ledger and Log windows
    listings = {},                 -- your auctions as last read: { t, rows, lowest = { [itemID] = { lo, t } } }
    posted = {},                   -- posts made through Salvager: { auctionID, itemID, qty, each, t }
    money = {},                    -- the gold journal, every change of gold with its cause (Journal.lua)
}

------------------------------------------------------------------ output

function ns.Print(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cff9370dbSalvager|r: " .. msg)
end

function ns.Money(copper) return Util.FormatMoney(copper, true) end

local LOG_MAX = 5000

--- Adds a line to the activity log (SalvagerDB.log): "HH:MM:SS text". A line "== <date> ==" starts each day.
function ns.Log(fmt, ...)
    if not ns.db then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    msg = Util.PlainMoney(msg)
    local log = ns.db.log
    local day = date("%Y-%m-%d")
    if ns.db.logDay ~= day then
        ns.db.logDay = day
        log[#log + 1] = "== " .. date("%A %d %B %Y") .. " =="
    end
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

-- The auction house has one error event for every kind of request (buy, post, cancel): it belongs to the
-- request sent last. Each module notes its request when it sends it and takes an error only when it is the owner.
local lastRequest
local REQUEST_ERROR_WINDOW = 10   -- seconds: an error later than this after the request is no answer to it

function ns.NoteRequest(kind) lastRequest = { kind = kind, t = GetTime() } end

function ns.ErrorIs(kind)
    return lastRequest ~= nil and lastRequest.kind == kind and GetTime() - lastRequest.t <= REQUEST_ERROR_WINDOW
end

-- A click that cannot run now runs by itself as soon as it can (docs/UI.md, Actions 1).
-- One waiting action per label; all are dropped when the auction house closes.
local deferred = {}

--- Runs fn when ready() is true. `what` names the action, `until_` what it waits for (both for the chat).
function ns.Defer(label, ready, fn, what, until_)
    deferred[label] = { ready = ready, fn = fn }
    ns.Print("%s starts by itself when %s", what, until_)
    ns.Log("%s waits until %s", what, until_)
end

ns.OnTick(function()
    for label, d in pairs(deferred) do
        if d.ready() then
            deferred[label] = nil
            d.fn()
        end
    end
end)
ns.On("AUCTION_HOUSE_CLOSED", function() wipe(deferred) end)

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

local LINK_COLOR_QUALITY = { ["9d9d9d"] = 0, ffffff = 1, ["1eff00"] = 2, ["0070dd"] = 3, a335ee = 4, ff8000 = 5 }

--- The quality written in an item link: "|cnIQ2:" (Forever) or the quality color. nil when none.
function ns.LinkQuality(link)
    if type(link) ~= "string" then return nil end
    local q = link:match("|cnIQ(%d+):")
    if q then return tonumber(q) end
    local hex = link:match("|cff(%x%x%x%x%x%x)")
    return hex and LINK_COLOR_QUALITY[hex:lower()] or nil
end

function ns.QualityOf(linkOrID)
    local fromLink = ns.LinkQuality(linkOrID)
    if fromLink then return fromLink end
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

-- The last price seen stays in use when a scan finds no listings, for a day at most. A price is never
-- higher than its ceiling (History.Ceiling, worked out when it was scanned).
local LAST_PRICE_MAX_AGE = 24 * 3600
local function rawPrice(id)
    local e = ns.db and ns.db.prices[id]
    if not e then return nil end
    local p = e.p
    if not p and e.last and e.lastT and time() - e.lastT <= LAST_PRICE_MAX_AGE then p = e.last end
    if p and e.cap and p > e.cap then p = e.cap end
    return p
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

--- Seconds after which a material price shows as old.
function ns.PriceOldAfter()
    local every = ns.db.settings.priceRescan
    if every > 0 then return every * 60 * 2 end
    return ns.db.settings.priceMaxAge
end

-- The gear qualities, by the game's names and colors.
ns.QUALITY_NAME = { [2] = "Uncommon", [3] = "Rare", [4] = "Epic" }
ns.QUALITY_COLOR = { [2] = "|cff1eff00", [3] = "|cff0070dd", [4] = "|cffa335ee" }

--- "Uncommon armor, item level 26-30", with the game's quality color.
function ns.BandName(quality, classID, band)
    local names, colors = ns.QUALITY_NAME, ns.QUALITY_COLOR
    local list = quality == 2 and Data.GREEN or quality == 3 and Data.BLUE or quality == 4 and Data.PURPLE or {}
    local lo = 1
    for _, row in ipairs(list) do
        if row.up == band then break end
        lo = row.up + 1
    end
    return (colors[quality] or "") .. (names[quality] or "?") .. (classID == Data.CLASS_WEAPON and " Weapons" or " Armor")
        .. "|r|cffffd100, item level " .. lo .. ((band or 0) >= 999 and "+" or ("-" .. tostring(band))) .. "|r"
end

--- The short form for narrow columns: "Uncommon Armor 26-30".
function ns.BandShort(quality, classID, band)
    return (ns.BandName(quality, classID, band):gsub("|r|cffffd100, item level ", " |r|cffffd100"))
end

ns.CLASS_LABEL = { [Data.CLASS_ARMOR] = "Armor", [Data.CLASS_WEAPON] = "Weapons" }

--- A quality's name in its color: "Uncommon".
function ns.QualityText(quality)
    return (ns.QUALITY_COLOR[quality] or "") .. (ns.QUALITY_NAME[quality] or "?") .. "|r"
end

--- An item level band as its range only: "26-30", "61+".
function ns.BandRange(quality, band)
    return ns.BandName(quality, nil, band):match("item level (.-)|r$") or tostring(band)
end

--- Lists of several gear types, qualities and bands are grouped one way everywhere (the user, 2026-11-26):
--- gear type (Armor, then Weapons), quality under it (Uncommon, Rare, Epic), then each band by its range only.
--- `entries` = { { quality, classID, band, ... } }. `row(e)` = the row of one entry (its first cell is set to
--- the range); `head(list, label, level)` = a heading row for a group (level 1 = gear type, 2 = quality),
--- or nil for a plain heading. Headings have `head = true`; every row has `section` (its quality group).
--- @return table rows
--- `opts.collapsed` = { [key] = true } closes a heading (key "<classID>" or "<classID>:<quality>"): its rows
--- are left out; with it the headings get `open` (the open / close sign) and `onClick` (it flips, then
--- `opts.changed()`).
function ns.GroupedRows(entries, row, head, indent, opts)
    indent = indent or 22
    opts = opts or {}
    local collapsed = opts.collapsed
    local function toggle(h, key)
        if not collapsed then return end
        h.open = not collapsed[key]
        h.onClick = function()
            collapsed[key] = (not collapsed[key]) or nil
            if opts.changed then opts.changed() end
        end
    end
    local rows, section = {}, 0
    for _, classID in ipairs({ Data.CLASS_ARMOR, Data.CLASS_WEAPON }) do
        local ofType = {}
        for _, e in ipairs(entries) do if e.classID == classID then ofType[#ofType + 1] = e end end
        if #ofType > 0 then
            section = section + 1
            local label = "|cffffd100" .. ns.CLASS_LABEL[classID] .. "|r"
            local h = head and head(ofType, label, 1) or { cells = { label } }
            h.head, h.section = true, section
            toggle(h, tostring(classID))
            rows[#rows + 1] = h
            for _, quality in ipairs((collapsed and collapsed[tostring(classID)]) and {} or { 2, 3, 4 }) do
                local of = {}
                for _, e in ipairs(ofType) do if e.quality == quality then of[#of + 1] = e end end
                if #of > 0 then
                    section = section + 1
                    table.sort(of, function(a, b) return (a.band or 0) < (b.band or 0) end)
                    local qLabel = ns.QualityText(quality)
                    local qh = head and head(of, qLabel, 2) or { cells = { qLabel } }
                    qh.head, qh.section, qh.indent = true, section, indent
                    local qKey = classID .. ":" .. quality
                    toggle(qh, qKey)
                    rows[#rows + 1] = qh
                    for _, e in ipairs((collapsed and collapsed[qKey]) and {} or of) do
                        local r = row(e)
                        r.cells[1] = ns.BandRange(e.quality, e.band)
                        r.indent, r.section = 2 * indent, section
                        rows[#rows + 1] = r
                    end
                end
            end
        end
    end
    return rows
end

--- The item level bands, as the scan's level filter offers them: { { up, label }, ... }.
--- They are the bands of green gear: 1-15, 16-20, ... 61+.
function ns.LevelBands()
    local out, lo = {}, 1
    for _, row in ipairs(Data.GREEN) do
        out[#out + 1] = { up = row.up, label = lo .. (row.up >= 999 and "+" or ("-" .. row.up)) }
        lo = row.up + 1
    end
    return out
end

--- Does the scan look at this item level? (Its band is ticked, and it is inside the custom range.)
function ns.LevelAllowed(ilvl)
    local s = ns.db.settings
    if s.ilvlMin > 0 and ilvl < s.ilvlMin then return false end
    if s.ilvlMax > 0 and ilvl > s.ilvlMax then return false end
    for _, row in ipairs(Data.GREEN) do
        if ilvl <= row.up then return not s.levelBandsOff[row.up] end
    end
    return true
end

--- Is any scan running?
function ns.Busy()
    return (ns.Prices and ns.Prices.scanning) or (ns.Scanner and ns.Scanner.state ~= "idle") or ns.scanBothPending or false
end

--- Material prices first, then the gear scan. `clear` = asked for by a click: the Deals list starts empty.
function ns.ScanBoth(clear)
    if not ns.Queue.open then ns.Print("open the auction house first") return end
    if ns.Busy() then return end
    if clear then ns.Scanner.ClearDeals() end
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

ns.BandKey = Ledger.BandKey

--- The recommended buy limit: value after cut minus the minimum profit.
--- What a buy limit is measured from: the average value, or with cautious pricing the value with
--- every material at its lowest amount.
function ns.LimitBasis(v)
    return ns.db.settings.cautious and v.low or v.net
end

--- @return number limit, string rule ("profit" | "return")
function ns.RecommendedLimit(net)
    return Model.MaxBuy(net, ns.db.settings.minProfit, ns.db.settings.minReturn)
end

--- The buy limit in use: the one set by hand for this band, else the recommended one.
--- @return number copper, boolean manual
--- A limit set by hand is never above the value: when material prices fall, it does not buy at a loss.
function ns.BuyLimit(quality, classID, band, net)
    local o = band and ns.db.settings.limitOverride[ns.BandKey(quality, classID, band)]
    if o then return (net and math.min(o, net) or o), true end
    return (ns.RecommendedLimit(net)), false
end

--- A lose chance (0 to 1) as text: green under 30%, yellow 30% or more, red 60% or more.
function ns.LoseText(lose)
    if not lose then return "-" end
    local pct = math.floor(lose * 100 + 0.5)
    local color = pct >= 60 and "|cffff4040" or pct >= 30 and "|cffffd100" or "|cff40ff40"
    return color .. pct .. "%|r"
end

function ns.SetLimitOverride(quality, classID, band, copper)
    local key = ns.BandKey(quality, classID, band)
    ns.db.settings.limitOverride[key] = copper
    ns.Log("buy limit %s = %s", key, copper and ns.Money(copper) or "recommended")
    ns.Fire("SALVAGER_SETTINGS")
end

--- Buy limits per disenchant band, for the Limits tab.
--- @return table  rows { quality, lo, up, armor = {value, recommended, limit, manual, missing}, weapon = {...} }
--- `all` = every quality, whatever the scan looks at (the Limits tab).
function ns.Limits(all)
    local rows, s = {}, ns.db.settings
    local salv = ns.SalvagerForBuy()
    local function one(quality, classID, ilvl)
        local o = Model.Outcomes(quality, classID, ilvl)
        if not o then return nil end
        local v = Model.Value(o, ns.PriceOf, { salvager = salv, salvagerChance = s.salvagerChance, cut = s.cut })
        local basis = ns.LimitBasis(v)
        local limit, manual = ns.BuyLimit(quality, classID, o.band, basis)
        local recommended, rule = ns.RecommendedLimit(basis)
        return { value = v.net, recommended = recommended, rule = rule, limit = limit, manual = manual,
            missing = #v.missing > 0, blocked = ns.MissingMajor(v, o), quality = quality, classID = classID,
            band = o.band }
    end
    for _, q in ipairs({ { 2, Data.GREEN }, { 3, Data.BLUE }, { 4, Data.PURPLE } }) do
        if all or s.qualities[q[1]] then
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
    local doubles = Ledger.DropDoubleSales(ns.db.ledger)
    if doubles > 0 then ns.Log("ledger: removed %d sale(s) that an older version booked twice", doubles) end
    -- Windows renamed in 0.3.4: keep their place and size.
    local w = ns.db.windows
    if w.results then w.ledger, w.results = w.ledger or w.results, nil end
    if w.activity then w.log, w.activity = w.log or w.activity, nil end
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
    "/salv minreturn 15 - lowest return a deal must make as well, in percent of its price (0 = off)",
    "/salv salvager auto|on|off - Arcane Salvager bonus in buy prices",
    "/salv quality uncommon|rare|epic|both|all - which gear the scan looks at",
    "/salv gear weapons|armor|both - which item types the scan looks at",
    "/salv config - the options panel",
    "/salv levels 20 60 - required level range for the gear scan (0 0 = all)",
    "/salv interval 20 - seconds between gear scans while Play runs",
    "/salv rescan 10 - minutes after which Play scans the material prices again (0 = never)",
    "/salv stock <item> <quantity> <cost each> - opening stock, e.g. /salv stock 11137 40 6s",
    "/salv report - disenchant results by band",
    "/salv gold 24 - what happened to your gold in the last 24 hours (or any number of hours)",
    "/salv reports - the reports window (gold, profit by quality and band, materials, items)",
    "/salv auras - list your buffs (to find the Salvager's)",
    "/salv materials - the materials list in its own window (again: put it back)",
    "/salv ledger - the ledger window (purchases, sales, odds)",
    "/salv breakdown <material> - where a material came from, e.g. /salv breakdown 11083",
    "/salv log - the log window; /salv log 20 prints the last 20 lines in chat",
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
    elseif cmd == "minreturn" then
        local n = tonumber((args[2] or ""):match("^(%d+)%%?$"))
        if not n then ns.Print("usage: /salv minreturn 15 (percent, 0 = off)") return end
        s.minReturn = n
        ns.Print("minimum return: %s", n > 0 and (n .. "%") or "off")
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
    elseif cmd == "rescan" then
        local n = tonumber(args[2])
        if not n or n < 0 then ns.Print("usage: /salv rescan 10 (minutes, 0 = never)") return end
        s.priceRescan = math.floor(n)
        ns.Print(n > 0 and "Play scans the material prices again when they are older than %d min"
            or "Play never scans the material prices again", n)
        ns.Fire("SALVAGER_SETTINGS")
    elseif cmd == "stock" then
        local id, qty, each = parseItem(args[2]), tonumber(args[3]), Util.ParseMoney(args[4])
        if not (id and qty and each) or not Data.MATERIAL_BY_ID[id] then
            ns.Print("usage: /salv stock <material id or link> <quantity> <cost each>, e.g. /salv stock 11137 40 6s")
            return
        end
        Ledger.SetStock(ns.db.ledger, id, qty, each)
        ns.Print("%s: %d at %s each", ns.MaterialName(id), qty, ns.Money(each))
        ns.Fire("SALVAGER_LEDGER")
    elseif cmd == "gold" then
        local h = tonumber(args[2] or "24")
        if not h or h <= 0 then ns.Print("usage: /salv gold 24 (hours)") return end
        ns.Gold.Report(h)
    elseif cmd == "reports" then
        ns.Reports.Toggle()
    elseif cmd == "report" then
        if ns.Report then ns.Report.Print() end
    elseif cmd == "materials" then
        if ns.Materials.IsPoppedOut() then ns.Materials.PutBack() else ns.Materials.PopOut() end
    elseif cmd == "breakdown" then
        local id = parseItem(args[2])
        if not (id and ns.Breakdown.Is(id)) then ns.Print("usage: /salv breakdown <material id or link>") return end
        ns.Breakdown.Open(id)
    elseif cmd == "ledger" or cmd == "results" then
        ns.LedgerWindow.Toggle()
    elseif cmd == "log" and not tonumber(args[2]) or cmd == "activity" then
        ns.LogWindow.Toggle()
    elseif cmd == "log" then
        local n = tonumber(args[2])
        local log = ns.db.log
        for i = math.max(1, #log - n + 1), #log do ns.Print(log[i]) end
    elseif cmd == "auras" then
        if ns.Disenchant then ns.Disenchant.PrintAuras() end
    elseif cmd == "reset" and args[2] == "ledger" and args[3] == "confirm" then
        ns.db.ledger = Ledger.Reset(ns.db.ledger)
        ns.Print("ledger cleared")
        ns.Fire("SALVAGER_LEDGER")
    else
        for _, line in ipairs(HELP) do ns.Print(line) end
    end
end

-- Salvager: namespace, saved data, settings, events, item helpers, slash commands.
local ADDON, ns = ...

local Util, Data, Model, Ledger = ns.Util, ns.Data, ns.Model, ns.Ledger

ns.NAME = ADDON
ns.VERSION = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON, "Version")) or "dev"

local DEFAULTS = {
    settings = {
        minProfit = 1000,          -- copper; deals below this profit are hidden
        minReturn = 0,             -- percent of the price a deal must make as well (0 = off)
        dealSort = "profit",       -- Gear tab order: "profit" | "return"
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
        timeZone = "local",        -- "local" | "server": the clock every shown time follows (SDD 110)
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
    sessions = {},                 -- sessions from login to logout, and the stock's value at each (Statement.lua)
    groups = {},                   -- [table] = { [heading] = true }: group headings not in their first state (ns.GroupState)
    competition = {},              -- who undercuts you, and the profit lost to them (Competition.lua, SDD 109)
}

------------------------------------------------------------------ output

function ns.Print(fmt, ...)
    local msg = select("#", ...) > 0 and string.format(fmt, ...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("|cff9370dbSalvager|r: " .. msg)
end

function ns.Money(copper) return Util.FormatMoney(copper, true) end
--- Money in a column of amounts (a statement): every unit under the largest one, two digits each.
function ns.MoneyColumn(copper) return Util.FormatMoney(copper, true, true) end

------------------------------------------------------------------ times (SDD 110)

-- Every shown time goes through ns.Date: the computer's clock, or the realm's (Options, "Times shown in").
-- Saved times stay Unix time; only the text changes. The realm's offset from UTC is measured at login and every
-- hour (a daylight saving change of the realm shows within the hour).
local SERVER_CHECK = 3600   -- s between two readings of the realm's clock
local serverOffset          -- s: the realm's clock minus UTC (Util.ServerOffset); nil until read
local serverTried = false

-- The realm's clock now: the game's calendar time (with the date), else GetGameTime (hours and minutes).
local function serverClock()
    if C_DateAndTime and C_DateAndTime.GetCurrentCalendarTime then
        local ok, c = pcall(C_DateAndTime.GetCurrentCalendarTime)
        if ok and type(c) == "table" and type(c.year) == "number" and c.year >= 2000 then return c end
    end
    if GetGameTime then
        local ok, h, m = pcall(GetGameTime)
        if ok and type(h) == "number" and type(m) == "number" then return { hour = h, minute = m } end
    end
    return nil
end

--- Reads the realm's clock again. When its offset changed while times follow it, the windows draw again (not with
--- `quiet`: the first reading, made while a window draws).
--- @return number|nil the realm's offset from UTC in seconds
function ns.MeasureServerTime(quiet)
    serverTried = true
    local offset = Util.ServerOffset(time(), serverClock())
    if offset == nil or offset == serverOffset then return serverOffset end
    local was = serverOffset
    serverOffset = offset
    ns.Log("server time: %s%s", Util.OffsetName(offset), was and (" (was " .. Util.OffsetName(was) .. ")") or "")
    if not quiet and ns.db and ns.db.settings.timeZone == "server" then ns.Fire("SALVAGER_SETTINGS") end
    return offset
end

--- The offset ns.Date applies: nil = local time; else seconds from UTC (server time, once the realm's clock is known).
function ns.TimeOffset()
    if not (ns.db and ns.db.settings.timeZone == "server") then return nil end
    if serverOffset == nil and not serverTried then ns.MeasureServerTime(true) end
    return serverOffset
end

--- A shown time (`date` formats) on the clock the Times option picks. `t` defaults to now.
function ns.Date(fmt, t) return Util.Date(fmt, t or time(), ns.TimeOffset()) end
--- "HH:MM" of a time on that clock.
function ns.Clock(t) return ns.Date("%H:%M", t) end
--- "server time" or "local time": the clock the shown times follow now.
function ns.TimesName() return ns.TimeOffset() ~= nil and "server time" or "local time" end
--- The sentence the help on time titles ends with.
function ns.TimesNote()
    if ns.TimeOffset() ~= nil then
        return "Times in server time (the realm's clock, " .. Util.OffsetName(serverOffset) .. "): Options, Times shown in."
    end
    return "Times in local time (your computer's clock): Options, Times shown in."
end
--- Help for a time column's title: `text`, then which clock (read when the help shows).
function ns.TimeHelp(title, text)
    return { title, function() return (text and (text .. " ") or "") .. ns.TimesNote() end }
end

local function measureEveryHour()
    ns.MeasureServerTime()
    C_Timer.After(SERVER_CHECK, measureEveryHour)
end

local LOG_MAX = 5000

--- Adds a line to the activity log (SalvagerDB.log): "HH:MM:SS text". A line "== <date> ==" starts each day.
function ns.Log(fmt, ...)
    if not ns.db then return end
    local ok, msg = pcall(string.format, fmt, ...)
    if not ok then msg = tostring(fmt) end
    msg = Util.PlainMoney(msg)
    local log = ns.db.log
    local day = ns.Date("%Y-%m-%d")
    if ns.db.logDay ~= day then
        ns.db.logDay = day
        log[#log + 1] = "== " .. ns.Date("%A %d %B %Y") .. " =="
    end
    log[#log + 1] = ns.Date("%H:%M:%S") .. " " .. msg
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

-- The realm's clock (ns.Date): read at login (and at each loading screen), then every hour.
local measuring = false
ns.On("PLAYER_ENTERING_WORLD", function()
    if measuring then ns.MeasureServerTime() return end
    measuring = true
    measureEveryHour()
end)

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

------------------------------------------------------------------ forecast (SDD 3, 96)

-- The sell price ratios and deposit rates, worked out when first asked for after the ledger or the prices changed.
local forecast

local function priceAt(id, t)
    return (Model.PairPrice(id, function(x) return ns.History.At(ns.db.history, x, t) end))
end

-- The material's value when a sale was posted: the post of that material at that price each made before the
-- sale (SalvagerDB.posted: its own `val`, else the price history then), else the value at the sale. Kept on the
-- sale (`val`), so it is looked up once.
local function valueAtPost(s)
    local each = s.each or (s.gross / s.count)
    local t = s.t or 0
    local posted = ns.db.posted or {}
    local v
    for i = #posted, 1, -1 do
        local p = posted[i]
        if p.itemID == s.id and p.each and math.abs(p.each - each) < 1 and (p.t or 0) <= t then
            v, t = p.val, p.t
            break
        end
    end
    v = v or priceAt(s.id, t)
    s.val = v
    return v
end

--- The deposit of one unit in one post: from your posts of it, else from the game (the post duration you use).
--- @return number|nil copper (may be a fraction)
function ns.UnitDeposit(id)
    local c, q = 0, 0
    for _, p in ipairs(ns.db.posted or {}) do
        if p.itemID == id and p.deposit and (p.qty or 0) > 0 then c, q = c + p.deposit, q + p.qty end
    end
    if q > 0 then return c / q end
    local AH = C_AuctionHouse
    if AH and AH.CalculateCommodityDeposit then
        local ok, d = pcall(AH.CalculateCommodityDeposit, id, ns.db.settings.postDuration, 1)
        if ok and tonumber(d) then return tonumber(d) end
    end
    return nil
end

local function forecastData()
    if not forecast then
        local deposits = {}
        local function unit(id)
            if deposits[id] == nil then deposits[id] = ns.UnitDeposit(id) or false end
            return deposits[id] or nil
        end
        forecast = {
            ratios = Ledger.SellRatios(ns.db.ledger, valueAtPost, time()),
            deposits = Ledger.DepositRates(ns.db.ledger, unit, time()),
            unit = unit,
            times = Ledger.TimesToSell(ns.db.ledger, ns.db.posted, time()),
            results = Ledger.Results(ns.db.ledger),
            blended = {},
        }
    end
    return forecast
end

function ns.ForecastChanged() forecast = nil end
for _, event in ipairs({ "SALVAGER_LEDGER", "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS" }) do
    ns.On(event, ns.ForecastChanged)
end

--- The sell price ratio of a material: what one unit sells for against its value (SDD 3).
--- @return table { ratio, n (your sales of it in the last 30 days), few (fewer than Ledger.FORECAST_MIN_SALES) }
function ns.SellRatio(id)
    local r = forecastData().ratios
    return r[id] or { ratio = r.all.ratio, n = 0, few = true }
end

--- Time to sell of a material (SDD 100): post to sale, the median of your sales of the last 30 days.
--- @return table { seconds (nil: no sale of any material), n (its sales), few }
function ns.TimeToSell(id)
    local t = forecastData().times
    return t[id] or { seconds = t.all.seconds, n = 0, few = true }
end

local function timeOf(id)
    local x = ns.TimeToSell(id)
    return x.seconds, x.few
end

--- A time in seconds as text: "< 1 min", "12 min", "3 h 05 min", "2 d 4 h".
function ns.DurationText(seconds)
    if not seconds then return "-" end
    if seconds < 60 then return "< 1 min" end
    local m = math.floor(seconds / 60 + 0.5)
    if m < 60 then return m .. " min" end
    if m < 48 * 60 then return string.format("%d h %02d min", math.floor(m / 60), m % 60) end
    local h = math.floor(m / 60 + 0.5)
    return string.format("%d d %d h", math.floor(h / 24), h % 24)
end

--- Time to sell as text, grey with "(few sales)" when it rests on few sales (UI.md Data 2).
function ns.TimeToSellText(id)
    local x = ns.TimeToSell(id)
    if not x.seconds then return "|cff808080-|r" end
    local text = ns.DurationText(x.seconds)
    if x.few then return "|cff808080" .. text .. " (few sales)|r" end
    return text
end

--- Days until the materials of one disenchant sell (Model.DaysToSell over its value parts), at least 1.
--- @return number|nil days, boolean few, number|nil seconds (before the 1 day floor)
function ns.DaysToSell(parts) return Model.DaysToSell(parts, timeOf) end

--- What one disenchant of this band gives, as the forecast counts it (SDD 99): the table blended with your own
--- results of the band with the same Salvager state. `salvager` nil = as for buying.
--- @return table|nil outcomes (Model.Blended)
function ns.Outcomes(quality, classID, ilvl, salvager)
    local o = Model.Outcomes(quality, classID, ilvl)
    if not o then return nil end
    if salvager == nil then salvager = ns.SalvagerForBuy() end
    local f = forecastData()
    local key = Ledger.BandKey(quality, classID, o.band)
    local cacheKey = key .. (salvager and ":s" or "")
    if not f.blended[cacheKey] then
        local seen = f.results[key]
        f.blended[cacheKey] = Model.Blended(o, seen and seen[salvager and "on" or "off"],
            { salvager = salvager, salvagerChance = ns.db.settings.salvagerChance })
    end
    return f.blended[cacheKey]
end

--- Deposits lost per unit sold of a material, copper.
--- @return number copper, table|nil its rate (Ledger.DepositRates), number share of one post's deposit
function ns.DepositPerUnit(id)
    local f = forecastData()
    local rate = f.deposits[id]
    local k = rate and rate.k or f.deposits.all.k
    return k * (f.unit(id) or 0), rate, k
end

--- What one unit of a material is worth to the forecast: price × sell price ratio, after the cut, less the
--- deposits lost per unit sold (Model.UnitValue). The statement's stock and the Reports' Materials value use it.
function ns.UnitValue(id) return Model.UnitValue(id, ns.PriceOf, ns.ValueOptions()) end

--- The sell price ratio as text: "99.8%", grey with "(few sales)" when it rests on few sales (UI.md Data 2).
function ns.SellRatioText(id)
    local r = ns.SellRatio(id)
    local text = string.format("%.1f%%", r.ratio * 100)
    if r.few then return "|cff808080" .. text .. " (few sales)|r" end
    return text
end

local function ratioOf(id) return ns.SellRatio(id).ratio end
local function depositOf(id) return (ns.DepositPerUnit(id)) end

--- The options of the forecast (Model.Value, Model.LossChance): the Salvager bonus, the cut, the sell price
--- ratio and the deposits lost. `salvager` nil = as for buying.
function ns.ValueOptions(salvager)
    local s = ns.db.settings
    if salvager == nil then salvager = ns.SalvagerForBuy() end
    return { salvager = salvager, salvagerChance = s.salvagerChance, cut = s.cut, ratio = ratioOf, deposit = depositOf }
end

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
    local opts = ns.ValueOptions(salvager)
    local outcomes = ns.Outcomes(quality, classID, ilvl, opts.salvager)
    if not outcomes then return nil end
    local v = Model.Value(outcomes, ns.PriceOf, opts)
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

--- Group headings that open and close (UI.md Tables 15), the one way for every table: the state of one table's
--- headings, kept in the saved data. SalvagerDB.groups[id] = { [key] = true } for each heading that is not in the
--- table's first state (closed where headings start open, open where they start closed).
function ns.GroupState(id)
    local all = ns.db.groups
    all[id] = all[id] or {}
    return all[id]
end

--- Makes `row` a heading that opens and closes: `row.open` (its arrow: Widgets.GroupArrow) and `row.onClick` (a click
--- anywhere on the row flips it in `state`, then `changed()`). `closedFirst`: the heading starts closed.
--- @return boolean open
function ns.HeadingToggle(row, state, key, changed, closedFirst)
    local flipped = state[key] and true or false
    local open = (closedFirst and flipped) or (not closedFirst and not flipped)
    row.open = open
    row.onClick = function()
        state[key] = (not state[key]) or nil
        if changed then changed() end
    end
    return open
end

--- Lists of several gear types, qualities and bands are grouped one way everywhere (the user, 2026-11-26):
--- gear type (Armor, then Weapons), quality under it (Uncommon, Rare, Epic), then each band by its range only.
--- `entries` = { { quality, classID, band, ... } }. `row(e)` = the row of one entry (its first cell is set to
--- the range); `head(list, label, level)` = a heading row for a group (level 1 = gear type, 2 = quality),
--- or nil for a plain heading. Headings have `head = true`; every row has `section` (its quality group).
--- @return table rows
--- `opts.collapsed` = { [key] = true } closes a heading (key "<classID>" or "<classID>:<quality>"): its rows
--- are left out; with it the headings open and close (ns.HeadingToggle: `open`, `onClick`, then `opts.changed()`).
--- Pass ns.GroupState(<table>) so the state is remembered.
function ns.GroupedRows(entries, row, head, indent, opts)
    indent = indent or 22
    opts = opts or {}
    local collapsed = opts.collapsed
    local function toggle(h, key)
        if collapsed then ns.HeadingToggle(h, collapsed, key, opts.changed) end
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

--- Material prices first, then the gear scan. `clear` = asked for by a click: the Gear list starts empty.
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

--- Buy limits per disenchant band, for the Limits window.
--- @return table  rows { quality, lo, up, armor = {value, recommended, limit, manual, missing}, weapon = {...} }
--- `all` = every quality, whatever the scan looks at (the Limits window).
function ns.Limits(all)
    local rows, s = {}, ns.db.settings
    local opts = ns.ValueOptions()
    local function one(quality, classID, ilvl)
        local o = ns.Outcomes(quality, classID, ilvl, opts.salvager)
        if not o then return nil end
        local v = Model.Value(o, ns.PriceOf, opts)
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
    ns.Competition.Init(ns.db.competition)
    local doubles = Ledger.DropDoubleSales(ns.db.ledger)
    if doubles > 0 then ns.Log("ledger: removed %d sale(s) that an older version booked twice", doubles) end
    if Ledger.NeedsRecost(ns.db.ledger) then
        ns.Backup.Save("before sharing the costs per band")
        local n, sold = Ledger.Recost(ns.db.ledger)
        ns.Log("ledger: material costs shared per band once (%d disenchants, %d sales booked again)", n, sold)
    end
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
    "/salv gear weapons|armor|both - which gear types the scan looks at",
    "/salv config - the options panel",
    "/salv levels 20 60 - required level range for the gear scan (0 0 = all)",
    "/salv interval 20 - seconds between gear scans while Play runs",
    "/salv rescan 10 - minutes after which Play scans the material prices again (0 = never)",
    "/salv stock <material> <quantity> <cost each> - opening stock, e.g. /salv stock 11137 40 6s",
    "/salv report - disenchant results by band",
    "/salv gold 24 - what happened to your gold in the last 24 hours (or any number of hours)",
    "/salv reports - the reports window (gold; gear by band and piece by piece; materials)",
    "/salv auras - list your buffs (to find the Salvager's)",
    "/salv materials - the materials list in its own window (again: put it back)",
    "/salv ledger - the ledger window (purchases, sales, odds)",
    "/salv breakdown <material> - where a material came from, e.g. /salv breakdown 11083",
    "/salv log - the log window; /salv log 20 prints the last 20 lines in chat",
    "/salv reset ledger confirm - clear all purchases, stock and history (a backup is kept)",
    "/salv restore - put the last ledger backup back (it asks first)",
    "/salv windows reset - every Salvager window back on the screen, at its default place",
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
    elseif cmd == "windows" and (args[2] or ""):lower() == "reset" then
        ns.Widgets.ResetWindows()
        ns.Print("every window is back on the screen, at its default place")
    elseif cmd == "restore" then
        ns.Backup.AskRestore()
    elseif cmd == "reset" and args[2] == "ledger" and args[3] == "confirm" then
        ns.Backup.Save("before /salv reset ledger")
        ns.db.ledger = Ledger.Reset(ns.db.ledger)
        ns.Competition.Clear(ns.db.competition)
        ns.Print("ledger cleared")
        ns.Fire("SALVAGER_LEDGER")
    else
        for _, line in ipairs(HELP) do ns.Print(line) end
    end
end

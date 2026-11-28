-- Salvager: small helpers with no game dependencies (money text, tables).
local _, ns = ...
ns = ns or {}

local Util = {}
ns.Util = Util

local SILVER, GOLD = 100, 10000

Util.COIN = {
    g = "|TInterface\\MoneyFrame\\UI-GoldIcon:0:0:2:0|t",
    s = "|TInterface\\MoneyFrame\\UI-SilverIcon:0:0:2:0|t",
    c = "|TInterface\\MoneyFrame\\UI-CopperIcon:0:0:2:0|t",
}

--- Replaces coin icons with g, s and c (for the log).
function Util.PlainMoney(text)
    return (text:gsub("|TInterface\\MoneyFrame\\UI%-(%a+)Icon[^|]*|t", function(kind)
        return kind == "Gold" and "g" or kind == "Silver" and "s" or "c"
    end))
end

--- "1g 2s 3c" style text for a copper amount. Negative amounts get a minus sign.
--- With `icons`, coin icons replace the letters.
--- `aligned`: the form for a column of amounts (UI.md Tables 8): every unit under the largest one is shown, with two
--- digits ("12g 05s 00c", "5s 03c"), so right-aligned amounts keep their coins under each other.
-- (The texts made, per form: a table of thousands of rows asks for the same amounts again on every refresh.
-- Bounded: emptied past MONEY_MEMO_MAX.)
local MONEY_MEMO_MAX = 4096
local moneyMemo, moneyMemoN = { {}, {}, {}, {} }, 0
local formatMoney
function Util.FormatMoney(copper, icons, aligned)
    if copper == nil then return "-" end
    copper = math.floor(copper + 0.5)
    local memo = moneyMemo[(icons and 2 or 1) + (aligned and 2 or 0)]
    local text = memo[copper]
    if text then return text end
    if moneyMemoN >= MONEY_MEMO_MAX then
        moneyMemo, moneyMemoN = { {}, {}, {}, {} }, 0
        memo = moneyMemo[(icons and 2 or 1) + (aligned and 2 or 0)]
    end
    text = formatMoney(copper, icons, aligned)
    memo[copper], moneyMemoN = text, moneyMemoN + 1
    return text
end

function formatMoney(copper, icons, aligned)
    local sign = ""
    if copper < 0 then sign, copper = "-", -copper end
    local g = math.floor(copper / GOLD)
    local s = math.floor((copper % GOLD) / SILVER)
    local c = copper % SILVER
    local G, S, C = "g", "s", "c"
    if icons then G, S, C = Util.COIN.g, Util.COIN.s, Util.COIN.c end
    local parts = {}
    if aligned then
        if g > 0 then parts[1] = g .. G end
        if g > 0 then parts[#parts + 1] = string.format("%02d", s) .. S elseif s > 0 then parts[#parts + 1] = s .. S end
        parts[#parts + 1] = ((g > 0 or s > 0) and string.format("%02d", c) or tostring(c)) .. C
        return sign .. table.concat(parts, " ")
    end
    if g > 0 then parts[#parts + 1] = g .. G end
    if s > 0 or (g > 0 and c > 0) then parts[#parts + 1] = s .. S end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. C end
    return sign .. table.concat(parts, " ")
end

--- Money in a short form for a range of three amounts in one cell (the Gear list's profit, SDD 116): from 1 gold up,
--- gold and silver (rounded to the silver, two digits); below, silver and copper. With its sign ("+" or "-") when
--- `signed`.
function Util.MoneyShort(copper, icons, signed)
    if copper == nil then return "-" end
    copper = math.floor(copper + 0.5)
    local sign = copper < 0 and "-" or (signed and copper > 0 and "+" or "")
    copper = math.abs(copper)
    if copper >= GOLD then
        local silver = math.floor(copper / SILVER + 0.5)
        local G, S = "g", "s"
        if icons then G, S = Util.COIN.g, Util.COIN.s end
        return string.format("%s%d%s %02d%s", sign, math.floor(silver / 100), G, silver % 100, S)
    end
    return sign .. Util.FormatMoney(copper, icons)
end

--- A table cell's money in short (UI.md Tables 2, SDD 120): every amount of 1 gold or more in `text` loses its copper
--- ("12g 34s 56c" -> "12g 35s", rounded to the silver), the coins as icons or letters, any color and sign kept.
--- The full amount goes in the row's hover. Returns the text, and true when it changed.
local function escaped(s) return (s:gsub("%p", "%%%0")) end
local SHORT_PATTERNS = {}
for _, set in ipairs({ { Util.COIN.g, Util.COIN.s, Util.COIN.c }, { "g", "s", "c" } }) do
    SHORT_PATTERNS[#SHORT_PATTERNS + 1] = { "(%d+)" .. escaped(set[1]) .. " (%d+)" .. escaped(set[2]) .. " (%d+)"
        .. escaped(set[3]), set[1], set[2] }
end
function Util.ShortMoneyText(text)
    if type(text) ~= "string" then return text, false end
    local changed = false
    for _, p in ipairs(SHORT_PATTERNS) do
        text = text:gsub(p[1], function(g, s, c)
            local silver = tonumber(g) * 100 + tonumber(s) + (tonumber(c) >= 50 and 1 or 0)
            changed = true
            return string.format("%d%s %02d%s", math.floor(silver / 100), p[2], silver % 100, p[3])
        end)
    end
    return text, changed
end

--- Parses "1g50s", "20s", "35c", "1g 2s 3c". A bare number means silver.
--- Returns copper, or nil when the text is not money.
function Util.ParseMoney(text)
    if type(text) == "number" then return math.floor(text * SILVER + 0.5) end
    if type(text) ~= "string" then return nil end
    local t = text:lower():gsub("%s+", "")
    if t == "" then return nil end
    local bare = tonumber(t)
    if bare then return math.floor(bare * SILVER + 0.5) end
    local total, rest = 0, t
    for _, unit in ipairs({ { "g", GOLD }, { "s", SILVER }, { "c", 1 } }) do
        local num, after = rest:match("^([%d%.]+)" .. unit[1] .. "(.*)$")
        if num then
            total = total + math.floor(tonumber(num) * unit[2] + 0.5)
            rest = after
        end
    end
    if rest ~= "" then return nil end
    return total
end

--- The value a table cell sorts by (UI.md Tables 10), from its full text (before Widgets.CellText shortens money):
--- money with coin icons -> copper; "12%" -> 12; a number (signed, decimals) -> the number; a range "a - b - c" of
--- money -> its middle part (the average); "MM-DD HH:MM" -> a number in time order; "3d 4h", "12m", "1h 05m" -> seconds;
--- "" and "-" -> nil (unknown: last both ways); any other text -> its lowercase letters without color codes, links
--- or icons. Returns the value and its kind ("number" or "text").
local function plain(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", ""):gsub("|T.-|t", "")
        :gsub("^%s+", ""):gsub("%s+$", ""))
end
local function moneyOf(text)
    local t = Util.PlainMoney(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("[%*!]", "")
        :gsub("^%s+", ""):gsub("%s+$", "")
    local sign, rest = t:match("^([%+%-]?)(.*)$")
    local total, any = 0, false
    for _, unit in ipairs({ { "g", GOLD }, { "s", SILVER }, { "c", 1 } }) do
        local num, after = rest:match("^(%d+)" .. unit[1] .. "%s*(.*)$")
        if num then total, rest, any = total + tonumber(num) * unit[2], after, true end
    end
    if not any or rest ~= "" then return nil end
    return sign == "-" and -total or total
end
function Util.SortValue(text)
    if type(text) == "number" then return text, "number" end
    if type(text) ~= "string" then return nil end
    if text:find("Interface\\MoneyFrame", 1, true) then
        -- A range "low - avg - high": its average (the middle).
        local parts = {}
        for part in (text .. " - "):gmatch("(.-) %- ") do parts[#parts + 1] = part end
        if #parts == 3 then
            local mid = moneyOf(parts[2])
            if mid then return mid, "number" end
        end
        local m = moneyOf(text)
        if m then return m, "number" end
    end
    local t = plain(text):gsub("[%*!]+$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if t == "" or t == "-" then return nil end
    local n = tonumber((t:gsub("%%$", "")))
    if n then return n, "number" end
    local mo, d, h, mi = t:match("^(%d%d)%-(%d%d) (%d%d):(%d%d)$")
    if mo then return ((tonumber(mo) * 31 + tonumber(d)) * 24 + tonumber(h)) * 60 + tonumber(mi), "number" end
    if t:find("^%d+[dhms]") then
        local secs, rest = 0, t
        for _ = 1, 4 do
            local num, unit, after = rest:match("^(%d+)%s*([dhms])%s*(.*)$")
            if not num then break end
            secs = secs + tonumber(num) * ({ d = 86400, h = 3600, m = 60, s = 1 })[unit]
            rest = after
        end
        if rest == "" then return secs, "number" end
    end
    return t:lower(), "text"
end

--- Shallow copy of defaults into t for keys t does not have (tables copied deep).
function Util.Defaults(t, defaults)
    for k, v in pairs(defaults) do
        if t[k] == nil then
            if type(v) == "table" then
                t[k] = Util.Defaults({}, v)
            else
                t[k] = v
            end
        elseif type(v) == "table" and type(t[k]) == "table" then
            Util.Defaults(t[k], v)
        end
    end
    return t
end

--- Something kept was dropped by a bound: `n` entries of `what`, `max` kept. Calls Util.OnDrop(what, n, max) when
--- the game glue has set it (Core logs it), so no bound drops data silently.
function Util.Dropped(what, n, max)
    if n > 0 and what and Util.OnDrop then Util.OnDrop(what, n, max) end
end

--- Keeps at most `max` entries in an array, dropping the oldest (front). `what` (what the entries are, for the
--- Log): the drop is reported (Util.Dropped). @return number entries dropped
function Util.Cap(list, max, what)
    local extra = #list - max
    if extra <= 0 then return 0 end
    for _ = 1, extra do table.remove(list, 1) end
    Util.Dropped(what, extra, max)
    return extra
end

--- A copy of a table and every table in it (no shared parts). Other values are returned as they are.
function Util.Copy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local out = {}
    seen[v] = out
    for k, x in pairs(v) do out[Util.Copy(k, seen)] = Util.Copy(x, seen) end
    return out
end

--- About how many bytes a value takes in the game's saved data file (each key and value as the game writes
--- them: ["key"] = value, one per line).
function Util.SavedSize(v, seen)
    local t = type(v)
    if t == "string" then return #v + 2 end
    if t == "number" then return #tostring(v) end
    if t == "boolean" then return v and 4 or 5 end
    if t ~= "table" then return 3 end
    seen = seen or {}
    if seen[v] then return 0 end
    seen[v] = true
    local n = 4   -- "{", "}" and their line ends
    for k, x in pairs(v) do
        n = n + Util.SavedSize(k, seen) + 2 + 3 + Util.SavedSize(x, seen) + 2   -- [k] = x,
    end
    return n
end

--- "12.3 KB", "1.40 MB".
function Util.FormatBytes(n)
    if n >= 1024 * 1024 then return string.format("%.2f MB", n / 1024 / 1024) end
    return string.format("%.1f KB", n / 1024)
end

------------------------------------------------------------------ times (SDD 110)

--- A time as text (`date` formats). `offset` nil: the computer's local time (its own DST rules for `t`);
--- else the clock `offset` seconds ahead of UTC (the realm's clock, Util.ServerOffset).
--- The one place a shown time is made: every window calls it through ns.Date.
function Util.Date(fmt, t, offset)
    local dateOf = date or os.date   -- (the game's `date`; the tests' Lua has os.date)
    if offset == nil then return dateOf(fmt, t) end
    return dateOf("!" .. fmt, t + offset)
end

-- Days from 1970-01-01 to a calendar date (proleptic Gregorian; H. Hinnant's days_from_civil).
local function daysFromCivil(year, month, day)
    local y = month <= 2 and year - 1 or year
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local doy = math.floor((153 * (month + (month > 2 and -3 or 9)) + 2) / 5) + day - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end
Util.DaysFromCivil = daysFromCivil

Util.OFFSET_STEP = 900          -- s: a time zone is a whole number of quarter hours
Util.OFFSET_MAX = 14 * 3600     -- s: no time zone is further from UTC

--- The realm's clock against UTC, in seconds, rounded to the nearest quarter hour; nil when `clock` makes no sense.
--- `now` = Unix time (UTC); `clock` = the realm's clock now: { year, month, monthDay, hour, minute } (the game's
--- CalendarTime) or { hour, minute } only (GetGameTime: the nearest day is taken, so within 12 hours of UTC).
function Util.ServerOffset(now, clock)
    if type(clock) ~= "table" or type(clock.hour) ~= "number" or type(clock.minute) ~= "number" then return nil end
    local d
    if type(clock.year) == "number" and type(clock.month) == "number" and type(clock.monthDay) == "number" then
        d = daysFromCivil(clock.year, clock.month, clock.monthDay) * 86400 + clock.hour * 3600 + clock.minute * 60 - now
    else
        d = (clock.hour * 3600 + clock.minute * 60 - now % 86400) % 86400
        if d >= 43200 then d = d - 86400 end
    end
    d = math.floor(d / Util.OFFSET_STEP + 0.5) * Util.OFFSET_STEP
    if math.abs(d) > Util.OFFSET_MAX then return nil end
    return d
end

--- "UTC+1", "UTC-5:30", "UTC" for an offset in seconds.
function Util.OffsetName(offset)
    if offset == 0 then return "UTC" end
    local m = math.floor(math.abs(offset) / 60 + 0.5)
    local text = (offset < 0 and "UTC-" or "UTC+") .. math.floor(m / 60)
    if m % 60 ~= 0 then text = text .. string.format(":%02d", m % 60) end
    return text
end

return Util

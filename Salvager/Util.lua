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
function Util.FormatMoney(copper, icons, aligned)
    if copper == nil then return "-" end
    copper = math.floor(copper + 0.5)
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

--- Keeps at most `max` entries in an array, dropping the oldest (front).
function Util.Cap(list, max)
    local extra = #list - max
    if extra <= 0 then return end
    for _ = 1, extra do table.remove(list, 1) end
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

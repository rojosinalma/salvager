-- Salvager: small helpers with no game dependencies (money text, tables).
local _, ns = ...
ns = ns or {}

local Util = {}
ns.Util = Util

local SILVER, GOLD = 100, 10000

--- "1g 2s 3c" style text for a copper amount. Negative amounts get a minus sign.
function Util.FormatMoney(copper)
    if copper == nil then return "-" end
    copper = math.floor(copper + 0.5)
    local sign = ""
    if copper < 0 then sign, copper = "-", -copper end
    local g = math.floor(copper / GOLD)
    local s = math.floor((copper % GOLD) / SILVER)
    local c = copper % SILVER
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 or (g > 0 and c > 0) then parts[#parts + 1] = s .. "s" end
    if c > 0 or #parts == 0 then parts[#parts + 1] = c .. "c" end
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

return Util

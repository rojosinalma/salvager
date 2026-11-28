-- Salvager: the activity log (SDD 129). SalvagerDB.log holds records, oldest first:
--   { t = Unix time, lvl = "ERROR" | "WARN" | "INFO" | "DEBUG", cat = one word (Log.CATEGORIES),
--     msg = one short sentence for the player (names, money as coins), kv = { key = value } for the agent }
-- One API: ns.Log(lvl, cat, msg, kv). The old form ns.Log(fmt, ...) still works (a shim, until every call site is
-- moved): INFO, category "ui" (or the category word its text starts with, "ledger: ..."), ERROR where the text
-- starts with "ERROR". The window draws the records (LogView.lua); ns.LogExport gives them as logfmt lines.
local _, ns = ...

local Util = ns.Util

local Log = {}
ns.LogBook = Log

Log.MAX = 5000   -- records kept; the oldest go first (Util.Cap, with its drop line)
Log.LEVELS = { "ERROR", "WARN", "INFO", "DEBUG" }
Log.RANK = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4 }
Log.CATEGORIES = { "session", "scan", "search", "buy", "mail", "disenchant", "post", "sale", "ledger", "books", "gold",
    "competition", "layout", "ui", "options" }
Log.IS_CATEGORY = {}
for _, c in ipairs(Log.CATEGORIES) do Log.IS_CATEGORY[c] = true end
local DUMP_LINES = 200   -- ERROR and WARN lines in the layout dump, the newest
local MONTHS = { January = 1, February = 2, March = 3, April = 4, May = 5, June = 6, July = 7, August = 8,
    September = 9, October = 10, November = 11, December = 12 }

--- The offset from UTC of the computer's clock at `t`, in seconds.
function Log.LocalOffset(t)
    local d = (date or os.date)("*t", t)   -- not shown: the computer's clock against UTC
    return Util.DaysFromCivil(d.year, d.month, d.day) * 86400 + d.hour * 3600 + d.min * 60 + d.sec - t
end

--- The offset of the clock the shown times follow (Options, Times shown in) at `t`.
local function shownOffset(t) return ns.TimeOffset() or Log.LocalOffset(t) end

--- An old text line's level, category and message: ERROR where it starts with "ERROR", the category word it starts
--- with ("ledger: ..."), else INFO and "ui".
function Log.Classify(text)
    local lvl = "INFO"
    local rest = text:match("^ERROR:? (.*)")
    if rest then lvl, text = "ERROR", rest end
    local word, after = text:match("^(%a+): (.*)")
    if word and Log.IS_CATEGORY[word] then return lvl, word, after end
    return lvl, "ui", text
end

--- Turns the old text lines of `list` ("HH:MM:SS text", a "== <weekday> <day> <month> <year> ==" line at each day)
--- into records, in place. `offset`: the shown clock's offset from UTC (the clock the lines were written on);
--- `now` bounds the times (a line with no day line before it is from the day of the first one after it, else today).
--- @return number lines turned into records
function Log.Migrate(list, offset, now)
    local out, n = {}, 0
    -- The day of each line: the day line before it; lines before the first day line, the day before that one.
    local firstDay
    for _, line in ipairs(list) do
        if type(line) == "string" then
            local d, month, y = line:match("^== %a+ (%d+) (%a+) (%d+) ==")
            if d and MONTHS[month] then
                firstDay = Util.DaysFromCivil(tonumber(y), MONTHS[month], tonumber(d)) - 1
                break
            end
        end
    end
    local today = math.floor((now + offset) / 86400)
    local day = firstDay or today
    local lastT = (day * 86400) - offset
    for _, line in ipairs(list) do
        if type(line) ~= "string" then
            out[#out + 1] = line
        else
            local d, month, y = line:match("^== %a+ (%d+) (%a+) (%d+) ==")
            if d and MONTHS[month] then
                day = Util.DaysFromCivil(tonumber(y), MONTHS[month], tonumber(d))
            elseif not line:find("^== ") then
                local h, m, s, text = line:match("^(%d%d):(%d%d):(%d%d) (.*)")
                local t = lastT
                if h then
                    t = day * 86400 + tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) - offset
                    if t > now then t = t - 86400 end
                else
                    text = line
                end
                local lvl, cat, msg = Log.Classify(text)
                out[#out + 1] = { t = t, lvl = lvl, cat = cat, msg = msg }
                lastT = t
                n = n + 1
            end
        end
    end
    for i = 1, math.max(#list, #out) do list[i] = out[i] end
    return n
end

-- The log as records: the old text lines are turned into records the first time it is read.
local migrated
function Log.Records()
    local log = ns.db.log
    if migrated == log and type(log[1]) ~= "string" then return log end
    migrated = log
    ns.db.logDay = nil   -- (the old day line's date)
    local old = false
    for _, line in ipairs(log) do if type(line) == "string" then old = true break end end
    if old then
        local now = time()
        Log.Migrate(log, shownOffset(now), now)
    end
    return log
end

local capping = false
--- Adds one record. `msg` is plain text (coin icons as g, s, c); `kv` is kept as given, when it has a key.
function Log.Add(lvl, cat, msg, kv)
    local log = Log.Records()
    local rec = { t = time(), lvl = lvl, cat = cat, msg = Util.PlainMoney(tostring(msg)) }
    if type(kv) == "table" and next(kv) ~= nil then rec.kv = kv end
    log[#log + 1] = rec
    ns.logChanged = true
    -- (The drop line is a record too: it is added without a second cap.)
    if not capping then
        capping = true
        Util.Cap(log, Log.MAX, "log records")
        capping = false
    end
    return rec
end

--- ns.Log(lvl, cat, msg, kv): one record (see the top of this file). ns.Log(fmt, ...): the old form (a shim).
function ns.Log(first, ...)
    if not ns.db then return end
    local cat, msg, kv = ...
    if Log.RANK[first] and type(cat) == "string" and type(msg) == "string" then
        return Log.Add(first, cat, msg, kv)
    end
    local ok, text = pcall(string.format, first, ...)
    if not ok then text = tostring(first) end
    local lvl, c, m = Log.Classify(text)
    return Log.Add(lvl, c, m)
end

------------------------------------------------------------------ text

--- An item for a message: its link (the name) where known, else its name, else "item <id>". The ID goes in kv.
function ns.LogItem(id, link)
    if type(link) == "string" and link ~= "" then return link end
    id = tonumber(id)
    if not id then return "an item" end
    local _, known = ns.GetItemInfo(id)
    return known or ns.MaterialName(id)
end

--- The item ID of a key string ("7048:29:0") or a number.
function Log.ItemOf(key) return tonumber(tostring(key or ""):match("^(%d+)")) end
--- A text without color codes, links and textures (an item link reads "[Name]").
function Log.Plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
        :gsub("|T.-|t", ""))
end

--- One record as the chat and the specs read it: "HH:MM:SS LEVEL cat: message" (the shown clock).
function ns.LogText(rec)
    if type(rec) ~= "table" then return tostring(rec) end
    return string.format("%s %s %s: %s", ns.Date("%H:%M:%S", rec.t), rec.lvl, rec.cat, Log.Plain(rec.msg))
end

--- Every record as ns.LogText, oldest first.
function ns.LogLines()
    local out = {}
    for i, rec in ipairs(Log.Records()) do out[i] = ns.LogText(rec) end
    return out
end

local function quote(s)
    return '"' .. s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n") .. '"'
end

local function value(v)
    if type(v) == "number" then
        if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return string.format("%d", v) end
        return string.format("%.4g", v)
    end
    if type(v) == "boolean" then return tostring(v) end
    local s = Log.Plain(tostring(v))
    if s ~= "" and s:match("^[%w%._:/%-%+]+$") then return s end
    return quote(s)
end

-- key=value pairs of `kv`, sorted by key; a table inside is flattened with dots (got.11083=2).
local function pairsOf(kv, prefix, out)
    local keys = {}
    for k in pairs(kv) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local name = prefix .. tostring(k):gsub("[%s=\"]", "_")
        local v = kv[k]
        if type(v) == "table" then pairsOf(v, name .. ".", out)
        else out[#out + 1] = name .. "=" .. value(v) end
    end
    return out
end

--- The kv fields of a record as "key: value" lines (the window's hover).
function Log.Fields(rec)
    local out = {}
    for _, pair in ipairs(pairsOf(rec.kv or {}, "", {})) do
        local k, v = pair:match("^([^=]*)=(.*)")
        out[#out + 1] = k .. ": " .. v
    end
    return out
end

--- The ISO time of `t` on the shown clock, with its offset: "2026-11-28T03:49:03+01:00".
function Log.Iso(t)
    local off = shownOffset(t)
    local m = math.floor(math.abs(off) / 60 + 0.5)
    return Util.Date("!%Y-%m-%dT%H:%M:%S", t + off) .. string.format("%s%02d:%02d", off < 0 and "-" or "+",
        math.floor(m / 60), m % 60)
end

--- One record as a logfmt line: ISO time, level, category, the quoted message, then key=value.
--- 2026-11-28T03:49:03+01:00 INFO disenchant "Hillman's Shoulders gave 2 Soul Dust" item=4251 got.11083=2
function Log.Line(rec)
    local parts = { Log.Iso(rec.t or 0), rec.lvl or "INFO", rec.cat or "ui", quote(Log.Plain(rec.msg or "")) }
    if rec.kv then pairsOf(rec.kv, "", parts) end
    return table.concat(parts, " ")
end

--- The log as logfmt lines, oldest first: the last `n` records (every one without `n`), only those of level `least`
--- and up (every level without it).
function ns.LogExport(n, least)
    local log, out = Log.Records(), {}
    local rank = least and Log.RANK[least] or 4
    local from = n and math.max(1, #log - n + 1) or 1
    for i = from, #log do
        if (Log.RANK[log[i].lvl] or 3) <= rank then out[#out + 1] = Log.Line(log[i]) end
    end
    return out
end

--- /salv log export: the whole log as logfmt lines into the saved data (SalvagerDB.logExport, replaced each time);
--- the game writes it to disk on /reload or logout, `make layout` copies it to .agents/tmp/layout/log.txt.
function Log.SaveExport()
    local lines = ns.LogExport()
    SalvagerDB.logExport = { version = ns.VERSION, time = time(), lines = lines }
    ns.Print("the log (%d lines) is in the saved data as text; /reload writes it to disk", #lines)
    return lines
end

--- For the layout dump: the count of records per level, and the newest ERROR and WARN lines as logfmt.
function Log.Dump()
    local counts = { ERROR = 0, WARN = 0, INFO = 0, DEBUG = 0 }
    local log = Log.Records()
    for _, rec in ipairs(log) do counts[rec.lvl] = (counts[rec.lvl] or 0) + 1 end
    local lines = {}
    for i = #log, 1, -1 do
        if #lines >= DUMP_LINES then break end
        if Log.RANK[log[i].lvl] <= 2 then table.insert(lines, 1, Log.Line(log[i])) end
    end
    return { counts = counts, lines = lines }
end

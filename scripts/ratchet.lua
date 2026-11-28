-- The ratchet (SDD 121): measured numbers that may only get better. The specs write what they measure now to
-- .ratchet/*.json; the baseline is spec/ratchet.json (in git). Lua 5.1, no modules: `make check` runs it in the
-- test image, and spec/ratchet_spec.lua loads it.
--
--   lua scripts/ratchet.lua check                 every number against its baseline; a table of what got worse, exit 1
--   lua scripts/ratchet.lua tighten               the baseline moves to the better numbers only (new ones join)
--   ALLOW_WORSE=<patterns> REASON=<text> lua scripts/ratchet.lua tighten
--                                                 also takes the worse numbers that match a pattern (Lua patterns on
--                                                 "<set>:<key>:<field>", comma separated), and writes the reason
--                                                 into the baseline, so the change shows in review
local R = {}

R.SCREEN = 1920        -- extreme data: a window may grow up to the screen
R.PERF_SLACK = 1.5     -- a timing may be 1.5 times its baseline (noise), never more
R.PERF_FLOOR = 2       -- ms: timings under it count as it (os.clock's grain)
R.PERF_BAND = 10       -- ms: a timing also has to be this much over its baseline to fail (a shared host's noise:
                       -- 12.1 -> 18.8 ms seen once in three runs of the same code, 2026-11-28)
R.PERF_TIGHTEN = 0.8   -- a timing moves the baseline only when 20 % better (a lucky run does not set it)

------------------------------------------------------------------ JSON (the subset the specs write)

local function decode(s)
    local i = 1
    local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
    local value
    local function str()
        local out, j = {}, i + 1
        while true do
            local c = s:sub(j, j)
            if c == '"' then break end
            if c == "\\" then
                local n = s:sub(j + 1, j + 1)
                if n == "u" then
                    out[#out + 1] = string.char(tonumber(s:sub(j + 2, j + 5), 16) % 256)
                    j = j + 6
                else
                    out[#out + 1] = ({ n = "\n", t = "\t", r = "\r" })[n] or n
                    j = j + 2
                end
            else
                out[#out + 1] = c
                j = j + 1
            end
        end
        i = j + 1
        return table.concat(out)
    end
    function value()
        ws()
        local c = s:sub(i, i)
        if c == "{" then
            i = i + 1
            local t = {}
            ws()
            if s:sub(i, i) == "}" then i = i + 1 return t end
            while true do
                ws()
                local k = str()
                ws()
                i = i + 1   -- ':'
                t[k] = value()
                ws()
                local d = s:sub(i, i)
                i = i + 1
                if d == "}" then return t end
            end
        elseif c == "[" then
            i = i + 1
            local t = {}
            ws()
            if s:sub(i, i) == "]" then i = i + 1 return t end
            while true do
                t[#t + 1] = value()
                ws()
                local d = s:sub(i, i)
                i = i + 1
                if d == "]" then return t end
            end
        elseif c == '"' then
            return str()
        elseif s:sub(i, i + 3) == "true" then
            i = i + 4 return true
        elseif s:sub(i, i + 4) == "false" then
            i = i + 5 return false
        elseif s:sub(i, i + 3) == "null" then
            i = i + 4 return nil
        end
        local num = s:match("^-?[%d%.eE+-]+", i)
        i = i + #num
        return tonumber(num)
    end
    return value()
end
R.decode = decode

local function encode(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.3f", v)
    elseif t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        if #v > 0 then
            local out = {}
            for _, x in ipairs(v) do out[#out + 1] = indent .. "  " .. encode(x, indent .. "  ") end
            return "[\n" .. table.concat(out, ",\n") .. "\n" .. indent .. "]"
        end
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = k end
        table.sort(keys)
        local out = {}
        for _, k in ipairs(keys) do out[#out + 1] = indent .. "  " .. encode(k) .. ": " .. encode(v[k], indent .. "  ") end
        if #out == 0 then return "{}" end
        return "{\n" .. table.concat(out, ",\n") .. "\n" .. indent .. "}"
    end
    return "null"
end
R.encode = encode

local function readFile(path)
    local f = io.open(path)
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
end
function R.read(path)
    local s = readFile(path)
    return s and decode(s) or nil
end
function R.write(path, t)
    local f = assert(io.open(path, "w"))
    f:write(encode(t), "\n")
    f:close()
end

------------------------------------------------------------------ the rules

-- Per set: how each field compares. worse(base, now) -> true when now is worse; better(base, now) -> the value the
-- baseline takes on `tighten`.
local function lessIsBetter(slack)
    return { worse = function(b, n) return n > b + slack end, better = function(b, n) return math.min(b, n) end }
end
local ZERO = { worse = function(b, n) return n > 0 or n > b end, better = function(b, n) return math.min(b, n) end }
local RULES = {
    ["layout-typical"] = { width = lessIsBetter(1), gap = lessIsBetter(0.5), cut = ZERO, overlap = ZERO },
    ["layout-empty"] = { width = lessIsBetter(1), gap = lessIsBetter(0.5), cut = ZERO, overlap = ZERO },
    ["layout-extreme"] = {
        width = { worse = function(_, n) return n > R.SCREEN end, better = function(_, n) return n end },
        cut = ZERO,
    },
    ["sim"] = { width = lessIsBetter(1), gap = lessIsBetter(0.5), cut = ZERO },
    perf = { value = {
        worse = function(b, n)
            local base = math.max(b, R.PERF_FLOOR)
            return n > R.PERF_SLACK * base and n > base + R.PERF_BAND
        end,
        better = function(b, n) if n < R.PERF_TIGHTEN * b then return n end return b end,
    } },
    suite = {
        specs = { worse = function(b, n) return n < b end, better = function(b, n) return math.max(b, n) end },
        luacheck = ZERO,
    },
}
R.RULES = RULES

-- The fields of one entry: a table of fields, or a number (a timing: field "value").
local function fields(x)
    if type(x) == "table" then return x end
    return { value = x }
end

--- Compares `now` with `base` (both { [set] = { [key] = entry } }), for the sets in `now`.
--- @return table worse  { { set, key, field, base, now }, ... }; table missing (keys of the baseline not measured)
function R.compare(base, now)
    local worse, missing = {}, {}
    local sets = {}
    for set in pairs(now) do sets[#sets + 1] = set end
    table.sort(sets)
    for _, set in ipairs(sets) do
        local rules, b, n = RULES[set], base[set] or {}, now[set]
        if rules then
            local keys = {}
            for k in pairs(n) do keys[#keys + 1] = k end
            table.sort(keys)
            for _, key in ipairs(keys) do
                local bf, nf = b[key] and fields(b[key]), fields(n[key])
                if bf then
                    local names = {}
                    for field in pairs(nf) do names[#names + 1] = field end
                    table.sort(names)
                    for _, field in ipairs(names) do
                        local rule, bv, nv = rules[field], bf[field], nf[field]
                        if rule and type(bv) == "number" and type(nv) == "number" and rule.worse(bv, nv) then
                            worse[#worse + 1] = { set, key, field, bv, nv }
                        end
                    end
                end
            end
            for key in pairs(b) do if n[key] == nil then missing[#missing + 1] = set .. ":" .. key end end
        end
    end
    table.sort(missing)
    return worse, missing
end

local function allowed(patterns, id)
    for _, p in ipairs(patterns or {}) do if id:find(p) then return true end end
    return false
end

--- The baseline after `tighten`: every number at the better of the two, new keys added; worse numbers only where
--- `allow` (patterns) matches, and then `reason` is noted. Returns the new baseline and the lines that changed.
function R.tighten(base, now, allow, reason, date)
    local out, changes, took = {}, {}, {}
    for set, keys in pairs(base) do
        if type(keys) == "table" and set ~= "reasons" then
            out[set] = {}
            for k, v in pairs(keys) do out[set][k] = v end
        end
    end
    out.reasons = base.reasons or {}
    for set, keys in pairs(now) do
        local rules = RULES[set]
        if rules then
            out[set] = out[set] or {}
            for key, entry in pairs(keys) do
                local old = out[set][key]
                if old == nil then
                    out[set][key] = entry
                    changes[#changes + 1] = string.format("new      %s:%s", set, key)
                else
                    local of, nf = fields(old), fields(entry)
                    local nextf = {}
                    for field, nv in pairs(nf) do
                        local rule, bv = rules[field], of[field]
                        local v = bv
                        if rule and type(bv) == "number" and type(nv) == "number" then
                            local id = set .. ":" .. key .. ":" .. field
                            if rule.worse(bv, nv) then
                                if allowed(allow, id) then
                                    v = nv
                                    took[#took + 1] = id
                                    changes[#changes + 1] = string.format("LOOSER   %s %s -> %s", id, tostring(bv), tostring(nv))
                                end
                            else
                                v = rule.better(bv, nv)
                                if v ~= bv then
                                    changes[#changes + 1] = string.format("tighter  %s %s -> %s", id, tostring(bv), tostring(v))
                                end
                            end
                        elseif bv == nil then
                            v = nv
                        end
                        nextf[field] = v
                    end
                    if type(old) == "table" then out[set][key] = nextf else out[set][key] = nextf.value end
                end
            end
        end
    end
    -- A key no longer measured (a view gone) leaves the baseline only where allowed.
    for set, keys in pairs(now) do
        if RULES[set] and out[set] then
            for key in pairs(out[set]) do
                if keys[key] == nil and allowed(allow, set .. ":" .. key) then
                    out[set][key] = nil
                    took[#took + 1] = set .. ":" .. key
                    changes[#changes + 1] = string.format("DROPPED  %s:%s", set, key)
                end
            end
        end
    end
    if #took > 0 then
        table.sort(took)
        out.reasons[#out.reasons + 1] = (date or os.date("%Y-%m-%d")) .. " looser (" .. table.concat(took, ", ") .. "): "
            .. tostring(reason)
    end
    table.sort(changes)
    return out, changes, took
end

------------------------------------------------------------------ the measured numbers

local SETS = { "layout-typical", "layout-empty", "layout-extreme", "perf", "suite", "sim" }

--- What the specs measured, from `dir` (.ratchet): the sets that are there.
function R.now(dir)
    local now = {}
    for _, set in ipairs(SETS) do now[set] = R.read(dir .. "/" .. set .. ".json") end
    return now
end

--- The suite's counts from the outputs `make check` keeps: busted's last line, luacheck's total.
function R.suite(dir)
    local busted, lint = readFile(dir .. "/busted.txt"), readFile(dir .. "/luacheck.txt")
    local out = {}
    local ok = busted and busted:match("(%d+) successes? /")
    if ok then out.specs = tonumber(ok) end
    local w = lint and lint:gsub("\27%[[%d;]*m", ""):match("Total: (%d+) warnings?")
    if w then out.luacheck = tonumber(w) end
    return { all = out }
end

local function report(worse, missing)
    local lines = {}
    if #worse > 0 then
        lines[#lines + 1] = string.format("%-16s %-48s %-9s %10s %10s %10s", "set", "key", "field", "baseline", "now", "worse by")
        for _, w in ipairs(worse) do
            lines[#lines + 1] = string.format("%-16s %-48s %-9s %10s %10s %10s", w[1], w[2], w[3], tostring(w[4]),
                tostring(w[5]), string.format("%+.3g", w[5] - w[4]))
        end
    end
    for _, m in ipairs(missing) do lines[#lines + 1] = "not measured any more: " .. m end
    return table.concat(lines, "\n")
end
R.report = report

function R.main(argv)
    local cmd = argv[1] or "check"
    local basePath, dir = os.getenv("RATCHET_BASE") or "spec/ratchet.json", os.getenv("RATCHET_DIR") or ".ratchet"
    local base = R.read(basePath) or {}
    local now = R.now(dir)
    now.suite = R.suite(dir)
    if not next(now.suite.all) then now.suite = nil end
    if cmd == "check" then
        local worse, missing = R.compare(base, now)
        if #worse > 0 or #missing > 0 then
            io.stderr:write("ratchet: worse than the baseline (" .. basePath .. ")\n" .. report(worse, missing) .. "\n"
                .. "Fix it, or loosen on purpose: make ratchet ALLOW_WORSE=<patterns> REASON=\"why\"\n")
            return 1
        end
        print(string.format("ratchet: no number worse than %s", basePath))
        return 0
    elseif cmd == "tighten" then
        local allow = {}
        for p in (os.getenv("ALLOW_WORSE") or ""):gmatch("[^,]+") do allow[#allow + 1] = p end
        local reason = os.getenv("REASON")
        if #allow > 0 and not (reason and reason ~= "") then
            io.stderr:write("ratchet: ALLOW_WORSE needs REASON=\"why\" (it goes into the baseline)\n")
            return 1
        end
        local out, changes = R.tighten(base, now, allow, reason)
        local worse = R.compare(out, now)
        R.write(basePath, out)
        for _, c in ipairs(changes) do print(c) end
        print(string.format("ratchet: %d changes written to %s", #changes, basePath))
        if #worse > 0 then
            io.stderr:write("ratchet: still worse (not allowed):\n" .. report(worse, {}) .. "\n")
            return 1
        end
        return 0
    end
    io.stderr:write("usage: lua scripts/ratchet.lua check|tighten\n")
    return 2
end

if arg and arg[0] and arg[0]:find("ratchet%.lua$") then os.exit(R.main(arg)) end
return R

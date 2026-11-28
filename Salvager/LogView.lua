-- Salvager: the Log window's table and its filters (SDD 129). Time | Level | Category | Message, oldest first, a
-- heading row at each day; the level's word in its color (ERROR red, WARN orange, INFO white, DEBUG grey); filters
-- Search, Level (the least level shown, INFO at first) and Category (any of them); a row's hover shows its data.
local _, ns = ...

local W, Book = ns.Widgets, ns.LogBook

local View = {}
ns.LogView = View

local GOLD, GREY = "|cffffd100", "|cff808080"
View.COLOR = { ERROR = "|cffff4040", WARN = "|cffff8040", INFO = "|cffffffff", DEBUG = GREY }
local TIME_FORMAT = "%H:%M:%S"
local CUT_MEMO_MAX = 4000   -- cut messages kept (emptied past it)

View.COLUMNS = {
    { "Time", 60, "RIGHT", help = ns.TimeHelp("Time", "When it happened.") },
    { "Level", 50, "LEFT", help = { "Level", "ERROR: a Lua error or an action that failed. WARN: something dropped, "
        .. "limited, given up or without an answer. INFO: what you did and what the addon did for you. DEBUG: the "
        .. "detail of each search and page." } },
    { "Category", 80, "LEFT", help = { "Category", "The part of the trade a line is about: session, scan, search, buy, "
        .. "mail, disenchant, post, sale, ledger, books, gold, competition, layout, ui, options." } },
    { "Message", 300, "LEFT", help = { "Message", "What happened. A line too long for the window ends with \"...\": "
        .. "hover it for the whole line and its data." } },
}

View.LEVEL_OPTIONS = {
    { "DEBUG", "All" }, { "INFO", "Info and up" }, { "WARN", "Warnings and up" }, { "ERROR", "Errors" },
}

--- The window's filters (saved with the window): { level = least level shown, catsOff = { [cat] = true }, search }.
function View.Filter()
    local s = ns.db.windows.log or {}
    ns.db.windows.log = s
    -- (The Lines filter up to 0.4.0: "errors" is the level ERROR now; the others show what INFO shows.)
    if s.filter ~= nil then
        if s.filter == "errors" and not s.level then s.level = "ERROR" end
        s.filter = nil
    end
    if not Book.RANK[s.level or ""] then s.level = "INFO" end
    if type(s.catsOff) ~= "table" then s.catsOff = {} end
    return s
end

--- Does record `rec` show under filter `flt`?
function View.Matches(rec, flt)
    if (Book.RANK[rec.lvl] or 3) > (Book.RANK[flt.level] or 3) then return false end
    if flt.catsOff and flt.catsOff[rec.cat] then return false end
    return W.Matches(rec.msg, flt.search)
end

-- The widest text of a column of fixed words (its title too), in px; nil where the client cannot measure.
local function widest(title, words)
    local w = W.TextWidth(title, W.TITLE_FONT)
    if not w then return nil end
    for _, word in ipairs(words) do
        local x = W.TextWidth(word, W.CELL_FONT)
        if not x then return nil end
        w = math.max(w, x)
    end
    return w
end

--- The room the Message column has in `list` now, in px: the list's width less the other three columns (at their
--- widest texts) and the gaps. nil where the client cannot measure text.
function View.MessageRoom(list)
    local digits = W.WidestDigits("00:00:00")
    local time = digits and widest("Time", { digits })
    local level = widest("Level", Book.LEVELS)
    local cat = widest("Category", Book.CATEGORIES)
    if not (time and level and cat) then return nil end
    local pad = W.CELL_PAD
    local fixed = 4 + math.ceil(time) + pad + math.ceil(level) + pad + math.ceil(cat) + pad
        + W.ColumnGap("RIGHT", "LEFT") + 2 * W.ColumnGap("LEFT", "LEFT")
    -- (Widgets.List: 18 px of scroll bar and 8 px of margins; then the Message column's own pad, and 2 px to spare.)
    return math.floor((tonumber((list:GetWidth())) or 0) - 18 - 8 - fixed - pad - 2)
end

local cutMemo, cutCount = {}, 0
--- `text` as it fits in `room` px of the cells' font: in full, or cut with "..." (its plain text: no codes cut open).
function View.Cut(text, room)
    if not room then return text end
    local key = room .. "\0" .. text
    local done = cutMemo[key]
    if done then return done end
    local w = W.TextWidth(text, W.CELL_FONT)
    local out = text
    if w and w > room then
        local plain = Book.Plain(text)
        local lo, hi = 0, #plain
        while lo < hi do
            local mid = math.floor((lo + hi + 1) / 2)
            local x = W.TextWidth(plain:sub(1, mid) .. "...", W.CELL_FONT) or 0
            if x <= room then lo = mid else hi = mid - 1 end
        end
        -- (Never in the middle of a character of more than one byte.)
        while lo > 0 and plain:byte(lo + 1) and plain:byte(lo + 1) >= 128 and plain:byte(lo + 1) < 192 do lo = lo - 1 end
        out = plain:sub(1, lo) .. "..."
    end
    if cutCount >= CUT_MEMO_MAX then cutMemo, cutCount = {}, 0 end
    cutMemo[key], cutCount = out, cutCount + 1
    return out
end

--- One record as a row: its four cells (the message cut to `room`), and its hover: level, category and time, the
--- whole message, then its data, one field per line.
function View.Row(rec, room)
    local color = View.COLOR[rec.lvl] or "|cffffffff"
    local msg = View.Cut(rec.msg, room)
    local tip = { string.format("%s %s, %s", rec.lvl, rec.cat, ns.Date("%Y-%m-%d " .. TIME_FORMAT, rec.t)),
        Book.Plain(rec.msg) }
    for _, line in ipairs(Book.Fields(rec)) do tip[#tip + 1] = line end
    return {
        cells = { ns.Date(TIME_FORMAT, rec.t), color .. rec.lvl .. "|r", rec.cat,
            rec.lvl == "INFO" and msg or (color .. msg .. "|r") },
        tip = tip,
    }
end

--- The records that show, in order, with a day heading before each day's first one ({ day = Unix time }).
--- @return table entries, number records shown
function View.Shown(records, flt)
    local out, n, dayStart, dayEnd = {}, 0, nil, nil
    for _, rec in ipairs(records) do
        if View.Matches(rec, flt) then
            local t = rec.t or 0
            if not dayStart or t < dayStart or t >= dayEnd then
                -- (The day's bounds on the shown clock: one date reading per day, not per record.)
                local d = ns.Date("*t", t)
                dayStart = t - (d.hour * 3600 + d.min * 60 + d.sec)
                dayEnd = dayStart + 86400
                out[#out + 1] = { day = t }
            end
            out[#out + 1] = rec
            n = n + 1
        end
    end
    return out, n
end

--- The row of one entry of View.Shown.
function View.Entry(e, room)
    if e.day then return { cells = { GOLD .. ns.Date("%A %d %B %Y", e.day) .. "|r" }, span = true } end
    return View.Row(e, room)
end

--- Why nothing shows (UI.md Tables 6).
function View.Empty(total, flt)
    if total == 0 then return GREY .. "Nothing logged yet: the addon writes here what it does.|r" end
    if flt.search and flt.search ~= "" then return GREY .. W.NoMatch(flt.search) .. "|r" end
    return GREY .. "No line at this level and in these categories: change Level or Category.|r"
end

--- The filter row's controls: Search, Level, Category. `changed()` runs after a change.
--- @return table controls { search, level, category }
function View.BuildFilters(bar, changed)
    local SEARCH_HELP = "Shows the lines whose message has this text, in any case."
    local search = W.Search(bar, 120, function() return View.Filter().search or "" end, function(text)
        View.Filter().search = text ~= "" and text or nil
        changed()
    end, SEARCH_HELP)
    bar:AddFilter("Search", search, 120, SEARCH_HELP)
    local LEVEL_HELP = "The least level shown: every line, Info and up (not the detail of each search), warnings and "
        .. "errors, or only errors."
    local level
    level = W.Dropdown(bar, 140, View.LEVEL_OPTIONS, function(key) return View.Filter().level == key end,
        function(key)
            View.Filter().level = key
            level:Close()
            changed()
        end, LEVEL_HELP, "Level", nil, true)
    bar:AddFilter("Level", level, 140, LEVEL_HELP)
    local options = {}
    for _, c in ipairs(Book.CATEGORIES) do options[#options + 1] = { c, c } end
    local CAT_HELP = "Which categories show: tick or untick each. At least one stays ticked."
    local category = W.Dropdown(bar, 120, options, function(key) return not View.Filter().catsOff[key] end,
        function(key, on)
            local off = View.Filter().catsOff
            off[key] = (not on) or nil
            local any = false
            for _, c in ipairs(Book.CATEGORIES) do if not off[c] then any = true break end end
            if not any then
                off[key] = nil
                ns.Print("at least one category must stay ticked")
            end
            changed()
        end, CAT_HELP, "Category", function(names, total)
            if #names == total then return "All" end
            if #names > 2 then return #names .. " categories" end
            return table.concat(names, ", ")
        end)
    bar:AddFilter("Category", category, 120, CAT_HELP)
    return { search = search, level = level, category = category }
end

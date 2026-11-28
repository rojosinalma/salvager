-- The structured log (SDD 129): records { t, lvl, cat, msg, kv }, the old form through its shim, the bound, the
-- migration of the old text lines, the logfmt export, the error capture, every call site with a level and a
-- category, and the Log window's table and filters.
local wow = require("spec.wow")

local T = 1700000000          -- 2023-11-14 22:13:20 UTC

-- Files that still write the old form ns.Log(fmt, ...) (the shim): none since 0.4.1; a file here fails when it is moved.
local SHIM = {}

-- The first two arguments of a call that starts at `text` (after "ns.Log("), split at the top-level commas.
local function firstArgs(text)
    local args, depth, cur, quote, i = {}, 0, {}, nil, 1
    while i <= #text and #args < 2 do
        local c = text:sub(i, i)
        if quote then
            if c == "\\" then cur[#cur + 1] = text:sub(i, i + 1) i = i + 1
            else
                if c == quote then quote = nil end
                cur[#cur + 1] = c
            end
        elseif c == '"' or c == "'" then quote = c cur[#cur + 1] = c
        elseif c == "(" or c == "{" then depth = depth + 1 cur[#cur + 1] = c
        elseif (c == ")" or c == "}") and depth == 0 then args[#args + 1] = table.concat(cur) break
        elseif c == ")" or c == "}" then depth = depth - 1 cur[#cur + 1] = c
        elseif c == "," and depth == 0 then args[#args + 1] = table.concat(cur) cur = {}
        else cur[#cur + 1] = c end
        i = i + 1
    end
    return args
end

local function load(opts)
    local env = wow.install(opts)
    local ns = wow.loadAddon()
    wow.fire(ns, "ADDON_LOADED", "Salvager")
    return env, ns
end

describe("The log's call sites", function()
    it("give every ns.Log call a level and a category of the lists (the files on the shim aside)", function()
        local env, ns = load()
        local Book = ns.LogBook
        local IS_LEVEL = Book.RANK
        local bad, shimUsed = {}, {}
        for line in io.lines("Salvager/Salvager.toc") do
            local file = line:match("^([%w_]+%.lua)$")
            if file and file ~= "Log.lua" then
                local f = assert(io.open("Salvager/" .. file))
                local text = f:read("*a")
                f:close()
                local from = 1
                while true do
                    local s, e = text:find("ns%.Log%(", from)
                    if not s then break end
                    from = e + 1
                    local n = select(2, text:sub(1, s):gsub("\n", "")) + 1
                    local args = firstArgs(text:sub(e + 1, e + 2000))
                    local levels, cats, other = 0, 0, false
                    for word in (args[1] or ""):gmatch('"([^"]*)"') do
                        if IS_LEVEL[word] then levels = levels + 1 else other = true end
                    end
                    for word in (args[2] or ""):gmatch('"([^"]*)"') do
                        if Book.IS_CATEGORY[word] then cats = cats + 1 else other = true end
                    end
                    local ok = levels > 0 and cats > 0 and not other
                    if not ok and SHIM[file] then shimUsed[file] = true
                    elseif not ok then bad[#bad + 1] = file .. ":" .. n end
                end
            end
        end
        assert.are.same({}, bad)
        -- The list of files on the shim shrinks as they are moved: a file that no longer needs it leaves the list.
        for file in pairs(SHIM) do assert.is_true(shimUsed[file] == true, file .. " is moved: take it off SHIM") end
        assert.is_table(env)
    end)
end)

describe("The log", function()
    local env, ns, Book
    before_each(function()
        env, ns = load()
        Book = ns.LogBook
        env.clock = T
    end)

    it("keeps a record of level, category, message and data", function()
        local rec = ns.Log("INFO", "buy", "bought [Boots] for " .. ns.Money(12345), { item = 4251, paid = 12345 })
        assert.are.same({ t = T, lvl = "INFO", cat = "buy", msg = "bought [Boots] for 1g 23s 45c",
            kv = { item = 4251, paid = 12345 } }, rec)
        assert.are.equal(rec, ns.db.log[#ns.db.log])
        assert.is_nil(ns.Log("WARN", "scan", "no data", {}).kv)           -- an empty kv is not kept
        assert.is_true(ns.logChanged)
    end)

    it("takes the old form through its shim: INFO and ui, ERROR and a category word where the text says so", function()
        local r = ns.Log("checked item %s: %d auctions", "7048:29:0", 3)
        assert.are.same({ "INFO", "ui", "checked item 7048:29:0: 3 auctions" }, { r.lvl, r.cat, r.msg })
        r = ns.Log("ERROR in %s: %s", "ticker", "boom")
        assert.are.same({ "ERROR", "ui", "in ticker: boom" }, { r.lvl, r.cat, r.msg })
        r = ns.Log("layout: ledger/sales wider than its content by 9 px")
        assert.are.same({ "INFO", "layout", "ledger/sales wider than its content by 9 px" }, { r.lvl, r.cat, r.msg })
        r = ns.Log("price: %d", "not a number")                         -- a format that fails keeps its text
        assert.are.equal("price: %d", r.msg)
        r = ns.Log("INFO")                                              -- a level word alone is an old text
        assert.are.same({ "INFO", "ui", "INFO" }, { r.lvl, r.cat, r.msg })
    end)

    it("is bounded, and says what its bound dropped", function()
        local max = Book.MAX
        Book.MAX = 20
        for i = 1, 30 do ns.Log("DEBUG", "search", "line " .. i) end
        Book.MAX = max
        assert.is_true(#ns.db.log <= 21)
        assert.are.equal("line 30", ns.db.log[#ns.db.log].msg)
        local dropLine
        for _, rec in ipairs(ns.db.log) do if rec.msg:find("log records dropped", 1, true) then dropLine = rec end end
        assert.is_table(dropLine)
        assert.are.equal("DEBUG", dropLine.lvl)                         -- (the log's own rotation is how it works)
        assert.are.equal("log records", dropLine.kv.what)
        -- Any other bound: WARN.
        ns.Util.Cap({ 1, 2, 3 }, 1, "test records")
        local last = ns.db.log[#ns.db.log]
        assert.are.same({ "WARN", "ledger", 2, 1 }, { last.lvl, last.cat, last.kv.dropped, last.kv.kept })
    end)

    it("turns the old text lines into records, with their day and time", function()
        local day = ns.Util.DaysFromCivil(2026, 11, 27) * 86400
        local now = day + 86400 + 3600                                 -- 2026-11-28 01:00 UTC
        local list = { "23:59:00 before the first day line", "== Friday 27 November 2026 ==",
            "10:00:00 ERROR in ticker: boom", "10:00:05 ledger: removed 2 sale(s)", "11:00:00 bought [Boots] for 1s",
            { t = now, lvl = "INFO", cat = "ui", msg = "a record already" } }
        assert.are.equal(4, Book.Migrate(list, 3600, now))              -- written on a clock at UTC+1
        assert.are.equal(5, #list)
        assert.are.same({ t = day - 60 - 3600, lvl = "INFO", cat = "ui", msg = "before the first day line" }, list[1])
        assert.are.same({ t = day + 36000 - 3600, lvl = "ERROR", cat = "ui", msg = "in ticker: boom" }, list[2])
        assert.are.same({ "ledger", "removed 2 sale(s)" }, { list[3].cat, list[3].msg })
        assert.are.equal(day + 39600 - 3600, list[4].t)
        assert.are.equal("a record already", list[5].msg)
        -- In the game: the saved text lines are records at the first read, and the old day mark goes.
        ns.db.log = { "== Tuesday 14 November 2023 ==", "21:00:00 auction house opened" }
        ns.db.logDay = "2023-11-14"
        ns.Log("INFO", "session", "next")
        assert.are.equal(2, #ns.db.log)
        assert.are.equal("auction house opened", ns.db.log[1].msg)
        assert.are.equal("21:00:00", ns.Date("%H:%M:%S", ns.db.log[1].t))
        assert.is_nil(ns.db.logDay)
    end)

    it("writes logfmt lines: ISO time with the clock's offset, level, category, the quoted message, key=value", function()
        ns.TimeOffset = function() return 3600 end
        assert.are.equal("2023-11-14T23:13:20+01:00", Book.Iso(T))
        ns.TimeOffset = function() return -5 * 3600 - 1800 end
        assert.are.equal("2023-11-14T16:43:20-05:30", Book.Iso(T))
        ns.TimeOffset = function() return 0 end
        local rec = ns.Log("INFO", "disenchant", "|cff1eff00|Hitem:4251::::|h[Hillman's Shoulders]|h|r gave 2 Soul Dust",
            { item = 4251, got = { [11083] = 2 }, value = 836, salvager = "aura", note = "a \"quoted\" word", f = 0.5,
                ok = true })
        assert.are.equal('2023-11-14T22:13:20+00:00 INFO disenchant "[Hillman\'s Shoulders] gave 2 Soul Dust" f=0.5 '
            .. 'got.11083=2 item=4251 note="a \\"quoted\\" word" ok=true salvager=aura value=836', Book.Line(rec))
        ns.Log("DEBUG", "search", "detail")
        ns.Log("ERROR", "ui", "Lua error in X: boom")
        local all = ns.LogExport()
        assert.are.equal(#ns.db.log, #all)
        assert.are.equal(2, #ns.LogExport(2))
        local errors = ns.LogExport(nil, "WARN")
        for _, line in ipairs(errors) do assert.is_truthy(line:find(" ERROR ") or line:find(" WARN ")) end
        assert.is_truthy(errors[#errors]:find('ERROR ui "Lua error in X: boom"', 1, true))
        -- /salv log export: into the saved data, for /reload.
        SlashCmdList.SALVAGER("log export")
        assert.are.equal(#ns.db.log - 0, #_G.SalvagerDB.logExport.lines)
        assert.is_truthy(env.chat[#env.chat]:find("is in the saved data as text", 1, true))
        -- The layout dump: counts by level and the ERROR and WARN lines.
        wow.fire(ns, "PLAYER_LOGOUT")
        local dump = _G.SalvagerDB.layout.log
        assert.are.equal(1, dump.counts.DEBUG)
        assert.is_true(dump.counts.ERROR >= 1)
        assert.is_truthy(dump.lines[#dump.lines]:find('ERROR ui "Lua error in X: boom"', 1, true)
            or table.concat(dump.lines, "\n"):find('ERROR ui "Lua error in X: boom"', 1, true))
    end)

    it("logs a Lua error of an event handler as ERROR, with its event", function()
        ns.On("SALVAGER_TEST_BOOM", function() error("boom") end)
        ns.Fire("SALVAGER_TEST_BOOM")
        local last = ns.db.log[#ns.db.log]
        assert.are.equal("ERROR", last.lvl)
        assert.are.equal("SALVAGER_TEST_BOOM", last.kv.event)
        assert.is_truthy(last.msg:find("boom", 1, true))
        assert.is_truthy(ns.LogText(last):find("ERROR ui: Lua error in SALVAGER_TEST_BOOM", 1, true))
    end)
end)

describe("The Log window", function()
    local env, ns, View
    before_each(function()
        env, ns = load({ layout = true })
        View = ns.LogView
        env.clock = T
        wipe(ns.db.log)
    end)

    -- The game ticks or unticks the box, then runs OnClick.
    local function tick(check, on)
        check:SetChecked(on)
        check.scripts.OnClick(check)
    end
    local function rows()
        local list = ns.LogWindow.list
        local out = {}
        for i = 1, list.count do out[i] = list.getRow(i) end
        return out
    end

    it("shows Time | Level | Category | Message, the level in its color and word, a heading per day", function()
        ns.Log("INFO", "buy", "bought a piece of gear")
        ns.Log("ERROR", "ui", "Lua error in X: boom", { event = "X" })
        env.clock = T + 86400
        ns.Log("WARN", "search", "no answer")
        ns.LogWindow.Show()
        local titles = {}
        for i, c in ipairs(View.COLUMNS) do titles[i] = c[1] end
        assert.are.same({ "Time", "Level", "Category", "Message" }, titles)
        local r = rows()
        assert.are.equal(5, #r)                                       -- two days: two headings
        assert.is_true(r[1].span)
        assert.is_truthy(r[1].cells[1]:find(ns.Date("%A %d %B %Y", T), 1, true))
        assert.are.same({ ns.Date("%H:%M:%S", T), "|cffffffffINFO|r", "buy", "bought a piece of gear" }, r[2].cells)
        assert.are.equal("|cffff4040ERROR|r", r[3].cells[2])
        assert.are.equal("|cffff4040Lua error in X: boom|r", r[3].cells[4])
        assert.is_true(r[4].span)
        assert.are.equal("|cffff8040WARN|r", r[5].cells[2])
        -- The hover: level, category and time, the whole message, then the data one field per line.
        assert.is_truthy(r[3].tip[1]:find("ERROR ui", 1, true))
        assert.are.equal("Lua error in X: boom", r[3].tip[2])
        assert.are.equal("event: X", r[3].tip[3])
        assert.is_truthy(ns.LogWindow.bars.footer)
    end)

    it("filters by least level (INFO at first), category and search, and says why nothing shows", function()
        ns.LogWindow.Show()
        assert.is_truthy(rows()[1].cells[1]:find("Nothing logged yet", 1, true))
        ns.Log("DEBUG", "search", "checked Azure Silk Hood: 12 auctions")
        ns.Log("INFO", "buy", "bought Azure Silk Hood")
        ns.Log("WARN", "scan", "browse dropped")
        ns.Log("ERROR", "post", "could not cancel Soul Dust")
        local c = ns.LogWindow.controls
        local function messages()
            ns.LogWindow.Refresh()
            local out = {}
            for _, r in ipairs(rows()) do if not r.span then out[#out + 1] = ns.LogBook.Plain(r.cells[4]) end end
            return out
        end
        assert.are.equal("INFO", View.Filter().level)
        assert.are.same({ "bought Azure Silk Hood", "browse dropped", "could not cancel Soul Dust" }, messages())
        tick(c.level.checks[1], true)                                -- All
        assert.are.equal(4, #messages())
        tick(c.level.checks[3], true)                                -- Warnings and up
        assert.are.same({ "browse dropped", "could not cancel Soul Dust" }, messages())
        tick(c.level.checks[1], true)
        local scan
        for i, o in ipairs(c.category.options) do if o[1] == "scan" then scan = i end end
        tick(c.category.checks[scan], false)                         -- scan off
        assert.is_true(View.Filter().catsOff.scan)
        assert.are.equal(3, #messages())
        tick(c.category.checks[scan], true)
        c.search:SetText("azure")
        c.search.scripts.OnTextChanged(c.search)
        assert.are.same({ "checked Azure Silk Hood: 12 auctions", "bought Azure Silk Hood" }, messages())
        c.search:SetText("nothing like it")
        c.search.scripts.OnTextChanged(c.search)
        messages()
        assert.is_truthy(rows()[1].cells[1]:find("Nothing matches", 1, true))
        c.search:SetText("")
        c.search.scripts.OnTextChanged(c.search)
        tick(c.level.checks[4], true)                                -- Errors
        for i, o in ipairs(c.category.options) do if o[1] == "post" then tick(c.category.checks[i], false) end end
        messages()
        assert.is_truthy(rows()[1].cells[1]:find("No line at this level", 1, true))
        assert.are.equal("0 of 4 lines", ns.LogWindow.countLabel:GetText())
    end)

    it("takes the old Lines filter over: Errors is the level ERROR", function()
        ns.db.windows.log = { filter = "errors" }
        assert.are.equal("ERROR", View.Filter().level)
        assert.is_nil(ns.db.windows.log.filter)
        ns.db.windows.log = { filter = "trades" }
        assert.are.equal("INFO", View.Filter().level)
    end)

    it("cuts a message too long for the window, in full on its hover", function()
        local long = string.rep("a very long message ", 40)
        ns.Log("INFO", "scan", long)
        ns.LogWindow.Show()
        local r = rows()[2]
        assert.is_truthy(r.cells[4]:find("%.%.%.$"))
        assert.is_true(#r.cells[4] < #long)
        assert.are.equal(long, r.tip[2])
        local room = View.MessageRoom(ns.LogWindow.list)
        assert.is_true(ns.Widgets.TextWidth(r.cells[4], ns.Widgets.CELL_FONT) <= room)
        -- Every column shows: none is left out for the long message.
        assert.are.same({}, ns.LogWindow.list.leftOut)
        for _, m in ipairs(env.chat) do assert.is_nil(m:find("error", 1, true), m) end
    end)
end)

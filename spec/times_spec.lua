-- Times shown in local or server time (SDD 110): one helper for every shown time, the realm's offset from UTC
-- read at login and every hour.
local helper = require("spec.helper")
local wow = require("spec.wow")

local T = 1700000000          -- 2023-11-14 22:13:20 UTC, a Tuesday
local NEAR_MIDNIGHT = 1700004600   -- 2023-11-14 23:30:00 UTC
local H, HALF = 3600, 1800

describe("Times (pure)", function()
    local Util
    before_each(function() Util = helper.load().Util end)

    it("local time is the computer's clock", function()
        assert.are.equal(os.date("%Y-%m-%d %H:%M", T), Util.Date("%Y-%m-%d %H:%M", T))
    end)

    it("server time is the clock the offset gives, near midnight on the right day", function()
        assert.are.equal("11-14 23:13", Util.Date("%m-%d %H:%M", T, H))
        assert.are.equal("11-14 16:43", Util.Date("%m-%d %H:%M", T, -5 * H - HALF))
        assert.are.equal("Wed 11-15 00:30", Util.Date("%a %m-%d %H:%M", NEAR_MIDNIGHT, H))      -- the next day
        assert.are.equal("2023-11-14", Util.Date("%Y-%m-%d", NEAR_MIDNIGHT, -5 * H - HALF))
        assert.are.equal("Tue 11-14 21:30", Util.Date("%a %m-%d %H:%M", T + 5 * H - 13 * 60 - 20, -5 * H - HALF))
        assert.are.equal(15, Util.Date("*t", T + 5 * H, H).day)                                 -- tables too
    end)

    it("reads the realm's offset from its calendar time, rounded to the quarter hour", function()
        assert.are.equal(H, Util.ServerOffset(T, { year = 2023, month = 11, monthDay = 14, hour = 23, minute = 13 }))
        assert.are.equal(H, Util.ServerOffset(T + 59, { year = 2023, month = 11, monthDay = 14, hour = 23, minute = 13 }))
        assert.are.equal(-5 * H - HALF,
            Util.ServerOffset(T, { year = 2023, month = 11, monthDay = 14, hour = 16, minute = 43 }))
        assert.are.equal(2 * H, Util.ServerOffset(T, { year = 2023, month = 11, monthDay = 15, hour = 0, minute = 13 }))
        assert.are.equal(0, Util.ServerOffset(T, { year = 2023, month = 11, monthDay = 14, hour = 22, minute = 13 }))
        assert.is_nil(Util.ServerOffset(T, { year = 2023, month = 11, monthDay = 16, hour = 22, minute = 13 }))  -- 2 days
        assert.is_nil(Util.ServerOffset(T, nil))
    end)

    it("reads it from hours and minutes alone (GetGameTime), the nearest day", function()
        assert.are.equal(H, Util.ServerOffset(T, { hour = 23, minute = 13 }))
        assert.are.equal(2 * H, Util.ServerOffset(T, { hour = 0, minute = 13 }))                -- past midnight
        assert.are.equal(-5 * H - HALF, Util.ServerOffset(T, { hour = 16, minute = 43 }))
        assert.are.equal(-8 * H, Util.ServerOffset(NEAR_MIDNIGHT, { hour = 15, minute = 30 }))
    end)

    it("names an offset", function()
        assert.are.same({ "UTC", "UTC+1", "UTC-5:30", "UTC+5:45" },
            { Util.OffsetName(0), Util.OffsetName(H), Util.OffsetName(-5 * H - HALF), Util.OffsetName(5 * H + 45 * 60) })
    end)

    it("the active hours of competitors follow the shown clock", function()
        local ns = helper.load()
        ns.Date = function(fmt, t) return ns.Util.Date(fmt, t, H) end
        local state = {}
        ns.Competition.Init(state)
        state.events[1] = { t = NEAR_MIDNIGHT, id = 1, p = 90, my = 100, g = 10, q = 1, u = 1, o = "Bob" }
        local list = ns.Competition.Competitors(state)
        assert.are.equal(0, list[1].hourOrder[1].h)   -- 23:30 UTC is 00:30 on the realm's clock
    end)
end)

describe("Times in a simulated client", function()
    local env, ns
    local function calendar(offset)
        local c = os.date("!*t", env.clock + offset)
        env.cal = { year = c.year, month = c.month, monthDay = c.day, hour = c.hour, minute = c.min, weekday = c.wday }
    end
    -- An hour later; the realm's clock then is UTC + `offset`.
    local function nextHour(offset)
        env.clock = env.clock + H
        calendar(offset)
        env.now = env.now + H
        wow.tick(ns, 0.1)
    end
    before_each(function()
        env = wow.install()
        env.clock = T
        calendar(H)                                 -- the realm runs on UTC+1
        _G.C_DateAndTime = { GetCurrentCalendarTime = function() return env.cal end }
        ns = wow.loadAddon()
        wow.fire(ns, "ADDON_LOADED", "Salvager")
        wow.fire(ns, "PLAYER_ENTERING_WORLD", false, false)
    end)
    after_each(function() _G.C_DateAndTime, _G.GetGameTime = nil, nil end)

    local function pickServer()
        ns.Options.Open()
        local drop = _G.SalvagerOptionsFrame.timesDrop
        drop.checks[2]:Click()
        return drop
    end

    it("shows local time first, and server time once the option says so, and the windows draw again", function()
        assert.are.equal("local", ns.db.settings.timeZone)
        assert.are.equal(os.date("%H:%M", T), ns.Clock(T))
        assert.are.equal("local time", ns.TimesName())
        local drawn = 0
        ns.On("SALVAGER_SETTINGS", function() drawn = drawn + 1 end)
        pickServer()
        assert.are.equal("server", ns.db.settings.timeZone)
        assert.are.equal(1, drawn)
        assert.are.equal("23:13", ns.Clock(T))
        assert.are.equal("server time", ns.TimesName())
        assert.is_truthy(ns.TimesNote():find("UTC+1", 1, true))
        -- The statements' period line and the help on time titles say which clock.
        ns.Reports.range = "24h"
        assert.is_truthy(ns.Reports.StatementRows()[2].cells[1]:find("times in server time", 1, true))
        local help = ns.TimeHelp("Bought", "When you bought it.")
        assert.is_truthy(help[2]():find("Times in server time", 1, true))
        -- The log writes its lines on that clock.
        ns.Log("a line")
        assert.is_truthy(ns.LogText(ns.db.log[#ns.db.log]):find("^23:13:20 INFO ui: a line"))
        -- Back to local.
        ns.Options.Open() ns.Options.Open()
        _G.SalvagerOptionsFrame.timesDrop.checks[1]:Click()
        assert.are.equal(os.date("%H:%M", T), ns.Clock(T))
    end)

    it("puts a purchase near midnight under the realm's day", function()
        pickServer()
        ns.Ledger.AuctionPurchase(ns.db.ledger, 1001, 500, 600, NEAR_MIDNIGHT, nil)
        local rows = ns.LedgerWindow.PurchaseRows()
        assert.is_truthy(rows[1].cells[1]:find("Wed 11-15", 1, true))
        nextHour(-5 * H - HALF)
        rows = ns.LedgerWindow.PurchaseRows()
        assert.is_truthy(rows[1].cells[1]:find("Tue 11-14", 1, true))
    end)

    it("follows a daylight saving change of the realm at the next hourly reading", function()
        pickServer()
        assert.are.equal("23:13", ns.Clock(T))
        local drawn = 0
        ns.On("SALVAGER_SETTINGS", function() drawn = drawn + 1 end)
        calendar(2 * H)                              -- the realm moves its clock one hour on
        env.now = env.now + H / 2
        wow.tick(ns, 0.1)
        assert.are.equal("23:13", ns.Clock(T))        -- not read yet
        env.now = env.now + H / 2
        wow.tick(ns, 0.1)
        assert.are.equal("00:13", ns.Clock(T))        -- read at the hour
        assert.are.equal(1, drawn)
        assert.is_truthy(ns.LogText(ns.db.log[#ns.db.log]):find("server time: UTC+2 (was UTC+1)", 1, true))
    end)

    it("reads the realm's hours and minutes where the calendar time is missing", function()
        _G.C_DateAndTime = nil
        _G.GetGameTime = function() return env.cal.hour, env.cal.minute end
        nextHour(-5 * H - HALF)                      -- 23:13 UTC, the realm's 17:43
        pickServer()
        assert.is_truthy(ns.TimesNote():find("UTC-5:30", 1, true))
        assert.are.equal("17:43", ns.Clock())
    end)
end)

describe("Every shown time goes through ns.Date", function()
    it("no other date() in the addon (Util.Date is the one; reading times back is marked \"not shown\")", function()
        local stray = {}
        for line in io.lines("Salvager/Salvager.toc") do
            local file = line:match("^([%w_]+)%.lua$")
            if file and file ~= "Util" then
                local n = 0
                for text in io.lines("Salvager/" .. file .. ".lua") do
                    n = n + 1
                    local code = text:gsub("%-%-.*$", "")
                    if (code:find("os%.date") or (" " .. code):find("[^%w_%.]date%(")) and not text:find("not shown") then
                        stray[#stray + 1] = file .. ".lua:" .. n
                    end
                end
            end
        end
        assert.are.same({}, stray)
    end)
end)

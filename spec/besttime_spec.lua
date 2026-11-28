local helper = require("spec.helper")

describe("Highest at / Lowest at (History.BestTime, pure)", function()
    local History
    local ID = 11137
    local NOW = 1795000000 - (1795000000 % 86400) + 86400 * 0.5   -- noon UTC
    local function utcHour(t) return math.floor(t / 3600) % 24 end

    setup(function() History = helper.load().History end)

    -- One point an hour for `days` days back from NOW; price(hour, day) gives each.
    local function build(days, price, every)
        local state = {}
        for t = NOW - days * 86400 + 1, NOW, (every or 3600) do
            local p = price(utcHour(t), math.floor(t / 86400))
            if p then History.Add(state, ID, t, p) end
        end
        return state
    end

    local function bump(hours, by)
        local set = {}
        for _, h in ipairs(hours) do set[h] = true end
        return function(h) return 1000 + (set[h] and by or 0) end
    end

    it("finds the 3 hours when the price is highest, and the ones when it is lowest", function()
        local state = build(14, function(h)
            if h >= 18 and h <= 20 then return 1100 end
            if h >= 4 and h <= 6 then return 900 end
            return 1000
        end)
        local high = History.BestTime(state, ID, NOW, utcHour, "high")
        assert.are.equal("ok", high.status)
        assert.are.equal(18, high.from)
        assert.are.equal(21, high.to)
        assert.is_true(high.diff > 0.08 and high.diff < 0.11, tostring(high.diff))
        assert.are.equal("18:00-21:00", History.WindowText(high))
        local low = History.BestTime(state, ID, NOW, utcHour, "low")
        assert.are.equal("ok", low.status)
        assert.are.equal(4, low.from)
        assert.is_true(low.diff < -0.08, tostring(low.diff))
    end)

    it("wraps the window at midnight", function()
        local state = build(14, bump({ 23, 0, 1 }, 150))
        local r = History.BestTime(state, ID, NOW, utcHour, "high")
        assert.are.equal("ok", r.status)
        assert.are.equal(23, r.from)
        assert.are.equal(2, r.to)
        assert.are.equal("23:00-02:00", History.WindowText(r))
    end)

    it("follows the clock it is given (the Times option)", function()
        local state = build(14, bump({ 18, 19, 20 }, 150))
        local function plus3(t) return (utcHour(t) + 3) % 24 end
        assert.are.equal(21, History.BestTime(state, ID, NOW, plus3, "high").from)
    end)

    it("says few data with less than 3 days or less than 12 hours of the day", function()
        local two = build(1, bump({ 18, 19, 20 }, 150))
        local r = History.BestTime(two, ID, NOW, utcHour, "high")
        assert.are.equal("few", r.status)
        assert.is_nil(r.from)
        assert.is_nil(History.WindowText(r))
        -- 14 days, but only from 08:00 to 17:00: 10 hours of the day.
        local narrow = build(14, function(h) if h >= 8 and h < 18 then return 1000 + (h == 12 and 200 or 0) end end)
        assert.are.equal("few", History.BestTime(narrow, ID, NOW, utcHour, "high").status)
        assert.are.equal("few", History.BestTime({}, ID, NOW, utcHour, "low").status)
    end)

    it("says no clear time when no window stands out", function()
        local flat = build(14, function() return 1000 end)
        assert.are.equal("none", History.BestTime(flat, ID, NOW, utcHour, "high").status)
        assert.are.equal("none", History.BestTime(flat, ID, NOW, utcHour, "low").status)
        -- 1 % higher at night is not clear.
        local slight = build(14, bump({ 1, 2, 3 }, 10))
        assert.are.equal("none", History.BestTime(slight, ID, NOW, utcHour, "high").status)
    end)

    it("is not fooled by a price that rises over the days: each point counts against its own day", function()
        -- 2 % more each day, the same at every hour of a day.
        local state = build(14, function(_, day) return math.floor(1000 * 1.02 ^ (day % 1000)) end)
        assert.are.equal("none", History.BestTime(state, ID, NOW, utcHour, "high").status)
    end)

    it("looks at the last 14 days only", function()
        local state = {}
        -- 20 to 15 days ago: highest at 06:00; the last 14 days: highest at 18:00.
        for t = NOW - 20 * 86400, NOW, 3600 do
            local h, old = utcHour(t), t < NOW - 14 * 86400
            local high = old and (h >= 6 and h <= 8) or (not old and h >= 18 and h <= 20)
            History.Add(state, ID, t, high and 1200 or 1000)
        end
        assert.are.equal(18, History.BestTime(state, ID, NOW, utcHour, "high").from)
    end)

    it("skips points without a price (nothing listed)", function()
        local state, f = {}, bump({ 18, 19, 20 }, 150)
        local k = 0
        for t = NOW - 14 * 86400 + 1, NOW, 1800 do
            -- Every second point has no price; a missing price at 18-21 must not count as low.
            k = k + 1
            History.Add(state, ID, t, k % 2 == 0 and f(utcHour(t)) or nil)
        end
        local r = History.BestTime(state, ID, NOW, utcHour, "high")
        assert.are.equal(18, r.from)
    end)
end)

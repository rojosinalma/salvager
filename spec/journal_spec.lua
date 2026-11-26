local helper = require("spec.helper")

describe("Journal", function()
    local J

    before_each(function() J = helper.load().Journal end)

    it("starts a character without a change, then records each change with its kind", function()
        local s = J.Init({})
        assert.is_nil(J.Seen(s, "A-R", 1000, 10))
        assert.is_nil(J.Seen(s, "A-R", 1000, 20))                -- no change, no entry
        local e = J.Seen(s, "A-R", 400, 30, "buy", "[Boots]")
        assert.are.same({ -600, 400, "buy", "[Boots]" }, { e.d, e.b, e.k, e.r })
        assert.are.equal(2, #s.entries)                           -- the start and the purchase
        assert.are.equal("other", J.Seen(s, "A-R", 450, 40).k)
    end)

    it("sums a period by kind, from the balance before it", function()
        local s = J.Init({})
        J.Seen(s, "A-R", 1000, 10)
        J.Seen(s, "A-R", 900, 20, "buy")
        J.Seen(s, "A-R", 2900, 30, "sale")
        J.Seen(s, "A-R", 2800, 40, "buy")
        J.Seen(s, "B-R", 50, 25)                                  -- another character does not count
        local sum = J.Summary(s, "A-R", 15, 100)
        assert.are.equal(1000, sum.start)
        assert.are.equal(2800, sum.finish)
        assert.are.equal(1800, sum.change)
        assert.are.same({ gain = 0, loss = -200, n = 2 }, sum.kinds.buy)
        assert.are.same({ gain = 2000, loss = 0, n = 1 }, sum.kinds.sale)
        local quiet = J.Summary(s, "A-R", 50, 100)                -- nothing happened: the balance then
        assert.are.same({ 2800, 2800, 0 }, { quiet.start, quiet.finish, quiet.change })
    end)

    it("matches a change to the exact amount first, then to its sign, and forgets old expectations", function()
        local list = {}
        J.Expect(list, { k = "deposit", sign = -1 }, 0, 10)
        J.Expect(list, { k = "buy", a = -500, r = "[Boots]" }, 0, 10)
        assert.are.same({ "buy", "[Boots]" }, { J.Match(list, -500, 1) })
        assert.is_nil(J.Match(list, 300, 1))                      -- a gain is no deposit
        assert.are.equal("deposit", J.Match(list, -60, 1))
        J.Expect(list, { k = "buy", a = -500 }, 0, 10)
        assert.is_nil(J.Match(list, -500, 11))                    -- too late
    end)

    it("stays bounded", function()
        local s = J.Init({})
        J.Seen(s, "A-R", 0, 0)
        for i = 1, J.MAX + 10 do J.Seen(s, "A-R", i, i) end
        assert.are.equal(J.MAX, #s.entries)
    end)
end)

-- Salvager: a small time chart. Lines over time, flat lines for fixed values (a break-even), and a
-- strip of bars under them (units listed). The caller anchors the returned frame.
--   chart:SetData({
--     from = t, to = t,
--     lines  = { { points = { { t, value }, ... }, color = { r, g, b }, label = text }, ... },
--     levels = { { value = v, color = { r, g, b }, label = text }, ... },
--     bars   = { points = { { t, value }, ... }, label = text },
--     format = function(value) -> text      (the scale's labels; default: money)
--     empty  = text shown when there is nothing to draw
--   })
local _, ns = ...

local Widgets = ns.Widgets

function Widgets.Chart(parent)
    local LEFT, BOTTOM, TOP, BARS = 78, 18, 20, 0.2   -- room for the scale, the times, the legend; the bars' share
    local chart = Widgets.Panel(parent, 0, 0, 0, 0.5)
    local plot = CreateFrame("Frame", nil, chart)
    plot:SetPoint("TOPLEFT", chart, "TOPLEFT", LEFT, -TOP)
    plot:SetPoint("BOTTOMRIGHT", chart, "BOTTOMRIGHT", -12, BOTTOM)
    local legend = chart:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    legend:SetPoint("TOPLEFT", chart, "TOPLEFT", LEFT, -5)
    legend:SetPoint("RIGHT", chart, "RIGHT", -12, 0)
    legend:SetJustifyH("LEFT")
    legend:SetWordWrap(false)
    local empty = chart:CreateFontString(nil, "OVERLAY", "GameFontDisable")
    empty:SetPoint("CENTER", plot, "CENTER", 0, 0)
    local scale, times, grid = {}, {}, {}
    for i = 1, 3 do
        local fs = chart:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetJustifyH("RIGHT")
        scale[i] = fs
        local g = plot:CreateTexture(nil, "BACKGROUND")
        g:SetColorTexture(1, 1, 1, 0.06)
        g:SetHeight(1)
        grid[i] = g
    end
    for i = 1, 2 do
        times[i] = chart:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    end
    times[1]:SetPoint("TOPLEFT", plot, "BOTTOMLEFT", 0, -3)
    times[2]:SetPoint("TOPRIGHT", plot, "BOTTOMRIGHT", 0, -3)

    -- Drawn things are made once and used again.
    local pools = { line = {}, dot = {}, bar = {} }
    local used = { line = 0, dot = 0, bar = 0 }
    local canLine
    local function take(kind)
        used[kind] = used[kind] + 1
        local obj = pools[kind][used[kind]]
        if not obj then
            if kind == "line" then
                obj = plot:CreateLine(nil, "ARTWORK")
            else
                obj = plot:CreateTexture(nil, kind == "bar" and "BORDER" or "ARTWORK")
            end
            pools[kind][used[kind]] = obj
        end
        if type(obj) == "table" then obj:Show() end
        return obj
    end
    local function segment(x1, y1, x2, y2, c, thick)
        if canLine == nil then
            local probe = plot:CreateLine(nil, "ARTWORK")
            canLine = type(probe) == "table"
            if canLine then pools.line[#pools.line + 1] = probe end
        end
        if canLine then
            local l = take("line")
            l:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
            l:SetThickness(thick or 2)
            l:SetStartPoint("BOTTOMLEFT", plot, x1, y1)
            l:SetEndPoint("BOTTOMLEFT", plot, x2, y2)
        else
            -- A client without line objects: a dot at each end.
            for _, p in ipairs({ { x1, y1 }, { x2, y2 } }) do
                local dot = take("dot")
                dot:SetColorTexture(c[1], c[2], c[3], c[4] or 1)
                dot:SetSize(3, 3)
                dot:ClearAllPoints()
                dot:SetPoint("CENTER", plot, "BOTTOMLEFT", p[1], p[2])
            end
        end
    end

    function chart:SetData(data) self.data = data end

    --- The lowest and highest value of everything on the money scale. Pure: used by the tests.
    function chart.Bounds(data)
        local lo, hi
        local function see(v)
            if v then
                lo = (not lo or v < lo) and v or lo
                hi = (not hi or v > hi) and v or hi
            end
        end
        for _, line in ipairs(data.lines or {}) do
            for _, p in ipairs(line.points) do see(p[2]) end
        end
        for _, level in ipairs(data.levels or {}) do see(level.value) end
        if not lo then return nil end
        local pad = math.max(1, (hi - lo) * 0.08)
        return math.max(0, lo - pad), hi + pad
    end

    function chart:Refresh()
        local data = self.data or {}
        for kind, pool in pairs(pools) do
            for i = 1, #pool do if type(pool[i]) == "table" then pool[i]:Hide() end end
            used[kind] = 0
        end
        local w, h = tonumber(plot:GetWidth()) or 0, tonumber(plot:GetHeight()) or 0
        local lo, hi = chart.Bounds(data)
        local from, to = data.from, data.to
        local any = lo ~= nil and from and to and to > from and w > 10 and h > 10
        empty:SetText(any and "" or (data.empty or "Nothing to show yet."))
        legend:SetText("")
        for i = 1, 3 do scale[i]:SetText("") grid[i]:Hide() end
        times[1]:SetText("") times[2]:SetText("")
        if not any then return end
        local format = data.format or ns.Money
        local bars = data.bars and #data.bars.points > 0 and data.bars or nil
        local base = bars and h * BARS or 0          -- the lines sit above the bars
        local function x(t) return (t - from) / (to - from) * w end
        local function y(v) return base + (v - lo) / (hi - lo) * (h - base) end
        for i, v in ipairs({ hi, (hi + lo) / 2, lo }) do
            scale[i]:ClearAllPoints()
            scale[i]:SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, y(v))
            scale[i]:SetText(format(math.floor(v + 0.5)))
            grid[i]:ClearAllPoints()
            grid[i]:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y(v))
            grid[i]:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, y(v))
            grid[i]:Show()
        end
        times[1]:SetText(date("%m-%d %H:%M", from))
        times[2]:SetText(date("%m-%d %H:%M", to))
        local names = {}
        if bars then
            local top = 0
            for _, p in ipairs(bars.points) do if (p[2] or 0) > top then top = p[2] end end
            local barW = math.max(2, math.min(10, w / math.max(1, #bars.points) - 1))
            for _, p in ipairs(bars.points) do
                if top > 0 and (p[2] or 0) > 0 and p[1] >= from and p[1] <= to then
                    local bar = take("bar")
                    bar:SetColorTexture(0.35, 0.6, 1, 0.45)
                    bar:ClearAllPoints()
                    bar:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", math.min(w - barW, math.max(0, x(p[1]) - barW / 2)), 0)
                    bar:SetSize(barW, math.max(1, p[2] / top * base * 0.9))
                end
            end
            names[#names + 1] = string.format("|cff5999ff%s|r (highest bar: %d)", bars.label or "", top)
        end
        for _, level in ipairs(data.levels or {}) do
            local c = level.color
            segment(0, y(level.value), w, y(level.value), { c[1], c[2], c[3], 0.8 }, 1)
            names[#names + 1] = string.format("|cff%02x%02x%02x%s|r %s", c[1] * 255, c[2] * 255, c[3] * 255,
                level.label or "", format(level.value))
        end
        for _, line in ipairs(data.lines or {}) do
            local c, prev = line.color, nil
            for _, p in ipairs(line.points) do
                if p[2] and p[1] >= from and p[1] <= to then
                    if prev then segment(x(prev[1]), y(prev[2]), x(p[1]), y(p[2]), c, 2) end
                    prev = p
                else
                    prev = nil
                end
            end
            -- One point alone still shows.
            if #line.points == 1 and line.points[1][2] then
                local p = line.points[1]
                segment(math.max(0, x(p[1]) - 2), y(p[2]), math.min(w, x(p[1]) + 2), y(p[2]), c, 3)
            end
            table.insert(names, 1, string.format("|cff%02x%02x%02x%s|r", c[1] * 255, c[2] * 255, c[3] * 255,
                line.label or ""))
        end
        legend:SetText(table.concat(names, "     "))
    end

    chart:SetScript("OnSizeChanged", function() chart:Refresh() end)
    return chart
end

-- Salvager: a small time chart. Lines over time, flat lines for fixed values (a break-even), and a
-- strip of bars under them (units listed). The caller anchors the returned frame.
--   chart:SetData({
--     from = t, to = t,
--     lines  = { { points = { { t, value }, ... }, color = { r, g, b }, label = text }, ... },
--     levels = { { value = v, color = { r, g, b }, label = text }, ... },
--     bars   = { points = { { t, value }, ... }, label = text },
--     format = function(value) -> text      (the scale's labels; default: money)
--     xFormat = function(x) -> text         (the labels under the two ends; default: date and time)
--     xTicks = { { x, label or nil }, ... } (marks on the time axis; a label under the ones that have one,
--                                            in place of the two end labels)
--     negative = true                       (the scale may go below zero)
--     empty  = text shown when there is nothing to draw
--   })
-- The mouse over the chart shows the values at the point nearest to it: a mark, a dot on each line, and a
-- tooltip with the time and each value.
local _, ns = ...

local Widgets = ns.Widgets

function Widgets.Chart(parent)
    -- Room for the scale (LEFT until it is measured: its widest label + 6 px to the axis + 8 px from the edge, 0.4.0),
    -- the times, the legend; the bars' share.
    local LEFT, BOTTOM, TOP, BARS = 78, 18, 20, 0.2
    local chart = Widgets.Panel(parent, 0, 0, 0, 0.5)
    local plot = CreateFrame("Frame", nil, chart)
    plot:SetPoint("TOPLEFT", chart, "TOPLEFT", LEFT, -TOP)
    plot:SetPoint("BOTTOMRIGHT", chart, "BOTTOMRIGHT", -12, BOTTOM)
    local legend = chart:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    legend:SetPoint("TOPLEFT", chart, "TOPLEFT", LEFT, -5)
    legend:SetPoint("RIGHT", chart, "RIGHT", -12, 0)
    legend:SetJustifyH("LEFT")
    -- The legend wraps; the plot starts under its lines (UI.md Layout 6). The plot starts right of the scale's widest
    -- label (the labels went past the chart's left edge, 0.4.0, the user: nothing outside its window).
    local plotTop, plotLeft = TOP, LEFT
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
    local tickMarks, tickLabels = {}, {}

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

    --- The values at the moment nearest to `t` that has one: its time, and per line, the bars and each level,
    --- { label, color, value } (a line with no point at that moment is left out). Pure: used by the tests.
    function chart.Nearest(data, t)
        local best
        local function see(p)
            if p[2] and p[1] >= (data.from or -math.huge) and p[1] <= (data.to or math.huge)
                and (not best or math.abs(p[1] - t) < math.abs(best - t)) then best = p[1] end
        end
        for _, line in ipairs(data.lines or {}) do for _, p in ipairs(line.points) do see(p) end end
        if data.bars then for _, p in ipairs(data.bars.points) do see(p) end end
        if not best then return nil end
        local out = { t = best, values = {} }
        for _, line in ipairs(data.lines or {}) do
            for _, p in ipairs(line.points) do
                if p[1] == best and p[2] then
                    out.values[#out.values + 1] = { label = line.label, color = line.color, value = p[2], line = true }
                    break
                end
            end
        end
        if data.bars then
            for _, p in ipairs(data.bars.points) do
                if p[1] == best and p[2] then
                    out.values[#out.values + 1] = { label = data.bars.label, color = { 0.35, 0.6, 1 }, value = p[2],
                        count = true }
                    break
                end
            end
        end
        for _, level in ipairs(data.levels or {}) do
            out.values[#out.values + 1] = { label = level.label, color = level.color, value = level.value }
        end
        return out
    end

    -- The mark under the mouse: a thin vertical line, and a dot on each line at that moment.
    local mark = plot:CreateTexture(nil, "OVERLAY")
    mark:SetColorTexture(1, 1, 1, 0.35)
    mark:SetWidth(1)
    mark:Hide()
    local marks = {}
    local view   -- what the last Refresh drew: { x = fn, y = fn, w, from, to }
    local function hideMarks()
        mark:Hide()
        for _, d in ipairs(marks) do d:Hide() end
        if GameTooltip:IsOwned(plot) then GameTooltip:Hide() end
    end
    local function hover()
        if not view then return hideMarks() end
        local cx = GetCursorPosition()
        local scaleUI = plot:GetEffectiveScale() or 1
        local left = plot:GetLeft()
        if not cx or not left then return end
        local px = cx / scaleUI - left
        local t = view.from + math.max(0, math.min(1, px / view.w)) * (view.to - view.from)
        local n = chart.Nearest(chart.data or {}, t)
        if not n then return hideMarks() end
        local mx = view.x(n.t)
        mark:ClearAllPoints()
        mark:SetPoint("TOPLEFT", plot, "TOPLEFT", mx, 0)
        mark:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", mx, 0)
        mark:Show()
        local data = chart.data
        local format = data.format or ns.Money
        local xFormat = data.xFormat or function(at) return ns.Date("%m-%d %H:%M", at) end
        GameTooltip:SetOwner(plot, "ANCHOR_CURSOR")
        GameTooltip:SetText(xFormat(n.t), 1, 1, 1)
        local d = 0
        for _, v in ipairs(n.values) do
            local c = v.color or { 1, 1, 1 }
            GameTooltip:AddDoubleLine(v.label or "", v.count and tostring(v.value) or format(math.floor(v.value + 0.5)),
                c[1], c[2], c[3], 1, 1, 1)
            if v.line then
                d = d + 1
                local dot = marks[d]
                if not dot then
                    dot = plot:CreateTexture(nil, "OVERLAY")
                    dot:SetSize(6, 6)
                    marks[d] = dot
                end
                dot:SetColorTexture(c[1], c[2], c[3], 1)
                dot:ClearAllPoints()
                dot:SetPoint("CENTER", plot, "BOTTOMLEFT", mx, view.y(v.value))
                dot:Show()
            end
        end
        for i = d + 1, #marks do marks[i]:Hide() end
        GameTooltip:Show()
    end
    plot:EnableMouse(true)
    plot:SetScript("OnEnter", function(self) self:SetScript("OnUpdate", hover) end)
    plot:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        hideMarks()
    end)

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
        return data.negative and (lo - pad) or math.max(0, lo - pad), hi + pad
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
        view = nil
        if not any then return end
        local format = data.format or ns.Money
        local bars = data.bars and #data.bars.points > 0 and data.bars or nil
        local base = bars and h * BARS or 0          -- the lines sit above the bars
        local function x(t) return (t - from) / (to - from) * w end
        local function y(v) return base + (v - lo) / (hi - lo) * (h - base) end
        view = { x = x, y = y, w = w, from = from, to = to }
        -- The scale's labels, right-aligned against the axis, each as wide as the widest (measured in its own font).
        local widest = 0
        for i, v in ipairs({ hi, (hi + lo) / 2, lo }) do
            scale[i]:SetWidth(0)
            scale[i]:SetText(format(math.floor(v + 0.5)))
            widest = math.max(widest, tonumber(((scale[i].GetUnboundedStringWidth or scale[i].GetStringWidth)(scale[i]))) or 0)
        end
        local left = math.ceil(widest) + 2 + 6 + 8
        if left ~= plotLeft then
            plotLeft = left
            plot:SetPoint("TOPLEFT", chart, "TOPLEFT", left, -plotTop)
            legend:SetPoint("TOPLEFT", chart, "TOPLEFT", left, -5)
            return chart:Refresh()   -- (once: drawn again in the plot's new width)
        end
        chart.scaleLeft = left
        for i, v in ipairs({ hi, (hi + lo) / 2, lo }) do
            scale[i]:ClearAllPoints()
            scale[i]:SetPoint("RIGHT", plot, "BOTTOMLEFT", -6, y(v))
            scale[i]:SetWidth(math.ceil(widest) + 2)
            scale[i].chartLabel = true   -- (the checks find them: inside the chart, never cut)
            grid[i]:ClearAllPoints()
            grid[i]:SetPoint("BOTTOMLEFT", plot, "BOTTOMLEFT", 0, y(v))
            grid[i]:SetPoint("BOTTOMRIGHT", plot, "BOTTOMRIGHT", 0, y(v))
            grid[i]:Show()
        end
        local xFormat = data.xFormat or function(t) return ns.Date("%m-%d %H:%M", t) end
        for _, m in ipairs(tickMarks) do m:Hide() end
        for _, l in ipairs(tickLabels) do l:Hide() end
        if data.xTicks then
            -- Marks on the axis, a label under the ones that have one (the end labels give way to them).
            local nl = 0
            for i, tk in ipairs(data.xTicks) do
                local m = tickMarks[i]
                if not m then
                    m = plot:CreateTexture(nil, "BACKGROUND")
                    m:SetColorTexture(1, 1, 1, 0.12)
                    m:SetWidth(1)
                    tickMarks[i] = m
                end
                m:ClearAllPoints()
                m:SetPoint("BOTTOM", plot, "BOTTOMLEFT", x(tk[1]), 0)
                m:SetHeight(tk[2] and h or 4)
                m:SetAlpha(tk[2] and 1 or 0.6)
                m:Show()
                if tk[2] then
                    nl = nl + 1
                    local l = tickLabels[nl]
                    if not l then
                        l = chart:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
                        tickLabels[nl] = l
                    end
                    l:SetText(tk[2])
                    -- (Centred under its mark, but kept inside the plot's width: the last one went past the
                    -- window's edge, 0.4.0.)
                    local lw = math.ceil(tonumber((l:GetStringWidth())) or 0) + 2
                    local lx = math.max(0, math.min(w - lw, x(tk[1]) - lw / 2))
                    l:SetWidth(lw)
                    l:ClearAllPoints()
                    l:SetPoint("TOPLEFT", plot, "BOTTOMLEFT", lx, -3)
                    l:Show()
                end
            end
        else
            times[1]:SetText(xFormat(from))
            times[2]:SetText(xFormat(to))
        end
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
        local top = math.max(TOP, math.ceil(tonumber((legend:GetStringHeight())) or 0) + 8)
        if top ~= plotTop then
            plotTop = top
            plot:SetPoint("TOPLEFT", chart, "TOPLEFT", plotLeft, -top)
            return chart:Refresh()   -- (once: drawn again in the plot's new height)
        end
    end

    chart:SetScript("OnSizeChanged", function() chart:Refresh() end)
    return chart
end

-- A small stand-in for the WoW client, enough to load the whole addon and
-- drive it through events. Only what Salvager calls is modelled.
local M = {}

local function noop() end

-- True when `region` is `target` or is anchored, directly or through others, to it.
local function dependsOn(region, target, seen)
    if region == target then return true end
    seen = seen or {}
    if type(region) ~= "table" or seen[region] then return false end
    seen[region] = true
    for _, p in ipairs(rawget(region, "points") or {}) do
        for i = 1, #p do
            if type(p[i]) == "table" and dependsOn(p[i], target, seen) then return true end
        end
    end
    return false
end

local widget

-- The methods every widget shares, as the client's do (one table, so a hook on it reaches every widget). Made new
-- by each install, so a hook from one load does not stay for the next.
local function newMethods()
    local methods = {
        SetScript = function(self, name, fn) self.scripts[name] = fn end,
        GetScript = function(self, name) return self.scripts[name] end,
        RegisterEvent = function(self, e) self.events[e] = true end,
        Show = function(self) self.shown = true if self.scripts.OnShow then self.scripts.OnShow(self) end end,
        Hide = function(self)
            local was = self.shown
            self.shown = false
            if was and self.scripts.OnHide then self.scripts.OnHide(self) end
        end,
        SetShown = function(self, v) if v then self:Show() else self:Hide() end end,
        IsShown = function(self) return self.shown end,
        SetText = function(self, t) self.text = t end,
        GetText = function(self) return self.text end,
        SetChecked = function(self, v) self.checked = v end,
        GetChecked = function(self) return self.checked end,
        HasFocus = function() return false end,
        IsMouseOver = function(self) return rawget(self, "mouseOver") or false end,
        UnregisterEvent = function(self, e) self.events[e] = nil end,
        SetEnabled = function(self, v) self.enabled = v and true or false end,
        IsEnabled = function(self) return self.enabled ~= false end,
        GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end,
        -- The anchors set, in order, so a spec can tell what a region hangs on.
        SetPoint = function(self, ...)
            -- The client refuses an anchor to a region that depends on this one (a loop): so does the stand-in.
            for i = 1, select("#", ...) do
                local rel = select(i, ...)
                if type(rel) == "table" and dependsOn(rel, self) then
                    error("Action[SetPoint] failed because[Cannot anchor to a region dependent on it]", 2)
                end
            end
            rawset(self, "points", rawget(self, "points") or {}) table.insert(self.points, { ... })
        end,
        ClearAllPoints = function(self) rawset(self, "points", nil) end,
        GetParent = function(self) return self.parent end,
        CreateFontString = function(self, _, layer, template)
            local fs = widget("FontString") fs.parent = self fs.layer = layer fs.template = template
            table.insert(self._regions, fs)
            return fs
        end,
        CreateTexture = function(self, _, layer)
            local t = widget("Texture") t.parent = self t.layer = layer
            table.insert(self._regions, t)
            return t
        end,
        -- The tree, as the client walks it: child frames, and the regions (texts, textures) of a frame.
        GetChildren = function(self) return unpack(self._children) end,
        GetRegions = function(self) return unpack(self._regions) end,
        GetObjectType = function(self) return self.kind end,
        GetName = function(self) return rawget(self, "_name") end,
        IsVisible = function(self)
            local p = rawget(self, "parent")
            return self.shown and (type(p) ~= "table" or p == _G.UIParent or p:IsVisible())
        end,
        GetRect = function(self) return 0, 0, self:GetWidth(), self:GetHeight() end,
        -- As the client: PreClick, OnClick, PostClick; a disabled button does nothing.
        Click = function(self, button)
            if self.enabled == false then return end
            if self.scripts.PreClick then self.scripts.PreClick(self, button) end
            if self.scripts.OnClick then self.scripts.OnClick(self, button) end
            if self.scripts.PostClick then self.scripts.PostClick(self, button) end
        end,
        SetAttribute = function(self, k, v)
            rawset(self, "attrs", rawget(self, "attrs") or {})
            self.attrs[k] = v
        end,
        GetAttribute = function(self, k) return (rawget(self, "attrs") or {})[k] end,
        CreateAnimationGroup = function() return widget("AnimationGroup") end,
        CreateAnimation = function() return widget("Animation") end,
        GetWidth = function() return 140 end,
        GetHeight = function() return 560 end,
        GetCenter = function() return 500, 500 end,
        GetEffectiveScale = function() return 1 end,
        HookScript = function(self, name, fn)
            local old = self.scripts[name]
            self.scripts[name] = function(...) if old then old(...) end fn(...) end
        end,
        -- What the layout dump reads of a text: its font, justification and color.
        GetFont = function() return "Fonts\\FRIZQT__.TTF", 10, "" end,
        SetJustifyH = function(self, j) self.justifyH = j end,
        GetJustifyH = function(self) return rawget(self, "justifyH") or "CENTER" end,
        SetTextColor = function(self, r, g, b, a) self.textColor = { r, g, b, a or 1 } end,
        GetTextColor = function(self)
            local c = rawget(self, "textColor") or { 1, 1, 1, 1 }
            return c[1], c[2], c[3], c[4]
        end,
        GetDrawLayer = function(self) return rawget(self, "layer") end,
        GetScale = function() return 1 end,
    }
    return setmetatable(methods, { __index = function() return noop end })
end

------------------------------------------------------------------ layout mode (wow.install({ layout = true }))
-- Sizes, anchors and text widths, enough to tell where each region is and how wide its text is. Off by default:
-- the other specs keep the constant sizes they were written against.

-- Font sizes of the game's font objects (the ones Salvager uses).
local FONT_SIZE = {
    GameFontNormal = 12, GameFontHighlight = 12, GameFontDisable = 12,
    GameFontNormalSmall = 10, GameFontHighlightSmall = 10, GameFontDisableSmall = 10,
    GameFontNormalLarge = 16, GameFontHighlightLarge = 16,
}
M.FONT_SIZE = FONT_SIZE

-- A character's width, as a share of the font size, per size: Friz Quadrata (the game's font) as the client measured
-- it (GetUnboundedStringWidth) in the layout dump of 2026-11-28 (spec/fixtures/text_widths.lua, SDD 123): least
-- squares over 143 texts at 10 pt (the small fonts: titles, cells, labels) and 30 at 12 pt (buttons, headings, a
-- total's texts), each character pulled to its class's old share. Within 2 px of every sample (the old one share for
-- every size was 12 % off: digits narrower, capitals wider than drawn). A character not seen at a size takes its
-- 10 pt share, then its class's; sizes over 12 take the 12 pt shares.
local EM = {}
EM[10] = {
    [" "] = 0.254, ["%"] = 0.839, ["'"] = 0.338, ["("] = 0.401, [")"] = 0.401, ["*"] = 0.618, ["+"] = 0.623,
    [","] = 0.281, ["-"] = 0.473, ["."] = 0.333, ["0"] = 0.690, ["1"] = 0.605, ["2"] = 0.690, ["3"] = 0.650,
    ["4"] = 0.645, ["5"] = 0.683, ["6"] = 0.653, ["7"] = 0.657, ["8"] = 0.717, ["9"] = 0.679, [":"] = 0.291,
    ["<"] = 0.631, ["="] = 0.656, ["A"] = 0.832, ["B"] = 0.833, ["C"] = 0.816, ["D"] = 0.870, ["E"] = 0.720,
    ["G"] = 0.891, ["H"] = 0.865, ["I"] = 0.345, ["L"] = 0.767, ["M"] = 1.028, ["N"] = 0.875, ["O"] = 0.846,
    ["P"] = 0.787, ["Q"] = 0.872, ["R"] = 0.793, ["S"] = 0.699, ["T"] = 0.801, ["V"] = 0.799, ["["] = 0.480,
    ["]"] = 0.480, ["a"] = 0.624, ["b"] = 0.497, ["c"] = 0.588, ["d"] = 0.571, ["e"] = 0.598, ["f"] = 0.471,
    ["g"] = 0.634, ["h"] = 0.607, ["i"] = 0.298, ["k"] = 0.585, ["l"] = 0.290, ["m"] = 0.997, ["n"] = 0.667,
    ["o"] = 0.663, ["p"] = 0.703, ["q"] = 0.571, ["r"] = 0.388, ["s"] = 0.527, ["t"] = 0.488, ["u"] = 0.574,
    ["v"] = 0.588, ["w"] = 0.880, ["x"] = 0.662, ["y"] = 0.626, ["z"] = 0.597,
}
EM[12] = {
    [" "] = 0.368, [","] = 0.337, ["/"] = 0.485, ["1"] = 0.625, ["2"] = 0.625, ["4"] = 0.625, ["8"] = 0.629,
    ["9"] = 0.625, ["?"] = 0.614, ["A"] = 0.914, ["B"] = 0.805, ["C"] = 0.836, ["D"] = 0.873, ["E"] = 0.836,
    ["G"] = 0.856, ["L"] = 0.806, ["M"] = 0.910, ["R"] = 0.813, ["S"] = 0.768, ["T"] = 0.794, ["U"] = 0.836,
    ["W"] = 0.892, ["a"] = 0.587, ["b"] = 0.624, ["c"] = 0.551, ["d"] = 0.627, ["e"] = 0.584, ["g"] = 0.550,
    ["h"] = 0.630, ["i"] = 0.253, ["k"] = 0.644, ["l"] = 0.248, ["m"] = 0.808, ["n"] = 0.615, ["o"] = 0.641,
    ["p"] = 0.561, ["r"] = 0.530, ["s"] = 0.580, ["t"] = 0.419, ["u"] = 0.597, ["v"] = 0.577, ["w"] = 0.862,
    ["y"] = 0.578,
}
local CLASS_EM = {}
for c in ("ijlI.,:;!'|"):gmatch(".") do CLASS_EM[c] = 0.31 end
for c in ("frt -()/[]"):gmatch(".") do CLASS_EM[c] = 0.48 end
for c in ("mwMW%"):gmatch(".") do CLASS_EM[c] = 0.84 end
for c in ("ABCDEFGHJKLNOPQRSTUVXYZ"):gmatch(".") do CLASS_EM[c] = 0.85 end
for c in ("0123456789"):gmatch(".") do CLASS_EM[c] = 0.65 end
local OTHER_EM = 0.61   -- lower case and the rest
local function emOf(c, size)
    local own = size >= 12 and EM[12] or EM[10]
    return own[c] or EM[10][c] or CLASS_EM[c] or OTHER_EM
end
-- An inline texture of the font's height (|T path:0 |t) with its x offset: 8 % over the size (money icons, 10 pt).
local ICON_EM = 1.08

--- How wide `text` is in a font of `size` pt: the widest of its lines; color codes and link codes take no room, an
--- inline texture (|T path:h:w |t) is as wide as its size (h = 0: the font's size).
function M.textWidth(text, size)
    text = tostring(text or "")
    size = size or 12
    local most = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local w = 0
        line = line:gsub("|T(.-)|t", function(spec)
            local h, tw = spec:match("^[^:]*:(%-?%d*):?(%-?%d*)")
            h, tw = tonumber(h) or 0, tonumber(tw) or 0
            if h <= 0 then h = size * ICON_EM end
            w = w + (tw > 0 and tw or h)
            return ""
        end)
        line = line:gsub("|A(.-)|a", function() w = w + size return "" end)
            :gsub("|cn[^:]*:", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|H.-|h", ""):gsub("|h", "")
        for i = 1, #line do
            local b = line:byte(i)
            if b < 0x80 or b >= 0xC0 then   -- (one per character: UTF-8 continuation bytes are left out)
                w = w + emOf(line:sub(i, i), size) * size
            end
        end
        if w > most then most = w end
    end
    return most
end

local function fontSizeOf(font)
    if type(font) == "table" then return rawget(font, "size") or 12 end
    return FONT_SIZE[font] or 12
end
local function sizeOf(fs) return rawget(fs, "fontSize") or fontSizeOf(rawget(fs, "template")) end

-- The anchors of a region, one per point (a later SetPoint on the same point replaces the earlier one), with the
-- relative region and point filled in as the client does.
local POINTS = { TOPLEFT = { 0, 1 }, TOP = { 0.5, 1 }, TOPRIGHT = { 1, 1 }, LEFT = { 0, 0.5 }, CENTER = { 0.5, 0.5 },
    RIGHT = { 1, 0.5 }, BOTTOMLEFT = { 0, 0 }, BOTTOM = { 0.5, 0 }, BOTTOMRIGHT = { 1, 0 } }
local function anchorsOf(region)
    local out, order = {}, {}
    for _, p in ipairs(rawget(region, "points") or {}) do
        local point, a, b, c, d = p[1], p[2], p[3], p[4], p[5]
        local rel, relPoint, x, y
        if type(a) == "table" or type(a) == "string" then
            rel = type(a) == "string" and _G[a] or a
            if type(b) == "string" then relPoint, x, y = b, c, d else relPoint, x, y = point, b, c end
        else
            rel, relPoint, x, y = nil, point, a, b
        end
        if rel == nil then rel = rawget(region, "parent") end
        if not out[point] then order[#order + 1] = point end
        out[point] = { point = point, rel = rel, relPoint = relPoint, x = x or 0, y = y or 0 }
    end
    local list = {}
    for _, point in ipairs(order) do list[#list + 1] = out[point] end
    return list
end

local generation, rectCache, busy = 0, {}, {}
local function touch() generation = generation + 1 rectCache = {} end
M.touch = touch

local stringWidth   -- (below)

-- The region's own width or height where no pair of anchors sets it: the size set, or a text's own size.
local linesIn, wrapWidth   -- (below)
local function ownSize(region, axis, width)
    if axis == 1 then
        local w = rawget(region, "_w")
        if w and w > 0 then return w end
        if region.kind == "FontString" then return stringWidth(region) end
        return w or 0
    end
    local h = rawget(region, "_h")
    if h and h > 0 then return h end
    if region.kind == "FontString" then
        -- A text is as high as its lines: more than one where it wraps in the width it was given.
        local n = math.max(1, linesIn(region, wrapWidth(region, width)))
        return n * sizeOf(region) + (n - 1) * (rawget(region, "spacing") or 2)
    end
    return h or 0
end

--- The region's rect in UIParent's space: left, bottom, width, height; nil where it is not placed.
local function rectOf(region)
    if region == _G.UIParent then return 0, 0, 1920, 1080 end
    local c = rectCache[region]
    if c then return c[1], c[2], c[3], c[4] end
    if busy[region] then return nil end
    busy[region] = true
    local anchors = anchorsOf(region)
    local result
    local scrollParent = rawget(region, "_scrollParent")
    if #anchors == 0 and scrollParent then
        local l, b, _, h = rectOf(scrollParent)
        if l then
            local w, hh = ownSize(region, 1), ownSize(region, 2)
            result = { l, b + h - hh + (rawget(scrollParent, "_scroll") or 0), w, hh }
        end
    elseif #anchors > 0 then
        local out, ok = {}, true
        for axis = 1, 2 do
            local lo, hi   -- the constraints with the smallest and the largest factor
            for _, a in ipairs(anchors) do
                local rl, rb, rw, rh = rectOf(a.rel)
                if not rl then ok = false break end
                local f = POINTS[a.point] and POINTS[a.point][axis] or 0.5
                local rf = POINTS[a.relPoint] and POINTS[a.relPoint][axis] or 0.5
                local at = axis == 1 and (rl + rf * rw + a.x) or (rb + rf * rh + a.y)
                if not lo or f < lo[1] then lo = { f, at } end
                if not hi or f > hi[1] then hi = { f, at } end
            end
            if not ok then break end
            local size, start
            if hi[1] > lo[1] then
                size = (hi[2] - lo[2]) / (hi[1] - lo[1])
                start = lo[2] - lo[1] * size
            else
                size = ownSize(region, axis, out[3])
                start = lo[2] - lo[1] * size
            end
            out[axis], out[axis + 2] = start, size
        end
        if ok then result = { out[1], out[2], out[3], out[4] } end
    end
    busy[region] = nil
    if result then rectCache[region] = result return result[1], result[2], result[3], result[4] end
    return nil
end
M.rectOf = rectOf

function stringWidth(fs)
    return M.textWidth(rawget(fs, "text") or "", sizeOf(fs))
end

-- The lines a text takes in `width` (nil: no width of its own, one line per line break). Words wrap; a word wider
-- than the line takes a line of its own.
function linesIn(fs, width)
    local text = rawget(fs, "text") or ""
    if text == "" then return 0 end
    local size = sizeOf(fs)
    local n = 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        local count = 1
        if width and rawget(fs, "wordWrap") ~= false then
            local cur = ""
            for word in line:gmatch("%S+") do
                local try = cur == "" and word or (cur .. " " .. word)
                if cur ~= "" and M.textWidth(try, size) > width + 0.5 then count, cur = count + 1, word else cur = try end
            end
        end
        n = n + count
    end
    return n
end

-- The width a text wraps in: its own (set, or given by two anchors), else nil.
function wrapWidth(fs, w)
    local own = rawget(fs, "_w")
    if own and own > 0 then return w or own end
    local fs1 = {}
    for _, a in ipairs(anchorsOf(fs)) do fs1[POINTS[a.point] and POINTS[a.point][1] or 0.5] = true end
    local n = 0
    for _ in pairs(fs1) do n = n + 1 end
    return n > 1 and w or nil
end

-- A button's text: a FontString of its own, centered on it, in its font object.
local function buttonText(self)
    local fs = rawget(self, "_fs")
    if not fs then
        fs = self:CreateFontString(nil, "OVERLAY", rawget(self, "_font") or "GameFontNormal")
        fs:SetPoint("CENTER", self, "CENTER", 0, 0)
        rawset(self, "_fs", fs)
        fs.buttonText = true
    end
    return fs
end

local function geometry(base)
    local g = {}
    local function setSize(self, w, h)
        if w ~= nil then rawset(self, "_w", w) end
        if h ~= nil then rawset(self, "_h", h) end
        if rawget(self, "_firstW") == nil and w and h then rawset(self, "_firstW", w) rawset(self, "_firstH", h) end
        touch()
    end
    g.SetSize = function(self, w, h) setSize(self, w, h) end
    g.SetWidth = function(self, w) setSize(self, w, nil) end
    g.SetHeight = function(self, h) setSize(self, nil, h) end
    g.SetPoint = function(self, ...) base.SetPoint(self, ...) touch() end
    g.ClearAllPoints = function(self) base.ClearAllPoints(self) touch() end
    g.SetAllPoints = function(self, rel)
        rel = rel or rawget(self, "parent")
        base.ClearAllPoints(self)
        base.SetPoint(self, "TOPLEFT", rel, "TOPLEFT", 0, 0)
        base.SetPoint(self, "BOTTOMRIGHT", rel, "BOTTOMRIGHT", 0, 0)
        touch()
    end
    g.GetRect = function(self) return rectOf(self) end
    g.GetWidth = function(self)
        local _, _, w = rectOf(self)
        return w or ownSize(self, 1)
    end
    g.GetHeight = function(self)
        local _, _, _, h = rectOf(self)
        return h or ownSize(self, 2)
    end
    g.GetLeft = function(self) return (rectOf(self)) end
    g.GetBottom = function(self) local _, b = rectOf(self) return b end
    g.GetRight = function(self) local l, _, w = rectOf(self) return l and l + w end
    g.GetTop = function(self) local _, b, _, h = rectOf(self) return b and b + h end
    g.GetCenter = function(self)
        local l, b, w, h = rectOf(self)
        if not l then return nil end
        return l + w / 2, b + h / 2
    end
    g.GetPoint = function(self, i)
        local a = anchorsOf(self)[i or 1]
        if not a then return nil end
        return a.point, a.rel, a.relPoint, a.x, a.y
    end
    g.GetNumPoints = function(self) return #anchorsOf(self) end
    g.SetText = function(self, t)
        self.text = t
        if self.kind == "Button" or self.kind == "CheckButton" then
            if rawget(self, "_fs") or (t ~= nil and t ~= "") then buttonText(self).text = t end
        end
        touch()
    end
    g.SetFormattedText = function(self, fmt, ...) g.SetText(self, fmt:format(...)) end
    g.GetFontString = function(self) return buttonText(self) end
    g.SetNormalFontObject = function(self, font)
        rawset(self, "_font", font)
        local fs = rawget(self, "_fs")
        if fs then fs.fontSize = fontSizeOf(font) touch() end
    end
    g.SetFontObject = function(self, font) self.fontSize = fontSizeOf(font) touch() end
    g.SetFont = function(self, _, size) self.fontSize = size or 12 touch() end
    g.GetFont = function(self) return "Fonts\\FRIZQT__.TTF", sizeOf(self), "" end
    g.GetStringWidth = function(self) return stringWidth(self) end
    g.GetUnboundedStringWidth = g.GetStringWidth
    g.SetWordWrap = function(self, on) self.wordWrap = on and true or false touch() end
    g.GetWordWrap = function(self) return rawget(self, "wordWrap") ~= false end
    g.SetSpacing = function(self, s) self.spacing = s end
    -- The lines a text takes in its width (words wrap; a word wider than the line takes a line of its own).
    g.GetNumLines = function(self)
        local _, _, w = rectOf(self)
        return linesIn(self, wrapWidth(self, w))
    end
    g.GetStringHeight = function(self)
        local n = g.GetNumLines(self)
        local size = sizeOf(self)
        return n * size + math.max(0, n - 1) * (rawget(self, "spacing") or 2)
    end
    g.IsTruncated = function(self) return M.isCut(self) end
    g.SetScrollChild = function(self, child) rawset(child, "_scrollParent", self) touch() end
    g.SetVerticalScroll = function(self, v) rawset(self, "_scroll", v or 0) touch() end
    g.GetVerticalScroll = function(self) return rawget(self, "_scroll") or 0 end
    g.SetClipsChildren = function(self, on) rawset(self, "_clips", on and true or false) end
    g.DoesClipChildren = function(self) return rawget(self, "_clips") or self.kind == "ScrollFrame" end
    g.SetFrameStrata = function(self, s) rawset(self, "_strata", s) end
    g.GetFrameStrata = function(self) return rawget(self, "_strata") or "MEDIUM" end
    g.SetResizeBounds = function(self, minW, minH, maxW, maxH)
        rawset(self, "_bounds", { minW, minH, maxW, maxH })
    end
    g.SetMinResize = function(self, minW, minH) rawset(self, "_bounds", { minW, minH }) end
    g.GetResizeBounds = function(self)
        local b = rawget(self, "_bounds") or {}
        return b[1], b[2], b[3], b[4]
    end
    return g
end

--- How the text of a FontString is drawn in its box: true when the client cuts it (with "...").
function M.isCut(fs)
    local text = rawget(fs, "text") or ""
    if text == "" or not fs:IsVisible() then return false end
    local l, _, w, h = rectOf(fs)
    if not l then return false end
    local size = sizeOf(fs)
    local tw = stringWidth(fs)
    local oneLine = fs:GetWordWrap() == false or h < 2 * size + 1
    if oneLine then return tw > w + 0.5 end
    -- Wrapped: cut where its lines do not fit its height (a height set or given by two anchors).
    local hSet = rawget(fs, "_h")
    local twoV = false
    local seen = {}
    for _, a in ipairs(anchorsOf(fs)) do seen[POINTS[a.point] and POINTS[a.point][2] or 0.5] = true end
    for f in pairs(seen) do for f2 in pairs(seen) do if f ~= f2 then twoV = true end end end
    if not ((hSet and hSet > 0) or twoV) then return false end
    return fs:GetStringHeight() > h + 0.5
end

local methods = newMethods()
local meta = { __index = methods }

--- A frame/region whose unknown methods do nothing. Scripts and state are kept.
function widget(kind)
    local w = { kind = kind, scripts = {}, shown = true, events = {}, text = "", checked = false,
        _children = {}, _regions = {} }
    return setmetatable(w, meta)
end
M.widget = widget

--- opts.layout: sizes, anchors and text widths are modelled (see "layout mode").
function M.install(opts)
    opts = opts or {}
    local env = {
        now = 1000, clock = 1700000000, chat = {}, timers = {}, frames = {}, tooltipCalls = {},
        items = {}, bags = {}, auras = {}, loot = {}, inbox = {}, money = 1000000, casts = {}, cvars = {},
        ah = { browse = {}, fullBrowse = true, commodities = {}, itemResults = {}, sent = {}, bids = {},
            hasResults = {}, ready = true, posts = {}, owned = {}, cancels = {}, commodityBuys = {} },
    }
    M.env = env
    _G.SalvagerDB = nil   -- every install starts with fresh saved data
    methods = newMethods()
    meta.__index = methods
    M.layout = opts.layout and true or false
    if M.layout then
        local base = { SetPoint = methods.SetPoint, ClearAllPoints = methods.ClearAllPoints }
        for k, v in pairs(geometry(base)) do methods[k] = v end
        touch()
    end
    _G.GetScreenWidth = function() return 1920 end
    _G.GetScreenHeight = function() return 1080 end

    _G.GetTime = function() return env.now end
    _G.time = function() return env.clock end
    _G.date = os.date
    _G.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    _G.tinsert = table.insert
    _G.hooksecurefunc = function(a, b, c)
        local tbl, name, hook = a, b, c
        if type(a) == "string" then tbl, name, hook = _G, a, b end
        local orig = tbl[name]
        tbl[name] = function(...) local r = { orig(...) } hook(...) return unpack(r) end
    end
    _G.DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(env.chat, m) end }
    _G.UIParent = widget("Frame")
    -- The screen is 1920 wide (a window that fits its tables stops there); without layout every other frame is 140.
    if not M.layout then rawset(_G.UIParent, "GetWidth", function() return 1920 end) end
    _G.UISpecialFrames = {}
    _G.GameTooltip = widget("GameTooltip")
    _G.ItemRefTooltip = widget("GameTooltip")
    _G.SlashCmdList = {}
    _G.StaticPopupDialogs = {}
    _G.StaticPopup_Show = function(name) env.popup = name end
    _G.CreateFrame = function(kind, name, parent, template)
        local f = widget(kind)
        f._template = template   -- (the specs check which look a control has)
        -- The game's button templates bring their art as fields (Left, Middle, Right textures), as the client does.
        if template and template:find("Button") then
            f.Left, f.Middle, f.Right = widget("Texture"), widget("Texture"), widget("Texture")
        end
        -- The window template brings its title bar and title text, as the client does.
        if template and template:find("BasicFrameTemplate") then
            f.TitleBg, f.TitleText = widget("Texture"), widget("FontString")
            f.TitleBg.parent, f.TitleText.parent = f, f
            if M.layout then
                -- Where the template puts them: the title bar along the top, the title centered on it, the close
                -- button at the top right.
                f.TitleBg:SetPoint("TOPLEFT", f, "TOPLEFT", 2, -3)
                f.TitleBg:SetPoint("TOPRIGHT", f, "TOPRIGHT", -25, -3)
                f.TitleBg:SetHeight(18)
                f.TitleText.template = "GameFontHighlight"
                f.TitleText:SetPoint("TOP", f, "TOP", 0, -5)
                table.insert(f._regions, f.TitleBg)
                table.insert(f._regions, f.TitleText)
            end
        end
        -- A secure action button (SecureTemplates.lua): type "spell" casts its spell, then uses target-bag and
        -- target-slot as the spell's target. Here a cast is recorded in env.casts. Its attributes cannot change in
        -- combat (env.combat), as in the client.
        if template and template:find("SecureActionButtonTemplate") then
            f.secure = true
            f.scripts.OnClick = function(self)
                local a = rawget(self, "attrs") or {}
                if a.type == "spell" then
                    table.insert(env.casts, { spell = a.spell, bag = a["target-bag"], slot = a["target-slot"] })
                end
            end
            f.SetAttribute = function(self, k, v)
                if env.combat then error("Action[SetAttribute] blocked in combat", 2) end
                rawset(self, "attrs", rawget(self, "attrs") or {})
                self.attrs[k] = v
            end
        end
        f.parent = parent
        if type(parent) == "table" and rawget(parent, "_children") then table.insert(parent._children, f) end
        table.insert(env.frames, f)
        if name then _G[name] = f f._name = name end
        if M.layout and template and template:find("BasicFrameTemplate") then
            f.CloseButton = _G.CreateFrame("Button", nil, f)
            f.CloseButton:SetSize(24, 24)
            f.CloseButton:SetPoint("TOPRIGHT", f, "TOPRIGHT", 0, 0)
            f.CloseButton.uiKind = "close"
        end
        return f
    end
    _G.C_Timer = { After = function(s, fn) table.insert(env.timers, { at = env.now + s, fn = fn }) end }
    -- The TOC's fields, read from the addon's own TOC file.
    _G.C_AddOns = { GetAddOnMetadata = function(_, field)
        local toc = io.open("Salvager/Salvager.toc")
        local text = toc and toc:read("*a") or ""
        if toc then toc:close() end
        return text:match("## " .. field .. ": ([^\r\n]+)") or "test"
    end }
    _G.IsPlayerSpell = function() return false end
    -- env.combat: in a fight (the client locks secure frames); env.cvars[name]: a game setting (true/false).
    _G.InCombatLockdown = function() return env.combat or false end
    _G.GetCVarBool = function(name) return env.cvars[name] end
    _G.IsShiftKeyDown = function() return env.shift or false end
    -- The macros (env.macros: { { name, icon, body } }, the account's; env.macroMax: its slots).
    env.macros = {}
    _G.Constants = { MacroConsts = { MAX_ACCOUNT_MACROS = 120, MAX_CHARACTER_MACROS = 30 } }
    _G.GetNumMacros = function() return #env.macros, 0 end
    _G.GetMacroIndexByName = function(name)
        for i, m in ipairs(env.macros) do if m.name == name then return i end end
        return 0
    end
    _G.GetMacroInfo = function(i) local m = env.macros[i] if m then return m.name, m.icon, m.body end end
    _G.CreateMacro = function(name, icon, body, perCharacter)
        assert(not perCharacter, "an account macro")
        assert(#env.macros < (env.macroMax or 120), "no free slot")
        env.macros[#env.macros + 1] = { name = name, icon = icon, body = body }
        return #env.macros
    end   -- (env.shift: the Shift key held)
    -- EditMacro(index, name, icon, body): nil keeps a field (the game's Blizzard_MacroUI.lua). env.spellIcons[id]:
    -- the file ID C_Spell.GetSpellTexture returns (nil: the spell is not found). An icon must be a file ID or a
    -- bare texture name, never a path (SDD 136).
    _G.EditMacro = function(i, name, icon, body)
        local m = assert(env.macros[i], "no macro at that index")
        assert(icon == nil or type(icon) == "number" or not tostring(icon):find("[\\/]"), "an icon path")
        m.name, m.icon, m.body = name or m.name, icon or m.icon, body or m.body
        env.macroEdits = (env.macroEdits or 0) + 1
        return i
    end
    env.spellIcons = { [13262] = 136244 }   -- Disenchant: a stand-in file ID
    _G.C_Spell = _G.C_Spell or {}
    _G.C_Spell.GetSpellTexture = function(id) return env.spellIcons[id] end
    _G.GetMoney = function() return env.money end
    -- env.equipped[slot] = itemID: what the character wears (the game's item count includes it).
    _G.GetInventoryItemID = function(unit, slot) return unit == "player" and env.equipped and env.equipped[slot] or nil end
    _G.UnitName = function() return "Tester" end
    _G.GetRealmName = function() return "Realm" end
    _G.TooltipDataProcessor = { AddTooltipPostCall = function(_, fn) env.tooltipPost = fn end }
    _G.ATTACHMENTS_MAX_RECEIVE = 16
    _G.Minimap = widget("Minimap")
    _G.GetCursorPosition = function() return 600, 500 end
    _G.Settings = {
        RegisterCanvasLayoutCategory = function() return { GetID = function() return 1 end } end,
        RegisterAddOnCategory = function() env.settingsRegistered = true end,
        OpenToCategory = function() env.settingsOpened = true end,
    }

    _G.Enum = {
        AuctionHouseSortOrder = { Price = 0, Name = 1, Level = 2, Bid = 3, Buyout = 4 },
        AuctionHouseFilter = { UncommonQuality = 8, RareQuality = 9, EpicQuality = 10 },
        TooltipDataType = { Item = 0 },
        AuctionStatus = { Active = 0, Sold = 1 },
    }

    -- Items: env.items[id] = { name, quality, ilvl, req, classID }
    local function item(x)
        local id = type(x) == "number" and x or tonumber(tostring(x):match("item:(%d+)"))
        return id and env.items[id], id
    end
    _G.C_Item = {
        GetItemInfoInstant = function(x)
            local it, id = item(x)
            if not it then return nil end
            return id, "", "", "", 0, it.classID, 0
        end,
        GetItemInfo = function(x)
            local it, id = item(x)
            if not it then return nil end
            return it.name, "|Hitem:" .. id .. "|h[" .. it.name .. "]|h", it.quality, it.ilvl, it.req
        end,
        GetItemQualityByID = function(x) local it = item(x) return it and it.quality end,
        GetDetailedItemLevelInfo = function(x) local it = item(x) return it and it.ilvl end,
        GetItemNameByID = function(x) local it = item(x) return it and it.name end,
        GetItemCount = function(id)
            local worn = 0
            for _, e in pairs(env.equipped or {}) do if e == id then worn = worn + 1 end end
            return (env.bags[id] or 0) + worn
        end,
        -- env.guids["bag:slot"] = the item's GUID
        GetItemGUID = function(loc) return env.guids and env.guids[loc.bag .. ":" .. loc.slot] end,
    }
    -- env.bagSize[bag] = slots (the backpack has 4 unless set), env.bagFree[bag] = free slots (all of them
    -- unless set), env.bagFamily[bag] = the bag family (0 = holds anything; a profession bag is not 0).
    env.bagSize, env.bagFree, env.bagFamily = { [0] = 4 }, {}, {}
    _G.C_Container = {
        GetContainerItemLink = function(bag, slot) return env.bagLinks and env.bagLinks[bag .. ":" .. slot] end,
        GetContainerNumSlots = function(bag) return env.bagSize[bag] or 0 end,
        GetContainerNumFreeSlots = function(bag)
            return env.bagFree[bag] or env.bagSize[bag] or 0, env.bagFamily[bag] or 0
        end,
        -- env.bagItems["bag:slot"] = itemID (else env.bagSlots[slot], in any bag)
        GetContainerItemID = function(bag, slot)
            local id = env.bagItems and env.bagItems[bag .. ":" .. slot]
            if id then return id end
            return env.bagSlots and env.bagSlots[slot]
        end,
    }
    _G.NUM_BAG_SLOTS = 4
    _G.ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
    _G.C_UnitAuras = { GetAuraDataByIndex = function(_, i) return env.auras[i] end }
    _G.GetNumLootItems = function() return #env.loot end
    _G.GetLootSlotLink = function(i) return env.loot[i] and ("|Hitem:" .. env.loot[i].id .. "|h") end
    _G.GetLootSlotInfo = function(i) return nil, nil, env.loot[i] and env.loot[i].qty end
    -- env.loot[i].source = the GUID the loot comes from (nil: the client does not say)
    _G.GetLootSourceInfo = function(i) return env.loot[i] and env.loot[i].source end

    -- Mail: env.inbox[i] = { header = {...}, invoice = {...}, link = ... }
    _G.GetInboxHeaderInfo = function(i)
        local m = env.inbox[i]
        return nil, nil, m.sender, m.subject, m.money or 0, nil, m.daysLeft or 30, m.link and 1 or 0
    end
    _G.GetInboxNumItems = function() return #env.inbox end
    _G.GetInboxInvoiceInfo = function(i) return unpack(env.inbox[i].invoice) end
    _G.GetInboxItemLink = function(i, a) local m = env.inbox[i] return a == 1 and m.link or nil end
    _G.TakeInboxItem = function() end
    _G.TakeInboxMoney = function() end
    _G.AutoLootMailItem = function() end
    _G.RepairAllItems = function() end

    local ah = env.ah
    _G.C_AuctionHouse = {
        IsThrottledMessageSystemReady = function() return ah.ready end,
        MakeItemKey = function(id, lvl, suf) return { itemID = id, itemLevel = lvl or 0, itemSuffix = suf or 0 } end,
        HasSearchResults = function(key) return ah.hasResults[key.itemID] or false end,
        SendSearchQuery = function(key) table.insert(ah.sent, { kind = "search", key = key }) end,
        RefreshCommoditySearchResults = function(id) table.insert(ah.sent, { kind = "refreshC", id = id }) end,
        RefreshItemSearchResults = function(key) table.insert(ah.sent, { kind = "refreshI", key = key }) end,
        GetNumCommoditySearchResults = function(id) return #(ah.commodities[id] or {}) end,
        GetCommoditySearchResultInfo = function(id, i) return ah.commodities[id][i] end,
        SendBrowseQuery = function(q)
            ah.query = q
            table.insert(ah.sent, { kind = "browse", query = q })
        end,
        -- Like the real one: only rows that match the query's gear type and quality.
        GetBrowseResults = function()
            local q = ah.query
            if not q then return ah.browse end
            local classes, qualities = {}, {}
            for _, c in ipairs(q.itemClassFilters or {}) do classes[c.classID] = true end
            for _, f in ipairs(q.filters or {}) do qualities[f - 6] = true end
            local out = {}
            for _, r in ipairs(ah.browse) do
                local it = env.items[r.itemKey.itemID]
                if not it or ((not next(classes) or classes[it.classID]) and (not next(qualities) or qualities[it.quality])) then
                    out[#out + 1] = r
                end
            end
            return out
        end,
        PostCommodity = function(loc, duration, quantity, unitPrice)
            table.insert(ah.posts, { loc = loc, duration = duration, quantity = quantity, unitPrice = unitPrice })
            return ah.needsConfirm or false
        end,
        ConfirmPostCommodity = function(loc, duration, quantity, unitPrice)
            table.insert(ah.posts, { loc = loc, duration = duration, quantity = quantity, unitPrice = unitPrice,
                confirmed = true })
        end,
        CalculateCommodityDeposit = function(_, _, quantity) return quantity * 3 end,
        QueryOwnedAuctions = function()
            table.insert(ah.sent, { kind = "owned" })
            ah.ownedAsked = true
        end,
        GetNumOwnedAuctions = function() return #ah.owned end,
        GetOwnedAuctionInfo = function(i) return ah.owned[i] end,
        CanCancelAuction = function() return true end,
        GetCancelCost = function() return 12 end,
        CancelAuction = function(id) table.insert(ah.cancels, id) end,
        HasFullBrowseResults = function() return ah.fullBrowse end,
        RequestMoreBrowseResults = function() table.insert(ah.sent, { kind = "more" }) end,
        GetItemKeyInfo = function(key)
            local it = env.items[key.itemID]
            return it and { quality = it.quality, isCommodity = it.commodity }
        end,
        GetNumItemSearchResults = function(key) return #(ah.itemResults[key.itemID] or {}) end,
        GetItemSearchResultInfo = function(key, i) return ah.itemResults[key.itemID][i] end,
        PlaceBid = function(id, amount) table.insert(ah.bids, { id = id, amount = amount }) end,
        -- Commodity purchases: each call is recorded in ah.commodityBuys ({ kind = "start" | "confirm" | "cancel",
        -- itemID, quantity }); the spec answers with COMMODITY_PRICE_UPDATED and COMMODITY_PURCHASE_SUCCEEDED.
        StartCommoditiesPurchase = function(id, qty)
            table.insert(ah.commodityBuys, { kind = "start", itemID = id, quantity = qty })
        end,
        ConfirmCommoditiesPurchase = function(id, qty)
            table.insert(ah.commodityBuys, { kind = "confirm", itemID = id, quantity = qty })
        end,
        CancelCommoditiesPurchase = function() table.insert(ah.commodityBuys, { kind = "cancel" }) end,
    }
    return env
end

--- Loads every file of the TOC into one namespace.
function M.loadAddon()
    local ns = {}
    for line in io.lines("Salvager/Salvager.toc") do
        if line:match("%.lua$") then
            local chunk = assert(loadfile("Salvager/" .. line))
            chunk("Salvager", ns)
        end
    end
    return ns
end

--- Delivers an event the way the client does (through the addon's event frame).
function M.fire(ns, event, ...)
    ns.eventFrame.scripts.OnEvent(ns.eventFrame, event, ...)
end

--- Advances the clock and runs the OnUpdate ticker and due timers.
--- A purchase on its way (the scan and every other request wait for it, SDD 105), sent with the auction house
--- ready. Returns a function that ends it: the auction house's error answer ("could not buy").
function M.buying(ns, auctionID)
    local env = M.env
    local d = { auctionID = auctionID or 990, buyout = 1, itemID = 2001, value = 2, profit = 1 }
    local ready = env.ah.ready
    env.ah.ready = true
    ns.Scanner.Buy(d)
    env.ah.ready = ready
    assert(d.pending, "the purchase did not go out")
    return function() M.fire(ns, "AUCTION_HOUSE_SHOW_ERROR") end
end

function M.tick(ns, seconds)
    local env = M.env
    local step = 0.1
    local n = math.floor(seconds / step + 0.5)
    for _ = 1, n do
        env.now = env.now + step
        if env.ah.ownedAsked then    -- the auction house answers a request for your auctions
            env.ah.ownedAsked = false
            M.fire(ns, "OWNED_AUCTIONS_UPDATED")
        end
        ns.eventFrame.scripts.OnUpdate(ns.eventFrame, step)
        for i = #env.timers, 1, -1 do
            local t = env.timers[i]
            if t.at <= env.now then table.remove(env.timers, i) t.fn() end
        end
    end
end

return M

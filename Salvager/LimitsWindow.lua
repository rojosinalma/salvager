-- Salvager: the buy limits per item level band, for armor and for weapons, in a window of their own (the main
-- window's Limits button). Each row is a band of a quality; type your own limit, or go back to the recommended one.
local _, ns = ...

local Data, W = ns.Data, ns.Widgets

local Limits = {}
ns.LimitsWindow = Limits

local WIDTH, ROW_H = 780, 24   -- the width it opens with (Widgets.FitTables sets it)
-- A column of boxes is as wide as the boxes and their x (the reset button, 20 px, 6 px into the boxes' frame).
local EDIT_W = W.MONEY_W + 14
local EDIT = { [3] = "armor", [5] = "weapon" }   -- the columns with the gold, silver and copper boxes

local COLUMNS = {
    { "Item level", 90 },
    { "Armor: recommended", 120, "RIGHT", help = { "Armor: recommended", "The most to pay for one piece of armor of this "
        .. "band: its value after the cut, less the min profit, or less the min return when that asks for more. A % "
        .. "after the amount: the min return sets it. ?: a material of the band has no price yet." } },
    { "Armor: limit used", 184, "LEFT", least = EDIT_W, help = { "Armor: limit used", "The most the scan pays for one piece of armor "
        .. "of this band. Type your own (yellow); the x next to it goes back to the recommended one. Grey: the scan "
        .. "does not look at armor, or at this quality." } },
    { "Weapons: recommended", 120, "RIGHT", help = { "Weapons: recommended", "The same for weapons." } },
    { "Weapons: limit used", 184, "LEFT", least = EDIT_W, help = { "Weapons: limit used", "The same for weapons." } },
}

local function recommendedText(x, dim)
    if not x then return "-" end
    local t = ns.Money(x.recommended)
    if x.missing then t = t .. "?" end
    if x.rule == "return" then t = t .. " %" end   -- (set by the min return, not the min profit)
    if dim then return "|cff808080" .. t .. "|r" end
    return t
end

--- The rows: a heading per quality, then its bands (every quality, whatever the scan looks at). A heading opens
--- and closes (ns.HeadingToggle).
function Limits.Rows()
    local out = {}
    local classes, qualities = ns.GearClasses(), ns.db.settings.qualities
    local state = ns.GroupState("limits")
    local last, open
    for _, r in ipairs(ns.Limits(true)) do
        if r.quality ~= last then
            last = r.quality
            local head = { cells = { ns.QualityText(r.quality), "", "", "", "" }, head = true, group = true }
            open = ns.HeadingToggle(head, state, tostring(r.quality), function() Limits.Refresh() end)
            out[#out + 1] = head
        end
        if open then
            -- Grey where the scan does not look: that gear type, or that quality.
            local off = not qualities[r.quality]
            local dimA, dimW = off or not classes[Data.CLASS_ARMOR], off or not classes[Data.CLASS_WEAPON]
            out[#out + 1] = {
                cells = { ns.BandRange(r.quality, r.up), recommendedText(r.armor, dimA), "",
                    recommendedText(r.weapon, dimW), "" },
                indent = 22,
                limits = { armor = r.armor, weapon = r.weapon },
                dim = { armor = dimA, weapon = dimW },
            }
        end
    end
    return out
end

--- What the columns and marks mean, one line each (the "?" button).
function Limits.HelpLines()
    local cut = math.floor(ns.Cut() * 100 + 0.5) .. "%"
    return {
        "Armor and Weapons: two columns each. The rows are the bands of every quality.",
        ns.db.settings.cautious and ("Recommended: the value with every material at its lowest amount, after the "
            .. cut .. " cut, minus your min profit (cautious pricing is on).")
            or ("Recommended: the disenchant value after the " .. cut .. " cut, minus your min profit, or minus your "
                .. "min return when that asks for more (a % after the amount)."),
        "Limit used: the limit the scan uses. Type gold, silver and copper to set your own; it then shows in yellow. "
            .. "x: back to the recommended one.",
        "Grey: a gear type or a quality the scan does not look at.",
        "?: a material of that band has no price yet.",
        "Max price, when set, still applies on top of these limits.",
        "Min profit, Min return and Cautious are set in the main window's Settings.",
    }
end

local f, list, status

--- Shows one limit box: yellow when set by hand, white for the recommended limit, grey where the scan does not look.
local function showEdit(e, x, dim)
    e.limit = x
    if not x then e:Hide() e.reset:Hide() return end
    e:Show()
    e.reset:SetShown(x.manual)
    e:Set(x.limit)
    if dim then e:SetTextColor(0.5, 0.5, 0.5)
    elseif x.manual then e:SetTextColor(1, 0.82, 0)
    else e:SetTextColor(1, 1, 1) end
end

-- The limit boxes of a list row, made the first time the row shows a band.
local function editsOf(row)
    if rawget(row, "edits") then return row.edits end
    row.edits = {}
    for _, which in pairs(EDIT) do
        local e
        e = W.Money(row, function(copper)
            local lim = e.limit
            if not lim or copper == lim.limit then return end
            if copper == lim.recommended and lim.manual then
                ns.SetLimitOverride(lim.quality, lim.classID, lim.band, nil)
            elseif copper ~= lim.recommended then
                ns.SetLimitOverride(lim.quality, lim.classID, lim.band, copper)
            end
        end)
        e.reset = W.Button(e:Right(), "x", 20, function()
            local lim = e.limit
            if lim then ns.SetLimitOverride(lim.quality, lim.classID, lim.band, nil) end
        end, "Use the recommended limit again.")
        e.reset:SetPoint("LEFT", e:Right(), "RIGHT", -6, 0)
        e.reset:Hide()
        e:Hide()
        row.edits[which] = e
    end
    return row.edits
end

function Limits.Refresh()
    if not f or not f:IsShown() then return end
    local rows = Limits.Rows()
    -- The x next to the boxes shows only where a limit of your own is set: the columns keep room for it only then.
    local manual = false
    for _, r in ipairs(rows) do
        for _, which in pairs(EDIT) do
            local x = r.limits and r.limits[which]
            if x and x.manual then manual = true end
        end
    end
    for col in pairs(EDIT) do COLUMNS[col].least = W.MONEY_W + (manual and 14 or 0) end
    list:SetSource(#rows, function(i) return rows[i] end)
    status:SetText(ns.db.settings.cautious and "Cautious pricing is on: the limits count every material at its "
        .. "lowest amount." or "")
    list:Refresh()
    -- (The width first: the boxes follow the cells where they are drawn.)
    W.FitTables(f, { list }, "limits")
    for _, row in ipairs(list.rows) do
        local data = row:IsShown() and rawget(row, "data") or nil
        if data and data.limits then
            local edits = editsOf(row)
            for col, which in pairs(EDIT) do
                local e = edits[which]
                e:ClearAllPoints()
                e:SetPoint("LEFT", row.cells[col], "LEFT", 0, 0)
                showEdit(e, row.cells[col]:IsShown() and data.limits[which] or nil, data.dim[which])
            end
        elseif rawget(row, "edits") then
            for _, e in pairs(row.edits) do showEdit(e, nil) end
        end
    end
end

local function build()
    -- As wide as its columns; the height is the player's.
    f = W.Window("SalvagerLimitsFrame", "Salvager Limits", "limits", WIDTH, 560, WIDTH, 220, "vertical")
    local footer = W.Bar(f, "footer"):PlaceBottom(8, 12, 24)
    local help = W.HelpButton(footer, "Limits", Limits.HelpLines)
    footer:AddRight(help, 22)
    status = W.Label(footer, "", "GameFontHighlightSmall")
    footer:Add(status, 300)
    status:SetPoint("RIGHT", help, "LEFT", -10, 0)
    status:SetJustifyH("LEFT")
    status:SetWordWrap(false)
    f.layoutName = "limits"
    list = W.List(f, { rowHeight = ROW_H })
    list:SetColumns(COLUMNS)
    list:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -30)
    list:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 40)
    Limits.list, Limits.footer = list, footer   -- (the specs read them)
    f.onResize = Limits.Refresh
    f:HookScript("OnShow", Limits.Refresh)
end

function Limits.Toggle()
    if not f then build() end
    f.UserToggle()
end

function Limits.Show()
    if not f then build() end
    f.UserShow()
end

--- Opens the window again if it was open the last time (the auction house opened).
function Limits.Restore()
    local saved = ns.db.windows.limits
    if not (saved and saved.open) then return end
    if not f then build() end
    f:Show()
end

for _, e in ipairs({ "SALVAGER_PRICES_DONE", "SALVAGER_SETTINGS", "SALVAGER_LEDGER" }) do
    ns.On(e, function() Limits.Refresh() end)
end

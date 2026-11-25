-- A small stand-in for the WoW client, enough to load the whole addon and
-- drive it through events. Only what Salvager calls is modelled.
local M = {}

local function noop() end

--- A frame/region whose unknown methods do nothing. Scripts and state are kept.
local function widget(kind)
    local w = { kind = kind, scripts = {}, shown = true, events = {}, text = "", checked = false }
    local methods = {
        SetScript = function(self, name, fn) self.scripts[name] = fn end,
        GetScript = function(self, name) return self.scripts[name] end,
        RegisterEvent = function(self, e) self.events[e] = true end,
        Show = function(self) self.shown = true if self.scripts.OnShow then self.scripts.OnShow(self) end end,
        Hide = function(self) self.shown = false end,
        SetShown = function(self, v) if v then self:Show() else self:Hide() end end,
        IsShown = function(self) return self.shown end,
        SetText = function(self, t) self.text = t end,
        GetText = function(self) return self.text end,
        SetChecked = function(self, v) self.checked = v end,
        GetChecked = function(self) return self.checked end,
        HasFocus = function() return false end,
        SetEnabled = function(self, v) self.enabled = v and true or false end,
        IsEnabled = function(self) return self.enabled ~= false end,
        GetPoint = function() return "CENTER", nil, "CENTER", 0, 0 end,
        GetParent = function(self) return self.parent end,
        CreateFontString = function(self) local fs = widget("FontString") fs.parent = self return fs end,
        CreateTexture = function(self) local t = widget("Texture") t.parent = self return t end,
        Click = function(self, button) if self.scripts.OnClick then self.scripts.OnClick(self, button) end end,
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
    }
    return setmetatable(w, { __index = function(_, k) return methods[k] or noop end })
end
M.widget = widget

function M.install()
    local env = {
        now = 1000, clock = 1700000000, chat = {}, timers = {}, frames = {}, tooltipCalls = {},
        items = {}, bags = {}, auras = {}, loot = {}, inbox = {}, money = 1000000,
        ah = { browse = {}, fullBrowse = true, commodities = {}, itemResults = {}, sent = {}, bids = {},
            hasResults = {}, ready = true, posts = {}, owned = {}, cancels = {} },
    }
    M.env = env
    _G.SalvagerDB = nil   -- every install starts with fresh saved data

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
    _G.UISpecialFrames = {}
    _G.GameTooltip = widget("GameTooltip")
    _G.ItemRefTooltip = widget("GameTooltip")
    _G.SlashCmdList = {}
    _G.StaticPopupDialogs = {}
    _G.StaticPopup_Show = function(name) env.popup = name end
    _G.CreateFrame = function(kind, name, parent)
        local f = widget(kind)
        f.parent = parent
        table.insert(env.frames, f)
        if name then _G[name] = f end
        return f
    end
    _G.C_Timer = { After = function(s, fn) table.insert(env.timers, { at = env.now + s, fn = fn }) end }
    _G.C_AddOns = { GetAddOnMetadata = function() return "test" end }
    _G.IsPlayerSpell = function() return false end
    _G.IsShiftKeyDown = function() return false end
    _G.GetMoney = function() return env.money end
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
        GetItemCount = function(id) return env.bags[id] or 0 end,
    }
    _G.C_Container = {
        GetContainerItemLink = function(bag, slot) return env.bagLinks and env.bagLinks[bag .. ":" .. slot] end,
        GetContainerNumSlots = function(bag) return bag == 0 and 4 or 0 end,
        GetContainerItemID = function(_, slot) return env.bagSlots and env.bagSlots[slot] end,
    }
    _G.ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
    _G.C_UnitAuras = { GetAuraDataByIndex = function(_, i) return env.auras[i] end }
    _G.GetNumLootItems = function() return #env.loot end
    _G.GetLootSlotLink = function(i) return env.loot[i] and ("|Hitem:" .. env.loot[i].id .. "|h") end
    _G.GetLootSlotInfo = function(i) return nil, nil, env.loot[i] and env.loot[i].qty end

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
        GetItemKeyInfo = function(key) local it = env.items[key.itemID] return it and { quality = it.quality } end,
        GetNumItemSearchResults = function(key) return #(ah.itemResults[key.itemID] or {}) end,
        GetItemSearchResultInfo = function(key, i) return ah.itemResults[key.itemID][i] end,
        PlaceBid = function(id, amount) table.insert(ah.bids, { id = id, amount = amount }) end,
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

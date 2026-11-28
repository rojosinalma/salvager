-- Salvager: the ledger's backups. Clearing the history (or a reset) first copies the whole ledger into
-- SalvagerBackup, a saved variable of its own, so a click by mistake can be undone: Restore puts the copy
-- back (and keeps what it replaces as a backup too). The last BACKUPS copies are kept.
local _, ns = ...

local Util, Ledger = ns.Util, ns.Ledger

local Backup = {}
ns.Backup = Backup

Backup.MAX = 3

local function store()
    SalvagerBackup = type(SalvagerBackup) == "table" and SalvagerBackup or {}
    SalvagerBackup.list = SalvagerBackup.list or {}
    return SalvagerBackup.list
end

--- The backups, newest last: { { t, reason, version, ledger }, ... }.
function Backup.List() return store() end

--- The newest backup, or nil.
function Backup.Last()
    local list = store()
    return list[#list]
end

--- Copies the ledger as it is now. `reason` says why ("before clearing the history").
function Backup.Save(reason)
    local list = store()
    list[#list + 1] = { t = time(), reason = reason, version = ns.VERSION, ledger = Util.Copy(ns.db.ledger) }
    Util.Cap(list, Backup.MAX)
    ns.Log("INFO", "ledger", "backup: the ledger copied (" .. tostring(reason) .. ")", { backups = #list })
end

--- Puts the newest backup back. What it replaces becomes a backup itself, so a restore can be undone too.
--- @return boolean done
function Backup.Restore()
    local b = Backup.Last()
    if not b then return false end
    local list = store()
    table.remove(list)
    Backup.Save("before restoring the backup of " .. ns.Date("%m-%d %H:%M", b.t))
    ns.db.ledger = Ledger.Init(Util.Copy(b.ledger))
    -- A copy from before 0.3.120 has its costs shared per band once (what it replaces is kept above).
    if Ledger.NeedsRecost(ns.db.ledger) then
        local n, sold = Ledger.Recost(ns.db.ledger)
        ns.Log("INFO", "ledger", string.format("material costs shared per band once (%d disenchants, %d sales booked "
            .. "again)", n, sold), { disenchants = n, sales = sold })
    end
    Ledger.OpenBooks(ns.db.ledger)
    ns.Log("INFO", "ledger", "backup: the ledger of " .. ns.Date("%m-%d %H:%M", b.t) .. " restored", { backup = b.t })
    ns.Print("the ledger of %s is back", ns.Date("%m-%d %H:%M", b.t))
    ns.Fire("SALVAGER_LEDGER")
    return true
end

--- What the addon keeps on disk, in bytes (about): its data, and its backups.
function Backup.Sizes()
    return Util.SavedSize(SalvagerDB or {}), Util.SavedSize(SalvagerBackup or {})
end

--- Clears the history (purchases, disenchants, sales; the stock stays), after a copy.
function Backup.ClearHistory()
    Backup.Save("before clearing the history")
    local n = Ledger.ClearHistory(ns.db.ledger, ns.NoDisenchant)
    -- Who undercut you goes too (its events and the profit lost to them, SDD 109); it is not in the backup.
    n = n + #(ns.db.competition.events or {})
    ns.Competition.Clear(ns.db.competition)
    ns.Print("ledger history cleared (%d entries). A backup is kept: Options, Restore backup.", n)
    ns.Log("INFO", "ledger", string.format("ledger history cleared (%d entries)", n), { entries = n })
    ns.Fire("SALVAGER_LEDGER")
end

StaticPopupDialogs["SALVAGER_CLEAR_LEDGER"] = {
    text = "Clear the Salvager ledger history?\n\nThis deletes every purchase, disenchant and sale record, and who "
        .. "undercut you: the Ledger, the Reports, the Accuracy, the Odds and the Competition start empty, and what "
        .. "they learned is lost (the backup does not keep the competition).\n\nWhat stays: your "
        .. "material stock and its costs, and the purchases you have not disenchanted yet.\n\nA copy is kept in the "
        .. "background: Options, Restore backup brings it back.",
    button1 = "Delete the history",
    button2 = "Cancel",
    OnAccept = function() Backup.ClearHistory() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

StaticPopupDialogs["SALVAGER_RESTORE_LEDGER"] = {
    text = "Restore the ledger backup of %s?\n\nThe ledger as it is now is replaced by that copy. What it replaces "
        .. "is kept as a backup too, so this can be undone the same way.",
    button1 = "Restore",
    button2 = "Cancel",
    OnAccept = function() Backup.Restore() end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
}

--- Asks, then restores the newest backup.
function Backup.AskRestore()
    local b = Backup.Last()
    if not b then ns.Print("there is no backup yet") return end
    StaticPopup_Show("SALVAGER_RESTORE_LEDGER", ns.Date("%Y-%m-%d %H:%M", b.t) .. " (" .. tostring(b.reason) .. ")")
end

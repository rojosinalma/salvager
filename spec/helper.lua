-- Loads the addon's pure modules into one shared namespace, like the client does.
local M = {}

function M.load()
    local ns = {}
    for _, file in ipairs({ "Util", "Data", "NoDisenchant", "Model", "Ledger", "History", "Journal", "Statement", "Competition" }) do
        local chunk = assert(loadfile("Salvager/" .. file .. ".lua"))
        chunk("Salvager", ns)
    end
    return ns
end

-- Silver amounts from the community spreadsheet, as copper.
function M.sheetPrices(ns)
    local D, E, S = ns.Data.DUST, ns.Data.ESS, ns.Data.SHARD
    local silver = {
        [D.soul] = 4.33, [D.vision] = 8.43, [D.dream] = 18.2, [D.illusion] = 20.73,
        [E.gastral] = 17.66, [E.gmystic] = 21.2, [E.gnether] = 231.92, [E.geternal] = 319.88,
        [S.lglim] = 57.8, [S.sglow] = 9.65, [S.lglow] = 27.48, [S.srad] = 96.77,
        [S.lrad] = 193.93, [S.sbril] = 56.7, [S.lbril] = 310.5,
    }
    return function(id)
        local s = silver[id]
        return s and s * 100 or nil
    end
end

return M

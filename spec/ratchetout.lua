-- The numbers the specs measure for the ratchet (scripts/ratchet.py, SDD 121): each spec writes its set to
-- .ratchet/<name>.json (gitignored); `make check` compares them with the baseline, spec/ratchet.json.
local M = {}

local function encode(v, indent)
    indent = indent or ""
    local t = type(v)
    if t == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.4f", v)
    elseif t == "string" then
        return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
    elseif t == "boolean" then
        return tostring(v)
    elseif t == "table" then
        local keys = {}
        for k in pairs(v) do keys[#keys + 1] = tostring(k) end
        table.sort(keys)
        local out = {}
        for _, k in ipairs(keys) do
            local x = v[k]
            if x == nil then x = v[tonumber(k)] end
            out[#out + 1] = indent .. "  " .. encode(k) .. ": " .. encode(x, indent .. "  ")
        end
        if #out == 0 then return "{}" end
        return "{\n" .. table.concat(out, ",\n") .. "\n" .. indent .. "}"
    end
    return "null"
end
M.encode = encode

--- Writes `numbers` to .ratchet/<name>.json (the folder is made where it is missing).
function M.write(name, numbers)
    os.execute("mkdir -p .ratchet")
    local f = io.open(".ratchet/" .. name .. ".json", "w")
    if not f then return false end
    f:write(encode(numbers), "\n")
    f:close()
    return true
end

return M

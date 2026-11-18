-- LiLiBanque: text export « !LILI1!<base64(json)>!<crc32 hex> » (CONTRACT.md, « Export depuis le jeu »).
-- Pure Lua 5.1, no bit library: JSON, base64 (RFC 4648, padded) and CRC32 (IEEE, zlib) by arithmetic.
-- Work runs in a coroutine so a large journal is spread over several frames.
LiLiBanque = LiLiBanque or {}
local E = {}; LiLiBanque.Export = E
E.PREFIX = '!LILI1!'
E.BANK_MONEY_KEPT = 30
local floor, byte, char, format, concat = math.floor, string.byte, string.char, string.format, table.concat
local yield, running = coroutine.yield, coroutine.running

-- Cooperative pause: only yields when running inside the export coroutine.
local budget = 0
local function work(n)
    budget = budget - n
    if budget <= 0 then
        budget = E.STEP
        if running() then yield() end
    end
end
E.STEP = 6000

-- 4-bit XOR table, then 8-bit XOR as two nibble lookups.
local X4 = {}
for a = 0, 15 do
    for b = 0, 15 do
        local r, bit, x, y = 0, 1, a, b
        for _ = 1, 4 do
            if x % 2 ~= y % 2 then r = r + bit end
            x, y, bit = floor(x / 2), floor(y / 2), bit * 2
        end
        X4[a * 16 + b] = r
    end
end
-- The 8-bit XOR and CRC tables (~1 Mo) are only built on the first export.
local X8, T0, T1, T2, T3
local function xor8(a, b) return X8[a * 256 + b] end
local function prepare()
    if X8 then return end
    local x8 = {}
    for a = 0, 255 do
        local ah, al = floor(a / 16), a % 16
        for b = 0, 255 do
            x8[a * 256 + b] = X4[ah * 16 + floor(b / 16)] * 16 + X4[al * 16 + b % 16]
        end
        if a % 32 == 31 then work(4096) end
    end
    X8 = x8
    -- CRC table split in 4 bytes (low byte first) to avoid 32-bit XOR.
    T0, T1, T2, T3 = {}, {}, {}, {}
    for n = 0, 255 do
        local c = {n, 0, 0, 0}
        for _ = 1, 8 do
            local lsb = c[1] % 2
            c[1] = floor(c[1] / 2) + (c[2] % 2) * 128
            c[2] = floor(c[2] / 2) + (c[3] % 2) * 128
            c[3] = floor(c[3] / 2) + (c[4] % 2) * 128
            c[4] = floor(c[4] / 2)
            if lsb == 1 then -- reflected polynomial 0xEDB88320
                c[1] = xor8(c[1], 0x20); c[2] = xor8(c[2], 0x83); c[3] = xor8(c[3], 0xB8); c[4] = xor8(c[4], 0xED)
            end
        end
        T0[n], T1[n], T2[n], T3[n] = c[1], c[2], c[3], c[4]
    end
end

function E.crc32(s)
    prepare()
    local c0, c1, c2, c3 = 255, 255, 255, 255
    local len = #s; local i = 1
    while i <= len do
        local last = i + 2047; if last > len then last = len end
        for j = i, last do
            local idx = xor8(c0, byte(s, j))
            c0 = xor8(c1, T0[idx]); c1 = xor8(c2, T1[idx]); c2 = xor8(c3, T2[idx]); c3 = T3[idx]
        end
        i = last + 1; work(2048)
    end
    return format('%02x%02x%02x%02x', 255 - c3, 255 - c2, 255 - c1, 255 - c0)
end

local B64 = {}
local alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
for i = 1, 64 do B64[i - 1] = alphabet:sub(i, i) end
function E.base64(s)
    local out, n, len = {}, 0, #s
    for i = 1, len, 3 do
        local a, b, c = byte(s, i, i + 2)
        local v = a * 65536 + (b or 0) * 256 + (c or 0)
        local c1, c2 = B64[floor(v / 262144)], B64[floor(v / 4096) % 64]
        local c3 = b and B64[floor(v / 64) % 64] or '='
        local c4 = c and B64[v % 64] or '='
        n = n + 1; out[n] = c1 .. c2 .. c3 .. c4
        if n % 1024 == 0 then work(3072) end
    end
    return concat(out)
end

-- JSON strings: escape quotes, backslash and controls; keep valid UTF-8 bytes as is,
-- replace invalid sequences by U+FFFD so the export is always valid UTF-8 JSON.
local escapes = {['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t'}
local function utf8clean(s)
    if not s:find('[\128-\255]') then return s end
    local out, i, len = {}, 1, #s
    while i <= len do
        local c = byte(s, i); local n
        if c < 0x80 then n = 1
        elseif c >= 0xC2 and c <= 0xDF then n = 2
        elseif c >= 0xE0 and c <= 0xEF then n = 3
        elseif c >= 0xF0 and c <= 0xF4 then n = 4 end
        local ok = n ~= nil and i + n - 1 <= len
        if ok and n > 1 then
            for k = 1, n - 1 do local d = byte(s, i + k); if d < 0x80 or d > 0xBF then ok = false; break end end
            local d = byte(s, i + 1)
            if ok and (c == 0xE0 and d < 0xA0 or c == 0xED and d > 0x9F or c == 0xF0 and d < 0x90 or c == 0xF4 and d > 0x8F) then ok = false end
        end
        if ok then out[#out + 1] = s:sub(i, i + n - 1); i = i + n
        else out[#out + 1] = '\239\191\189'; i = i + 1 end
    end
    return concat(out)
end
local function jstring(s)
    s = utf8clean(s)
    return '"' .. s:gsub('[%c"\\]', function(ch) return escapes[ch] or format('\\u%04x', byte(ch)) end) .. '"'
end
E.jstring = jstring
local function jnumber(v)
    if v ~= v or v == math.huge or v == -math.huge then return 'null' end
    if v == floor(v) and v >= -9007199254740992 and v <= 9007199254740992 then return format('%d', v) end
    return format('%.14g', v)
end

-- Tables keyed 1..n become arrays; others objects with sorted keys (deterministic output).
-- Empty tables are objects unless their key is listed in arrays.
local ARRAYS = {bankMoney = true, gaps = true}
local encode
local function isArray(t, key)
    local n = #t
    if n == 0 then return ARRAYS[key] == true end
    local count = 0
    for _ in pairs(t) do count = count + 1 end
    return count == n
end
function encode(v, out, key)
    local kind = type(v)
    if kind == 'string' then out[#out + 1] = jstring(v)
    elseif kind == 'number' then out[#out + 1] = jnumber(v)
    elseif kind == 'boolean' then out[#out + 1] = v and 'true' or 'false'
    elseif kind == 'table' then
        if isArray(v, key) then
            out[#out + 1] = '['
            for i = 1, #v do
                if i > 1 then out[#out + 1] = ',' end
                encode(v[i], out, nil)
            end
            out[#out + 1] = ']'
        else
            -- Keys and values are captured before any pause, so a scan running between
            -- two frames cannot leave a hole in the output.
            local keys, vals = {}, {}
            for k, val in pairs(v) do
                local tk = type(val)
                if (type(k) == 'string' or type(k) == 'number') and (tk == 'string' or tk == 'number' or tk == 'boolean' or tk == 'table') then
                    local sk = tostring(k); keys[#keys + 1] = sk; vals[sk] = val
                end
            end
            table.sort(keys)
            out[#out + 1] = '{'
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = ',' end
                out[#out + 1] = jstring(k); out[#out + 1] = ':'
                encode(vals[k], out, k)
            end
            out[#out + 1] = '}'
        end
        work(40)
    else out[#out + 1] = 'null' end
end
function E.json(v) local out = {}; encode(v, out, nil); return concat(out) end

-- Export subset defined by the contract: everything except bankMoney is kept whole.
function E.payload(db)
    local money = {}
    local list = db.bankMoney or {}
    for i = math.max(1, #list - E.BANK_MONEY_KEPT + 1), #list do money[#money + 1] = list[i] end
    return {
        schema = db.schema, addonVersion = db.addonVersion, guild = db.guild,
        scannedBy = db.scannedBy or {}, ledger = db.ledger or {}, events = db.events or {},
        roster = db.roster or {scannedAt = 0, members = {}}, bankMoney = money, gaps = db.gaps or {},
    }
end

function E.build(db)
    local json = E.json(E.payload(db))
    return E.PREFIX .. E.base64(json) .. '!' .. E.crc32(json), json
end

-- Frame-sliced job: call job:step() once per frame until it returns true.
function E.job(db)
    local job = {done = false}
    local co = coroutine.create(function()
        budget = E.STEP
        return E.build(db)
    end)
    function job:step()
        if self.done then return true end
        local ok, result, json = coroutine.resume(co)
        if not ok then self.done = true; self.error = tostring(result); return true end
        if coroutine.status(co) == 'dead' then self.done = true; self.result = result; self.json = json; return true end
        self.steps = (self.steps or 0) + 1
        return false
    end
    return job
end

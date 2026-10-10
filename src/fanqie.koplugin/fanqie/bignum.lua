--[[ 大整数（bignum）—— 纯 Lua / LuaJIT，无外部依赖。

用途：CM 客户端握手的 DH 运算（`pub = 2^priv mod P`、`shared = server_key^priv mod P`）。
模数取自 ch6vip/fqapp 的 `rust/src/upstream/cm.rs`，是 **RFC 3526 的 1536 位 MODP 群**
（该文件注释写的是 group 15，但常量实际是 1536 位的那个，位长已由向量实测确认为 1536）。

表示：以 2^24 为底的 limb 数组（小端）。选 2^24 是因为双精度能精确表示两个 24 位数的
乘积并留出累加余量。模运算用二进制长除法——慢但简单，握手一次只有两三次模幂。

与 KOReader 的关系：KOReader 的 LuaJIT 自带 `bit` 库，本模块只用普通算术，不需要 `bit`。
]]

local BASE = 16777216          -- 2^24
local BASE_BITS = 24

local M = {}

local function trim(a)
    while #a > 1 and a[#a] == 0 do a[#a] = nil end
    return a
end

M.trim = trim

function M.is_zero(a) return #a == 1 and a[1] == 0 end

function M.from_int(n)
    local a = {}
    if n == 0 then return { 0 } end
    while n > 0 do
        a[#a + 1] = n % BASE
        n = math.floor(n / BASE)
    end
    return a
end

function M.from_hex(h)
    local a = { 0 }
    for i = 1, #h do
        local d = tonumber(h:sub(i, i), 16)
        local carry = d
        for k = 1, #a do
            local t = a[k] * 16 + carry
            a[k] = t % BASE
            carry = math.floor(t / BASE)
        end
        while carry > 0 do
            a[#a + 1] = carry % BASE
            carry = math.floor(carry / BASE)
        end
    end
    return trim(a)
end

function M.from_bytes_be(s)
    local a = { 0 }
    for i = 1, #s do
        local carry = string.byte(s, i)
        for k = 1, #a do
            local t = a[k] * 256 + carry
            a[k] = t % BASE
            carry = math.floor(t / BASE)
        end
        while carry > 0 do
            a[#a + 1] = carry % BASE
            carry = math.floor(carry / BASE)
        end
    end
    return trim(a)
end

--- 最小大端字节串（与 num_bigint 的 to_bytes_be 一致：0 → 空串）
function M.to_bytes_be(a)
    if M.is_zero(a) then return "" end
    local out = {}
    local top = a[#a]
    local bytes = {}
    repeat
        bytes[#bytes + 1] = top % 256
        top = math.floor(top / 256)
    until top == 0
    for i = #bytes, 1, -1 do out[#out + 1] = string.char(bytes[i]) end
    for i = #a - 1, 1, -1 do
        local v = a[i]
        out[#out + 1] = string.char(math.floor(v / 65536) % 256,
            math.floor(v / 256) % 256, v % 256)
    end
    return table.concat(out)
end

function M.to_hex(a)
    local h = {}
    for i = #a, 1, -1 do
        h[#h + 1] = string.format(i == #a and "%x" or "%06x", a[i])
    end
    return table.concat(h)
end

function M.cmp(a, b)
    if #a ~= #b then return #a > #b and 1 or -1 end
    for i = #a, 1, -1 do
        if a[i] ~= b[i] then return a[i] > b[i] and 1 or -1 end
    end
    return 0
end

--- a - b（要求 a >= b）
function M.sub(a, b)
    local r, borrow = {}, 0
    for i = 1, #a do
        local t = a[i] - (b[i] or 0) - borrow
        if t < 0 then t = t + BASE; borrow = 1 else borrow = 0 end
        r[i] = t
    end
    return trim(r)
end

function M.mul(a, b)
    local r = {}
    for i = 1, #a + #b do r[i] = 0 end
    for i = 1, #a do
        local ai = a[i]
        if ai ~= 0 then
            local carry = 0
            for j = 1, #b do
                local t = r[i + j - 1] + ai * b[j] + carry
                r[i + j - 1] = t % BASE
                carry = math.floor(t / BASE)
            end
            local k = i + #b
            while carry > 0 do
                local t = r[k] + carry
                r[k] = t % BASE
                carry = math.floor(t / BASE)
                k = k + 1
            end
        end
    end
    return trim(r)
end

--- 取模：二进制长除法（逐位：r = r*2 + bit，若 r>=m 则 r-=m）。
---
--- 为什么不用"按 limb 对齐 + 反复减"那种写法：那样每一步的减法次数等于**该位的前缀商**，
--- 而商可以大到 BASE（2^24）——一旦模数比被除数小很多就会退化成一亿级次减法（实测直接卡死）。
--- 逐位写法每步只做一次比较、最多一次减法，**步数上界是确定的**（约 2×位数），
--- 代价是 1536 位模数下一次取模要几毫秒——一次握手两次模幂，手机上约 8 秒，
--- 但这个成本由 client 侧的会话缓存摊掉了（10 分钟内所有章节复用一次握手）。
--- 想再快就得换成正规的多 limb 除法（估商）或 Barrett/Montgomery —— 那是独立的一块工作，
--- 不该在没有对照测试的情况下顺手改。
function M.mod(a, m)
    if M.cmp(a, m) < 0 then return a end
    local r = { 0 }
    for i = #a, 1, -1 do
        local limb = a[i]
        for b = BASE_BITS - 1, 0, -1 do
            local bit = math.floor(limb / 2 ^ b) % 2
            -- r = r*2 + bit
            local carry = bit
            for k = 1, #r do
                local t = r[k] * 2 + carry
                r[k] = t % BASE
                carry = math.floor(t / BASE)
            end
            if carry > 0 then r[#r + 1] = carry end
            if M.cmp(r, m) >= 0 then r = M.sub(r, m) end
        end
    end
    return trim(r)
end

--- 模幂：平方-乘法。exp 是 limb 数组。
function M.powmod(base, exp, m)
    local result = { 1 }
    local b = M.mod(base, m)
    local e = {}
    for i = 1, #exp do e[i] = exp[i] end
    while not M.is_zero(e) do
        if e[1] % 2 == 1 then result = M.mod(M.mul(result, b), m) end
        local carry = 0
        for i = #e, 1, -1 do
            local cur = e[i] + carry * BASE
            e[i] = math.floor(cur / 2)
            carry = cur % 2
        end
        trim(e)
        if not M.is_zero(e) then b = M.mod(M.mul(b, b), m) end
    end
    return result
end

return M

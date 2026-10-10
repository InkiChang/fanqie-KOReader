-- fanqie.sm3 用例
--
-- 为什么单独一个 spec：SM3 在番茄签名里用来算 bodyHash / queryHash（各取前 6 字节）。
-- 它出错的方式是**静默的**——算错了不会报错，只会让签名被服务端拒掉。
--
-- 验收标准两条，互相独立：
--   1) 与 **公开标准向量** 一致（GB/T 32905-2016 的样例），不依赖我们自己的任何实现；
--   2) 与本项目的 Python 参考实现逐字节一致（向量由 `gen_lua_vectors.py` 生成）。
-- 两条都过，才能排除"两边一起错"的情况。

local T = require("tap")
local K = require("koreader")   -- 装上基座：把 src/fanqie.koplugin 放进 package.path

local sm3 = require("fanqie.sm3")
local SC = require("fanqie.sign_crypto")

--- 读向量表（由 .cache/tmp/gen_lua_vectors.py 生成）
local function load_vectors()
    local tries = {
        "tests/spec/vectors_sign_extra.lua",
        "tests/spec/vectors_sign_extra.lua",
    }
    for _, p in ipairs(tries) do
        local ok, res = pcall(dofile, p)
        if ok and type(res) == "table" then return res end
    end
    error("找不到 tests/spec/vectors_sign_extra.lua（请从仓库根目录运行测试）")
end

local V = load_vectors()

local function unhex(s)
    return (s:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

T.test("SM3 与公开标准向量一致（GB/T 32905 样例）", function(t)
    -- SM3("abc") 的公开值：不依赖我们自己的任何实现
    t:eq(sm3.hash_hex("abc"),
        "66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0",
        'SM3("abc")')
    -- 注意：GB/T 32905 的官方样例是 64 字节的 "abcd"×16，
    -- 它的摘要是 debe9ff9...；而 4 字节的 "abcd" 是 82ec580f...。两者别搞混。
    t:eq(sm3.hash_hex("abcd"),
        "82ec580fe6d36ae4f81cae3c73f4a5b3b5a09c943172dc9053c69fd8e18dca1e",
        'SM3("abcd")')
    t:eq(sm3.hash_hex(string.rep("abcd", 16)),
        "debe9ff92275b8a138604889c18e5a4d6fdb70e5387e5765293dcba39c0c5732",
        'SM3("abcd"x16) —— GB/T 32905 标准样例')
end)

T.test("SM3 与 Python 参考实现逐字节一致", function(t)
    t:ok(type(V.sm3) == "table", "向量表里有 sm3 段")
    local n = 0
    for name, case in pairs(V.sm3) do
        t:eq(sm3.hash_hex(unhex(case.msg)), case.want, "sm3/" .. name)
        n = n + 1
    end
    t:eq(n, 7, "向量条数（空/abc/中文/55/56/64/1000 字节）")
end)

T.test("SM3 的 prefix6 就是前 6 字节（签名里用的形式）", function(t)
    local h = sm3.hash("abc")
    t:eq(#h, 32, "摘要长度 32 字节")
    t:eq(sm3.prefix6("abc"), h:sub(1, 6), "prefix6 = 摘要前 6 字节")
    t:eq(#sm3.prefix6("abc"), 6, "prefix6 长度 6")
    -- 空消息也要能算（bodyHash 在无 body 时会用 16 个零字节，但空串本身也不能崩）
    t:eq(#sm3.hash(""), 32, "空消息摘要长度")
end)

T.test("SM3 对跨 64 字节边界与长输入稳定（分组填充）", function(t)
    t:eq(sm3.hash_hex(unhex(V.sm3.len55.msg)), V.sm3.len55.want, "55 字节（填充刚好放得下）")
    t:eq(sm3.hash_hex(unhex(V.sm3.len56.msg)), V.sm3.len56.want, "56 字节（必须多开一块）")
    t:eq(sm3.hash_hex(unhex(V.sm3.len64.msg)), V.sm3.len64.want, "64 字节（正好一块）")
    t:eq(sm3.hash_hex(unhex(V.sm3.len1000.msg)), V.sm3.len1000.want, "1024 字节（多块）")
end)

-- ── Simon（X-Argus 的内层加密）───────────────────────────────────────

local simon = require("fanqie.simon")

T.test("Simon-64/128 与 Python 参考实现逐字节一致", function(t)
    t:ok(type(V.simon) == "table", "向量表里有 simon 段")
    local n = 0
    for name, case in pairs(V.simon) do
        if type(case) == "table" then
            local ca, cb = simon.encrypt_hex(case.a, case.b, V.simon.key)
            t:eq(ca, case.ca, "simon/" .. name .. " 左半字")
            t:eq(cb, case.cb, "simon/" .. name .. " 右半字")
            n = n + 1
        end
    end
    t:eq(n, 4, "向量条数（zero / seq / ones / one）")
end)

T.test("Simon 的 64 位循环移位在跨半字时不丢位", function(t)
    -- 直接盯住最容易写错的地方：rotr 跨 32 位边界
    local v = simon.from_hex("0000000100000002")
    t:eq(simon.to_hex(simon.from_hex("0000000100000002")), "0000000100000002", "hex 往返")
    -- rotr64(0x0000000100000002, 1) = 0x8000000080000001
    local r = simon.rotate_for_test and simon.rotate_for_test(v, 1) or nil
    if r then
        t:eq(simon.to_hex(r), "8000000080000001", "跨半字循环右移 1 位")
    else
        t:skip("模块未暴露 rotate_for_test，跳过（不是失败）")
    end
end)

-- ── AES：番茄正文解密需要 AES-256（128 位也要对）─────────────────────

T.test("AES-128-CBC 对上 NIST SP800-38A F.2.1", function(t)
    local AES = SC.aes_cbc_encrypt or SC.aes128_cbc_encrypt
    t:ok(type(AES) == "function", "sign_crypto 暴露 CBC 加密")
    t:eq(SC.hex_encode(AES(unhex(V.aes.aes128_key_pt), unhex(V.aes.aes128_key), unhex(V.aes.aes128_key_iv))),
        V.aes.aes128_key_ct, "AES-128-CBC NIST 向量")
end)

T.test("AES-256-CBC 对上 NIST SP800-38A F.2.5", function(t)
    local AES = SC.aes_cbc_encrypt or SC.aes128_cbc_encrypt
    t:ok(type(AES) == "function", "sign_crypto 暴露 CBC 加密")
    -- CM 握手解密正文用的是 AES-256。若这条失败，说明 sign_crypto 只实现了 128 位密钥轮数。
    t:eq(SC.hex_encode(AES(unhex(V.aes.aes256_key_pt), unhex(V.aes.aes256_key), unhex(V.aes.aes256_key_iv))),
        V.aes.aes256_key_ct, "AES-256-CBC NIST 向量")
end)

T.test("AES 解密能还原 NIST 明文（CM 解正文要用）", function(t)
    local D = SC.aes_cbc_decrypt
    t:ok(type(D) == "function", "sign_crypto 暴露 aes_cbc_decrypt")
    if type(D) ~= "function" then return end
    -- 解密是独立一关：加密对了不代表解密对（InvSubBytes/InvMixColumns 极易写错）
    t:eq(SC.hex_encode(D(unhex(V.aes.aes128_key_ct), unhex(V.aes.aes128_key), unhex(V.aes.aes128_key_iv))),
        V.aes.aes128_key_pt, "AES-128-CBC 解密还原 NIST 明文")
    t:eq(SC.hex_encode(D(unhex(V.aes.aes256_key_ct), unhex(V.aes.aes256_key), unhex(V.aes.aes256_key_iv))),
        V.aes.aes256_key_pt, "AES-256-CBC 解密还原 NIST 明文")
    t:eq(SC.hex_encode(D(unhex(V.aes.handshake_ct), unhex(V.aes.handshake_key), unhex(V.aes.handshake_iv))),
        V.aes.handshake_pt, "CM 握手那条 16 字节密钥向量也能还原")
    -- 空数据不应崩
    t:eq(D("", unhex(V.aes.aes128_key), unhex(V.aes.aes128_key_iv)), "", "空输入返回空")
end)

-- ── X-Argus 551：直接对上游黄金向量（这是最强的一关）────────────────

T.test("X-Argus 551 命中上游黄金向量（crypto_vectors.rs）", function(t)
    local arg = require("fanqie.argus")
    local G
    for _, p in ipairs({
        "tests/spec/vectors_argus551.lua",
        "tests/spec/vectors_argus551.lua",
    }) do
        local ok, res = pcall(dofile, p)
        if ok and type(res) == "table" then G = res; break end
    end
    t:ok(type(G) == "table", "读到黄金向量表")
    if type(G) ~= "table" then return end
    t:eq(#G, 4, "黄金向量条数")
    for i, c in ipairs(G) do
        -- install_id 传空串、license_id 1611921764 —— 与上游测试的调用一致
        local got = arg.get_sign(c.query, "", c.ts, 1967, 1611921764, c.device_id, "", "551", c.f3)
        t:eq(got, c.want, "golden#" .. i .. " " .. c.query)
    end
end)

T.test("X-Argus 的 bean 与哈希助手自检", function(t)
    local arg = require("fanqie.argus")
    -- 空 query / 空 stub 走"16 个零字节"分支，且长度都是 6
    t:eq(#arg.query_hash(""), 6, "空 query 的 queryHash 长度 6")
    t:eq(#arg.body_hash(""), 6, "空 stub 的 bodyHash 长度 6")
    t:eq(arg.query_hash("a=1"), sm3.hash("a=1"):sub(1, 6), "非空 queryHash = SM3(query) 前 6 字节")
    -- query_param 取首个匹配，且能解百分号转义
    t:eq(arg.query_param("a=1&version_name=6.5.1.32&b=2", "version_name"), "6.5.1.32", "取 version_name")
    t:eq(arg.query_param("x=%E4%B8%AD", "x"), "中", "百分号转义解码")
    t:eq(arg.query_param("a=1", "zzz"), nil, "找不到返回 nil")
end)

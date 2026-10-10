-- fanqie.sign_crypto 用例
--
-- 这个模块是把番茄小说签名里**与密钥无关的密码学部分**从 Python 参考实现
--   refs/fanqie_sign.py
-- 翻成纯 Lua 的结果。它出错的方式是**静默**的：SHA-256 少一轮、AES 的
-- ShiftRows 方向反了、varint 的续延位写错——本机看着"跑通了"，到设备上
-- 只是签名被服务端拒掉，看不出是哪一环。
--
-- 所以这里的验收标准只有一条：**逐字节等于 Python**。下面的向量全部是
-- 硬编码的（输入 hex + 期望输出 hex），不依赖 Python 侧任何东西，也不依赖
-- 随机数。生成方式见文件末尾的标记区说明。
--
-- 三个容易"优化错"的地方，各有一条专门的用例盯着：
--   * pkcs7 对已对齐的数据**仍然追加一整块**；
--   * write_varint 先把值截断成 u32，且循环条件是 `> 0x80` 而不是 `>= 0x80`；
--   * ladon 的轮常量表头 32 字节是 md5 hex **字符的 ASCII 码**，不是解码后的 16 字节。

local T = require("tap")
local K = require("koreader")   -- 装上基座：把 src/fanqie.koplugin 放进 package.path

local SC = require("fanqie.sign_crypto")

local hx = SC.hex_encode

--- hex 字符串 → 字节串（向量表里输入统一用 hex 写，避免编辑器/编码破坏二进制）。
local function unhex(s)
    return SC.hex_decode(s)
end

-- 下面一整段由 `python scripts/gen_sign_crypto_vectors.py --update-spec` 生成。
-- >>> BEGIN GENERATED VECTORS（由 scripts/gen_sign_crypto_vectors.py 生成，勿手改）
local V = {}

V.sha256 = {
    { "", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" },
    { "abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" },
    { "番茄小说", "0d59901cdd8093d1cd6338c6408f56b99c6b3379786d889a1c97e0ce9a5bdf51" },
    { "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb" },
    { "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318" },
    { "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a" },
}

V.md5 = {
    { "", "d41d8cd98f00b204e9800998ecf8427e" },
    { "abc", "900150983cd24fb0d6963f7d28e17f72" },
    { "番茄小说", "bd6de23a83259e2798a2415b927bcee6" },
    { "The quick brown fox jumps over the lazy dog", "9e107d9d372bb6826bd81d3542a419d6" },
}

V.b64 = {
    { "", "" },
    { "66", "Zg==" },
    { "666f", "Zm8=" },
    { "666f6f", "Zm9v" },
    { "666f6f62", "Zm9vYg==" },
    { "666f6f6261", "Zm9vYmE=" },
    { "666f6f626172", "Zm9vYmFy" },
    { "e795aae88c84", "55Wq6IyE" },
    { "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff", "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0+P0BBQkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYKDhIWGh4iJiouMjY6PkJGSk5SVlpeYmZqbnJ2en6ChoqOkpaanqKmqq6ytrq+wsbKztLW2t7i5uru8vb6/wMHCw8TFxsfIycrLzM3Oz9DR0tPU1dbX2Nna29zd3t/g4eLj5OXm5+jp6uvs7e7v8PHy8/T19vf4+fr7/P3+/w==" },
}

V.aes_ecb = {
    key = "000102030405060708090a0b0c0d0e0f",
    plain = "00112233445566778899aabbccddeeff6bc1bee22e409f96e93d7e117393172af69f2445df4f9b17ad2b417be66c3710",
    cipher = "69c4e0d86a7b0430d8cdb78070b4c55a47c58d5e21caaf840d015b7d9b910981ae4ea8f78fb85884cb77dc4d11e98392",
}

V.aes_cbc = {
    key = "2b7e151628aed2a6abf7158809cf4f3c",
    iv = "000102030405060708090a0b0c0d0e0f",
    plain = "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e5130c81c46a35ce411e5fbc1191a0a52ef",
    cipher = "7649abac8119b246cee98e9b12e9197d5086cb9b507219ee95db113a917678b273bed6b8e3c1743b7116e69e22229516",
}

V.pkcs7 = {
    { "", "10101010101010101010101010101010" },
    { "31", "310f0f0f0f0f0f0f0f0f0f0f0f0f0f0f" },
    { "3132333435363738", "31323334353637380808080808080808" },
    { "303132333435363738396162636465", "30313233343536373839616263646501" },
    { "30313233343536373839616263646566", "3031323334353637383961626364656610101010101010101010101010101010" },
    { "3031323334353637383961626364656630", "30313233343536373839616263646566300f0f0f0f0f0f0f0f0f0f0f0f0f0f0f" },
}

V.ror64 = {
    { "0000000000000001", 1, "8000000000000000" },
    { "0000000000000001", 8, "0100000000000000" },
    { "0000000000000001", 61, "0000000000000008" },
    { "8000000000000000", 1, "4000000000000000" },
    { "0123456789abcdef", 8, "ef0123456789abcd" },
    { "0123456789abcdef", 40, "6789abcdef012345" },
    { "ffffffffffffffff", 13, "ffffffffffffffff" },
    { "0f0f0f0f0f0f0f0f", 32, "0f0f0f0f0f0f0f0f" },
    { "deadbeefcafebabe", 0, "deadbeefcafebabe" },
    { "00000000ffffffff", 63, "00000001fffffffe" },
}

V.ladon = {
    khronos = 1791600000,
    lc_id = 0,
    aid = 1967,
    rand4 = "9ae1b0ac",
    ht = "6264363139343033d6bed51cb9c6e6f28ed2a7b5d6c27cc284a3e345bb3107e405166499f8144b8b0190977c2bf8f89e31ed3c6f09183766b60f14e8e94a5ab964bb6b9706bccc2df8e0aa52eb4c3b0597d36b602f481e6bec031da96126f7654fe4eec103b6db10570393382dcac3ee445ca597fd9e1e301081041b6ef6aadcb86d189698a744e929c7a89aac94afaed0cc08c8ca577795a36f11f089d4397845a6b0d87dfbd0a603c748439edc36720226bf38fb84bc0bdb51eeae8384c7371e910768961130d8d202163145974a30bb0c3103c100e0791be4d897fe0a468e622e8d30ee8207c176dc719dd8203fe45dcf8e7f2160798599636b66fd96e76f9c60df3cde2defaf0d6488c4b4c0eae568a1619feae878740000000000000000",
    out = "muGwrFUOXpVJmluqmFANY2ZTTgMW8OCQUw+a+KCBxcrArXz0",
    long_data = "1791600000-0-999",
    long_out = "muGwrLePcaxYPVNhAUE29Q20qzTcLt7SQdyYWKdt7ifd6NbU",
}

V.sign = {
    { q = "query=aid=1967&book_id=1", data = nil, ts = 1791600000, aid = 1967, dev = "1234567890123456", ver = "7.0.1.32",
      rand = 57005, out = "8oG/Dy1BytAiUdkusxvJ5k9mEARPehcHa3JynMpoBI3GVxGURCHKnUQCdSoH8A0OFZ3AGtch4sLVuw6JNQe32SpOk1XNkxjWiz8x7OJGFO+SLezr5Z6G1KB+42D65B6PetYoen+oJHXKZfyUHBiS3/ydNBzkHCY+n/qEm94mnxOmx/kTiWFlwiFqZOrY7jB8raNNqutrRcJ9NyXoOS3jRaBZDct5GwRqE8wZnWJN+eQeowU8how28Ig6Pe82l8kW0MvFwgHq/mS33fnX6zOpcTrc" },
    { q = "", data = "aabbccddeeff00112233445566778899", ts = 1700000000, aid = 0, dev = "", ver = "",
      rand = 0, out = "8oGlP7ez5Jv/ySLlqVM8Wz2vsA7rINP3neEB375EyD4aXRmoLEarupJesUGjiksurMurF2vcLCEgH1TBUOZO+utwrO+oXD8hLEH8tjmVf1sv+0ohOELvyRII5g2GdmCRgKjCa1Szh3ywkPhThGxsMdON6Qd7wEXcHOaqqNtBsvpp+neq3iiA7nFE97dqdSdflf7O2MrJUV2L+NjSGIKHaBH384hcD+2OawLsjWAXClKK/Q==" },
    { q = "wechat", data = "00", ts = 4294967295, aid = 1611921764, dev = "ABCDEF0123456789", ver = "v04.04.05-ov-android",
      rand = 2147483647, out = "8oEoRwUOI9IHefNtCZDx7ZWBiVIWqcuNZXiKmstNz7b1OgjOsNb8tc/yMCAPR3E/kx+ajB1QuoNTT9D2FAWBApPPdQNqlhL23sm/kYcRksuN3FiWOOASFS9Fda+Nw7JY+h2awUXSsB046+9TaY9WYTBVxEHREadZSshNduulot/bRp2y66vGXwH8GhUhhCYcMRHosTEFzJOc61N7leWfI3cMYPbw0e0XGspfbQ9EcAIXnex+9Nh3E8GGBqqT7Ygr+WXdnodUB5XcZZs1gfeZL12+raI9Ta9/eEG3MltHjHMVig==" },
}

V.varint = {
    { 0, "00" },
    { 1, "01" },
    { 127, "7f" },
    { 128, "00" },
    { 129, "8101" },
    { 255, "ff01" },
    { 256, "8002" },
    { 16383, "ff7f" },
    { 16384, "8000" },
    { 3348294860, "ccd9cbbc0c" },
    { 4294967295, "ffffffff0f" },
    { 4886718345, "89cf959a02" },
    { 1077940818, "d2a4808204" },
    { 269489280, "80a9c000" },
}

V.dict = {
    -- 单字段 varint
    { fields = { { 1, "varint", 2 } },
      out = "0802" },
    -- 嵌套 dict
    { fields = { { 15, "dict", { { 1, "varint", 1 }, { 2, "varint", 1 }, { 3, "varint", 1 }, { 7, "varint", 3348294860 } } } },
      out = "7a0c08011001180138ccd9cbbc0c" },
    -- utf8 + bytes
    { fields = { { 4, "utf8", "1967" }, { 10, "bytes", "\000\000\000\000\000\000\000\000" }, { 20, "utf8", "none" } },
      out = "22043139363752080000000000000000a201046e6f6e65" },
    -- 空 utf8
    { fields = { { 16, "utf8", "" } },
      out = "820100" },
    -- 大 varint
    { fields = { { 12, "varint", 3583200000 }, { 25, "varint", 2 } },
      out = "608096cdac0dc80102" },
    -- varint 怪癖 128
    { fields = { { 1, "varint", 128 } },
      out = "0800" },
    -- get_sign 字段 15
    { fields = { { 15, "dict", { { 1, "varint", 1 }, { 2, "varint", 1 }, { 3, "varint", 1 }, { 7, "varint", 3348294860 } } } },
      out = "7a0c08011001180138ccd9cbbc0c" },
}
-- <<< END GENERATED VECTORS

-- ── 哈希 ──────────────────────────────────────────────────────────────

T.test("sha256 与 Python 参考实现逐字节一致", function(t)
    t:eq(#V.sha256, 6, "向量条数（空串 / abc / 中文 / 跨块边界 55/56/64 字节）")
    for i = 1, #V.sha256 do
        local msg, want = V.sha256[i][1], V.sha256[i][2]
        local got = hx(SC.sha256(msg))
        t:eq(got, want, "sha256(" .. string.format("%q", msg) .. ")")
        -- sha256 必须返回 32 字节**二进制**，不是 hex
        t:eq(#SC.sha256(msg), 32, "sha256 长度应为 32 字节")
    end
    -- 明文 hex 辅助函数应与手工 hex 一致
    t:eq(SC.sha256_hex(V.sha256[3][1]), V.sha256[3][2], "sha256_hex 与 sha256 一致")
end)

T.test("md5 与 Python 参考实现逐字节一致", function(t)
    t:eq(#V.md5, 4, "向量条数")
    for i = 1, #V.md5 do
        local msg, want = V.md5[i][1], V.md5[i][2]
        t:eq(hx(SC.md5(msg)), want, "md5(" .. string.format("%q", msg) .. ")")
        t:eq(#SC.md5(msg), 16, "md5 长度应为 16 字节")
    end
    t:eq(SC.md5_hex(V.md5[2][1]), V.md5[2][2], "md5_hex 与 md5 一致")
end)

-- ── 编码 ──────────────────────────────────────────────────────────────

T.test("base64_encode 与 Python 参考实现逐字节一致", function(t)
    t:eq(#V.b64, 9, "向量条数（含 0/1/2 字节尾部与全部 256 个字节值）")
    for i = 1, #V.b64 do
        local raw, want = V.b64[i][1], V.b64[i][2]
        t:eq(SC.base64_encode(unhex(raw)), want, "base64(" .. raw:sub(1, 24) .. ")")
    end
    -- 清单点名的向量：base64_encode("abc") → "YWJj"（明文是 ASCII，不是 hex）
    t:eq(SC.base64_encode("abc"), "YWJj", 'base64_encode("abc")')
    t:eq(SC.base64_encode(unhex("616263")), "YWJj", "同一个值的 hex 写法必须给同一结果")
end)

T.test("pkcs7_pad 与 Python 一致：已对齐仍补整块", function(t)
    t:eq(#V.pkcs7, 6, "向量条数")
    for i = 1, #V.pkcs7 do
        local src, want = V.pkcs7[i][1], V.pkcs7[i][2]
        t:eq(hx(SC.pkcs7_pad(unhex(src), 16)), want, "pkcs7_pad(#" .. #src / 2 .. ")")
    end
    -- 单独把"已对齐"这条挑出来说清楚：16 字节输入 → 32 字节输出
    local aligned = unhex(V.pkcs7[5][1])
    t:eq(#aligned, 16, "第 5 条恰好是一个整块")
    t:eq(#SC.pkcs7_pad(aligned, 16), 32, "已对齐的数据仍要追加完整的一块")
    t:eq(SC.pkcs7_pad(aligned, 16):sub(17), string.rep("\16", 16), "追加的是 16 个 0x10")
end)

-- ── 分组密码 ──────────────────────────────────────────────────────────

T.test("aes128_ecb_encrypt 与 Python 参考实现逐字节一致", function(t)
    local key = unhex(V.aes_ecb.key)
    local plain = unhex(V.aes_ecb.plain)
    t:eq(#plain, 48, "多块明文（3 块）")
    t:eq(hx(SC.aes128_ecb_encrypt(plain, key)), V.aes_ecb.cipher, "ECB 3 块")
    -- 单块（FIPS-197 官方向量，模块载入自检也用了同一个）
    t:eq(hx(SC.aes128_ecb_encrypt(plain:sub(1, 16), key)),
        V.aes_ecb.cipher:sub(1, 32), "ECB 单块应等于整串的第一块")
end)

T.test("aes128_cbc_encrypt 与 Python 参考实现逐字节一致", function(t)
    local key = unhex(V.aes_cbc.key)
    local iv = unhex(V.aes_cbc.iv)
    local plain = unhex(V.aes_cbc.plain)
    t:eq(#plain, 48, "多块明文（NIST SP800-38A F.2.1）")
    t:eq(hx(SC.aes128_cbc_encrypt(plain, key, iv)), V.aes_cbc.cipher, "CBC 3 块")
    t:eq(hx(SC.aes128_cbc_encrypt(plain:sub(1, 16), key, iv)),
        V.aes_cbc.cipher:sub(1, 32), "CBC 单块应等于整串的第一块")
    -- 链式：第二块必须受第一块密文影响（拿全零 IV 当对照）
    local zero_iv = string.rep("\0", 16)
    t:neq(hx(SC.aes128_cbc_encrypt(plain:sub(1, 16), key, zero_iv)),
        V.aes_cbc.cipher:sub(1, 32), "换 IV 必须换结果")
end)

-- ── X-Ladon ───────────────────────────────────────────────────────────

T.test("ror64 与 Python 参考实现逐字节一致", function(t)
    t:eq(#V.ror64, 10, "向量条数（含 c=0/32/61/63 边界）")
    for i = 1, #V.ror64 do
        local hex, c, want = V.ror64[i][1], V.ror64[i][2], V.ror64[i][3]
        local v = { hi = tonumber(hex:sub(1, 8), 16), lo = tonumber(hex:sub(9, 16), 16) }
        local r = SC.ror64(v, c)
        t:eq(string.format("%08x%08x", r.hi, r.lo), want, "ror64(" .. hex .. ", " .. c .. ")")
    end
end)

T.test("ladon 轮常量表与 Python 参考实现逐字节一致", function(t)
    t:eq(hx(SC.ladon_round_table(unhex(V.ladon.rand4), V.ladon.aid)), V.ladon.ht,
        "轮常量表应为 288 字节（272+16）")
    -- 头 8 字节必须是 md5 hex 的 **ASCII 码**，不是 16 字节摘要。
    -- 参考实现先把 32 字节 md5hex 写进 ht[0:32]，但紧接着的轮循环会从偏移 8 开始
    -- 覆写，所以只有前 8 字节还能认出是 ASCII hex（其余是轮常量）。
    local ht = SC.ladon_round_table(unhex(V.ladon.rand4), V.ladon.aid)
    local md5hex = SC.md5_hex(unhex(V.ladon.rand4) .. tostring(V.ladon.aid))
    t:eq(ht:sub(1, 8), md5hex:sub(1, 8), "头 8 字节应是 md5 hex 的 ASCII 码")
    t:eq(SC.md5_hex(unhex(V.ladon.rand4) .. tostring(V.ladon.aid)),
        "bd6194038e90d737bbe46e0d5be538dd", "rand4=9ae1b0ac, aid=1967 的 md5")
end)

T.test("ladon 固定随机量输出与 Python 参考实现逐字节一致", function(t)
    t:eq(SC.ladon(V.ladon.khronos, V.ladon.lc_id, V.ladon.aid, unhex(V.ladon.rand4)),
        V.ladon.out, "ladon(1791600000, 0, 1967, 9ae1b0ac)")
    -- long_data 是**当成 aid 传进去**的，所以真正的明文是
    --   tostring(khronos).."-"..tostring(lc_id).."-"..long_data = 29 字节，
    -- 并不是 16 的整数倍——这条只覆盖"两个分组的长明文"，
    -- **没有**落在"已对齐仍补整块"那条分支上（那条由上面的 pkcs7_pad 用例负责）。
    t:eq(SC.ladon(V.ladon.khronos, V.ladon.lc_id, V.ladon.long_data,
        unhex(V.ladon.rand4)), V.ladon.long_out, "ladon（明文 29 字节 / 两个分组）")
    t:eq(#V.ladon.long_data, 16, "long_data 这个 aid 字面量本身是 16 字节")
    local plain = tostring(V.ladon.khronos) .. "-" .. tostring(V.ladon.lc_id) .. "-" .. V.ladon.long_data
    t:eq(#plain, 29, "拼接后的明文是 29 字节，不是整分组")
    t:eq(#SC.pkcs7_pad(plain, 16), 32, "29 字节补到 32 字节（两个分组）")
end)

-- ── protobuf 写入器 ───────────────────────────────────────────────────

T.test("write_varint 复刻 u32 截断与 `> 0x80` 两个怪癖", function(t)
    t:eq(#V.varint, 14, "向量条数")
    for i = 1, #V.varint do
        local v, want = V.varint[i][1], V.varint[i][2]
        local out = {}
        SC.write_varint(out, v)
        t:eq(hx(table.concat(out)), want, "write_varint(" .. v .. ")")
    end
    -- 怪癖 1：值先被截断成 u32 —— 0x123456789 与 0x23456789 编码结果相同
    local a, b = {}, {}
    SC.write_varint(a, 4886718345)      -- 0x123456789
    SC.write_varint(b, 0x23456789)
    t:eq(hx(table.concat(a)), hx(table.concat(b)), "超过 u32 的部分必须被截掉")
    -- 怪癖 2：循环条件是 `v > 0x80`，所以 128 编码成单字节 0x00（而不是 0x80 0x01）
    local c = {}
    SC.write_varint(c, 128)
    t:eq(hx(table.concat(c)), "00", "128 落到 `> 0x80` 的空档里，只写 0x00")
end)

T.test("encode_dict 与 Python 参考实现逐字节一致（含嵌套 dict）", function(t)
    t:eq(#V.dict, 7, "向量条数")
    for i = 1, #V.dict do
        local case = V.dict[i]
        t:eq(hx(SC.encode_dict(case.fields)), case.out, "encode_dict 第 " .. i .. " 组")
    end
    -- 嵌套 dict 是 X-Argus 里字段 15/23 的形态，单独确认它真的嵌进去了
    local nested = SC.encode_dict(V.dict[2].fields)
    t:eq(nested:sub(1, 1), "\122", "字段 15 + wire type 2 的 key 是 (15<<3)|2 = 0x7a")
    t:contains(hx(nested), "ccd9cbbc0c", "嵌套里应含 3348294860 的 varint")
    -- 清单点名的用例：dict 里也要有**超过 u32** 的 varint（触发 write_varint 的截断）。
    -- 生成的 7 组里最大只有 3583200000，还在 u32 之内，所以这里补三条；
    -- 期望值由 Python 参考实现算出：
    --   ref.encode_dict([(1, "varint", 4886718345)]).hex()               == "0889cf959a02"
    --   ref.encode_dict([(9, "dict", [(1,"varint",4886718345),(2,"utf8","x")])]).hex()
    --                                                                   == "4a090889cf959a02120178"
    t:eq(hx(SC.encode_dict({ { 1, "varint", 4886718345 } })), "0889cf959a02",
        "encode_dict 里的大 varint 同样先被截断成 u32")
    t:eq(hx(SC.encode_dict({ { 1, "varint", 0x23456789 } })), "0889cf959a02",
        "0x123456789 截断后与 0x23456789 编码相同")
    t:eq(hx(SC.encode_dict({ { 9, "dict", { { 1, "varint", 4886718345 }, { 2, "utf8", "x" } } } })),
        "4a090889cf959a02120178", "嵌套 dict 里的大 varint（字段 9 → key (9<<3)|2 = 0x4a）")
end)

-- ── X-Argus 全链路 ────────────────────────────────────────────────────

T.test("get_sign 固定随机量输出与 Python 参考实现逐字节一致", function(t)
    t:eq(#V.sign, 3, "向量条数")
    for i = 1, #V.sign do
        local c = V.sign[i]
        local got = SC.get_sign(c.q, c.data, c.ts, c.aid, c.dev, c.ver, c.rand)
        t:eq(got, c.out, "get_sign 第 " .. i .. " 组（rand=" .. c.rand .. "）")
        t:eq(got:sub(1, 2), "8o", "密文前缀 \\242\\129 的 base64")
    end
    -- 同一个输入换个随机量必须换结果（说明 rand 真的进了 protobuf）
    local c = V.sign[1]
    t:neq(SC.get_sign(c.q, c.data, c.ts, c.aid, c.dev, c.ver, c.rand + 1), c.out,
        "rand 变了结果必须变")
end)

T.test("sign_crypto 的模块级常量与参考实现一致", function(t)
    -- SIGN_KEY 是模块级常量（将来要换成真 key），不是写死在函数里的字面量
    t:eq(type(SC.SIGN_KEY), "string", "SIGN_KEY 是模块级常量")
    t:eq(#SC.SIGN_KEY, 32, "SIGN_KEY 32 字节")
    t:eq(hx(SC.SIGN_KEY),
        "ac1adaae95a7af94a5114ab3b3a97dd80050aa0a39314c40528caec95256c28c",
        "SIGN_KEY 内容")
    t:eq(hx(SC.SALT), "f281616f", "SALT")
    t:eq(SC.LICENSE_ID, 1611921764, "LICENSE_ID")
    t:eq(SC.SDK_VERSION_STR, "v04.04.05-ov-android", "SDK_VERSION_STR")
    -- 派生量：inner key 是 sha256(SIGN_KEY + SALT + SIGN_KEY)，get_sign 只取前 16 字节
    t:eq(hx(SC.derive_inner_key()),
        "3596e80bf7e999577a7b7ef1e4e79dbb21781cdcfaac71ed9b696c4bdbcce4e7",
        "derive_inner_key")
    -- sign_key = md5(SIGN_KEY[1:16])，sign_iv = md5(SIGN_KEY[17:32])
    t:eq(hx(SC.md5(SC.SIGN_KEY:sub(1, 16))), "d31e3718288a1027baab59f146a09a9c",
        "CBC 的 key 是 md5(SIGN_KEY 前 16 字节)")
    t:eq(hx(SC.md5(SC.SIGN_KEY:sub(17, 32))), "ea180a0336ed352fcd24e4d50018ae54",
        "CBC 的 iv 是 md5(SIGN_KEY 后 16 字节)")
    t:eq(hx(SC.query_hash("")), hx(SC.sha256(string.rep("\0", 16)):sub(1, 6)),
        "空 query 的哈希当 16 个 0 字节处理")
    t:eq(#SC.query_hash("aid=1"), 6, "query_hash 只取 sha256 前 6 字节")
    t:eq(#SC.body_hash("aabb"), 6, "body_hash 只取 sha256 前 6 字节")
    t:eq(#SC.body_hash(nil), 6, "body_hash(nil) 也要给出 6 字节")
end)

-- ── 随机源 ────────────────────────────────────────────────────────────

T.test("随机量可注入；默认路径至少返回形状正确的随机字节", function(t)
    -- 默认路径（/dev/urandom，失败退回 math.random）只做形状检查：
    -- 值本身不可复现，任何"等于某个常量"的断言都是错的。
    local b = SC.random_bytes(4)
    t:eq(#b, 4, "random_bytes(4) 应给 4 字节")
    t:eq(#SC.random_bytes(1), 1, "random_bytes(1) 应给 1 字节")
    t:eq(#SC.random_bytes(33), 33, "random_bytes(33) 应给 33 字节")
    -- 连续两次必须不同。这条是防"生成器卡住"的弱护栏：它抓不到"没播种"
    -- （那要跨进程才看得出，见报告里的探针），但能抓到退回分支被写成常量。
    t:ok(SC.random_bytes(16) ~= SC.random_bytes(16), "连续两次随机字节不应相同")
    local v = SC.random_u31()
    t:eq(type(v), "number", "random_u31 返回数字")
    t:ok(v >= 0 and v < 2147483648, "random_u31 落在 [0, 2^31)，实际 " .. v)
    -- 注入路径必须与注入值一致（不碰随机源）
    t:eq(hx(SC.ladon(V.ladon.khronos, V.ladon.lc_id, V.ladon.aid, "\1\2\3\4")),
        hx(SC.ladon(V.ladon.khronos, V.ladon.lc_id, V.ladon.aid, "\1\2\3\4")),
        "同样的 rand4 必须给同样的结果")
    -- 不注入也能跑（真机默认路径），但结果不可复现，只查形状
    local out = SC.ladon(V.ladon.khronos, V.ladon.lc_id, V.ladon.aid)
    t:ok(#out > 0, "不注入 rand4 时也应能出结果")
    t:ok(SC.get_sign("q", nil, 1, 1, "d", "v") ~= nil, "get_sign 不注入 rand_val 也应出结果")
end)

T.test("hex_decode 对非法输入返回 nil 而不是抛异常", function(t)
    t:eq(SC.hex_decode("abc"), nil, "奇数长度")
    t:eq(SC.hex_decode("zz"), nil, "非 hex 字符")
    t:eq(SC.hex_decode(nil), nil, "nil")
    t:eq(SC.hex_decode(123), nil, "数字")
    t:eq(hx(SC.hex_decode("")), "", "空串 → 空串")
    t:eq(hx(SC.hex_decode("00ff")), "00ff", "正常往返")
    t:eq(#SC.hex_decode("000102030405060708090a0b0c0d0e0f"), 16, "16 字节往返")
end)

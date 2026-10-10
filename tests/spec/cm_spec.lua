-- fanqie.bignum / fanqie.cm 用例
--
-- 这两块是「拿到正文」的最后一道算法关：DH 握手（1536 位模幂）+ AES-256 解密。
-- 它们的错误同样是静默的——算出别的东西不会报错，只会在设备上表现为"解出乱码"。
--
-- 期望值来自 Python 参考实现（`full_mget_client.py` 用它成功解出过可读中文），
-- 常数取自 ch6vip/fqapp 的 `rust/src/upstream/cm.rs`。

local T = require("tap")
local K = require("koreader")

local bignum = require("fanqie.bignum")
local cm = require("fanqie.cm")

local function load_vectors()
    for _, p in ipairs({
        "tests/spec/vectors_cm.lua",
        "tests/spec/vectors_cm.lua",
    }) do
        local ok, res = pcall(dofile, p)
        if ok and type(res) == "table" then return res end
    end
    error("找不到 tests/spec/vectors_cm.lua（请从仓库根目录运行测试）")
end

local V = load_vectors()

local function unhex(s)
    return (s:gsub("%x%x", function(cc) return string.char(tonumber(cc, 16)) end))
end

T.test("bignum 基本正确性（模幂 / 字节序 往返）", function(t)
    -- 2^10 mod 1000 = 24
    t:eq(bignum.to_hex(bignum.powmod(bignum.from_int(2), bignum.from_int(10), bignum.from_int(1000))),
        "18", "2^10 mod 1000 = 0x18")
    -- 大端字节往返
    local n = bignum.from_bytes_be(unhex("00ff10abcdef"))
    t:eq(bignum.to_bytes_be(n), unhex("ff10abcdef"), "去掉前导零的大端往返")
    t:eq(bignum.to_bytes_be(bignum.from_int(0)), "", "0 → 空串（与 Rust num_bigint 一致）")
    -- to_hex / from_hex 往返
    t:eq(bignum.to_hex(bignum.from_hex("deadbeef00")), "deadbeef00", "hex 往返")
end)

T.test("bignum：1536 位模数下的 DH 公钥与向量一致", function(t)
    local pub_bytes = cm.public_key_bytes(unhex(V.priv_hex))
    t:eq(#V.pub_hex / 2, #pub_bytes, "公钥字节数")
    local got = (pub_bytes:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
    end))
    t:eq(got, V.pub_hex, "pub = 2^priv mod P")
end)

T.test("CM 握手生成的 key 与向量逐字节一致", function(t)
    local key_b64 = cm.handshake(unhex(V.priv_hex), unhex(V.iv_hex))
    t:eq(key_b64, V.key_b64, "base64(iv + AES-128-CBC(pkcs7(pub)))")
end)

T.test("CM 解密：共享密钥前 32 字节 + AES-256-CBC 能还原正文", function(t)
    local _, priv = cm.public_key_bytes(unhex(V.priv_hex))
    local plain = cm.decrypt(priv, V.server_key_b64, V.content_b64)
    t:eq(#plain, V.plain_len, "明文长度")
    local got = (plain:gsub(".", function(c)
        return string.format("%02x", string.byte(c))
    end))
    t:eq(got, V.plain_hex, "明文逐字节一致")
end)

T.test("CM 解密对畸形输入给出错误而不是静默返回垃圾", function(t)
    local _, priv = cm.public_key_bytes(unhex(V.priv_hex))
    t:throws(function() cm.decrypt(priv, "", V.content_b64) end, "空 server key 应报错")
    t:throws(function() cm.decrypt(priv, V.server_key_b64, "") end, "空 content 应报错")
    t:throws(function() cm.decrypt(priv, V.server_key_b64, "AAAA") end, "过短的 content 应报错")
end)

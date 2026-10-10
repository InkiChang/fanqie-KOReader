--[[ CM 客户端握手 + 正文解密 —— 纯 Lua / LuaJIT。

规格来源：ch6vip/fqapp 的 `rust/src/upstream/cm.rs`（GPL-3.0，**只当规格读**），
并在 Python 参考实现上验证过（`full_mget_client.py` 用它成功解出可读中文）。

流程：
  1. 取 32 字节随机私钥 priv，对 P-1 取模；
  2. pub = 2^priv mod P（P 是 RFC 3526 的 **1536 位** MODP 群，见 bignum.lua 里的说明）；
  3. 用固定握手密钥做 AES-128-CBC 加密 pub 的大端字节（PKCS7），拼上随机 16 字节 IV，base64
     → 这就是 POST `full/mget` 请求体里的 `key`；
  4. 服务端回它自己的公钥（响应里的 `key`，base64）；
  5. shared = server_key^priv mod P，取大端字节的**前 32 字节**当 AES-256 密钥；
  6. 正文 = base64 解出的 [iv(16)][密文] 用 AES-256-CBC 解密后去 PKCS7。
]]

local bignum = require("fanqie.bignum")
local SC = require("fanqie.sign_crypto")

local M = {}

M.PRIME_HEX = "ffffffffffffffffc90fdaa22168c234c4c6628b80dc1cd129024e088a67cc74"
    .. "020bbea63b139b22514a08798e3404ddef9519b3cd3a431b302b0a6df25f14374fe1356d6d51c245"
    .. "e485b576625e7ec6f44c42e9a637ed6b0bff5cb6f406b7edee386bfb5a899fa5ae9f24117c4b1fe6"
    .. "49286651ece45b3dc2007cb8a163bf0598da48361c55d39a69163fa8fd24cf5f83655d23dca3ad96"
    .. "1c62f356208552bb9ed529077096966d670c354e4abc9804f1746c08ca237327ffffffffffffffff"

M.HANDSHAKE_KEY_HEX = "ac25c67ddd8f38c1b37a2348828e222e"   -- base64 rCXGfd2POMGzeiNIgo4iLg==

local P = bignum.from_hex(M.PRIME_HEX)
local P_MINUS_1 = bignum.sub(P, bignum.from_int(1))
local TWO = bignum.from_int(2)

M.P = P
M.PRIME_BITS = 1536

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.base64_decode(s)
    local map = {}
    for i = 1, 64 do map[B64:sub(i, i)] = i - 1 end
    local out, acc, nbits = {}, 0, 0
    for i = 1, #s do
        local c = s:sub(i, i)
        if c == "=" then break end
        local v = map[c]
        if v then
            acc = acc * 64 + v
            nbits = nbits + 6
            while nbits >= 8 do
                nbits = nbits - 8
                out[#out + 1] = string.char(math.floor(acc / 2 ^ nbits) % 256)
            end
            acc = acc % 2 ^ nbits
        end
    end
    return table.concat(out)
end

local function pad16(s)
    local p = 16 - (#s % 16)
    return s .. string.rep(string.char(p), p)
end

local function unpad16(s)
    if #s == 0 then return s end
    local p = string.byte(s, #s)
    if p < 1 or p > 16 or p > #s then return s end
    return s:sub(1, #s - p)
end

M.pad16, M.unpad16 = pad16, unpad16

--- 由 32 字节随机私钥算出公钥（大端最小字节）。测试里直接对向量。
function M.public_key_bytes(priv_bytes)
    local priv = bignum.mod(bignum.from_bytes_be(priv_bytes), P_MINUS_1)
    return bignum.to_bytes_be(bignum.powmod(TWO, priv, P)), priv
end

--- 生成请求体里的 `key` 字段。返回 key_b64, priv（priv 解密时还要用）。
function M.handshake(priv_bytes, iv)
    local pub_bytes, priv = M.public_key_bytes(priv_bytes)
    local ct = SC.aes_cbc_encrypt(pad16(pub_bytes), SC.hex_decode(M.HANDSHAKE_KEY_HEX), iv)
    return SC.base64_encode(iv .. ct), priv
end

--- 用一次握手解一章正文。priv 是 handshake() 返回的那个。
function M.decrypt(priv, server_key_b64, content_b64)
    if not server_key_b64 or server_key_b64 == "" then error("缺 server key", 0) end
    if not content_b64 or content_b64 == "" then error("缺 content", 0) end
    local blob = M.base64_decode(content_b64)
    if #blob < 16 then error("content 太短", 0) end
    local iv, ct = blob:sub(1, 16), blob:sub(17)
    if #ct % 16 ~= 0 then error("content 不是 16 的整数倍", 0) end

    local server = bignum.from_bytes_be(M.base64_decode(server_key_b64))
    local shared = bignum.powmod(server, priv, P)
    local sb = bignum.to_bytes_be(shared)
    if #sb < 32 then error("共享密钥太短：" .. #sb, 0) end
    local aes_key = sb:sub(1, 32)

    return unpad16(SC.aes_cbc_decrypt(ct, aes_key, iv))
end

--- 便捷：随机生成一对私钥/IV（需要 sign_crypto.random_bytes）
function M.new()
    local rb = SC.random_bytes
    if not rb then error("sign_crypto 没有 random_bytes", 0) end
    local priv_bytes = rb(32)
    local iv = rb(16)
    local key_b64, priv = M.handshake(priv_bytes, iv)
    return { key_b64 = key_b64, priv = priv, priv_bytes = priv_bytes, iv = iv,
             priv_hex = SC.hex_encode(priv_bytes) }
end

--- 从 priv 的 hex 还原出模幂要用的私钥（供"把会话缓存到磁盘"的路径使用）
function M.priv_from_hex(h)
    return bignum.mod(bignum.from_bytes_be(SC.hex_decode(h)), P_MINUS_1)
end

return M

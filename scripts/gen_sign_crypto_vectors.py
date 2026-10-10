"""生成 sign_crypto_spec.lua 需要的固定向量，并**当场**用 lupa 交叉验证 Lua 实现。

为什么要有这个脚本：
    验收要求"向量硬编码进 Lua 测试"，也就是 Lua 侧不依赖 Python。但如果向量的
    生成过程本身不可复现，别人没法判断这些 hex 是不是编出来的。所以这里把
    生成与比对做成同一条命令：既打印 Lua spec 段的源码，也把 Lua 实现的结果
    与 Python 参考实现逐字节比对，任何一条不一致就直接非零退出。

用法：
    python scripts/gen_sign_crypto_vectors.py            # 打印 Lua 向量段 + 交叉验证
    python scripts/gen_sign_crypto_vectors.py --lua-only # 只打印 Lua 向量段

输入（唯一权威）：
    refs/fanqie_sign.py

注意：Python 参考实现的 `ladon()` 内部用 os.urandom 取 4 字节随机量，
      本脚本改用等价的本地实现 `ladon_fixed()`（rand4 可注入）来生成向量——
      除随机量来源外，代码逐行照抄。get_sign 本身已有 rand_val 参数。
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import importlib.util
import os
import pathlib
import sys

REF = pathlib.Path(os.environ.get("FANQIE_SIGN_REF", "refs/fanqie_sign.py"))
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
_LUA_PATHS = [
    REPO_ROOT / "tests" / "support" / "?.lua",
    REPO_ROOT / "tests" / "?.lua",
    REPO_ROOT / "src" / "fanqie.koplugin" / "?.lua",
]

spec = importlib.util.spec_from_file_location("fanqie_sign", REF)
if spec is None or spec.loader is None:  # pragma: no cover
    raise SystemExit(f"找不到参考实现：{REF}")
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)   # 导入时自带 FIPS-197 / NIST 自检


# ── 与参考实现等价的固定随机量版本 ────────────────────────────────────────

def ladon_fixed(khronos: int, lc_id: int, aid, rand4: bytes) -> str:
    """照抄 ref.ladon()，只把 os.urandom(4) 换成注入的 rand4。"""
    data = f"{khronos}-{lc_id}-{aid}".encode()
    rnd = rand4
    md5hex = hashlib.md5(rnd + str(aid).encode()).hexdigest().encode()
    ht = bytearray(272 + 16)
    ht[0:32] = md5hex[:32]
    temp = [int.from_bytes(ht[i * 8:(i + 1) * 8], "little") for i in range(4)]
    b0, b8 = temp[0], temp[1]
    temp.pop(0)
    temp.pop(0)
    for i in range(0x22):
        x9 = b0
        x8 = ref._ror64(b8, 8)
        x8 = (x8 + x9) & ref._M
        x8 ^= i
        temp.append(x8)
        x8 ^= ref._ror64(x9, 61)
        ht[(i + 1) * 8:(i + 2) * 8] = x8.to_bytes(8, "little")
        b0, b8 = x8, temp[0]
        temp.pop(0)
    new_size = len(data) + (16 - len(data) % 16) if len(data) % 16 else len(data)
    padded = ref._pkcs7(data)
    out = bytearray(new_size)
    for i in range(new_size // 16):
        out[i * 16:i * 16 + 16] = ref._ladon_block(bytes(ht), padded[i * 16:(i + 1) * 16])[:16]
    return base64.b64encode(rnd + bytes(out)).decode()


def ladon_ht(rand4: bytes, aid) -> bytes:
    return bytes(_ladon_ht_bytes(rand4, aid))


def _ladon_ht_bytes(rand4: bytes, aid):
    md5hex = hashlib.md5(rand4 + str(aid).encode()).hexdigest().encode()
    ht = bytearray(272 + 16)
    ht[0:32] = md5hex[:32]
    temp = [int.from_bytes(ht[i * 8:(i + 1) * 8], "little") for i in range(4)]
    b0, b8 = temp[0], temp[1]
    temp.pop(0)
    temp.pop(0)
    for i in range(0x22):
        x9 = b0
        x8 = ref._ror64(b8, 8)
        x8 = (x8 + x9) & ref._M
        x8 ^= i
        temp.append(x8)
        x8 ^= ref._ror64(x9, 61)
        ht[(i + 1) * 8:(i + 2) * 8] = x8.to_bytes(8, "little")
        b0, b8 = x8, temp[0]
        temp.pop(0)
    return ht


# ── 案例定义 ─────────────────────────────────────────────────────────────

AES_KEY = bytes(range(16))
AES_KEY_HEX = AES_KEY.hex()
ECB_BLOCKS = [
    bytes.fromhex("00112233445566778899aabbccddeeff"),
    bytes.fromhex("6bc1bee22e409f96e93d7e117393172a"),
    bytes.fromhex("f69f2445df4f9b17ad2b417be66c3710"),
]
ECB_PT = b"".join(ECB_BLOCKS)
CBC_KEY = bytes.fromhex("2b7e151628aed2a6abf7158809cf4f3c")
CBC_IV = bytes.fromhex("000102030405060708090a0b0c0d0e0f")
CBC_PT = bytes.fromhex(
    "6bc1bee22e409f96e93d7e117393172a"
    "ae2d8a571e03ac9c9eb76fac45af8e51"
    "30c81c46a35ce411e5fbc1191a0a52ef"
)

LADON_RAND = bytes.fromhex("9ae1b0ac")
LADON_KHRONOS = 1791600000
LADON_LC = 0
LADON_AID = 1967
# "1791600000-0-999" 正好 16 字节：命中 pkcs7 的"已对齐仍补整块"分支。
# （10 + 1 + 1 + 1 + 3 = 16）
LADON_LONG_DATA = "1791600000-0-999"

# get_sign 的参数组
SIGN_CASES = [
    ("query=aid=1967&book_id=1", None, 1791600000, 1967, "1234567890123456", "7.0.1.32", 57005),
    ("", "aabbccddeeff00112233445566778899", 1700000000, 0, "", "", 0),
    ("wechat", "00", 4294967295, 1611921764, "ABCDEF0123456789", "v04.04.05-ov-android",
     2147483647),
]


def to_lua_hex(b: bytes) -> str:
    return b.hex()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--lua-only", action="store_true", help="只打印 Lua 向量段")
    ap.add_argument("--no-verify", action="store_true", help="跳过 lupa 交叉验证")
    ap.add_argument("--update-spec", action="store_true",
                    help="把向量段原地写回 tests/spec/sign_crypto_spec.lua 的标记区")
    args = ap.parse_args()

    # ---- 1. 计算全部向量 ----
    inner_key = ref._derive_inner_key()[:16]
    aes_key = hashlib.md5(ref.SIGN_KEY[:16]).digest()
    aes_iv = hashlib.md5(ref.SIGN_KEY[16:]).digest()

    vectors = {
        "sha256": [
            ("", hashlib.sha256(b"").hexdigest()),
            ("abc", hashlib.sha256(b"abc").hexdigest()),
            ("番茄小说", hashlib.sha256("番茄小说".encode()).hexdigest()),
            ("a" * 64, hashlib.sha256(b"a" * 64).hexdigest()),
            ("a" * 55, hashlib.sha256(b"a" * 55).hexdigest()),
            ("a" * 56, hashlib.sha256(b"a" * 56).hexdigest()),
        ],
        "md5": [
            ("", hashlib.md5(b"").hexdigest()),
            ("abc", hashlib.md5(b"abc").hexdigest()),
            ("番茄小说", hashlib.md5("番茄小说".encode()).hexdigest()),
            ("The quick brown fox jumps over the lazy dog",
             hashlib.md5(b"The quick brown fox jumps over the lazy dog").hexdigest()),
        ],
        "b64": [
            (b"".hex(), base64.b64encode(b"").decode()),
            (b"f".hex(), base64.b64encode(b"f").decode()),
            (b"fo".hex(), base64.b64encode(b"fo").decode()),
            (b"foo".hex(), base64.b64encode(b"foo").decode()),
            (b"foob".hex(), base64.b64encode(b"foob").decode()),
            (b"fooba".hex(), base64.b64encode(b"fooba").decode()),
            (b"foobar".hex(), base64.b64encode(b"foobar").decode()),
            ("番茄".encode().hex(), base64.b64encode("番茄".encode()).decode()),
            (bytes(range(256)).hex(), base64.b64encode(bytes(range(256))).decode()),
        ],
    }

    ecb = ref.aes_ecb_encrypt(ECB_PT, AES_KEY)
    cbc = ref.aes_cbc_encrypt(CBC_PT, CBC_KEY, CBC_IV)
    pad_cases = [b"", b"1", b"12345678", b"0123456789abcde", b"0123456789abcdef",
                 b"0123456789abcdef0"]
    pad_vectors = [(p.hex(), ref._pkcs7(p, 16).hex()) for p in pad_cases]

    ror_cases = [
        (0x0000000000000001, 1), (0x0000000000000001, 8), (0x0000000000000001, 61),
        (0x8000000000000000, 1), (0x0123456789abcdef, 8), (0x0123456789abcdef, 40),
        (0xffffffffffffffff, 13), (0x0f0f0f0f0f0f0f0f, 32), (0xdeadbeefcafebabe, 0),
        (0x00000000ffffffff, 63),
    ]
    ror_vectors = [(f"{v:016x}", c, f"{ref._ror64(v, c):016x}") for v, c in ror_cases]

    ht_hex = ladon_ht(LADON_RAND, LADON_AID).hex()
    ladon_out = ladon_fixed(LADON_KHRONOS, LADON_LC, LADON_AID, LADON_RAND)
    ladon_out_long = ladon_fixed(LADON_KHRONOS, LADON_LC, LADON_LONG_DATA, LADON_RAND)

    sign_vectors = []
    for q, d, ts, aid, dev, ver, rnd in SIGN_CASES:
        sign_vectors.append({
            "q": q, "d": d, "ts": ts, "aid": aid, "dev": dev, "ver": ver, "rnd": rnd,
            "out": ref.get_sign(q, d, ts, aid, dev, ver, rnd),
        })

    # protobuf 怪癖
    varint_cases = [0, 1, 0x7f, 0x80, 0x81, 0xff, 0x100, 0x3fff, 0x4000,
                    3348294860, 0xffffffff, 0x123456789,
                    0x40401252, 269489280]  # 0x20200929<<1, 134744640
    varint_vectors = []
    for v in varint_cases:
        buf = bytearray()
        ref._write_varint(buf, v)
        varint_vectors.append((v, bytes(buf).hex()))

    dict_cases = [
        ("单字段 varint", [(1, "varint", 2)]),
        ("嵌套 dict", [(15, "dict", [(1, "varint", 1), (2, "varint", 1),
                                     (3, "varint", 1), (7, "varint", 3348294860)])]),
        ("utf8 + bytes", [(4, "utf8", "1967"), (10, "bytes", bytes(8)),
                          (20, "utf8", "none")]),
        ("空 utf8", [(16, "utf8", "")]),
        ("大 varint", [(12, "varint", 3583200000), (25, "varint", 2)]),
        ("varint 怪癖 128", [(1, "varint", 128)]),
        ("get_sign 字段 15", [(15, "dict", [(1, "varint", 1), (2, "varint", 1),
                                            (3, "varint", 1), (7, "varint", 3348294860)])]),
    ]
    dict_vectors = [(name, fields, ref.encode_dict(fields).hex())
                    for name, fields in dict_cases]

    # ---- 2. 交叉验证（lupa 里真跑一遍 Lua 实现）----
    if not args.no_verify:
        if not verify(vectors, ecb, cbc, pad_vectors, ror_vectors, ht_hex, ladon_out,
                      ladon_out_long, sign_vectors, varint_vectors, dict_vectors,
                      inner_key, aes_key, aes_iv):
            return 1

    if args.update_spec:
        write_spec(vectors, ecb, cbc, pad_vectors, ror_vectors, ht_hex, ladon_out,
                   ladon_out_long, sign_vectors, varint_vectors, dict_vectors)
    else:
        emit_lua(vectors, ecb, cbc, pad_vectors, ror_vectors, ht_hex, ladon_out,
                 ladon_out_long, sign_vectors, varint_vectors, dict_vectors)
    return 0


BEGIN_MARK = "-- >>> BEGIN GENERATED VECTORS（由 scripts/gen_sign_crypto_vectors.py 生成，勿手改）"
END_MARK = "-- <<< END GENERATED VECTORS"
SPEC_PATH = REPO_ROOT / "tests" / "spec" / "sign_crypto_spec.lua"


def write_spec(*a) -> None:
    """把生成的向量段原地替换进 spec 的标记区。"""
    import io as _io
    buf = _io.StringIO()
    _stdout = sys.stdout
    sys.stdout = buf
    try:
        emit_lua(*a)
    finally:
        sys.stdout = _stdout
    block = buf.getvalue().rstrip("\n")
    # emit_lua 的头部注释是给"贴进文件"用的，标记区里去掉，只留 local V = ...
    lines = block.split("\n")
    start = next(i for i, ln in enumerate(lines) if ln.startswith("local V = {}"))
    body_lines = [ln for ln in lines[start:] if ln.strip() != "return V"]
    body = "\n".join(body_lines).rstrip("\n")

    text = SPEC_PATH.read_text(encoding="utf-8")
    i = text.index(BEGIN_MARK) + len(BEGIN_MARK)
    j = text.index(END_MARK)
    SPEC_PATH.write_text(text[:i] + "\n" + body + "\n" + text[j:], encoding="utf-8")
    print(f"# 已更新 {SPEC_PATH}", file=sys.stderr)


def _lua_escape(s: str) -> str:
    out = []
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        else:
            out.append(ch)
    return "".join(out)


def emit_lua(vectors, ecb, cbc, pad_vectors, ror_vectors, ht_hex, ladon_out,
             ladon_out_long, sign_vectors, varint_vectors, dict_vectors) -> None:
    L = []
    w = L.append
    w("-- ===========================================================================")
    w("-- 由 scripts/gen_sign_crypto_vectors.py 生成，勿手改。")
    w("-- 期望值全部来自 Python 参考实现")
    w("--   refs/fanqie_sign.py")
    w("-- 重新生成：")
    w("--   python scripts/gen_sign_crypto_vectors.py")
    w("-- ===========================================================================")
    w("")
    w("local V = {}")
    w("")
    w("V.sha256 = {")
    for msg, digest in vectors["sha256"]:
        w('    { %s, "%s" },' % (_lua_utf8(msg), digest))
    w("}")
    w("")
    w("V.md5 = {")
    for msg, digest in vectors["md5"]:
        w('    { %s, "%s" },' % (_lua_utf8(msg), digest))
    w("}")
    w("")
    w("V.b64 = {")
    for raw_hex, enc in vectors["b64"]:
        w('    { "%s", "%s" },' % (raw_hex, _lua_escape(enc)))
    w("}")
    w("")
    w("V.aes_ecb = {")
    w('    key = "%s",' % AES_KEY_HEX)
    w('    plain = "%s",' % ECB_PT.hex())
    w('    cipher = "%s",' % ecb.hex())
    w("}")
    w("")
    w("V.aes_cbc = {")
    w('    key = "%s",' % CBC_KEY.hex())
    w('    iv = "%s",' % CBC_IV.hex())
    w('    plain = "%s",' % CBC_PT.hex())
    w('    cipher = "%s",' % cbc.hex())
    w("}")
    w("")
    w("V.pkcs7 = {")
    for src, dst in pad_vectors:
        w('    { "%s", "%s" },' % (src, dst))
    w("}")
    w("")
    w("V.ror64 = {")
    for v, c, out in ror_vectors:
        w('    { "%s", %d, "%s" },' % (v, c, out))
    w("}")
    w("")
    w('V.ladon = {')
    w('    khronos = %d,' % LADON_KHRONOS)
    w('    lc_id = %d,' % LADON_LC)
    w('    aid = %d,' % LADON_AID)
    w('    rand4 = "%s",' % LADON_RAND.hex())
    w('    ht = "%s",' % ht_hex)
    w('    out = "%s",' % ladon_out)
    w('    long_data = "%s",' % LADON_LONG_DATA)
    w('    long_out = "%s",' % ladon_out_long)
    w("}")
    w("")
    w("V.sign = {")
    for c in sign_vectors:
        w('    { q = %s, data = %s, ts = %d, aid = %d, dev = %s, ver = %s,' %
          (_lua_utf8(c["q"]), _lua_opt(c["d"]), c["ts"], c["aid"],
           _lua_utf8(c["dev"]), _lua_utf8(c["ver"])))
        w('      rand = %d, out = "%s" },' % (c["rnd"], c["out"]))
    w("}")
    w("")
    w("V.varint = {")
    for v, out in varint_vectors:
        w('    { %d, "%s" },' % (v, out))
    w("}")
    w("")
    w("V.dict = {")
    for name, fields, out in dict_vectors:
        w("    -- %s" % name)
        w("    { fields = %s," % _ser_fields(fields))
        w('      out = "%s" },' % out)
    w("}")
    w("")
    w("return V")
    sys.stdout.write("\n".join(L) + "\n")


def _lua_utf8(s: str) -> str:
    """把 Python 字符串写成 Lua 的字节串字面量（UTF-8 字节原样保留）。"""
    return '"%s"' % _lua_escape(s)


def _lua_opt(s):
    return "nil" if s is None else _lua_utf8(s)


def _lua_bytes(b: bytes) -> str:
    """字节串 → Lua 字符串字面量。

    Lua 5.1 **没有** `\\xNN` 转义，只能用十进制 `\\ddd`；而且必须是三位，
    否则 `\\0` 后面跟数字会被当成同一个转义读掉。
    """
    out = []
    for ch in b:
        if ch == 0x5C:
            out.append("\\\\")
        elif ch == 0x22:
            out.append('\\"')
        elif 0x20 <= ch < 0x7F:
            out.append(chr(ch))
        else:
            out.append("\\%03d" % ch)
    return '"' + "".join(out) + '"'


def _ser_fields(fields):
    """把 (idx, kind, val) 三元组列表写成 Lua 表字面量。"""
    parts = []
    for idx, kind, val in fields:
        if kind == "varint":
            v = str(val)
        elif kind == "bytes":
            v = _lua_bytes(bytes(val) if not isinstance(val, str) else val.encode("latin-1"))
        elif kind == "utf8":
            v = _lua_utf8(val)
        elif kind == "dict":
            v = _ser_fields(val)
        else:  # pragma: no cover
            raise AssertionError(kind)
        parts.append('{ %d, "%s", %s }' % (idx, kind, v))
    return "{ " + ", ".join(parts) + " }"


def _lua_runtime():
    import os as _os
    for extra in (REPO_ROOT / ".pylibs", REPO_ROOT.parent / ".cache" / "pylibs"):
        if extra.is_dir():
            sys.path.insert(0, str(extra))
    from lupa.luajit21 import LuaRuntime  # type: ignore

    _os.environ["FANQIE_REPO_ROOT"] = str(REPO_ROOT)
    lua = LuaRuntime(unpack_returned_tuples=True, encoding="utf-8")
    paths = ";".join(str(p).replace("\\", "/") for p in _LUA_PATHS)
    lua.execute('package.path = "%s;" .. package.path' % paths)
    lua.execute('require("koreader")')       # 装好基座（bit / 模块路径）
    return lua


def verify(vectors, ecb, cbc, pad_vectors, ror_vectors, ht_hex, ladon_out, ladon_out_long,
           sign_vectors, varint_vectors, dict_vectors, inner_key, aes_key, aes_iv) -> bool:
    lua = _lua_runtime()
    g = lua.globals()
    g.SC = lua.eval('require("fanqie.sign_crypto")')
    fails = []

    def check(name, got, want):
        if got != want:
            fails.append(f"{name}\n    期望 {want}\n    实际 {got}")

    lua.execute("""
        local SC = require("fanqie.sign_crypto")
        local function hx(b) return SC.hex_encode(b) end
        function PY_SHA256(s) return hx(SC.sha256(s)) end
        function PY_MD5(s) return hx(SC.md5(s)) end
        function PY_B64(s) return SC.base64_encode(s) end
        function PY_PAD(s) return hx(SC.pkcs7_pad(s, 16)) end
        function PY_ECB(d, k) return hx(SC.aes128_ecb_encrypt(d, k)) end
        function PY_CBC(d, k, iv) return hx(SC.aes128_cbc_encrypt(d, k, iv)) end
        function PY_ROR(v, c)
            local hi = tonumber(v:sub(1, 8), 16)
            local lo = tonumber(v:sub(9, 16), 16)
            local r = SC.ror64({ hi = hi, lo = lo }, c)
            return string.format("%08x%08x", r.hi, r.lo)
        end
        function PY_HT(rand4, aid) return SC.hex_encode(SC.ladon_round_table(rand4, aid)) end
        function PY_LADON(k, l, a, r) return SC.ladon(k, l, a, r) end
        function PY_SIGN(...) return SC.get_sign(...) end
        function PY_VARINT(v)
            local out = {}
            SC.write_varint(out, v)
            return SC.hex_encode(table.concat(out))
        end
        function PY_DERIVE() return SC.hex_encode(SC.derive_inner_key()) end
        function PY_ENCPB(d, l) return SC.hex_encode(SC.enc_pb(d, l)) end
        function PY_QHASH(q) return SC.hex_encode(SC.query_hash(q)) end
        function PY_BHASH(d) return SC.hex_encode(SC.body_hash(d)) end
        function PY_DICT(literal)
            local fields = loadstring("return " .. literal)()
            return SC.hex_encode(SC.encode_dict(fields))
        end
    """)

    def hxd(s):
        return None if s is None else bytes.fromhex(s)

    for msg, digest in vectors["sha256"]:
        check(f"sha256({msg!r})", g.PY_SHA256(msg), digest)
    for msg, digest in vectors["md5"]:
        check(f"md5({msg!r})", g.PY_MD5(msg), digest)
    for raw_hex, enc in vectors["b64"]:
        check(f"base64({raw_hex[:32]})", g.PY_B64(hxd(raw_hex)), enc)
    check("aes_ecb", g.PY_ECB(ECB_PT, AES_KEY), ecb.hex())
    check("aes_cbc", g.PY_CBC(CBC_PT, CBC_KEY, CBC_IV), cbc.hex())
    for src, dst in pad_vectors:
        check(f"pkcs7({src})", g.PY_PAD(hxd(src)), dst)
    for v, c, out in ror_vectors:
        check(f"ror64({v},{c})", g.PY_ROR(v, c), out)
    check("ladon ht", g.PY_HT(LADON_RAND, LADON_AID), ht_hex)
    check("ladon", g.PY_LADON(LADON_KHRONOS, LADON_LC, LADON_AID, LADON_RAND), ladon_out)
    check("ladon long", g.PY_LADON(LADON_KHRONOS, LADON_LC, LADON_LONG_DATA, LADON_RAND),
          ladon_out_long)
    for c in sign_vectors:
        got = g.PY_SIGN(c["q"], c["d"], c["ts"], c["aid"], c["dev"], c["ver"], c["rnd"])
        check(f"get_sign({c['q']!r},{c['d']!r})", got, c["out"])
    for v, out in varint_vectors:
        check(f"varint({v})", g.PY_VARINT(v), out)
    for name, fields, out in dict_vectors:
        check(f"encode_dict({name})", g.PY_DICT(_ser_fields(fields)), out)
    check("derive_inner_key", g.PY_DERIVE(), ref._derive_inner_key().hex())
    check("query_hash('')", g.PY_QHASH(""), ref._query_hash("").hex())
    check("query_hash(aid)", g.PY_QHASH("aid=1"), ref._query_hash("aid=1").hex())
    check("body_hash(nil)", g.PY_BHASH(None), ref._body_hash(None).hex())
    check("body_hash(aabb)", g.PY_BHASH("aabb"), ref._body_hash("aabb").hex())
    check("body_hash(非 hex)", g.PY_BHASH("zz"), ref._body_hash("zz").hex())

    if fails:
        print("交叉验证失败：", file=sys.stderr)
        for f in fails:
            print("  - " + f, file=sys.stderr)
        return False
    print(f"# 交叉验证通过：{len(vectors['sha256'])} sha256 / {len(vectors['md5'])} md5 / "
          f"{len(vectors['b64'])} base64 / 1 ecb / 1 cbc / {len(pad_vectors)} pkcs7 / "
          f"{len(ror_vectors)} ror64 / 2 ladon / {len(sign_vectors)} get_sign / "
          f"{len(varint_vectors)} varint", file=sys.stderr)
    return True


if __name__ == "__main__":
    try:
        sys.stdout.reconfigure(encoding="utf-8", errors="replace")
        sys.stderr.reconfigure(encoding="utf-8", errors="replace")
    except Exception:  # noqa: BLE001
        pass
    sys.exit(main())

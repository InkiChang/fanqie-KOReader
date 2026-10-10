"""生成一本"肉眼可验收"的示例 EPUB。

用途：`fanqie/epub.lua` 是纯字节组装，不需要 KOReader 就能产出真书。这个脚本用
测试基座（lupa + 插件源码）生成一本十几章的样本，产出的 .epub 可以直接双击，
用 Calibre / Thorium / Apple Books / 多看 等任何阅读器打开翻阅。

它验证的是 EPUB 生成器本身，**不覆盖**插件的下载与打开流程（那部分还没接线）。

用法：
    python tools/make_sample_epub.py                 # 默认写到 ./sample-book.epub
    python tools/make_sample_epub.py <输出路径>
    python tools/make_sample_epub.py --probe         # 顺带演示守卫生效（推荐看一眼）

退出码 0 表示生成成功且结构自检通过。

实现注意：测试基座的边界纪律是"跨 lupa 边界只搬路径、不搬数据"。这里更严格——
Lua 侧只用 `return` 回一行**纯 ASCII 的键值摘要**，中文报告与落盘全部由 Python 完成。
（曾经用 io.write 直接吐中文，虽然多数情况能过，但一旦某段里混进二进制就会在
边界上抛 UnicodeDecodeError，排查成本远高于这里多写几行。）
"""

from __future__ import annotations

import argparse
import pathlib
import shutil
import sys

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
sys.path.insert(0, str(REPO_ROOT / "tests"))

import run_tests as R  # noqa: E402

# 注意：这里的正文是占位文本，不是任何真实小说的内容。
CHAPTER_TITLES = [
    "第一章 起点",
    "第二章 意外的访客",
    "第三章 旧地图",
    "第四章 山谷里的信号",
    "第五章 夜谈",
    "第六章 分歧",
    "第七章 逆流而上",
    "第八章 一场雨",
    "第九章 沉默的证词",
    "第十章 交汇",
    "第十一章 归途",
    "第十二章 尾声",
]

PARAGRAPHS = [
    "这是一段占位正文，用来验证 EPUB 的排版、分章与目录是否正确。"
    "它刻意包含常见的中文标点：顿号、破折号——以及省略号……",
    "第二段包含需要 XML 转义、但由生成器负责处理的字符：a & b、1 < 2、"
    "以及引号「双引号」与「单引号」。这些一旦没转义，整本书就会打不开。",
    "第三段用来拉长页面，检查长段落换行与行距是否符合预期。"
    "重复若干次以便观察滚动表现：" + "地" * 40 + "。",
    "第四段是一段很短的文字。",
]


def build_lua(staging: pathlib.Path, with_probe: bool) -> str:
    """生成 Lua chunk。

    只允许 `return` 一行 ASCII 摘要——所有会变长的、可能非 UTF-8 的东西
    （尤其是 build 返回的 EPUB 字节）都绝不出现在返回值里。
    """
    chapters = []
    for i, title in enumerate(CHAPTER_TITLES):
        parts = []
        for j in range(3 + (i % 2)):
            p = PARAGRAPHS[j % len(PARAGRAPHS)]
            parts.append(p)
        # 用 text 字段（纯文本，逐段自动转义），而不是 html：
        # 正文里本来就带裸 & 与裸 <，走 text 才是插件下载正文的真实路径，
        # 也正是这里要验的——读出来必须是字面字符，而不是打不开的书。
        # 段落分隔用空行：text_to_xhtml 把"空行"当段落边界，单个换行只是软换行
        # （会被并进同一段、用空格连起来）。用 "\n" 拼会得到一整段。
        body = "\n\n".join(parts)
        chapters.append(f'{{ title = [[{title}]], text = [[{body}]] }}')

    probe = ""
    if with_probe:
        probe = r"""
    -- 演示：这两个片段正是会产出"打不开的书"的输入，现在被拦在构建期。
    -- 只回报"拦住了没有"与"错误类型"，不回报错误正文（正文里会带输入片段，
    -- 而输入片段本身可能含任意字节——那正是不能跨边界的东西）。
    local unsafe_amp = Epub.find_unsafe_xml("<p>math a & b</p>")
    local unsafe_lt = Epub.find_unsafe_xml("<p>1 < 2</p>")
    local unsafe_ok = Epub.find_unsafe_xml("<p>a &amp; b &lt; c</p>")
    local rejected, reject_err = Epub.build({
        title = "rejected",
        chapters = { { title = "c1", html = "<p>a & b</p>" } },
    })
    r.unsafe_amp = unsafe_amp and "flagged" or "missed"
    r.unsafe_lt = unsafe_lt and "flagged" or "missed"
    r.unsafe_ok = unsafe_ok and "flagged" or "clean"
    r.rejected_bytes = (rejected == nil) and "nil" or "bytes!"
    r.rejected_err_type = type(reject_err)
    -- 错误正文单独走文本通道（它是纯文本，不含二进制）
    r.rejected_err = tostring(reject_err or "")
"""

    return f"""
package.path = table.concat({{
    [[{REPO_ROOT}\\tests\\support\\?.lua]],
    [[{REPO_ROOT}\\tests\\?.lua]],
    package.path,
}}, ";")
require("koreader")
local Epub = require("fanqie.epub")

local r = {{}}

local chapters = {{
{",".join(chapters)}
}}

local opts = {{
    title = "示例书：番茄小说插件 EPUB 生成器验收样本",
    author = "fanqie-KOReader 测试基座",
    -- book_id 必须是字符串：19 位超出 Lua 数字精度（传数字会被拒绝）
    book_id = "7544410373084957758",
    language = "zh",
    chapters = chapters,
    modified = "2026-01-01T00:00:00Z",
}}
{probe}
r.chapter_count = #chapters

local bytes, err, identifier = Epub.build(opts)
if not bytes then
    r.build = "failed"
    r.build_err = tostring(err)
    return string.format("build=%s\\nbuild_err=%s\\n", r.build,
        (r.build_err:gsub("\\n", " ")))
end

r.build = "ok"
r.byte_count = #bytes
r.identifier = tostring(identifier or "")

local ok, problems = Epub.verify(bytes)
r.verify = ok and "ok" or "failed"
r.problem_count = #(problems or {{}})
r.problems = table.concat(problems or {{}}, " | ")

local written, werr, n = Epub.write([[{staging}]], opts)
r.write = written and "ok" or "failed"
r.write_err = tostring(werr or "")
r.write_bytes = tostring(n or "")

if r.write ~= "ok" then
    return string.format("build=%s\\nwrite=failed\\nwrite_err=%s\\n",
        r.build, (r.write_err:gsub("\\n", " ")))
end

-- 读回来确认落盘字节与内存字节一致（"写了但写全了吗"）
local f = io.open([[{staging}]], "rb")
local back = f and f:read("*a") or ""
if f then f:close() end
r.roundtrip = (#back == #bytes) and "same" or "differs"

local lines = {{}}
for _, k in ipairs({{ "build", "chapter_count", "byte_count", "identifier", "verify",
        "problem_count", "problems", "write", "write_err", "write_bytes", "roundtrip",
        "unsafe_amp", "unsafe_lt", "unsafe_ok", "rejected_bytes", "rejected_err_type",
        "rejected_err" }}) do
    lines[#lines + 1] = k .. "=" .. tostring(r[k] == nil and "" or r[k]):gsub("\\n", " ")
end
return ((table.concat(lines, "\\n") .. "\\n"):gsub(".", function(c)
    return string.format("%02x", c:byte())
end))
"""


def main() -> int:
    parser = argparse.ArgumentParser(description="生成示例 EPUB 供肉眼验收")
    parser.add_argument("output", nargs="?", default=str(REPO_ROOT / "sample-book.epub"))
    parser.add_argument("--probe", action="store_true", help="顺带演示 XHTML 守卫")
    args = parser.parse_args()

    output = pathlib.Path(args.output).resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    # 遵守测试基座的边界纪律：跨 lupa 边界只搬路径、不搬数据。
    # Lua 侧永远写 ASCII 暂存路径，最后一步由 Python 把文件搬到可能含中文的
    # 目标路径——这样既绕开 Windows 的 ANSI 代码页，也绕开 UTF-8 解码边界。
    staging_dir = REPO_ROOT / "tests" / ".tmp" / "demo"
    staging_dir.mkdir(parents=True, exist_ok=True)
    staging = staging_dir / "sample-book.epub"
    if staging.exists():
        staging.unlink()

    LuaRuntime, reason = R.load_lupa_runtime()
    if LuaRuntime is None:
        print(f"lupa 不可用：{reason}", file=sys.stderr)
        print("先跑 python scripts/bootstrap_pylibs.py", file=sys.stderr)
        return 2

    lua = LuaRuntime(unpack_returned_tuples=True, encoding="utf-8")
    # 基座要求 __PYIO_WRITE 存在（io.write 的出口）。我们不用它，但必须挂上，
    # 否则被测代码里任何一次 io.write 都会炸。
    lua.globals().__PYIO_WRITE = lambda _s: None
    R.install_pyfs(lua)
    R.install_pyfile(lua)
    g = lua.globals()
    g.__FANQIE_REPO_ROOT = str(REPO_ROOT)
    g.__FANQIE_TEST_DATA_DIR = str(REPO_ROOT / "tests" / ".tmp" / "demo")
    g.__FANQIE_EMBEDDED = True

    summary = lua.execute(build_lua(staging, args.probe)) or ""
    raw = bytes.fromhex("".join(summary.split()))
    try:
        summary = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        print(f"摘要含非 UTF-8 字节：{exc}", file=sys.stderr)
        p = exc.start
        print(f"上下文字节：{raw[max(0, p - 60):p + 60]!r}", file=sys.stderr)
        print("已解出的部分：", raw[:p].decode("utf-8", "replace"), file=sys.stderr)
        return 1
    fields = {}
    for line in summary.splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            fields[k.strip()] = v.strip()

    if fields.get("build") != "ok":
        print("构建失败：" + fields.get("build_err", "未知原因"), file=sys.stderr)
        return 1
    if fields.get("verify") != "ok":
        print(f"自检未通过（{fields.get('problem_count')} 个问题）："
              f"{fields.get('problems')}", file=sys.stderr)
        return 1
    if fields.get("write") != "ok":
        print(f"落盘失败：{fields.get('write_err')}", file=sys.stderr)
        return 1
    if not staging.exists():
        print("Lua 报告写成功，但暂存文件不存在", file=sys.stderr)
        return 1

    try:
        shutil.copyfile(staging, output)
    except OSError as exc:
        print(f"搬到最后位置失败：{exc}", file=sys.stderr)
        return 1

    size = output.stat().st_size
    print(f"章节数     = {fields.get('chapter_count')}")
    print(f"字节数     = {fields.get('byte_count')}（Lua 内存字节）")
    print(f"落盘字节   = {size}（实测文件大小）")
    print(f"回读一致   = {fields.get('roundtrip')}")
    print(f"identifier = {fields.get('identifier')}")
    print(f"结构自检   = {fields.get('verify')}（问题 {fields.get('problem_count')} 个）")
    print(f"输出路径   = {output}")

    if args.probe:
        print("")
        print("守卫 find_unsafe_xml：")
        print(f"  裸 &      -> {fields.get('unsafe_amp')}")
        print(f"  裸 <      -> {fields.get('unsafe_lt')}")
        print(f"  合法实体  -> {fields.get('unsafe_ok')}")
        print(f"  坏输入 build -> {fields.get('rejected_bytes')}"
              f"（错误类型 {fields.get('rejected_err_type')}）")
        err_text = fields.get("rejected_err", "")
        if err_text:
            print(f"  错误正文  -> {err_text}")

    if size != int(fields.get("byte_count", -1)):
        print("警告：文件大小与内存字节数不一致", file=sys.stderr)
        return 1

    print("")
    print("验收方式：直接双击打开，或用任意 EPUB 阅读器导入；")
    print("          也可以把扩展名改成 .zip 解开看目录结构。")
    print("期望：能翻到 12 章、目录里有 12 条、中文标点正常、")
    print("       'a & b' 与 '1 < 2' 显示为字面字符而不是乱码或报错。")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

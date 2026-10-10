"""独立验收一个 EPUB：刻意**不用**插件自己的 Epub.verify()。

为什么要另写一个：用自己的代码检查自己的产物，两边同时错就一起绿。这里换成
Python 标准库（zipfile + xml.etree）——另一套实现、另一个语言、另一个作者，
用来回答一个更朴素的问题：**这本书别的阅读器能不能打开？**

它检查的是"打开前"的硬条件：
  - zip 本身完好（每条 CRC 都对）
  - mimetype 是第一个条目且不压缩（规范硬要求，很多阅读器靠这个识别）
  - container.xml → OPF 这条寻址链通
  - manifest / spine / nav / ncx 的交叉引用没有断头
  - 每个 .xhtml/.ncx/.opf 都能作为 XML 解析（这是"能打开"的真关卡）
  - 转义正确：'a & b' 读出来是字面字符，且没有双重转义

用法：
    python tools/verify_epub.py sample-book.epub
    python tools/verify_epub.py sample-book.epub --html 报告.html   # 顺带生成可翻阅的报告

退出码：0 = 全部通过；1 = 有检查项失败。
"""

from __future__ import annotations

import argparse
import html as html_mod
import pathlib
import re
import sys
import zipfile
import xml.etree.ElementTree as ET

NS_CONTAINER = "{urn:oasis:names:tc:opendocument:xmlns:container}"
NS_OPF = "{http://www.idpf.org/2007/opf}"
NS_DC = "{http://purl.org/dc/elements/1.1/}"


class Report:
    def __init__(self) -> None:
        self.rows: list[tuple[str, bool, str]] = []

    def check(self, name: str, ok: object, detail: str = "") -> bool:
        ok = bool(ok)
        self.rows.append((name, ok, detail))
        return ok

    @property
    def failures(self) -> list[tuple[str, bool, str]]:
        return [r for r in self.rows if not r[1]]


def _body_inner(xhtml_text: str) -> str:
    m = re.search(r"<body[^>]*>(.*?)</body>", xhtml_text, re.S)
    return m.group(1).strip() if m else ""


def verify(path: pathlib.Path) -> tuple[Report, dict]:
    r = Report()
    info: dict = {"chapters": [], "css": "", "title": "", "identifier": ""}

    # ---- 1. zip 完好性 -----------------------------------------------------
    try:
        z = zipfile.ZipFile(path)
    except Exception as exc:  # noqa: BLE001
        r.check("zip 可打开", False, f"{type(exc).__name__}: {exc}")
        return r, info
    r.check("zip 可打开", True, f"{path.name}")

    bad_crc = z.testzip()
    r.check("每条 CRC 校验通过", bad_crc is None,
            "全部条目完好" if bad_crc is None else f"损坏条目：{bad_crc}")

    names = z.namelist()
    dups = sorted({n for n in names if names.count(n) > 1})
    r.check("无重复条目", not dups, f"{len(names)} 个条目" if not dups else str(dups))

    unsafe = [n for n in names if n.startswith("/") or ".." in n.split("/")]
    r.check("无绝对路径 / 无 .. 越界", not unsafe, "无" if not unsafe else str(unsafe))

    # ---- 2. mimetype ------------------------------------------------------
    if names:
        r.check("mimetype 是第一个条目", names[0] == "mimetype", f"第一个是 {names[0]!r}")
    if "mimetype" in names:
        raw = z.read("mimetype")
        r.check("mimetype 内容正确", raw == b"application/epub+zip", raw.decode("latin-1"))
        r.check("mimetype 未压缩（stored）", z.getinfo("mimetype").compress_type == 0,
                "stored" if z.getinfo("mimetype").compress_type == 0 else "被压缩了")

    # ---- 3. container.xml → OPF -------------------------------------------
    opf_name = None
    if "META-INF/container.xml" in names:
        try:
            root = ET.fromstring(z.read("META-INF/container.xml"))
            rf = root.find(f"{NS_CONTAINER}rootfiles/{NS_CONTAINER}rootfile")
            opf_name = rf.get("full-path") if rf is not None else None
            r.check("container.xml 指向 OPF", bool(opf_name), str(opf_name))
        except ET.ParseError as exc:
            r.check("container.xml 可解析", False, str(exc))
    else:
        r.check("container.xml 存在", False, "缺 META-INF/container.xml")

    if not opf_name or opf_name not in names:
        r.check("OPF 文件存在", False, f"{opf_name!r} 不在包里")
        return r, info
    r.check("OPF 文件存在", True, opf_name)

    opf_dir = opf_name.rsplit("/", 1)[0] + "/" if "/" in opf_name else ""
    opf = ET.fromstring(z.read(opf_name))

    # ---- 4. OPF 必需元数据 ------------------------------------------------
    title_el = opf.find(f"{NS_OPF}metadata/{NS_DC}title")
    ident_el = opf.find(f"{NS_OPF}metadata/{NS_DC}identifier")
    info["title"] = (title_el.text or "") if title_el is not None else ""
    info["identifier"] = (ident_el.text or "") if ident_el is not None else ""
    r.check("有 dc:title", bool(info["title"]), info["title"])
    r.check("有 dc:identifier", bool(info["identifier"]), info["identifier"])
    modified = [m for m in opf.iter(f"{NS_OPF}meta")
                if m.get("property") == "dcterms:modified"]
    r.check("有 dcterms:modified", bool(modified),
            modified[0].text if modified else "缺（EPUB3 要求）")

    # ---- 5. manifest / spine 交叉引用 -------------------------------------
    manifest = {}
    for item in opf.iter(f"{NS_OPF}item"):
        iid = item.get("id")
        if iid in manifest:
            r.check("manifest id 唯一", False, f"重复 id：{iid}")
        manifest[iid] = item
    r.check("manifest id 唯一", True, f"{len(manifest)} 项")

    missing_files = [it.get("href") for it in manifest.values()
                     if it.get("href") and f"{opf_dir}{it.get('href')}" not in names]
    r.check("manifest 里每个文件都在包里", not missing_files,
            "全部命中" if not missing_files else f"缺：{missing_files}")

    spine = [it.get("idref") for it in opf.iter(f"{NS_OPF}itemref")]
    dangling = [s for s in spine if s not in manifest]
    r.check("spine 的 idref 都能在 manifest 找到", not dangling,
            f"{len(spine)} 个条目" if not dangling else f"断头：{dangling}")

    ncx_id = next((i for i, it in manifest.items()
                   if it.get("media-type") == "application/x-dtbncx+xml"), None)
    nav_id = next((i for i, it in manifest.items()
                   if "nav" in (it.get("properties") or "")), None)
    r.check("有 NCX（兼容老阅读器）", bool(ncx_id), str(ncx_id))
    r.check("有 nav 文档（EPUB3）", bool(nav_id), str(nav_id))

    # ---- 6. 所有 XML 文档都能解析 ----------------------------------------
    xml_names = [n for n in names if n.endswith((".xhtml", ".ncx", ".opf", ".xml"))]
    broken = []
    for n in xml_names:
        try:
            ET.fromstring(z.read(n))
        except ET.ParseError as exc:
            broken.append(f"{n}: {exc}")
    r.check(f"全部 {len(xml_names)} 个 XML 文档可解析（'能不能打开'的真关卡）",
            not broken, "全部通过" if not broken else " | ".join(broken[:3]))

    # ---- 7. 章节与目录 ----------------------------------------------------
    text_meta = {i: it for i, it in manifest.items() if it.get("media-type") == "application/xhtml+xml"}
    for iid, it in text_meta.items():
        if it.get("properties"):
            continue  # nav 不算正文
        full = f"{opf_dir}{it.get('href')}"
        if full not in names:
            continue
        raw = z.read(full).decode("utf-8")
        inner = _body_inner(raw)
        m = re.search(r'<h1[^>]*>(.*?)</h1>', inner, re.S)
        ctitle = re.sub(r"<[^>]+>", "", m.group(1)).strip() if m else it.get("href", "")
        info["chapters"].append({"href": full, "title": ctitle, "html": inner})

    r.check("正文章节数 > 0", len(info["chapters"]) > 0, f"{len(info['chapters'])} 章")

    if nav_id:
        nav_full = f"{opf_dir}{manifest[nav_id].get('href')}"
        if nav_full in names:
            nav_text = z.read(nav_full).decode("utf-8")
            nav_links = re.findall(r'<a\s[^>]*href="([^"#]+)', nav_text)
            r.check("nav 目录条目数与章节数一致", len(nav_links) == len(info["chapters"]),
                    f"nav {len(nav_links)} 条 / 章节 {len(info['chapters'])} 章")

    if "OEBPS/style.css" in names or any(n.endswith("style.css") for n in names):
        css_name = next(n for n in names if n.endswith("style.css"))
        info["css"] = z.read(css_name).decode("utf-8")

    # ---- 8. 转义正确性（读出来必须是字面字符） ----------------------------
    all_text = []
    for c in info["chapters"]:
        all_text.append(re.sub(r"<[^>]+>", "", c["html"]))
    joined = html_mod.unescape(" ".join(all_text))
    r.check("'a & b' 读出来是字面字符", "a & b" in joined,
            "命中" if "a & b" in joined else "没找到（转义错或丢失）")
    r.check("'1 < 2' 读出来是字面字符", "1 < 2" in joined,
            "命中" if "1 < 2" in joined else "没找到（转义错或丢失）")
    r.check("没有双重转义（&amp; 残留）", "&amp;" not in joined,
            "干净" if "&amp;" not in joined else "出现 &amp; 字面量")

    return r, info


def write_html_report(out: pathlib.Path, src: pathlib.Path, r: Report, info: dict) -> None:
    def esc(s: str) -> str:
        return html_mod.escape(s)

    rows = "\n".join(
        f'<tr class="{"ok" if ok else "bad"}"><td>{esc(n)}</td>'
        f'<td>{"通过" if ok else "失败"}</td><td>{esc(d)}</td></tr>'
        for n, ok, d in r.rows)

    toc = "\n".join(
        f'<li><a href="#ch{i}">{esc(c["title"])}</a></li>'
        for i, c in enumerate(info["chapters"]))

    chs = "\n".join(
        f'<section class="chapter" id="ch{i}"><h2>{esc(c["title"])}</h2>{c["html"]}</section>'
        for i, c in enumerate(info["chapters"]))

    out.write_text(f"""<!DOCTYPE html>
<html lang="zh"><head><meta charset="utf-8"/>
<title>EPUB 验收报告 — {esc(info['title'])}</title>
<style>
body {{ font-family: "Microsoft YaHei", "Noto Sans CJK", sans-serif; margin: 2rem auto;
        max-width: 46rem; line-height: 1.8; color: #222; background: #fafafa; }}
h1 {{ font-size: 1.5rem; }} h2 {{ font-size: 1.15rem; margin-top: 2rem; }}
table {{ border-collapse: collapse; width: 100%; background: #fff; font-size: .92rem; }}
th, td {{ border: 1px solid #ddd; padding: .4rem .6rem; text-align: left; }}
th {{ background: #f0f0f0; }}
tr.ok td:nth-child(2) {{ color: #0a0; font-weight: 600; }}
tr.bad td:nth-child(2) {{ color: #c00; font-weight: 600; }}
tr.bad {{ background: #fff2f2; }}
.meta {{ background: #fff; border: 1px solid #ddd; padding: .8rem 1rem; font-size: .9rem; }}
.chapter {{ background: #fff; border: 1px solid #ddd; padding: 1rem 1.4rem; margin-top: 1rem; }}
.chapter h1, .chapter-title {{ font-size: 1.25rem; }}
{info['css']}
</style></head><body>
<h1>EPUB 验收报告（独立工具链）</h1>
<div class="meta">
<b>文件</b>：{esc(src.name)}<br/>
<b>书名</b>：{esc(info['title'])}<br/>
<b>identifier</b>：<code>{esc(info['identifier'])}</code><br/>
<b>章节数</b>：{len(info['chapters'])}<br/>
<b>检查项</b>：{len(r.rows)} 项，失败 {len(r.failures)} 项<br/>
<b>生成工具</b>：tools/verify_epub.py（Python 标准库，非插件自身实现）
</div>
<h2>检查项</h2>
<table><tr><th>检查</th><th>结果</th><th>说明</th></tr>
{rows}
</table>
<h2>目录</h2><ol>{toc}</ol>
<h2>正文（按书里存的原样渲染）</h2>
{chs}
</body></html>
""", encoding="utf-8")


def main() -> int:
    ap = argparse.ArgumentParser(description="独立验收 EPUB")
    ap.add_argument("epub", type=pathlib.Path)
    ap.add_argument("--html", type=pathlib.Path, default=None,
                    help="同时写出可翻阅的 HTML 报告")
    args = ap.parse_args()

    if not args.epub.exists():
        print(f"找不到文件：{args.epub}", file=sys.stderr)
        return 2

    r, info = verify(args.epub)

    width = max((len(n) for n, _, _ in r.rows), default=10)
    for name, ok, detail in r.rows:
        print(f"[{'通过' if ok else '失败'}] {name.ljust(width)}  {detail}")

    print()
    if r.failures:
        print(f"结论：{len(r.failures)} 项失败 / 共 {len(r.rows)} 项")
    else:
        print(f"结论：全部 {len(r.rows)} 项通过 — 这本书的结构是可打开的")

    if args.html:
        write_html_report(args.html, args.epub, r, info)
        print(f"报告：{args.html}")

    return 1 if r.failures else 0


if __name__ == "__main__":
    raise SystemExit(main())

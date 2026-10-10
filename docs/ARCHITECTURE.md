# 架构说明

> 本文回答一个问题：**为什么现在的番茄插件读起来"每一章都像一本新书"，以及要改成什么样。**
> 文中所有结论都带 `文件:行号` 证据，可直接在 `src/fanqie.koplugin/` 下查证。

---

## 0. 一句话结论

不是"每章下载成一本书"再推送——而是**插件把每一章各存成一个独立 `.html` 文件，然后让
KOReader 一章一次地"打开这个文件"**。KOReader 的阅读器以"文档"为一切状态的单位
（分页、进度、书签、目录、字号、阅读统计、返回行为），所以每翻一章就等于换一本书。

问题不在下载环节，在**交给阅读器的粒度**。

---

## 1. 现状：一条完整的阅读链路

以"点开一本书 → 读到下一章"为例，实际发生的事：

| 步骤 | 位置 | 行为 |
| --- | --- | --- |
| 1. 取目录 | `fanqie/client.lua:1124` `Client:fetch_chapter_directory` | 请求章节列表 |
| 2. 取正文 | `fanqie/content.lua:1428` `Content.fetch_chapter_html` | 抓单章正文 + 段评 |
| 3. 落盘 | `fanqie/content.lua:1297` `Content.save_chapter_html` | 写成**一章一个** `.html` |
| 4. 落盘路径 | `fanqie/content.lua:1303` | `<缓存目录>/chapter_<item_id>.html` |
| 5. 图片 | `fanqie/content.lua`(同函数内) | 一份写到 `<缓存目录>/images/`，一份内联成 base64 `data:` URI |
| 6. 打开 | `main.lua:2415` / `fanqie/reader_navigation.lua:193` | `ReaderUI:showReader(path, nil, true)` |
| 7. 翻下一章 | `main.lua:2873-2875`、`main.lua:2746-2749` | 再走一遍 2→6 |
| 8. 缓存命中 | `fanqie/content.lua:316-319` `Content.find_chapter_file` | 命中就跳过 2，直接走 6 |

关键代码（`fanqie/content.lua:1297` 附近的原注释直说了这件事）：

```lua
-- HTML format (standalone .html files, one per chapter)
function Content.save_chapter_html(settings, book, chapter, xhtml, assets, css)
    ...
    local path = dir .. "/" .. "chapter_" .. item_id .. ".html"   -- content.lua:1303
```

---

## 2. 根因：`ReaderUI:showReader()` 会重造整个阅读器

`main.lua:2403`（`fanqie/reader_navigation.lua:183` 是同构副本）：

```lua
function FanQiePlugin:showReaderUI(path, chapter)
    ...
    ReaderUI:showReader(path, nil, true)  -- seamless=true 隐藏"打开文件"提示
```

`showReader` 的语义是"打开一个文档"，不是"跳到这本书的某个位置"。于是每翻一章：

- **文档实例被换掉** → `ReaderUI` 重新构造 `ReaderPaging` / `ReaderRolling` / `ReaderToc` 等组件；
- **分页与进度重置** → 进度条从"这本书的 37%"变成"这一章的 x%"；
- **目录变成"这一章的目录"** → 所以插件必须猴补丁 `ReaderToc:onShowToc`，把它劫持成插件自己的章节目录（`patches/core.lua:63`）；
- **每章末尾触发 `onEndOfBook`** → 所以"翻下一章"要靠挂在这个事件上实现（`main.lua:2797`）；
- **每一章都会进阅读历史** → 所以必须猴补丁 `ReadHistory:addItem` 直接 `return`（`patches/core.lua:80`）；
- **第一页再往前翻没有"上一章"概念** → 所以必须在 `ReaderPaging:onGotoViewRel` / `ReaderRolling:onGotoViewRel` 上判断"位置没动"来补（`patches/core.lua:95`、`patches/core.lua:113`）；
- **章内锚点链接不被识别** → 所以 `fanqie-para:N` 协议要拦 `ReaderLink:onGotoLink`（`patches/core.lua:137`）。

> **这五个猴补丁本身就是"粒度不对"的证据。** 它们不是插件想做的功能，
> 而是为了掩盖"把章当书"这一层错配而付出的代价。

### 2.1 一个刺眼的旁证

`fanqie/i18n.lua:64` 里躺着一条**从未被调用**的文案：

```lua
["Download all %1 chapters as one EPUB?"] = "将全部 %1 章下载为一个 EPUB？",
```

全仓库 grep `epub` / `mimetype` / `content.opf` / `toc.ncx` / `container.xml`
只命中这条文案和它的"EPUB"标签——**上游的 EPUB 导出功能只存在于文案里，代码没有实现**。
上游作者显然清楚正确形态是什么，只是没做完。

> 本仓库已经把这一块补上了：`src/fanqie.koplugin/fanqie/epub.lua` 是新增的
> EPUB 3 生成器（纯字节组装、零 UI 依赖），由 `tests/spec/epub_spec.lua` 的
> 20 条用例钉住。**还差最后一步**：把它接进 `main.lua` 的下载与打开流程。
> 也就是说，"正确形态"现在是可执行的代码，不再是文案。

---

## 3. 目标架构：一本书 = 一个 EPUB

把"交给阅读器的粒度"从**章**提升到**书**：

```
                  现状                                    目标
  ┌──────────────┐                        ┌──────────────────────────┐
  │ 目录（内存）  │                        │ 目录（内存）              │
  └──────┬───────┘                        └────────┬─────────────────┘
         │ 逐章抓取                                │ 逐章抓取
  ┌──────▼───────┐                        ┌────────▼─────────────────┐
  │ chapter_1.html│──┐                     │ 章节正文缓存（可复用）    │
  │ chapter_2.html│  │ 一章一开             └────────┬─────────────────┘
  │ chapter_3.html│  │                              │ 组装（一次性）
  └──────────────┘  │                     ┌────────▼─────────────────┐
                    └──► ReaderUI          │ book.epub                │
                         （每章一次）       │  ├─ mimetype             │
                                          │  ├─ META-INF/container.xml│
                                          │  ├─ OEBPS/content.opf    │
                                          │  ├─ OEBPS/toc.ncx        │
                                          │  ├─ OEBPS/nav.xhtml      │
                                          │  ├─ OEBPS/text/ch1.xhtml │
                                          │  └─ OEBPS/images/*       │
                                          └────────┬─────────────────┘
                                                   │ 一次
                                                   ▼
                                            ReaderUI（整本书）
```

换成整书 EPUB 之后，**上面五个猴补丁全部可以删除**，因为：

| 现状要靠补丁实现的事 | 交给 EPUB 后由谁负责 |
| --- | --- |
| 章节目录 | EPUB 的 `nav.xhtml` / `toc.ncx` → KOReader 原生目录 |
| 翻上一章 / 下一章 | 原生翻页到文档边界 |
| 章内锚点（段评） | XHTML 内部链接 |
| 阅读进度 | 原生整书进度（`%`、剩余时间、页码） |
| 不进阅读历史 | 只打开一个文档，本来就只进一条历史 |

### 3.1 为什么选 EPUB 而不是"合并成一个大 HTML"

| 方案 | 优点 | 缺点 |
| --- | --- | --- |
| **单 EPUB**（推荐） | KOReader 原生支持最好；目录/进度/锚点/图片全走标准路径；可脱离本插件用其它阅读器打开；增量更新只需重写被改动的章 | 要正确实现 `content.opf` / `toc.ncx` / 唯一标识 / 图片路径 |
| 合并单 HTML | 实现最简单 | 无原生目录；大书单文件会拖慢 crengine；图片只能 base64 内联，文件膨胀 |

选 EPUB。它是**标准**，而不是又一层只有本插件认识的私有约定。

### 3.2 EPUB 组装要点（实现时的硬约束）

- `mimetype` 必须是压缩包**第一个**条目且**不压缩**（`store`），内容为 `application/epub+zip`；
- `META-INF/container.xml` 指向 `OEBPS/content.opf`；
- `content.opf` 的 `dc:identifier` 必须是**稳定唯一值**（用番茄 `book_id`），否则重装书会丢进度；
- 每个 XHTML 必须**格式良好**（crengine 对 XHTML 比 HTML 严格得多）：自闭合标签、属性加引号、实体转义；
- 章节顺序由 `<spine>` 决定；中文书名/章节名要按 UTF-8 写入并对 XML 保留字符转义；
- 图片路径统一为 OEBPS 内相对路径，不再需要 base64 内联的那一份。

---

## 4. 模块边界（测试友好的硬约束）

本项目在 `tests/` 下带了一套**不需要 KOReader 就能跑**的测试基座，它靠一条约定成立：

> **纯逻辑模块不许 require KOReader 的 UI / apps。**

按这条线划分：

| 类别 | 模块 | 可否在裸 Lua 下测 | 说明 |
| --- | --- | --- | --- |
| 纯逻辑 | `fanqie/cookie.lua` | ✅ 零依赖 | 已有 `tests/spec/cookie_spec.lua`（14 条） |
| 纯逻辑 | `fanqie/sources.lua`、`fanqie/fanqie.lua` | ✅ 只拼 URL | 用真实现替换即可 |
| 纯逻辑 | `fanqie/epub.lua` | ✅ 零依赖（已实现） | 已有 `tests/spec/epub_spec.lua`（20 条）；见下 |
| 半纯 | `fanqie/content.lua` | ⚠️ 需替身 | HTML 清洗/组装/base64/缓存索引可测；抓取部分靠注入传输层 |
| 半纯 | `fanqie/client.lua` | ⚠️ 需替身 | 请求构造 + 响应解析可测；`socket.http` 由测试注入 |
| UI 层 | `main.lua`、`fanqie/bookshelf.lua`、`fanqie/shelf_view.lua`、`fanqie/settings.lua`、`fanqie/reader_navigation.lua`、`patches/core.lua` | ❌ | 只能真机/模拟器验收 |
| 静态护栏 | `tests/spec/logging_spec.lua` | ✅ | 扫源码，禁止日志里出现整份 Cookie 头或对凭据变量做截断 |

**`fanqie/epub.lua` 必须只依赖 Lua 标准库**（它确实如此：连 zip 与 CRC-32 都是自己
实现的，不依赖 `ffi`/`zlib`）。理由很实际：EPUB 是纯字节组装，把它写成纯函数意味着
**整书导出逻辑可以在 CI 里被完整断言**，而不是只能在真机上"看着好像能读"。
这一条已经从约束变成了事实——`tests/spec/epub_spec.lua` 会真的把产出的字节当 zip
重新解析回来，逐条目校验 CRC。

---

## 5. 与上游的关系

- 本仓库的 `src/fanqie.koplugin/` 以 [hesan1232/fanqie.koplugin](https://github.com/hesan1232/fanqie.koplugin)
  v2.2.0（commit `1071e03`，MIT）为起点，详见 `NOTICE.md`。
- 上游既有代码里**已经包含**的是：Web 端 API 路线、一章一文档的阅读链路、五个猴补丁。
- 本项目要改的是**两件相互独立的事**，不要混在一起做：
  1. **粒度**：一章一文档 → 整书 EPUB（见本文）；
  2. **数据源**：Web API → 移动端 API + 设备注册（见 `docs/API.md`）。
- 两者一起改会让"读不出来"的归因彻底混乱。冒烟顺序应当是**先粒度、后数据源**，
  且每一步都用 `tests/` 里的用例锁住已有行为。

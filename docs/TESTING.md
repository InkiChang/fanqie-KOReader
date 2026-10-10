# 测试说明

> 本文回答一个问题：**在 Windows 上，没有任何 KOReader 能用的情况下，怎么测这个插件？**

---

## 0. 先说清约束

KOReader 官方 README 的原话是它可以跑在
"embedded devices (Cervantes, Kindle, Kobo, PocketBook, reMarkable), Android and Linux computers.
Developers can run a KOReader emulator in Linux and MacOS."

也就是说：

| 目标平台 | 有无官方发行 | 能否在本机（Windows）直接跑 |
| --- | --- | --- |
| Kindle / Kobo / PocketBook / reMarkable | ✅ | ❌ 需要真机 |
| Android | ✅ APK | ⚠️ 需要模拟器或真机 |
| Linux 桌面（AppImage） | ✅ | ❌ 需要 Linux 环境或 WSL |
| **Windows 桌面** | ❌ **官方不支持** | — |
| 开发用模拟器（`kodev run`） | ✅ | ❌ 仅 Linux / macOS |

**结论：本机不可能原生跑起 KOReader。** 所以测试必须分层，
把"能在本机自动跑的"和"只能上真机验收的"明确分开。

---

## 1. 三层测试策略

```
        ┌─────────────────────────────────────────────┐
   L3   │ 真机 / 模拟器验收                            │  人工，低频
        │ Kindle・Kobo・Android APK・Linux AppImage     │  每次发版前
        ├─────────────────────────────────────────────┤
   L2   │ 无头集成：对着 mock 番茄服务跑完整请求-解析链路 │  自动，CI
        │ tests/spec/*_spec.lua（注入传输层）           │
        ├─────────────────────────────────────────────┤
   L1   │ 纯逻辑单元测试                                │  自动，CI + 本机
        │ cookie / URL / HTML 清洗 / EPUB 组装 / 缓存索引│  每次提交
        └─────────────────────────────────────────────┘
```

**L1 与 L2 的边界**是"要不要 KOReader 的 UI"。该项目用一条硬规则守住它：
纯逻辑模块不许 `require` `ui/*`、`apps/*`、`device`。
违反规则的模块会在 CI 里被 `--strict` 模式当场拒绝。

**L1 / L2 覆盖不到的东西**（必须如实承认）：触摸手势、排版效果、翻页动画、
菜单弹层、字体重排、以及"整本书读起来手感如何"。这些只能在 L3 用眼睛看。

---

## 2. 本机怎么跑（Windows，已可用）

不需要装 Lua，也不需要装 KOReader。测试基座把 **LuaJIT 2.1 嵌进 Python**，
再用一个"假 KOReader"顶掉 `ui/*` / `apps/*`。

### 2.1 一次性准备

```powershell
# 把 lupa（内含 LuaJIT 2.1）解包到仓库外的缓存目录
python scripts/bootstrap_pylibs.py
```

> 为什么不用 `pip install`：本机 pip 受环境策略限制会报
> `[Errno 13] Permission denied`，所以脚本直接从 wheel 解包，不做安装。

### 2.2 跑测试

```powershell
python tests/run_tests.py                 # 全部用例
python tests/run_tests.py cookie_spec     # 只跑一个
python tests/run_tests.py --strict        # 纯逻辑模块一旦依赖 UI 就报错
python tests/run_tests.py --stub-log      # 打印所有被桩化的 KOReader 模块名
python tests/run_tests.py --list          # 只列用例
```

输出是 TAP 13，退出码 `0` = 全绿、`1` = 有断言失败、`2` = 基座自身出错。

### 2.3 为什么选 LuaJIT 2.1 而不是 PUC Lua 5.5

lupa 里同时打包了 `lua51`/`lua52`/`lua53`/`lua54`/`lua55`/`luajit20`/`luajit21`，而
**默认的 `LuaRuntime` 是 Lua 5.5**。KOReader 自己是 LuaJIT 2.1（Lua 5.1 语义），
用 5.5 跑插件代码会得到毫无意义的结论——比如 `unpack` 已从 5.5 移除、
`tostring(1.0)` 变成了 `"1.0"` 而不是 `"1"`。
所以 `tests/run_tests.py` 显式写 `from lupa.luajit21 import LuaRuntime`。

### 2.4 在 Linux / macOS / WSL 上跑

装了 `lua5.1` 或 `luajit` 时可以直接走原生路径（CI 就是这么跑的）：

```bash
sudo apt-get install -y lua5.1 luarocks
lua tests/run.lua
# 或者让 Python 驱动改用原生解释器
python tests/run_tests.py --native
```

---

## 3. 这个"假 KOReader"到底假在哪

`tests/support/koreader.lua` 分三层，越往下越假：

| 层 | 内容 | 是真是假 |
| --- | --- | --- |
| 1 | `gettext`、`datastorage`、`util.template`、`logger`、`libs/libkoreader-lfs` | **真实现**——被依赖的语义必须对，例如 `util.template` 按 KOReader 的 `%1/%2` 占位做替换（`main.lua:52` 把 26 处文案都托付给了它） |
| 2 | `socket`、`socket.http`、`ssl.https`、`ltn12` | **可控替身**——由测试注入传输函数，所以 L2 能对着 mock 番茄服务跑完整链路 |
| 3 | 其余 `ui/*`、`apps/*`、`device`、`ffi/*` | **宽松桩**——任意字段都是函数、任意调用都返回新桩，保证 `require` 与调用不炸 |

`tests/support/tap.lua` 是自己写的极简 TAP 框架（不依赖 busted / luarocks），
原因和上面一样：本机的包管理环境不可靠，而测试基座自身不该是依赖地狱。

### 3.1 已抹平的三处偏差（第三处是踩过坑的）

基座故意把这些对齐到 Linux 行为，否则同一个断言会在本机与 CI 给出不同结果：

1. **换行**：Windows 文本模式会把 `\n` 写成 `\r\n`，而 KOReader 只跑 Linux/Android
   （C 库 stdio 不做翻译）。`io.open` 被覆写为一律二进制打开。
2. **路径编码**：Windows 的 `fopen` 走 ANSI 代码页，UTF-8 中文路径直接失败。
   中文路径下自动回退到 Python。
   真机没这个问题，但测试里会出现"章节缓存写不进去"这种假故障。
3. **编码层（容易漏掉的一条）**：桥接用的 lupa 是以 `encoding="utf-8"` 构造的。
   这意味着两端方向并不对称：

   | 方向 | 数据类型 | 是否安全 |
   | --- | --- | --- |
   | Python → Lua | Python `bytes` | 安全，原样进 Lua（Lua 字符串本来就是字节串） |
   | Python → Lua | Python `str` | 安全，按 UTF-8 编码成字节 |
   | Lua → Python | Lua 字符串 | **不安全**：会被严格按 UTF-8 解码，非法字节直接抛 `UnicodeDecodeError` |

   所以"写"绝不能跨这条边界传数据。`tests/support/koreader.lua` 的做法是：
   Lua 先把内容写到一个**纯 ASCII 路径**的中转文件（Windows 原生 `fopen` 能处理），
   再由 Python 按路径把文件搬到目标位置——**跨过边界的只有路径，没有数据**。

   这不是学术问题：EPUB 产物是 zip，字节里必然出现 `0x80–0xFF` 的裸字节。
   这条规则被 `tests/spec/harness_spec.lua` 的
   "基座.io.open 对中文路径传输任意字节而不做编码转换" 钉住；一旦有人把写路径
   改回"直接交给 Python"，那条用例会立刻红。

   顺带一条由此得出的实现纪律：`io.open` 的 `close()` 返回值**必须被检查**。
   经桥接写文件时，缓冲区真正落盘发生在 `close()`；不检查就会把"磁盘满/目录消失"
   表现为静默成功。`fanqie/epub.lua` 的 `Epub.write` 就是按这个写的。

---

## 4. 用例怎么写

```lua
-- tests/spec/xxx_spec.lua
local T = require("tap")
local Cookie = require("fanqie/cookie")   -- 路径相对 src/fanqie.koplugin/

T.test("cookie.xxx 在某条件下应当如何", function(t)
    t:eq(actual, expected, "失败时给人看的中文说明")
    t:ok(cond, "说明")
    t:contains(haystack, needle, "说明")
end)
```

约定：

- 一个文件一个模块，文件名 `<模块>_spec.lua`；
- 断言说明写**为什么**（"属性不该被持久化，否则 Cookie 头会带上 Path=/"
  比"应当相等"有用得多）；
- 每跑一个 spec 文件前，基座会清空临时数据目录、日志、网络替身，用例之间不残留状态；
- 需要"服务端怎么回"的用例，用 `require("koreader").net.set_transport(fn)` 注入响应。

**记一条**：框架没有 `not_ok`，要写 `t:ok(not x, "说明")`。断言全集是
`ok` / `assert_ok` / `eq` / `neq` / `contains` / `not_contains` / `matches` /
`fail` / `throws` / `skip`（见 `tests/support/tap.lua`）。

`t:skip("原因")` 用于**前提不成立**，不是"懒得写"。它会中断当前用例
（内部借 `error()` 实现，所以调用之后的断言不会执行），在 TAP 里输出
`ok - <名称> # SKIP <原因>`，并单独计入 `skipped`，不会污染 `passed`。

典型例子就是"基座.宽松桩让 KOReader 的 UI 模块 require 得到"：`--strict`
的语义是**拒绝**给 UI 模块造桩，那条用例的前提在严格模式下不存在，
所以它显式跳过 —— 不这么做，`--strict` 就会永远带着一条假红，
久而久之没人再看它的输出。

### 4.1 已有用例

| 文件 | 用例数 | 覆盖 |
| --- | --- | --- |
| `tests/spec/harness_spec.lua` | 14 | 基座自检：gettext / `util.template` / lfs / logger / 网络替身 / 离线可用性 / io.open 三处偏差（含裸字节保真） |
| `tests/spec/cookie_spec.lua` | 14 | `fanqie/cookie.lua`：Cookie 头解析、Set-Cookie 属性过滤、`Expires` 里的逗号、cURL 粘贴解析 |
| `tests/spec/epub_spec.lua` | 20 | `fanqie/epub.lua`：CRC-32（含增量）、XML 转义、zip 打包/解包、OPF/nav/NCX 骨架、落盘字节保真、`book_id` 精度守卫、裸 `&`/`<` 拒绝、自检能发现截断、报错信息在中文正文里仍是合法 UTF-8 |
| `tests/spec/logging_spec.lua` | 5 | 日志不得泄漏凭据：不得打印整份 Cookie 头、不得截断打印 `jar_str`/`raw_set_cookie`/`payload` 等；含反空洞检查 |

当前共 **53** 条用例，两种模式都必须是绿的：

| 模式 | 命令 | 期望输出 |
| --- | --- | --- |
| 宽松（默认） | `python tests/run_tests.py` | `passed=53 failed=0 errored=0 skipped=0` |
| 严格 | `python tests/run_tests.py --strict` | `passed=52 failed=0 errored=0 skipped=1` |

严格模式的 52 条里没有一条用到 UI 桩 —— 这就是
`docs/ARCHITECTURE.md` §4 那条"纯逻辑模块不许依赖 UI"边界的**可执行证明**，
而不是一句口号。改动 `cookie.lua` / `epub.lua` 时如果悄悄引入了 UI 依赖，
严格模式会立刻红。

> Cookie 这一份已经赚回了成本：它当场抓出 `extract_from_curl` 在
> `-d '{"a":"b"}'` 上会把内容截断成 `{` 的真实缺陷（见该文件内的注释）。
>
> 基座自检这一份同样赚回了成本：它把"中文路径下写 EPUB"从"碰巧绿"变成
> "真的绿"——原先的桥接写法根本传不了 zip 里的裸字节，是 §3.1 第 3 条那个
> 边界被钉住之后才暴露的。

---

## 5. L3：真的要在设备上验收时

| 途径 | 成本 | 接近真机的程度 |
| --- | --- | --- |
| Android 模拟器 + 官方 KOReader APK | 中（要装 Android SDK） | 高（触摸、排版、性能都真） |
| Android 手机 + 官方 APK | 低（有手机就行） | 高 |
| WSL2 + Linux AppImage | 中（要装 WSL，需要管理员与重启） | 中（Linux 桌面版） |
| Kindle / Kobo 真机 | 低（有设备就行） | 最高 |

安装方式：把 `src/fanqie.koplugin/` 整个目录拷到设备的
`koreader/plugins/fanqie.koplugin/`，重启 KOReader 即可（打包脚本见 `scripts/package.sh`）。

> **注意**：L3 的结果不能替代 L1/L2。真机上"看起来能读"不代表回车、
> 转义、目录顺序、`dc:identifier` 稳定性这些细节是对的——那些必须由用例钉住。

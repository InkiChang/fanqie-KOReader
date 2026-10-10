# NOTICE / 来源与致谢

本项目（`fanqie-KOReader`）是围绕 **KOReader 番茄小说插件** 的独立开源工程。
代码与设计来源于以下上游项目，按各自的许可证使用，特此声明与致谢。

---

## 1. 插件骨架与既有实现

| 项 | 内容 |
| --- | --- |
| 项目 | `fanqie.koplugin` — KOReader 番茄小说插件 |
| 上游仓库 | https://github.com/hesan1232/fanqie.koplugin |
| 引入 commit | `1071e03b723c386fb23a42baf44c17df624b8dce`（2026-08-11，「支持晴天书源、优化界面和缓存逻辑」） |
| 初始版本 | v2.2.0 |
| 许可证 | MIT（见上游 `README.md` 的「许可证」章节） |
| 在本仓库的位置 | `src/fanqie.koplugin/`（作为本项目 v0.1.0 的基线代码，后续在其上演进） |
| 上游原始克隆 | `refs/fanqie.koplugin-upstream/`（本地保留，已被 `.gitignore` 排除，不入库） |

本项目保留上游 MIT 许可证与版权声明；对本仓库内 `src/fanqie.koplugin/` 的任何修改，
同样以 MIT 许可证发布。

---

## 2. 官方账号体系 / 书架与进度同步的接口参考

| 项 | 内容 |
| --- | --- |
| 项目 | `Fanqie-novel-Downloader` |
| 上游仓库 | https://github.com/POf-L/Fanqie-novel-Downloader |
| 引入 commit | `9fa8f45`（fix(ci): 资产审计下载对 5xx/限流做指数退避重试） |
| 上游公开内容 | 仅含文档、CI 工作流、发布脚本与测试，**不含业务源码** |
| 参考价值 | 官方账号登录流程、书架/阅读进度同步的产品行为与发布工程实践 |
| 在本仓库的位置 | `refs/Fanqie-novel-Downloader/`（本地保留，不入库） |

> [!IMPORTANT]
> 该仓库未提供业务源码，因此本项目对番茄移动端接口的认识来自**公开可观察的请求行为**，
> 详见 [`docs/API.md`](docs/API.md)。本仓库不包含、也不分发任何上游的闭源二进制或私有代码。

---

## 3. 对上游代码的本地修改

`src/fanqie.koplugin/` 是上游 v2.2.0 的拷贝。下表是**逐文件比对上游 clone 得出的完整清单**
（比对方式：对 `refs/fanqie.koplugin-upstream/` 与本仓库同名文件做哈希比对）：

| 文件 | 改动 | 为什么 |
| --- | --- | --- |
| `fanqie/qrlogin.lua` | 删掉打印完整 Cookie 头、`Set-Cookie` 原文、`jar_str` 前缀的日志，只保留长度与键名 | 会把 `sessionid` 写进 `fanqie.log`，而该日志正是缺陷报告要求用户上传的文件 |
| `fanqie/async.lua` | 跨进程载荷只记录长度，不再打印前 120 字 | 同上：登录场景的载荷里含 cookie |
| `fanqie/cookie.lua` | `extract_from_curl` 改为按单引号/双引号分别匹配 | 原写法在 `-d '{"book_id":"7351"}'` 的第一个双引号处截断，只解析出 `{` |
| `config.example.lua` | 删掉 6 个没有任何代码读取的 `debug.*` 键，改为指向真实开关（插件菜单 → 设置 → 开发者日志） | 照它改配置不会有任何效果 |
| `fanqie/epub.lua` | **新增文件**：EPUB 3 生成器（纯 Lua、零 UI 依赖） | 上游只有一句未实现的 EPUB 文案，本项目把它补成了可执行的代码 |

> [!NOTE]
> **凭据日志那两处修复是本仓库单独做的，维护者决定不向上游提交 PR。**
> 因此上游后续版本中该问题大概率仍然存在——从上游同步新版本时，请不要"以新版为准"
> 把这几处覆盖回去。`tests/spec/logging_spec.lua` 会在这类回归发生时直接失败。

> [!TIP]
> 上游包内的 `README.md` 声称书源顺序是「大灰狼 → 晴天 → 官方」，但上游自己的代码
> （`fanqie/settings.lua`）写的是 `official = 1`、`qingtian = 2`、`dahuilang = 3`。
> 这两处都不是本仓库的改动；根 README 与 `docs/ARCHITECTURE.md` 一律以代码为准。

---

## 4. 运行时依赖

| 依赖 | 说明 |
| --- | --- |
| [KOReader](https://github.com/koreader/koreader) | 宿主阅读器，AGPL-3.0。插件以运行时 `require` 方式调用其模块，不复制其源码 |
| [LuaJIT](https://luajit.org/) | KOReader 的 Lua 运行时，Lua 5.1 语义 |
| [LuaFileSystem](https://github.com/lunarmodules/luafilesystem) | KOReader 内置 `libs/libkoreader-lfs` 的上游实现 |
| [LuaSocket](https://github.com/lunarmodules/luasocket) | KOReader 内置的 HTTP/`ltn12` 栈 |

---

## 5. 请求签名与正文解密的实现来源（2026-10 新增）

番茄移动端的请求签名（`x-argus` / `x-ladon` / `x-ss-stub`）与正文解密（CM 握手）**没有公开规范**。
本项目的做法是：**读别人的实现当"规格"，自己用 Lua 独立重写，再用权威向量逐字节验证。**

| 项目 | 许可 | 我们怎么用它 |
| --- | --- | --- |
| `ch6vip/fqapp` | **GPL-3.0** | **只当规格读**。取的是**事实**：三把密钥常量的值、protobuf 字段布局、SM3 + Simon + 551 框架的流程、CM 握手（RFC 3526 **1536 位** MODP + AES-256-CBC）的步骤。**未复制其代码**；本仓库的 `fanqie/sm3.lua`、`fanqie/simon.lua`、`fanqie/argus.lua`、`fanqie/bignum.lua`、`fanqie/cm.lua`、`fanqie/official_api.lua` 均为独立重写。 |
| `linzj/fanqie-dl` | MIT | 早期签名复刻参考（`fanqie/sign_crypto.lua` 里的 SHA-256 / AES / Ladon）。**注意：那一套算法后被证实是错的**（正确算法是 SM3 + Simon + 551 框架），现仅作为历史与向量来源保留。 |
| `Fanqie-novel-Downloader`（Android 构建） | 见其仓库 | 其原生库 `libfanqie_novel_downloader_tauri.so` 保留了完整符号表，我们用做**符号级定位**（确认 `backend::signing::*` 的存在）。**未复制代码**。 |
| `zero199901/fqnovel-unidbg`、`buding9527/fqnovel-unidbg` | **无许可** | **仅作情报阅读**，未复制任何代码。 |
| `mtongle/fqnovel-unidbg` | Apache-2.0 | 曾评估的技术路线（模拟 metasec SO），**最终未采用**。 |
| `momijineko/fanqie-web-reader` | AGPL-3.0 | 未使用。 |

**验证方式（不靠"看起来能跑"）**：

- **SM3** → GB/T 32905-2016 公开样例；
- **AES** → NIST SP800-38A F.2.1 / F.2.5 官方向量（**加解密都验**）；
- **Simon-64/128** → 与独立实现逐字节比对；
- **X-Argus 551** → **上游仓库自带的 4 条黄金向量**（即"服务端会接受"的那组值，且不依赖我们自己的实现）；
- **CM 握手 / 正文解密 / 请求组装** → 与独立实现的 `pub` / `key` / 明文 / `url` / `body` / `x-argus` 逐字节一致；
- 最终在**真机（Android KOReader）**上跑通「取正文 + 解密」。

> [!CAUTION]
> **这套实现依赖第三方源码里硬编码的三把密钥常量。番茄随时可以轮换，轮换后签名立即失效。**
> 请勿把它当成"长期可用"的前提；插件保留本地已下载内容的回退路径。
> 另：正文与封面版权归原作者与平台，缓存仅供个人阅读，请勿再分发。

---

## 6. 免责声明

本项目仅用于**个人学习与在自有设备上的阅读便利**，不提供、不托管、不分发任何小说正文内容。
所有正文版权归原作者与版权方所有。请支持正版阅读。若相关权利方认为本项目不当，请通过
[`SECURITY.md`](SECURITY.md) 中的联系方式告知，我们将及时调整或移除相关内容。

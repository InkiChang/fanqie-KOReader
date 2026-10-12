# 贡献指南

先说清楚这个项目的边界，因为大部分"看起来该做的事"其实是刻意不做的：

- 本仓库只做 **KOReader 阅读端接入**。它不下载、不托管、不分发小说文本。
- 本仓库只走 **官方账号自己的接口**（书架/目录/进度）。第三方书源是历史遗留的
  可回退项，不主动扩展。
- 改动要能 **在 Windows 上被验证**。做不到的改动（纯 UI 视觉微调）需要说明
  你是在什么设备上肉眼验证的。

---

## 环境准备

仓库里同时有两条运行路径，按你的机器挑：

| 机器 | 运行时 | 命令 |
| --- | --- | --- |
| Linux / macOS / WSL | 原生 Lua 5.1 或 LuaJIT | `make test-native` |
| **Windows（无原生 Lua）** | Python 3.9+ 与 `lupa`（内嵌 LuaJIT 2.1） | `make test-windows` |

不确定就用 `make test`，它会自动挑。

### Windows 上装 lupa

`pip install lupa` 一般可用。若这台机器的 `pip` 因沙箱/权限写不了临时目录，
用仓库自带的绕过脚本——它直接解包 wheel，不碰 `site-packages`：

```powershell
python scripts/bootstrap_pylibs.py --check
python scripts/bootstrap_pylibs.py
python tests/run_tests.py
```

脚本会把包放进仓库上级的 `.cache/pylibs`，`tests/run_tests.py` 会自动找到它。

### 为什么会有 lupa 这条路径

KOReader **官方不支持 Windows**（官方模拟器只有 Linux 与 macOS）。但我们仍然
必须能在改代码后立刻知道自己有没有弄坏东西，所以这里用 lupa 把 LuaJIT 2.1
嵌进 Python，再配一套 KOReader 模块替身（`tests/support/koreader.lua`），
让纯逻辑代码能在 Windows 上跑用例。**这不等于能在 Windows 上跑 KOReader**，
只是能跑其中不依赖 UI 的那部分。

---

## 目录约定

```
src/fanqie.koplugin/   插件本体，唯一事实源。装到设备上就是这个目录
tests/                 Windows 可跑的用例
  support/             测试基座（KOReader 替身、TAP 框架、lfs 桥）
  spec/                用例，命名 <模块>_spec.lua
docs/                  架构、接口、测试、路线图
scripts/               打包与本地引导脚本
tools/                 只读探针（把真实响应落盘看清楚，不写业务逻辑）
.github/               CI 与发布
refs/                  上游克隆，gitignore 掉，只作对照
```

**`refs/` 里的代码不要从 `src/` 里直接 require。** 需要对照时打开看，
要吸收的改动手写进 `src/`，这样 diff 才是可审的。

---

## 加一个用例

1. 在 `tests/spec/` 建 `<模块>_spec.lua`。
2. `require("tap")` 拿到 `T`，`require("koreader")` 拿到基座。
3. 用 `T.test("分组.用例名", function() ... end)`，断言写在里面。

```lua
local T = require("tap")
local K = require("koreader")

T.test("cookie.解析标准 Cookie 头", function()
    local cookie = require("fanqie.cookie")
    local jar = cookie.parse_cookie_header("a=1; b=2")
    T.eq(jar.a, "1")
    T.eq(jar.b, "2")
end)
```

要点：

- **每个用例前基座会自动清空数据目录、日志、网络替身**，用例之间不许互相依赖。
- 需要网络时用注入式替身，别真的发请求：
  `K.net.set_transport(function(req) ... end)`。
- 断言是可用的集合是 `ok / eq / neq / contains / not_contains / matches / throws`。
  想表达"应该失败"就用 `throws`，不要写 `ok(not x)`——后者失败时看不出原因。
- 需要落盘时把路径拼到 `K.data_dir` 下面，别写绝对路径。
- `make test-strict` 会把未登记的 KOReader 模块变成硬错误。**新增的纯逻辑模块
  应该在严格模式下也能跑过**；跑不过说明你 require 了 UI，那是设计问题，不是测试问题。

---

## 改代码时的几条硬规矩

1. **不要新增猴补丁**。`patches/core.lua` 的每一个补丁都是在还历史的债。
   方向是**删补丁**，不是加补丁。确实需要新增时，PR 里要说明为什么没有别的办法。
2. **不要在 `main.lua` 里堆逻辑**。它已经 3200 行了。新功能优先落成
   `fanqie/` 下的独立模块，`main.lua` 只做接线。
3. **不要引入新的外部依赖**。插件跑在嵌入式设备上，多一个依赖就多一处装不上。
   `content.lua` 连 base64 都是自己内联实现的，就是这个原因。
4. **不要提交任何凭据**。`config.lua`、`.env*`、`*.token` 已在 `.gitignore` 里，
   别用 `-f` 绕过去。PR 里贴日志前先把 `sessionid`、`install_id`、`device_id` 抹掉。
5. **接口路径必须可追溯**。新接口要么在 `docs/API.md` 里有记录，要么在 PR 描述里
   说明你是从哪里确认的（探针输出的原文）。凭印象写的路径会被打回。

---

## 提交信息

用 [Conventional Commits](https://www.conventionalcommits.org/)：

```
<类型>(<范围>): <一句话说明>
```

类型用 `feat` `fix` `docs` `test` `refactor` `chore` `perf` `build` `ci`。
范围写模块名，如 `content`、`sources`、`device`、`docs`。

```
fix(cookie): curl 单引号参数被错误截断

extract_from_curl 用 ['"] 匹配引号，遇到 -d '{"book_id":"1"}' 会在
第一个双引号处截断，只拿到 "{'。改为按单/双引号分别匹配。
```

正文里说清 **为什么**，不要复述 diff。

---

## Pull Request 检查清单

- [ ] `make test` 全绿（Windows 用 `make test-windows`）
- [ ] 新逻辑带用例；只改文档则说明无需用例
- [ ] 没有新增猴补丁，或已说明无法避免的理由
- [ ] 没有新增外部依赖
- [ ] 没有提交凭据、缓存目录、`dist/` 产物
- [ ] 涉及接口改动时同步更新了 `docs/API.md`
- [ ] 涉及行为改动时在 `CHANGELOG.md` 的 `Unreleased` 下加了一行

## 关于版权

贡献代码即表示你同意以本仓库的 MIT 许可证发布。**不要提交从别处抄来的
代码**——如果确实要移植，在 PR 里标明来源项目、版本与许可证，并确认它
与 MIT 兼容。`NOTICE.md` 里登记所有非原创来源。

# 更新日志

本文件记录本仓库（fanqie-KOReader）的变更。

格式参考 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> **关于版本号的说明**
> 本仓库起点是上游 `fanqie.koplugin` v2.2.0（见 `NOTICE.md`），
> 插件自身的 `version` 从 **0.0.1** 起算（0.0.x 表示尚在早期自用阶段）。
> 仓库基础设施（测试、CI、打包、文档）不计入插件版本号。

---

## [未发布]

### 新增

- 标准仓库结构：`src/` 放插件本体，`tests/` `docs/` `scripts/` `tools/` `.github/` 各司其职
- **可在 Windows 上运行的测试基座**（`tests/support/`）：
  KOReader 模块替身、TAP 断言框架（含 `skip`）、基于 Python 的文件系统桥
- 测试入口两条路径：原生 Lua（`tests/run.lua`）与 Python + lupa 内嵌 LuaJIT
  （`tests/run_tests.py`），后者用于没有原生 Lua 的机器
- **`fanqie/epub.lua`：EPUB 3 生成器**（纯 Lua、零 UI 依赖）。
  自己实现 CRC-32 与 stored zip 打包，产出标准
  `mimetype` / `container.xml` / `content.opf` / `toc.ncx` / `nav.xhtml` / 分章 XHTML，
  自带 `Epub.verify()` 产物自检。这是把"一章一文档"改成"一本书一个文档"的基础
  （`docs/ARCHITECTURE.md`），**但尚未接进 `main.lua` 的下载/打开流程**
- 用例：`harness_spec`（基座自检，14）、`cookie_spec`（14）、`epub_spec`（20）、
  `logging_spec`（5，日志不得泄漏凭据），共 **53** 条，
  宽松与 `--strict` 两种模式均为绿
- `scripts/bootstrap_pylibs.py`：解包 wheel 方式安装 `lupa`，绕开受限环境下的 pip
- `scripts/package.py`：打包出可安装的 zip 并自检（顶层目录名、必需文件、
  不含本地 `config.lua`、逐条目 CRC），输出 `.sha256`；
  构建使用固定时间戳，因而可复现（同样的输入产出同样的校验和）。
  `scripts/package.sh` 只是它的一层薄封装——用 Python 是为了不依赖 `zip`/`unzip`，
  从而能在打包的同一台机器上把产物读回来验证
- `tools/make_sample_epub.py`：用测试基座生成一本 12 章的示例 EPUB，产出物可以
  直接双击用任何阅读器打开——"生成器到底出不出真书"不必等真机就能肉眼验收
- `tools/verify_epub.py`：**独立**的 EPUB 验收器，刻意改用 Python 标准库
  （`zipfile` + `xml.etree`）而**不是**插件自己的 `Epub.verify()`——用同一套
  代码检查自己的产物，两边同时错就会一起绿。它查 23 项硬条件（CRC、`mimetype`
  的位置与压缩方式、container→OPF 寻址链、manifest/spine/nav/ncx 交叉引用、
  每个 XML 都能解析、转义正确性），并可另出一份 HTML 报告把书按原样渲染出来
- 文档：`docs/ARCHITECTURE.md`（含"每章一本书"问题的定位）、`docs/API.md`、
  `docs/TESTING.md`、`docs/ROADMAP.md`
- CI：Linux 原生 Lua 作业、Windows lupa 作业、打包产物检查作业、luacheck 作业
- 发布流程 `.github/workflows/release.yml`：打 tag 自动构建并发布 zip 与 sha256
- 许可与归属：`LICENSE`（MIT）、`NOTICE.md`

### 修复

> 以下前五条来自一次独立代码审核（用 Python 的 `zipfile` + `xml.etree` 校验产物，
> 而**不是**信 `Epub.verify()` 自己的结论），每条都先复现、后修复。

- **登录凭据会被写进日志**（`fanqie/qrlogin.lua`、`fanqie/async.lua` 共 5 处），
  且与仓库自己的排障流程直接冲突：`.github/ISSUE_TEMPLATE/bug_report.yml` 让用户
  「打开记录日志后复现」再把日志附上来，而 `Log.info`/`Log.debug` 恰好会把
  完整 Cookie 头（含 `sessionid`）、原始 `Set-Cookie`、跨进程载荷前缀写进
  `fanqie.log`。现在只记录**长度与键名**，并用新增的 `tests/spec/logging_spec.lua`
  （5 条）钉住不再回归
- `fanqie/epub.lua` 的 `book_id`：原先用 `tostring()` 拼 `dc:identifier`，传数字时
  会得到 `urn:fanqie:book:7.544410373085e+18`——番茄的 id 有 19 位、超出 Lua 数字
  精度，值本身也已被舍入成 `...957696`。同一本书因此会拿到两个 identity，
  阅读进度归属随之错乱。现在**拒绝数字形式的 `book_id` 并给出可操作的报错**，
  用例也补上了"标识符必须逐字包含传入 id"的断言（原先只断言两次调用一致，
  两次都错也能通过）
- `fanqie/epub.lua` 的正文入口：`chapter_xhtml` 不对 `html`/`body` 转义（因为它是
  标记），但一个字面量的裸 `&` 或裸 `<` 会让整本书变成"格式错误"——构建成功、
  文件存在、打开就报错。现在由新增的 `Epub.find_unsafe_xml()` 在构建期检出并
  报错，并指出具体章节；纯文本请走 `text` 字段（该路径会自动转义）
- `fanqie/cookie.lua` 的 `extract_from_curl`：原本用 `['"]` 匹配引号，
  遇到 `-d '{"book_id":"7351"}'` 这类参数会在第一个双引号处截断，
  只解析出 `{'`。改为按单引号/双引号分别匹配
- `tests/support/koreader.lua` 的 `io.open` 兜底：原先把 Lua 字符串直接交给
  Python（lupa 以 `encoding="utf-8"` 构造，会严格解码），含 `0x80`–`0xFF`
  裸字节的内容会抛 `UnicodeDecodeError`——也就是说**中文路径下根本写不了
  EPUB**（zip 里必然有裸字节）。改为"Lua 先写 ASCII 中转文件，再由 Python 按
  路径搬运"，跨过边界的只有路径、没有数据
- `fanqie/epub.lua` 的 `Epub.write`：原先不检查 `file:close()` 的返回值，
  缓冲区落盘失败（磁盘满、目录消失）会被当成写入成功。现在会报错
- CI 的 `lua-native` 作业原先只装 `lua5.1`，而基座优先用原生 `lfs`，
  该作业必然以"找不到 LuaFileSystem"失败；改为用
  `luarocks --lua-version=5.1 install luafilesystem` 并加一步依赖自检
- `Epub.find_unsafe_xml()` **自己的报错信息在中文正文里是非法 UTF-8**：它用
  `s:sub(pos - 12, pos + 12)` 取"附近片段"，而 `pos` 是**字节**位置，中文里会正好
  切在一个三字节字符的中间，于是错误信息本身带着半截序列。危害不止是显示成乱码：
  任何对这条信息做严格解码的下游（写 JSON 日志、跨语言边界传递）会在"报错路径"上
  再报一次错。改为先按 UTF-8 边界把窗口收拢到字符起始处（新增局部函数
  `utf8_safe_window`），并补了一条**只在中文长句里才会暴露**的回归用例——旧样本
  是 `<p>a & b</p>` 这种短 ASCII 串，窗口被 `math.max(1, ...)` 夹到串首，
  永远切不到字符中间，所以这个 bug 一直藏在"已覆盖"的表象下

### 文档

- 修正 7 处写错的用例计数：`cookie_spec` 13→14、`epub_spec` 18→19，
  总数 45→52（`CHANGELOG.md`、`docs/ARCHITECTURE.md`、`docs/ROADMAP.md`、`docs/TESTING.md`）
- 再次同步计数：`epub_spec` 19→20、总数 52→53（新增一条中文报错用例后本机实测）
- 补齐 `docs/TESTING.md` 的「`t:skip` 用法」与断言全集说明

### 说明

- KOReader 官方不支持 Windows（官方模拟器仅 Linux/macOS）。
  测试基座能验证的是**不依赖 UI 的纯逻辑**，UI 行为仍需真机验收
- CI 工作流**尚未在 GitHub 上真实运行过**：L1 用例、`--strict` 与打包自检
  均已在本机实测，但 CI 里的依赖安装（luarocks 等）要等第一次 push 才算验证

---

## [0.0.1] - 首个开源版本

本仓库的第一个公开版本：

- 纯 Lua 实现官方 App 移动端接口（X-Argus 签名、CM 握手、内容解密）
- 扫码登录、书架、逐章取文与两层缓存、阅读进度同步、预下载
- 段评：段落末尾显示条数气泡，点开查看该段真实评论
- 书源仅保留官方 App

## [2.2.0] - 上游起点

本仓库从上游 `fanqie.koplugin` v2.2.0 起步，
commit `1071e03b723c386fb23a42baf44c17df624b8dce`（2026-08-11），MIT 许可。
上游已有能力（扫码登录、多书源、段评、两层缓存、进度同步）在本仓库中保留，
详见 `NOTICE.md` 与上游自己的文档。

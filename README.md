# fanqie-KOReader

KOReader 插件，用于在 Kindle 等电纸书设备上阅读番茄小说。

当前插件版本：`0.0.2`

## 当前正文源

运行时只有两个正文源，并按优先级自动 fallback：

1. **官方 App 源（`official_app`）**：使用番茄移动端接口获取正文和段评，请求身份模拟为 Android 设备。
2. **番茄 API 备用源（`official_proxy`）**：官方 App 源失败时自动接管正文请求。

网页正文源已移除，因为无法稳定返回完整章节内容。两个源默认都启用，不需要用户手动切换。

## 主要功能

- 扫码登录、书架同步、目录和阅读进度同步
- 官方 App 源优先、番茄 API 自动 fallback
- 章节缓存、离线阅读和 3/5/10 章预下载设置
- 段评气泡、段评详情和真实段落索引
- 适配 Kindle 墨水屏的逐章阅读界面

## 安装

1. 从 GitHub Releases 下载 `fanqie.koplugin-v*.zip`，或运行 `python scripts/package.py` 自行生成。
2. 解压后，将压缩包内的 `fanqie.koplugin/` 整个目录放入 KOReader 的 `plugins/` 目录。
3. 重启 KOReader，在工具菜单中打开「番茄小说」。

最终路径应为：

```text
<KOReader 数据目录>/plugins/fanqie.koplugin/main.lua
```

首次使用通过插件内的扫码登录获取账号状态。官方 App 源会在运行时读取或生成 Android 设备身份；不会使用 Kindle 型号、序列号等硬件信息。

插件源码位于 [`src/fanqie.koplugin/`](src/fanqie.koplugin/)，详细安装、运行时文件、设备身份、段评、缓存和上游参考说明见 [`src/fanqie.koplugin/README.md`](src/fanqie.koplugin/README.md)。

## 开发

```bash
python3 scripts/package.py
```

发布包会写入 `dist/`，并排除 `config.lua`、`config.local.lua`、`fanqie_device.json`、Cookie、Token、日志、缓存、`.DS_Store` 和 `.luac`。

测试需要 Python 依赖 `lupa` 或原生 Lua 5.1/LuaJIT：

```bash
# 没有 lupa 时，先准备仓库外的本地测试依赖
python3 scripts/bootstrap_pylibs.py
python3 tests/run_tests.py
```

KOReader 真机上的扫码登录、正文 fallback、预下载和段评仍需在 Kindle/Android 设备上验收。

## 安全提示

`config.lua`、`fanqie_device.json`、Cookie、Token、日志和缓存都是运行时数据，不应提交到公开仓库。

## 许可证

MIT License。第三方参考项目和归属说明见 [`NOTICE.md`](NOTICE.md)。

## 致谢与参考项目

本项目参考了以下开源项目的插件骨架、接口分析、正文解析和 Android 调用链研究；它们不是本插件的运行时依赖，本项目使用独立的 Lua 实现。

- [hesan1232/fanqie.koplugin](https://github.com/hesan1232/fanqie.koplugin)：KOReader 插件骨架与界面流程。
- [ch6vip/fqapp](https://github.com/ch6vip/fqapp)：番茄 App 设备注册、正文接口和解密流程。
- [POf-L/Fanqie-novel-Downloader](https://github.com/POf-L/Fanqie-novel-Downloader)：移动端正文接口和客户端行为。
- [qianbkk/fanqie-novel-bypass](https://github.com/qianbkk/fanqie-novel-bypass)：正文接口和网页内容完整性验证。
- [zwb8926/fanqie-novel-vscode](https://github.com/zwb8926/fanqie-novel-vscode)、[fysh1010/mcp-server-fanqie](https://github.com/fysh1010/mcp-server-fanqie)、[qinggudao-yang/fanqie-harvest](https://github.com/qinggudao-yang/fanqie-harvest)：章节字段、正文解析和备用接口。
- [zhongbai2333/Tomato-Novel-Downloader](https://github.com/zhongbai2333/Tomato-Novel-Downloader)、[ZfxZephyr/Fanqie-novel-Downloader-CSharp-Rebuild](https://github.com/ZfxZephyr/Fanqie-novel-Downloader-CSharp-Rebuild)：正文请求和兼容处理。
- [imengying/unidbg](https://github.com/imengying/unidbg)：Android/native 调用链和设备注册流程研究；本插件不依赖 Unidbg 后端。

感谢上述项目作者公开协议分析、接口观察和实现经验。许可证和具体参考范围见 [`NOTICE.md`](NOTICE.md)。

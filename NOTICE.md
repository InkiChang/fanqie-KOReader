# NOTICE / 来源与致谢

本项目（`fanqie-KOReader`）是一个面向 KOReader 的番茄小说阅读插件。本文件记录运行时代码、协议分析和产品设计所参考的公开项目；这些项目不是本插件的运行时依赖，除非另有说明，本仓库没有复制其闭源二进制或服务端代码。

## 本项目的直接基础

| 项目 | 用途 | 许可证/说明 |
| --- | --- | --- |
| [hesan1232/fanqie.koplugin](https://github.com/hesan1232/fanqie.koplugin) | KOReader 插件骨架、界面流程、书架/目录/阅读进度和第三方书源兼容接口 | 以上游仓库公开许可证为准；本仓库在其基础上重构正文源和运行时身份流程 |
| [ch6vip/fqapp](https://github.com/ch6vip/fqapp) | 番茄移动端注册、请求字段、正文响应和设备画像的协议参考 | GPL-3.0；本仓库仅参考公开实现和可验证的数据结构，未复制其代码 |
| [POf-L/Fanqie-novel-Downloader](https://github.com/POf-L/Fanqie-novel-Downloader) | Android 客户端行为、正文接口和发布工程的参考 | 以其仓库许可证为准；未将其 Android 二进制作为插件依赖 |

当前插件的正文源只有两类：`official_app` 官方 App 源，以及 `official_proxy` 番茄 API 备用源。官方 App 源使用独立的 Android 设备画像，不读取 Kindle 型号或序列号；请求失败、返回空正文或明显过短的正文时，读取逻辑会继续尝试备用源。

## 正文解析与接口行为参考

以下项目用于交叉核对接口字段、正文解析、段评数据或客户端行为；本项目只保留独立的 Lua 实现：

- [zwb8926/fanqie-novel-vscode](https://github.com/zwb8926/fanqie-novel-vscode)
- [fysh1010/mcp-server-fanqie](https://github.com/fysh1010/mcp-server-fanqie)
- [qinggudao-yang/fanqie-harvest](https://github.com/qinggudao-yang/fanqie-harvest)
- [qianbkk/fanqie-novel-bypass](https://github.com/qianbkk/fanqie-novel-bypass)
- [zhongbai2333/Tomato-Novel-Downloader](https://github.com/zhongbai2333/Tomato-Novel-Downloader)
- [ZfxZephyr/Fanqie-novel-Downloader-CSharp-Rebuild](https://github.com/ZfxZephyr/Fanqie-novel-Downloader-CSharp-Rebuild)

这些项目帮助确认了正文接口的响应变体、HTML/转义文本的清洗边界、章节字段兼容和备用源的行为。本仓库没有把不稳定的网页正文接口注册为运行时源：实测该接口可能只返回截断内容或 HTML 转义片段。

## Android 设备身份、签名与解密研究

- [imengying/unidbg](https://github.com/imengying/unidbg)：用于理解 Android/native 调用链和设备注册流程的研究参考。本插件不嵌入 JVM/native 模拟器，也不依赖 Unidbg 后端。
- [ch6vip/fqapp](https://github.com/ch6vip/fqapp)：用于核对设备注册字段、请求签名和正文解密步骤；实现已在 Lua 中独立重写。

设备身份文件 `fanqie_device.json` 仅在运行时生成或读取，发布包会排除该文件、Cookie、Token、日志和缓存。番茄接口可能随时变更，相关实现不承诺长期稳定。

## 运行时依赖

| 依赖 | 说明 |
| --- | --- |
| [KOReader](https://github.com/koreader/koreader) | 宿主阅读器；插件通过运行时 `require` 调用其模块，不复制 KOReader 源码 |
| LuaJIT / Lua 5.1 | KOReader 使用的 Lua 运行时 |
| LuaFileSystem、LuaSocket | KOReader 内置的文件系统和 HTTP 支持 |

## 许可证与免责声明

本仓库代码以 MIT License 发布，除非文件或上游项目另有明确说明。第三方项目的版权和许可证归其各自作者所有，使用时请遵守对应条款。

本项目仅用于个人学习和在自有设备上的阅读便利，不提供、不托管、不分发小说正文。正文及封面版权归原作者、出版方和平台所有，请支持正版阅读。若权利方认为本项目侵犯其权益，请通过 [`SECURITY.md`](SECURITY.md) 联系维护者。

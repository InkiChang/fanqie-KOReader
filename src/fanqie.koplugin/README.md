# fanqie.koplugin

KOReader 插件，用于在 Kindle 等电纸书设备上阅读番茄小说。

当前版本：`0.0.2`

## 当前实现

插件现在只保留两个正文源，并按优先级自动 fallback：

| 顺序 | 源 | 用途 |
| --- | --- | --- |
| 1 | 官方 App 源（`official_app`） | 使用番茄移动端接口获取正文和段评；请求身份模拟为 Android 设备 |
| 2 | 番茄 API 备用源（`official_proxy`） | 官方 App 源失败时的备用正文接口 |

两个源默认都启用。正文请求会依次尝试启用的源，当前源失败后自动切换下一个源；网页正文源已移除，因为无法稳定返回完整章节内容。

## 功能

- 扫码登录番茄账号，获取书架、目录和阅读进度
- 官方 App 源优先、番茄 API 备用源自动 fallback
- 使用 Android 移动端请求参数获取完整章节正文
- 段评显示、段评详情和段落切换
- 章节缓存与离线阅读
- 预下载后续章节，可选择 `3`、`5` 或 `10` 章
- 书架、目录、下载管理和阅读进度同步
- 适配 KOReader 的黑白墨水屏界面

## 安装

1. 从 GitHub Releases 下载 `fanqie.koplugin-v*.zip`。
2. 解压后，将压缩包内的插件文件放入 KOReader 的 `plugins/fanqie.koplugin/` 目录。
3. 重启 KOReader。
4. 在菜单中打开「番茄书架」。
5. 首次使用时进入「扫码登录」，用番茄小说 App 扫码确认。

压缩包内的文件直接位于插件目录内容层级。最终路径应类似：

```text
koreader/plugins/fanqie.koplugin/main.lua
```

## 登录与运行时文件

正常使用只需要扫码登录，不需要手动填写 Cookie。扫码得到的 Cookie 会保存到 KOReader 数据目录中。

官方 App 源首次运行时需要一组 Android 设备身份，优先读取：

```text
<KOReader 数据目录>/fanqie_device.json
```

文件格式如下：

```json
{
  "install_id": "...",
  "device_id": "..."
}
```

如果文件不存在，插件会尝试用 Android 设备画像自动注册并保存身份。Kindle 的型号、序列号和其他硬件信息不会用于生成这组身份。不要把真实的 `fanqie_device.json`、Cookie 或日志提交到 GitHub。

## 段评

在「设置 → 段评显示」启用段评，然后重新获取当前章节或进入尚未缓存的章节。正文中的段评数量可以点击查看评论详情，数据会随章节缓存保存。实现使用真实段落索引和移动端接口返回的评论 ID，不依赖网页源标识。正文 fallback 到番茄 API 时，段评数据可能不可用。

## 缓存与预下载

在「设置 → 预下载章节数」中选择 `3`、`5` 或 `10`。该值会实际控制阅读时后台预下载的后续章节数量，不会写死为某个值。缓存命中时可以离线阅读，网络失败不会删除已有缓存。

## 可选配置

[`config.example.lua`](config.example.lua) 只包含不敏感的示例配置。复制为 `config.lua` 后按需要修改。扫码登录优先级高于配置文件中的 Cookie；个人 `config.lua` 已被 `.gitignore` 排除。

## 开发与打包

项目是普通 KOReader Lua 插件，不需要 Android 模拟器或额外后端。请在仓库根目录运行：

```bash
python3 scripts/package.py
```

脚本会生成 `dist/fanqie.koplugin-v<版本>.zip` 和对应的 `.sha256` 文件，且自动检查顶层目录、必需文件和敏感文件排除情况。发布包不应包含 Cookie、`config.lua`、`fanqie_device.json`、日志、缓存、`.DS_Store` 或 Lua 编译产物。

测试需要 Python 依赖 `lupa` 或原生 Lua 5.1/LuaJIT；测试和真机验收说明见仓库根目录的 `docs/TESTING.md`。

## 上游参考

本项目借鉴了以下项目中的协议分析、数据结构和实现思路；它们不是运行时依赖：

- [ch6vip/fqapp](https://github.com/ch6vip/fqapp)
- [POf-L/Fanqie-novel-Downloader](https://github.com/POf-L/Fanqie-novel-Downloader)
- [hesan1232/fanqie.koplugin](https://github.com/hesan1232/fanqie.koplugin)
- [qianbkk/fanqie-novel-bypass](https://github.com/qianbkk/fanqie-novel-bypass)
- [zwb8926/fanqie-novel-vscode](https://github.com/zwb8926/fanqie-novel-vscode)
- [fysh1010/mcp-server-fanqie](https://github.com/fysh1010/mcp-server-fanqie)
- [qinggudao-yang/fanqie-harvest](https://github.com/qinggudao-yang/fanqie-harvest)
- [imengying/unidbg](https://github.com/imengying/unidbg)
- [zhongbai2333/Tomato-Novel-Downloader](https://github.com/zhongbai2333/Tomato-Novel-Downloader)
- [ZfxZephyr/Fanqie-novel-Downloader-CSharp-Rebuild](https://github.com/ZfxZephyr/Fanqie-novel-Downloader-CSharp-Rebuild)

## 常见问题

### 官方 App 源提示设备身份缺失或注册失败

确认数据目录下存在有效的 `fanqie_device.json`，或者允许插件自动注册。保持番茄 API 备用源启用可继续 fallback。不要使用 Kindle 型号信息代替 Android 设备身份。

### 为什么没有网页源

网页接口对部分章节只返回截断内容或 HTML 转义片段，无法稳定获取完整正文，因此已从运行时源注册表中移除。

### 章节只下载一章

后台预下载数量由「设置 → 预下载章节数」控制。选择 `3`、`5` 或 `10` 后，新触发的任务会使用对应数量。

### 段评不显示

确认已开启「设置 → 段评显示」，并重新获取章节正文。已缓存的纯正文不会因打开段评开关而自动重复下载。

## 许可证

MIT License

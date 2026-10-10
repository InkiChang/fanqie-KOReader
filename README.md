# 番茄小说 KOReader 插件

在 **KOReader** 里阅读**番茄小说**：扫码登录、书架同步、逐章阅读、阅读进度回传，全部在设备本地完成。

> 目标设备是**越狱 Kindle**。插件为**纯 Lua**，只依赖 KOReader 自带模块，不需要电脑中转、也不需要另外运行桌面程序。

---

## 功能

| 功能 | 说明 |
|---|---|
| **扫码登录** | 插件内直接显示二维码，用番茄小说 App 扫码登录，登录态保存在本机 |
| **书架** | 读取账号书架，显示书籍、封面与阅读进度 |
| **阅读** | 逐章取回正文并缓存（内存 + 磁盘两层），支持翻章与进度回传 |
| **段评** | 正文段落末尾显示段评条数气泡，点开查看该段真实评论（正文 / 用户名 / 点赞数） |
| **预下载** | 读到某章时后台预下后续 N 章（1 / 3 / 5 / 10 可选），切章不再等待 |
| **进度同步** | 阅读进度回传服务器，与 App 保持一致 |
| **墨水屏适配** | 黑白显示、翻页无闪烁，字号行距跟随 KOReader 全局设置 |

## 环境要求

- KOReader（较新版本即可，插件只使用其内置模块）
- 一台越狱的 Kindle；或 Android / Linux 上的 KOReader（用于调试）
- 网络：可访问番茄小说的接口

## 安装

1. 把整个 `fanqie.koplugin` 目录拷贝到 KOReader 的插件目录：

   | 平台 | 插件目录 |
   |---|---|
   | Kindle / 多数设备 | `<KOReader 数据目录>/plugins/` |
   | Android | `/storage/emulated/0/koreader/plugins/` |

   最终结构应为 `<插件目录>/fanqie.koplugin/main.lua`。

2. 重启 KOReader。
3. 在 KOReader 的**文件浏览器 → 工具菜单**里找到「番茄小说」并启用。
4. 首次使用选择「扫码登录」，用番茄小说 App 扫描屏幕上的二维码。

> 登录凭据只保存在**本机**配置里。请勿把配置文件提交到仓库，也不要贴进公开日志。

## 配置

插件使用 KOReader 的配置机制保存设置（字段说明见 `src/fanqie.koplugin/config.example.lua`）。
常用可调项：

- `cookies.ttwid` / `cookies.sessionid`：按 Cookie 名分别填写（通常由扫码登录自动写入）
- `cache.pre_download_chapters`：预下载章节数（1 / 3 / 5 / 10）
- `para_review_enabled`：段评开关
- `advanced.developer_logs`：开发者日志（排查问题时打开）

**安全提示**：含真实 Cookie / Token 的配置文件已在 `.gitignore` 中排除，请勿强制提交。

## 目录结构

```
src/fanqie.koplugin/     插件本体（KOReader 直接加载）
  main.lua               入口、菜单、阅读流程
  fanqie/                取文、登录、签名、缓存、段评等模块
  patches/               对 KOReader 的最小猴补丁
tests/                   测试（向量与集成用例）
scripts/                 向量生成、打包等开发脚本
tools/                   辅助工具
docs/                    接口与架构说明
```

## 开发与测试

```bash
# 运行全部测试（需要 Python 3 与 lupa）
python tests/run_tests.py

# 打包插件目录
make package
```

当前状态：**68 通过 / 0 失败**（签名向量、密钥交换、接口契约与正文清洗）。

## 免责声明

- 本项目仅供**个人学习与自用**，用于在自己的设备上访问自己账号的内容；
- 项目**不提供、不分发**任何小说内容，内容均实时来自官方接口；
- 请遵守番茄小说的用户协议，并**支持正版阅读**；
- 使用本插件产生的任何后果由使用者自行承担。

## 致谢

插件的关键部分——尤其是**签名算法、密钥交换与接口协议**——能够与官方实现对齐，
离不开下面这些公开项目的启发与交叉验证。它们**仅作为协议与接口规格的参考**，
本项目**没有复制其代码**：

- **[fqapp](https://github.com/ch6vip/fqapp)** —— 接口路径、参数组合与协议行为的可靠参照
  （例如评论接口的 `business_param` 结构与参数组）；本项目按其公开规格自行实现；
- **[Fanqie-novel-Downloader](https://github.com/POf-L/Fanqie-novel-Downloader)** ——
  在接口常量与字段命名上提供了旁证；
- **[kindle-forge](https://github.com/ch6vip/kindle-forge)** —— 段评气泡的
  **全局占位符替换方案**参考自该项目；
- **[KOReader](https://github.com/koreader/koreader)** —— 本插件运行于其上，
  猴补丁与事件机制均依赖其稳定接口。

也感谢所有在签名、加密与请求协议上公开过分析与讨论的人。

## 许可

见 [LICENSE](LICENSE)；第三方项目的署名与许可说明见 [NOTICE.md](NOTICE.md)。

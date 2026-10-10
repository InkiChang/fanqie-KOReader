# 数据源与接口

> 本文回答一个问题：**为什么现在抓不到正文，以及要换成什么接口。**

---

## 0. 结论

| | 现有实现（上游 v2.2.0） | 目标实现 |
| --- | --- | --- |
| 基站 | Web 端 `https://fanqienovel.com` | 移动端 `https://api5-normal-*.fqnovel.com` |
| 例证 | `fanqie/fanqie.lua:7` `FanQie.BASE_URL` | 见 §3.2 |
| 设备身份 | 无 | `install_id` + `device_id`（§3.1） |
| UA | 桌面 Chrome（`fanqie/fanqie.lua:5`） | 模拟 Android 设备（`?` 有 `MOBILE_UA` 但当前主路径未用） |
| 正文 | `fanqie/fanqie.lua:58` `/api/reader/chapter/content` | `reader/full/v/` 系列（§3.2） |

核心判断：**Web 端即使带着合法 `sessionid`，正文接口也返回空/受限内容。**
移动端 API 之所以能拿到正文，靠的不是"账号已登录"这一件事，而是
**"账号 + 已注册设备"** 两件事——设备注册这一环现在完全缺失。

---

## 2. 两套接口的差异（已实测对比）

| 维度 | Web 端（现状） | 移动端（目标） |
| --- | --- | --- |
| 域名 | `fanqienovel.com` | `api5-normal-hl.fqnovel.com`<br>`api5-normal-lf.fqnovel.com`<br>`api5-normal-sinfonlinec.fqnovel.com`<br>备用：`reading.snssdk.com` |
| 设备注册 | ❌ 无 | ✅ `https://i.snssdk.com/service/2/device_register/` |
| 认证材料 | `sessionid` cookie | `install_id` + `device_id` + `sessionid` cookie |
| 书架 | `/reading/bookapi/bookshelf/info/v`<br>`/api/bookshelf/multidetail` | 同上，另有 `add/v`、`check/v`、`delete/v`、`update/v` |
| 阅读进度 | `/api/reader/book/progress`<br>`/api/reader/book/update_progress` | 同上，另有 `batch_update_progress`、`read_item_list`、`read_progress/upload/v` |
| 目录 | `/api/reader/directory/detail` | 同上，另有 `/reading/bookapi/directory/all_items/v` |
| 正文 | `/api/reader/chapter/content` | `reader/full/v/`（单章）、`reader/batch_full/v/`（批量） |
| 设备参数 | `aid`、`iid`、`version_code` 等（`fanqie/fanqie.lua:29`） | 全套安卓设备画像（§3.1） |

---

## 3. 移动端接口清单

以下路径来自对本机已安装的桌面版 `fanqie-desktop.exe` 做 UTF-8 字节串扫描的结果——
**它们是这个程序实际会请求的路径**，比任何第三方文档都可靠。

### 3.1 设备注册

```
POST https://i.snssdk.com/service/2/device_register/?tt_data=<...>
```

注册成功后拿到一对稳定标识，之后**所有业务请求都要带上它们**：

| 字段 | 说明 |
| --- | --- |
| `install_id` | 安装标识，形如 16 位十进制数字串 |
| `device_id` | 设备标识，同样形如 16 位十进制数字串 |
| `cdid` | 客户端生成的 UUID |
| `openudid` | 客户端生成的 16 位十六进制串 |

注册结果应当**持久化到插件配置目录**，跨启动复用；只有被服务端拒绝时才重新注册。
「设备身份每次重启都变」会导致登录态与应用内进度看起来莫名其妙地丢失。

设备画像（模拟小米 MI 9，这些字段要一并送上）：

| 字段 | 值 |
| --- | --- |
| `device_type` / `device_brand` | `MI 9` / `Xiaomi` |
| `os_version` / `os_api` | `11` / `29` |
| `host_abi` | `armeabi-v7a` |
| `resolution` / `dpi` | `1280*720` / `240` |
| `rom_version` | `L8E1.226024.33956602+release-keys` |
| `language` / `channel` | `zh` / `43536163a` |
| `version_code` / `version_name` | `72332` / `7.2.3.32` |
| `dragon_device_type` / `is_android_pad_screen` | `pad` / `1` |

> ⚠️ **本仓库不提交任何真实 `install_id` / `device_id`。** 它们属于本机凭据，
> 只应存在于开发者本地的配置文件里，由插件首次运行时自行注册获得。
> 本文刻意只描述字段形状。

### 3.2 业务接口（按用途分组）

```
# 书架
/reading/bookapi/bookshelf/info/v
/reading/bookapi/bookshelf/add/v
/reading/bookapi/bookshelf/check/v
/reading/bookapi/bookshelf/delete/v
/reading/bookapi/bookshelf/update/v
/api/bookshelf/multidetail

# 阅读进度
/api/reader/book/progress
/api/reader/book/update_progress
/api/reader/book/batch_update_progress
/api/reader/book/read_item_list
/reading/bookapi/read_progress/upload/v
/reading/bookapi/read_history/update/v
/reading/bookapi/last_page/get_user_book_duration/v

# 目录 / 详情
/api/reader/directory/detail
/reading/bookapi/directory/all_items/v
/reading/bookapi/detail/v/
/api/book/simple/info

# 正文（关键）
/reading/reader/full/v/
/reading/reader/batch_full/v/

# 账号
/api/user/info/v
/passport/user/login/
/passport/user/logout/
/passport/user/privilege/add/v

# 搜索
/reading/bookapi/search/tab/v
/search/api/novel/channel/homepage/search/search/v

# 段评
/novel/commentapi/comment/add|list|update/v
/novel/commentapi/idea/list/
/book/reading/ugc/novel_comment/rank_book/v/
/book/reading/ugc/person_comment/book/v/
```

> **正文接口仍需确认**：`reader/full/v/` 与 `reader/batch_full/v/` 是从二进制里
> 扫出来的候选，其**确切参数名与响应结构尚未在本机验证**。
> 实现时应当先写一个只读的探针脚本（`tools/` 下）把响应落盘看清楚，
> 再写解析代码——不要凭猜测写解析。

---

## 4. 实现计划（模块级）

改动集中在**新增一个数据源层**，而不是把现有代码到处改：

```
fanqie/fanqie.lua       # 保留：URL 构造，改为按"数据源"产生不同 BASE_URL
fanqie/device.lua       # 新增：设备注册 + 画像持久化（纯逻辑，可测）
fanqie/mobile.lua       # 新增：移动端请求头组装 + 响应解析（纯逻辑，可测）
fanqie/client.lua       # 改：把请求发送抽象成可注入的传输层，便于测试
fanqie/sources.lua      # 改：注册"官方移动端"为默认源，第三方源降级为备用
```

设计约束：

- **`device.lua` 与 `mobile.lua` 必须零 UI 依赖**，这样设备注册的字段组装、
  响应解析、失败重试都能在 `tests/` 里断言（见 `docs/TESTING.md` 的 L1 层）。
- 请求发送必须走**可注入的传输函数**，测试用 `require("koreader").net.set_transport(fn)`
  替掉真实网络。这个能力已经就绪。
- 数据源要能**随时切回 Web 端**。移动端接口是逆向来的，随时可能变；
  一旦失效，用户至少要能退回"能用但功能少"的状态，而不是彻底不能用。

---

## 5. 备用数据源（不删）

上游已支持晴天书源（`fanqie/fanqie.lua:8` `QINGTIAN_DEFAULT_URL`）。它在
`fanqie/sources.lua:135` 的注释里被定位为"官方源之后的兜底"。

**保留它的理由**：官方移动端接口是逆向的，一旦番茄调整签名或风控，
官方源会整体失效。此时第三方源至少还能让用户读书。
`fanqie/sources.lua:135` 的注释已经说明官方源"always available as fallback"，
目标状态是要让**两边的兜底关系对称**——谁能用就用谁，而不是把用户卡死。

---

## 6. 风险与边界

- **接口会变**：移动端 API 没有公开文档，路径/参数/签名都可能在任何一次
  番茄客户端更新后改变。这是这条技术路线的固有成本，不是实现缺陷。
- **频率**：批量抓正文必须限速，否则会触发风控（现有代码里已有
  `rate_info` / `get_chapter_content_with_fallback` 的限流记录机制，见
  `fanqie/client.lua:1692`，应当沿用并加强）。
- **账号安全**：插件只在本机保存登录 Cookie 与设备标识，不上传任何东西到第三方。
  这一点应当在 `SECURITY.md` 与 README 里对用户明示。
- **合规**：本项目是个人自用性质的阅读客户端。使用者需自行遵守番茄小说的
  用户协议与所在地区法律；仓库不提供任何内容下载服务，也不分发任何小说文本。

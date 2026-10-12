# 数据源与接口说明

本文记录 `0.0.2` 当前实现使用的数据源、设备身份和正文 fallback 行为。接口是运行时实现细节，番茄可能随时调整；请以源码和真机测试为准。

## 当前正文源

插件正文请求按优先级尝试两个源：

1. `official_app`：官方移动端接口。请求使用插件自动注册或本机持久化的 Android 设备身份，并复用官方 App 的签名、registerkey、批量正文解密和 gzip 处理。
2. `official_proxy`：番茄 API 备用源。官方 App 源抛错、响应为空或正文过短时接管请求。

两个源默认启用，`fanqie/sources.lua` 中的 `order` 控制顺序。网页正文源已移除，因为实测只能返回截断正文或 HTML 转义片段。

## Android 设备身份

官方 App 源需要 `install_id` 与 `device_id`。插件不会从 Kindle 型号、序列号或其他硬件信息生成身份，而是：

- 优先读取 `<KOReader 数据目录>/fanqie_device.json`；
- 没有文件时尝试使用 Android 设备画像注册；
- 注册成功后持久化身份，后续启动复用；
- 也可以在官方 App 源设置中手动填写这两个字段。

真实设备身份属于运行时凭据，不得提交到 GitHub、日志或发布包。

## 官方 App 正文链路

正文链路由 `fanqie/client.lua` 和 `fanqie/app_legacy.lua` 负责：

1. 组装 Android 移动端公共参数和签名请求。
2. 获取或复用 `registerkey`。
3. 请求 `reading/reader/batch_full/v`，支持按章读取和批量读取。
4. 对响应正文做 AES-CBC 解密、PKCS#7 去填充和 gzip 解压。
5. 清洗 HTML 标记，返回 KOReader 使用的纯文本正文。

签名、加密和设备注册模块均为插件内纯 Lua 实现，不依赖额外后端。

## 备用 API 正文链路

备用源通过 `official_proxy_get_content` 访问配置的番茄 API 地址，并尝试多个兼容端点。解析器支持常见的 `content`、`text`、`chapter_content`、`chapterContent` 和嵌套 `data` 字段，随后清洗 HTML 转义和段落标签。

备用源只负责正文；官方账号的书架、目录、阅读进度和扫码登录仍走插件已有的官方账号流程。

## 段评与缓存

官方 App 源返回章节段评索引和评论 ID，`content.lua` 会随章节缓存 `paragraph_index`、数量和评论 ID。正文 fallback 到备用 API 时可能没有段评数据。预下载数量由设置页的 `3`、`5`、`10` 选项传入，不在接口层写死。

## 风险

移动端接口和第三方 API 都没有稳定的公开兼容承诺。接口变化时请先记录请求和响应样本，再修改解析代码；不要把 Cookie、Token、设备身份或完整响应写入公开 issue。

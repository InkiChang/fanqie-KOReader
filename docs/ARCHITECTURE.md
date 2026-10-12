# 架构说明

## 当前阅读链路

插件仍按 KOReader 兼容性要求采用“逐章 HTML”阅读流程：

1. `main.lua` 创建设置和客户端对象。
2. `client.lua` 获取目录，并按 `sources.lua` 的顺序请求正文。
3. `content.lua` 清洗正文、处理图片和段评索引，将章节保存为缓存 HTML。
4. `reader_navigation.lua` 打开当前章节，翻章时复用缓存或触发下一次正文 fallback。
5. `patches/core.lua` 只负责 KOReader 的章节导航和段评链接交互。

整本书不是一个 EPUB 文档；当前发布说明不把未接入的 EPUB 生成方案当作功能。

## 数据源边界

数据源调度集中在 `fanqie/client.lua:get_chapter_content_with_fallback`：

- `official_app` 负责 Android 设备画像、官方移动端签名、正文解密和官方段评。
- `official_proxy` 负责第三方番茄 API 备用正文。
- 任一源返回空正文、正文过短或抛出错误，调度器继续尝试下一个启用源。
- `fanqie/sources.lua` 保存注册表和顺序；两个源默认启用。

书架、目录、扫码登录、阅读进度和账号 Cookie 仍由插件的官方账号模块管理，和正文源调度分开。

## 运行时数据

运行时数据存放在 KOReader 数据目录，不进入源码目录：

- `fanqie.lua`：插件设置、Cookie、源开关和预下载数量。
- `fanqie_device.json`：Android 设备身份。
- 缓存目录：章节 HTML、图片、段评索引和书架缓存。
- `fanqie.log`：可选开发者日志。

发布包和 Git 忽略规则排除这些数据。设备身份必须跨启动复用，但不能从 Kindle 硬件字段推导。

## 维护原则

- 纯逻辑模块尽量不依赖 KOReader UI，签名、压缩、解密和正文解析可以单独检查。
- 不把真实 Cookie、Token、设备身份或小说正文样本提交到仓库。
- 接口调整先记录响应结构，再修改解析代码；移动端源失效时保留备用 API 的可用性。
- 不新增额外后端；插件直接访问官方移动端接口和番茄 API 备用源。

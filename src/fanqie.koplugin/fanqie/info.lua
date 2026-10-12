-- 插件元信息集中管理：版本号、描述、关于文案
-- 所有需要展示版本/关于的地方统一从这里读取，避免多处维护不同步。
--   - main.lua: require("fanqie.info") 读取 version 和 about_template
--   - _meta.lua: pcall(require, "fanqie.info") 读取 version 和 description
--
-- about_template 用 T() 格式化，占位符：
--   %1 = 版本号（self.version）
--   %2 = 缓存目录（self.settings:get_download_dir()）

local ok_gettext, gettext = pcall(require, "gettext")
local _ = ok_gettext and gettext or function(text) return text end

return {
    -- 版本号（唯一来源，main.lua 和 _meta.lua 都读这里）
    version = "0.0.2",

    -- 插件描述（_meta.lua 的 description 字段使用）
    description = _("在 KOReader 中阅读番茄小说，支持扫码登录、官方 App 源、番茄 API 备用源、段评、缓存和进度同步。"),

    -- 关于文案模板：main.lua 两处「关于」对话框共用
    -- 修改文案只需改这一处，两处关于对话框自动同步
    about_template = _("番茄小说插件 v%1\n\n为 KOReader 打造的墨水屏阅读体验，适配黑白电子墨水屏。\n\n核心特性:\n• 扫码登录: 自动获取书架/进度/目录\n• 双源正文: 官方 App 源优先，番茄 API 自动 fallback\n• Android 设备画像: 不读取 Kindle 硬件信息生成身份\n• 段评功能: 章节段落评论，真实段落索引，开关常驻设置页\n• 异步引擎: 目录获取/章节下载/进度上传均在子进程执行\n• 缓存与预下载: 支持 3、5、10 章设置，支持离线阅读\n• 智能回退: 网络失败保留旧缓存，Cookie 过期不丢失数据\n\n下载格式: HTML\n缓存目录: %2"),
}

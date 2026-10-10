-- FanQie Plugin Configuration
-- Copy this file to config.lua and modify the values below

return {
    -- Cookie 保底配置（可选）：扫码登录优先，以下字段仅在未扫码时作为 fallback。
    -- 正常使用无需填写，菜单 → 番茄小说 → 扫码登录即可自动获取并持久化 Cookie。
    -- 如需手动填写：从浏览器复制 Cookie 字符串填入 cookie_string，
    -- 或在 cookies 表里填入 ttwid / sessionid 等键值。
    cookie_string = "",

    cookies = {
        ["ttwid"] = "",
        ["sessionid"] = "",
    },

    -- 晴天聚合服务器配置（仅用于获取正文，目录和书架仍使用官方API）
    qingtian = {
        -- 晴天服务器地址
        server_url = "https://v1.gyks.cf/",
        -- 可用服务器列表（自动检测时按顺序尝试）
        servers = {
            "https://v1.gyks.cf",
            "https://v2.gyks.cf",
            "https://v3.gyks.cf",
            "https://v4.gyks.cf",
        },
        -- 晴天账号（邮箱）
        username = "",
        -- 晴天密码
        password = "",
        -- token（登录后自动获取，无需手动填写）
        token = "",
        -- 设备ID（自动生成，无需手动填写）
        device_id = "",
        -- 是否自动登录（当 token 过期时自动重新登录）
        auto_login = true,
        -- 请求频率限制
        rate_limit = {
            max_requests = 5,      -- 最大请求数
            window_seconds = 30,   -- 时间窗口（秒）
        },
    },

    -- 大灰狼聚合服务器配置
    -- 可用后端地址（任选其一，程序会自动检测可用线路）：
    --   https://v2.czyl.cf
    --   https://v4.czyl.cf
    --   https://v5.czyl.cf
    --   https://v7.czyl.cf
    --   https://v8.czyl.cf
    --   https://v9.czyl.cf
    --   https://v10.czyl.cf
    dahuilang = {
        -- 大灰狼服务器地址（默认使用第一个可用线路）
        server_url = "https://v2.czyl.cf",
        -- 可用服务器列表（自动检测时按顺序尝试）
        servers = {
            "https://v2.czyl.cf",
            "https://v4.czyl.cf",
            "https://v5.czyl.cf",
            "https://v7.czyl.cf",
            "https://v8.czyl.cf",
            "https://v9.czyl.cf",
            "https://v10.czyl.cf",
        },
        -- 大灰狼账号（邮箱）
        username = "",
        -- 大灰狼密码
        password = "",
        -- 大灰狼密钥（可选，优先于账号密码登录）
        key = "",
        -- token（登录后自动获取，无需手动填写）
        token = "",
        -- 设备ID（自动生成，无需手动填写）
        device_id = "",
        -- 是否自动登录（当 token 过期时自动重新登录）
        auto_login = true,
        -- 原始书源（番茄/七猫/塔读等）
        source = "番茄",
        -- 请求频率限制
        rate_limit = {
            max_requests = 5,      -- 最大请求数
            window_seconds = 30,   -- 时间窗口（秒）
        },
    },

    sync = {
        pull_on_open = true,
        upload_on_close = true,
    },

    cache = {
        download_book_images = true,
        pre_download_chapters = 3,
        pre_download_groups = 2,
        -- 整书 EPUB：已缓存的章节达到 single_epub_min_chapters 时，
        -- 打开流程会把它们组装成一个 EPUB 再打开（不再是"一章一本书"）。
        -- 设 single_epub = false 可退回逐章 HTML。
        single_epub = true,
        single_epub_min_chapters = 2,
        single_epub_max_chapters = 3000,
    },

    reading = {
        max_level = 1000,
        min_level = 1,
        auto_navigate = true,
        auto_navigate_delay = 0,
        disable_double_tap_navigation = false,
        enable_reflow = false,
        sync_bookmark = true,
        sync_annotation = true,
        sync_reading_progress = true,
        sync_calendar = true,
        sync_notebook = true,
    },

    -- 关于日志：日志开关**不在 config.lua 里**，而是插件菜单里的
    --   菜单 → 番茄小说 → 设置 → 开发者日志
    -- （settings 里的 advanced.developer_logs，默认关闭；关闭时只写 WARN/ERROR）
    -- 日志文件在缓存目录的上一级：<缓存目录的父目录>/fanqie.log
    --
    -- 这里原先放着 dump_network / log_request / log_response / log_session /
    -- log_error / log_level 六个键，但代码里没有任何地方读它们——照它改配置不会有
    -- 任何效果。已删除，避免误导。若将来真要做网络报文转储，请连同实现一起加。
    layout = {
        reading_font_size = 0,
        reading_line_height = 0,
        reading_text_alignment = 0,
        reading_margin_top = 0,
        reading_margin_bottom = 0,
        reading_margin_left = 0,
        reading_margin_right = 0,
    },

    notification = {
        enabled = true,
        duration = 3,
    },

    experimental = {
        enable_new_sync = false,
        enable_new_api = false,
    },
}
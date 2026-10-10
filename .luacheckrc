-- luacheck 配置：面向 KOReader 插件运行时（LuaJIT / Lua 5.1 语义）
std = "lua51"

max_line_length = false
unused_args = false
allow_defined_top = true

-- KOReader 在应用初始化时注入的全局量。
-- 这份清单要跟着实际用法走：声明了用不到的会掩盖拼写错误，
-- 漏掉实际在用的则会产生噪声告警（CI 里目前是软失败，但噪声会让人不看输出）。
--   Event             ui/event.lua 由 KOReader 注入为全局
--   DEBUG             KOReader 的调试构建标记
--   G_reader_settings KOReader 的全局阅读设置（patches/core.lua 用它判断插件是否被禁用）
globals = {
    "Event",
    "DEBUG",
    "G_reader_settings",
}

-- 忽略的告警码（逐条给出理由，避免"一把梭"式静默）：
--   212/self  : 内部工具函数把 self 当普通参数传，误报率高
--   542       : 空 if 分支在 KOReader 的"能力探测"写法里是常见模式
--   581       : 未使用的参数在回调签名里是必要的占位
ignore = {
    "212/self",
    "542",
    "581",
    "611",   -- 空行含空白字符（Windows 编辑器残留，交给 .editorconfig 兜底）
}

-- 测试基座与桩代码不参与插件自身的静态检查
exclude_files = {
    "tests/**/*.lua",
    "tools/**",
    "refs/**",
}

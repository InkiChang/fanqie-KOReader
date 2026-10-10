--- cookie.lua 的用例集。
--
-- 为什么先测它：这一层是"登录态"的唯一入口，而且完全无依赖（整份 103 行不 require
-- 任何模块），是最适合钉死行为的地方。它同时守着一个很隐蔽的坑——Set-Cookie 的
-- Expires 属性合法含有逗号，而 LuaSocket 会把多个 Set-Cookie 合并成一个逗号串。

local Cookie = require("fanqie/cookie")
local T = require("tap")

T.test("cookie.parse_cookie_header 解析常规 Cookie 头", function(t)
    local c = Cookie.parse_cookie_header("sessionid=abc123; ttwid=xyz; odin_tt=qq")
    t:eq(c.sessionid, "abc123", "第一个键值对")
    t:eq(c.ttwid, "xyz", "第二个")
    t:eq(c.odin_tt, "qq", "第三个")
end)

T.test("cookie.parse_cookie_header 容忍前缀与分号后的空白", function(t)
    t:eq(Cookie.parse_cookie_header("Cookie:  sessionid=v1 ").sessionid, "v1",
        "带 'Cookie:' 前缀、值后有空格也能解析")
    t:eq(Cookie.parse_cookie_header("  sessionid=v3").sessionid, "v3", "前导空白")
    t:eq(Cookie.parse_cookie_header("a=1;  b=2").b, "2",
        "分号后的多个空格由 ^%s* 吃掉")
    t:eq(Cookie.parse_cookie_header("cookie:x=9").x, "9", "小写前缀")
end)

T.test("cookie.parse_cookie_header 对空输入返回空表而不是 nil", function(t)
    -- 调用方普遍写 `for k in pairs(Cookie.parse_cookie_header(x))`，
    -- 返回 nil 会让上层直接崩，所以空表是契约的一部分。
    t:eq(type(Cookie.parse_cookie_header(nil)), "table", "nil 输入")
    t:eq(next(Cookie.parse_cookie_header("")), nil, "空串输入 → 空表")
    t:eq(next(Cookie.parse_cookie_header("   ")), nil, "全空白 → 空表")
end)

T.test("cookie.parse_cookie_header 忽略没有等号的片段", function(t)
    local c = Cookie.parse_cookie_header("good=1; flag; also_good=2")
    t:eq(c.good, "1", "正常项保留")
    t:eq(c.also_good, "2", "坏项之后的正常项不受影响")
    t:eq(c.flag, nil, "无等号片段不产生键")
end)

T.test("cookie.to_header 输出稳定顺序", function(t)
    -- 顺序必须稳定（内部 table.sort），否则每次请求的 Cookie 头都不同，
    -- 会让基于请求签名的服务端风控与快照测试都不稳定。
    t:eq(Cookie.to_header({ z = "1", a = "2", m = "3" }), "a=2; m=3; z=1",
        "按键名排序并以 '; ' 连接")
    t:eq(Cookie.to_header({}), "", "空 cookie 返回空串")
    t:eq(Cookie.to_header(nil), "", "nil 也返回空串")
end)

T.test("cookie.to_header 与 parse_cookie_header 可往返", function(t)
    local original = { sessionid = "7541813009765633048", ttwid = "sF1rZ" }
    local round = Cookie.parse_cookie_header(Cookie.to_header(original))
    t:eq(round.sessionid, original.sessionid, "值往返一致")
    t:eq(round.ttwid, original.ttwid, "第二个值往返一致")
end)

T.test("cookie.merge_set_cookie 只取 cookie 名值对，丢弃属性", function(t)
    -- 属性被当成 cookie 存下来的后果很脏：Cookie 头会带上 "Path=/"、
    -- "Domain=..."，服务端可能直接判为异常请求。
    local c = Cookie.merge_set_cookie({}, "sessionid=abc123; Path=/; Domain=.fqnovel.com; HttpOnly")
    t:eq(c.sessionid, "abc123", "cookie 值正确")
    t:eq(c.Path, nil, "Path 不应被持久化")
    t:eq(c.Domain, nil, "Domain 不应被持久化")
    t:eq(c.HttpOnly, nil, "HttpOnly 不应被持久化")
end)

T.test("cookie.merge_set_cookie 保护 Expires 里的逗号", function(t)
    -- 本文件最容易写错的一处：LuaSocket 会把两行 Set-Cookie 合并为
    --   "a=1; Expires=Mon, 01 Jan 2026 00:00:00 GMT, b=2"
    -- 若直接按逗号切分，Expires 会被切成两半，还会产生垃圾键。
    local c = Cookie.merge_set_cookie({},
        "a=1; Expires=Mon, 01 Jan 2026 00:00:00 GMT, b=2")
    t:eq(c.a, "1", "第一个 cookie 保住")
    t:eq(c.b, "2", "逗号之后的第二个 cookie 也要保住")
    t:eq(c.Expires, nil, "Expires 自身不应成为 cookie")
    t:eq(c["01 Jan 2026 00:00:00 GMT"], nil, "被切开的日期残片不应成为键")
end)

T.test("cookie.merge_set_cookie 支持换行分隔与表输入", function(t)
    local c = Cookie.merge_set_cookie({}, "x=1\r\ny=2")
    t:eq(c.x, "1", "换行分隔的第一个")
    t:eq(c.y, "2", "换行分隔的第二个")

    local from_table = Cookie.merge_set_cookie({}, { "p=10", "q=20" })
    t:eq(from_table.p, "10", "表输入的第一个")
    t:eq(from_table.q, "20", "表输入的第二个")
end)

T.test("cookie.merge_set_cookie 覆盖旧值且不改动无关键", function(t)
    local c = { keep = "old", sessionid = "stale" }
    Cookie.merge_set_cookie(c, "sessionid=fresh")
    t:eq(c.sessionid, "fresh", "同名 cookie 应被覆盖")
    t:eq(c.keep, "old", "无关键不受影响")

    t:eq(Cookie.merge_set_cookie(nil, nil), nil, "nil 输入原样返回")
    local empty = {}
    t:eq(Cookie.merge_set_cookie(empty, ""), empty, "空串输入返回同一张表")
end)

T.test("cookie.has_login_cookie 以值长度判据区分真登录与空 cookie", function(t)
    -- 未登录时番茄也会下发 ttwid 之类的短值甚至空值；把空值当登录会让插件
    -- 在"已登录"状态下发起必然 401 的请求，用户看到的是"书架空白"而不是
    -- "请先登录"，排障成本极高。
    t:ok(not Cookie.has_login_cookie(nil), "nil 未登录")
    t:ok(not Cookie.has_login_cookie({}), "空表未登录")
    t:ok(not Cookie.has_login_cookie({ sessionid = "" }), "空值未登录")
    t:ok(not Cookie.has_login_cookie({ sessionid = "abc" }), "过短的值不算登录")
    t:ok(Cookie.has_login_cookie({ sessionid = "12345678" }), "正好 8 位算登录")
    t:ok(Cookie.has_login_cookie({ a = "", sessionid = "0123456789abcdef" }),
        "同一张表里只要有一个够长的值就算")
end)

T.test("cookie.extract_from_curl 适配浏览器复制出来的 cURL", function(t)
    -- 这是用户的常见路径：从浏览器 devtools 复制 "Copy as cURL" 再粘进插件。
    local cookie = Cookie.extract_from_curl(
        [[curl 'https://fanqienovel.com/api/reader/directory/detail?bookId=7351' -H 'Cookie: sessionid=abc123; ttwid=xyz' -H 'User-Agent: Mozilla/5.0']])
    t:eq(cookie, "sessionid=abc123; ttwid=xyz", "抽到 Cookie 头内容")

    local cookie_b, data_b = Cookie.extract_from_curl(
        [[curl 'https://x/y' -b 'sessionid=fromb' --data-raw '{"book_id":"7351"}']])
    t:eq(cookie_b, "sessionid=fromb", "-b 形式")
    t:eq(data_b, '{"book_id":"7351"}', "--data-raw 形式")
end)

T.test("cookie.extract_from_curl 对空输入返回空串而不是 nil", function(t)
    -- 上层会直接把它丢给 parse_cookie_header；返回 nil 虽也被容忍，但
    -- 空串是更明确的"没抽到"信号，且能安全参与字符串拼接。
    t:eq(Cookie.extract_from_curl(""), "", "空串输入")
    t:eq(Cookie.extract_from_curl(nil), "", "nil 输入")
    t:eq(Cookie.extract_from_curl("curl https://x"), "curl https://x",
        "没找到 -H/-b/--cookie 时原样返回整串（供上层报错时展示）")
end)

T.test("cookie.extract_from_curl 抽到的 cookie 可直接喂给 parse", function(t)
    local cookie = Cookie.extract_from_curl(
        [[curl 'https://x' -H 'cookie: sessionid=deep123; odin_tt=zzz']])
    local parsed = Cookie.parse_cookie_header(cookie)
    t:eq(parsed.sessionid, "deep123", "小写 cookie: 前缀也认得")
    t:eq(parsed.odin_tt, "zzz", "第二个 cookie 也在")
end)

local H = require("fanqie.helper")

local FanQie = {}

FanQie.USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
FanQie.MOBILE_UA = "Mozilla/5.0 (Linux; Android 10; Pixel 3) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36"
FanQie.BASE_URL = "https://fanqienovel.com"
FanQie.QINGTIAN_DEFAULT_URL = "https://v1.gyks.cf/"

function FanQie.normalize_base(base)
    local b = H.trim(base)
    if not b:match("^http") then
        b = "https://" .. b
    end
    if b:sub(-1) == "/" then
        b = b:sub(1, -2)
    end
    return b
end

function FanQie.qt_login_url(server_url)
    return FanQie.normalize_base(server_url) .. "/login_api"
end

function FanQie.qt_content_url(server_url)
    return FanQie.normalize_base(server_url) .. "/content"
end

function FanQie.make_shelf_params()
    return {
        aid = 1967,
        iid = 0,
        version_code = 57700,
        update_version_code = 57700,
    }
end

function FanQie.shelf_url()
    return FanQie.BASE_URL .. "/reading/bookapi/bookshelf/info/v:version/"
end

function FanQie.bookshelf_multidetail_url()
    return FanQie.BASE_URL .. "/api/bookshelf/multidetail"
end

function FanQie.progress_url()
    return FanQie.BASE_URL .. "/api/reader/book/progress"
end

function FanQie.update_progress_url()
    return FanQie.BASE_URL .. "/api/reader/book/update_progress"
end

function FanQie.directory_url(book_id)
    return FanQie.BASE_URL .. "/api/reader/directory/detail?bookId=" .. H.url_encode(book_id)
end

function FanQie.chapter_content_url(book_id, item_id)
    return FanQie.BASE_URL .. "/api/reader/chapter/content?book_id=" .. H.url_encode(book_id) .. "&item_id=" .. H.url_encode(item_id)
end

function FanQie.reader_url(item_id)
    return "https://fanqienovel.com/reader/" .. item_id
end

function FanQie.is_valid_book_id(book_id)
    return book_id and tostring(book_id) ~= ""
end

function FanQie.normalize_book_id(book_id)
    return tostring(book_id or "")
end

-- ============================================================================
-- 番茄小说官方账号密码登录 API
-- 接口参考 fanqienovel.com/passport 体系，
-- 与 QR 登录共用同一套 Cookie（sessionid）。
-- ============================================================================

-- 密码登录第一步：通过手机号/邮箱+密码获取重定向 token
-- 请求体: {account, password, passport_jssdk_version, passport_jssdk_type, aid, language, account_sdk_source}
function FanQie.password_login_api()
    return FanQie.BASE_URL .. "/passport/web/login/v3/"
end

-- 密码登录第二步：用 redirect token 换取 session cookie
-- redirect_uri 参数通常为 /reader/ 或 /
function FanQie.password_redirect_url(redirect_token)
    return FanQie.BASE_URL .. "/passport/web/redirect/?token="
        .. (redirect_token or "")
        .. "&redirect_uri=" .. H.url_encode("/reader/")
end

-- 检查账户状态 / 获取用户信息（用于验证登录是否成功）
function FanQie.user_info_url()
    return FanQie.BASE_URL .. "/api/user/info"
end

return FanQie
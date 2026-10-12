-- FanQie Plugin Configuration
-- Copy this file to config.lua only when you need optional local overrides.
-- Do not put real Cookies or device identities in version control.

return {
    -- Optional Cookie fallback. QR login takes priority and is persisted by KOReader.
    cookie_string = "",
    cookies = {
        ttwid = "",
        sessionid = "",
    },

    sync = {
        pull_on_open = true,
        upload_on_close = true,
    },

    cache = {
        download_book_images = true,
        -- The menu also lets you select 3, 5, or 10 chapters.
        pre_download_chapters = 3,
        pre_download_groups = 2,
    },

    reading = {
        auto_navigate = true,
        sync_bookmark = true,
        sync_annotation = true,
        sync_reading_progress = true,
    },

    notification = {
        enabled = true,
        duration = 3,
    },
}

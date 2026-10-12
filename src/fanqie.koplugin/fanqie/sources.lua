-- FanQie Plugin Source Manager
local SourceManager = {}

SourceManager.REGISTRY = {
    official_app = { name = "官方App（移动端）", configurable = false },
    official_proxy = { name = "番茄 API 备用源", configurable = false },
}

local RATE_LIMIT_TIMESTAMPS = {}

function SourceManager.rate_limit_check(source_id, max_requests, window_seconds)
    if not max_requests or max_requests <= 0 then return true, 0, nil end
    window_seconds = window_seconds or 30
    local now = os.time()
    local valid = {}
    for _, ts in ipairs(RATE_LIMIT_TIMESTAMPS[source_id] or {}) do
        if now - ts < window_seconds then table.insert(valid, ts) end
    end
    if #valid >= max_requests then
        return false, math.max(window_seconds - (now - valid[1]), 0), nil
    end
    table.insert(valid, now)
    RATE_LIMIT_TIMESTAMPS[source_id] = valid
    return true, 0, now
end

function SourceManager.merge_rate_limit_timestamps(recorded)
    for _, entry in ipairs(recorded or {}) do
        if entry.source_id and entry.ts then
            local stamps = RATE_LIMIT_TIMESTAMPS[entry.source_id] or {}
            local found = false
            for _, ts in ipairs(stamps) do
                if ts == entry.ts then found = true break end
            end
            if not found then table.insert(stamps, entry.ts) end
            RATE_LIMIT_TIMESTAMPS[entry.source_id] = stamps
        end
    end
end

function SourceManager.rate_limit_peek(source_id, max_requests, window_seconds)
    if not max_requests or max_requests <= 0 then return true, 0 end
    window_seconds = window_seconds or 30
    local now = os.time()
    local valid = {}
    for _, ts in ipairs(RATE_LIMIT_TIMESTAMPS[source_id] or {}) do
        if now - ts < window_seconds then table.insert(valid, ts) end
    end
    if #valid >= max_requests then
        return false, math.max(window_seconds - (now - valid[1]), 0)
    end
    return true, 0
end

function SourceManager.rate_limit_reset(source_id)
    RATE_LIMIT_TIMESTAMPS[source_id] = nil
end

function SourceManager.is_configured(source_id)
    return SourceManager.REGISTRY[source_id] ~= nil
end

local DEFAULT_ENABLED = {
    official_app = { enabled = true, order = 0 },
    official_proxy = { enabled = true, order = 1 },
}

function SourceManager.get_active_sources(settings)
    local sources_cfg = settings:get("sources", {})
    local list = {}
    for source_id, meta in pairs(SourceManager.REGISTRY) do
        local cfg = sources_cfg[source_id] or DEFAULT_ENABLED[source_id]
        if cfg and cfg.enabled ~= false and not meta.in_development
                and SourceManager.is_configured(source_id) then
            table.insert(list, { id = source_id, config = cfg, meta = meta })
        end
    end
    table.sort(list, function(a, b)
        return (a.config.order or 999) < (b.config.order or 999)
    end)
    return list
end

function SourceManager.get_all_sources(settings)
    local sources_cfg = settings:get("sources", {})
    local list = {}
    for source_id, meta in pairs(SourceManager.REGISTRY) do
        local cfg = sources_cfg[source_id] or DEFAULT_ENABLED[source_id] or {}
        table.insert(list, {
            id = source_id,
            config = cfg,
            meta = meta,
        })
    end
    table.sort(list, function(a, b)
        return (a.config.order or 999) < (b.config.order or 999)
    end)
    return list
end

return SourceManager

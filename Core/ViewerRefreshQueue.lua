-- 多 Viewer 刷新合并。immediate==false 时同 key 在同一 queueVersion 下只入队一次；true 则每次同步执行（勿在热路径滥用）。

local VFlow = _G.VFlow
if not VFlow then return end

local ViewerRefreshQueue = {}
VFlow.ViewerRefreshQueue = ViewerRefreshQueue

ViewerRefreshQueue.KEY_ESSENTIAL = "EssentialCooldownViewer"
ViewerRefreshQueue.KEY_UTILITY = "UtilityCooldownViewer"
ViewerRefreshQueue.KEY_BUFF_ICONS = "BuffIconCooldownViewer"
ViewerRefreshQueue.KEY_BUFF_BAR = "BuffBarCooldownViewer"

local handlers = {}
local queue = {}
local queueVersion = 0
local updaterActive = false

local Updater = CreateFrame("Frame", "VFlow_ViewerRefreshQueueUpdater")

local function sortedQueueKeys()
    local keys = {}
    for k in pairs(queue) do
        keys[#keys + 1] = k
    end
    table.sort(keys)
    return keys
end

local function ProcessQueue()
    for name, version in pairs(queue) do
        if version ~= queueVersion then
            queue[name] = nil
        end
    end
    if not next(queue) then
        updaterActive = false
        Updater:SetScript("OnUpdate", nil)
        return
    end

    local keys = sortedQueueKeys()
    local pickKey = keys[1]
    if not pickKey then
        updaterActive = false
        Updater:SetScript("OnUpdate", nil)
        return
    end

    local ver = queue[pickKey]
    queue[pickKey] = nil

    if ver == queueVersion then
        local fn = handlers[pickKey]
        if fn then
            fn()
        end
    end

    if not next(queue) then
        updaterActive = false
        Updater:SetScript("OnUpdate", nil)
    end
end

function ViewerRefreshQueue.register(key, fn)
    if type(key) ~= "string" or key == "" then
        return
    end
    handlers[key] = fn
end

function ViewerRefreshQueue.unregister(key)
    handlers[key] = nil
    queue[key] = nil
end

function ViewerRefreshQueue.bumpVersion()
    queueVersion = queueVersion + 1
end

function ViewerRefreshQueue.request(key, immediate)
    local fn = handlers[key]
    if not fn then
        return
    end
    if immediate then
        queue[key] = nil
        fn()
        if not next(queue) and updaterActive then
            Updater:SetScript("OnUpdate", nil)
            updaterActive = false
        end
        return
    end

    local qv = queueVersion
    if queue[key] == qv then
        return
    end

    queue[key] = qv
    if not updaterActive then
        updaterActive = true
        Updater:SetScript("OnUpdate", ProcessQueue)
    end
end

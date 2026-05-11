-- =========================================================
-- SECTION 1: 模块入口
-- RefreshBus — 技能刷新总线（按 scope 合并、按阶段执行）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ViewerRefreshQueue = VFlow.ViewerRefreshQueue
local Profiler = VFlow.Profiler

local RefreshBus = {}
VFlow.RefreshBus = RefreshBus

-- =========================================================
-- SECTION 2: Scope 常量与优先级
-- =========================================================

local SCOPES = {
    SKILL_GROUP_MAP = "SKILL_GROUP_MAP",
    SKILL_DATA = "SKILL_DATA",
    ITEM_APPEND_LAYOUT = "ITEM_APPEND_LAYOUT",
    SKILL_LAYOUT = "SKILL_LAYOUT",
    SKILL_GROUP_LAYOUT = "SKILL_GROUP_LAYOUT",
    SKILL_STYLE = "SKILL_STYLE",
    SKILL_COOLDOWN = "SKILL_COOLDOWN",
    BUFF_LAYOUT = "BUFF_LAYOUT",
    BUFFBAR_LAYOUT = "BUFFBAR_LAYOUT",
    HIGHLIGHT = "HIGHLIGHT",
    DEPENDENT_LAYOUT = "DEPENDENT_LAYOUT",
}
RefreshBus.SCOPES = SCOPES

local SCOPE_ORDER = {
    SCOPES.SKILL_GROUP_MAP,
    SCOPES.SKILL_DATA,
    SCOPES.ITEM_APPEND_LAYOUT,
    SCOPES.SKILL_LAYOUT,
    SCOPES.SKILL_GROUP_LAYOUT,
    SCOPES.SKILL_STYLE,
    SCOPES.SKILL_COOLDOWN,
    SCOPES.BUFF_LAYOUT,
    SCOPES.BUFFBAR_LAYOUT,
    SCOPES.HIGHLIGHT,
    SCOPES.DEPENDENT_LAYOUT,
}

local PRESETS = {
    SKILL_FULL = {
        SCOPES.SKILL_GROUP_MAP,
        SCOPES.SKILL_DATA,
        SCOPES.ITEM_APPEND_LAYOUT,
        SCOPES.SKILL_LAYOUT,
        SCOPES.SKILL_GROUP_LAYOUT,
        SCOPES.SKILL_STYLE,
        SCOPES.HIGHLIGHT,
        SCOPES.DEPENDENT_LAYOUT,
    },
    SKILL_LAYOUT = {
        SCOPES.SKILL_DATA,
        SCOPES.ITEM_APPEND_LAYOUT,
        SCOPES.SKILL_LAYOUT,
        SCOPES.SKILL_GROUP_LAYOUT,
        SCOPES.DEPENDENT_LAYOUT,
    },
    SKILL_STYLE = {
        SCOPES.SKILL_STYLE,
    },
    SKILL_GROUP_MAP = {
        SCOPES.SKILL_GROUP_MAP,
        SCOPES.SKILL_DATA,
        SCOPES.ITEM_APPEND_LAYOUT,
        SCOPES.SKILL_LAYOUT,
        SCOPES.SKILL_GROUP_LAYOUT,
        SCOPES.DEPENDENT_LAYOUT,
    },
    SKILL_COOLDOWN = {
        SCOPES.SKILL_COOLDOWN,
    },
    BUFF_FULL = {
        SCOPES.BUFF_LAYOUT,
    },
    BUFFBAR_FULL = {
        SCOPES.BUFFBAR_LAYOUT,
    },
    SKILL_HIGHLIGHT = {
        SCOPES.HIGHLIGHT,
    },
}
RefreshBus.PRESETS = PRESETS

local BUS_QUEUE_KEY = "VFlow.RefreshBus"
local registeredOwners = {}
local handlersByScope = {}

local pendingScopes = {}
local pendingSkillViewers = {}
local pendingGroups = {}
local pendingFlags = {}

local queueRegistered = false
local queueScheduled = false
local flushing = false

local function copySet(src)
    local out = {}
    for key, value in pairs(src) do
        out[key] = value
    end
    return out
end

local function clearSet(setObj)
    for key in pairs(setObj) do
        setObj[key] = nil
    end
end

local function hasAnyEntries(setObj)
    return next(setObj) ~= nil
end

local function ensureBusQueueRegistered()
    if queueRegistered or not ViewerRefreshQueue then
        return
    end
    queueRegistered = true
    ViewerRefreshQueue.register(BUS_QUEUE_KEY, function()
        queueScheduled = false
        RefreshBus.flush()
    end)
end

local function scheduleFlush(immediate)
    if ViewerRefreshQueue then
        ensureBusQueueRegistered()
        queueScheduled = true
        ViewerRefreshQueue.request(BUS_QUEUE_KEY, immediate == true)
        return
    end

    if immediate then
        RefreshBus.flush()
        return
    end

    if queueScheduled then
        return
    end
    queueScheduled = true
    C_Timer.After(0, function()
        queueScheduled = false
        RefreshBus.flush()
    end)
end

local function consumePendingState()
    if not hasAnyEntries(pendingScopes) then
        return nil
    end

    local state = {
        scopes = copySet(pendingScopes),
        dirtySkillViewers = copySet(pendingSkillViewers),
        dirtyGroups = copySet(pendingGroups),
        flags = copySet(pendingFlags),
    }

    clearSet(pendingScopes)
    clearSet(pendingSkillViewers)
    clearSet(pendingGroups)
    clearSet(pendingFlags)

    return state
end

-- =========================================================
-- SECTION 3: 对外 API
-- =========================================================

function RefreshBus.register(scope, owner, callback)
    if type(scope) ~= "string" or scope == "" then
        return
    end
    if type(owner) ~= "string" or owner == "" or type(callback) ~= "function" then
        return
    end

    handlersByScope[scope] = handlersByScope[scope] or {}
    local key = scope .. ":" .. owner
    if registeredOwners[key] then
        return
    end
    registeredOwners[key] = true
    handlersByScope[scope][#handlersByScope[scope] + 1] = {
        owner = owner,
        callback = callback,
    }
end

function RefreshBus.unregister(scope, owner)
    local list = handlersByScope[scope]
    if not list or type(owner) ~= "string" then
        return
    end

    local key = scope .. ":" .. owner
    if not registeredOwners[key] then
        return
    end
    registeredOwners[key] = nil

    for idx = #list, 1, -1 do
        local entry = list[idx]
        if entry and entry.owner == owner then
            table.remove(list, idx)
        end
    end
end

function RefreshBus.request(scopeOrScopes, opts)
    opts = opts or {}

    local function addScope(scope)
        if type(scope) == "string" and scope ~= "" then
            pendingScopes[scope] = true
        end
    end

    if type(scopeOrScopes) == "table" then
        for _, scope in ipairs(scopeOrScopes) do
            addScope(scope)
        end
    else
        addScope(scopeOrScopes)
    end

    if opts.viewers then
        for _, viewerName in ipairs(opts.viewers) do
            if type(viewerName) == "string" and viewerName ~= "" then
                pendingSkillViewers[viewerName] = true
            end
        end
    end
    if type(opts.viewer) == "string" and opts.viewer ~= "" then
        pendingSkillViewers[opts.viewer] = true
    end
    if opts.allViewers then
        pendingSkillViewers.EssentialCooldownViewer = true
        pendingSkillViewers.UtilityCooldownViewer = true
        pendingSkillViewers.BuffIconCooldownViewer = true
        pendingSkillViewers.BuffBarCooldownViewer = true
    end
    if opts.allSkillViewers then
        pendingSkillViewers.EssentialCooldownViewer = true
        pendingSkillViewers.UtilityCooldownViewer = true
    end

    if opts.groupIndices then
        for _, groupIndex in ipairs(opts.groupIndices) do
            if type(groupIndex) == "number" then
                pendingGroups[groupIndex] = true
            end
        end
    end
    if type(opts.groupIndex) == "number" then
        pendingGroups[opts.groupIndex] = true
    end

    for key, value in pairs(opts.flags or {}) do
        pendingFlags[key] = value
    end

    scheduleFlush(opts.immediate == true)
end

function RefreshBus.requestViewers(scopeOrScopes, viewerNames, opts)
    opts = opts or {}
    opts.viewers = viewerNames
    RefreshBus.request(scopeOrScopes, opts)
end

function RefreshBus.requestAllViewers(scopeOrScopes, opts)
    opts = opts or {}
    opts.allViewers = true
    RefreshBus.request(scopeOrScopes, opts)
end

function RefreshBus.requestSkillViewers(scopeOrScopes, viewerNames, opts)
    RefreshBus.requestViewers(scopeOrScopes, viewerNames, opts)
end

function RefreshBus.requestAllSkillViewers(scopeOrScopes, opts)
    opts = opts or {}
    opts.allSkillViewers = true
    RefreshBus.request(scopeOrScopes, opts)
end

function RefreshBus.requestPreset(presetKeyOrScopes, opts)
    local scopes = presetKeyOrScopes
    if type(presetKeyOrScopes) == "string" then
        scopes = PRESETS[presetKeyOrScopes]
    end
    if not scopes then
        return
    end
    RefreshBus.requestAllSkillViewers(scopes, opts)
end

function RefreshBus.requestSkillViewerPreset(presetKeyOrScopes, viewerNames, opts)
    local scopes = presetKeyOrScopes
    if type(presetKeyOrScopes) == "string" then
        scopes = PRESETS[presetKeyOrScopes]
    end
    if not scopes then
        return
    end
    RefreshBus.requestViewers(scopes, viewerNames, opts)
end

function RefreshBus.markGroupDirty(groupIndex)
    if type(groupIndex) == "number" then
        pendingGroups[groupIndex] = true
    end
end

function RefreshBus.getScopeOrder()
    return SCOPE_ORDER
end

function RefreshBus.isFlushing()
    return flushing
end

-- =========================================================
-- SECTION 4: Flush 执行
-- =========================================================

local function dispatchScope(scope, context)
    local list = handlersByScope[scope]
    if not list then
        return
    end
    context.currentScope = scope
    for idx = 1, #list do
        local entry = list[idx]
        if entry and entry.callback then
            entry.callback(context)
        end
    end
end

function RefreshBus.flush()
    if flushing then
        return
    end

    flushing = true
    local cycles = 0

    while cycles < 8 do
        local state = consumePendingState()
        if not state then
            break
        end

        cycles = cycles + 1
        local context = {
            cycle = cycles,
            scopes = state.scopes,
            dirtyViewers = state.dirtySkillViewers,
            dirtySkillViewers = state.dirtySkillViewers,
            dirtyGroups = state.dirtyGroups,
            flags = state.flags,
            request = RefreshBus.request,
            requestViewers = RefreshBus.requestViewers,
            requestAllViewers = RefreshBus.requestAllViewers,
            requestAllSkillViewers = RefreshBus.requestAllSkillViewers,
        }

        if not hasAnyEntries(context.dirtySkillViewers) then
            context.dirtySkillViewers.EssentialCooldownViewer = true
            context.dirtySkillViewers.UtilityCooldownViewer = true
        end

        for _, scope in ipairs(SCOPE_ORDER) do
            if state.scopes[scope] then
                dispatchScope(scope, context)
            end
        end
    end

    flushing = false

    if hasAnyEntries(pendingScopes) then
        scheduleFlush(false)
    end
end

-- =========================================================
-- SECTION 5: Profiler
-- =========================================================

if Profiler and Profiler.registerScope then
    Profiler.registerScope("RB:Flush", function()
        return RefreshBus.flush
    end, function(fn)
        RefreshBus.flush = fn
    end)
end

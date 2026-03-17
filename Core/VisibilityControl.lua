-- =========================================================
-- VFlow VisibilityControl - 显示条件控制
-- 职责：根据全局显示条件配置，控制UI元素的显示/隐藏
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then
    error("VFlow.VisibilityControl: Core模块未加载")
end

local MODULE_KEY = "VFlow.StyleDisplay"

local VisibilityControl = {}
VFlow.VisibilityControl = VisibilityControl

-- =========================================================
-- 暴雪内置Viewer列表
-- =========================================================

local VIEWERS = {
    { name = "EssentialCooldownViewer", scopeType = "importantSkills" },  -- 重要技能
    { name = "UtilityCooldownViewer",   scopeType = "utilitySkills" },    -- 效能技能
    { name = "BuffIconCooldownViewer",  scopeType = "buffs" },            -- BUFF图标
    { name = "BuffBarCooldownViewer",   scopeType = "trackedBuffs" },     -- BUFF条（追踪的BUFF）
}

-- =========================================================
-- 状态缓存
-- =========================================================

local stateCache = {
    inCombat = false,
    isMounted = false,
    isSkyriding = false,
    inVehicle = false,
    inPetBattle = false,
    hasTarget = false,
}

-- =========================================================
-- UI元素注册表（用于自定义UI元素）
-- =========================================================

-- 注册的UI元素 { [frame] = scopeType }
local registeredFrames = {}

--- 注册UI元素（用于自定义UI元素，如CustomMonitor）
-- @param frame Frame 要控制的帧
-- @param scopeType string 作用域类型："importantSkills" | "utilitySkills" | "buffs" | "trackedBuffs"
function VisibilityControl.RegisterFrame(frame, scopeType)
    if not frame then return end
    registeredFrames[frame] = scopeType
end

--- 取消注册UI元素
-- @param frame Frame 要取消注册的帧
function VisibilityControl.UnregisterFrame(frame)
    if not frame then return end
    registeredFrames[frame] = nil
end

-- =========================================================
-- 配置缓存
-- =========================================================

local configCache = {
    visibilityMode = "hide",
    hideInCombat = false,
    hideOnMount = false,
    hideOnSkyriding = false,
    hideInSpecial = false,
    hideNoTarget = false,
    applyToImportantSkills = true,
    applyToUtilitySkills = true,
    applyToBuffs = true,
    applyToTrackedBuffs = true,
}

-- =========================================================
-- 核心逻辑
-- =========================================================

--- 判断是否应该隐藏（根据当前状态和配置）
-- @return boolean 是否应该隐藏
local function ShouldHide()
    -- 检查是否满足任一条件
    local matchesCondition = false

    if configCache.hideInCombat and stateCache.inCombat then
        matchesCondition = true
    end

    if configCache.hideOnMount and stateCache.isMounted then
        matchesCondition = true
    end

    if configCache.hideOnSkyriding and stateCache.isSkyriding then
        matchesCondition = true
    end

    if configCache.hideInSpecial and (stateCache.inVehicle or stateCache.inPetBattle) then
        matchesCondition = true
    end

    if configCache.hideNoTarget and not stateCache.hasTarget then
        matchesCondition = true
    end

    -- 根据 visibilityMode 决定是否隐藏
    if configCache.visibilityMode == "hide" then
        -- "隐藏"模式：满足条件时隐藏
        return matchesCondition
    else
        -- "显示"模式：不满足条件时隐藏
        return not matchesCondition
    end
end

--- 检查作用域是否启用
-- @param scopeType string 作用域类型
-- @return boolean 是否启用
local function IsScopeEnabled(scopeType)
    local scopeMap = {
        importantSkills = "applyToImportantSkills",
        utilitySkills   = "applyToUtilitySkills",
        buffs           = "applyToBuffs",
        trackedBuffs    = "applyToTrackedBuffs",
    }

    local scopeKey = scopeMap[scopeType]
    if not scopeKey then return false end

    return configCache[scopeKey] == true
end

-- =========================================================
-- 应用显示条件到UI元素
-- =========================================================

--- 应用显示条件到单个Viewer
-- @param viewer Frame Viewer帧
-- @param scopeType string 作用域类型
local function UpdateViewer(viewer, scopeType)
    if not viewer then return end

    -- 检查作用域是否启用
    if not IsScopeEnabled(scopeType) then
        viewer:Show()  -- 作用域未启用，始终显示
        return
    end

    -- 根据显示条件决定显示/隐藏
    if ShouldHide() then
        viewer:Hide()
    else
        viewer:Show()
    end
end

--- 应用显示条件到所有UI元素
function VisibilityControl.EvaluateAll()
    -- 1. 处理暴雪内置Viewer
    for _, viewerInfo in ipairs(VIEWERS) do
        local viewer = _G[viewerInfo.name]
        if viewer then
            UpdateViewer(viewer, viewerInfo.scopeType)
        end
    end

    -- 2. 处理注册的自定义UI元素
    local shouldHide = ShouldHide()
    for frame, scopeType in pairs(registeredFrames) do
        if frame and frame.IsObjectType and frame:IsObjectType("Frame") then
            -- 检查作用域是否启用
            if IsScopeEnabled(scopeType) then
                -- 应用显示条件
                if shouldHide then
                    frame:Hide()
                else
                    frame:Show()
                end
            else
                -- 作用域未启用，始终显示
                frame:Show()
            end
        else
            -- 帧已被销毁，从注册表中移除
            registeredFrames[frame] = nil
        end
    end
end

-- =========================================================
-- 状态更新
-- =========================================================

--- 更新状态缓存
-- @param stateKey string 状态键
-- @param value any 新值
local function UpdateStateCache(stateKey, value)
    if stateCache[stateKey] ~= value then
        stateCache[stateKey] = value
        VisibilityControl.EvaluateAll()
    end
end

--- 更新配置缓存
local function UpdateConfigCache()
    local db = VFlow.getDB(MODULE_KEY)
    if not db then return end

    for key, value in pairs(db) do
        configCache[key] = value
    end

    VisibilityControl.EvaluateAll()
end

-- =========================================================
-- 初始化
-- =========================================================

function VisibilityControl.Initialize()
    -- 监听State变化
    VFlow.State.watch("inCombat", "VisibilityControl", function(newValue)
        UpdateStateCache("inCombat", newValue)
    end)

    VFlow.State.watch("isMounted", "VisibilityControl", function(newValue)
        UpdateStateCache("isMounted", newValue)
    end)

    VFlow.State.watch("isSkyriding", "VisibilityControl", function(newValue)
        UpdateStateCache("isSkyriding", newValue)
    end)

    VFlow.State.watch("inVehicle", "VisibilityControl", function(newValue)
        UpdateStateCache("inVehicle", newValue)
    end)

    VFlow.State.watch("inPetBattle", "VisibilityControl", function(newValue)
        UpdateStateCache("inPetBattle", newValue)
    end)

    VFlow.State.watch("hasTarget", "VisibilityControl", function(newValue)
        UpdateStateCache("hasTarget", newValue)
    end)

    -- 监听Store配置变化
    VFlow.Store.watch(MODULE_KEY, "VisibilityControl", function(key, value)
        UpdateConfigCache()
    end)

    -- 初始化配置缓存
    UpdateConfigCache()
end

-- 延迟初始化（等待State和Store系统就绪）
C_Timer.After(0.1, function()
    VisibilityControl.Initialize()
end)


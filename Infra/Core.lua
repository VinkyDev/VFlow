-- =========================================================
-- VFlow Core - 核心系统
-- 职责：事件分发、模块注册、状态管理
-- =========================================================

local ADDON_NAME = "VFlow"

-- 创建插件命名空间
local VFlow = {}
_G.VFlow = VFlow
VFlow.build = GetBuildInfo()
VFlow.L = LibStub("AceLocale-3.0"):GetLocale("VFlow", true) or setmetatable({}, { __index = function(_, k) return tostring(k) end })
local L = VFlow.L

-- 模块注册表（用于UI模块注册）
VFlow.Modules = {}

-- 事件回调存储 { [event] = { { owner, callback }, ... } }
local eventCallbacks = {}

-- 模块注册表 { [moduleKey] = { config, db } }
local modules = {}

local moduleCatalog = {
    { moduleKey = "VFlow.GeneralHome", shortName = "GeneralHome", displayName = L["Home"], fixedEnabled = true },
    { moduleKey = "VFlow.GeneralConfig", shortName = "GeneralConfig", displayName = L["Config"], fixedEnabled = true },
    { moduleKey = "VFlow.StyleIcon", shortName = "StyleIcon", displayName = L["Icon"], controlKey = "core" },
    { moduleKey = "VFlow.StyleGlow", shortName = "StyleGlow", displayName = L["Glow"], controlKey = "core" },
    { moduleKey = "VFlow.StyleDisplay", shortName = "StyleDisplay", displayName = L["Display"], controlKey = "core" },
    { moduleKey = "VFlow.Skills", shortName = "Skills", displayName = L["Skills"], controlKey = "core" },
    { moduleKey = "VFlow.Buffs", shortName = "Buffs", displayName = L["BUFF"], controlKey = "core" },
    { moduleKey = "VFlow.BuffBar", shortName = "BuffBar", displayName = L["BUFF Bar"], controlKey = "buffBar" },
    { moduleKey = "VFlow.CustomMonitor", shortName = "CustomMonitor", displayName = L["Graphic Monitor"], controlKey = "custom" },
    { moduleKey = "VFlow.Items", shortName = "Items", displayName = L["Extra CD Monitor"], controlKey = "items", requiredControlKeys = { "core" } },
    { moduleKey = "VFlow.OtherFeatures", shortName = "SharedSettings", displayName = L["Skill/BUFF Settings"], controlKey = "core" },
    { moduleKey = "VFlow.Resources", shortName = "Resources", displayName = L["Resource bar"], controlKey = "resources" },
}

local moduleControlCatalog = {
    { controlKey = "core", label = L["Style/Skills/BUFF"], order = 10, moduleKeys = { "VFlow.StyleIcon", "VFlow.StyleGlow", "VFlow.StyleDisplay", "VFlow.Skills", "VFlow.Buffs", "VFlow.OtherFeatures" } },
    { controlKey = "buffBar", label = L["BUFF Bar"], order = 20, moduleKeys = { "VFlow.BuffBar" } },
    { controlKey = "custom", label = L["Graphic Monitor"], order = 30, moduleKeys = { "VFlow.CustomMonitor" } },
    { controlKey = "items", label = L["Extra CD Monitor"], order = 40, moduleKeys = { "VFlow.Items" }, dependencies = { "core" } },
    { controlKey = "resources", label = L["Resource bar"], order = 50, moduleKeys = { "VFlow.Resources" } },
}

local moduleCatalogByKey = {}
local moduleCatalogByShortName = {}
local moduleControlCatalogByKey = {}
local runtimeControlState = {}
local runtimeModuleState = {}

for _, info in ipairs(moduleCatalog) do
    moduleCatalogByKey[info.moduleKey] = info
    moduleCatalogByShortName[info.shortName] = info
end

for _, info in ipairs(moduleControlCatalog) do
    moduleControlCatalogByKey[info.controlKey] = info
end

local function copyArray(items)
    local copied = {}
    for i = 1, #(items or {}) do
        copied[i] = items[i]
    end
    return copied
end

local function containsValue(items, value)
    for _, item in ipairs(items or {}) do
        if item == value then
            return true
        end
    end
    return false
end

local function getModuleControlStore()
    if type(_G.VFlowDB) ~= "table" then
        _G.VFlowDB = {}
    end
    local root = _G.VFlowDB
    if type(root.moduleControl) ~= "table" then
        root.moduleControl = {}
    end
    if type(root.moduleControl.enabled) ~= "table" then
        root.moduleControl.enabled = {}
    end
    return root.moduleControl.enabled
end

local function normalizeModuleKey(moduleKeyOrShortName)
    if type(moduleKeyOrShortName) ~= "string" then
        return nil
    end
    if moduleCatalogByKey[moduleKeyOrShortName] then
        return moduleKeyOrShortName
    end
    local info = moduleCatalogByShortName[moduleKeyOrShortName]
    return info and info.moduleKey or nil
end

local function normalizeControlKey(controlKey)
    if type(controlKey) ~= "string" then
        return nil
    end
    if moduleControlCatalogByKey[controlKey] then
        return controlKey
    end
    local moduleInfo = moduleCatalogByKey[controlKey] or moduleCatalogByShortName[controlKey]
    return moduleInfo and moduleInfo.controlKey or nil
end

local function readSavedControlRequested(controlKey)
    local enabledStore = getModuleControlStore()
    local value = enabledStore[controlKey]
    if value ~= nil then
        return value ~= false
    end

    local info = moduleControlCatalogByKey[controlKey]
    for _, moduleKey in ipairs(info and info.moduleKeys or {}) do
        if enabledStore[moduleKey] == false then
            return false
        end
    end

    return true
end

local function makeControlRequestedReader(enabledStore)
    return function(controlKey)
        local value = enabledStore[controlKey]
        if value ~= nil then
            return value ~= false
        end

        local info = moduleControlCatalogByKey[controlKey]
        for _, moduleKey in ipairs(info and info.moduleKeys or {}) do
            if enabledStore[moduleKey] == false then
                return false
            end
        end

        return true
    end
end

local function buildControlStateSnapshot(readRequested)
    local snapshot = {}
    local visiting = {}

    local function resolve(controlKey)
        if snapshot[controlKey] then
            return snapshot[controlKey]
        end

        if visiting[controlKey] then
            local cyclic = {
                requested = false,
                effective = false,
                missingDependencies = {},
                hasCycle = true,
            }
            snapshot[controlKey] = cyclic
            return cyclic
        end

        local info = moduleControlCatalogByKey[controlKey]
        if not info then
            local missing = {
                requested = false,
                effective = false,
                missingDependencies = {},
                missingControl = true,
            }
            snapshot[controlKey] = missing
            return missing
        end

        visiting[controlKey] = true

        local requested = readRequested(controlKey)
        local missingDependencies = {}
        if requested then
            for _, depKey in ipairs(info.dependencies or {}) do
                local depState = resolve(depKey)
                if not depState or not depState.effective then
                    missingDependencies[#missingDependencies + 1] = depKey
                end
            end
        end

        visiting[controlKey] = nil

        local state = {
            requested = requested,
            effective = requested and #missingDependencies == 0,
            missingDependencies = missingDependencies,
        }
        snapshot[controlKey] = state
        return state
    end

    for _, info in ipairs(moduleControlCatalog) do
        resolve(info.controlKey)
    end

    return snapshot
end

local function buildModuleStateSnapshot(controlSnapshot)
    local snapshot = {}
    for _, info in ipairs(moduleCatalog) do
        if info.fixedEnabled then
            snapshot[info.moduleKey] = {
                requested = true,
                effective = true,
                missingDependencies = {},
            }
        else
            local controlState = controlSnapshot[info.controlKey]
            local missingDependencies = copyArray(controlState and controlState.missingDependencies or nil)
            for _, depKey in ipairs(info.requiredControlKeys or {}) do
                local depState = controlSnapshot[depKey]
                if (not depState or not depState.effective) and not containsValue(missingDependencies, depKey) then
                    missingDependencies[#missingDependencies + 1] = depKey
                end
            end
            snapshot[info.moduleKey] = {
                requested = controlState and controlState.requested == true,
                effective = controlState and controlState.effective == true and #missingDependencies == 0,
                missingDependencies = missingDependencies,
            }
        end
    end
    return snapshot
end

runtimeControlState = buildControlStateSnapshot(readSavedControlRequested)
runtimeModuleState = buildModuleStateSnapshot(runtimeControlState)

local function getStateFromSnapshot(snapshot, key)
    local state = snapshot[key]
    if not state then
        return nil
    end
    return {
        requested = state.requested == true,
        effective = state.effective == true,
        missingDependencies = copyArray(state.missingDependencies),
    }
end

function VFlow.getModuleInfo(moduleKeyOrShortName)
    local moduleKey = normalizeModuleKey(moduleKeyOrShortName)
    if not moduleKey then
        return nil
    end
    local info = moduleCatalogByKey[moduleKey]
    if not info then
        return nil
    end
    return {
        moduleKey = info.moduleKey,
        shortName = info.shortName,
        displayName = info.displayName,
        controlKey = info.controlKey,
        requiredControlKeys = copyArray(info.requiredControlKeys),
        fixedEnabled = info.fixedEnabled == true,
    }
end

function VFlow.getModuleCatalog()
    local items = {}
    for i, info in ipairs(moduleCatalog) do
        items[i] = VFlow.getModuleInfo(info.moduleKey)
    end
    return items
end

function VFlow.getModuleControlInfo(controlKey)
    local normalizedKey = normalizeControlKey(controlKey)
    if not normalizedKey then
        return nil
    end
    local info = moduleControlCatalogByKey[normalizedKey]
    if not info then
        return nil
    end
    return {
        controlKey = info.controlKey,
        label = info.label,
        order = info.order,
        dependencies = copyArray(info.dependencies),
        moduleKeys = copyArray(info.moduleKeys),
    }
end

function VFlow.getModuleControlCatalog()
    local items = {}
    for i, info in ipairs(moduleControlCatalog) do
        items[i] = VFlow.getModuleControlInfo(info.controlKey)
    end
    return items
end

function VFlow.getModuleRuntimeState(moduleKeyOrShortName)
    local moduleKey = normalizeModuleKey(moduleKeyOrShortName)
    if not moduleKey then
        return nil
    end
    return getStateFromSnapshot(runtimeModuleState, moduleKey)
end

function VFlow.getModuleSavedState(moduleKeyOrShortName)
    local moduleKey = normalizeModuleKey(moduleKeyOrShortName)
    if not moduleKey then
        return nil
    end
    local snapshot = buildModuleStateSnapshot(buildControlStateSnapshot(readSavedControlRequested))
    return getStateFromSnapshot(snapshot, moduleKey)
end

function VFlow.getModuleControlRuntimeState(controlKey)
    local normalizedKey = normalizeControlKey(controlKey)
    if not normalizedKey then
        return nil
    end
    return getStateFromSnapshot(runtimeControlState, normalizedKey)
end

function VFlow.getModuleControlSavedState(controlKey)
    local normalizedKey = normalizeControlKey(controlKey)
    if not normalizedKey then
        return nil
    end
    local snapshot = buildControlStateSnapshot(readSavedControlRequested)
    return getStateFromSnapshot(snapshot, normalizedKey)
end

function VFlow.isModuleEnabled(moduleKeyOrShortName)
    local moduleKey = normalizeModuleKey(moduleKeyOrShortName)
    if not moduleKey then
        return false
    end
    local constants = VFlow.ModuleControlConstants and VFlow.ModuleControlConstants.MODULE_RUNTIME_ENABLED
    if constants then
        return constants[moduleKey] ~= false
    end
    local state = VFlow.getModuleRuntimeState(moduleKey)
    return state and state.effective == true or false
end

function VFlow.isModuleRequestedEnabled(moduleKeyOrShortName)
    local state = VFlow.getModuleRuntimeState(moduleKeyOrShortName)
    return state and state.requested == true or false
end

function VFlow.setSavedModuleEnabled(moduleKeyOrShortName, enabled)
    local info = VFlow.getModuleInfo(moduleKeyOrShortName)
    if not info or info.fixedEnabled or not info.controlKey then
        return false
    end
    return VFlow.setSavedModuleControlEnabled(info.controlKey, enabled)
end

function VFlow.setSavedModuleControlEnabled(controlKey, enabled)
    local normalizedKey = normalizeControlKey(controlKey)
    if not normalizedKey then
        return false
    end
    local enabledStore = getModuleControlStore()

    if enabled == false then
        local visited = {}
        local function disableRecursive(key)
            if visited[key] then
                return
            end
            visited[key] = true
            enabledStore[key] = false
            for _, info in ipairs(moduleControlCatalog) do
                if containsValue(info.dependencies, key) then
                    disableRecursive(info.controlKey)
                end
            end
        end
        disableRecursive(normalizedKey)
        return true
    end

    local trialStore = {}
    for key, value in pairs(enabledStore) do
        trialStore[key] = value
    end
    trialStore[normalizedKey] = true
    local snapshot = buildControlStateSnapshot(makeControlRequestedReader(trialStore))
    local state = snapshot[normalizedKey]
    if not state or not state.effective then
        return false, copyArray(state and state.missingDependencies or nil)
    end

    enabledStore[normalizedKey] = true
    return true
end

function VFlow.hasModuleStateChangesPendingReload()
    for _, info in ipairs(moduleControlCatalog) do
        local runtimeState = runtimeControlState[info.controlKey]
        local savedState = VFlow.getModuleControlSavedState(info.controlKey)
        if runtimeState and savedState and runtimeState.requested ~= savedState.requested then
            return true
        end
    end
    return false
end

function VFlow.getDependentModules(moduleKeyOrShortName)
    local info = VFlow.getModuleInfo(moduleKeyOrShortName)
    if not info or not info.controlKey then
        return {}
    end
    local dependents = {}
    for _, moduleInfo in ipairs(moduleCatalog) do
        if containsValue(moduleInfo.requiredControlKeys, info.controlKey) then
            dependents[#dependents + 1] = VFlow.getModuleInfo(moduleInfo.moduleKey)
        end
    end
    return dependents
end

function VFlow.getModuleControlDependents(controlKey)
    local normalizedKey = normalizeControlKey(controlKey)
    if not normalizedKey then
        return {}
    end
    local dependents = {}
    for _, info in ipairs(moduleControlCatalog) do
        if containsValue(info.dependencies, normalizedKey) then
            dependents[#dependents + 1] = VFlow.getModuleControlInfo(info.controlKey)
        end
    end
    table.sort(dependents, function(a, b)
        return (a.order or 0) < (b.order or 0)
    end)
    return dependents
end

-- 创建事件帧
local eventFrame = CreateFrame("Frame")
VFlow.eventFrame = eventFrame

-- =========================================================
-- 事件管理
-- =========================================================

--- 注册事件监听
-- @param event string 事件名称
-- @param owner string 所有者标识（用于批量注销）
-- @param callback function 回调函数
-- @param units string|nil 可选，传入单位字符串时使用RegisterUnitEvent（如 "player"）
--                         多个单位用逗号分隔，如 "player,target"
function VFlow.on(event, owner, callback, units)
    if type(event) ~= "string" then
        error("VFlow.on: event必须是字符串", 2)
    end
    if owner == nil then
        error("VFlow.on: owner不能为nil", 2)
    end
    if type(callback) ~= "function" then
        error("VFlow.on: callback必须是函数", 2)
    end

    -- 防止重复注册
    if eventCallbacks[event] then
        for _, entry in ipairs(eventCallbacks[event]) do
            if entry.owner == owner and entry.callback == callback then
                return -- 已存在，跳过
            end
        end
    end

    -- 注册到WoW事件系统
    if units then
        -- 使用RegisterUnitEvent，只监听指定单位，避免全团事件开销
        local unitList = {}
        for u in units:gmatch("[^,]+") do
            unitList[#unitList + 1] = u
        end
        pcall(eventFrame.RegisterUnitEvent, eventFrame, event, unpack(unitList))
    else
        pcall(eventFrame.RegisterEvent, eventFrame, event)
    end

    -- 存储回调
    if not eventCallbacks[event] then
        eventCallbacks[event] = {}
    end
    table.insert(eventCallbacks[event], {
        owner = owner,
        callback = callback
    })
end

--- 注销owner的所有事件
-- @param owner string 所有者标识
function VFlow.off(owner)
    if owner == nil then
        error("VFlow.off: owner不能为nil", 2)
    end

    -- 遍历所有事件，移除该owner的回调
    for event, callbacks in pairs(eventCallbacks) do
        for i = #callbacks, 1, -1 do
            if callbacks[i].owner == owner then
                table.remove(callbacks, i)
            end
        end

        -- 如果该事件没有回调了，注销WoW事件
        if #callbacks == 0 then
            pcall(eventFrame.UnregisterEvent, eventFrame, event)
            eventCallbacks[event] = nil
        end
    end
end

-- 事件分发器
eventFrame:SetScript("OnEvent", function(self, event, ...)
    local callbacks = eventCallbacks[event]
    if not callbacks then return end

    -- 调用所有回调
    for _, entry in ipairs(callbacks) do
        local success, err = pcall(entry.callback, event, ...)
        if not success then
            print("|cffff0000VFlow错误:|r 事件", event, "回调失败:", err)
        end
    end
end)

-- =========================================================
-- 状态管理（已迁移到 State.lua）
-- =========================================================

-- =========================================================
-- 模块管理
-- =========================================================

--- 注册模块
-- @param moduleKey string 模块唯一标识
-- @param config table 模块配置 { name, description, ... }
function VFlow.registerModule(moduleKey, config)
    if type(moduleKey) ~= "string" then
        error("VFlow.registerModule: moduleKey必须是字符串", 2)
    end
    if type(config) ~= "table" then
        error("VFlow.registerModule: config必须是表", 2)
    end

    if modules[moduleKey] then
        print("|cffff8800VFlow警告:|r 模块", moduleKey, "已注册，将被覆盖")
    end

    modules[moduleKey] = {
        config = config,
        db = nil -- 延迟初始化
    }
end

--- 检查模块是否已注册
-- @param moduleKey string 模块唯一标识
-- @return boolean 是否已注册
function VFlow.hasModule(moduleKey)
    return modules[moduleKey] ~= nil
end

--- 获取模块配置DB
-- @param moduleKey string 模块唯一标识
-- @param defaults table 默认配置
-- @return table 配置DB（带metatable的代理表）
function VFlow.getDB(moduleKey, defaults)
    if type(moduleKey) ~= "string" then
        error("VFlow.getDB: moduleKey必须是字符串", 2)
    end

    local module = modules[moduleKey]
    if not module then
        error("VFlow.getDB: 模块 " .. moduleKey .. " 未注册", 2)
    end

    -- 如果已初始化，直接返回
    if module.db then
        return module.db
    end

    -- 初始化DB（通过Store模块）
    local Store = _G.VFlow.Store
    if not Store then
        error("VFlow.getDB: Store模块未加载", 2)
    end

    module.db = Store.initModule(moduleKey, defaults)
    return module.db
end

--- 若模块已注册且已通过 getDB(moduleKey, defaults) 完成初始化，则返回其 DB；否则返回 nil（不抛错、不隐式 init）
-- 用于 Core/跨模块只读：目标模块可能未加载或加载顺序更早。
function VFlow.getDBIfReady(moduleKey)
    if type(moduleKey) ~= "string" then
        return nil
    end
    local module = modules[moduleKey]
    if not module or not module.db then
        return nil
    end
    return module.db
end

-- =========================================================
-- 初始化
-- =========================================================

-- 初始化基础状态
local function initState()
    -- 战斗状态
    VFlow.State.update("inCombat", InCombatLockdown())

    -- 玩家信息
    VFlow.State.update("playerName", UnitName("player"))
    VFlow.State.update("playerClass", select(2, UnitClass("player")))

    -- 专精信息
    VFlow.State.update("specID", GetSpecialization() or 0)
end

-- 注册核心事件
VFlow.on("PLAYER_LOGIN", "VFlow.Core", function()
    initState()
end)

VFlow.on("PLAYER_REGEN_DISABLED", "VFlow.Core", function()
    VFlow.State.update("inCombat", true)
end)

VFlow.on("PLAYER_REGEN_ENABLED", "VFlow.Core", function()
    VFlow.State.update("inCombat", false)
end)

VFlow.on("PLAYER_SPECIALIZATION_CHANGED", "VFlow.Core", function()
    VFlow.State.update("specID", GetSpecialization() or 0)
end)

-- =========================================================
-- 调试工具
-- =========================================================

--- 打印所有注册的事件
function VFlow.debugEvents()
    print("|cff00ff00VFlow调试:|r 已注册事件:")
    for event, callbacks in pairs(eventCallbacks) do
        print("  ", event, "->", #callbacks, "个回调")
        for _, entry in ipairs(callbacks) do
            print("    ", "owner:", entry.owner)
        end
    end
end

--- 打印所有状态监听器（委托给 State.lua）
function VFlow.debugWatchers()
    if VFlow.State and VFlow.State.debugWatchers then
        VFlow.State.debugWatchers()
    else
        print("|cffff8800VFlow警告:|r State模块未加载")
    end
end

--- 打印所有模块
function VFlow.debugModules()
    print("|cff00ff00VFlow调试:|r 已注册模块:")
    for moduleKey, module in pairs(modules) do
        print("  ", moduleKey, "->", module.config.name or "未命名")
    end
end

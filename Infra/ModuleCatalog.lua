-- =========================================================
-- VFlow ModuleCatalog - 模块目录 + 启用/禁用控制
-- =========================================================

local VFlow = _G.VFlow
local L = VFlow.L

-- =========================================================
-- 目录定义
-- =========================================================

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

-- =========================================================
-- 索引表
-- =========================================================

local moduleCatalogByKey = {}
local moduleCatalogByShortName = {}
local moduleControlCatalogByKey = {}

for _, info in ipairs(moduleCatalog) do
    moduleCatalogByKey[info.moduleKey] = info
    moduleCatalogByShortName[info.shortName] = info
end

for _, info in ipairs(moduleControlCatalog) do
    moduleControlCatalogByKey[info.controlKey] = info
end

-- =========================================================
-- 内部工具
-- =========================================================

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

-- =========================================================
-- 持久化读取
-- =========================================================

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

-- =========================================================
-- 快照构建
-- =========================================================

local function buildControlStateSnapshot(readRequested)
    local snapshot = {}
    local visiting = {}

    local function resolve(controlKey)
        if snapshot[controlKey] then
            return snapshot[controlKey]
        end
        -- 循环依赖保护
        if visiting[controlKey] then
            local cyclic = { requested = false, effective = false, missingDependencies = {}, hasCycle = true }
            snapshot[controlKey] = cyclic
            return cyclic
        end
        local info = moduleControlCatalogByKey[controlKey]
        if not info then
            local missing = { requested = false, effective = false, missingDependencies = {}, missingControl = true }
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
            snapshot[info.moduleKey] = { requested = true, effective = true, missingDependencies = {} }
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

-- =========================================================
-- 运行时状态（加载时即计算一次）
-- =========================================================

local runtimeControlState = buildControlStateSnapshot(readSavedControlRequested)
local runtimeModuleState = buildModuleStateSnapshot(runtimeControlState)

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

-- =========================================================
-- 公共 API
-- =========================================================

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
    -- 优先使用预计算常量表（由 ModuleControlConstants 在登录后生成）
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
        -- 级联禁用依赖此 controlKey 的所有子项
        local visited = {}
        local function disableRecursive(key)
            if visited[key] then return end
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

    -- 启用前试算：依赖未满足则拒绝
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
        local rState = runtimeControlState[info.controlKey]
        local savedState = VFlow.getModuleControlSavedState(info.controlKey)
        if rState and savedState and rState.requested ~= savedState.requested then
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

local VFlow = _G.VFlow
if not VFlow then
    error("VFlow.Store: Core模块未加载")
end

local Store = {}
VFlow.Store = Store

VFlowDB = VFlowDB or {}

local moduleDefaults = {}
local moduleProxies = {}

local ROOT_META_KEY = "__meta"
local CURRENT_PROFILE_KEY = "currentProfile"
local PROFILES_KEY = "profiles"
local PROFILE_KEYS_KEY = "profileKeys"
local DEFAULT_PROFILE = "default"

local configWatchers = {}
local runtimeCurrentProfileName

local function trim(value)
    if type(value) ~= "string" then
        return nil
    end
    local out = value:gsub("^%s*(.-)%s*$", "%1")
    if out == "" then
        return nil
    end
    return out
end

local function deepCopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for k, v in pairs(value) do
        out[k] = deepCopy(v)
    end
    return out
end

local function deepCopyInto(target, source)
    for k, v in pairs(source) do
        if type(v) == "table" then
            target[k] = {}
            deepCopyInto(target[k], v)
        else
            target[k] = v
        end
    end
end

local function wipeTable(tbl)
    for k in pairs(tbl) do
        tbl[k] = nil
    end
end

local function deepMerge(target, source)
    for k, v in pairs(source) do
        if target[k] == nil then
            if type(v) == "table" then
                target[k] = {}
                deepMerge(target[k], v)
            else
                target[k] = v
            end
        elseif type(v) == "table" and type(target[k]) == "table" then
            deepMerge(target[k], v)
        end
    end
end

local function getCharacterKey()
    local name = UnitName and UnitName("player")
    local realm = GetRealmName and GetRealmName()
    if type(name) ~= "string" or name == "" then
        return nil
    end
    if type(realm) ~= "string" or realm == "" then
        return nil
    end
    return name .. " - " .. realm
end

local function ensureProfileRoot()
    if type(VFlowDB) ~= "table" then
        VFlowDB = {}
    end
    local meta = VFlowDB[ROOT_META_KEY]
    local valid = type(meta) == "table"
        and type(meta[PROFILES_KEY]) == "table"
        and type(meta[CURRENT_PROFILE_KEY]) == "string"
    if not valid then
        VFlowDB = {
            [ROOT_META_KEY] = {
                [CURRENT_PROFILE_KEY] = DEFAULT_PROFILE,
                [PROFILE_KEYS_KEY] = {},
                [PROFILES_KEY] = {
                    [DEFAULT_PROFILE] = {},
                },
            },
        }
        meta = VFlowDB[ROOT_META_KEY]
    end
    local profiles = meta[PROFILES_KEY]
    if type(profiles[DEFAULT_PROFILE]) ~= "table" then
        profiles[DEFAULT_PROFILE] = {}
    end
    if type(meta[PROFILE_KEYS_KEY]) ~= "table" then
        meta[PROFILE_KEYS_KEY] = {}
    end
    local profileKeys = meta[PROFILE_KEYS_KEY]
    local charKey = getCharacterKey()
    local current = charKey and profileKeys[charKey] or nil
    if (type(current) ~= "string" or current == "" or type(profiles[current]) ~= "table") then
        local legacy = meta[CURRENT_PROFILE_KEY]
        local shouldUseLegacy = (next(profileKeys) == nil)
        if shouldUseLegacy and type(legacy) == "string" and legacy ~= "" and type(profiles[legacy]) == "table" then
            current = legacy
        else
            current = DEFAULT_PROFILE
        end
    end
    if type(current) ~= "string" or current == "" then
        current = DEFAULT_PROFILE
    end
    if type(profiles[current]) ~= "table" then
        profiles[current] = {}
    end
    meta[CURRENT_PROFILE_KEY] = current
    if charKey then
        profileKeys[charKey] = current
    end
    return meta, profiles
end

local function getCurrentProfileName()
    local meta = ensureProfileRoot()
    return meta[CURRENT_PROFILE_KEY]
end

local function getProfileTable(profileName)
    local _, profiles = ensureProfileRoot()
    return profiles[profileName]
end

local function getActiveProfileTable()
    local current = getCurrentProfileName()
    local profile = getProfileTable(current)
    if not profile then
        local _, profiles = ensureProfileRoot()
        profiles[current] = {}
        profile = profiles[current]
    end
    return profile
end

local function collectChangedKeys(result, source)
    if type(source) ~= "table" then return end
    for key in pairs(source) do
        result[key] = true
    end
end

function Store.initModule(moduleKey, defaults)
    if type(moduleKey) ~= "string" then
        error("Store.initModule: moduleKey必须是字符串", 2)
    end
    if type(defaults) ~= "table" then
        error("Store.initModule: defaults必须是表", 2)
    end

    moduleDefaults[moduleKey] = defaults
    local profile = getActiveProfileTable()
    if type(profile[moduleKey]) ~= "table" then
        profile[moduleKey] = {}
    end
    deepMerge(profile[moduleKey], defaults)
    local db = profile[moduleKey]
    moduleProxies[moduleKey] = db
    if not runtimeCurrentProfileName then
        runtimeCurrentProfileName = getCurrentProfileName()
    end
    return db
end

function Store.get(moduleKey, configKey)
    if type(moduleKey) ~= "string" then
        error("Store.get: moduleKey必须是字符串", 2)
    end
    if type(configKey) ~= "string" then
        error("Store.get: configKey必须是字符串", 2)
    end

    local proxy = moduleProxies[moduleKey]
    if not proxy then
        error("Store.get: 模块 " .. moduleKey .. " 未初始化", 2)
    end

    return proxy[configKey]
end

local function setNestedValue(obj, path, value)
    local keys = {}
    for key in path:gmatch("[^%.]+") do
        table.insert(keys, key)
    end

    if #keys == 0 then return false end

    local current = obj
    for i = 1, #keys - 1 do
        local key = keys[i]
        local numKey = tonumber(key)
        if numKey then key = numKey end

        if type(current[key]) ~= "table" then
            current[key] = {}
        end
        current = current[key]
    end

    local lastKey = keys[#keys]
    local numKey = tonumber(lastKey)
    if numKey then lastKey = numKey end
    current[lastKey] = value

    return true
end
function Store.set(moduleKey, configKey, value)
    if type(moduleKey) ~= "string" then
        error("Store.set: moduleKey必须是字符串", 2)
    end
    if type(configKey) ~= "string" then
        error("Store.set: configKey必须是字符串", 2)
    end

    local proxy = moduleProxies[moduleKey]
    if not proxy then
        error("Store.set: 模块 " .. moduleKey .. " 未初始化", 2)
    end

    if configKey:find("%.") then
        if not setNestedValue(proxy, configKey, value) then
            print("|cffff8800VFlow警告:|r 无法设置嵌套配置", configKey)
            return
        end
    else
        local defaults = moduleDefaults[moduleKey]
        if defaults and defaults[configKey] ~= nil then
            local expectedType = type(defaults[configKey])
            local actualType = type(value)
            if expectedType ~= actualType then
                print("|cffff8800VFlow警告:|r 配置", configKey, "类型不匹配，期望", expectedType, "实际", actualType)
            end
        end

        proxy[configKey] = value
    end

    Store.notifyChange(moduleKey, configKey, value)
end

function Store.getDefaults(moduleKey)
    if type(moduleKey) ~= "string" then
        error("Store.getDefaults: moduleKey必须是字符串", 2)
    end

    local defaults = moduleDefaults[moduleKey]
    if not defaults then
        error("Store.getDefaults: 模块 " .. moduleKey .. " 未初始化", 2)
    end

    return deepCopy(defaults)
end

function Store.reset(moduleKey)
    if type(moduleKey) ~= "string" then
        error("Store.reset: moduleKey必须是字符串", 2)
    end

    local defaults = moduleDefaults[moduleKey]
    if not defaults then
        error("Store.reset: 模块 " .. moduleKey .. " 未初始化", 2)
    end

    local profile = getActiveProfileTable()
    local proxy = moduleProxies[moduleKey]
    local changedKeys = {}
    if proxy then
        collectChangedKeys(changedKeys, proxy)
        wipeTable(proxy)
        deepMerge(proxy, defaults)
        profile[moduleKey] = proxy
    else
        local fresh = {}
        deepMerge(fresh, defaults)
        profile[moduleKey] = fresh
    end
    collectChangedKeys(changedKeys, defaults)
    for key in pairs(changedKeys) do
        local value = proxy and proxy[key] or profile[moduleKey][key]
        Store.notifyChange(moduleKey, tostring(key), value)
    end
    print("|cff00ff00VFlow:|r 模块", moduleKey, "已重置为默认值")
end

function Store.watch(moduleKey, owner, callback)
    if type(moduleKey) ~= "string" then
        error("Store.watch: moduleKey必须是字符串", 2)
    end
    if owner == nil then
        error("Store.watch: owner不能为nil", 2)
    end
    if type(callback) ~= "function" then
        error("Store.watch: callback必须是函数", 2)
    end

    if not configWatchers[moduleKey] then
        configWatchers[moduleKey] = {}
    end
    configWatchers[moduleKey][owner] = callback
end

function Store.unwatch(moduleKey, owner)
    if type(moduleKey) ~= "string" then
        error("Store.unwatch: moduleKey必须是字符串", 2)
    end
    if owner == nil then
        error("Store.unwatch: owner不能为nil", 2)
    end

    if configWatchers[moduleKey] then
        configWatchers[moduleKey][owner] = nil

        local hasWatchers = false
        for _ in pairs(configWatchers[moduleKey]) do
            hasWatchers = true
            break
        end
        if not hasWatchers then
            configWatchers[moduleKey] = nil
        end
    end
end

function Store.notifyChange(moduleKey, key, value)
    local watchers = configWatchers[moduleKey]
    if not watchers then return end

    for owner, callback in pairs(watchers) do
        local success, err = pcall(callback, key, value)
        if not success then
            print("|cffff0000VFlow错误:|r 配置变更回调失败:", err)
        end
    end
end

function Store.getState(stateKey)
    return VFlow.State.get(stateKey)
end

function Store.setState(stateKey, value)
    VFlow.State.update(stateKey, value)
end



function Store.getCurrentProfile()
    return getCurrentProfileName()
end

function Store.listProfiles()
    local _, profiles = ensureProfileRoot()
    local list = {}
    for profileName in pairs(profiles) do
        table.insert(list, profileName)
    end
    table.sort(list, function(a, b)
        if a == DEFAULT_PROFILE then return true end
        if b == DEFAULT_PROFILE then return false end
        return a < b
    end)
    return list
end

function Store.createProfile(profileName, sourceProfileName)
    local name = trim(profileName)
    if not name then
        return false, "配置名不能为空"
    end
    local _, profiles = ensureProfileRoot()
    if profiles[name] then
        return false, "配置已存在"
    end
    local sourceName = trim(sourceProfileName)
    if sourceName then
        local source = profiles[sourceName]
        if not source then
            return false, "来源配置不存在"
        end
        profiles[name] = deepCopy(source)
    else
        profiles[name] = {}
    end
    return true
end

function Store.copyProfile(sourceProfileName, targetProfileName)
    local sourceName = trim(sourceProfileName)
    local targetName = trim(targetProfileName)
    if not sourceName then
        return false, "源配置名不能为空"
    end
    if not targetName then
        return false, "目标配置名不能为空"
    end
    local _, profiles = ensureProfileRoot()
    if not profiles[sourceName] then
        return false, "源配置不存在"
    end
    if profiles[targetName] then
        return false, "目标配置已存在"
    end
    profiles[targetName] = deepCopy(profiles[sourceName])
    return true
end

function Store.setCurrentProfile(profileName)
    local name = trim(profileName)
    if not name then
        return false, "配置名不能为空"
    end
    local meta, profiles = ensureProfileRoot()
    local target = profiles[name]
    if not target then
        return false, "配置不存在"
    end
    local currentName = runtimeCurrentProfileName or meta[CURRENT_PROFILE_KEY]
    if currentName == name then
        local charKey = getCharacterKey()
        if charKey then
            meta[PROFILE_KEYS_KEY][charKey] = name
        end
        meta[CURRENT_PROFILE_KEY] = name
        runtimeCurrentProfileName = name
        return true
    end
    if type(profiles[currentName]) ~= "table" then
        profiles[currentName] = {}
    end
    local current = profiles[currentName]
    for moduleKey, proxy in pairs(moduleProxies) do
        current[moduleKey] = deepCopy(proxy)
    end
    meta[CURRENT_PROFILE_KEY] = name
    local charKey = getCharacterKey()
    if charKey then
        meta[PROFILE_KEYS_KEY][charKey] = name
    end
    for moduleKey, proxy in pairs(moduleProxies) do
        local source = target[moduleKey]
        local changedKeys = {}
        collectChangedKeys(changedKeys, proxy)
        collectChangedKeys(changedKeys, source)
        collectChangedKeys(changedKeys, moduleDefaults[moduleKey])
        wipeTable(proxy)
        if type(source) == "table" then
            deepCopyInto(proxy, source)
        end
        local defaults = moduleDefaults[moduleKey]
        if defaults then
            deepMerge(proxy, defaults)
        end
        target[moduleKey] = proxy
        for key in pairs(changedKeys) do
            Store.notifyChange(moduleKey, tostring(key), proxy[key])
        end
    end
    runtimeCurrentProfileName = name
    return true
end

function Store.deleteProfile(profileName)
    local name = trim(profileName)
    if not name then
        return false, "配置名不能为空"
    end
    if name == DEFAULT_PROFILE then
        return false, "默认配置不可删除"
    end
    local _, profiles = ensureProfileRoot()
    if not profiles[name] then
        return false, "配置不存在"
    end
    local currentName = getCurrentProfileName()
    if currentName == name then
        local fallback = profiles[DEFAULT_PROFILE] and DEFAULT_PROFILE or nil
        if not fallback then
            for key in pairs(profiles) do
                if key ~= name then
                    fallback = key
                    break
                end
            end
        end
        if not fallback then
            return false, "没有可切换的配置"
        end
        local ok, err = Store.setCurrentProfile(fallback)
        if not ok then
            return false, err
        end
    end
    profiles[name] = nil
    return true
end

function Store.getModuleData(moduleKey, profileName)
    if type(moduleKey) ~= "string" then
        error("Store.getModuleData: moduleKey必须是字符串", 2)
    end
    local profile = getProfileTable(trim(profileName) or getCurrentProfileName())
    if not profile then
        return nil
    end
    if type(profile[moduleKey]) ~= "table" then
        return nil
    end
    return deepCopy(profile[moduleKey])
end

function Store.getModuleRef(moduleKey)
    if type(moduleKey) ~= "string" then
        error("Store.getModuleRef: moduleKey必须是字符串", 2)
    end
    local proxy = moduleProxies[moduleKey]
    if proxy then
        return proxy
    end
    local profile = getActiveProfileTable()
    if type(profile[moduleKey]) == "table" then
        return profile[moduleKey]
    end
    return nil
end

function Store.setModuleData(moduleKey, data, profileName)
    if type(moduleKey) ~= "string" then
        error("Store.setModuleData: moduleKey必须是字符串", 2)
    end
    if type(data) ~= "table" then
        error("Store.setModuleData: data必须是表", 2)
    end
    local targetProfileName = trim(profileName) or getCurrentProfileName()
    local profile = getProfileTable(targetProfileName)
    if not profile then
        return false, "目标配置不存在"
    end

    local defaults = moduleDefaults[moduleKey]
    local currentName = getCurrentProfileName()
    local isCurrent = (targetProfileName == currentName)
    local proxy = isCurrent and moduleProxies[moduleKey] or nil
    local oldData = profile[moduleKey]

    if proxy then
        local changedKeys = {}
        collectChangedKeys(changedKeys, oldData)
        collectChangedKeys(changedKeys, proxy)
        collectChangedKeys(changedKeys, data)
        collectChangedKeys(changedKeys, defaults)
        wipeTable(proxy)
        deepCopyInto(proxy, data)
        if defaults then
            deepMerge(proxy, defaults)
        end
        profile[moduleKey] = proxy
        for key in pairs(changedKeys) do
            Store.notifyChange(moduleKey, tostring(key), proxy[key])
        end
        return true
    end

    local copy = deepCopy(data)
    if defaults then
        deepMerge(copy, defaults)
    end
    profile[moduleKey] = copy
    return true
end

function Store.listModules(profileName)
    local profile = getProfileTable(trim(profileName) or getCurrentProfileName()) or {}
    local keys = {}
    local seen = {}
    for moduleKey in pairs(moduleDefaults) do
        seen[moduleKey] = true
        table.insert(keys, moduleKey)
    end
    for moduleKey in pairs(profile) do
        if type(moduleKey) == "string" and not seen[moduleKey] then
            seen[moduleKey] = true
            table.insert(keys, moduleKey)
        end
    end
    table.sort(keys)
    return keys
end

function Store.resetAll()
    local previous = moduleProxies
    VFlowDB = {}
    local _, profiles = ensureProfileRoot()
    local defaultProfile = profiles[DEFAULT_PROFILE]
    local count = 0
    for moduleKey, defaults in pairs(moduleDefaults) do
        local proxy = previous[moduleKey]
        if proxy then
            wipeTable(proxy)
            deepMerge(proxy, defaults)
            defaultProfile[moduleKey] = proxy
            for key, value in pairs(proxy) do
                Store.notifyChange(moduleKey, tostring(key), value)
            end
        else
            defaultProfile[moduleKey] = deepCopy(defaults)
        end
        count = count + 1
    end
    runtimeCurrentProfileName = DEFAULT_PROFILE
    return count
end

VFlow.on("PLAYER_LOGIN", "VFlow.Store_ProfileKeySync", function()
    local current = Store.getCurrentProfile()
    if current and current ~= "" then
        Store.setCurrentProfile(current)
    end
end)

function Store.debugConfig(moduleKey)
    if type(moduleKey) ~= "string" then
        error("Store.debugConfig: moduleKey必须是字符串", 2)
    end

    print("|cff00ff00VFlow调试:|r 模块", moduleKey, "配置:")

    local profile = getActiveProfileTable()
    local data = profile[moduleKey]
    if type(data) ~= "table" then
        print("  ", "未初始化")
        return
    end

    for key, value in pairs(data) do
        local valueStr
        if type(value) == "table" then
            valueStr = "{...}"
        else
            valueStr = tostring(value)
        end
        print("  ", key, "=", valueStr)
    end
end

function Store.debugAll()
    print("|cff00ff00VFlow调试:|r 配置", Store.getCurrentProfile(), "模块配置:")
    for _, moduleKey in ipairs(Store.listModules()) do
        Store.debugConfig(moduleKey)
    end
end

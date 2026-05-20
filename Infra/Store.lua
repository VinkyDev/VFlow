local VFlow = _G.VFlow
if not VFlow then error("VFlow.Store: Core模块未加载") end

local Store = {}
VFlow.Store = Store

VFlowDB = VFlowDB or {}

local moduleDefaults = {}
local moduleProxies = {}
local configWatchers = {}
local runtimeCurrentProfileName

local ROOT_META_KEY = "__meta"
local CURRENT_PROFILE_KEY = "currentProfile"
local PROFILES_KEY = "profiles"
local PROFILE_KEYS_KEY = "profileKeys"
local DEFAULT_PROFILE = "default"

-- ============================================================
-- SECTION: 工具函数
-- ============================================================

local function trim(value)
    if type(value) ~= "string" then return nil end
    local out = value:gsub("^%s*(.-)%s*$", "%1")
    return out ~= "" and out or nil
end

local function deepCopy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = deepCopy(v) end
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
    for k in pairs(tbl) do tbl[k] = nil end
end

local function deepMerge(target, source)
    for k, v in pairs(source) do
        if target[k] == nil then
            target[k] = type(v) == "table" and deepCopy(v) or v
        elseif type(v) == "table" and type(target[k]) == "table" then
            deepMerge(target[k], v)
        end
    end
end

local function setNestedValue(obj, path, value)
    local keys = {}
    for key in path:gmatch("[^%.]+") do keys[#keys + 1] = key end
    if #keys == 0 then return false end
    local current = obj
    for i = 1, #keys - 1 do
        local key = tonumber(keys[i]) or keys[i]
        if type(current[key]) ~= "table" then current[key] = {} end
        current = current[key]
    end
    local lastKey = tonumber(keys[#keys]) or keys[#keys]
    current[lastKey] = value
    return true
end

local function collectChangedKeys(result, source)
    if type(source) ~= "table" then return end
    for key in pairs(source) do result[key] = true end
end

-- ============================================================
-- SECTION: 配置档案基础设施
-- ============================================================

local function getCharacterKey()
    local name = UnitName and UnitName("player")
    local realm = GetRealmName and GetRealmName()
    if type(name) ~= "string" or name == "" then return nil end
    if type(realm) ~= "string" or realm == "" then return nil end
    return name .. " - " .. realm
end

local function ensureProfileRoot()
    if type(VFlowDB) ~= "table" then VFlowDB = {} end
    local meta = VFlowDB[ROOT_META_KEY]
    local valid = type(meta) == "table"
        and type(meta[PROFILES_KEY]) == "table"
        and type(meta[CURRENT_PROFILE_KEY]) == "string"
    if not valid then
        VFlowDB = {
            [ROOT_META_KEY] = {
                [CURRENT_PROFILE_KEY] = DEFAULT_PROFILE,
                [PROFILE_KEYS_KEY] = {},
                [PROFILES_KEY] = { [DEFAULT_PROFILE] = {} },
            },
        }
        meta = VFlowDB[ROOT_META_KEY]
    end
    local profiles = meta[PROFILES_KEY]
    if type(profiles[DEFAULT_PROFILE]) ~= "table" then profiles[DEFAULT_PROFILE] = {} end
    if type(meta[PROFILE_KEYS_KEY]) ~= "table" then meta[PROFILE_KEYS_KEY] = {} end

    -- 按角色查找当前配置，兼容旧版单配置字段
    local profileKeys = meta[PROFILE_KEYS_KEY]
    local charKey = getCharacterKey()
    local current = charKey and profileKeys[charKey] or nil
    if type(current) ~= "string" or current == "" or type(profiles[current]) ~= "table" then
        local legacy = meta[CURRENT_PROFILE_KEY]
        if next(profileKeys) == nil and type(legacy) == "string" and legacy ~= "" and type(profiles[legacy]) == "table" then
            current = legacy
        else
            current = DEFAULT_PROFILE
        end
    end
    if type(current) ~= "string" or current == "" then current = DEFAULT_PROFILE end
    if type(profiles[current]) ~= "table" then profiles[current] = {} end
    meta[CURRENT_PROFILE_KEY] = current
    if charKey then profileKeys[charKey] = current end
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

-- ============================================================
-- SECTION: 核心 API
-- ============================================================

function Store.initModule(moduleKey, defaults)
    moduleDefaults[moduleKey] = defaults
    local profile = getActiveProfileTable()
    if type(profile[moduleKey]) ~= "table" then profile[moduleKey] = {} end
    deepMerge(profile[moduleKey], defaults)
    local db = profile[moduleKey]
    moduleProxies[moduleKey] = db
    if not runtimeCurrentProfileName then
        runtimeCurrentProfileName = getCurrentProfileName()
    end
    return db
end

function Store.get(moduleKey, configKey)
    return moduleProxies[moduleKey][configKey]
end

function Store.set(moduleKey, configKey, value)
    local proxy = moduleProxies[moduleKey]
    if configKey:find("%.") then
        if not setNestedValue(proxy, configKey, value) then return end
    else
        proxy[configKey] = value
    end
    Store.notifyChange(moduleKey, configKey, value)
end

function Store.getDefaults(moduleKey)
    return deepCopy(moduleDefaults[moduleKey])
end

function Store.reset(moduleKey)
    local defaults = moduleDefaults[moduleKey]
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
end

function Store.watch(moduleKey, owner, callback)
    if not configWatchers[moduleKey] then configWatchers[moduleKey] = {} end
    configWatchers[moduleKey][owner] = callback
end

function Store.unwatch(moduleKey, owner)
    if not configWatchers[moduleKey] then return end
    configWatchers[moduleKey][owner] = nil
    if not next(configWatchers[moduleKey]) then configWatchers[moduleKey] = nil end
end

function Store.notifyChange(moduleKey, key, value)
    local watchers = configWatchers[moduleKey]
    if not watchers then return end
    for _, callback in pairs(watchers) do
        local ok, err = pcall(callback, key, value)
        if not ok then
            print("|cffff0000VFlow错误:|r 配置变更回调失败:", err)
        end
    end
end

-- ============================================================
-- SECTION: 配置档案管理
-- ============================================================

function Store.getCurrentProfile()
    return getCurrentProfileName()
end

function Store.listProfiles()
    local _, profiles = ensureProfileRoot()
    local list = {}
    for name in pairs(profiles) do list[#list + 1] = name end
    table.sort(list, function(a, b)
        if a == DEFAULT_PROFILE then return true end
        if b == DEFAULT_PROFILE then return false end
        return a < b
    end)
    return list
end

function Store.createProfile(profileName, sourceProfileName)
    local name = trim(profileName)
    if not name then return false, "配置名不能为空" end
    local _, profiles = ensureProfileRoot()
    if profiles[name] then return false, "配置已存在" end
    local sourceName = trim(sourceProfileName)
    if sourceName then
        local source = profiles[sourceName]
        if not source then return false, "来源配置不存在" end
        profiles[name] = deepCopy(source)
    else
        profiles[name] = {}
    end
    return true
end

function Store.copyProfile(sourceProfileName, targetProfileName)
    local sourceName = trim(sourceProfileName)
    local targetName = trim(targetProfileName)
    if not sourceName then return false, "源配置名不能为空" end
    if not targetName then return false, "目标配置名不能为空" end
    local _, profiles = ensureProfileRoot()
    if not profiles[sourceName] then return false, "源配置不存在" end
    if profiles[targetName] then return false, "目标配置已存在" end
    profiles[targetName] = deepCopy(profiles[sourceName])
    return true
end

function Store.setCurrentProfile(profileName)
    local name = trim(profileName)
    if not name then return false, "配置名不能为空" end
    local meta, profiles = ensureProfileRoot()
    local target = profiles[name]
    if not target then return false, "配置不存在" end

    local currentName = runtimeCurrentProfileName or meta[CURRENT_PROFILE_KEY]
    if currentName == name then
        local charKey = getCharacterKey()
        if charKey then meta[PROFILE_KEYS_KEY][charKey] = name end
        meta[CURRENT_PROFILE_KEY] = name
        runtimeCurrentProfileName = name
        return true
    end

    -- 保存当前配置到旧档案
    if type(profiles[currentName]) ~= "table" then profiles[currentName] = {} end
    local current = profiles[currentName]
    for moduleKey, proxy in pairs(moduleProxies) do
        current[moduleKey] = deepCopy(proxy)
    end

    meta[CURRENT_PROFILE_KEY] = name
    local charKey = getCharacterKey()
    if charKey then meta[PROFILE_KEYS_KEY][charKey] = name end

    -- 加载目标档案到内存代理
    for moduleKey, proxy in pairs(moduleProxies) do
        local source = target[moduleKey]
        local changedKeys = {}
        collectChangedKeys(changedKeys, proxy)
        collectChangedKeys(changedKeys, source)
        collectChangedKeys(changedKeys, moduleDefaults[moduleKey])
        wipeTable(proxy)
        if type(source) == "table" then deepCopyInto(proxy, source) end
        local defaults = moduleDefaults[moduleKey]
        if defaults then deepMerge(proxy, defaults) end
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
    if not name then return false, "配置名不能为空" end
    if name == DEFAULT_PROFILE then return false, "默认配置不可删除" end
    local _, profiles = ensureProfileRoot()
    if not profiles[name] then return false, "配置不存在" end
    if getCurrentProfileName() == name then
        local fallback = profiles[DEFAULT_PROFILE] and DEFAULT_PROFILE or nil
        if not fallback then
            for key in pairs(profiles) do
                if key ~= name then fallback = key; break end
            end
        end
        if not fallback then return false, "没有可切换的配置" end
        local ok, err = Store.setCurrentProfile(fallback)
        if not ok then return false, err end
    end
    profiles[name] = nil
    return true
end

-- ============================================================
-- SECTION: 模块数据导入导出
-- ============================================================

function Store.getModuleData(moduleKey, profileName)
    local profile = getProfileTable(trim(profileName) or getCurrentProfileName())
    if not profile or type(profile[moduleKey]) ~= "table" then return nil end
    return deepCopy(profile[moduleKey])
end

function Store.getModuleRef(moduleKey)
    local proxy = moduleProxies[moduleKey]
    if proxy then return proxy end
    local profile = getActiveProfileTable()
    return type(profile[moduleKey]) == "table" and profile[moduleKey] or nil
end

function Store.setModuleData(moduleKey, data, profileName)
    local targetProfileName = trim(profileName) or getCurrentProfileName()
    local profile = getProfileTable(targetProfileName)
    if not profile then return false, "目标配置不存在" end

    local defaults = moduleDefaults[moduleKey]
    local isCurrent = (targetProfileName == getCurrentProfileName())
    local proxy = isCurrent and moduleProxies[moduleKey] or nil

    if proxy then
        local changedKeys = {}
        collectChangedKeys(changedKeys, profile[moduleKey])
        collectChangedKeys(changedKeys, proxy)
        collectChangedKeys(changedKeys, data)
        collectChangedKeys(changedKeys, defaults)
        wipeTable(proxy)
        deepCopyInto(proxy, data)
        if defaults then deepMerge(proxy, defaults) end
        profile[moduleKey] = proxy
        for key in pairs(changedKeys) do
            Store.notifyChange(moduleKey, tostring(key), proxy[key])
        end
        return true
    end

    local copy = deepCopy(data)
    if defaults then deepMerge(copy, defaults) end
    profile[moduleKey] = copy
    return true
end

function Store.listModules(profileName)
    local profile = getProfileTable(trim(profileName) or getCurrentProfileName()) or {}
    local keys, seen = {}, {}
    for moduleKey in pairs(moduleDefaults) do
        seen[moduleKey] = true
        keys[#keys + 1] = moduleKey
    end
    for moduleKey in pairs(profile) do
        if type(moduleKey) == "string" and not seen[moduleKey] then
            seen[moduleKey] = true
            keys[#keys + 1] = moduleKey
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

-- ============================================================
-- SECTION: 事件注册
-- ============================================================

-- 登录时同步角色→配置映射
VFlow.on("PLAYER_LOGIN", "VFlow.Store_ProfileKeySync", function()
    local current = Store.getCurrentProfile()
    if current and current ~= "" then
        Store.setCurrentProfile(current)
    end
end)

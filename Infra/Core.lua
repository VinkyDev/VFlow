-- =========================================================
-- VFlow Core - 核心系统
-- 职责：事件分发、模块注册、状态管理
-- =========================================================

local ADDON_NAME = "VFlow"

-- 创建插件命名空间
local VFlow = {}
_G.VFlow = VFlow
VFlow.build = GetBuildInfo()

-- 模块注册表（用于UI模块注册）
VFlow.Modules = {}

-- 事件回调存储 { [event] = { { owner, callback }, ... } }
local eventCallbacks = {}

-- 模块注册表 { [moduleKey] = { config, db } }
local modules = {}

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
function VFlow.on(event, owner, callback)
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
    pcall(eventFrame.RegisterEvent, eventFrame, event)

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

-- =========================================================
-- VFlow Core - 事件分发 + 模块注册
-- =========================================================

-- 创建插件命名空间
local VFlow = {}
_G.VFlow = VFlow
VFlow.build = GetBuildInfo()
VFlow.L = LibStub("AceLocale-3.0"):GetLocale("VFlow", true) or setmetatable({}, { __index = function(_, k) return tostring(k) end })

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

function VFlow.on(event, owner, callback, units)
    -- 防止重复注册
    if eventCallbacks[event] then
        for _, entry in ipairs(eventCallbacks[event]) do
            if entry.owner == owner and entry.callback == callback then
                return
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

    if not eventCallbacks[event] then
        eventCallbacks[event] = {}
    end
    table.insert(eventCallbacks[event], {
        owner = owner,
        callback = callback
    })
end

function VFlow.off(owner)
    for event, callbacks in pairs(eventCallbacks) do
        for i = #callbacks, 1, -1 do
            if callbacks[i].owner == owner then
                table.remove(callbacks, i)
            end
        end
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
    for _, entry in ipairs(callbacks) do
        local success, err = pcall(entry.callback, event, ...)
        if not success then
            print("|cffff0000VFlow错误:|r 事件", event, "回调失败:", err)
        end
    end
end)

-- =========================================================
-- 模块管理
-- =========================================================

function VFlow.registerModule(moduleKey, config)
    if modules[moduleKey] then
        print("|cffff8800VFlow警告:|r 模块", moduleKey, "已注册，将被覆盖")
    end
    modules[moduleKey] = {
        config = config,
        db = nil
    }
end

function VFlow.hasModule(moduleKey)
    return modules[moduleKey] ~= nil
end

function VFlow.getDB(moduleKey, defaults)
    local module = modules[moduleKey]
    if not module then return nil end
    if module.db then return module.db end
    local Store = _G.VFlow.Store
    if not Store then return nil end
    module.db = Store.initModule(moduleKey, defaults)
    return module.db
end

--- 跨模块只读：目标模块可能未加载或未初始化
function VFlow.getDBIfReady(moduleKey)
    local module = modules[moduleKey]
    if not module or not module.db then
        return nil
    end
    return module.db
end

-- =========================================================
-- 核心事件
-- =========================================================

local function initState()
    VFlow.State.update("inCombat", InCombatLockdown())
    VFlow.State.update("playerName", UnitName("player"))
    VFlow.State.update("playerClass", select(2, UnitClass("player")))
    VFlow.State.update("specID", GetSpecialization() or 0)
end

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

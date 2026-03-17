-- =========================================================
-- VFlow State - 运行时状态管理
-- 职责：管理transient（非持久化）状态、响应式状态监听
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then
    error("VFlow.State: Core模块未加载")
end

local State = {}
VFlow.State = State

-- =========================================================
-- 状态数据表（预定义键）
-- =========================================================

-- 内部状态数据存储
local stateData = {
    inCombat = false,
    specID = 0,
    playerClass = "",
    playerName = "",
}

-- =========================================================
-- 状态监听器管理
-- =========================================================

-- 状态监听器存储 { [stateKey] = { [owner] = callback } }
local stateWatchers = {}

--- 监听状态变化
-- @param stateKey string 状态键
-- @param owner string 所有者标识（用于批量注销）
-- @param callback function 回调函数 function(newValue, oldValue)
function State.watch(stateKey, owner, callback)
    if type(stateKey) ~= "string" then
        error("VFlow.State.watch: stateKey必须是字符串", 2)
    end
    if owner == nil then
        error("VFlow.State.watch: owner不能为nil", 2)
    end
    if type(callback) ~= "function" then
        error("VFlow.State.watch: callback必须是函数", 2)
    end

    -- 存储监听器
    if not stateWatchers[stateKey] then
        stateWatchers[stateKey] = {}
    end
    stateWatchers[stateKey][owner] = callback

    -- 立即触发一次回调（传入当前值）
    local success, err = pcall(callback, stateData[stateKey], nil)
    if not success then
        print("|cffff0000VFlow错误:|r 状态", stateKey, "回调失败:", err)
    end
end

--- 取消监听状态变化
-- @param stateKey string 状态键
-- @param owner string 所有者标识
function State.unwatch(stateKey, owner)
    if type(stateKey) ~= "string" then
        error("VFlow.State.unwatch: stateKey必须是字符串", 2)
    end
    if owner == nil then
        error("VFlow.State.unwatch: owner不能为nil", 2)
    end

    if stateWatchers[stateKey] then
        stateWatchers[stateKey][owner] = nil

        -- 如果没有监听器了，清理表
        local hasWatchers = false
        for _ in pairs(stateWatchers[stateKey]) do
            hasWatchers = true
            break
        end
        if not hasWatchers then
            stateWatchers[stateKey] = nil
        end
    end
end

--- 更新状态
-- @param stateKey string 状态键
-- @param value any 新值
function State.update(stateKey, value)
    if type(stateKey) ~= "string" then
        error("VFlow.State.update: stateKey必须是字符串", 2)
    end

    -- 检查值是否变化
    local oldValue = stateData[stateKey]
    if oldValue == value then
        return
    end

    -- 更新状态
    stateData[stateKey] = value

    -- 通知所有监听器
    local watchers = stateWatchers[stateKey]
    if not watchers then return end

    for owner, callback in pairs(watchers) do
        local success, err = pcall(callback, value, oldValue)
        if not success then
            print("|cffff0000VFlow错误:|r 状态", stateKey, "回调失败:", err)
        end
    end
end

--- 获取状态
-- @param stateKey string 状态键
-- @return any 状态值
function State.get(stateKey)
    return stateData[stateKey]
end

-- =========================================================
-- 暴露状态表（只读访问）
-- =========================================================

-- 允许通过 VFlow.State.inCombat 直接读取状态值
setmetatable(State, {
    __index = stateData
})

-- =========================================================
-- 调试工具
-- =========================================================

--- 打印所有状态监听器
function State.debugWatchers()
    print("|cff00ff00VFlow调试:|r 状态监听器:")
    for stateKey, watchers in pairs(stateWatchers) do
        local count = 0
        for _ in pairs(watchers) do count = count + 1 end
        print("  ", stateKey, "->", count, "个监听器")
        for owner, _ in pairs(watchers) do
            print("    ", "owner:", owner)
        end
    end
end

--- 打印所有状态值
function State.debugValues()
    print("|cff00ff00VFlow调试:|r 当前状态值:")
    for key, value in pairs(stateData) do
        print("  ", key, "=", tostring(value))
    end
end

-- =========================================================
-- 玩家状态管理
-- =========================================================

-- 御龙术检测（参考CDFlow实现）
local function IsSkyriding()
    if GetBonusBarIndex() == 11 and GetBonusBarOffset() == 5 then
        return true
    end
    local _, canGlide = C_PlayerInfo.GetGlidingInfo()
    return canGlide == true
end

-- 初始化玩家状态
local function InitPlayerStates()
    stateData.isMounted = false
    stateData.isSkyriding = false
    stateData.inVehicle = false
    stateData.inPetBattle = false
    stateData.hasTarget = false
end

-- 更新玩家状态
local function UpdatePlayerStates()
    State.update("isMounted", IsMounted())
    State.update("isSkyriding", IsSkyriding())
    State.update("inVehicle", UnitInVehicle("player"))
    State.update("inPetBattle", C_PetBattles.IsInBattle())
    State.update("hasTarget", UnitExists("target"))
end

-- 事件监听
local playerStateFrame = CreateFrame("Frame")

playerStateFrame:RegisterEvent("PLAYER_LOGIN")
playerStateFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
playerStateFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
playerStateFrame:RegisterEvent("UNIT_ENTERED_VEHICLE")
playerStateFrame:RegisterEvent("UNIT_EXITED_VEHICLE")
playerStateFrame:RegisterEvent("PET_BATTLE_OPENING_START")
playerStateFrame:RegisterEvent("PET_BATTLE_CLOSE")
playerStateFrame:RegisterEvent("PLAYER_TARGET_CHANGED")
playerStateFrame:RegisterEvent("UPDATE_BONUS_ACTIONBAR")
playerStateFrame:RegisterEvent("ACTIONBAR_UPDATE_STATE")
playerStateFrame:RegisterEvent("PLAYER_CAN_GLIDE_CHANGED")
playerStateFrame:RegisterEvent("PLAYER_IS_GLIDING_CHANGED")

playerStateFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "PLAYER_LOGIN" then
        InitPlayerStates()
        UpdatePlayerStates()
        State.update("inCombat", InCombatLockdown())
    elseif event == "PLAYER_REGEN_DISABLED" then
        State.update("inCombat", true)
    elseif event == "PLAYER_REGEN_ENABLED" then
        State.update("inCombat", false)
    elseif event == "UNIT_ENTERED_VEHICLE" or event == "UNIT_EXITED_VEHICLE" then
        local unit = ...
        if unit == "player" then
            State.update("inVehicle", UnitInVehicle("player"))
        end
    elseif event == "PET_BATTLE_OPENING_START" then
        State.update("inPetBattle", true)
    elseif event == "PET_BATTLE_CLOSE" then
        State.update("inPetBattle", false)
    elseif event == "PLAYER_TARGET_CHANGED" then
        State.update("hasTarget", UnitExists("target"))
    elseif event == "UPDATE_BONUS_ACTIONBAR" or event == "ACTIONBAR_UPDATE_STATE"
        or event == "PLAYER_CAN_GLIDE_CHANGED" or event == "PLAYER_IS_GLIDING_CHANGED" then
        -- 御龙术状态变化
        State.update("isSkyriding", IsSkyriding())
        -- 骑乘状态也可能变化
        State.update("isMounted", IsMounted())
    end
end)

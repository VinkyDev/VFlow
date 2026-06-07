-- =========================================================
-- VFlow CustomMonitor Runtime — Visibility
-- 显示条件判定（visibilityMode + hideXXX 组合）与容器可见性应用
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

VFlow.CustomMonitor = VFlow.CustomMonitor or {}
VFlow.CustomMonitor.Runtime = VFlow.CustomMonitor.Runtime or {}

local Visibility = {}
VFlow.CustomMonitor.Runtime.Visibility = Visibility

-- 判断是否应该显示条
local function ShouldShowBar(cfg, isBuffActive)
    local mode = cfg.visibilityMode or "hide"
    local conditionMet = false

    -- 检查各个条件（任一条件满足即为 true）
    if cfg.hideInCombat and VFlow.State.get("inCombat") then
        conditionMet = true
    end
    if cfg.hideOnMount and VFlow.State.get("isMounted") then
        conditionMet = true
    end
    if cfg.hideOnSkyriding and VFlow.State.get("isSkyriding") then
        conditionMet = true
    end
    if cfg.hideInSpecial and (VFlow.State.get("inVehicle") or VFlow.State.get("inPetBattle")) then
        conditionMet = true
    end
    if cfg.hideNoTarget and not VFlow.State.get("hasTarget") then
        conditionMet = true
    end
    if cfg.hideWhenInactive and not isBuffActive then
        conditionMet = true
    end

    -- 根据模式返回结果
    if mode == "show" then
        -- "仅...时显示"模式：条件满足时显示，否则隐藏
        return conditionMet
    end
    -- "仅...时隐藏"模式（默认）：条件满足时隐藏，否则显示
    return not conditionMet
end

--- 勾选「不在系统编辑模式中显示」时：仅暴雪编辑预览阶段隐藏，内部编辑模式仍显示
local function IsHiddenForSystemEditOnly(cfg)
    if not cfg or not cfg.hideInSystemEditMode then return false end
    local sys = VFlow.State.systemEditMode or false
    local internal = VFlow.State.internalEditMode or false
    return sys and not internal
end

--- 条件不满足时不 Hide：保持 Shown + Alpha=0，布局/API/充能等与「始终显示」同路径（避免因 Hide 跳过更新）
local function ApplyMonitorContainerVisibility(container, shouldShow)
    if not container then return end
    container:Show()
    container:SetAlpha(shouldShow and 1 or 0)
end

Visibility.shouldShowBar = ShouldShowBar
Visibility.isHiddenForSystemEditOnly = IsHiddenForSystemEditOnly
Visibility.applyContainerVisibility = ApplyMonitorContainerVisibility

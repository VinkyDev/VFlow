-- =========================================================
-- SECTION 1: 控制组运行态常量
-- ModuleControlConstants — 将控制组启用状态冻结为本次会话常量
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local function readControlEnabled(controlKey)
    local state = VFlow.getModuleControlRuntimeState and VFlow.getModuleControlRuntimeState(controlKey)
    return state and state.effective == true or false
end

local CORE_ENABLED = readControlEnabled("core")
local BUFF_BAR_ENABLED = readControlEnabled("buffBar")
local CUSTOM_ENABLED = readControlEnabled("custom")
local ITEMS_ENABLED = readControlEnabled("items")
local RESOURCES_ENABLED = readControlEnabled("resources")

local MODULE_RUNTIME_ENABLED = {
    ["VFlow.GeneralHome"] = true,
    ["VFlow.GeneralConfig"] = true,
    ["VFlow.StyleIcon"] = CORE_ENABLED,
    ["VFlow.StyleGlow"] = CORE_ENABLED,
    ["VFlow.StyleDisplay"] = CORE_ENABLED,
    ["VFlow.Skills"] = CORE_ENABLED,
    ["VFlow.Buffs"] = CORE_ENABLED,
    ["VFlow.BuffBar"] = BUFF_BAR_ENABLED,
    ["VFlow.CustomMonitor"] = CUSTOM_ENABLED,
    ["VFlow.Items"] = ITEMS_ENABLED,
    ["VFlow.OtherFeatures"] = CORE_ENABLED,
    ["VFlow.Resources"] = RESOURCES_ENABLED,

    GeneralHome = true,
    GeneralConfig = true,
    StyleIcon = CORE_ENABLED,
    StyleGlow = CORE_ENABLED,
    StyleDisplay = CORE_ENABLED,
    Skills = CORE_ENABLED,
    Buffs = CORE_ENABLED,
    BuffBar = BUFF_BAR_ENABLED,
    CustomMonitor = CUSTOM_ENABLED,
    Items = ITEMS_ENABLED,
    SharedSettings = CORE_ENABLED,
    Resources = RESOURCES_ENABLED,
}

VFlow.ModuleControlConstants = {
    CORE_ENABLED = CORE_ENABLED,
    BUFF_BAR_ENABLED = BUFF_BAR_ENABLED,
    CUSTOM_ENABLED = CUSTOM_ENABLED,
    ITEMS_ENABLED = ITEMS_ENABLED,
    RESOURCES_ENABLED = RESOURCES_ENABLED,
    MODULE_RUNTIME_ENABLED = MODULE_RUNTIME_ENABLED,
}

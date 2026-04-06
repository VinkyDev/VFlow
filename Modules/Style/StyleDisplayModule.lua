--[[ Core 依赖：
  - Core/VisibilityControl.lua：按本模块条件与作用域控制内置 Viewer、注册帧与资源条显隐
  - Core/CooldownStyle.lua：与冷却/BUFF 区整体显示逻辑协同
  - Core/ResourceBars.lua：读 VisibilityControl.ShouldApplyGlobalVisibilityHide("resourceBars")
]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

local MODULE_KEY = "VFlow.StyleDisplay"

VFlow.registerModule(MODULE_KEY, {
    name = L["Display Conditions"],
    description = L["Display condition settings"],
})

-- =========================================================
-- SECTION 2: 默认配置
-- =========================================================

local defaults = {
    -- 显示条件
    visibilityMode   = "hide", -- "show" 或 "hide"
    hideInCombat     = false,
    hideOnMount      = false,
    hideOnSkyriding  = false,
    hideInSpecial    = false, -- 载具/宠物对战
    hideNoTarget     = false,

    -- 作用域（哪些UI元素应用这些显示条件）
    applyToImportantSkills = true,  -- 重要技能冷却
    applyToUtilitySkills   = true,  -- 效能技能
    applyToBuffs           = true,  -- BUFF条
    applyToTrackedBuffs    = true,  -- 追踪的BUFF条
    applyToResourceBars    = true,  -- VFlow 主/次资源条
}

local db = VFlow.getDB(MODULE_KEY, defaults)

-- =========================================================
-- SECTION 3: 渲染
-- =========================================================

local function renderContent(container, _menuKey)
    local Grid = VFlow.Grid
    if VFlow.Utils and VFlow.Utils.applyDefaults then
        VFlow.Utils.applyDefaults(db, defaults)
    end

    local layout = {
        { type = "title", text = L["Display Conditions"], cols = 24 },
        { type = "separator", cols = 24 },
        { type = "description", text = L["Global visibility config for Cooldown Manager"], cols = 24 },
        { type = "spacer", height = 10, cols = 24 },

        { type = "subtitle", text = L["Display Conditions"], cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "dropdown",
            key = "visibilityMode",
            label = L["Only when the following conditions"],
            cols = 12,
            items = {
                { L["Hide"], "hide" },
                { L["Show"], "show" },
            }
        },
        { type = "spacer", height = 1, cols = 24 },
        { type = "checkbox", key = "hideInCombat", label = L["In combat"], cols = 6 },
        { type = "checkbox", key = "hideOnMount", label = L["While mounted"], cols = 6 },
        { type = "checkbox", key = "hideOnSkyriding", label = L["While dragonriding"], cols = 6 },
        { type = "checkbox", key = "hideInSpecial", label = L["In special scenarios"], cols = 6 },
        { type = "checkbox", key = "hideNoTarget", label = L["No target"], cols = 6 },
        { type = "spacer", height = 4, cols = 24 },
        { type = "description", text = L["Special scenarios: Vehicle/Pet battle"], cols = 24 },

        { type = "spacer", height = 10, cols = 24 },

        { type = "subtitle", text = L["Scope"], cols = 24 },
        { type = "separator", cols = 24 },
        { type = "description", text = L["Choose which UI elements to apply visibility to:"], cols = 24 },
        { type = "spacer", height = 4, cols = 24 },
        { type = "checkbox", key = "applyToImportantSkills", label = L["Important skills"], cols = 12 },
        { type = "checkbox", key = "applyToUtilitySkills", label = L["Efficiency skills"], cols = 12 },
        { type = "checkbox", key = "applyToBuffs", label = "BUFF", cols = 12 },
        { type = "checkbox", key = "applyToTrackedBuffs", label = L["Tracked BUFF bar"], cols = 12 },
        { type = "checkbox", key = "applyToResourceBars", label = L["Resource bars"], cols = 12 },
        { type = "spacer", height = 10, cols = 24 },
    }

    Grid.render(container, layout, db, MODULE_KEY)
end

-- =========================================================
-- SECTION 4: 公共接口
-- =========================================================

if not VFlow.Modules then
    VFlow.Modules = {}
end

VFlow.Modules.StyleDisplay = {
    renderContent = renderContent,
}
local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.StyleDisplay"

VFlow.registerModule(MODULE_KEY, {
    name = "显示条件",
    description = "显示条件设置",
})

-- =========================================================
-- 默认配置
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
}

local db = VFlow.getDB(MODULE_KEY, defaults)

-- =========================================================
-- 渲染函数
-- =========================================================

local function renderContent(container, menuKey)
    local Grid = VFlow.Grid

    local layout = {
        { type = "title", text = "显示条件", cols = 24 },
        { type = "separator", cols = 24 },
        { type = "description", text = "全局显示条件配置，控制冷却管理器在特定场景下的显示/隐藏行为。", cols = 24 },
        { type = "spacer", height = 10, cols = 24 },

        -- 显示条件配置
        { type = "subtitle", text = "显示条件", cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "dropdown",
            key = "visibilityMode",
            label = "仅以下条件时",
            cols = 12,
            items = {
                { "隐藏", "hide" },
                { "显示", "show" },
            }
        },
        { type = "spacer", height = 1, cols = 24 },
        { type = "checkbox", key = "hideInCombat", label = "战斗中", cols = 6 },
        { type = "checkbox", key = "hideOnMount", label = "骑乘时", cols = 6 },
        { type = "checkbox", key = "hideOnSkyriding", label = "御龙术时", cols = 6 },
        { type = "checkbox", key = "hideInSpecial", label = "特殊场景时", cols = 6 },
        { type = "checkbox", key = "hideNoTarget", label = "无目标时", cols = 6 },
        { type = "spacer", height = 4, cols = 24 },
        { type = "description", text = "特殊场景：载具/宠物对战", cols = 24 },

        { type = "spacer", height = 10, cols = 24 },

        -- 作用域配置
        { type = "subtitle", text = "作用域", cols = 24 },
        { type = "separator", cols = 24 },
        { type = "description", text = "选择显示条件应用到哪些UI元素：", cols = 24 },
        { type = "spacer", height = 4, cols = 24 },
        { type = "checkbox", key = "applyToImportantSkills", label = "重要技能冷却", cols = 12 },
        { type = "checkbox", key = "applyToUtilitySkills", label = "效能技能", cols = 12 },
        { type = "checkbox", key = "applyToBuffs", label = "BUFF条", cols = 12 },
        { type = "checkbox", key = "applyToTrackedBuffs", label = "追踪的BUFF条", cols = 12 },
        { type = "spacer", height = 10, cols = 24 },
    }

    Grid.render(container, layout, db, MODULE_KEY)
end

-- =========================================================
-- 公共接口
-- =========================================================

if not VFlow.Modules then VFlow.Modules = {} end
VFlow.Modules.StyleDisplay = {
    renderContent = renderContent,
}
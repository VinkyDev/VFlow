--[[ Core 依赖：
  - Core/Style/StyleApply.lua：图标样式缓存与监听本模块
  - Core/Style/StyleEngine.lua：将样式应用到冷却管理器帧
  - Core/Style/MasqueSupport.lua：Masque 检测与皮肤注册桥接
]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

local MODULE_KEY = "VFlow.StyleIcon"
local ModuleControlConstants = VFlow.ModuleControlConstants

if not ModuleControlConstants.CORE_ENABLED then return end

VFlow.registerModule(MODULE_KEY, {
    name = L["Icon Style"],
    description = L["Icon style settings"],
})

-- =========================================================
-- SECTION 2: 依赖与默认配置
-- =========================================================

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

local defaults = {
    -- 图标美化
    zoomIcons = true,
    zoomAmount = 0.08, -- 8%
    
    hideIconOverlay = true, -- 移除图标阴影遮罩
    hideIconOverlayTexture = true, -- 移除默认图标遮罩

    -- 边框设置
    borderFile = "1PX", -- 默认边框
    borderSize = 1,
    borderOffsetX = 0,
    borderOffsetY = 0,
    borderColor = { r = 0, g = 0, b = 0, a = 1 },

    -- 视觉元素
    hideDebuffBorder = true,
    hidePandemicIndicator = true,
    hideCooldownBling = true,
    -- 隐藏 GCD 转圈
    hideIconGCD = false,
}

local db = VFlow.getDB(MODULE_KEY, defaults)

-- =========================================================
-- SECTION 3: 辅助与渲染
-- =========================================================

local function getBorderOptions()
    local options = {}
    
    table.insert(options, { "1PX", "1PX" })
    table.insert(options, { L["None"], "None" })
    
    if LSM then
        local borders = LSM:List("border")
        for _, name in ipairs(borders) do
            table.insert(options, { name, name })
        end
    end
    
    if #options == 2 then
        table.insert(options, { L["Default"], "Interface\\Buttons\\WHITE8x8" })
    end
    
    return options
end

local function renderContent(container, _menuKey)
    local layout = {
        { type = "title", text = L["Icon Style"], cols = 24 },
        { type = "separator", cols = 24 },
    }
    
    if VFlow.MasqueSupport and VFlow.MasqueSupport:IsActive() then
        table.insert(layout, {
            type = "interactiveText",
            cols = 24,
            text = L["Masque detected. Configure VFlow icon style in {Masque settings}. Some VFlow options may be overridden."],
            links = {
                [L["Masque settings"]] = function()
                    SlashCmdList["MASQUE"]("VFlow")
                end
            }
        })
        table.insert(layout, { type = "spacer", height = 10, cols = 24 })
    end

    local mainOptions = {
        { type = "subtitle", text = L["Icon enhancement"], cols = 24 },
        { type = "separator", cols = 24 },
        
        { type = "checkbox", key = "zoomIcons", label = L["Enable icon zoom"], cols = 12 },
        { 
            type = "if", 
            dependsOn = "zoomIcons", 
            condition = function(cfg) return cfg.zoomIcons end,
            children = {
                { type = "slider", key = "zoomAmount", label = L["Zoom amount"], min = 0, max = 0.3, step = 0.01, cols = 12 },
            }
        },
        
        { type = "checkbox", key = "hideIconOverlay", label = L["Remove icon shadow mask"], cols = 12 },
        { type = "checkbox", key = "hideIconOverlayTexture", label = L["Remove default icon mask"], cols = 12 },
        
        { type = "spacer", height = 10, cols = 24 },
        
        { type = "subtitle", text = L["Border settings"], cols = 24 },
        { type = "separator", cols = 24 },
        
        { 
            type = "dropdown", 
            key = "borderFile", 
            label = L["Border texture"], 
            cols = 12, 
            items = getBorderOptions 
        },
        { type = "colorPicker", key = "borderColor", label = L["Border color"], hasAlpha = true, cols = 12 },
        
        { type = "slider", key = "borderSize", label = L["Border size"], min = 1, max = 50, step = 1, cols = 8 },
        { type = "slider", key = "borderOffsetX", label = L["Offset X"], min = -50, max = 50, step = 1, cols = 8 },
        { type = "slider", key = "borderOffsetY", label = L["Offset Y"], min = -50, max = 50, step = 1, cols = 8 },

        { type = "spacer", height = 10, cols = 24 },
        
        { type = "subtitle", text = L["Visual elements"], cols = 24 },
        { type = "separator", cols = 24 },
        
        { type = "checkbox", key = "hideDebuffBorder", label = L["Hide Debuff border (red highlight)"], cols = 24 },
        { type = "checkbox", key = "hideCooldownBling", label = L["Hide cooldown bling (CD complete animation)"], cols = 24 },
        { type = "checkbox", key = "hideIconGCD", label = L["Hide GCD swipe on icons"], cols = 24 },
        { type = "checkbox", key = "hidePandemicIndicator", label = L["Hide pandemic indicator (DoT refresh highlight)"], cols = 24 },
        
        { type = "spacer", height = 10, cols = 24 },
        { type = "description", text = L["Note: Some settings may require /reload to fully apply."], cols = 24 },
    }
    
    for _, item in ipairs(mainOptions) do
        table.insert(layout, item)
    end
    
    VFlow.Grid.render(container, layout, db, MODULE_KEY)
end

-- =========================================================
-- SECTION 4: 公共接口
-- =========================================================

if not VFlow.Modules then
    VFlow.Modules = {}
end

VFlow.Modules.StyleIcon = {
    renderContent = renderContent,
}

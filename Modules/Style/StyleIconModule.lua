local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.StyleIcon"

VFlow.registerModule(MODULE_KEY, {
    name = "图标样式",
    description = "图标样式设置",
})

-- LSM
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- 默认配置
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
}

local db = VFlow.getDB(MODULE_KEY, defaults)

local function getBorderOptions()
    local options = {}
    
    table.insert(options, { "1PX", "1PX" })
    table.insert(options, { "无", "None" })
    
    if LSM then
        local borders = LSM:List("border")
        for _, name in ipairs(borders) do
            table.insert(options, { name, name })
        end
    end
    
    if #options == 2 then
        table.insert(options, { "默认", "Interface\\Buttons\\WHITE8x8" })
    end
    
    return options
end

local function renderContent(container, menuKey)
    local layout = {
        { type = "title", text = "图标样式", cols = 24 },
        { type = "separator", cols = 24 },
    }
    
    if VFlow.MasqueSupport and VFlow.MasqueSupport:IsActive() then
        table.insert(layout, {
            type = "interactiveText",
            cols = 24,
            text = "|cff00ff00已检测到 Masque 插件。|r\n您可以在 {Masque设置} 中配置 VFlow 的图标样式。\n部分 VFlow 自带的美化选项可能已被 Masque 覆盖。",
            links = {
                ["Masque设置"] = function()
                    SlashCmdList["MASQUE"]("VFlow")
                end
            }
        })
        table.insert(layout, { type = "spacer", height = 10, cols = 24 })
    end

    local mainOptions = {
        -- 图标美化
        { type = "subtitle", text = "图标美化", cols = 24 },
        { type = "separator", cols = 24 },
        
        { type = "checkbox", key = "zoomIcons", label = "启用图标缩放", cols = 12 },
        { 
            type = "if", 
            dependsOn = "zoomIcons", 
            condition = function(cfg) return cfg.zoomIcons end,
            children = {
                { type = "slider", key = "zoomAmount", label = "缩放比例", min = 0, max = 0.3, step = 0.01, cols = 12 },
            }
        },
        
        { type = "checkbox", key = "hideIconOverlay", label = "移除图标阴影遮罩", cols = 12 },
        { type = "checkbox", key = "hideIconOverlayTexture", label = "移除默认图标遮罩", cols = 12 },
        
        { type = "spacer", height = 10, cols = 24 },
        
        -- 边框设置
        { type = "subtitle", text = "边框设置", cols = 24 },
        { type = "separator", cols = 24 },
        
        { 
            type = "dropdown", 
            key = "borderFile", 
            label = "边框材质", 
            cols = 12, 
            items = getBorderOptions 
        },
        { type = "colorPicker", key = "borderColor", label = "边框颜色", hasAlpha = true, cols = 12 },
        
        { type = "slider", key = "borderSize", label = "边框大小", min = 1, max = 50, step = 1, cols = 8 },
        { type = "slider", key = "borderOffsetX", label = "偏移 X", min = -50, max = 50, step = 1, cols = 8 },
        { type = "slider", key = "borderOffsetY", label = "偏移 Y", min = -50, max = 50, step = 1, cols = 8 },

        { type = "spacer", height = 10, cols = 24 },
        
        -- 视觉元素
        { type = "subtitle", text = "视觉元素", cols = 24 },
        { type = "separator", cols = 24 },
        
        { type = "checkbox", key = "hideDebuffBorder", label = "隐藏Debuff边框 (红色高亮)", cols = 24 },
        { type = "checkbox", key = "hideCooldownBling", label = "隐藏冷却闪光 (CD完成动画)", cols = 24 },
        { type = "checkbox", key = "hidePandemicIndicator", label = "隐藏传染指示器 (Dot刷新高亮)", cols = 24 },
        
        { type = "spacer", height = 10, cols = 24 },
        { type = "description", text = "注意：部分设置可能需要重载界面 (/reload) 才能完全生效。", cols = 24 },
    }
    
    for _, item in ipairs(mainOptions) do
        table.insert(layout, item)
    end
    
    if VFlow.Grid and VFlow.Grid.render then
        VFlow.Grid.render(container, layout, db, MODULE_KEY)
    end
end

if not VFlow.Modules then VFlow.Modules = {} end
VFlow.Modules.StyleIcon = {
    renderContent = renderContent,
}

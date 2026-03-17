-- =========================================================
-- VFlow Minimap - 小地图按钮
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ldb = LibStub and LibStub("LibDataBroker-1.1", true)
local icon = LibStub and LibStub("LibDBIcon-1.0", true)

if not ldb or not icon then
    print("|cffff8800VFlow警告:|r 缺少 LibDataBroker 或 LibDBIcon，无法创建小地图按钮")
    return
end

local MINIMAP_MODULE_KEY = "VFlow.GeneralHome"

local broker = ldb:NewDataObject("VFlow", {
    type = "launcher",
    text = "VFlow",
    icon = "Interface\\AddOns\\VFlow\\Assets\\Logo.png",
    OnClick = function(self, button)
        if button == "LeftButton" or button == "RightButton" then
            if VFlow.MainUI and VFlow.MainUI.toggle then
                VFlow.MainUI.toggle()
            end
        end
    end,
    OnTooltipShow = function(tooltip)
        tooltip:SetText("VFlow")
        tooltip:AddLine("左键/右键点击: 打开/关闭主界面", 1, 1, 1)
        tooltip:Show()
    end,
})

VFlow.on("PLAYER_LOGIN", "VFlow.GeneralHome.Minimap", function()
    local defaults = {
        hide = false,
        minimapPos = 220,
        enableWaCommand = true,
    }
    local db = VFlow.getDB(MINIMAP_MODULE_KEY, defaults)

    icon:Register("VFlow", broker, db)

    -- 监听配置变化以更新小地图按钮状态
    VFlow.Store.watch(MINIMAP_MODULE_KEY, "MinimapButton", function(key, value)
        if key == "hide" then
            if value then
                icon:Hide("VFlow")
            else
                icon:Show("VFlow")
            end
        elseif key == "minimapPos" then
            icon:Refresh("VFlow")
        end
    end)
end)

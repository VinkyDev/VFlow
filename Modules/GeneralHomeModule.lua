local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.GeneralHome"

VFlow.registerModule(MODULE_KEY, {
    name = "首页",
    description = "通用设置-首页",
})

-- =========================================================
-- 更新日志与计划
-- =========================================================

local CHANGELOG = {
    {
        version = "0.1.2",
        date = "2026-03-18",
        content = {
            "修复若干BUG",
        }
    },
    {
        version = "0.1.0",
        date = "2026-03-18",
        content = {
            "第一个版本，基础功能搭建完成",
        }
    },
}

local ROADMAP = {
    "多语言支持",
    "资源条",
    "自定义播报",
    "自定义高亮"
}

-- =========================================================
-- 渲染逻辑
-- =========================================================

local function renderContent(container, menuKey)
    local db = VFlow.getDB(MODULE_KEY, { hide = false, minimapPos = 220, enableWaCommand = true })
    local UI = VFlow.UI
    local primaryColor = UI.style.colors.primary
    local githubColor = { 1, 1, 1, 1 }
    local ngaColor = { 1, 1, 1, 1 }

    local layout = {
        -- LOGO
        {
            type = "customRender",
            height = 160,
            cols = 24,
            render = function(parent)
                local texture = parent:CreateTexture(nil, "ARTWORK")
                texture:SetSize(128, 128)
                texture:SetPoint("TOP", 0, -10)
                texture:SetTexture("Interface\\AddOns\\VFlow\\Assets\\Logo.png")

                local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
                fs:SetPoint("TOP", texture, "BOTTOM", 0, -10)
                local addonVersion = C_AddOns and C_AddOns.GetAddOnMetadata("VFlow", "Version") or
                GetAddOnMetadata and GetAddOnMetadata("VFlow", "Version") or ""
                fs:SetText(addonVersion ~= "" and ("VFlow v" .. addonVersion) or "VFlow")
                fs:SetTextColor(unpack(primaryColor))
            end
        },

        -- 设置
        { type = "subtitle", text = "通用设置", cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "checkbox",
            key = "hide",
            label = "隐藏小地图按钮",
            cols = 24,
            onChange = function(cfg, value)
                VFlow.Store.set(MODULE_KEY, "hide", value)
            end
        },
        {
            type = "checkbox",
            key = "enableWaCommand",
            label = "允许使用 /wa 命令打开插件 (需重载)",
            cols = 24,
            onChange = function(cfg, value)
                VFlow.Store.set(MODULE_KEY, "enableWaCommand", value)
                if value then
                    print("|cff00ff00VFlow:|r 已启用 /wa 命令，请输入 /reload 重载界面以生效")
                else
                    print("|cff00ff00VFlow:|r 已禁用 /wa 命令，请输入 /reload 重载界面以生效")
                end
            end
        },

        -- 核心机制说明
        { type = "spacer", height = 10, cols = 24 },
        { type = "subtitle", text = "功能说明", cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "interactiveText",
            cols = 24,
            text =
            "插件中大部分功能基于系统冷却管理器实现，你需要在{冷却管理器}中配置你需要监控的技能，通过本插件进行美化和增强。支持技能分组，BUFF分组，自定义图形监控等功能。框体移动有两种方式：{系统编辑模式}会打开暴雪编辑界面；插件右上角的{内部编辑模式}，不依赖暴雪编辑界面，可直接编辑本插件内所有已注册框体。",
            links = {
                ["冷却管理器"] = function()
                    VFlow.openCooldownManager()
                end,
                ["系统编辑模式"] = function()
                    VFlow.toggleSystemEditMode()
                end,
                ["内部编辑模式"] = function()
                    if VFlow.DragFrame and VFlow.DragFrame.setInternalEditMode then
                        VFlow.DragFrame.setInternalEditMode(true)
                    end
                end
            }
        },

        -- 相关链接
        { type = "spacer", height = 10, cols = 24 },
        { type = "subtitle", text = "相关链接", cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "customRender",
            height = 60,
            cols = 12,
            render = function(parent)
                local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                label:SetPoint("TOPLEFT", 0, 0)
                label:SetText("GitHub 地址")
                label:SetTextColor(unpack(githubColor))

                local editBox = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
                editBox:SetPoint("TOPLEFT", 0, -20)
                editBox:SetPoint("TOPRIGHT", -10, -20)
                editBox:SetHeight(24)
                editBox:SetFontObject("GameFontHighlight")
                editBox:SetTextColor(unpack(githubColor))
                editBox:SetTextInsets(4, 4, 0, 0)
                editBox:SetBackdrop({
                    bgFile = "Interface\\Buttons\\WHITE8x8",
                    edgeFile = "Interface\\Buttons\\WHITE8x8",
                    edgeSize = 1,
                })
                editBox:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
                editBox:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

                local link = "https://github.com/VinkyDev/VFlow"
                editBox:SetText(link)
                editBox:SetAutoFocus(false)

                editBox:SetScript("OnEditFocusGained", function(self)
                    self:HighlightText()
                    self:SetBackdropBorderColor(unpack(primaryColor))
                end)
                editBox:SetScript("OnEditFocusLost", function(self)
                    self:HighlightText(0, 0)
                    self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                    self:SetText(link)
                end)
                editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
                editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
            end
        },
        {
            type = "customRender",
            height = 60,
            cols = 12,
            render = function(parent)
                local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                label:SetPoint("TOPLEFT", 0, 0)
                label:SetText("NGA 帖子")
                label:SetTextColor(unpack(ngaColor))

                local editBox = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
                editBox:SetPoint("TOPLEFT", 0, -20)
                editBox:SetPoint("TOPRIGHT", 0, -20)
                editBox:SetHeight(24)
                editBox:SetFontObject("GameFontHighlight")
                editBox:SetTextColor(unpack(ngaColor))
                editBox:SetTextInsets(4, 4, 0, 0)
                editBox:SetBackdrop({
                    bgFile = "Interface\\Buttons\\WHITE8x8",
                    edgeFile = "Interface\\Buttons\\WHITE8x8",
                    edgeSize = 1,
                })
                editBox:SetBackdropColor(0.1, 0.1, 0.1, 0.8)
                editBox:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)

                local link = "https://ngabbs.com/read.php?tid=46210925"
                editBox:SetText(link)
                editBox:SetAutoFocus(false)

                editBox:SetScript("OnEditFocusGained", function(self)
                    self:HighlightText()
                    self:SetBackdropBorderColor(unpack(primaryColor))
                end)
                editBox:SetScript("OnEditFocusLost", function(self)
                    self:HighlightText(0, 0)
                    self:SetBackdropBorderColor(0.3, 0.3, 0.3, 1)
                    self:SetText(link)
                end)
                editBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
                editBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
            end
        },

        -- 更新日志
        { type = "spacer", height = 10, cols = 24 },
        { type = "subtitle", text = "更新日志", cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "for",
            cols = 24,
            dataSource = CHANGELOG,
            template = {
                type = "customRender",
                render = function(parent, _, _, item)
                    local log = item._forData
                    local y = 0

                    -- 版本号和日期
                    local header = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
                    header:SetPoint("TOPLEFT", 0, y)
                    header:SetText(log.version .. " (" .. log.date .. ")")
                    header:SetTextColor(unpack(primaryColor))
                    y = y - 20

                    -- 内容
                    for _, content in ipairs(log.content) do
                        local line = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                        line:SetPoint("TOPLEFT", 10, y)
                        line:SetText("• " .. content)
                        y = y - 18
                    end

                    y = y - 5 -- 底部间距
                    parent:SetHeight(-y)
                end
            }
        },

        -- 开发计划
        { type = "spacer", height = 10, cols = 24 },
        { type = "subtitle", text = "开发计划", cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "for",
            cols = 24,
            dataSource = ROADMAP,
            template = {
                type = "customRender",
                height = 20,
                render = function(parent, _, _, item)
                    local text = item._forData
                    local line = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
                    line:SetPoint("TOPLEFT", 10, 0)
                    line:SetText("• " .. text)
                end
            }
        },
    }

    VFlow.Grid.render(container, layout, db, MODULE_KEY)
end

if not VFlow.Modules then VFlow.Modules = {} end
VFlow.Modules.GeneralHome = {
    renderContent = renderContent,
}

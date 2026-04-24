--[[ Core 依赖：
  - Core/Minimap.lua：小地图按钮（读取本模块配置）
  - Core/MainUI.lua：/wa 命令是否启用（读取 enableWaCommand）
]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then
	return
end
local L = VFlow.L

local MODULE_KEY = "VFlow.GeneralHome"

VFlow.registerModule(MODULE_KEY, {
	name = L["Home"],
	description = L["General settings - Home"],
})

-- =========================================================
-- SECTION 2: 更新日志（仅中文客户端显示）
-- =========================================================

local CHANGELOG = {
	{
		version = "0.5.7",
		date = "2026-04-25",
		content = {
			"修复自定义播报在12.0.5版本下不生效的BUG",
			"修复资源条位置相关BUG",
		},
	},
	{
		version = "0.5.6",
		date = "2026-04-23",
		content = {
			"资源条兼容最新版本",
		},
	},
	{
		version = "0.5.5",
		date = "2026-04-14",
		content = {
			"4.16更新: 优化Buff条和资源条性能",
			"解决卡顿问题"
		},
	},
	{
		version = "0.5.1",
		date = "2026-04-07",
		content = {
			"新增资源条模块",
			"全面升级编辑模式样式和逻辑, 所有框体支持右键打开Vflow对应设置页, 支持完美边框吸附",
			"升级自定义图形监控模块, 支持宽度模式设置",
			"修复若干BUG"
		},
	},
	{
		version = "0.4.0",
		date = "2026-03-30",
		content = {
			"技能组新增隐藏增益遮罩层配置",
			"自定义高亮和播报支持效能技能",
			"修复自定义图形监控 - BUFF堆叠层数条清空时有延迟的bug, 修复充能条垂直布局时BUG",
			"优化自定义BUFF分组的布局逻辑, 位置更稳定"
		},
	},
	{
		version = "0.3.4",
		date = "2026-03-27",
		content = {
			"修复图形监控 - 充能条相关BUG",
			"修复自定义技能组的样式相关BUG",
		},
	},
	{
		version = "0.3.2",
		date = "2026-03-25",
		content = {
			"兼容3.25暴雪新API",
			"样式 - 图标新增隐藏GCD选项",
			"所有插件创建的容器均支持依附框体和锚点配置",
			"修复自定义图形监控 - 充能技能仅战斗中显示时异常显示的BUG",
			"移除额外CD组的鼠标提示"
		},
	},
	{
		version = "0.3.1",
		date = "2026-03-24",
		content = {
			"性能优化",
			"新增enUS,zhTW语言支持",
			"自定义图形监控 - 条形监控支持进度反向, 修复垂直布局时的相关bug",
			"修复技能布局方向选择向上增长时的相关bug",
			"修复部分技能/BUFF自定义播报不生效的bug",
			"额外CD组支持显示条件配置",
		},
	},
	{
		version = "0.3.0",
		date = "2026-03-22",
		content = {
			"新增自定义播报，自定义高亮功能",
			"修复大量BUG: 包含Masque联动BUG, 技能组间距像素BUG等",
		},
	},
	{
		version = "0.2.0",
		date = "2026-03-21",
		content = {
			"新增额外CD监控模块",
			"自定义图形监控增加不在系统编辑模式中显示的配置",
		},
	},
	{
		version = "0.1.7",
		date = "2026-03-20",
		content = {
			"修复BUFF条动态布局可能失效的BUG",
			"修复一个滑块组件问题, 该问题曾导致通过滑块滑动修改的配置值可能未生效",
			"针对多人场景(如团本)进行小幅性能优化",
			"修复自定义图形监控 - 环形BUFF持续时间监控的相关BUG",
			"优化自定义图形监控 - 充能条的冷却剩余时间文本锚点逻辑",
			"自定义图形监控增加背景色配置",
		},
	},
	{
		version = "0.1.5",
		date = "2026-03-19",
		content = {
			"修复堆叠文本层级BUG,修复自定义图形监控高占用BUG",
		},
	},
	{
		version = "0.1.0",
		date = "2026-03-18",
		content = {
			"第一个版本，基础功能搭建完成",
		},
	},
}

-- =========================================================
-- SECTION 3: 渲染
-- =========================================================

local function renderContent(container, _menuKey)
	local locale = GAME_LOCALE or GetLocale()
	local isZh = (locale == "zhCN" or locale == "zhTW")
	local db = VFlow.getDB(MODULE_KEY, {
		hide = false,
		minimapPos = 220,
		enableWaCommand = true,
		changelogShowHistory = false,
	})
	local UI = VFlow.UI
	local primaryColor = UI.style.colors.primary
	local githubColor = { 1, 1, 1, 1 }
	local ngaColor = { 1, 1, 1, 1 }

	local function renderOneChangelogBlock(parent, log, isLatest)
		local y = 0

		local header = parent:CreateFontString(nil, "OVERLAY", isLatest and "GameFontNormalLarge" or "GameFontNormal")
		header:SetPoint("TOPLEFT", 0, y)
		header:SetText(log.version .. " (" .. log.date .. ")")
		header:SetTextColor(unpack(primaryColor))
		y = y - (isLatest and 22 or 20)

		for _, lineText in ipairs(log.content) do
			local line = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
			line:SetPoint("TOPLEFT", 10, y)
			line:SetText("• " .. lineText)
			y = y - 18
		end

		y = y - 5
		parent:SetHeight(-y)
	end

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
				local addonVersion = C_AddOns and C_AddOns.GetAddOnMetadata("VFlow", "Version")
					or GetAddOnMetadata and GetAddOnMetadata("VFlow", "Version")
					or ""
				fs:SetText(addonVersion ~= "" and ("VFlow v" .. addonVersion) or "VFlow")
				fs:SetTextColor(unpack(primaryColor))
			end,
		},
	}

	if isZh then
		layout[#layout + 1] = { type = "spacer", height = 6, cols = 24 }
		layout[#layout + 1] = { type = "subtitle", text = L["Changelog"], cols = 24 }
		layout[#layout + 1] = { type = "separator", cols = 24 }
		layout[#layout + 1] = {
			type = "customRender",
			cols = 24,
			render = function(parent)
				if CHANGELOG[1] then
					renderOneChangelogBlock(parent, CHANGELOG[1], true)
				end
			end,
		}
	end

	if isZh and #CHANGELOG > 1 then
		layout[#layout + 1] = {
			type = "checkbox",
			key = "changelogShowHistory",
			label = string.format(L["Show history changelog (%d more)"], #CHANGELOG - 1),
			cols = 24,
		}
		layout[#layout + 1] = {
			type = "if",
			dependsOn = "changelogShowHistory",
			condition = function(cfg)
				return cfg.changelogShowHistory == true
			end,
			children = {
				{ type = "spacer",    height = 4,                    cols = 24 },
				{ type = "subtitle",  text = L["History changelog"], cols = 24 },
				{ type = "separator", cols = 24 },
				{
					type = "for",
					cols = 24,
					dataSource = function()
						local t = {}
						for i = 2, #CHANGELOG do
							t[#t + 1] = CHANGELOG[i]
						end
						return t
					end,
					template = {
						type = "customRender",
						render = function(parent, _, _, item)
							renderOneChangelogBlock(parent, item._forData, false)
						end,
					},
				},
			},
		}
	end

	local tail = {
		{ type = "spacer",    height = 10,                     cols = 24 },
		{ type = "subtitle",  text = L["Feature Description"], cols = 24 },
		{ type = "separator", cols = 24 },
		{
			type = "interactiveText",
			cols = 24,
			text = L
				["Most features use the system Cooldown Manager. Configure tracked spells in {cooldown manager}, enhance with this addon. Supports skill groups, BUFF groups, custom monitors. Two ways to move frames: {System Edit Mode} opens Blizzard's editor; {Internal Edit Mode} in top-right directly edits addon frames."],
			links = {
				[L["cooldown manager"]] = function()
					VFlow.openCooldownManager()
				end,
				[L["System Edit Mode"]] = function()
					VFlow.toggleSystemEditMode()
				end,
				[L["Internal Edit Mode"]] = function()
					if VFlow.DragFrame and VFlow.DragFrame.setInternalEditMode then
						VFlow.DragFrame.setInternalEditMode(true)
					end
				end,
			},
		},

		{ type = "subtitle",  text = L["General Settings"], cols = 24 },
		{ type = "separator", cols = 24 },
		{
			type = "checkbox",
			key = "hide",
			label = L["Hide minimap button"],
			cols = 12,
		},
		{
			type = "checkbox",
			key = "enableWaCommand",
			label = L["Allow /wa command to open addon (reload required)"],
			cols = 12,
			onChange = function(_, value)
				if value then
					print("|cff00ff00VFlow:|r " .. L["Enabled /wa command, /reload to apply"])
				else
					print("|cff00ff00VFlow:|r " .. L["Disabled /wa command, /reload to apply"])
				end
			end,
		},

		{ type = "spacer",    height = 10,               cols = 24 },
		{ type = "subtitle",  text = L["Related Links"], cols = 24 },
		{ type = "separator", cols = 24 },
		{
			type = "customRender",
			height = 60,
			cols = 12,
			render = function(parent)
				local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
				label:SetPoint("TOPLEFT", 0, 0)
				label:SetText(L["GitHub"])
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
				editBox:SetScript("OnEscapePressed", function(self)
					self:ClearFocus()
				end)
				editBox:SetScript("OnEnterPressed", function(self)
					self:ClearFocus()
				end)
			end,
		},
		{
			type = "customRender",
			height = 60,
			cols = 12,
			render = function(parent)
				local label = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
				label:SetPoint("TOPLEFT", 0, 0)
				label:SetText(L["NGA Post"])
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
				editBox:SetScript("OnEscapePressed", function(self)
					self:ClearFocus()
				end)
				editBox:SetScript("OnEnterPressed", function(self)
					self:ClearFocus()
				end)
			end,
		},
	}

	for i = 1, #tail do
		layout[#layout + 1] = tail[i]
	end

	VFlow.Grid.render(container, layout, db, MODULE_KEY)
end

-- =========================================================
-- SECTION 4: 公共接口
-- =========================================================

if not VFlow.Modules then
	VFlow.Modules = {}
end

VFlow.Modules.GeneralHome = {
	renderContent = renderContent,
}

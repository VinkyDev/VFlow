-- =========================================================
-- VFlow CooldownStyle - 技能/BUFF样式引擎
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local StyleApply = VFlow.StyleApply
local StyleLayout = VFlow.StyleLayout
local BuffRuntime = VFlow.BuffRuntime
local BuffBarRuntime = VFlow.BuffBarRuntime
local MasqueSupport = VFlow.MasqueSupport
local PP = VFlow.PixelPerfect
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
local abs = math.abs
local Profiler = VFlow.Profiler
local RequestBuffRefresh
local RequestBuffBarRefresh
local IsViewerReady
local MAX_BUFF_READY_RETRIES = 20
local MAX_BUFFBAR_READY_RETRIES = 20

-- =========================================================
-- 按钮样式版本号（配置变更时递增，用于跳过无变化的 ApplyButtonStyle）
-- =========================================================
local _buttonStyleVersion = 0

local function BumpButtonStyleVersion()
    _buttonStyleVersion = _buttonStyleVersion + 1
    VFlow._buttonStyleVersion = _buttonStyleVersion
end

-- =========================================================
-- 模块级 DB 引用缓存（避免热路径上反复 Store.getModuleRef）
-- =========================================================
local _cachedBuffsDB
local _cachedBuffBarDB

local function InvalidateDBCache()
    local store = VFlow and VFlow.Store
    if not store or not store.getModuleRef then return end
    _cachedBuffsDB  = store.getModuleRef("VFlow.Buffs")
    _cachedBuffBarDB = store.getModuleRef("VFlow.BuffBar")
end

local function GetBuffViewerAndConfig()
    Profiler.count("CDS:GetBuffViewerAndConfig")
    local viewer = _G.BuffIconCooldownViewer
    local cfg = _cachedBuffsDB and _cachedBuffsDB.buffMonitor
    return viewer, cfg
end

local function GetBuffBarViewerAndConfig()
    Profiler.count("CDS:GetBuffBarViewerAndConfig")
    local viewer = _G.BuffBarCooldownViewer
    return viewer, _cachedBuffBarDB
end

local function ResolveStatusBarTexture(textureName)
    if not textureName or textureName == "" or textureName == "默认" then
        return "Interface\\Buttons\\WHITE8X8"
    end
    if LSM then
        local path = LSM:Fetch("statusbar", textureName)
        if path then
            return path
        end
    end
    return textureName
end

local function ResolveBuffBarWidth(cfg)
    local width = cfg and cfg.barWidth or 200
    if not width or width <= 0 then
        return 200
    end
    return width
end

local function CollectBuffBarFrames(viewer)
    Profiler.count("CDS:CollectBuffBarFrames")
    local frames = {}
    if not viewer then
        return frames
    end
    if viewer.itemFramePool then
        for frame in viewer.itemFramePool:EnumerateActive() do
            if frame and frame.IsShown and frame:IsShown() then
                frames[#frames + 1] = frame
            end
        end
    else
        for _, frame in ipairs({ viewer:GetChildren() }) do
            if frame and frame.IsShown and frame:IsShown() then
                frames[#frames + 1] = frame
            end
        end
    end
    table.sort(frames, function(a, b)
        return (a.layoutIndex or 0) < (b.layoutIndex or 0)
    end)
    return frames
end

local function IsSafeEqual(v, expected)
    if type(v) == "number" and issecretvalue and issecretvalue(v) then
        return false
    end
    return v == expected
end

local function HideIconOverlays(iconFrame)
    if not iconFrame then return end
    for _, region in ipairs({ iconFrame:GetRegions() }) do
        if region and region.IsObjectType and region:IsObjectType("Texture") then
            local atlas = region.GetAtlas and region:GetAtlas()
            local tex = region.GetTexture and region:GetTexture()
            if IsSafeEqual(atlas, "UI-HUD-CoolDownManager-IconOverlay") or IsSafeEqual(tex, 6707800) then
                region:Hide()
                region:SetAlpha(0)
            end
        end
    end
end

-- =========================================================
-- BuffBar 辅助函数
-- =========================================================

--- 一次性 hook：当配置隐藏某文本时，阻止系统 Show() 调用
local function HookBarTextVisibility(frame, hookKey, textElement, cfgKey)
    if not frame or not textElement or frame[hookKey] then return end
    frame[hookKey] = true
    hooksecurefunc(textElement, "Show", function(self)
        local localCfg = frame._vf_barCfg
        if localCfg and localCfg[cfgKey] == false then
            self:Hide()
        end
    end)
end

--- 确保 bar 有自定义背景纹理
local function EnsureBarBackground(bar)
    if not bar then return nil end
    if not bar._vf_bg then
        local bg = bar:CreateTexture(nil, "BACKGROUND", nil, -1)
        bg:ClearAllPoints()
        bg:SetAllPoints(bar)
        bar._vf_bg = bg
    end
    return bar._vf_bg
end

--- 确保 bar 有像素边框
local function EnsureBarBorder(bar)
    if not bar or not PP then return end
    if not bar._vf_borderFrame then
        local borderFrame = CreateFrame("Frame", nil, bar)
        borderFrame:SetAllPoints(bar)
        borderFrame:SetFrameLevel((bar:GetFrameLevel() or 1) + 2)
        bar._vf_borderFrame = borderFrame
    end
    PP.CreateBorder(bar._vf_borderFrame, 1, { r = 0, g = 0, b = 0, a = 1 }, true)
    PP.ShowBorder(bar._vf_borderFrame)
end

--- 应用样式到单个BuffBar帧
local function ApplyBuffBarFrameStyle(frame, cfg, frameWidth, frameHeight)
    if not frame or not cfg then return end

    local barStyleVer = BuffBarRuntime and BuffBarRuntime.getStyleVersion() or 0
    local iconPosition = cfg.iconPosition or "LEFT"

    -- 脏检查：版本+尺寸+图标位置均未变则跳过
    if frame._vf_barStyled
        and frame._vf_barStyleVer == barStyleVer
        and frame._vf_barW == frameWidth
        and frame._vf_barH == frameHeight
        and frame._vf_barIconPos == iconPosition
    then
        return
    end

    frame._vf_barCfg = cfg
    frame:SetSize(frameWidth, frameHeight)

    local icon = frame.Icon
    local bar = frame.Bar or frame.StatusBar
    local nameText = (bar and bar.Name) or frame.Name or frame.SpellName or frame.NameText
    local durationText = (bar and bar.Duration) or frame.Duration or frame.DurationText
        or StyleApply.GetCooldownFontString(frame)
    local appText = (icon and (icon.Applications or icon.Count))
        or StyleApply.GetStackFontString(frame)
        or frame.ApplicationsText

    local iconGap = cfg.iconGap or 0

    -- ===== 一次性隐藏系统默认元素 =====
    if not frame._vf_barHidesDone then
        if bar then
            if bar.BarBG then
                bar.BarBG:Hide()
                bar.BarBG:SetAlpha(0)
                if not frame._vf_barBGHooked then
                    frame._vf_barBGHooked = true
                    hooksecurefunc(bar.BarBG, "Show", function(self)
                        self:Hide()
                        self:SetAlpha(0)
                    end)
                end
            end
            if bar.Pip then
                bar.Pip:Hide()
                bar.Pip:SetAlpha(0)
                if not frame._vf_pipHooked then
                    frame._vf_pipHooked = true
                    hooksecurefunc(bar.Pip, "Show", function(self)
                        self:Hide()
                        self:SetAlpha(0)
                    end)
                end
            end
        end
        frame._vf_barHidesDone = true
    end

    -- ===== 图标 Show hook（一次性） =====
    if icon and not frame._vf_iconShowHooked then
        frame._vf_iconShowHooked = true
        hooksecurefunc(icon, "Show", function(self)
            local localCfg = frame._vf_barCfg
            if localCfg and localCfg.iconPosition == "HIDDEN" then
                self:Hide()
            end
        end)
    end

    -- ===== 图标布局 =====
    if bar and bar.ClearAllPoints then
        bar:ClearAllPoints()
        bar:SetHeight(frameHeight)

        if bar.SetStatusBarTexture then
            bar:SetStatusBarTexture(ResolveStatusBarTexture(cfg.barTexture))
        end
        if bar.SetStatusBarColor and cfg.barColor then
            local c = cfg.barColor
            bar:SetStatusBarColor(c.r or 1, c.g or 1, c.b or 1, c.a or 1)
        end

        if icon and iconPosition ~= "HIDDEN" then
            icon:Show()
            icon:SetSize(frameHeight, frameHeight)
            icon:ClearAllPoints()

            if iconPosition == "RIGHT" then
                icon:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
                bar:SetPoint("LEFT", frame, "LEFT", 0, 0)
                bar:SetPoint("RIGHT", icon, "LEFT", -iconGap, 0)
            else
                icon:SetPoint("LEFT", frame, "LEFT", 0, 0)
                bar:SetPoint("LEFT", icon, "RIGHT", iconGap, 0)
                bar:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
            end

            -- 图标纹理处理
            local iconTexture = icon.Icon
            if iconTexture then
                if iconTexture.ClearAllPoints then
                    iconTexture:ClearAllPoints()
                    iconTexture:SetAllPoints(icon)
                end
                if iconTexture.SetTexCoord then
                    iconTexture:SetTexCoord(0.08, 0.92, 0.08, 0.92)
                end
                -- 移除圆形遮罩
                for _, region in ipairs({ icon:GetRegions() }) do
                    if region and region.IsObjectType and region:IsObjectType("MaskTexture")
                        and iconTexture.RemoveMaskTexture then
                        pcall(iconTexture.RemoveMaskTexture, iconTexture, region)
                    end
                end
            end
            HideIconOverlays(icon)
        else
            -- 图标隐藏：bar占满整个帧
            bar:SetPoint("LEFT", frame, "LEFT", 0, 0)
            bar:SetPoint("RIGHT", frame, "RIGHT", 0, 0)
            if icon then icon:Hide() end
        end
    elseif icon then
        if iconPosition == "HIDDEN" then
            icon:Hide()
        else
            icon:Show()
            icon:SetSize(frameHeight, frameHeight)
        end
    end

    -- ===== 背景 =====
    local bgTex = EnsureBarBackground(bar)
    if bgTex and cfg.barBackgroundColor then
        local bc = cfg.barBackgroundColor
        bgTex:SetTexture(ResolveStatusBarTexture(cfg.barTexture))
        bgTex:SetVertexColor(bc.r or 0.1, bc.g or 0.1, bc.b or 0.1, bc.a or 0.8)
        bgTex:Show()
    end

    -- ===== 边框 =====
    EnsureBarBorder(bar)

    -- ===== 文本容器 =====
    if bar and not frame._vf_barTextContainer then
        local tc = CreateFrame("Frame", nil, bar)
        tc:SetAllPoints(bar)
        tc:SetFrameLevel((bar:GetFrameLevel() or 1) + 4)
        frame._vf_barTextContainer = tc
    end
    local textContainer = frame._vf_barTextContainer

    -- ===== 名称文本 =====
    if nameText then
        HookBarTextVisibility(frame, "_vf_nameHook", nameText, "showName")
        if cfg.showName == false then
            nameText:Hide()
        else
            if textContainer then
                nameText:SetParent(textContainer)
                textContainer:Show()
            end
            nameText:Show()
            nameText:SetAlpha(1)
            if nameText.SetDrawLayer then
                nameText:SetDrawLayer("OVERLAY", 7)
            end
            StyleApply.ApplyFontStyle(nameText, cfg.nameFont, "_vf_bar_name")
        end
    end

    -- ===== 持续时间文本 =====
    if durationText then
        HookBarTextVisibility(frame, "_vf_durHook", durationText, "showDuration")
        if cfg.showDuration == false then
            durationText:Hide()
        else
            if textContainer then
                durationText:SetParent(textContainer)
                textContainer:Show()
            end
            durationText:Show()
            durationText:SetAlpha(1)
            if durationText.SetDrawLayer then
                durationText:SetDrawLayer("OVERLAY", 7)
            end
            StyleApply.ApplyFontStyle(durationText, cfg.durationFont, "_vf_bar_dur")
        end
    end

    -- ===== 层数文本=====
    if appText then
        HookBarTextVisibility(frame, "_vf_stackHook", appText, "showStack")
        if cfg.showStack == false then
            appText:Hide()
            if frame._vf_barAppContainer then
                frame._vf_barAppContainer:Hide()
            end
        else
            -- 确保层数文本容器存在（parent为bar，层级高于bar）
            if bar and not frame._vf_barAppContainer then
                local container = CreateFrame("Frame", nil, bar)
                container:SetAllPoints(bar)
                container:SetFrameLevel((bar:GetFrameLevel() or 1) + 4)
                frame._vf_barAppContainer = container
            end
            if frame._vf_barAppContainer then
                frame._vf_barAppContainer:Show()
                -- 将层数文本从icon重新parent到bar的子容器
                appText:SetParent(frame._vf_barAppContainer)
            end
            appText:Show()
            appText:SetAlpha(1)
            if appText.SetDrawLayer then
                appText:SetDrawLayer("OVERLAY", 7)
            end
            StyleApply.ApplyFontStyle(appText, cfg.stackFont, "_vf_bar_stack")
        end
    end

    -- 记录版本号
    frame._vf_barStyled = true
    frame._vf_barStyleVer = barStyleVer
    frame._vf_barW = frameWidth
    frame._vf_barH = frameHeight
    frame._vf_barIconPos = iconPosition
end

--- 收集→排序→样式→定位
local function RefreshBuffBarViewer(viewer, cfg)
    local _pt = Profiler.start("CDS:RefreshBuffBarViewer")
    if not viewer or not cfg then Profiler.stop(_pt) return false end
    if viewer._vf_refreshing then Profiler.stop(_pt) return false end
    if not IsViewerReady(viewer) then Profiler.stop(_pt) return false end
    viewer._vf_refreshing = true

    -- 1. 收集可见帧并排序
    local frames = CollectBuffBarFrames(viewer)
    local count = #frames

    local width = ResolveBuffBarWidth(cfg)
    local height = cfg.barHeight or 20
    local spacing = cfg.barSpacing or 1
    local growDir = cfg.growDirection or "DOWN"

    if count == 0 then
        viewer._vf_refreshing = false
        Profiler.stop(_pt)
        return true
    end

    -- 2. 对每个帧：样式 → 定位 → 显示
    for i = 1, count do
        local frame = frames[i]
        local offset = (i - 1) * (height + spacing)

        -- 样式
        ApplyBuffBarFrameStyle(frame, cfg, width, height)

        -- 定位
        frame:ClearAllPoints()
        if growDir == "UP" then
            frame:SetPoint("BOTTOMLEFT", viewer, "BOTTOMLEFT", 0, offset)
        else
            frame:SetPoint("TOPLEFT", viewer, "TOPLEFT", 0, -offset)
        end

        -- 确保可见
        frame:SetAlpha(1)
    end

    viewer._vf_refreshing = false
    Profiler.stop(_pt)
    return true
end

-- =========================================================
-- 刷新Essential/Utility技能Viewer
-- =========================================================

local function RefreshSkillViewer(viewer, cfg)
    local _pt = Profiler.start("CDS:RefreshSkillViewer")
    if not viewer or not cfg then Profiler.stop(_pt) return end
    if viewer._vf_refreshing then Profiler.stop(_pt) return end
    viewer._vf_refreshing = true

    local allIcons = StyleLayout.CollectIcons(viewer)

    -- 分类图标：将自定义组的图标分离出去
    local mainVisible, groupBuckets = {}, {}
    if VFlow.SkillGroups and VFlow.SkillGroups.classifyIcons then
        mainVisible, groupBuckets = VFlow.SkillGroups.classifyIcons(allIcons)
        -- 过滤主viewer的可见图标
        mainVisible = StyleLayout.FilterVisible(mainVisible)
    else
        -- 降级：所有图标都显示在主viewer
        mainVisible = StyleLayout.FilterVisible(allIcons)
    end

    if #mainVisible == 0 then
        -- 隐藏所有无纹理的空图标，避免显示黑框
        for _, icon in ipairs(allIcons) do
            if icon:IsShown() and not (icon.Icon and icon.Icon:GetTexture()) then
                icon:SetAlpha(0)
            end
        end
        viewer:SetSize(1, 1)
        viewer._vf_refreshing = false
        return
    end

    local limit = cfg.maxIconsPerRow or 8
    local rows = StyleLayout.BuildRows(limit, mainVisible)
    local growUp = (cfg.growDirection == "up")

    local iconW = cfg.iconWidth or 40
    local iconH = cfg.iconHeight or 40
    local row2W = cfg.secondRowIconWidth or iconW
    local row2H = cfg.secondRowIconHeight or iconH

    local isH = (viewer.isHorizontal ~= false)
    local iconDir = (viewer.iconDirection == 1) and 1 or -1
    local spacingX = cfg.spacingX
    local spacingY = cfg.spacingY
    local fixedRowLengthByLimit = (cfg.fixedRowLengthByLimit == true)
    local rowAnchor = cfg.rowAnchor or "center"

    local yAccum = 0

    -- 计算最宽行宽度（用于居中对齐）
    local maxRowW = 0
    for ri, rIcons in ipairs(rows) do
        local rw = (ri == 1) and iconW or row2W
        local iconCountForWidth = fixedRowLengthByLimit and math.max(limit, 1) or #rIcons
        local rcw = iconCountForWidth * (rw + spacingX) - spacingX
        if rcw > maxRowW then maxRowW = rcw end
    end

    for rowIdx, rowIcons in ipairs(rows) do
        local w = (rowIdx == 1) and iconW or row2W
        local h = (rowIdx == 1) and iconH or row2H

        local rowContentW = #rowIcons * (w + spacingX) - spacingX
        local rowBaseW = fixedRowLengthByLimit and (math.max(limit, 1) * (w + spacingX) - spacingX) or maxRowW
        local alignOffset = rowBaseW - rowContentW
        local anchorOffset = 0
        if rowAnchor == "right" then
            anchorOffset = alignOffset
        elseif rowAnchor == "center" then
            anchorOffset = alignOffset / 2
        end
        local startX = ((maxRowW - rowBaseW) / 2 + anchorOffset) * iconDir
        if iconDir == -1 then startX = -startX end

        for colIdx, button in ipairs(rowIcons) do
            StyleApply.ApplyIconSize(button, w, h)

            local x, y
            if isH then
                x = startX + (colIdx - 1) * (w + spacingX) * iconDir
                y = growUp and yAccum or -yAccum
            else
                y = -(colIdx - 1) * (h + spacingY) * iconDir
                local rowOffset = (rowIdx - 1) * (w + spacingX)
                x = growUp and -rowOffset or rowOffset
            end

            StyleLayout.SetPointCached(button, "TOPLEFT", viewer, "TOPLEFT", x, y)
            if button._vf_btnStyleVer ~= _buttonStyleVersion then
                StyleApply.ApplyButtonStyle(button, cfg)
                button._vf_btnStyleVer = _buttonStyleVersion
            end

            if MasqueSupport and MasqueSupport:IsActive() then
                MasqueSupport:RegisterButton(button, button.Icon)
            end
        end

        yAccum = yAccum + h + spacingY
    end

    StyleLayout.UpdateViewerSizeToMatchIcons(viewer, mainVisible)

    -- 布局自定义技能组
    if VFlow.SkillGroups and VFlow.SkillGroups.layoutSkillGroups then
        VFlow.SkillGroups.layoutSkillGroups(groupBuckets)
    end

    viewer._vf_refreshing = false
    Profiler.stop(_pt)
end

-- =========================================================
-- 刷新BUFF Viewer
-- =========================================================

IsViewerReady = function(viewer)
    if not viewer then return false end
    if viewer.IsInitialized and not viewer:IsInitialized() then return false end
    if EditModeManagerFrame and EditModeManagerFrame.layoutApplyInProgress then return false end
    return true
end

local function HideFrameOffscreen(frame)
    if not frame then return end
    frame:SetAlpha(0)
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", -5000, 0)
end

local function ComputeReserveSlots(viewer, isH, w, h, spacingX, spacingY, iconLimit)
    local reserve = iconLimit or 20
    if reserve < 1 then reserve = 20 end

    if isH then
        local vw = viewer and viewer:GetWidth() or 0
        local step = w + spacingX
        if step > 0 and vw > 0 then
            local bySize = math.floor((vw + spacingX) / step)
            if bySize > reserve then reserve = bySize end
        end
        return reserve
    end

    local vh = viewer and viewer:GetHeight() or 0
    local step = h + spacingY
    if step > 0 and vh > 0 then
        local bySize = math.floor((vh + spacingY) / step)
        if bySize > reserve then reserve = bySize end
    end
    return reserve
end

local function ComputeSlotOffset(slot, totalSlots, isH, w, h, spacingX, spacingY, iconDir)
    if isH then
        local step = w + spacingX
        return (2 * slot - totalSlots + 1) * step / 2 * iconDir, 0
    end
    local step = h + spacingY
    return 0, (2 * slot - totalSlots + 1) * step / 2 * iconDir
end

local function ProvisionalPlaceBuffFrame(frame, viewer, cfg)
    Profiler.count("CDS:ProvisionalPlaceBuffFrame")
    if not frame or not viewer or not cfg then return end
    if not frame:IsShown() then return end
    if not (frame.Icon and frame.Icon:GetTexture()) then return end

    local w = cfg.width or 40
    local h = cfg.height or 40
    local spacingX = cfg.spacingX or 2
    local spacingY = cfg.spacingY or 2
    local iconLimit = viewer.iconLimit or 20
    if iconLimit < 1 then iconLimit = 20 end

    local isH = (viewer.isHorizontal ~= false)
    local iconDir = (viewer.iconDirection == 1) and 1 or -1

    local visible = StyleLayout.FilterVisible(StyleLayout.CollectIcons(viewer))
    local idx = nil
    for i = 1, #visible do
        if visible[i] == frame then idx = i break end
    end
    if not idx then
        visible[#visible + 1] = frame
        table.sort(visible, function(a, b)
            return (a.layoutIndex or 0) < (b.layoutIndex or 0)
        end)
        for i = 1, #visible do
            if visible[i] == frame then idx = i break end
        end
    end
    if not idx then return end

    local totalSlots = ComputeReserveSlots(viewer, isH, w, h, spacingX, spacingY, iconLimit)
    local slot
    if cfg.dynamicLayout then
        local count = #visible
        if count > totalSlots then totalSlots = count end
        local startSlot = 0
        local growDir = cfg.growDirection or "center"
        if growDir == "center" then
            startSlot = (totalSlots - count) / 2
        elseif growDir == "end" then
            startSlot = totalSlots - count
        end
        slot = startSlot + (idx - 1)
    else
        local rawSlot = (frame.layoutIndex or idx) - 1
        if rawSlot < 0 then rawSlot = 0 end
        local maxSlot = rawSlot
        for i = 1, #visible do
            local s = (visible[i].layoutIndex or i) - 1
            if s > maxSlot then maxSlot = s end
        end
        local usedSlots = math.max(maxSlot + 1, #visible)
        if usedSlots > totalSlots then totalSlots = usedSlots end
        local slotOffset = (totalSlots - usedSlots) / 2
        slot = rawSlot + slotOffset
    end

    local x, y = ComputeSlotOffset(slot, totalSlots, isH, w, h, spacingX, spacingY, iconDir)

    -- 1. 先应用样式（帧还在原parent下）
    StyleApply.ApplyIconSize(frame, w, h)
    if frame._vf_btnStyleVer ~= _buttonStyleVersion then
        StyleApply.ApplyButtonStyle(frame, cfg)
        frame._vf_btnStyleVer = _buttonStyleVersion
    end
    frame._vf_slot = slot

    -- 2. 再改父级
    if frame:GetParent() ~= UIParent then
        frame:SetParent(UIParent)
    end

    -- 3. 最后定位
    StyleLayout.SetPointCached(frame, "CENTER", viewer, "CENTER", x, y)
end

local function RefreshBuffViewer(viewer, cfg)
    local _pt = Profiler.start("CDS:RefreshBuffViewer")
    if not viewer or not cfg then Profiler.stop(_pt) return false end
    if viewer._vf_refreshing then Profiler.stop(_pt) return false end
    if not IsViewerReady(viewer) then Profiler.stop(_pt) return false end
    viewer._vf_refreshing = true

    local allIcons = StyleLayout.CollectIcons(viewer)

    -- 三路分类：主组可见、自定义组、隐藏
    local mainVisible, groupBuckets = {}, {}
    if VFlow.BuffGroups and VFlow.BuffGroups.classifyIcons then
        mainVisible, groupBuckets = VFlow.BuffGroups.classifyIcons(allIcons)
    else
        -- 降级：如果BuffGroups未加载，所有图标归主组
        mainVisible = allIcons
    end

    local w = cfg.width or 40
    local h = cfg.height or 40
    local spacingX = cfg.spacingX or 2
    local spacingY = cfg.spacingY or 2
    local iconLimit = viewer.iconLimit or 20
    if iconLimit < 1 then iconLimit = 20 end

    local isH = (viewer.isHorizontal ~= false)
    local iconDir = (viewer.iconDirection == 1) and 1 or -1
    local minSize = 400

    if isH then
        local blockW = iconLimit * (w + spacingX) - spacingX
        local targetW = math.max(minSize, blockW)
        local curW = viewer:GetWidth()
        if not curW or abs(curW - targetW) >= 1 then
            viewer:SetSize(targetW, h)
        end
    else
        local blockH = iconLimit * (h + spacingY) - spacingY
        local targetH = math.max(minSize, blockH)
        local curH = viewer:GetHeight()
        if not curH or abs(curH - targetH) >= 1 then
            viewer:SetSize(w, targetH)
        end
    end

    -- 过滤主组可见图标
    local visible = {}
    local hasNilTex = false
    local maxLayoutSlot = 0
    for i = 1, #mainVisible do
        local icon = mainVisible[i]
        local slot = (icon.layoutIndex or i) - 1
        if slot > maxLayoutSlot then
            maxLayoutSlot = slot
        end

        local shown = icon:IsShown()
        if shown and not (icon.Icon and icon.Icon:GetTexture()) then
            hasNilTex = true
            if cfg.dynamicLayout then
                HideFrameOffscreen(icon)
            end
        elseif shown then
            visible[#visible + 1] = icon
        end
    end

    local count = #visible
    local reserveSlots = ComputeReserveSlots(viewer, isH, w, h, spacingX, spacingY, iconLimit)
    local totalSlots = reserveSlots
    if totalSlots < 1 then totalSlots = iconLimit end
    if cfg.dynamicLayout and count > totalSlots then totalSlots = count end
    local usedSlots = math.max(maxLayoutSlot + 1, count)
    if not cfg.dynamicLayout and usedSlots > totalSlots then
        totalSlots = usedSlots
    end
    local fixedSlotOffset = 0
    if not cfg.dynamicLayout then
        fixedSlotOffset = (totalSlots - usedSlots) / 2
    end

    local startSlot = 0
    if cfg.dynamicLayout then
        local growDir = cfg.growDirection or "center"
        if growDir == "center" then
            startSlot = (totalSlots - count) / 2
        elseif growDir == "end" then
            startSlot = totalSlots - count
        end
    end

    -- 应用样式到主组图标（先样式，后SetParent，最后定位）
    for i = 1, count do
        local button = visible[i]

        local slot = cfg.dynamicLayout and (startSlot + i - 1) or (((button.layoutIndex or i) - 1) + fixedSlotOffset)
        if slot < 0 then slot = 0 end
        button._vf_slot = slot

        local x, y = ComputeSlotOffset(slot, totalSlots, isH, w, h, spacingX, spacingY, iconDir)

        -- 1. 先应用样式（帧还在原parent下，避免样式操作触发UIParent下的重渲染）
        StyleApply.ApplyIconSize(button, w, h)
        -- 版本号跳过：按钮已在当前配置版本下完成样式化则跳过
        if button._vf_btnStyleVer ~= _buttonStyleVersion then
            StyleApply.ApplyButtonStyle(button, cfg)
            button._vf_btnStyleVer = _buttonStyleVersion
        end

        if MasqueSupport and MasqueSupport:IsActive() then
            MasqueSupport:RegisterButton(button, button.Icon)
        end

        -- 2. 再改父级（样式已稳定，不会再触发重渲染）
        if button:GetParent() ~= UIParent then
            button:SetParent(UIParent)
        end

        -- 3. 最后定位并显示
        StyleLayout.SetPointCached(button, "CENTER", viewer, "CENTER", x, y)
        button:SetAlpha(1)
    end

    -- 布局自定义组（样式应用在LayoutBuffGroups内部完成）
    if VFlow.BuffGroups and VFlow.BuffGroups.layoutBuffGroups then
        VFlow.BuffGroups.layoutBuffGroups(groupBuckets)
    end

    viewer._vf_refreshing = false

    if hasNilTex and RequestBuffRefresh then
        C_Timer.After(0.05, function()
            RequestBuffRefresh()
        end)
    end

    Profiler.stop(_pt)
    return true
end

-- =========================================================
-- Hook管理
-- =========================================================

local hooked = false
local refreshPending = false
local SetupHooks
local buffRefreshPending = false
local buffBarRefreshPending = false
local DoBuffRefresh
local DoBuffBarRefresh

local function SetupBuffRuntimeHandlers()
    if not BuffRuntime then return end

    -- CollectIcons 缓存：只在 children 数量变化或 dirty 时重新收集
    local iconCache = {}
    local iconCacheChildCount = -1

    BuffRuntime.setHandlers({
        getViewer = function()
            local viewer = GetBuffViewerAndConfig()
            return viewer
        end,
        getConfig = function()
            local _, cfg = GetBuffViewerAndConfig()
            return cfg
        end,
        collectVisible = function(viewer, isDirty)
            local cc = select('#', viewer:GetChildren())
            if cc ~= iconCacheChildCount or isDirty then
                iconCache = StyleLayout.CollectIcons(viewer)
                iconCacheChildCount = cc
            end
            return StyleLayout.FilterVisible(iconCache)
        end,
        refresh = function(viewer, cfg)
            -- refresh 后强制刷新缓存（布局可能改变了 children）
            iconCacheChildCount = -1
            RefreshBuffViewer(viewer, cfg)
        end,
    })
end

local function SetupBuffBarRuntimeHandlers()
    if not BuffBarRuntime then return end

    BuffBarRuntime.setHandlers({
        getViewer = function()
            local viewer = GetBuffBarViewerAndConfig()
            return viewer
        end,
        getConfig = function()
            local _, cfg = GetBuffBarViewerAndConfig()
            return cfg
        end,
        collectVisible = function(viewer, isDirty)
            local frames = CollectBuffBarFrames(viewer)
            local visible = {}
            for i = 1, #frames do
                if frames[i]:IsShown() then
                    visible[#visible + 1] = frames[i]
                end
            end
            return visible
        end,
        refresh = function(viewer, cfg)
            RefreshBuffBarViewer(viewer, cfg)
        end,
    })
end

DoBuffRefresh = function(attempt)
    Profiler.count("CDS:DoBuffRefresh")
    local viewer, cfg = GetBuffViewerAndConfig()
    if not viewer or not cfg then
        if BuffRuntime then BuffRuntime.disable() end
        return
    end
    if not IsViewerReady(viewer) then
        if (attempt or 0) < MAX_BUFF_READY_RETRIES then
            C_Timer.After(0.05, function()
                DoBuffRefresh((attempt or 0) + 1)
            end)
        end
        return
    end

    local ok = RefreshBuffViewer(viewer, cfg)
    if not ok then
        if (attempt or 0) < MAX_BUFF_READY_RETRIES then
            C_Timer.After(0.05, function()
                DoBuffRefresh((attempt or 0) + 1)
            end)
        end
        return
    end

    if not BuffRuntime then return end
    BuffRuntime.markDirty()
    BuffRuntime.enable()
end

RequestBuffRefresh = function()
    Profiler.count("CDS:RequestBuffRefresh")
    if buffRefreshPending then return end
    buffRefreshPending = true
    C_Timer.After(0, function()
        buffRefreshPending = false
        DoBuffRefresh(0)
    end)
    -- followup 由 BuffRuntime.enable() 的 watchdog 机制保证，不再双重调度
end

DoBuffBarRefresh = function(attempt)
    Profiler.count("CDS:DoBuffBarRefresh")
    local viewer, cfg = GetBuffBarViewerAndConfig()
    if not viewer or not cfg then
        if BuffBarRuntime then BuffBarRuntime.disable() end
        return
    end
    if not IsViewerReady(viewer) then
        if (attempt or 0) < MAX_BUFFBAR_READY_RETRIES then
            C_Timer.After(0.05, function()
                DoBuffBarRefresh((attempt or 0) + 1)
            end)
        end
        return
    end

    local ok = RefreshBuffBarViewer(viewer, cfg)
    if not ok and (attempt or 0) < MAX_BUFFBAR_READY_RETRIES then
        C_Timer.After(0.05, function()
            DoBuffBarRefresh((attempt or 0) + 1)
        end)
        return
    end

    if not BuffBarRuntime then return end

    -- 始终启用runtime监控
    BuffBarRuntime.markDirty()
    BuffBarRuntime.enable()
end

RequestBuffBarRefresh = function()
    Profiler.count("CDS:RequestBuffBarRefresh")
    if buffBarRefreshPending then return end
    buffBarRefreshPending = true
    -- 同步执行，避免闪烁
    DoBuffBarRefresh(0)
    buffBarRefreshPending = false
end

local function DoRefresh()
    local skillsDB = VFlow and VFlow.Store and VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.Skills")
    local buffsDB = VFlow and VFlow.Store and VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.Buffs")
    local buffBarDB = VFlow and VFlow.Store and VFlow.Store.getModuleRef and VFlow.Store.getModuleRef("VFlow.BuffBar")

    if skillsDB then
        if EssentialCooldownViewer and skillsDB.importantSkills then
            RefreshSkillViewer(EssentialCooldownViewer, skillsDB.importantSkills)
        end
        if UtilityCooldownViewer and skillsDB.efficiencySkills then
            RefreshSkillViewer(UtilityCooldownViewer, skillsDB.efficiencySkills)
        end
    end

    if buffsDB and buffsDB.buffMonitor then
        RequestBuffRefresh()
    end

    if buffBarDB then
        RequestBuffBarRefresh()
    end
end

local function RequestRefresh(delay)
    if delay and delay > 0 then
        if refreshPending then return end
        refreshPending = true
        C_Timer.After(delay, function()
            refreshPending = false
            DoRefresh()
        end)
    else
        DoRefresh()
    end
end

SetupHooks = function()
    if hooked then return end
    SetupBuffRuntimeHandlers()
    SetupBuffBarRuntimeHandlers()

    local function SafeHook(obj, method, handler)
        if obj and obj[method] then
            hooksecurefunc(obj, method, handler)
        end
    end

    local skillHandler = function() RequestRefresh(0) end
    local buffHandler = function() RequestBuffRefresh() end
    local buffBarHandler = function() RequestBuffBarRefresh() end
    local buffBarImmediateHandler = function()
        DoBuffBarRefresh(0)
    end

    -- 帧末尾合并刷新：同一帧内多次 provisionalPlaceAndQueue 只做一次 DoBuffRefresh
    local _pendingSyncRefresh = false
    local _syncRefreshFrame = CreateFrame("Frame")
    _syncRefreshFrame:Hide()
    _syncRefreshFrame:SetScript("OnUpdate", function(self)
        self:Hide()
        _pendingSyncRefresh = false
        DoBuffRefresh(0)
    end)

    -- OnCooldownIDSet时：先ApplyStyle建立缓存，再ProvisionalPlace定位
    -- 确保样式初始化在定位之前完成，首次触发不会因样式操作触发重渲染
    local provisionalPlaceAndQueue = function(frame)
        Profiler.count("CDS:provisionalPlaceAndQueue")
        if not frame then return end
        local viewer, cfg = GetBuffViewerAndConfig()
        if not viewer or not cfg then return end
        -- 分组帧由BuffGroups自己管理，不走主组provisional逻辑
        if VFlow.BuffGroups and VFlow.BuffGroups.isGroupFrame and VFlow.BuffGroups.isGroupFrame(frame) then
            RequestBuffRefresh()
            return
        end
        StyleApply.ApplyIconSize(frame, cfg.width or 40, cfg.height or 40)
        StyleApply.ApplyButtonStyle(frame, cfg)
        frame._vf_btnStyleVer = _buttonStyleVersion
        ProvisionalPlaceBuffFrame(frame, viewer, cfg)
        -- 合并同一帧内的多次刷新：OnUpdate 在当前帧末尾触发一次 DoBuffRefresh
        if not _pendingSyncRefresh then
            _pendingSyncRefresh = true
            _syncRefreshFrame:Show()
        end
    end

    local function enforceScaleOnViewer(viewer)
        if not viewer then return end
        -- 强制viewer本身scale为1
        if viewer.SetScale and viewer:GetScale() ~= 1 then
            viewer:SetScale(1)
        end
        -- 强制pool中所有帧scale为1
        if viewer.itemFramePool then
            for frame in viewer.itemFramePool:EnumerateActive() do
                if frame and frame.SetScale and frame:GetScale() ~= 1 then
                    frame:SetScale(1)
                end
            end
        end
    end

    local function hookScaleForViewer(viewer)
        if not viewer or viewer._vf_scaleHooked then return end
        viewer._vf_scaleHooked = true
        -- hook OnAcquireItemFrame，每个帧出池时强制scale为1
        if viewer.OnAcquireItemFrame then
            hooksecurefunc(viewer, "OnAcquireItemFrame", function(_, frame)
                if frame and frame.SetScale and frame:GetScale() ~= 1 then
                    frame:SetScale(1)
                end
            end)
        end
        -- hook UpdateSystemSettingIconSize，阻止系统scale设置生效
        if viewer.UpdateSystemSettingIconSize then
            hooksecurefunc(viewer, "UpdateSystemSettingIconSize", function()
                enforceScaleOnViewer(viewer)
            end)
        end
    end

    if EssentialCooldownViewer then
        SafeHook(EssentialCooldownViewer, "RefreshLayout", skillHandler)
        hookScaleForViewer(EssentialCooldownViewer)
        enforceScaleOnViewer(EssentialCooldownViewer)
    end
    if UtilityCooldownViewer then
        SafeHook(UtilityCooldownViewer, "RefreshLayout", skillHandler)
        hookScaleForViewer(UtilityCooldownViewer)
        enforceScaleOnViewer(UtilityCooldownViewer)
    end

    if BuffIconCooldownViewer then
        SafeHook(BuffIconCooldownViewer, "RefreshLayout", buffHandler)
        SafeHook(BuffIconCooldownViewer, "RefreshData", buffHandler)
        SafeHook(BuffIconCooldownViewer, "UpdateLayout", buffHandler)
        SafeHook(BuffIconCooldownViewer, "Layout", buffHandler)
        SafeHook(BuffIconCooldownViewer, "SetPoint", buffHandler)
        BuffIconCooldownViewer:HookScript("OnShow", buffHandler)
        -- OnAcquireItemFrame：只做最少初始化，不做样式应用
        SafeHook(BuffIconCooldownViewer, "OnAcquireItemFrame", function(_, frame)
            if not frame then return end
            if frame.SetScale and frame:GetScale() ~= 1 then
                frame:SetScale(1)
            end
            -- 直接hook帧本身的OnCooldownIDSet（帧用的Mixin与CooldownViewerBuffIconItemMixin不同）
            if frame.OnCooldownIDSet and not frame._vf_cdIDHooked then
                frame._vf_cdIDHooked = true
                hooksecurefunc(frame, "OnCooldownIDSet", function(self)
                    provisionalPlaceAndQueue(self)
                end)
            end
            if frame.OnActiveStateChanged and not frame._vf_activeStateHooked then
                frame._vf_activeStateHooked = true
                hooksecurefunc(frame, "OnActiveStateChanged", function(self)
                    provisionalPlaceAndQueue(self)
                end)
            end
            RequestBuffRefresh()
        end)

        if BuffIconCooldownViewer.itemFramePool then
            hooksecurefunc(BuffIconCooldownViewer.itemFramePool, "Acquire", function(pool, frame)
                -- 最早时机，修正Scale
                if frame and frame.SetScale and frame:GetScale() ~= 1 then
                    frame:SetScale(1)
                end
            end)
            hooksecurefunc(BuffIconCooldownViewer.itemFramePool, "Release", buffHandler)
        end
    end

    if BuffBarCooldownViewer then
        SafeHook(BuffBarCooldownViewer, "RefreshData", buffBarHandler)
        BuffBarCooldownViewer:HookScript("OnShow", buffBarHandler)

        SafeHook(BuffBarCooldownViewer, "OnAcquireItemFrame", function(_, frame)
            if not frame then return end
            local viewer, cfg = GetBuffBarViewerAndConfig()
            if not viewer or not cfg then return end

            -- 强制scale为1
            if frame.SetScale then frame:SetScale(1) end

            -- 立即应用样式（强制，因为帧可能是复用的）
            frame._vf_barStyled = false
            local width = ResolveBuffBarWidth(cfg)
            local height = cfg.barHeight or 20
            ApplyBuffBarFrameStyle(frame, cfg, width, height)

            -- 标记runtime脏
            if BuffBarRuntime then BuffBarRuntime.markDirty() end
        end)

        if BuffBarCooldownViewer.itemFramePool then
            hooksecurefunc(BuffBarCooldownViewer.itemFramePool, "Release", buffBarImmediateHandler)
        end
    end

    if CooldownViewerBuffIconItemMixin then
        if CooldownViewerBuffIconItemMixin.OnCooldownIDSet then
            hooksecurefunc(CooldownViewerBuffIconItemMixin, "OnCooldownIDSet", function(frame)
                provisionalPlaceAndQueue(frame)
            end)
        end
        if CooldownViewerBuffIconItemMixin.OnActiveStateChanged then
            hooksecurefunc(CooldownViewerBuffIconItemMixin, "OnActiveStateChanged", function(frame)
                provisionalPlaceAndQueue(frame)
            end)
        end
    end

    -- BuffBar 的 Mixin hook
    if CooldownViewerBuffBarItemMixin then
        if CooldownViewerBuffBarItemMixin.OnCooldownIDSet then
            hooksecurefunc(CooldownViewerBuffBarItemMixin, "OnCooldownIDSet", function(frame)
                if not frame then return end
                local viewer, cfg = GetBuffBarViewerAndConfig()
                if not viewer or not cfg then return end
                -- 强制scale为1
                if frame.SetScale then frame:SetScale(1) end
                -- 立即对单帧应用样式
                frame._vf_barStyled = false
                local width = ResolveBuffBarWidth(cfg)
                local height = cfg.barHeight or 20
                ApplyBuffBarFrameStyle(frame, cfg, width, height)
                -- 确保帧可见（OnAcquire时可能还没Show，现在有内容了）
                frame:SetAlpha(1)
                -- 同步刷新全局布局
                DoBuffBarRefresh(0)
            end)
        end
        if CooldownViewerBuffBarItemMixin.OnActiveStateChanged then
            hooksecurefunc(CooldownViewerBuffBarItemMixin, "OnActiveStateChanged", function(frame)
                if not frame then return end
                frame._vf_barStyled = false
                DoBuffBarRefresh(0)
            end)
        end
        if CooldownViewerBuffBarItemMixin.SetBarContent then
            hooksecurefunc(CooldownViewerBuffBarItemMixin, "SetBarContent", function(frame)
                if not frame then return end
                frame._vf_barStyled = false
                -- SetBarContent 更新了文本内容（层数等），立即重新样式化
                local viewer, cfg = GetBuffBarViewerAndConfig()
                if viewer and cfg then
                    local width = ResolveBuffBarWidth(cfg)
                    local height = cfg.barHeight or 20
                    ApplyBuffBarFrameStyle(frame, cfg, width, height)
                end
                -- 确保帧可见
                frame:SetAlpha(1)
                DoBuffBarRefresh(0)
            end)
        end
    end

    if EventRegistry then
        EventRegistry:RegisterCallback("CooldownViewerSettings.OnDataChanged", function()
            RequestRefresh(0.2)
        end)
    end

    hooked = true
end

-- =========================================================
-- 初始化
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "VFlow.SkillStyle", function()
    InvalidateDBCache()
    BumpButtonStyleVersion()
    if BuffBarRuntime then BuffBarRuntime.bumpStyleVersion() end
    SetupHooks()
    RequestRefresh(0.5)
end)

-- =========================================================
-- 监听配置变更，自动刷新
-- =========================================================

-- 监听技能模块配置变更
VFlow.Store.watch("VFlow.Skills", "CooldownStyle_Skills", function(key, value)
    BumpButtonStyleVersion()
    RequestRefresh(0)
end)

-- 监听BUFF模块配置变更
VFlow.Store.watch("VFlow.Buffs", "CooldownStyle_Buffs", function(key, value)
    InvalidateDBCache()
    -- x/y坐标变化不需要触发样式引擎刷新
    if key:find("%.x$") or key:find("%.y$") then
        return
    end
    BumpButtonStyleVersion()
    RequestRefresh(0)
end)

VFlow.Store.watch("VFlow.BuffBar", "CooldownStyle_BuffBar", function(key, value)
    InvalidateDBCache()
    BumpButtonStyleVersion()
    if BuffBarRuntime then BuffBarRuntime.bumpStyleVersion() end
    RequestBuffBarRefresh()
end)

-- 监听自定义监控模块配置变更（隐藏功能）
VFlow.Store.watch("VFlow.CustomMonitor", "CooldownStyle_CustomMonitor", function(key, value)
    -- 只有hideInCooldownManager变化时才刷新
    if key:find("%.hideInCooldownManager$") then
        RequestRefresh(0)
    end
end)

-- 监听美化模块配置变更
VFlow.Store.watch("VFlow.StyleIcon", "CooldownStyle_StyleIcon", function(key, value)
    BumpButtonStyleVersion()
    RequestRefresh(0)
end)

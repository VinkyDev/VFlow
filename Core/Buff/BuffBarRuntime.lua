-- =========================================================
-- VFlow BuffBarRuntime
-- 职责：BuffBarCooldownViewer（条形 BUFF）刷新链路
--   - ApplyBuffBarFrameStyle：单帧样式（图标/进度条/背景/边框/三段文本）
--   - RefreshBuffBarViewer：收集 → 排序 → 样式 → 定位
--   - DoBuffBarRefresh：带 ready 重试
--   - VFlow.RequestBuffBarRefresh：通过 ViewerRuntime 入队
--
-- 由 RefreshBus.SCOPES.BUFFBAR_LAYOUT 调用。
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.BUFF_BAR_ENABLED then return end

local Utils = VFlow.Utils
local StyleApply = VFlow.StyleApply
local StyleLayout = VFlow.StyleLayout
local RefreshBus = VFlow.RefreshBus
local ViewerRuntime = VFlow.ViewerRuntime
local PP = VFlow.PixelPerfect
local Profiler = VFlow.Profiler
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

local BuffBarRuntime = {}
VFlow.BuffBarRuntime = BuffBarRuntime

local QK_BUFF_BAR = "BuffBarCooldownViewer"
local MAX_BUFFBAR_READY_RETRIES = 20

-- =========================================================
-- SECTION 1: 样式版本与 DB 缓存
-- =========================================================

local _buffBarStyleVersion = 0

local function BumpBuffBarStyleVersion()
    _buffBarStyleVersion = _buffBarStyleVersion + 1
end

local _cachedBuffBarDB

local function InvalidateDBCache()
    local store = VFlow.Store
    if not store or not store.getModuleRef then return end
    _cachedBuffBarDB = store.getModuleRef("VFlow.BuffBar")
end

local function GetBuffBarViewerAndConfig()
    local viewer = _G.BuffBarCooldownViewer
    return viewer, _cachedBuffBarDB
end

local function IsViewerReady(viewer)
    if not viewer then return false end
    if viewer.IsInitialized and not viewer:IsInitialized() then return false end
    if EditModeManagerFrame and EditModeManagerFrame.layoutApplyInProgress then return false end
    return true
end

-- =========================================================
-- SECTION 2: 纹理 / 宽度解析与帧收集
-- =========================================================

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
    if not viewer then
        return {}
    end
    local frames = viewer._vf_cdf_bar_collect_work
    if not frames then
        frames = {}
        viewer._vf_cdf_bar_collect_work = frames
    else
        wipe(frames)
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
    Utils.sortByLayoutIndex(frames)
    return frames
end

-- =========================================================
-- SECTION 3: 单帧样式（脏检查）
-- =========================================================

local function HideIconOverlays(iconFrame)
    if not iconFrame then return end
    local function IsSafeEqual(v, expected)
        if type(v) == "number" and issecretvalue and issecretvalue(v) then
            return false
        end
        return v == expected
    end
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

    -- 行帧不走路径 ApplyButtonStyle；需同步图标样式的 Debuff 红框 / 播疫 / CD 动画等隐藏（见 StyleApply.ApplyViewerItemVisualHides）
    StyleApply.ApplyViewerItemVisualHides(frame)

    local barStyleVer = _buffBarStyleVersion
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

-- =========================================================
-- SECTION 4: Viewer 刷新主循环
-- =========================================================

local QueueBuffBarRefresh

local function RefreshBuffBarViewer(viewer, cfg)
    if not viewer or not cfg then return false end
    if viewer._vf_refreshing then
        viewer._vf_needsReRefresh = true
        return false
    end
    if not IsViewerReady(viewer) then return false end

    viewer._vf_refreshing = true
    viewer._vf_needsReRefresh = false

    local width = ResolveBuffBarWidth(cfg)
    local height = cfg.barHeight or 20
    local spacing = cfg.barSpacing or 1
    local barLevel = (viewer.GetFrameLevel and viewer:GetFrameLevel() or 0) + 1
    local frames = CollectBuffBarFrames(viewer)
    local count = #frames

    if count == 0 then
        local targetW = math.max(1, width)
        local targetH = math.max(1, height)
        if math.abs((viewer:GetWidth() or 0) - targetW) >= 0.1
            or math.abs((viewer:GetHeight() or 0) - targetH) >= 0.1 then
            viewer:SetSize(targetW, targetH)
        end
        viewer._vf_refreshing = false
        if viewer._vf_needsReRefresh then
            viewer._vf_needsReRefresh = false
            QueueBuffBarRefresh()
        end
        return true
    end

    local containerHeight = (count * height) + ((count - 1) * spacing)
    local targetH = math.max(height, containerHeight)
    if math.abs((viewer:GetWidth() or 0) - width) >= 0.1
        or math.abs((viewer:GetHeight() or 0) - targetH) >= 0.1 then
        viewer:SetSize(width, targetH)
    end

    for i = 1, count do
        local frame = frames[i]
        local offset = (i - 1) * (height + spacing)

        if frame:GetParent() ~= viewer then
            frame:SetParent(viewer)
        end
        if frame.SetFrameLevel then
            frame:SetFrameLevel(barLevel)
        end

        ApplyBuffBarFrameStyle(frame, cfg, width, height)

        -- BuffBar 当前临时仅支持“居中锚点下的固定排布”。方向配置先不启用，避免与系统 EditMode 锚点策略冲突。
        StyleLayout.SetPointCached(frame, "TOPLEFT", viewer, "TOPLEFT", 0, -offset)
        frame:SetAlpha(1)
    end

    viewer._vf_refreshing = false

    if viewer._vf_needsReRefresh then
        viewer._vf_needsReRefresh = false
        QueueBuffBarRefresh()
    end

    return true
end

-- =========================================================
-- SECTION 5: 入队 / 安全入口
-- =========================================================

QueueBuffBarRefresh = function(opt)
    opt = opt or {}
    local viewer = _G.BuffBarCooldownViewer
    if viewer and viewer._vf_refreshing then
        viewer._vf_needsReRefresh = true
        return
    end
    if ViewerRuntime and ViewerRuntime.request then
        ViewerRuntime.request(QK_BUFF_BAR, "manual", opt)
        return
    end
    if RefreshBus and RefreshBus.requestViewers then
        RefreshBus.requestViewers(RefreshBus.PRESETS.BUFFBAR_FULL, { QK_BUFF_BAR }, opt)
    end
end

local function DoBuffBarRefresh(attempt)
    local viewer, cfg = GetBuffBarViewerAndConfig()
    if not viewer or not cfg then
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
    if not ok then
        if viewer and viewer._vf_needsReRefresh then
            -- 重入已由 RefreshBuffBarViewer 标记，由当前刷新末尾再次入队
        elseif (attempt or 0) < MAX_BUFFBAR_READY_RETRIES then
            C_Timer.After(0.05, function()
                DoBuffBarRefresh((attempt or 0) + 1)
            end)
        end
        return
    end
end

--- @param opt table|nil opt.immediate 为 true 时同帧刷新（RefreshData / Layout /池 Release）
local function RequestBuffBarRefresh(opt)
    QueueBuffBarRefresh(opt)
end

-- =========================================================
-- SECTION 6: 注册到 RefreshBus（BUFFBAR_LAYOUT）
-- =========================================================

if RefreshBus then
    RefreshBus.register(RefreshBus.SCOPES.BUFFBAR_LAYOUT, "CooldownStyle_BuffBarLayout", function(context)
        if context.dirtyViewers and context.dirtyViewers[QK_BUFF_BAR] then
            DoBuffBarRefresh(0)
        end
    end)
end

-- =========================================================
-- SECTION 7: Profiler 注册
-- =========================================================

if Profiler and Profiler.registerCount then
    Profiler.registerCount("CDS:GetBuffBarViewerAndConfig", function()
        return GetBuffBarViewerAndConfig
    end, function(fn)
        GetBuffBarViewerAndConfig = fn
    end)
    Profiler.registerCount("CDS:CollectBuffBarFrames", function()
        return CollectBuffBarFrames
    end, function(fn)
        CollectBuffBarFrames = fn
    end)
    Profiler.registerCount("CDS:DoBuffBarRefresh", function()
        return DoBuffBarRefresh
    end, function(fn)
        DoBuffBarRefresh = fn
    end)
    Profiler.registerCount("CDS:RequestBuffBarRefresh", function()
        return RequestBuffBarRefresh
    end, function(fn)
        RequestBuffBarRefresh = fn
    end)
end

if Profiler and Profiler.registerScope then
    Profiler.registerScope("CDS:RefreshBuffBarViewer", function()
        return RefreshBuffBarViewer
    end, function(fn)
        RefreshBuffBarViewer = fn
    end)
end

-- =========================================================
-- SECTION 8: 公共接口
-- =========================================================

VFlow.RequestBuffBarRefresh = RequestBuffBarRefresh

BuffBarRuntime.invalidateDBCache = InvalidateDBCache
BuffBarRuntime.bumpStyleVersion = BumpBuffBarStyleVersion
BuffBarRuntime.getStyleVersion = function() return _buffBarStyleVersion end
BuffBarRuntime.getViewerAndConfig = GetBuffBarViewerAndConfig
BuffBarRuntime.isViewerReady = IsViewerReady
BuffBarRuntime.applyFrameStyle = ApplyBuffBarFrameStyle
BuffBarRuntime.refreshViewer = RefreshBuffBarViewer
BuffBarRuntime.doRefresh = DoBuffBarRefresh
BuffBarRuntime.requestRefresh = RequestBuffBarRefresh
BuffBarRuntime.resolveBuffBarWidth = ResolveBuffBarWidth
BuffBarRuntime.QK = QK_BUFF_BAR

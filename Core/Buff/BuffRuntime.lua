-- =========================================================
-- VFlow BuffRuntime
-- 职责：BuffIconCooldownViewer 刷新链路
--   - RefreshBuffViewer：分类（主区/自定义组）、计算 slot 与位置、应用样式、扫描自定义高亮
--   - DoBuffRefresh：带 ready 重试的安全入口
--   - VFlow.RequestBuffRefresh：通过 ViewerRuntime 入队
--
-- 由 RefreshBus.SCOPES.BUFF_LAYOUT 调用，与 BuffGroups 协作。
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CORE_ENABLED then return end

local StyleApply = VFlow.StyleApply
local StyleLayout = VFlow.StyleLayout
local MasqueSupport = VFlow.MasqueSupport
local RefreshBus = VFlow.RefreshBus
local ViewerRuntime = VFlow.ViewerRuntime
local CustomHighlight = VFlow.CustomHighlight
local Profiler = VFlow.Profiler
local abs = math.abs

local BuffRuntime = {}
VFlow.BuffRuntime = BuffRuntime

local QK_BUFF_ICONS = "BuffIconCooldownViewer"
local MAX_BUFF_READY_RETRIES = 20

-- =========================================================
-- SECTION 1: DB / Viewer 取数
-- =========================================================

local _cachedBuffsDB

local function InvalidateDBCache()
    local store = VFlow.Store
    if not store or not store.getModuleRef then return end
    _cachedBuffsDB = store.getModuleRef("VFlow.Buffs")
end

local function GetBuffViewerAndConfig()
    local viewer = _G.BuffIconCooldownViewer
    local cfg = _cachedBuffsDB and _cachedBuffsDB.buffMonitor
    return viewer, cfg
end

local function IsViewerReady(viewer)
    if not viewer then return false end
    if viewer.IsInitialized and not viewer:IsInitialized() then return false end
    if EditModeManagerFrame and EditModeManagerFrame.layoutApplyInProgress then return false end
    return true
end

-- =========================================================
-- SECTION 2: 几何辅助
-- =========================================================

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

-- =========================================================
-- SECTION 3: 主刷新
-- =========================================================

local RequestBuffRefresh

local function RefreshBuffViewer(viewer, cfg)
    if not viewer or not cfg then return false end
    if viewer._vf_refreshing then
        viewer._vf_needsReRefresh = true
        return false
    end
    if not IsViewerReady(viewer) then return false end
    viewer._vf_refreshing = true

    local allIcons = StyleLayout.CollectIcons(viewer)

    local mainVisible, groupBuckets = {}, {}
    if VFlow.BuffGroups and VFlow.BuffGroups.classifyIcons then
        mainVisible, groupBuckets = VFlow.BuffGroups.classifyIcons(allIcons)
    else
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

    for i = 1, count do
        local button = visible[i]

        local slot = cfg.dynamicLayout and (startSlot + i - 1) or (((button.layoutIndex or i) - 1) + fixedSlotOffset)
        if slot < 0 then slot = 0 end
        button._vf_slot = slot

        local x, y = ComputeSlotOffset(slot, totalSlots, isH, w, h, spacingX, spacingY, iconDir)

        StyleApply.ApplyIconSize(button, w, h)
        -- BUFF 仍沿用旧链路（本轮重构重点是技能组刷新）；后续可单独将 BUFF 也接入 RefreshBus。
        StyleApply.ApplyButtonStyleIfStale(button, cfg)

        if MasqueSupport and MasqueSupport:IsActive() then
            MasqueSupport:RegisterButton(button, button.Icon)
        end

        button._vf_cdmKind = "buff"

        if button:GetParent() ~= viewer then
            button:SetParent(viewer)
        end

        StyleLayout.SetPointCached(button, "CENTER", viewer, "CENTER", x, y)
        button:SetAlpha(1)
    end

    if VFlow.BuffGroups and VFlow.BuffGroups.layoutBuffGroups then
        VFlow.BuffGroups.layoutBuffGroups(groupBuckets)
    end

    if CustomHighlight then
        CustomHighlight.scanViewer(viewer, allIcons)
        CustomHighlight.scanBuffGroups()
    end

    viewer._vf_refreshing = false

    if viewer._vf_needsReRefresh then
        viewer._vf_needsReRefresh = false
        if RequestBuffRefresh then
            RequestBuffRefresh()
        end
    end

    if hasNilTex then
        C_Timer.After(0.05, function()
            if RequestBuffRefresh then
                RequestBuffRefresh()
            end
        end)
    end

    return true
end

-- =========================================================
-- SECTION 4: 安全入口
-- =========================================================

local function DoBuffRefresh(attempt)
    local viewer, cfg = GetBuffViewerAndConfig()
    if not viewer or not cfg then
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
        if viewer and viewer._vf_needsReRefresh then
            -- 重入已由 RefreshBuffViewer 标记，由当前刷新末尾再次入队
        elseif (attempt or 0) < MAX_BUFF_READY_RETRIES then
            C_Timer.After(0.05, function()
                DoBuffRefresh((attempt or 0) + 1)
            end)
        end
        return
    end
end

--- @param opt table|nil opt.immediate 为 true 时本帧立即刷新 Buff 图标（含自定义 Buff 组布局）
RequestBuffRefresh = function(opt)
    opt = opt or {}
    if ViewerRuntime and ViewerRuntime.request then
        ViewerRuntime.request(QK_BUFF_ICONS, "manual", opt)
        return
    end
    if RefreshBus and RefreshBus.requestViewers then
        RefreshBus.requestViewers(RefreshBus.PRESETS.BUFF_FULL, { QK_BUFF_ICONS }, opt)
    end
end

-- =========================================================
-- SECTION 5: 注册到 RefreshBus（BUFF_LAYOUT）
-- =========================================================

if RefreshBus then
    RefreshBus.register(RefreshBus.SCOPES.BUFF_LAYOUT, "CooldownStyle_BuffLayout", function(context)
        if context.dirtyViewers and context.dirtyViewers[QK_BUFF_ICONS] then
            DoBuffRefresh(0)
        end
    end)
end

-- =========================================================
-- SECTION 6: Profiler 注册
-- =========================================================

if Profiler and Profiler.registerCount then
    Profiler.registerCount("CDS:GetBuffViewerAndConfig", function()
        return GetBuffViewerAndConfig
    end, function(fn)
        GetBuffViewerAndConfig = fn
    end)
    Profiler.registerCount("CDS:DoBuffRefresh", function()
        return DoBuffRefresh
    end, function(fn)
        DoBuffRefresh = fn
    end)
    Profiler.registerCount("CDS:RequestBuffRefresh", function()
        return RequestBuffRefresh
    end, function(fn)
        RequestBuffRefresh = fn
    end)
end

if Profiler and Profiler.registerScope then
    Profiler.registerScope("CDS:RefreshBuffViewer", function()
        return RefreshBuffViewer
    end, function(fn)
        RefreshBuffViewer = fn
    end)
end

-- =========================================================
-- SECTION 7: 公共接口
-- =========================================================

VFlow.RequestBuffRefresh = RequestBuffRefresh

BuffRuntime.invalidateDBCache = InvalidateDBCache
BuffRuntime.getBuffViewerAndConfig = GetBuffViewerAndConfig
BuffRuntime.isViewerReady = IsViewerReady
BuffRuntime.doBuffRefresh = DoBuffRefresh
BuffRuntime.requestBuffRefresh = RequestBuffRefresh
BuffRuntime.refreshBuffViewer = RefreshBuffViewer
BuffRuntime.QK = QK_BUFF_ICONS

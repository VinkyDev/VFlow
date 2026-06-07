-- =========================================================
-- VFlow CustomMonitor Runtime — Segments
-- 职责：StatusBar / 环形 / 阈值覆盖层的分段几何 + 颜色 + 像素边框
--   - CreateSegments：根据 cfg 与 (count, isStack, isRing) 重建段
--   - SegmentLayoutSignature：签名比对，避免重复重建
--   - ApplyTimerDuration / FillDirection / SetRemainingText：通用计时辅助
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

VFlow.CustomMonitor = VFlow.CustomMonitor or {}
VFlow.CustomMonitor.Runtime = VFlow.CustomMonitor.Runtime or {}

local Constants = VFlow.CustomMonitor.Runtime.Constants
local PP = VFlow.PixelPerfect
local BFK = VFlow.BarFrameKit

local Segments = {}
VFlow.CustomMonitor.Runtime.Segments = Segments

-- =========================================================
-- SECTION 1: 通用计时与文本辅助
-- =========================================================

--- 先尝试一位小数；含 secret 等对 format 有限制时回退为原值（引擎默认约三位小数）
local function SetRemainingText(text, durObj)
    local remaining
    pcall(function() remaining = durObj:GetRemainingDuration() end)
    if remaining == nil then
        text:SetText("")
        return
    end
    local ok1 = pcall(function()
        text:SetFormattedText("%.1f", remaining)
    end)
    if ok1 then return end
    local ok2 = pcall(function()
        text:SetText(remaining)
    end)
    if not ok2 then text:SetText("") end
end

local function FillDirection(fillMode)
    if fillMode == "fill" then
        return Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.RemainingTime or 1
    end
    return Enum.StatusBarTimerDirection and Enum.StatusBarTimerDirection.ElapsedTime or 0
end

local function ApplyTimerDuration(seg, durObj, interpolation, direction)
    if not (durObj and seg.SetTimerDuration) then return false end
    seg:SetMinMaxValues(0, 1)
    seg:SetTimerDuration(durObj, interpolation, direction)
    if seg.SetToTargetValue then seg:SetToTargetValue() end
    return true
end

local function SetBarTickState(barFrame, mode)
    if not barFrame then return end
    barFrame._tickMode = mode
end

-- =========================================================
-- SECTION 2: 签名计算（脏检查 / 重建判定）
-- =========================================================

local function colKey(c)
    if not c then return "-" end
    return table.concat({ tostring(c.r), tostring(c.g), tostring(c.b), tostring(c.a) }, ";")
end

local function ShouldRenderGraphics(cfg)
    return cfg and cfg.showGraphics ~= false
end

local function ShouldRenderText(cfg)
    return cfg and cfg.showText ~= false
end

local function timerFontKey(cfg)
    local t = cfg.timerFont or {}
    local fc = t.color or {}
    return table.concat({
        tostring(t.font or ""),
        tostring(t.size or 0),
        tostring(t.outline or ""),
        tostring(t.position or "CENTER"),
        tostring(t.offsetX or 0),
        tostring(t.offsetY or 0),
        colKey(fc),
    }, "\031")
end

--- CreateBarFrame 维度（含环形/条形共用的背景与计时文字区；不含 monitorType/充能业务模式）
local function InnerBarSignature(cfg)
    return table.concat({
        tostring(cfg.shape or "bar"),
        tostring(cfg.showGraphics ~= false),
        tostring(cfg.showText ~= false),
        colKey(cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }),
        tostring(cfg.showGraphics ~= false and cfg.showIcon ~= false),
        tostring(cfg.iconSize or 20),
        tostring(cfg.iconPosition or "LEFT"),
        tostring(cfg.iconOffsetX or 0),
        tostring(cfg.iconOffsetY or 0),
        timerFontKey(cfg),
    }, "\031")
end

--- CreateSegments 维度（含环形/堆叠阈值/充能路径）
local function SegmentLayoutSignature(cfg, barFrame)
    local storeKey = barFrame._storeKey or "skills"
    local shape = cfg.shape or "bar"
    local mon = (storeKey == "buffs") and (barFrame._monitorType or cfg.monitorType or "duration") or ""
    local bt = (BFK and BFK.ParseBorderThickness and BFK.ParseBorderThickness(cfg.borderThickness))
        or tonumber(cfg.borderThickness) or 1
    return table.concat({
        shape,
        storeKey,
        mon,
        tostring(cfg.showGraphics ~= false),
        tostring(tonumber(cfg.maxStacks) or 5),
        tostring(tonumber(cfg.segmentGap) or 0),
        cfg.barDirection or "horizontal",
        tostring(cfg.barReverse == true),
        tostring(cfg.barTexture or ""),
        tostring(tonumber(cfg.stackThreshold1) or 0),
        tostring(tonumber(cfg.stackThreshold2) or 0),
        colKey(cfg.stackColor1),
        colKey(cfg.stackColor2),
        colKey(cfg.barColor),
        colKey(cfg.bgColor),
        tostring(cfg.ringTexture or ""),
        colKey(cfg.ringColor or { r = 0.2, g = 0.6, b = 1, a = 1 }),
        tostring(cfg.ringThickness or 0),
        tostring(cfg.barFillMode or ""),
        tostring(bt),
        colKey(cfg.borderColor),
        storeKey == "skills" and tostring(cfg.isChargeSpell == true) or "",
        tostring(cfg.ringSize or 0),
    }, "\031")
end

-- =========================================================
-- SECTION 3: 段创建 / 清理
-- =========================================================

local function ClearSegments(barFrame)
    if barFrame._segments then
        for _, seg in ipairs(barFrame._segments) do
            seg:Hide()
            seg:SetParent(nil)
        end
    end
    if barFrame._segBGs then
        for _, bg in ipairs(barFrame._segBGs) do
            bg:Hide()
            bg:SetParent(nil)
        end
    end
    if barFrame._thresholdOverlays then
        for _, ov in ipairs(barFrame._thresholdOverlays) do
            ov:Hide()
            ov:SetParent(nil)
        end
    end
    if barFrame._segFrames then
        for _, frame in ipairs(barFrame._segFrames) do
            frame:Hide()
            frame:SetParent(nil)
        end
    end
    barFrame._segments = {}
    barFrame._segBGs = {}
    barFrame._thresholdOverlays = {}
    barFrame._segFrames = {}
end

-- count=1 → 单段；count>1 → 多段（充能/stacks）
-- isStack=true 时启用阈值覆盖层
-- isRing=true 时创建环形（仅用于BUFF持续时间，单段）
local function CreateSegments(barFrame, count, cfg, isStack, isRing)
    ClearSegments(barFrame)
    if not ShouldRenderGraphics(cfg) then
        barFrame._segSig = SegmentLayoutSignature(cfg, barFrame)
        barFrame._segsDirty = false
        barFrame._segsNeedCount = nil
        return
    end
    if count < 1 then
        return
    end

    local segContainer = barFrame._segContainer
    local totalW = segContainer:GetSize()
    if totalW <= 0 then
        barFrame._segsDirty = true
        barFrame._segsNeedCount = count
        return
    end

    -- 环形模式（仅 BUFF 持续时间）
    if isRing then
        local ringTexture = cfg.ringTexture or "10"
        local ringTex = string.format(Constants.RING_TEXTURE_FMT, ringTexture)
        local rc = cfg.ringColor or { r = 0.2, g = 0.6, b = 1, a = 1 }

        -- 背景环（使用环形纹理，深灰色）
        local bg = segContainer:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetTexture(ringTex)
        local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
        bg:SetVertexColor(bgc.r, bgc.g, bgc.b, bgc.a)
        bg:Show()
        barFrame._segBGs[1] = bg

        -- 隐藏 barFrame 自身的矩形背景
        local bgTex = barFrame.GetRegions and select(1, barFrame:GetRegions())
        if bgTex and bgTex.SetColorTexture then
            bgTex:SetColorTexture(0, 0, 0, 0)
        end

        -- 使用 CooldownFrame 作为进度显示
        local cd = CreateFrame("Cooldown", nil, segContainer, "CooldownFrameTemplate")
        cd:SetAllPoints()
        cd:SetDrawEdge(false)
        cd:SetDrawBling(false)
        cd:SetSwipeTexture(ringTex)
        cd:SetSwipeColor(rc.r, rc.g, rc.b, rc.a)
        cd:SetReverse(false) -- 不反向：黑色遮罩从满到空消退，露出背景环
        cd:SetHideCountdownNumbers(true)
        cd:SetUseCircularEdge(false)
        cd:EnableMouse(false)
        cd:Show()
        cd._isRing = true
        cd._needsRefresh = true
        barFrame._segments[1] = cd

        barFrame._segSig = SegmentLayoutSignature(cfg, barFrame)
        barFrame._segsDirty = false
        barFrame._segsNeedCount = nil
        return
    end

    -- 条形模式：分段几何与边框同 BarFrameKit / ResourceBars（ref 像素比例 + 末格双锚点）
    local dir = cfg.barDirection or "horizontal"
    local barReverse = cfg.barReverse == true
    local tex = BFK and BFK.ResolveBarTexture(cfg.barTexture) or "Interface\\Buttons\\WHITE8X8"
    local bc = cfg.barColor or { r = 0.2, g = 0.6, b = 1, a = 1 }

    -- 阈值配置（isStack 时读取）
    local t1 = isStack and (tonumber(cfg.stackThreshold1) or 0) or 0
    local t2 = isStack and (tonumber(cfg.stackThreshold2) or 0) or 0
    local c1 = cfg.stackColor1 or { r = 1, g = 0.5, b = 0, a = 1 }
    local c2 = cfg.stackColor2 or { r = 1, g = 0, b = 0, a = 1 }

    local baseLevel = segContainer:GetFrameLevel()

    for i = 1, count do
        local segFrame = CreateFrame("Frame", nil, segContainer)
        segFrame:SetFrameLevel(baseLevel)

        local bg = segFrame:CreateTexture(nil, "BACKGROUND")
        local bgc = cfg.bgColor or { r = 0.1, g = 0.1, b = 0.1, a = 0.5 }
        bg:SetColorTexture(bgc.r, bgc.g, bgc.b, bgc.a)
        bg:SetAllPoints(segFrame)

        local seg = CreateFrame("StatusBar", nil, segFrame)
        seg:SetStatusBarTexture(tex)
        seg:SetStatusBarColor(bc.r, bc.g, bc.b, bc.a)
        seg:SetValue(0)
        seg:EnableMouse(false)
        seg:SetFrameLevel(baseLevel + 1)
        seg:SetAllPoints(segFrame)
        if BFK then
            BFK.ConfigureStatusBar(seg)
            BFK.SetOrientation(seg, dir)
            BFK.SetReverseFill(seg, barReverse)
        end

        if isStack then
            seg:SetMinMaxValues(i - 1, i)
            if dir == "vertical" and seg.SetFillStyle then
                seg:SetFillStyle(Enum.StatusBarFillStyle.Standard)
            end
        else
            seg:SetMinMaxValues(0, 1)
        end

        barFrame._segBGs[i] = bg
        barFrame._segments[i] = seg
        barFrame._segFrames = barFrame._segFrames or {}
        barFrame._segFrames[i] = segFrame

        -- 阈值覆盖层
        if isStack then
            if t1 > 0 then
                local ov1 = CreateFrame("StatusBar", nil, segFrame)
                ov1:SetAllPoints(segFrame)
                ov1:SetStatusBarTexture(tex)
                ov1:SetStatusBarColor(c1.r, c1.g, c1.b, c1.a)
                ov1:SetValue(0)
                ov1:EnableMouse(false)
                ov1:SetFrameLevel(baseLevel + 2)
                ov1:SetMinMaxValues((i < t1) and (t1 - 1) or (i - 1), (i < t1) and t1 or i)
                if BFK then
                    BFK.ConfigureStatusBar(ov1)
                    BFK.SetOrientation(ov1, dir)
                    BFK.SetReverseFill(ov1, barReverse)
                end
                table.insert(barFrame._thresholdOverlays, ov1)
            end
            if t2 > 0 then
                local ov2 = CreateFrame("StatusBar", nil, segFrame)
                ov2:SetAllPoints(segFrame)
                ov2:SetStatusBarTexture(tex)
                ov2:SetStatusBarColor(c2.r, c2.g, c2.b, c2.a)
                ov2:SetValue(0)
                ov2:EnableMouse(false)
                ov2:SetFrameLevel(baseLevel + 3)
                ov2:SetMinMaxValues((i < t2) and (t2 - 1) or (i - 1), (i < t2) and t2 or i)
                if BFK then
                    BFK.ConfigureStatusBar(ov2)
                    BFK.SetOrientation(ov2, dir)
                    BFK.SetReverseFill(ov2, barReverse)
                end
                table.insert(barFrame._thresholdOverlays, ov2)
            end
        end

        local borderFrame = CreateFrame("Frame", nil, segFrame)
        borderFrame:SetFrameLevel(baseLevel + 4)
        borderFrame:SetAllPoints(segFrame)
        borderFrame:EnableMouse(false)
        segFrame._vf_segmentBorder = borderFrame
    end

    --- 与 ResourceBars 一致：像素比例以「正在分割的容器」为 ref（totalW/H 亦来自该容器）
    if BFK and BFK.LayoutDiscreteBarSegmentFrames then
        BFK.LayoutDiscreteBarSegmentFrames(segContainer, cfg, count, dir, barFrame._segFrames or {}, segContainer)
    end
    if BFK and BFK.ApplySegmentCellBorder then
        for i = 1, count do
            local sf = barFrame._segFrames and barFrame._segFrames[i]
            if sf and sf._vf_segmentBorder then
                BFK.ApplySegmentCellBorder(sf._vf_segmentBorder, cfg)
            end
        end
    end

    barFrame._segSig = SegmentLayoutSignature(cfg, barFrame)
    barFrame._segsDirty = false
    barFrame._segsNeedCount = nil
end

-- 将层数值同时设给基础分段和阈值覆盖层
local function SetStackSegmentsValue(barFrame, value)
    for _, seg in ipairs(barFrame._segments) do seg:SetValue(value) end
    for _, ov in ipairs(barFrame._thresholdOverlays) do ov:SetValue(value) end
end

-- =========================================================
-- SECTION 4: 充能段几何（独立路径，CooldownRenderer 复用）
-- =========================================================

local function BuildChargeSegmentMetrics(container, count, dir, segmentGap)
    if not container or count < 1 then return nil end

    local totalW = container:GetWidth()
    local totalH = container:GetHeight()
    if totalW <= 0 or totalH <= 0 then return nil end

    local ppScale = PP.GetPixelScale(container)
    local function ToPixel(v) return math.floor(v / ppScale + 0.5) end
    local function ToLogical(px) return px * ppScale end

    local pxTotalW = ToPixel(totalW)
    local pxTotalH = ToPixel(totalH)
    local pxGap = ToPixel(segmentGap)
    local metrics = {}

    if count == 1 then
        metrics[1] = {
            x = 0,
            y = 0,
            w = ToLogical(pxTotalW),
            h = ToLogical(pxTotalH),
        }
        return metrics
    end

    if dir == "vertical" then
        local pxAvailH = math.max(0, pxTotalH - (count - 1) * pxGap)
        local prevEdge = 0
        for i = 1, count do
            local edge = (i == count) and pxAvailH or math.floor(pxAvailH * i / count + 0.5)
            local segPxH = math.max(0, edge - prevEdge)
            metrics[i] = {
                x = 0,
                y = ToLogical(prevEdge + (i - 1) * pxGap),
                w = ToLogical(pxTotalW),
                h = ToLogical(segPxH),
            }
            prevEdge = edge
        end
    else
        local pxAvailW = math.max(0, pxTotalW - (count - 1) * pxGap)
        local prevEdge = 0
        for i = 1, count do
            local edge = (i == count) and pxAvailW or math.floor(pxAvailW * i / count + 0.5)
            local segPxW = math.max(0, edge - prevEdge)
            metrics[i] = {
                x = ToLogical(prevEdge + (i - 1) * pxGap),
                y = 0,
                w = ToLogical(segPxW),
                h = ToLogical(pxTotalH),
            }
            prevEdge = edge
        end
    end

    return metrics
end

-- =========================================================
-- SECTION 5: 公共接口
-- =========================================================

Segments.setRemainingText = SetRemainingText
Segments.fillDirection = FillDirection
Segments.applyTimerDuration = ApplyTimerDuration
Segments.setBarTickState = SetBarTickState
Segments.shouldRenderGraphics = ShouldRenderGraphics
Segments.shouldRenderText = ShouldRenderText
Segments.innerBarSignature = InnerBarSignature
Segments.segmentLayoutSignature = SegmentLayoutSignature
Segments.create = CreateSegments
Segments.clear = ClearSegments
Segments.setStackValue = SetStackSegmentsValue
Segments.buildChargeMetrics = BuildChargeSegmentMetrics

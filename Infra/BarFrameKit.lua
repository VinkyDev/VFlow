-- =========================================================
-- BarFrameKit — 条形 StatusBar 共用逻辑（资源条 / 自定义图形监控）
-- 依赖：PixelPerfect（纹理解析与边框无关；朝向/平滑与 PP 解耦）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local BFK = {}
VFlow.BarFrameKit = BFK

local WHITE8X8 = "Interface\\Buttons\\WHITE8X8"

BFK.WHITE8X8 = WHITE8X8
BFK.DEFAULT_BAR_TEXTURE = WHITE8X8

local STATUSBAR_SMOOTH_OUT = _G.Enum and Enum.StatusBarInterpolation and Enum.StatusBarInterpolation.ExponentialEaseOut

function BFK.DisableTextureSnap(tex)
    if not tex then
        return
    end
    if tex.SetSnapToPixelGrid then
        tex:SetSnapToPixelGrid(false)
    end
    if tex.SetTexelSnappingBias then
        tex:SetTexelSnappingBias(0)
    end
end

function BFK.ConfigureStatusBar(bar)
    local tex = bar and bar.GetStatusBarTexture and bar:GetStatusBarTexture()
    if tex then
        BFK.DisableTextureSnap(tex)
    end
end

function BFK.SetOrientation(bar, direction)
    if not bar or not bar.SetOrientation then
        return
    end
    if direction == "vertical" then
        bar:SetOrientation("VERTICAL")
    else
        bar:SetOrientation("HORIZONTAL")
    end
end

--- 沿当前朝向填充轴镜像（横条左↔右，竖条下↔上）
function BFK.SetReverseFill(bar, reversed)
    if not bar or not bar.SetReverseFill then
        return
    end
    bar:SetReverseFill(reversed == true)
end

function BFK.ResolveBarTexture(name)
    if not name or name == "默认" or name == "Solid" then
        return WHITE8X8
    end
    local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
    if LSM then
        local path = LSM:Fetch("statusbar", name)
        if path then
            return path
        end
    end
    return WHITE8X8
end

--- 支持配置里 "1"|"2"|"3" 或数字
function BFK.ParseBorderThickness(v)
    local n = tonumber(v)
    if n and n > 0 then
        return n
    end
    return 1
end

--- 分段单元格线框（ParseBorderThickness + PixelPerfect）
---@param borderFrame Frame SetAllPoints 在 seg 上、子层线框
---@param cfg table borderThickness、borderColor
function BFK.ApplySegmentCellBorder(borderFrame, cfg)
    local PP = VFlow.PixelPerfect
    if not borderFrame or not cfg or not PP or not PP.CreateBorder then
        return
    end
    local bt = BFK.ParseBorderThickness(cfg.borderThickness)
    local bc = cfg.borderColor or { r = 0, g = 0, b = 0, a = 1 }
    PP.CreateBorder(borderFrame, bt, bc, true)
end

--- 在 container 内铺分段：像素取整，末格双锚点拉满消误差。
---@param container Frame 条形容器（如 _segContainer）
---@param cfg table segmentGap、borderThickness
---@param count number 段数，>=1
---@param dir string "horizontal"|"vertical"
---@param segmentFrames Frame[] segmentFrames[i] 已为 container 子 Frame，尚未或未最终定位
---@param refForPixel Frame|nil 像素尺度参考（与 container 同坐标系；条用 host、分段监控可用 segContainer）
---@return boolean ok
function BFK.LayoutDiscreteBarSegmentFrames(container, cfg, count, dir, segmentFrames, refForPixel)
    local PP = VFlow.PixelPerfect
    if not container or not cfg or not segmentFrames or not PP or count < 1 then
        return false
    end
    refForPixel = refForPixel or container

    local gapUser = tonumber(cfg.segmentGap) or 0
    local bt = BFK.ParseBorderThickness(cfg.borderThickness)
    local segmentGap = (count > 1) and (gapUser - bt) or 0

    local totalW, totalH = container:GetWidth(), container:GetHeight()
    if totalW <= 0 or totalH <= 0 then
        return false
    end

    local ppScale = PP.GetPixelScale(refForPixel)
    local function ToPixel(v)
        return math.floor(v / ppScale + 0.5)
    end
    local function ToLogical(px)
        return px * ppScale
    end

    local pxTotalW = ToPixel(totalW)
    local pxTotalH = ToPixel(totalH)
    local pxGap = ToPixel(segmentGap)

    if count == 1 then
        local segFrame = segmentFrames[1]
        if not segFrame then
            return false
        end
        segFrame:ClearAllPoints()
        segFrame:SetPoint("TOPLEFT", container, "TOPLEFT", 0, 0)
        segFrame:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
        return true
    end

    local pxSegW_Base, pxSegH_Base, pxRemainder
    if dir == "vertical" then
        pxSegW_Base = pxTotalW
        local pxAvailH = math.max(0, pxTotalH - (count - 1) * pxGap)
        pxSegH_Base = math.floor(pxAvailH / count)
        pxRemainder = pxAvailH % count
    else
        pxSegH_Base = pxTotalH
        local pxAvailW = math.max(0, pxTotalW - (count - 1) * pxGap)
        pxSegW_Base = math.floor(pxAvailW / count)
        pxRemainder = pxAvailW % count
    end

    local gapLog = ToLogical(pxGap)
    local currentLogX = 0
    local currentLogY = 0

    if dir == "vertical" then
        for pos = 1, count - 1 do
            local segFrame = segmentFrames[pos]
            if not segFrame then
                return false
            end
            local thisPxH = pxSegH_Base + (pos <= pxRemainder and 1 or 0)
            local logH = ToLogical(thisPxH)
            local logW = ToLogical(pxSegW_Base)
            segFrame:ClearAllPoints()
            segFrame:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, currentLogY)
            PP.SetSize(segFrame, logW, logH)
            currentLogY = currentLogY + logH + gapLog
        end
        do
            local segFrame = segmentFrames[count]
            if not segFrame then
                return false
            end
            segFrame:ClearAllPoints()
            segFrame:SetPoint("BOTTOMLEFT", container, "BOTTOMLEFT", 0, currentLogY)
            segFrame:SetPoint("TOPRIGHT", container, "TOPRIGHT", 0, 0)
        end
    else
        for pos = 1, count - 1 do
            local segFrame = segmentFrames[pos]
            if not segFrame then
                return false
            end
            local thisPxW = pxSegW_Base + (pos <= pxRemainder and 1 or 0)
            local logW = ToLogical(thisPxW)
            local logH = ToLogical(pxSegH_Base)
            segFrame:ClearAllPoints()
            segFrame:SetPoint("TOPLEFT", container, "TOPLEFT", currentLogX, 0)
            PP.SetSize(segFrame, logW, logH)
            currentLogX = currentLogX + logW + gapLog
        end
        do
            local segFrame = segmentFrames[count]
            if not segFrame then
                return false
            end
            segFrame:ClearAllPoints()
            segFrame:SetPoint("TOPLEFT", container, "TOPLEFT", currentLogX, 0)
            segFrame:SetPoint("BOTTOMRIGHT", container, "BOTTOMRIGHT", 0, 0)
        end
    end
    return true
end

function BFK.ApplyBarTextureFromConfig(sb, cfg)
    if not sb or not cfg then
        return
    end
    sb:SetStatusBarTexture(BFK.ResolveBarTexture(cfg.barTexture))
    BFK.ConfigureStatusBar(sb)
end

function BFK.ApplyStatusBarLayoutFromConfig(sb, cfg)
    if not sb or not cfg then
        return
    end
    BFK.SetOrientation(sb, cfg.barDirection or "horizontal")
    BFK.SetReverseFill(sb, cfg.barReverse == true)
end

--- @param useSmooth boolean|nil
function BFK.ApplyBarProgress(sb, max, cur, useSmooth)
    if not sb or max == nil then
        return
    end
    local interp = useSmooth and STATUSBAR_SMOOTH_OUT or nil
    if interp then
        local ok = pcall(function()
            sb:SetMinMaxValues(0, max, interp)
            sb:SetValue(cur, interp)
        end)
        if ok then
            return
        end
    end
    pcall(function()
        sb:SetMinMaxValues(0, max)
        sb:SetValue(cur)
    end)
end

--- 在 host 上创建：底板纹理、StatusBar、边框层
--- 绘制顺序：BACKGROUND 底 → StatusBar → 子层 borderFrame 上的线框（需更高 FrameLevel）
---@param host Frame
function BFK.SetupResourceBarHost(host)
    if not host or host._bfk_hostReady then
        return
    end

    local baseLvl = host:GetFrameLevel() or 0

    local bg = host:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    host._vf_bg = bg

    local sb = CreateFrame("StatusBar", nil, host)
    sb:SetFrameLevel(baseLvl + 1)
    sb:SetAllPoints()
    sb:SetStatusBarTexture(BFK.DEFAULT_BAR_TEXTURE)
    BFK.ConfigureStatusBar(sb)
    host._vf_sb = sb

    local borderFrame = CreateFrame("Frame", nil, host)
    borderFrame:SetFrameLevel(baseLvl + 4)
    borderFrame:SetAllPoints(host)
    borderFrame:EnableMouse(false)
    host._vf_borderFrame = borderFrame

    host._bfk_hostReady = true
end

--- 条材质、朝向、外线框（底板色由 ResourceBars.ApplyBarBackground）
---@param host Frame
---@param cfg table
function BFK.ApplyResourceBarChrome(host, cfg)
    if not host or not cfg or not host._vf_sb or not host._vf_borderFrame then
        return
    end
    BFK.ApplyBarTextureFromConfig(host._vf_sb, cfg)
    BFK.ApplyStatusBarLayoutFromConfig(host._vf_sb, cfg)
    local PP = VFlow.PixelPerfect
    if not PP or not PP.CreateBorder then
        return
    end
    local bc = cfg.borderColor or { r = 0, g = 0, b = 0, a = 1 }
    PP.CreateBorder(host._vf_borderFrame, BFK.ParseBorderThickness(cfg.borderThickness), bc, true)
end

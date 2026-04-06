-- =========================================================
-- PixelPerfect — 像素对齐与内嵌线框（顶底边水平方向缩进，减轻角部双边叠粗）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local PixelPerfect = {}
VFlow.PixelPerfect = PixelPerfect

local UIParent = UIParent

-- =========================================================
--- SECTION 1: 物理像素尺度
-- =========================================================

local cachedPhysH = 0
local cachedUIParentScale = 0
local cachedGlobalPixel = 1

local function RefreshGlobalCache()
    local physH = select(2, GetPhysicalScreenSize())
    local sc = UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1
    if physH and physH > 0 and sc and sc > 0 then
        if physH == cachedPhysH and sc == cachedUIParentScale then
            return
        end
        cachedPhysH = physH
        cachedUIParentScale = sc
        cachedGlobalPixel = 768 / (physH * sc)
    end
end

local ev = CreateFrame("Frame", nil, UIParent)
ev:Hide()
ev:RegisterEvent("DISPLAY_SIZE_CHANGED")
pcall(function()
    ev:RegisterEvent("UI_SCALE_CHANGED")
end)
ev:SetScript("OnEvent", function()
    RefreshGlobalCache()
end)
RefreshGlobalCache()

-- 获取「一物理像素」在 frame 逻辑坐标系中的厚度（按该帧有效缩放）
local function GetOnePixelSize(frame)
    RefreshGlobalCache()
    local physH = select(2, GetPhysicalScreenSize())
    local uiScale = frame and frame.GetEffectiveScale and frame:GetEffectiveScale() or nil
    if not uiScale or uiScale == 0 then
        uiScale = UIParent and UIParent.GetEffectiveScale and UIParent:GetEffectiveScale() or 1
    end
    if not physH or physH == 0 or not uiScale or uiScale == 0 then
        return cachedGlobalPixel > 0 and cachedGlobalPixel or 1
    end
    return 768.0 / physH / uiScale
end

local function PixelSnap(value, frame)
    if not value then
        return 0
    end
    local onePixel = GetOnePixelSize(frame)
    if onePixel == 0 then
        return value
    end
    return math.floor(value / onePixel + 0.5) * onePixel
end

PixelPerfect.GetPixelScale = GetOnePixelSize
PixelPerfect.PixelSnap = PixelSnap
PixelPerfect.RefreshGlobalCache = RefreshGlobalCache

--- 横向排布：宽度与列间距分别对齐到 ref 的像素格
function PixelPerfect.NormalizeColumnStride(cellWidth, spacingX, refFrame)
    local w = cellWidth or 0
    local s = spacingX or 0
    if not refFrame then
        return w, w + s
    end
    local wS = PixelSnap(w, refFrame)
    local sS = PixelSnap(s, refFrame)
    return wS, wS + sS
end

-- =========================================================
-- SECTION 2: 尺寸
-- =========================================================

function PixelPerfect.SetWidth(frame, width)
    if not frame then
        return
    end
    frame:SetWidth(PixelSnap(width, frame))
end

function PixelPerfect.SetHeight(frame, height)
    if not frame then
        return
    end
    frame:SetHeight(PixelSnap(height, frame))
end

function PixelPerfect.SetSize(frame, width, height)
    if not frame then
        return
    end
    frame:SetSize(PixelSnap(width, frame), PixelSnap(height, frame))
end

--- 取与 ContainerAnchor.anchorCoords / 玩家角点语义一致：锚点「在屏幕上的那一个点」的世界坐标。
--- 必须与 GetCanonicalAnchorOffsets 用的点一致，否则 CENTER 锚点却按左下角平移，条宽一变就会误触发 canonicalSync 改写 x/y。
local function getAnchoredPointWorldXY(frame, point)
    if not frame or not point then
        return nil, nil
    end
    local l, r, t, b = frame:GetLeft(), frame:GetRight(), frame:GetTop(), frame:GetBottom()
    if not (l and r and t and b) then
        return nil, nil
    end
    if point == "CENTER" then
        return (l + r) * 0.5, (t + b) * 0.5
    elseif point == "TOP" then
        return (l + r) * 0.5, t
    elseif point == "BOTTOM" then
        return (l + r) * 0.5, b
    elseif point == "LEFT" then
        return l, (t + b) * 0.5
    elseif point == "RIGHT" then
        return r, (t + b) * 0.5
    elseif point == "TOPLEFT" then
        return l, t
    elseif point == "TOPRIGHT" then
        return r, t
    elseif point == "BOTTOMLEFT" then
        return l, b
    elseif point == "BOTTOMRIGHT" then
        return r, b
    end
    return nil, nil
end

--- 单锚点帧：整体平移使「当前 SetPoint 所用的锚点」落在物理像素格上。
--- 对称锚点（CENTER 等）下尺寸已 Snap 时，边仍常落在半像素；对齐锚点与规范偏移语义一致，避免专精切换改宽度后 Store 被误写。
--- 改锚点偏移 (x,y)，不改编排语义。CreateBorder 内 SnapSingleAnchorFrameToPixelGrid 与此共用实现。
function PixelPerfect.SnapFrameToPixelGrid(frame)
    if not frame or not frame.GetNumPoints or frame:GetNumPoints() ~= 1 then
        return
    end
    local pt, rel, rp, x, y = frame:GetPoint(1)
    if not pt then
        return
    end
    local ax, ay = getAnchoredPointWorldXY(frame, pt)
    if not ax or not ay then
        ax, ay = frame:GetLeft(), frame:GetBottom()
    end
    if not ax or not ay then
        return
    end
    local sx = PixelSnap(ax, frame)
    local sy = PixelSnap(ay, frame)
    local dx = sx - ax
    local dy = sy - ay
    if math.abs(dx) < 1e-6 and math.abs(dy) < 1e-6 then
        return
    end
    frame:ClearAllPoints()
    frame:SetPoint(pt, rel or UIParent, rp or pt, (x or 0) + dx, (y or 0) + dy)
end

-- =========================================================
-- SECTION 3: 边框
-- =========================================================

function PixelPerfect.UpdateBorderColor(frame, color)
    if not frame or not frame._ppBorders then
        return
    end
    color = color or { r = 1, g = 1, b = 1, a = 1 }
    for _, border in ipairs(frame._ppBorders) do
        border:SetVertexColor(color.r, color.g, color.b, color.a)
    end
end

function PixelPerfect.HideBorder(frame)
    if not frame or not frame._ppBorders then
        return
    end
    for _, border in ipairs(frame._ppBorders) do
        border:Hide()
    end
end

function PixelPerfect.ShowBorder(frame)
    if not frame or not frame._ppBorders then
        return
    end
    for _, border in ipairs(frame._ppBorders) do
        border:Show()
    end
end

local function ApplyBorderLinesInset(anchor, lines, px, color)
    local top, bottom, left, right = lines[1], lines[2], lines[3], lines[4]
    local r, g, b, a = color.r, color.g, color.b, color.a
    for _, line in ipairs(lines) do
        line:SetVertexColor(r, g, b, a)
        line:Show()
    end

    top:ClearAllPoints()
    top:SetPoint("TOPLEFT", anchor, "TOPLEFT", px, 0)
    top:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", -px, 0)
    top:SetHeight(px)

    bottom:ClearAllPoints()
    bottom:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", px, 0)
    bottom:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", -px, 0)
    bottom:SetHeight(px)

    left:ClearAllPoints()
    left:SetPoint("TOPLEFT", anchor, "TOPLEFT", 0, 0)
    left:SetPoint("BOTTOMLEFT", anchor, "BOTTOMLEFT", 0, 0)
    left:SetWidth(px)

    right:ClearAllPoints()
    right:SetPoint("TOPRIGHT", anchor, "TOPRIGHT", 0, 0)
    right:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
    right:SetWidth(px)
end

--- 外扩：四边向外伸出 px（少见；保留与旧行为接近的包角方式）
local function ApplyBorderLinesOutset(anchor, lines, px, color)
    local top, bottom, left, right = lines[1], lines[2], lines[3], lines[4]
    local r, g, b, a = color.r, color.g, color.b, color.a
    for _, line in ipairs(lines) do
        line:SetVertexColor(r, g, b, a)
        line:Show()
    end

    left:ClearAllPoints()
    left:SetPoint("TOPRIGHT", anchor, "TOPLEFT", 0, px)
    left:SetPoint("BOTTOMRIGHT", anchor, "BOTTOMLEFT", 0, -px)
    left:SetWidth(px)

    right:ClearAllPoints()
    right:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 0, px)
    right:SetPoint("BOTTOMLEFT", anchor, "BOTTOMRIGHT", 0, -px)
    right:SetWidth(px)

    top:ClearAllPoints()
    top:SetPoint("BOTTOMLEFT", anchor, "TOPLEFT", 0, 0)
    top:SetPoint("BOTTOMRIGHT", anchor, "TOPRIGHT", 0, 0)
    top:SetHeight(px)

    bottom:ClearAllPoints()
    bottom:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, 0)
    bottom:SetPoint("TOPRIGHT", anchor, "BOTTOMRIGHT", 0, 0)
    bottom:SetHeight(px)
end

--- 对单锚点帧对齐像素格（与 SnapFrameToPixelGrid 同一套锚点语义，避免顶左/底左混用）
local function SnapSingleAnchorFrameToPixelGrid(frame)
    PixelPerfect.SnapFrameToPixelGrid(frame)
end

local WHITE8X8 = "Interface\\Buttons\\WHITE8X8"

local function makeBorderLine(frame, color)
    local tex = frame:CreateTexture(nil, "OVERLAY")
    tex:SetTexture(WHITE8X8)
    if tex.SetSnapToPixelGrid then
        tex:SetSnapToPixelGrid(false)
    end
    if tex.SetTexelSnappingBias then
        tex:SetTexelSnappingBias(0)
    end
    tex:SetVertexColor(color.r, color.g, color.b, color.a)
    return tex
end

--- @param thickness number|string 逻辑厚度（1 表示一物理像素厚）
function PixelPerfect.CreateBorder(frame, thickness, color, inset)
    if not frame then
        return
    end

    RefreshGlobalCache()
    thickness = thickness or 1
    color = color or { r = 0, g = 0, b = 0, a = 1 }
    if inset == nil then
        inset = true
    end

    SnapSingleAnchorFrameToPixelGrid(frame)

    if frame._ppBorders then
        for _, border in ipairs(frame._ppBorders) do
            border:Hide()
            border:SetParent(nil)
        end
    end

    local borders = {}
    frame._ppBorders = borders

    local t
    local thickNum = tonumber(thickness) or 1
    if thickNum <= 1 then
        t = GetOnePixelSize(frame)
    else
        t = PixelSnap(thickNum, frame)
        local onePixel = GetOnePixelSize(frame)
        if t < onePixel then
            t = onePixel
        end
    end

    local top = makeBorderLine(frame, color)
    local bottom = makeBorderLine(frame, color)
    local left = makeBorderLine(frame, color)
    local right = makeBorderLine(frame, color)
    borders[1] = top
    borders[2] = bottom
    borders[3] = left
    borders[4] = right

    if inset then
        ApplyBorderLinesInset(frame, borders, t, color)
    else
        ApplyBorderLinesOutset(frame, borders, t, color)
    end

    return borders
end

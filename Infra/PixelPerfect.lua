-- =========================================================
-- VFlow PixelPerfect - 完美像素工具
-- 确保UI元素在不同分辨率下都能完美对齐像素网格
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local PixelPerfect = {}
VFlow.PixelPerfect = PixelPerfect

-- =========================================================
-- SECTION 1: 核心计算
-- =========================================================

local UIParent = UIParent

-- 获取一个物理像素在逻辑坐标系中的大小
-- 公式：768 / 物理高度 / UI缩放
local function GetOnePixelSize(frame)
    local screenHeight = select(2, GetPhysicalScreenSize())
    local uiScale = nil
    if frame and frame.GetEffectiveScale then
        uiScale = frame:GetEffectiveScale()
    end
    if not uiScale or uiScale == 0 then
        uiScale = UIParent:GetEffectiveScale()
    end
    if not screenHeight or screenHeight == 0 or not uiScale or uiScale == 0 then return 1 end
    return 768.0 / screenHeight / uiScale
end

-- 将数值对齐到最近的物理像素
local function PixelSnap(value, frame)
    if not value then return 0 end
    local onePixel = GetOnePixelSize(frame)
    if onePixel == 0 then return value end
    return math.floor(value / onePixel + 0.5) * onePixel
end

PixelPerfect.GetPixelScale = GetOnePixelSize
PixelPerfect.PixelSnap = PixelSnap

-- =========================================================
-- SECTION 2: 尺寸设置（完美像素）
-- =========================================================

function PixelPerfect.SetWidth(frame, width)
    if not frame then return end
    frame:SetWidth(PixelSnap(width, frame))
end

function PixelPerfect.SetHeight(frame, height)
    if not frame then return end
    frame:SetHeight(PixelSnap(height, frame))
end

function PixelPerfect.SetSize(frame, width, height)
    if not frame then return end
    frame:SetSize(PixelSnap(width, frame), PixelSnap(height, frame))
end

-- =========================================================
-- SECTION 3: 边框创建（完美像素）
-- =========================================================

-- 更新边框颜色
function PixelPerfect.UpdateBorderColor(frame, color)
    if not frame or not frame._ppBorders then return end
    color = color or { r = 1, g = 1, b = 1, a = 1 }
    for _, border in ipairs(frame._ppBorders) do
        border:SetVertexColor(color.r, color.g, color.b, color.a)
    end
end

-- 隐藏边框
function PixelPerfect.HideBorder(frame)
    if not frame or not frame._ppBorders then return end
    for _, border in ipairs(frame._ppBorders) do
        border:Hide()
    end
end

-- 显示边框
function PixelPerfect.ShowBorder(frame)
    if not frame or not frame._ppBorders then return end
    for _, border in ipairs(frame._ppBorders) do
        border:Show()
    end
end

-- 创建完美像素边框
-- frame: 目标帧
-- thickness: 边框厚度（逻辑像素）
-- color: 边框颜色 {r, g, b, a}
-- inset: 是否内嵌（true=边框在帧内部，false=边框在帧外部）。默认 true。
function PixelPerfect.CreateBorder(frame, thickness, color, inset)
    if not frame then return end

    thickness = thickness or 1
    color = color or { r = 0, g = 0, b = 0, a = 1 }
    if inset == nil then inset = true end

    -- 对齐 TOPLEFT 角落到像素网格（仅对单锚点帧有效）
    -- CENTER 对齐无法保证 TOPLEFT 在像素边界（帧尺寸为奇数像素时偏移半像素），
    -- 导致边框纹理跨两个物理像素而变粗。
    -- 多锚点帧（SetAllPoints）跳过：其位置由父帧决定，不能破坏多锚点布局。
    if frame.GetNumPoints and frame:GetNumPoints() == 1 then
        local frameLeft = frame:GetLeft()
        local frameTop  = frame:GetTop()
        if frameLeft and frameTop then
            local onePixel = GetOnePixelSize(frame)
            local snappedLeft = math.floor(frameLeft / onePixel + 0.5) * onePixel
            local snappedTop  = math.floor(frameTop  / onePixel + 0.5) * onePixel
            local dx = snappedLeft - frameLeft
            local dy = snappedTop  - frameTop
            if math.abs(dx) > 1e-5 or math.abs(dy) > 1e-5 then
                local pt, rel, relPt, x, y = frame:GetPoint(1)
                if pt then
                    frame:ClearAllPoints()
                    frame:SetPoint(pt, rel or UIParent, relPt or pt,
                                   (x or 0) + dx, (y or 0) + dy)
                end
            end
        end
    end

    -- 清理旧边框
    if frame._ppBorders then
        for _, border in ipairs(frame._ppBorders) do
            border:Hide()
            border:SetParent(nil)
        end
    end

    local borders = {}
    frame._ppBorders = borders

    -- 计算实际厚度
    local t
    if thickness == 1 then
        -- 特殊处理：如果请求1px，强制使用1物理像素，确保锐利
        t = GetOnePixelSize(frame)
    else
        t = PixelSnap(thickness, frame)
        -- 确保至少可见（不小于1物理像素）
        local onePixel = GetOnePixelSize(frame)
        if t < onePixel then t = onePixel end
    end

    -- 创建四条边
    -- 使用 WHITE8X8 纹理并禁用引擎自动像素 snap，
    -- 避免 SetColorTexture 被引擎二次对齐到错误像素边界导致边框变粗。
    local WHITE8X8 = "Interface\\Buttons\\WHITE8X8"
    local function makeBorderTex()
        local tex = frame:CreateTexture(nil, "OVERLAY")
        tex:SetTexture(WHITE8X8)
        if tex.SetSnapToPixelGrid  then tex:SetSnapToPixelGrid(false) end
        if tex.SetTexelSnappingBias then tex:SetTexelSnappingBias(0) end
        tex:SetVertexColor(color.r, color.g, color.b, color.a)
        return tex
    end
    local top    = makeBorderTex()
    local bottom = makeBorderTex()
    local left   = makeBorderTex()
    local right  = makeBorderTex()

    table.insert(borders, top)
    table.insert(borders, bottom)
    table.insert(borders, left)
    table.insert(borders, right)

    -- 设置尺寸
    top:SetHeight(t)
    bottom:SetHeight(t)
    left:SetWidth(t)
    right:SetWidth(t)

    if inset then
        -- 内嵌模式：边框在Frame内部
        -- 为避免半透明叠加加深，安排如下：
        -- Top/Bottom: 左右撑满
        -- Left/Right: 在Top/Bottom之间
        
        -- Top
        top:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, 0)
        top:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        
        -- Bottom
        bottom:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
        bottom:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
        
        -- Left (上下缩进t)
        left:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -t)
        left:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, t)
        
        -- Right (上下缩进t)
        right:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -t)
        right:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, t)
        
    else
        -- 外扩模式：边框在Frame外部
        -- 同样避免重叠
        -- Left/Right: 上下延伸（包角）
        -- Top/Bottom: 位于Left/Right之间
        
        -- Left (全高)
        left:SetPoint("TOPRIGHT", frame, "TOPLEFT", 0, t)
        left:SetPoint("BOTTOMRIGHT", frame, "BOTTOMLEFT", 0, -t)
        
        -- Right (全高)
        right:SetPoint("TOPLEFT", frame, "TOPRIGHT", 0, t)
        right:SetPoint("BOTTOMLEFT", frame, "BOTTOMRIGHT", 0, -t)
        
        -- Top (位于Left/Right内侧)
        top:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", 0, 0)
        top:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", 0, 0)
        
        -- Bottom (位于Left/Right内侧)
        bottom:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 0, 0)
        bottom:SetPoint("TOPRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    end

    return borders
end

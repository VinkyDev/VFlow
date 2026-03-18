-- =========================================================
-- VFlow StyleLayout - 布局计算和定位
-- 收集图标、分行、计算位置
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local StyleLayout = {}
VFlow.StyleLayout = StyleLayout

local floor = math.floor
local abs = math.abs
local Profiler = VFlow.Profiler

-- =========================================================
-- 工具函数
-- =========================================================

-- 缓存SetPoint，只在值变化时调用
function StyleLayout.SetPointCached(frame, point, relativeTo, relativePoint, x, y)
    if frame:GetNumPoints() == 1 then
        local p, rel, relP, cx, cy = frame:GetPoint(1)
        if p == point and rel == relativeTo and relP == relativePoint
            and abs(cx - x) < 0.01 and abs(cy - y) < 0.01 then
            return
        end
    end
    frame:ClearAllPoints()
    frame:SetPoint(point, relativeTo, relativePoint, x, y)
end

-- 收集viewer下所有图标帧
function StyleLayout.CollectIcons(viewer)
    local _pt = Profiler.start("SL:CollectIcons")
    local icons = {}
    local seen = {}

    for _, child in ipairs({ viewer:GetChildren() }) do
        if child and child.Icon then
            seen[child] = true
            icons[#icons + 1] = child
        end
    end

    -- 检查对象池
    if viewer.itemFramePool then
        for frame in viewer.itemFramePool:EnumerateActive() do
            if frame and frame.Icon and not seen[frame] then
                icons[#icons + 1] = frame
            end
        end
    end

    table.sort(icons, function(a, b)
        return (a.layoutIndex or 0) < (b.layoutIndex or 0)
    end)
    Profiler.stop(_pt)
    return icons
end

-- 过滤可见图标
function StyleLayout.FilterVisible(icons)
    local _pt = Profiler.start("SL:FilterVisible")
    local visible = {}
    for i = 1, #icons do
        local icon = icons[i]
        if icon:IsShown() then
            local tex = icon.Icon and icon.Icon:GetTexture()
            if tex then
                visible[#visible + 1] = icon
            end
        end
    end
    Profiler.stop(_pt)
    return visible
end

-- 按每行上限分行
function StyleLayout.BuildRows(limit, icons)
    local rows = {}
    if limit <= 0 then
        rows[1] = icons
        return rows
    end
    for i = 1, #icons do
        local ri = floor((i - 1) / limit) + 1
        rows[ri] = rows[ri] or {}
        rows[ri][#rows[ri] + 1] = icons[i]
    end
    return rows
end

-- 同步viewer尺寸与实际图标边界框
function StyleLayout.UpdateViewerSizeToMatchIcons(viewer, icons)
    if not viewer or not icons or #icons == 0 then return end
    local vScale = viewer:GetEffectiveScale()
    if not vScale or vScale == 0 then return end

    local left, right, top, bottom = 999999, 0, 0, 999999
    for _, icon in ipairs(icons) do
        if icon and icon:IsShown() then
            local scale = icon:GetEffectiveScale() / vScale
            local l = (icon:GetLeft() or 0) * scale
            local r = (icon:GetRight() or 0) * scale
            local t = (icon:GetTop() or 0) * scale
            local b = (icon:GetBottom() or 0) * scale
            if l < left then left = l end
            if r > right then right = r end
            if t > top then top = t end
            if b < bottom then bottom = b end
        end
    end

    if left >= right or bottom >= top then return end

    local targetW = right - left
    local targetH = top - bottom
    local curW = viewer:GetWidth()
    local curH = viewer:GetHeight()
    if curW and curH and (abs(curW - targetW) >= 1 or abs(curH - targetH) >= 1) then
        viewer:SetSize(targetW, targetH)
    end
end

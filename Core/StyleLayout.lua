-- =========================================================
-- SECTION 1: 模块入口
-- StyleLayout — 收集图标、分行、计算位置
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local StyleLayout = {}
VFlow.StyleLayout = StyleLayout

local Utils = VFlow.Utils

local floor = math.floor
local abs = math.abs
local Profiler = VFlow.Profiler

-- 池活动数量（优先 API，避免每帧全量 Enumerate）
local function PoolActiveCount(pool)
    if not pool then return 0 end
    if pool.GetNumActive then
        local n = pool:GetNumActive()
        if type(n) == "number" and n >= 0 then return n end
    end
    local n = 0
    if pool.EnumerateActive then
        for _ in pool:EnumerateActive() do
            n = n + 1
        end
    end
    return n
end

StyleLayout.PoolActiveCount = PoolActiveCount

--- 池/子级数量变化时清空 CollectIcons 等缓存（CooldownStyle 在 Acquire/Release 等时机调用）
function StyleLayout.InvalidateCollectIconsCache(viewer)
    if not viewer then return end
    viewer._vf_sl_icons = nil
    viewer._vf_sl_cn = nil
    viewer._vf_sl_pn = nil
    viewer._vf_bb_frames_cached = nil
    viewer._vf_bb_frames_cn = nil
    viewer._vf_bb_frames_pn = nil
end

-- =========================================================
-- SECTION 2: 工具函数
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

-- 收集viewer下所有图标帧（轻量缓存：仅子级数 + 池活动数；排序在池成员不变时复用）
function StyleLayout.CollectIcons(viewer)
    if not viewer then
        return {}
    end

    local childN = select("#", viewer:GetChildren())
    local poolN = PoolActiveCount(viewer.itemFramePool)
    local cached = viewer._vf_sl_icons
    if cached and viewer._vf_sl_cn == childN and viewer._vf_sl_pn == poolN then
        return cached
    end

    local icons = {}
    local seen = {}

    for _, ch in ipairs({ viewer:GetChildren() }) do
        if ch and ch.Icon and not ch._vf_itemAppendFrame then
            seen[ch] = true
            icons[#icons + 1] = ch
        end
    end

    if viewer.itemFramePool then
        for frame in viewer.itemFramePool:EnumerateActive() do
            if frame and frame.Icon and not seen[frame] and not frame._vf_itemAppendFrame then
                icons[#icons + 1] = frame
            end
        end
    end

    Utils.sortByLayoutIndex(icons)
    viewer._vf_sl_icons = icons
    viewer._vf_sl_cn = childN
    viewer._vf_sl_pn = poolN
    return icons
end

-- 过滤可见图标
function StyleLayout.FilterVisible(icons)
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
    if not vScale or vScale == 0 then
        return
    end

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

    if left >= right or bottom >= top then
        return
    end

    local targetW = right - left
    local targetH = top - bottom
    local curW = viewer:GetWidth()
    local curH = viewer:GetHeight()
    if curW and curH and (abs(curW - targetW) >= 1 or abs(curH - targetH) >= 1) then
        viewer:SetSize(targetW, targetH)
    end
end

if Profiler and Profiler.registerTableScope then
    Profiler.registerTableScope(StyleLayout, "CollectIcons", "SL:CollectIcons")
    Profiler.registerTableScope(StyleLayout, "FilterVisible", "SL:FilterVisible")
    Profiler.registerTableScope(StyleLayout, "BuildRows", "SL:BuildRows")
    Profiler.registerTableScope(StyleLayout, "UpdateViewerSizeToMatchIcons", "SL:UpdateViewerSizeToMatchIcons")
end

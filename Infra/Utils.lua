-- =========================================================
-- VFlow Utils - 通用工具函数
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

VFlow.Utils = {}
local Utils = VFlow.Utils

--- 深度合并：将 defaults 中缺失的字段补填到 target，已有值不覆盖
-- 对嵌套 table 递归处理（如 timerFont、barColor 等子表）
-- @param target table 目标表（已有配置）
-- @param defaults table 默认值表
function Utils.applyDefaults(target, defaults)
    for k, v in pairs(defaults) do
        if target[k] == nil then
            if type(v) == "table" then
                target[k] = {}
                Utils.applyDefaults(target[k], v)
            else
                target[k] = v
            end
        elseif type(v) == "table" and type(target[k]) == "table" then
            Utils.applyDefaults(target[k], v)
        end
    end
end

--- 合并多个 layout 数组（支持 nil 和 false，用于条件性添加）
-- 用法: mergeLayouts(layout1, condition and layout2, layout3)
function Utils.mergeLayouts(...)
    local result = {}
    for i = 1, select("#", ...) do
        local layout = select(i, ...)
        if type(layout) == "table" then
            for _, item in ipairs(layout) do
                table.insert(result, item)
            end
        end
    end
    return result
end

--- 去除首尾空白（非 string 返回空串）
function Utils.trim(value)
    if type(value) ~= "string" then
        return ""
    end
    return (value:gsub("^%s*(.-)%s*$", "%1"))
end

--- 按 layoutIndex 升序排序（CDM 子帧与池化图标等）
function Utils.sortByLayoutIndex(list)
    if type(list) ~= "table" then
        return list
    end
    table.sort(list, function(a, b)
        return (a and a.layoutIndex or 0) < (b and b.layoutIndex or 0)
    end)
    return list
end

--- 按 .name 升序原地排序（元素无 name 时视为 ""）
function Utils.sortByName(list)
    if type(list) ~= "table" then
        return list
    end
    table.sort(list, function(a, b)
        local na = a and a.name or ""
        local nb = b and b.name or ""
        return na < nb
    end)
    return list
end

--- 扫描后刷新所有自定义组的 _dataVersion，驱动 Grid 中 dependsOn 列表重绘
function Utils.bumpCustomGroupsDataVersion(moduleKey, customGroups)
    if not moduleKey or type(customGroups) ~= "table" or not VFlow.Store then
        return
    end
    local v = GetTime()
    for i = 1, #customGroups do
        VFlow.Store.set(moduleKey, "customGroups." .. i .. ".config._dataVersion", v)
    end
end

--- 未在 State 中追踪时，用 spellID 构造占位列表项（技能/BUFF 选择器共用）
function Utils.placeholderSpellEntry(spellID)
    local spellInfo = C_Spell.GetSpellInfo(spellID)
    local name = spellInfo and spellInfo.name
    local icon = spellInfo and spellInfo.iconID
    return {
        spellID = spellID,
        name = name or ("未知技能 " .. spellID),
        icon = icon or 134400,
        isMissing = true,
    }
end

--- 12.0+ Cooldown 禁止对 SetCooldown 传入含 secret 的起止参数；使用 Duration 对象
-- @param cd Cooldown 子帧
-- @param hostFrame 用于挂接可复用 Duration 的宿主（如图标 Frame，字段 _vf_cooldownDurObj）
-- @param startTime 起始时间（可与游戏 API 一致，含 secret）
-- @param durationSeconds 持续长度（秒，可与 API 一致）
-- @return 是否已成功调用 SetCooldownFromDurationObject
function Utils.setCooldownFromStartAndDuration(cd, hostFrame, startTime, durationSeconds)
    if not cd or not hostFrame then return false end
    if not (C_DurationUtil and C_DurationUtil.CreateDuration and cd.SetCooldownFromDurationObject) then
        return false
    end
    if not hostFrame._vf_cooldownDurObj then
        hostFrame._vf_cooldownDurObj = C_DurationUtil.CreateDuration()
    end
    local durObj = hostFrame._vf_cooldownDurObj
    local ok = pcall(function()
        durObj:SetTimeFromStart(startTime, durationSeconds)
        cd:SetCooldownFromDurationObject(durObj)
    end)
    return ok
end

--- 条「沿填充轴长度」：手动值或与重要/效能技能条（CooldownViewer）当前宽度同步
--- @param cfg table 配置表（含 manualKey / modeKey）
--- @param options? { manualKey?: string, modeKey?: string, defaultMode?: string }
function Utils.ResolveSyncedBarSpan(cfg, options)
    if not cfg then
        return 200
    end
    options = options or {}
    local manualKey = options.manualKey or "barWidth"
    local modeKey = options.modeKey or "barWidthMode"
    local defaultMode = options.defaultMode or "manual"
    local manual = tonumber(cfg[manualKey]) or 200
    local mode = cfg[modeKey] or defaultMode
    if mode == "sync_essential" or mode == "sync_utility" then
        local viewer = mode == "sync_essential" and _G.EssentialCooldownViewer
            or _G.UtilityCooldownViewer
        if viewer and viewer.GetWidth then
            local w = viewer:GetWidth()
            if type(w) == "number" and w > 1 then
                return w
            end
        end
    end
    return manual
end

-- 向后兼容：保留 VFlow.LayoutUtils 别名
VFlow.LayoutUtils = {
    mergeLayouts = Utils.mergeLayouts,
}

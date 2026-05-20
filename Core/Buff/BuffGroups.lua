-- =========================================================
-- BuffGroups — 自定义 BUFF 分组（TrackerGroup 薄封装）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
if not VFlow.ModuleControlConstants.CORE_ENABLED then return end

local MODULE_KEY = "VFlow.Buffs"
local TrackerGroup = VFlow.TrackerGroup

local BuffGroups = TrackerGroup.Create({
    moduleKey = MODULE_KEY,
    hideConfigKey = "buffs",
    framePrefix = "VFlow_BuffGroup_",
    menuKeyPrefix = "buff_custom_",
    defaultLabel = "Custom group",
    cdmKind = "buff",
    eventOwner = "BuffGroups",
    layoutMode = "dynamic",
    showOnRestore = false,
    visibilityKey = "buffs",

    getGroupIdxForIcon = TrackerGroup.BuffGetGroupIdxForIcon,

    getDragOptions = function(groupIdx, group, db)
        return {
            onPositionChanged = function(_, kind, x, y)
                if kind ~= "PLAYER_ANCHOR" and kind ~= "SYMMETRIC" then return end
                VFlow.Store.set(MODULE_KEY, "customGroups." .. groupIdx .. ".config.x", x)
                VFlow.Store.set(MODULE_KEY, "customGroups." .. groupIdx .. ".config.y", y)
            end,
            getAnchorOffset = function(frame)
                local cfg = group.config
                if not cfg or not cfg.dynamicLayout then return 0, 0 end
                local growDir = cfg.growDirection or "center"
                if growDir == "center" then return 0, 0 end

                local w, h = frame:GetSize()
                local isVertical = (cfg.vertical == true)

                if not isVertical then
                    if growDir == "start" then return -w / 2, 0
                    elseif growDir == "end" then return w / 2, 0 end
                else
                    if growDir == "start" then return 0, h / 2
                    elseif growDir == "end" then return 0, -h / 2 end
                end
                return 0, 0
            end,
        }
    end,

    onInit = function(tracker)
        C_Timer.After(0, function() tracker.reinitContainers() end)
    end,

    onStoreChange = function(tracker, key, value)
        -- 结构性变化：重建全部容器
        if key == "customGroups" or key:find("^customGroups%.%d+$") then
            tracker.reinitContainers()
        end

        -- 位置变化：仅重新锚定
        if key:find("customGroups%.%d+%.config%.") then
            local groupIndex = tonumber(key:match("customGroups%.(%d+)%."))
            if groupIndex and (
                key:find("%.x$") or key:find("%.y$")
                or key:find("%.anchorFrame$") or key:find("%.relativePoint$")
                or key:find("%.playerAnchorPosition$")
            ) then
                tracker.applyGroupAnchor(groupIndex)
                return
            end
        end

        tracker.markDirty()
    end,
})

-- 兼容已有调用点
BuffGroups.layoutBuffGroups = BuffGroups.layoutGroups
BuffGroups.isGroupFrame = function(icon)
    local spellMap = BuffGroups.buildGroupSpellMap()
    local idx = TrackerGroup.BuffGetGroupIdxForIcon(icon, spellMap)
    return idx ~= nil and idx ~= -1
end

VFlow.BuffGroups = BuffGroups

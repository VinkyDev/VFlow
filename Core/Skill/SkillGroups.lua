-- =========================================================
-- SkillGroups — 自定义技能分组（TrackerGroup 薄封装）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
if not VFlow.ModuleControlConstants.CORE_ENABLED then return end

local MODULE_KEY = "VFlow.Skills"
local TrackerGroup = VFlow.TrackerGroup

local SkillGroups = TrackerGroup.Create({
    moduleKey = MODULE_KEY,
    hideConfigKey = "skills",
    framePrefix = "VFlow_SkillGroup_",
    menuKeyPrefix = "skill_custom_",
    defaultLabel = "Custom skill group",
    cdmKind = "skill",
    eventOwner = "SkillGroups",
    layoutMode = "grid",
    showOnRestore = true,

    getGroupIdxForIcon = TrackerGroup.SkillGetGroupIdxForIcon,

    getDragOptions = function(groupIdx, group, db)
        return {
            onPositionChanged = function(_, kind, x, y)
                if kind ~= "PLAYER_ANCHOR" and kind ~= "SYMMETRIC" then return end
                group.config.x = x
                group.config.y = y
                VFlow.Store.set(MODULE_KEY, "customGroups", db.customGroups)
            end,
        }
    end,

    onInit = function(tracker)
        tracker.markDirty()
    end,

    onStoreChange = function(tracker, key, value)
        tracker.markDirty()
        if not (VFlow.RefreshBus and VFlow.RefreshBus.request) then return end

        local scopes = { VFlow.RefreshBus.SCOPES.SKILL_GROUP_MAP, VFlow.RefreshBus.SCOPES.SKILL_GROUP_LAYOUT }
        local opts = {}

        if key and key:find("^customGroups%.%d+%.config%.") then
            local groupIndex = tonumber(key:match("customGroups%.(%d+)%."))
            if groupIndex then opts.groupIndex = groupIndex end
        end

        if key and (key:find("%.x$") or key:find("%.y$")
            or key:find("%.anchorFrame$") or key:find("%.relativePoint$")
            or key:find("%.playerAnchorPosition$")) then
            opts.flags = { reanchorOnly = true }
            VFlow.RefreshBus.request(VFlow.RefreshBus.SCOPES.SKILL_GROUP_LAYOUT, opts)
            return
        end

        VFlow.RefreshBus.request(scopes, opts)
    end,
})

-- 兼容已有调用点
SkillGroups.layoutSkillGroups = SkillGroups.layoutGroups
SkillGroups.layoutGroupBuckets = SkillGroups.layoutGroups

VFlow.SkillGroups = SkillGroups

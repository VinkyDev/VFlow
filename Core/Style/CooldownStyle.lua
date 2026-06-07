-- =========================================================
-- VFlow CooldownStyle — 技能/BUFF 样式引擎主入口
-- 职责：维护全局样式版本（_buttonStyleVersion）、监听配置变化、初始化 Hook
--
-- 子模块：
--   - Style/CustomHighlight.lua             自定义高亮
--   - Skill/SkillRefreshOrchestrator.lua    技能 Pass 流水线编排
--   - Buff/BuffRuntime.lua                  BUFF 图标刷新
--   - Buff/BuffBarRuntime.lua               BUFF 条形刷新
--   - Style/ViewerHooks.lua                 Blizzard Viewer Hook 安装
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
local CORE_ENABLED = ModuleControlConstants.CORE_ENABLED
local BUFF_BAR_ENABLED = ModuleControlConstants.BUFF_BAR_ENABLED

if not (CORE_ENABLED or BUFF_BAR_ENABLED) then return end

local RefreshBus = VFlow.RefreshBus
local ViewerRefreshQueue = VFlow.ViewerRefreshQueue
local SkillStylePass = VFlow.SkillStylePass
local SkillRefreshOrchestrator = VFlow.SkillRefreshOrchestrator
local BuffRuntime = VFlow.BuffRuntime
local BuffBarRuntime = VFlow.BuffBarRuntime
local CustomHighlight = VFlow.CustomHighlight
local ViewerHooks = VFlow.ViewerHooks

-- =========================================================
-- SECTION 1: 全局按钮样式版本号
-- =========================================================

local _buttonStyleVersion = 0
VFlow._buttonStyleVersion = _buttonStyleVersion

local function BumpButtonStyleVersion()
    _buttonStyleVersion = _buttonStyleVersion + 1
    VFlow._buttonStyleVersion = _buttonStyleVersion
end

-- =========================================================
-- SECTION 2: 请求入口转发
-- =========================================================

local function RequestSkillRefresh(scopeOrScopes, opts)
    if SkillRefreshOrchestrator and SkillRefreshOrchestrator.requestSkillRefresh then
        SkillRefreshOrchestrator.requestSkillRefresh(scopeOrScopes, opts)
    end
end

local function RequestBuffRefresh(opts)
    if BuffRuntime and BuffRuntime.requestBuffRefresh then
        BuffRuntime.requestBuffRefresh(opts)
    end
end

local function RequestBuffBarRefresh(opts)
    if BuffBarRuntime and BuffBarRuntime.requestRefresh then
        BuffBarRuntime.requestRefresh(opts)
    end
end

local function RequestKeybindStyleRefresh(delay)
    if not CORE_ENABLED then return end
    BumpButtonStyleVersion()
    if SkillRefreshOrchestrator and SkillRefreshOrchestrator.requestDelayedSkillRefresh then
        SkillRefreshOrchestrator.requestDelayedSkillRefresh(delay, RefreshBus.PRESETS.SKILL_STYLE)
    end
end

VFlow.RequestKeybindStyleRefresh = RequestKeybindStyleRefresh

-- =========================================================
-- SECTION 3: 初始 / 专精切换刷新
-- =========================================================

local function RequestInitialViewerRefresh()
    if CORE_ENABLED then
        RequestSkillRefresh(RefreshBus.PRESETS.SKILL_FULL, {
            flags = { forceDependentLayout = true },
        })
    end

    local get = VFlow and VFlow.Store and VFlow.Store.getModuleRef
    local buffsDB = CORE_ENABLED and get and get("VFlow.Buffs") or nil
    local buffBarDB = BUFF_BAR_ENABLED and get and get("VFlow.BuffBar") or nil

    if buffsDB and buffsDB.buffMonitor then
        RequestBuffRefresh()
    end

    if buffBarDB then
        RequestBuffBarRefresh()
    end
end

local function InvalidateAllDBCache()
    if BuffRuntime and BuffRuntime.invalidateDBCache then
        BuffRuntime.invalidateDBCache()
    end
    if BuffBarRuntime and BuffBarRuntime.invalidateDBCache then
        BuffBarRuntime.invalidateDBCache()
    end
end

local function BumpAllStyleVersions()
    BumpButtonStyleVersion()
    if BuffBarRuntime and BuffBarRuntime.bumpStyleVersion then
        BuffBarRuntime.bumpStyleVersion()
    end
end

VFlow.on("PLAYER_ENTERING_WORLD", "VFlow.SkillStyle", function()
    if not (CORE_ENABLED or BUFF_BAR_ENABLED) then
        return
    end
    InvalidateAllDBCache()
    BumpAllStyleVersions()
    if ViewerRefreshQueue then ViewerRefreshQueue.bumpVersion() end
    if ViewerHooks and ViewerHooks.setup then
        ViewerHooks.setup()
    end
    C_Timer.After(0.5, RequestInitialViewerRefresh)
end)

VFlow.on("PLAYER_SPECIALIZATION_CHANGED", "VFlow.SkillStyle.SpecRefresh", function()
    if SkillRefreshOrchestrator and SkillRefreshOrchestrator.requestSpecDrivenSkillRefresh then
        SkillRefreshOrchestrator.requestSpecDrivenSkillRefresh()
    end
end)

-- =========================================================
-- SECTION 4: Store 监听
-- =========================================================

local function IsSkillStyleConfigKey(key)
    if not key then return false end
    local lowerKey = string.lower(key)
    return lowerKey:find("font")
        or lowerKey:find("border")
        or lowerKey:find("overlay")
        or lowerKey:find("glow")
        or lowerKey:find("keybind")
        or lowerKey:find("zoom")
        or lowerKey:find("color")
        or lowerKey:find("mask")
end

local function IsSkillGroupMapConfigKey(key)
    if not key then return false end
    return key:find("%.spellIDs$")
        or key:find("^customGroups%.%d+%.config%.spellIDs")
        or key:find("%.hideInCooldownManager$")
end

if CORE_ENABLED then
    VFlow.Store.watch("VFlow.Skills", "CooldownStyle_Skills", function(key, _)
        if key:find("^customGroups%.%d+%.config%.")
            and (key:find("%.x$") or key:find("%.y$")
                or key:find("%.anchorFrame$") or key:find("%.relativePoint$")
                or key:find("%.playerAnchorPosition$")) then
            local groupIndex = tonumber(key:match("^customGroups%.(%d+)%."))
            RequestSkillRefresh(RefreshBus.SCOPES.SKILL_GROUP_LAYOUT, {
                groupIndex = groupIndex,
                flags = { reanchorOnly = true },
            })
            return
        end
        if IsSkillStyleConfigKey(key) then
            BumpButtonStyleVersion()
            if SkillStylePass and SkillStylePass.Invalidate then
                SkillStylePass.Invalidate()
            end
            RequestSkillRefresh(RefreshBus.PRESETS.SKILL_STYLE)
            return
        end

        if IsSkillGroupMapConfigKey(key) then
            RequestSkillRefresh(RefreshBus.PRESETS.SKILL_GROUP_MAP)
            return
        end

        RequestSkillRefresh(RefreshBus.PRESETS.SKILL_LAYOUT)
    end)

    VFlow.Store.watch("VFlow.Buffs", "CooldownStyle_Buffs", function(key, _)
        if BuffRuntime and BuffRuntime.invalidateDBCache then
            BuffRuntime.invalidateDBCache()
        end
        if key:find("%.x$") or key:find("%.y$")
            or key:find("%.anchorFrame$") or key:find("%.relativePoint$") or key:find("%.playerAnchorPosition$") then
            return
        end
        BumpButtonStyleVersion()
        if ViewerRefreshQueue then ViewerRefreshQueue.bumpVersion() end
        RequestBuffRefresh()
    end)

    VFlow.Store.watch("VFlow.CustomMonitor", "CooldownStyle_CustomMonitor", function(key, _)
        if key:find("%.hideInCooldownManager$") then
            RequestSkillRefresh(RefreshBus.PRESETS.SKILL_LAYOUT)
        end
    end)

    VFlow.Store.watch("VFlow.OtherFeatures", "CooldownStyle_SharedSettingsHL", function(key, _)
        if not key then return end
        if key == "skillRules" or key:find("^skillRules%.") then
            BumpButtonStyleVersion()
            RequestSkillRefresh({
                RefreshBus.SCOPES.SKILL_STYLE,
                RefreshBus.SCOPES.HIGHLIGHT,
            })
        end
        if key == "highlightRules" or key:find("^highlightRules%.")
            or key == "highlightOnlyInCombat" then
            RequestSkillRefresh(RefreshBus.PRESETS.SKILL_HIGHLIGHT, { immediate = false })
            if CustomHighlight and CustomHighlight.refreshAll then
                C_Timer.After(0, CustomHighlight.refreshAll)
            end
        end
    end)

    VFlow.Store.watch("VFlow.StyleIcon", "CooldownStyle_StyleIcon", function(_, _)
        BumpAllStyleVersions()
        if SkillStylePass and SkillStylePass.Invalidate then
            SkillStylePass.Invalidate()
        end
        RequestSkillRefresh(RefreshBus.PRESETS.SKILL_STYLE)
        RequestBuffRefresh()
        RequestBuffBarRefresh()
    end)
end

if BUFF_BAR_ENABLED then
    VFlow.Store.watch("VFlow.BuffBar", "CooldownStyle_BuffBar", function(_, _)
        if BuffBarRuntime and BuffBarRuntime.invalidateDBCache then
            BuffBarRuntime.invalidateDBCache()
        end
        BumpAllStyleVersions()
        if ViewerRefreshQueue then ViewerRefreshQueue.bumpVersion() end
        RequestBuffBarRefresh()
    end)
end

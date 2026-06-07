-- =========================================================
-- VFlow CustomHighlight
-- 职责：技能/BUFF 图标自定义高亮（SharedSettings.highlightRules）
--
-- 数据流：
--   Hook OnShow / OnHide / OnCooldownIDSet / SpellStateWatcher
--     → RequestCustomHighlightUpdate(frame)（同帧合并）
--     → UpdateCustomHighlightForFrame → StyleApply.ShowCustomGlow / HideCustomGlow
--
-- 由 Style/CooldownStyle.lua、Skill/SkillRefreshOrchestrator.lua、
-- Buff/BuffRuntime.lua、Buff/BuffBarRuntime.lua 共用。
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CORE_ENABLED then return end

local StyleApply = VFlow.StyleApply
local StyleLayout = VFlow.StyleLayout
local Profiler = VFlow.Profiler

local CustomHighlight = {}
VFlow.CustomHighlight = CustomHighlight

-- =========================================================
-- SECTION 1: 高亮规则查询
-- =========================================================

local SHARED_SETTINGS_KEY = "VFlow.OtherFeatures"

local function GetSharedSettingsDB()
    local store = VFlow.Store
    if not store or not store.getModuleRef then return nil end
    return store.getModuleRef(SHARED_SETTINGS_KEY)
end

local function GetSharedSettingsHighlightRule(spellID)
    if not spellID then return nil end
    local db = GetSharedSettingsDB()
    if not db then return nil end
    local rules = db.highlightRules
    if not rules then return nil end
    local r = rules[spellID] or rules[tostring(spellID)]
    if type(r) ~= "table" or not r.enabled then return nil end
    return r
end

--- 默认 true（与模块 defaults 一致）；仅当显式为 false 时脱战也高亮
local function SharedSettingsHighlightOnlyInCombat()
    local db = GetSharedSettingsDB()
    if not db then return true end
    return db.highlightOnlyInCombat ~= false
end

local function IsPlayerInCombatForCustomHighlight()
    return UnitAffectingCombat and UnitAffectingCombat("player") == true
end

-- =========================================================
-- SECTION 2: 帧 → spellID / kind 解析
-- =========================================================

local function ResolveHighlightSpellID(frame)
    if not frame then return nil end
    if frame.GetSpellID then
        local id = frame:GetSpellID()
        if id and (not issecretvalue or not issecretvalue(id)) and type(id) == "number" and id > 0 then
            return id
        end
    end
    if frame.GetAuraSpellID then
        local id = frame:GetAuraSpellID()
        if id and (not issecretvalue or not issecretvalue(id)) and type(id) == "number" and id > 0 then
            return id
        end
    end
    if frame.cooldownID and StyleLayout.GetCachedCooldownViewerInfo then
        local info = StyleLayout.GetCachedCooldownViewerInfo(frame)
        if info then
            local spellID = info.linkedSpellIDs and info.linkedSpellIDs[1]
            spellID = spellID or info.overrideSpellID or info.spellID
            if spellID and spellID > 0 then
                return spellID
            end
        end
    end
    return nil
end

local function GetSpellStateWatcher()
    return VFlow.SpellStateWatcher
end

local function InferCdmKindFromParent(frame)
    local p = frame and frame:GetParent()
    if not p then return nil end
    local n = p:GetName()
    if n == "EssentialCooldownViewer" or n == "UtilityCooldownViewer" then return "skill" end
    if n == "BuffIconCooldownViewer" or n == "BuffBarCooldownViewer" then return "buff" end
    if n and n:match("^VFlow_SkillGroup_") then return "skill" end
    if n and n:match("^VFlow_BuffGroup_") then return "buff" end
    return nil
end

local function GetCdmFrameKind(frame)
    if not frame then return nil end
    if frame._vf_cdmKind == "skill" or frame._vf_cdmKind == "buff" then
        return frame._vf_cdmKind
    end
    return InferCdmKindFromParent(frame)
end

local function HighlightRuleMatchesKind(rule, kind)
    if not rule or not kind then return false end
    local src = rule.source
    if not src or src == "" then
        return true
    end
    if src == "skill" then return kind == "skill" end
    if src == "buff" then return kind == "buff" end
    return false
end

-- =========================================================
-- SECTION 3: 是否应高亮（图标 ready/active 判定）
-- =========================================================

-- 与 CustomMonitorRuntime / ItemGroups 一致：仅受 GCD 锁时仍视为「可用」
local function SkillCooldownIsGcdOnly(spellID)
    if not spellID or not C_Spell or not C_Spell.GetSpellCooldown then return false end
    local ok, info = pcall(function() return C_Spell.GetSpellCooldown(spellID) end)
    if not ok or type(info) ~= "table" then return false end
    return info.isOnGCD == true
end

local function SkillIconAppearsReady(frame)
    if not frame or not frame:IsShown() then return false end
    local spellID = ResolveHighlightSpellID(frame)
    if spellID and SkillCooldownIsGcdOnly(spellID) then
        return true
    end
    local cd = frame.Cooldown
    if not cd or not cd.IsShown or not cd:IsShown() then return true end
    local ok, dur = pcall(function()
        return cd.GetCooldownDuration and cd:GetCooldownDuration()
    end)
    if not ok or dur == nil then return false end
    if type(dur) == "number" then
        if issecretvalue and issecretvalue(dur) then return false end
        return dur <= 0
    end
    return false
end

local function BuffIconAppearsActive(frame)
    if not frame or not frame:IsShown() then return false end
    local a = frame.GetAlpha and frame:GetAlpha()
    if type(a) == "number" and a < 0.05 then return false end
    return true
end

local function UpdateCustomHighlightForFrame(frame)
    if not StyleApply or not StyleApply.ShowCustomGlow or not StyleApply.HideCustomGlow then return end
    local kind = GetCdmFrameKind(frame)
    local spellID = ResolveHighlightSpellID(frame)
    local rule = spellID and GetSharedSettingsHighlightRule(spellID)
    local wantGlow = false
    if rule and HighlightRuleMatchesKind(rule, kind) then
        if kind == "skill" then
            wantGlow = SkillIconAppearsReady(frame)
        elseif kind == "buff" then
            wantGlow = BuffIconAppearsActive(frame)
        end
    end
    if wantGlow and SharedSettingsHighlightOnlyInCombat() and not IsPlayerInCombatForCustomHighlight() then
        wantGlow = false
    end
    if wantGlow then
        StyleApply.ShowCustomGlow(frame)
    else
        StyleApply.HideCustomGlow(frame)
    end
end

-- =========================================================
-- SECTION 4: 同帧合并（双缓冲队列）
-- =========================================================

-- BUFF 激活瞬间会连续触发 CD 更新 / RefreshData / OnActiveStateChanged，合并到帧末只算一次，避免发光被反复打断。
-- 技能图标也必须延迟：SetCooldown hook 若在暴雪 RefreshData/充能缓存链内同步调用 C_Spell.GetSpellCooldown，
-- 会使 spellChargeInfo.maxCharges 等 secret 带上 VFlow 污染，触发 Blizzard_CooldownViewer CacheChargeValues 报错。
local pendingBatch1, pendingBatch2 = {}, {}
local pendingFrames = pendingBatch1
local flushFrame = CreateFrame("Frame")
flushFrame:Hide()

local flushOnUpdate
flushOnUpdate = function(self)
    self:Hide()
    for _ = 1, 12 do
        local batch = pendingFrames
        if not next(batch) then break end
        pendingFrames = (batch == pendingBatch1) and pendingBatch2 or pendingBatch1
        for f in pairs(batch) do
            if f and f.Icon then
                UpdateCustomHighlightForFrame(f)
            end
        end
        wipe(batch)
    end
end
flushFrame:SetScript("OnUpdate", flushOnUpdate)

local function RequestCustomHighlightUpdate(frame)
    if not frame then return end
    pendingFrames[frame] = true
    flushFrame:Show()
end

-- =========================================================
-- SECTION 5: SpellStateWatcher 订阅同步
-- =========================================================

local function EnsureCustomHighlightWatchOwner(frame)
    if not frame then return nil end
    if not frame._vf_customHLWatchOwner then
        frame._vf_customHLWatchOwner = { frame = frame }
    end
    return frame._vf_customHLWatchOwner
end

local function ReleaseCustomHighlightWatcher(frame)
    if not frame or not frame._vf_customHLWatchedSpellID then
        return
    end
    local watcher = GetSpellStateWatcher()
    local ownerKey = frame._vf_customHLWatchOwner
    if watcher and ownerKey then
        watcher.unwatch(ownerKey, frame._vf_customHLWatchedSpellID)
    end
    frame._vf_customHLWatchedSpellID = nil
end

local function SyncCustomHighlightWatcher(frame)
    if not frame or not frame.Icon then return end

    local kind = GetCdmFrameKind(frame)
    local isShown = frame.IsShown and frame:IsShown()
    local spellID = isShown and ResolveHighlightSpellID(frame) or nil
    local rule = spellID and GetSharedSettingsHighlightRule(spellID)
    local shouldWatch = isShown and rule and HighlightRuleMatchesKind(rule, kind)

    if shouldWatch and spellID == frame._vf_customHLWatchedSpellID then
        return
    end

    ReleaseCustomHighlightWatcher(frame)
    if not shouldWatch or not spellID then
        return
    end

    local watcher = GetSpellStateWatcher()
    if not watcher then return end

    local ownerKey = EnsureCustomHighlightWatchOwner(frame)
    if watcher.watch(ownerKey, spellID, function()
        RequestCustomHighlightUpdate(frame)
    end) then
        frame._vf_customHLWatchedSpellID = spellID
    end
end

-- =========================================================
-- SECTION 6: 帧 Hook（OnShow / OnHide）
-- =========================================================

local function EnsureCustomHighlightHooks(frame)
    if not frame or frame._vf_customHLHooked then return end
    frame._vf_customHLHooked = true
    if frame.HookScript then
        frame:HookScript("OnShow", function(self)
            SyncCustomHighlightWatcher(self)
            RequestCustomHighlightUpdate(self)
        end)
        frame:HookScript("OnHide", function(self)
            pendingFrames[self] = nil
            pendingBatch1[self] = nil
            pendingBatch2[self] = nil
            ReleaseCustomHighlightWatcher(self)
            if StyleApply and StyleApply.HideCustomGlow then
                StyleApply.HideCustomGlow(self)
            end
        end)
    end
end

local function TouchCustomHighlight(frame)
    if not frame or not frame.Icon then return end
    EnsureCustomHighlightHooks(frame)
    SyncCustomHighlightWatcher(frame)
    RequestCustomHighlightUpdate(frame)
end

-- =========================================================
-- SECTION 7: 批量扫描
-- =========================================================

--- @param icons? table 若已在同次刷新中 CollectIcons，传入可避免二次收集
local function ScanCooldownViewerIcons(viewer, icons)
    if not viewer then return end
    local list = icons or StyleLayout.CollectIcons(viewer)
    for i = 1, #list do
        TouchCustomHighlight(list[i])
    end
end

local function ScanSkillGroupCustomHighlights()
    if VFlow.SkillGroups and VFlow.SkillGroups.forEachGroupIcon then
        VFlow.SkillGroups.forEachGroupIcon(function(icon)
            TouchCustomHighlight(icon)
        end)
    end
end

local function ScanBuffGroupCustomHighlights()
    if VFlow.BuffGroups and VFlow.BuffGroups.forEachGroupIcon then
        VFlow.BuffGroups.forEachGroupIcon(function(icon)
            TouchCustomHighlight(icon)
        end)
    end
end

local function RefreshAllOtherFeatureHighlights()
    ScanCooldownViewerIcons(_G.EssentialCooldownViewer)
    ScanCooldownViewerIcons(_G.UtilityCooldownViewer)
    ScanCooldownViewerIcons(_G.BuffIconCooldownViewer)
    ScanSkillGroupCustomHighlights()
    ScanBuffGroupCustomHighlights()
end

-- =========================================================
-- SECTION 8: 战斗状态切换刷新
-- =========================================================

VFlow.on("PLAYER_REGEN_ENABLED", "VFlow.CustomHL.OutOfCombat", function()
    RefreshAllOtherFeatureHighlights()
end)
VFlow.on("PLAYER_REGEN_DISABLED", "VFlow.CustomHL.InCombat", function()
    RefreshAllOtherFeatureHighlights()
end)

-- =========================================================
-- SECTION 9: Profiler 注册
-- =========================================================

if Profiler and Profiler.registerScope then
    Profiler.registerScope("CDS:customHLFlush_OnUpdate", function()
        return flushOnUpdate
    end, function(fn)
        flushOnUpdate = fn
        flushFrame:SetScript("OnUpdate", fn)
    end)
    Profiler.registerScope("CDS:RefreshAllOtherFeatureHighlights", function()
        return RefreshAllOtherFeatureHighlights
    end, function(fn)
        RefreshAllOtherFeatureHighlights = fn
    end)
end

-- =========================================================
-- SECTION 10: 公共接口
-- =========================================================

CustomHighlight.touch = TouchCustomHighlight
CustomHighlight.request = RequestCustomHighlightUpdate
CustomHighlight.ensureHooks = EnsureCustomHighlightHooks
CustomHighlight.syncWatcher = SyncCustomHighlightWatcher
CustomHighlight.scanViewer = ScanCooldownViewerIcons
CustomHighlight.scanSkillGroups = ScanSkillGroupCustomHighlights
CustomHighlight.scanBuffGroups = ScanBuffGroupCustomHighlights
CustomHighlight.refreshAll = RefreshAllOtherFeatureHighlights
CustomHighlight.resolveSpellID = ResolveHighlightSpellID

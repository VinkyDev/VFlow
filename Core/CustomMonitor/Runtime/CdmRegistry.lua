-- =========================================================
-- VFlow CustomMonitor Runtime — CdmRegistry
-- 职责：扫描 Blizzard CooldownViewer 帧，建立
--   spellID ↔ cooldownID ↔ CDM 帧 三向映射；
--   提供 ShadowCooldown 创建辅助。
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

VFlow.CustomMonitor = VFlow.CustomMonitor or {}
VFlow.CustomMonitor.Runtime = VFlow.CustomMonitor.Runtime or {}

local Constants = VFlow.CustomMonitor.Runtime.Constants
local State = VFlow.CustomMonitor.Runtime.State

local CdmRegistry = {}
VFlow.CustomMonitor.Runtime.CdmRegistry = CdmRegistry

-- =========================================================
-- SECTION 1: 类型与判定
-- =========================================================

local function HasAuraInstanceID(value)
    if value == nil then return false end
    if issecretvalue and issecretvalue(value) then return true end
    if type(value) == "number" and value == 0 then return false end
    return true
end

-- CDM 偶发把整份 AuraData 挂在 auraInstanceID 上；C_UnitAuras 只要数值 ID。
local function AuraInstanceIDForAPI(v)
    if type(v) == "table" and v.auraInstanceID ~= nil then return v.auraInstanceID end
    return v
end

--- 仅用于映射/表键：含 secret 的 spellID 不可参与 >0 或与配置 ID 比较
local function IsUsableNonSecretSpellId(id)
    if not id or type(id) ~= "number" then return false end
    if issecretvalue and issecretvalue(id) then return false end
    return id > 0
end

local function SafeSpellIdEquals(a, b)
    local ok, eq = pcall(function() return a == b end)
    return ok and eq
end

local function GetCooldownIDFromFrame(frame)
    local cdID = frame.cooldownID
    if not cdID and frame.cooldownInfo then
        cdID = frame.cooldownInfo.cooldownID
    end
    return cdID
end

local function ResolveSpellID(info)
    if not info then return nil end
    local linked = info.linkedSpellIDs and info.linkedSpellIDs[1]
    if IsUsableNonSecretSpellId(linked) then return linked end
    if IsUsableNonSecretSpellId(info.overrideSpellID) then return info.overrideSpellID end
    if IsUsableNonSecretSpellId(info.spellID) then return info.spellID end
    return nil
end

-- =========================================================
-- SECTION 2: 帧注册 / 扫描
-- =========================================================

-- 从单个 CDM 帧注册映射（只追加，可在战斗中调用）
local function RegisterCDMFrame(frame)
    local cdID = GetCooldownIDFromFrame(frame)
    if not cdID then return end
    State.cooldownIDToFrame[cdID] = frame
    local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
    if not info then return end
    local sid = ResolveSpellID(info)
    if sid and not State.spellToCooldownID[sid] then
        State.spellToCooldownID[sid] = cdID
    end
    if info.linkedSpellIDs then
        for _, lid in ipairs(info.linkedSpellIDs) do
            if IsUsableNonSecretSpellId(lid) and not State.spellToCooldownID[lid] then
                State.spellToCooldownID[lid] = cdID
            end
        end
    end
    if IsUsableNonSecretSpellId(info.spellID) and not State.spellToCooldownID[info.spellID] then
        State.spellToCooldownID[info.spellID] = cdID
    end
end

-- 全量扫描重建映射（仅脱战时调用，需要 wipe 清表）
local function ScanCDMViewers()
    if InCombatLockdown() then return end
    wipe(State.spellToCooldownID)
    wipe(State.cooldownIDToFrame)
    wipe(State.spellMapRetryAt)
    for _, viewerName in ipairs(Constants.BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            if viewer.itemFramePool then
                for frame in viewer.itemFramePool:EnumerateActive() do
                    RegisterCDMFrame(frame)
                end
            else
                for _, child in ipairs({ viewer:GetChildren() }) do
                    RegisterCDMFrame(child)
                end
            end
        end
    end
end

-- 战斗中为单个 spellID 补建映射（只追加，找到即停）
-- 调用方负责检查 State.spellToCooldownID[spellID] == nil 后再调用
local function TryMapSpellID(spellID)
    local now = GetTime and GetTime() or 0
    local retryAt = State.spellMapRetryAt[spellID]
    if retryAt and now < retryAt then return end
    for _, viewerName in ipairs(Constants.BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            local function check(frame)
                local cdID = GetCooldownIDFromFrame(frame)
                if not cdID then return false end
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cdID)
                if not info then return false end
                local sid = ResolveSpellID(info)
                if SafeSpellIdEquals(sid, spellID) or SafeSpellIdEquals(info.spellID, spellID) then
                    RegisterCDMFrame(frame)
                    return true
                end
                if info.linkedSpellIDs then
                    for _, lid in ipairs(info.linkedSpellIDs) do
                        if SafeSpellIdEquals(lid, spellID) then
                            RegisterCDMFrame(frame)
                            return true
                        end
                    end
                end
                return false
            end
            if viewer.itemFramePool then
                for frame in viewer.itemFramePool:EnumerateActive() do
                    if check(frame) then
                        State.spellMapRetryAt[spellID] = nil
                        return
                    end
                end
            else
                for _, child in ipairs({ viewer:GetChildren() }) do
                    if check(child) then
                        State.spellMapRetryAt[spellID] = nil
                        return
                    end
                end
            end
        end
    end
    State.spellMapRetryAt[spellID] = now + Constants.MAP_RETRY_INTERVAL
end

local function FindCDMFrame(cooldownID)
    if not cooldownID then return nil end
    local cached = State.cooldownIDToFrame[cooldownID]
    if cached then return cached end
    for _, viewerName in ipairs(Constants.BUFF_VIEWERS) do
        local viewer = _G[viewerName]
        if viewer then
            if viewer.itemFramePool then
                for frame in viewer.itemFramePool:EnumerateActive() do
                    local cdID = GetCooldownIDFromFrame(frame)
                    if cdID == cooldownID then
                        State.cooldownIDToFrame[cdID] = frame
                        return frame
                    end
                end
            else
                for _, child in ipairs({ viewer:GetChildren() }) do
                    local cdID = GetCooldownIDFromFrame(child)
                    if cdID == cooldownID then
                        State.cooldownIDToFrame[cdID] = child
                        return child
                    end
                end
            end
        end
    end
    return nil
end

-- =========================================================
-- SECTION 3: ShadowCooldown（技能冷却用）
-- =========================================================

local function GetOrCreateShadowCooldown(barFrame)
    if barFrame._shadowCooldown then return barFrame._shadowCooldown end
    local cd = CreateFrame("Cooldown", nil, barFrame, "CooldownFrameTemplate")
    cd:SetAllPoints(barFrame)
    cd:SetDrawSwipe(false)
    cd:SetDrawEdge(false)
    cd:SetDrawBling(false)
    cd:SetHideCountdownNumbers(true)
    cd:SetAlpha(0)
    cd:EnableMouse(false)
    barFrame._shadowCooldown = cd
    return cd
end

-- =========================================================
-- SECTION 4: 公共接口
-- =========================================================

CdmRegistry.hasAuraInstanceID = HasAuraInstanceID
CdmRegistry.auraInstanceIDForAPI = AuraInstanceIDForAPI
CdmRegistry.isUsableNonSecretSpellId = IsUsableNonSecretSpellId
CdmRegistry.safeSpellIdEquals = SafeSpellIdEquals
CdmRegistry.getCooldownIDFromFrame = GetCooldownIDFromFrame
CdmRegistry.resolveSpellID = ResolveSpellID
CdmRegistry.registerCDMFrame = RegisterCDMFrame
CdmRegistry.scanCDMViewers = ScanCDMViewers
CdmRegistry.tryMapSpellID = TryMapSpellID
CdmRegistry.findCDMFrame = FindCDMFrame
CdmRegistry.getOrCreateShadowCooldown = GetOrCreateShadowCooldown

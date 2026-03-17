-- =========================================================
-- VFlow SkillScanner - 冷却管理器技能扫描
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

-- =========================================================
-- Spell ID解析
-- =========================================================

local function ResolveSpellID(info)
    if not info then return nil end

    -- 优先级1：如果暴雪在 CDM info 里明确给了 overrideSpellID，优先使用
    if info.overrideSpellID and info.overrideSpellID > 0 then
        return info.overrideSpellID
    end

    -- 优先级2：获取实际生效的覆盖技能（解决天赋强化版技能ID与基础ID不一致的问题）
    local baseID = info.spellID
    if baseID and baseID > 0 then
        local overrideID = C_Spell.GetOverrideSpell(baseID)
        if overrideID and overrideID > 0 and overrideID ~= baseID then
            return overrideID
        end
    end

    -- 优先级3：如果技能有 linkedSpellIDs（通常是光环变体），取第一个
    if info.linkedSpellIDs and info.linkedSpellIDs[1] and info.linkedSpellIDs[1] > 0 then
        return info.linkedSpellIDs[1]
    end

    return baseID
end

-- =========================================================
-- 扫描调度器
-- =========================================================

local function ScanSkillViewers()
    if InCombatLockdown() then return end

    local skills = {}

    -- 只扫描重要技能查看器
    local viewer = _G["EssentialCooldownViewer"]
    if viewer and viewer.itemFramePool then
        -- 遍历活动帧
        for frame in viewer.itemFramePool:EnumerateActive() do
            local cooldownID = frame.cooldownID
            if cooldownID then
                local info = C_CooldownViewer.GetCooldownViewerCooldownInfo(cooldownID)
                if info then
                    local spellID = ResolveSpellID(info)
                    if spellID and spellID > 0 then
                        local spellInfo = C_Spell.GetSpellInfo(spellID)
                        if spellInfo and spellInfo.name and spellInfo.iconID then
                            skills[spellID] = {
                                spellID = spellID,
                                name = spellInfo.name,
                                icon = spellInfo.iconID,
                                cooldownID = cooldownID,
                            }
                        end
                    end
                end
            end
        end
    end

    -- 更新全局状态
    VFlow.State.update("trackedSkills", skills)

    local count = 0
    for _ in pairs(skills) do count = count + 1 end
end

local function ScheduleScan()
    C_Timer.After(0.5, ScanSkillViewers)
    C_Timer.After(2.0, ScanSkillViewers)
end

-- =========================================================
-- 事件监听
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "SkillScanner", ScheduleScan)
VFlow.on("PLAYER_SPECIALIZATION_CHANGED", "SkillScanner", ScheduleScan)
VFlow.on("TRAIT_CONFIG_UPDATED", "SkillScanner", ScheduleScan)

-- =========================================================
-- 公共API
-- =========================================================

VFlow.SkillScanner = {
    scan = ScanSkillViewers,
}

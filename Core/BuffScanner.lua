-- =========================================================
-- SECTION 1: 模块入口
-- BuffScanner — 冷却管理器 BUFF 扫描
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Profiler = VFlow.Profiler

-- =========================================================
-- SECTION 2: SpellID 解析
-- =========================================================

local function ResolveSpellID(info)
    if not info then return nil end

    -- 优先级：linkedSpellIDs[1] > overrideSpellID > spellID
    if info.linkedSpellIDs and info.linkedSpellIDs[1] then
        return info.linkedSpellIDs[1]
    end

    return info.overrideSpellID or info.spellID
end

-- =========================================================
-- SECTION 3: 扫描调度
-- =========================================================

local function ScanBuffViewers()
    if InCombatLockdown() then return end

    local _pt = Profiler.start("BS:ScanBuffViewers")
    local buffs = {}

    -- 扫描BUFF查看器
    for _, viewerName in ipairs({ "BuffIconCooldownViewer" }) do
        local viewer = _G[viewerName]
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
                                buffs[spellID] = {
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
    end

    -- 更新全局状态
    VFlow.State.update("trackedBuffs", buffs)

    Profiler.stop(_pt)
end

local function ScheduleScan()
    C_Timer.After(0.5, ScanBuffViewers)
    C_Timer.After(2.0, ScanBuffViewers)
end

-- =========================================================
-- SECTION 4: 事件监听
-- =========================================================

VFlow.on("PLAYER_ENTERING_WORLD", "BuffScanner", ScheduleScan)
VFlow.on("PLAYER_SPECIALIZATION_CHANGED", "BuffScanner", ScheduleScan)
VFlow.on("TRAIT_CONFIG_UPDATED", "BuffScanner", ScheduleScan)

-- =========================================================
-- SECTION 5: 公共接口
-- =========================================================

VFlow.BuffScanner = {
    scan = ScanBuffViewers,
}

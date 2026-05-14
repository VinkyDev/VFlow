-- =========================================================
-- VFlow CustomMonitor Runtime — State
-- 模块级运行时状态表（活跃条/Hook/索引/刷新调度）
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

VFlow.CustomMonitor = VFlow.CustomMonitor or {}
VFlow.CustomMonitor.Runtime = VFlow.CustomMonitor.Runtime or {}

local State = {}
VFlow.CustomMonitor.Runtime.State = State

-- =========================================================
-- 活跃条索引（spellID → barFrame）
-- =========================================================

State.activeSkillBars = {}
State.activeBuffBars = {}

-- BUFF 派发索引（unit → spellID → barFrame）
State.buffProbeBars = {}
State.buffWatchedBars = {
    player = {},
    pet = {},
    target = {},
}

-- =========================================================
-- spellID → cooldownID 映射 / cooldownID → CDM帧 缓存
-- =========================================================

State.spellToCooldownID = {}
State.cooldownIDToFrame = {}
State.spellMapRetryAt = {}

-- =========================================================
-- CDM 帧 Hook 管理（弱表，随 CDM 帧释放自动清理）
-- =========================================================

State.hookedFrames = setmetatable({}, { __mode = "k" })   -- cdmFrame → { barIDs = {key→true} }
State.everHookedFrames = setmetatable({}, { __mode = "k" })
State.frameToBarKeys = setmetatable({}, { __mode = "k" }) -- cdmFrame → { barKey, ... }

-- aura key "unit#instanceID" → { barKey → true }（stacks 专用）
State.auraKeyToBars = {}
State.barToAuraKey = {}                                   -- barKey → aura key

-- =========================================================
-- CDM 同帧合并刷新调度
-- =========================================================
-- CDM RefreshData 等钩子同帧可能触发多次：合并到帧末一次处理，减少 UpdateStackBar 重复。

State.cdmFlushPending = setmetatable({}, { __mode = "k" })  -- [cdmFrame] = true
State.cdmFlushLastAura = setmetatable({}, { __mode = "k" }) -- [cdmFrame] = { auraInstanceID?, auraUnit? }
State.cdmFlushScratch = {}
State.cdmFlushFrame = CreateFrame("Frame")
State.cdmFlushFrame:Hide()

-- =========================================================
-- Tick 循环状态
-- =========================================================

State.tickBars = {}
State.tickBarCount = 0
State.tickScratch = {}
State.refreshScratch = {}
State.elapsed = 0
State.updateFrame = CreateFrame("Frame")
State.updateFrame:Hide()

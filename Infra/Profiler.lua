-- =========================================================
-- VFlow Profiler - 运行时性能打点
-- /vfprof start  开始采集
-- /vfprof stop   停止并打印报告
-- /vfprof reset  重置计数器
--
-- 未激活时 start/stop/count 均为空函数，零运行时开销。
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Profiler = {}
VFlow.Profiler = Profiler

local GetTime = GetTime
local _startTime = 0

-- 计数器：{ [name] = { calls = 0, totalMs = 0, maxMs = 0 } }
local _counters = {}

local function GetCounter(name)
    local c = _counters[name]
    if not c then
        c = { calls = 0, totalMs = 0, maxMs = 0 }
        _counters[name] = c
    end
    return c
end

-- =========================================================
-- 真实实现（仅在 active 期间使用）
-- =========================================================

local function realStart(name)
    return { name = name, t0 = debugprofilestop() }
end

local function realStop(token)
    if not token then return end
    local elapsed = debugprofilestop() - token.t0
    local c = GetCounter(token.name)
    c.calls = c.calls + 1
    c.totalMs = c.totalMs + elapsed
    if elapsed > c.maxMs then c.maxMs = elapsed end
end

local function realCount(name)
    local c = GetCounter(name)
    c.calls = c.calls + 1
end

-- =========================================================
-- 空实现（默认状态，零开销）
-- =========================================================

local NOOP_TOKEN = false

local function noopStart() return NOOP_TOKEN end
local function noopStop() end
local function noopCount() end

-- 默认挂载空实现
Profiler.start = noopStart
Profiler.stop  = noopStop
Profiler.count = noopCount

-- =========================================================
-- 切换函数
-- =========================================================

local function activate()
    Profiler.start = realStart
    Profiler.stop  = realStop
    Profiler.count = realCount
end

local function deactivate()
    Profiler.start = noopStart
    Profiler.stop  = noopStop
    Profiler.count = noopCount
end

-- =========================================================
-- 会话管理
-- =========================================================

function Profiler.reset()
    wipe(_counters)
end

function Profiler.startSession()
    Profiler.reset()
    _startTime = GetTime()
    activate()
    print("|cff00ff00VFlow Profiler:|r 开始采集")
end

function Profiler.stopSession()
    deactivate()
    local duration = GetTime() - _startTime

    print("========================================")
    print("VFlow Profiler 报告")
    print(string.format("采集时长: %.1f 秒", duration))
    print("----------------------------------------")
    print(string.format("%-45s %8s %10s %8s %8s", "函数", "调用次数", "总耗时ms", "最大ms", "次/秒"))
    print("----------------------------------------")

    local sorted = {}
    for name, c in pairs(_counters) do
        sorted[#sorted + 1] = { name = name, calls = c.calls, totalMs = c.totalMs, maxMs = c.maxMs }
    end
    table.sort(sorted, function(a, b) return a.totalMs > b.totalMs end)

    for _, entry in ipairs(sorted) do
        local perSec = duration > 0 and (entry.calls / duration) or 0
        print(string.format("%-45s %8d %10.2f %8.3f %8.1f",
            entry.name, entry.calls, entry.totalMs, entry.maxMs, perSec))
    end

    print("========================================")
end

-- =========================================================
-- 斜杠命令
-- =========================================================

SLASH_VFPROF1 = "/vfprof"
SlashCmdList["VFPROF"] = function(msg)
    msg = (msg or ""):lower():trim()
    if msg == "start" then
        Profiler.startSession()
    elseif msg == "stop" then
        Profiler.stopSession()
    elseif msg == "reset" then
        Profiler.reset()
        print("|cff00ff00VFlow Profiler:|r 已重置")
    else
        print("|cff00ff00VFlow Profiler:|r /vfprof start|stop|reset")
    end
end

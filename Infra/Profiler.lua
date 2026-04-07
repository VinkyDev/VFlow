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
local unpack = table.unpack or unpack
local pack = table.pack or function(...)
    return { n = select("#", ...), ... }
end

local _active = false
local _startTime = 0
local _lastDuration = 0
local _hasSnapshot = false
local _records = {}
local _eventOwners = {}
local _scopeStats = {}
local _countStats = {}
local _roots = {}
local _edges = {}
local _stack = {}

local function ResolveLabel(labelOrResolver, ...)
    if type(labelOrResolver) == "function" then
        local ok, value = pcall(labelOrResolver, ...)
        if ok and type(value) == "string" and value ~= "" then
            return value
        end
        return "Profiler:<invalid-label>"
    end
    if type(labelOrResolver) == "string" and labelOrResolver ~= "" then
        return labelOrResolver
    end
    return "Profiler:<unnamed>"
end

local function GetScopeStat(name)
    local stat = _scopeStats[name]
    if not stat then
        stat = {
            name = name,
            kind = "scope",
            calls = 0,
            totalMs = 0,
            selfMs = 0,
            maxMs = 0,
            maxSelfMs = 0,
        }
        _scopeStats[name] = stat
    end
    return stat
end

local function GetCountStat(name)
    local stat = _countStats[name]
    if not stat then
        stat = {
            name = name,
            kind = "count",
            calls = 0,
        }
        _countStats[name] = stat
    end
    return stat
end

local function GetRootStat(name)
    local stat = _roots[name]
    if not stat then
        stat = {
            name = name,
            calls = 0,
            totalMs = 0,
            maxMs = 0,
        }
        _roots[name] = stat
    end
    return stat
end

local function GetEdgeStat(parentName, childName)
    local byParent = _edges[parentName]
    if not byParent then
        byParent = {}
        _edges[parentName] = byParent
    end
    local edge = byParent[childName]
    if not edge then
        edge = {
            parent = parentName,
            name = childName,
            calls = 0,
            totalMs = 0,
            selfMs = 0,
            maxMs = 0,
            maxSelfMs = 0,
        }
        byParent[childName] = edge
    end
    return edge
end

local function RecordCount(name)
    local stat = GetCountStat(name)
    stat.calls = stat.calls + 1
end

local function RecordScopeSample(name, elapsed, selfMs, parentName)
    local stat = GetScopeStat(name)
    stat.calls = stat.calls + 1
    stat.totalMs = stat.totalMs + elapsed
    stat.selfMs = stat.selfMs + selfMs
    if elapsed > stat.maxMs then
        stat.maxMs = elapsed
    end
    if selfMs > stat.maxSelfMs then
        stat.maxSelfMs = selfMs
    end
    if parentName then
        local edge = GetEdgeStat(parentName, name)
        edge.calls = edge.calls + 1
        edge.totalMs = edge.totalMs + elapsed
        edge.selfMs = edge.selfMs + selfMs
        if elapsed > edge.maxMs then
            edge.maxMs = elapsed
        end
        if selfMs > edge.maxSelfMs then
            edge.maxSelfMs = selfMs
        end
    else
        local root = GetRootStat(name)
        root.calls = root.calls + 1
        root.totalMs = root.totalMs + elapsed
        if elapsed > root.maxMs then
            root.maxMs = elapsed
        end
    end
end

local function ErrorHandler(err)
    if debugstack then
        return tostring(err) .. "\n" .. debugstack(3, 8, 8)
    end
    return tostring(err)
end

local function WrapScope(labelOrResolver, fn)
    return function(...)
        local name = ResolveLabel(labelOrResolver, ...)
        local parent = _stack[#_stack]
        local frame = {
            name = name,
            childMs = 0,
            t0 = debugprofilestop(),
        }
        _stack[#_stack + 1] = frame
        local args = pack(...)
        local results = pack(xpcall(function()
            return fn(unpack(args, 1, args.n))
        end, ErrorHandler))
        _stack[#_stack] = nil
        local elapsed = debugprofilestop() - frame.t0
        local selfMs = elapsed - frame.childMs
        if selfMs < 0 then
            selfMs = 0
        end
        if parent then
            parent.childMs = parent.childMs + elapsed
            RecordScopeSample(name, elapsed, selfMs, parent.name)
        else
            RecordScopeSample(name, elapsed, selfMs, nil)
        end
        if not results[1] then
            error(results[2], 0)
        end
        return unpack(results, 2, results.n)
    end
end

local function WrapCount(labelOrResolver, fn)
    return function(...)
        RecordCount(ResolveLabel(labelOrResolver, ...))
        return fn(...)
    end
end

local function MakeWrappedFunction(record, fn)
    if record.mode == "count" then
        return WrapCount(record.labelOrResolver, fn)
    end
    return WrapScope(record.labelOrResolver, fn)
end

local function ApplyPatchRecord(record)
    if record.applied then
        return
    end
    local fn = record.getter and record.getter() or nil
    if type(fn) ~= "function" then
        return
    end
    record.original = fn
    record.wrapped = MakeWrappedFunction(record, fn)
    record.setter(record.wrapped)
    record.applied = true
end

local function RestorePatchRecord(record)
    if not record.applied then
        return
    end
    if type(record.original) == "function" then
        record.setter(record.original)
    end
    record.applied = false
    record.wrapped = nil
end

local function RefreshEventOwner(owner)
    local group = _eventOwners[owner]
    if not group then
        return
    end
    VFlow.off(owner)
    for _, record in ipairs(group.records) do
        local callback = record.original
        if _active then
            callback = MakeWrappedFunction(record, record.original)
        end
        record.current = callback
        VFlow.on(record.event, owner, callback, record.units)
    end
end

local function RegisterPatchRecord(mode, labelOrResolver, getter, setter)
    local record = {
        type = "patch",
        mode = mode,
        labelOrResolver = labelOrResolver,
        getter = getter,
        setter = setter,
        applied = false,
    }
    _records[#_records + 1] = record
    if _active then
        ApplyPatchRecord(record)
    end
    return record
end

function Profiler.registerScope(labelOrResolver, getter, setter)
    return RegisterPatchRecord("scope", labelOrResolver, getter, setter)
end

function Profiler.registerCount(labelOrResolver, getter, setter)
    return RegisterPatchRecord("count", labelOrResolver, getter, setter)
end

function Profiler.registerTableScope(target, key, labelOrResolver)
    return Profiler.registerScope(labelOrResolver, function()
        return target and target[key]
    end, function(fn)
        target[key] = fn
    end)
end

function Profiler.registerTableCount(target, key, labelOrResolver)
    return Profiler.registerCount(labelOrResolver, function()
        return target and target[key]
    end, function(fn)
        target[key] = fn
    end)
end

function Profiler.registerScript(frame, scriptName, labelOrResolver, callback, mode)
    frame:SetScript(scriptName, callback)
    local current = callback
    local setter = function(fn)
        current = fn
        frame:SetScript(scriptName, fn)
    end
    local getter = function()
        return current
    end
    if mode == "count" then
        return Profiler.registerCount(labelOrResolver, getter, setter)
    end
    return Profiler.registerScope(labelOrResolver, getter, setter)
end

function Profiler.registerEvent(event, owner, callback, units, labelOrResolver, mode)
    local group = _eventOwners[owner]
    if not group then
        group = { records = {} }
        _eventOwners[owner] = group
    end
    local record = {
        type = "event",
        event = event,
        owner = owner,
        units = units,
        original = callback,
        mode = mode or "scope",
        labelOrResolver = labelOrResolver,
    }
    group.records[#group.records + 1] = record
    RefreshEventOwner(owner)
    return record
end

local function realStart(name)
    local parent = _stack[#_stack]
    local frame = {
        name = ResolveLabel(name),
        childMs = 0,
        t0 = debugprofilestop(),
        parent = parent,
    }
    _stack[#_stack + 1] = frame
    return frame
end

local function realStop(token)
    if not token then
        return
    end
    if _stack[#_stack] == token then
        _stack[#_stack] = nil
    else
        for i = #_stack, 1, -1 do
            if _stack[i] == token then
                table.remove(_stack, i)
                break
            end
        end
    end
    local elapsed = debugprofilestop() - token.t0
    local selfMs = elapsed - (token.childMs or 0)
    if selfMs < 0 then
        selfMs = 0
    end
    local parent = token.parent
    if parent then
        parent.childMs = parent.childMs + elapsed
        RecordScopeSample(token.name, elapsed, selfMs, parent.name)
    else
        RecordScopeSample(token.name, elapsed, selfMs, nil)
    end
end

local function realCount(name)
    RecordCount(ResolveLabel(name))
end

local NOOP_TOKEN = false

local function noopStart()
    return NOOP_TOKEN
end

local function noopStop()
end

local function noopCount()
end

Profiler.start = noopStart
Profiler.stop = noopStop
Profiler.count = noopCount

local function activate()
    _active = true
    wipe(_stack)
    for _, record in ipairs(_records) do
        ApplyPatchRecord(record)
    end
    for owner in pairs(_eventOwners) do
        RefreshEventOwner(owner)
    end
    Profiler.start = realStart
    Profiler.stop = realStop
    Profiler.count = realCount
end

local function deactivate()
    Profiler.start = noopStart
    Profiler.stop = noopStop
    Profiler.count = noopCount
    for _, record in ipairs(_records) do
        RestorePatchRecord(record)
    end
    _active = false
    for owner in pairs(_eventOwners) do
        RefreshEventOwner(owner)
    end
    wipe(_stack)
end

function Profiler.reset()
    wipe(_scopeStats)
    wipe(_countStats)
    wipe(_roots)
    wipe(_edges)
    wipe(_stack)
    _lastDuration = 0
    _hasSnapshot = false
end

local function GetReportDuration()
    if _active then
        return math.max((GetTime() - _startTime), 0)
    end
    if _hasSnapshot then
        return _lastDuration
    end
    return math.max((GetTime() - _startTime), 0)
end

local function BuildSortedList(map, valueKey)
    local list = {}
    for _, entry in pairs(map) do
        list[#list + 1] = entry
    end
    table.sort(list, function(a, b)
        local av = a[valueKey] or 0
        local bv = b[valueKey] or 0
        if av == bv then
            return (a.calls or 0) > (b.calls or 0)
        end
        return av > bv
    end)
    return list
end

local function FlattenEdges(valueKey)
    local list = {}
    for _, byParent in pairs(_edges) do
        for _, edge in pairs(byParent) do
            list[#list + 1] = edge
        end
    end
    table.sort(list, function(a, b)
        local av = a[valueKey] or 0
        local bv = b[valueKey] or 0
        if av == bv then
            return (a.calls or 0) > (b.calls or 0)
        end
        return av > bv
    end)
    return list
end

local function PrintScopeTable(title, entries, duration, valueKey, limit)
    print("----------------------------------------")
    print(title)
    print(string.format("%-45s %8s %10s %10s %8s", "函数", "调用次数", "总耗时ms", "Self耗时", "次/秒"))
    print("----------------------------------------")
    local maxCount = math.min(limit, #entries)
    for i = 1, maxCount do
        local entry = entries[i]
        local perSec = duration > 0 and (entry.calls / duration) or 0
        print(string.format("%-45s %8d %10.2f %10.2f %8.1f",
            entry.name, entry.calls, entry.totalMs or 0, entry.selfMs or 0, perSec))
    end
end

local function PrintRootTable(entries, duration, limit)
    print("----------------------------------------")
    print("顶层入口")
    print(string.format("%-45s %8s %10s %8s", "函数", "调用次数", "总耗时ms", "次/秒"))
    print("----------------------------------------")
    local maxCount = math.min(limit, #entries)
    for i = 1, maxCount do
        local entry = entries[i]
        local perSec = duration > 0 and (entry.calls / duration) or 0
        print(string.format("%-45s %8d %10.2f %8.1f",
            entry.name, entry.calls, entry.totalMs or 0, perSec))
    end
end

local function PrintEdgeTable(entries, duration, limit)
    print("----------------------------------------")
    print("父子链路")
    print(string.format("%-45s %8s %10s %10s %8s", "父 -> 子", "调用次数", "总耗时ms", "Self耗时", "次/秒"))
    print("----------------------------------------")
    local maxCount = math.min(limit, #entries)
    for i = 1, maxCount do
        local entry = entries[i]
        local perSec = duration > 0 and (entry.calls / duration) or 0
        print(string.format("%-45s %8d %10.2f %10.2f %8.1f",
            entry.parent .. " -> " .. entry.name, entry.calls, entry.totalMs or 0, entry.selfMs or 0, perSec))
    end
end

local function PrintCountTable(entries, duration, limit)
    print("----------------------------------------")
    print("计数器")
    print(string.format("%-45s %8s %8s", "函数", "调用次数", "次/秒"))
    print("----------------------------------------")
    local maxCount = math.min(limit, #entries)
    for i = 1, maxCount do
        local entry = entries[i]
        local perSec = duration > 0 and (entry.calls / duration) or 0
        print(string.format("%-45s %8d %8.1f", entry.name, entry.calls, perSec))
    end
end

function Profiler.printReport(mode, limit)
    local duration = GetReportDuration()
    local maxRows = tonumber(limit) or 30
    if maxRows < 1 then
        maxRows = 30
    end
    local timedBySelf = BuildSortedList(_scopeStats, "selfMs")
    local timedByTotal = BuildSortedList(_scopeStats, "totalMs")
    local roots = BuildSortedList(_roots, "totalMs")
    local edges = FlattenEdges("totalMs")
    local counts = BuildSortedList(_countStats, "calls")
    local selected = (mode or "all"):lower()

    print("========================================")
    print("VFlow Profiler 报告")
    print(string.format("采集时长: %.1f 秒", duration))
    print(string.format("计时节点: %d  计数节点: %d", #timedByTotal, #counts))

    if selected == "all" or selected == "self" then
        PrintScopeTable("Self 热点", timedBySelf, duration, "selfMs", maxRows)
    end
    if selected == "all" or selected == "inclusive" or selected == "total" then
        PrintScopeTable("Inclusive 热点", timedByTotal, duration, "totalMs", maxRows)
    end
    if selected == "all" or selected == "roots" then
        PrintRootTable(roots, duration, maxRows)
    end
    if selected == "all" or selected == "edges" then
        PrintEdgeTable(edges, duration, maxRows)
    end
    if selected == "all" or selected == "counts" then
        PrintCountTable(counts, duration, maxRows)
    end
    print("========================================")
end

function Profiler.startSession()
    if _active then
        print("|cff00ff00VFlow Profiler:|r 已在采集中")
        return
    end
    Profiler.reset()
    _startTime = GetTime()
    activate()
    print("|cff00ff00VFlow Profiler:|r 开始采集")
end

function Profiler.stopSession(mode, limit)
    if not _active then
        if _hasSnapshot then
            Profiler.printReport(mode, limit)
        else
            print("|cff00ff00VFlow Profiler:|r 当前未在采集")
        end
        return
    end
    _lastDuration = math.max((GetTime() - _startTime), 0)
    _hasSnapshot = true
    deactivate()
    Profiler.printReport(mode, limit)
end

function Profiler.isActive()
    return _active
end

local function PrintCommonPreset(limit)
    local rows = limit or 20
    Profiler.printReport("self", rows)
    Profiler.printReport("roots", math.min(rows, 20))
    Profiler.printReport("edges", math.min(rows, 30))
end

local function PrintHelp()
    print("|cff00ff00VFlow Profiler:|r /vfprof start")
    print("|cff00ff00VFlow Profiler:|r /vfprof stop")
    print("|cff00ff00VFlow Profiler:|r /vfprof quick")
    print("|cff00ff00VFlow Profiler:|r /vfprof self|roots|edges|counts|all [limit]")
    print("|cff00ff00VFlow Profiler:|r /vfprof report [mode] [limit]")
    print("|cff00ff00VFlow Profiler:|r /vfprof reset")
end

-- =========================================================
-- 斜杠命令
-- =========================================================

SLASH_VFPROF1 = "/vfprof"
SlashCmdList["VFPROF"] = function(msg)
    local raw = (msg or ""):trim()
    local cmd, arg1, arg2 = raw:match("^(%S+)%s*(%S*)%s*(%S*)$")
    cmd = (cmd or ""):lower()
    arg1 = (arg1 ~= "" and arg1) or nil
    arg2 = (arg2 ~= "" and arg2) or nil
    if cmd == "" or cmd == "help" then
        PrintHelp()
    elseif cmd == "start" or cmd == "on" or cmd == "s" then
        Profiler.startSession()
    elseif cmd == "stop" or cmd == "off" or cmd == "x" then
        if arg1 or arg2 then
            Profiler.stopSession(arg1, arg2)
        else
            Profiler.stopSession("self", 40)
        end
    elseif cmd == "quick" or cmd == "q" then
        if _active then
            Profiler.stopSession("self", 40)
            Profiler.printReport("roots", 20)
            Profiler.printReport("edges", 30)
        elseif _hasSnapshot then
            PrintCommonPreset(40)
        else
            Profiler.startSession()
        end
    elseif cmd == "self" or cmd == "roots" or cmd == "edges" or cmd == "counts"
        or cmd == "all" or cmd == "inclusive" or cmd == "total" then
        Profiler.printReport(cmd, arg1)
    elseif cmd == "report" or cmd == "r" then
        Profiler.printReport(arg1, arg2)
    elseif cmd == "reset" then
        Profiler.reset()
        print("|cff00ff00VFlow Profiler:|r 已重置")
    else
        PrintHelp()
    end
end

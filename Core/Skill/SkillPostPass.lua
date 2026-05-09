-- =========================================================
-- SECTION 1: 模块入口
-- SkillPostPass — 高亮、依赖布局、外部联动
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local Profiler = VFlow.Profiler

local SkillPostPass = {}
VFlow.SkillPostPass = SkillPostPass

local highlightCallbacks = {}
local dependentCallbacks = {}

function SkillPostPass.registerHighlight(owner, callback)
    if type(owner) ~= "string" or type(callback) ~= "function" then
        return
    end
    highlightCallbacks[owner] = callback
end

function SkillPostPass.registerDependent(owner, callback)
    if type(owner) ~= "string" or type(callback) ~= "function" then
        return
    end
    dependentCallbacks[owner] = callback
end

function SkillPostPass.RunHighlights(context)
    for _, callback in pairs(highlightCallbacks) do
        callback(context)
    end
end

function SkillPostPass.RunDependents(context)
    for _, callback in pairs(dependentCallbacks) do
        callback(context)
    end
end

if Profiler and Profiler.registerScope then
    Profiler.registerScope("SKP:PostPass", function()
        return SkillPostPass.RunDependents
    end, function(fn)
        SkillPostPass.RunDependents = fn
    end)
end

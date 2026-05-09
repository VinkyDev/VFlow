-- =========================================================
-- SECTION 1: 模块入口
-- ViewerRuntime — 统一 viewer 运行时注册、hook 装配与刷新请求
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local StyleLayout = VFlow.StyleLayout
local RefreshBus = VFlow.RefreshBus

local ViewerRuntime = {
    _descriptors = {},
    _setupDone = {},
}
VFlow.ViewerRuntime = ViewerRuntime

local function SafeHook(obj, method, handler)
    if obj and obj[method] then
        hooksecurefunc(obj, method, handler)
    end
end

local function getDescriptor(name)
    return name and ViewerRuntime._descriptors[name] or nil
end

local function resolveScopes(desc, trigger)
    if not desc then
        return nil
    end
    local requestMap = desc.requestMap
    if not requestMap then
        return desc.requestScopes
    end
    return requestMap[trigger] or desc.requestScopes
end

local function resolveViewerNames(desc, viewerName)
    if desc and desc.resolveViewerNames then
        return desc.resolveViewerNames(viewerName)
    end
    return { viewerName }
end

local function requestByDescriptor(desc, viewerName, trigger, opts)
    if not desc then
        return
    end

    local scopes = resolveScopes(desc, trigger)
    if not scopes then
        return
    end

    local viewerNames = resolveViewerNames(desc, viewerName)
    opts = opts or {}

    if desc.requestHandler then
        desc.requestHandler(scopes, viewerNames, opts, trigger)
        return
    end

    if not RefreshBus then
        return
    end
    RefreshBus.requestSkillViewers(scopes, viewerNames, opts)
end

function ViewerRuntime.register(desc)
    if not desc or type(desc.name) ~= "string" or desc.name == "" then
        return
    end
    ViewerRuntime._descriptors[desc.name] = desc
end

function ViewerRuntime.request(name, trigger, opts)
    local desc = getDescriptor(name)
    if not desc then
        return
    end
    requestByDescriptor(desc, name, trigger, opts)
end

local function setupShowHook(viewer, desc)
    if not (viewer and viewer.HookScript and desc.enableOnShow ~= false) then
        return
    end
    viewer:HookScript("OnShow", function()
        if desc.lockViewerScale and viewer.SetScale and viewer:GetScale() ~= 1 then
            viewer:SetScale(1)
        end
        if desc.onShow then
            desc.onShow(viewer, desc)
        end
        requestByDescriptor(desc, desc.name, "onShow")
    end)
end

local function setupRefreshHooks(viewer, desc)
    if not viewer then
        return
    end

    if desc.hookRefreshLayout ~= false then
        SafeHook(viewer, "RefreshLayout", function()
            if desc.onRefreshLayout then
                desc.onRefreshLayout(viewer, desc)
            end
            requestByDescriptor(desc, desc.name, "refreshLayout")
        end)
    end

    if desc.hookRefreshData then
        SafeHook(viewer, "RefreshData", function()
            if desc.onRefreshData then
                desc.onRefreshData(viewer, desc)
            end
            requestByDescriptor(desc, desc.name, "refreshData")
        end)
    end

    if desc.hookUpdateLayout then
        local method = viewer.UpdateLayout and "UpdateLayout" or (viewer.Layout and "Layout" or nil)
        if method then
            SafeHook(viewer, method, function()
                if desc.onUpdateLayout then
                    desc.onUpdateLayout(viewer, desc)
                end
                requestByDescriptor(desc, desc.name, "updateLayout")
            end)
        end
    end
end

local function setupAcquireHook(viewer, desc)
    if not (viewer and viewer.OnAcquireItemFrame) then
        return
    end

    SafeHook(viewer, "OnAcquireItemFrame", function(_, frame)
        if not frame then
            return
        end

        if desc.invalidateCollectIcons ~= false then
            StyleLayout.InvalidateCollectIconsCache(viewer)
        end

        if desc.lockFrameScale and frame.SetScale and frame:GetScale() ~= 1 then
            frame:SetScale(1)
        end

        if desc.onAcquireFrame then
            desc.onAcquireFrame(viewer, frame, desc)
        end

        requestByDescriptor(desc, desc.name, "acquire")
    end)
end

local function setupPoolReleaseHook(viewer, desc)
    if not (desc.hookPoolRelease and viewer and viewer.itemFramePool and viewer.itemFramePool.Release) then
        return
    end

    hooksecurefunc(viewer.itemFramePool, "Release", function()
        if desc.invalidateCollectIcons ~= false then
            StyleLayout.InvalidateCollectIconsCache(viewer)
        end
        if desc.onPoolRelease then
            desc.onPoolRelease(viewer, desc)
        end
        requestByDescriptor(desc, desc.name, "poolRelease")
    end)
end

function ViewerRuntime.setup(name)
    if ViewerRuntime._setupDone[name] then
        return
    end

    local desc = getDescriptor(name)
    local viewer = desc and _G[name]
    if not (desc and viewer) then
        return
    end

    ViewerRuntime._setupDone[name] = true

    if desc.lockViewerScale and viewer.SetScale and viewer:GetScale() ~= 1 then
        viewer:SetScale(1)
    end
    if desc.onSetup then
        desc.onSetup(viewer, desc)
    end

    setupRefreshHooks(viewer, desc)
    setupShowHook(viewer, desc)
    setupAcquireHook(viewer, desc)
    setupPoolReleaseHook(viewer, desc)
end

function ViewerRuntime.setupAll()
    for name in pairs(ViewerRuntime._descriptors) do
        ViewerRuntime.setup(name)
    end
end

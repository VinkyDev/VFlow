-- =========================================================
-- VFlow CustomMonitor Runtime — Constants
-- 模块共享常量
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local ModuleControlConstants = VFlow.ModuleControlConstants
if not ModuleControlConstants.CUSTOM_ENABLED then return end

VFlow.CustomMonitor = VFlow.CustomMonitor or {}
VFlow.CustomMonitor.Runtime = VFlow.CustomMonitor.Runtime or {}

local Constants = {}
VFlow.CustomMonitor.Runtime.Constants = Constants

Constants.UPDATE_INTERVAL = 0.1
Constants.MAP_RETRY_INTERVAL = 1.5
Constants.BUFF_VIEWERS = {
    "BuffIconCooldownViewer",
    "BuffBarCooldownViewer",
    "EssentialCooldownViewer",
    "UtilityCooldownViewer",
}

Constants.INTERP_EASE_OUT = Enum.StatusBarInterpolation
    and Enum.StatusBarInterpolation.ExponentialEaseOut or 1

-- 环形纹理路径格式
Constants.RING_TEXTURE_FMT = "Interface\\AddOns\\VFlow\\Assets\\Ring\\Ring_%spx.tga"

-- =========================================================
-- VFlow UI Font - 字体解析、应用、回退逻辑
-- =========================================================

local VFlow = _G.VFlow
local UI = VFlow.UI
local L = VFlow.L
local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

--- 各客户端注册的「默认字体」显示名
local LSM_DEFAULT_FONT_DISPLAY_KEYS = {
    ["默认"] = true,
    ["預設"] = true,
}

local function LocalizeFontPickerDisplayName(name)
    if name and LSM_DEFAULT_FONT_DISPLAY_KEYS[name] then
        return L["Default"]
    end
    return name
end

local function ResolveFontSelection(value)
    if not value then
        return nil, nil
    end
    if not LSM then
        return value, value
    end
    local fonts = LSM:HashTable("font")
    local path = fonts[value]
    if path then
        return value, path
    end
    for name, fontPath in pairs(fonts) do
        if fontPath == value then
            return name, fontPath
        end
    end
    return value, value
end

local function ResolveFontPathOrValue(value)
    local _, path = ResolveFontSelection(value)
    if type(path) == "string" and path ~= "" then
        return path
    end
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function GetDefaultFontPath()
    if LSM then
        local fonts = LSM:HashTable("font")
        for name in pairs(LSM_DEFAULT_FONT_DISPLAY_KEYS) do
            local path = fonts[name]
            if type(path) == "string" and path ~= "" then
                return path
            end
        end
    end
    if ChatFontNormal and ChatFontNormal.GetFont then
        local path = ChatFontNormal:GetFont()
        if type(path) == "string" and path ~= "" then
            return path
        end
    end
    if type(STANDARD_TEXT_FONT) == "string" and STANDARD_TEXT_FONT ~= "" then
        return STANDARD_TEXT_FONT
    end
    return "Fonts\\FRIZQT__.TTF"
end

local function TrySetFont(fs, path, size, flags)
    if not fs or type(path) ~= "string" or path == "" then
        return false
    end
    local beforePath = fs.GetFont and fs:GetFont() or nil
    local ok, result = pcall(fs.SetFont, fs, path, size, flags or "")
    if not ok then
        return false
    end
    if result == true then
        return true
    end
    if result == false then
        return false
    end
    local afterPath = fs.GetFont and fs:GetFont() or nil
    if afterPath and afterPath == path then
        return true
    end
    if beforePath ~= afterPath and afterPath then
        return true
    end
    return false
end

local function ApplyFontWithFallback(fs, value, size, flags, fallbackPath)
    if not fs then
        return false
    end
    local candidates = {}
    local function push(path)
        if type(path) ~= "string" or path == "" then
            return
        end
        for i = 1, #candidates do
            if candidates[i] == path then
                return
            end
        end
        candidates[#candidates + 1] = path
    end
    push(ResolveFontPathOrValue(value))
    push(fallbackPath)
    push(GetDefaultFontPath())
    if fs.GetFont then
        push(fs:GetFont())
    end
    push(STANDARD_TEXT_FONT)
    push("Fonts\\FRIZQT__.TTF")
    for i = 1, #candidates do
        if TrySetFont(fs, candidates[i], size, flags) then
            return true
        end
    end
    return false
end

-- =========================================================
-- 公共 API
-- =========================================================

function UI.resolveFontSelection(value)
    return ResolveFontSelection(value)
end

function UI.resolveFontPath(value)
    return ResolveFontPathOrValue(value)
end

function UI.getDefaultFontPath()
    return GetDefaultFontPath()
end

function UI.applyFont(fs, value, size, flags, fallbackPath)
    return ApplyFontWithFallback(fs, value, size, flags, fallbackPath)
end

--- 供 UIPickers 使用的本地化显示名
function UI.localizeFontDisplay(name)
    return LocalizeFontPickerDisplayName(name)
end

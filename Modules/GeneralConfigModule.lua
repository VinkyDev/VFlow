--[[ Core 依赖：
  - Core/MainUI.lua：配置变更后刷新主界面与当前内容区
  例外：档案切换/导入导出等由本页按钮与下拉显式提交，不经业务模块式 registerModule 配置管线。
]]

-- =========================================================
-- SECTION 1: 模块注册
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L

local MODULE_KEY = "VFlow.GeneralConfig"
local EXPORT_PREFIX = "VFLOWCFG1:"
local DEFAULT_PROFILE = "default"

VFlow.registerModule(MODULE_KEY, {
    name = L["Config"],
    description = L["General settings - Config"],
})

-- =========================================================
-- SECTION 2: 依赖与页面状态
-- =========================================================

local LibSerialize = LibStub and LibStub("LibSerialize", true)
local LibDeflate = LibStub and LibStub("LibDeflate", true)
local trim = VFlow.Utils.trim

local pageState = {
    selectedProfile = DEFAULT_PROFILE,
    newProfileName = "",
    copySourceProfile = DEFAULT_PROFILE,
    moduleExportScope = "*",
    moduleImportScope = "*",
    exportText = "",
    importText = "",
}

-- =========================================================
-- SECTION 3: 配置导入/导出与档案操作
-- =========================================================

local function syncPageState()
    if not VFlow.Store then
        return
    end
    local current = VFlow.Store.getCurrentProfile()
    pageState.selectedProfile = current
    if not pageState.copySourceProfile or pageState.copySourceProfile == "" then
        pageState.copySourceProfile = current
    end
    if VFlow.SpecBinding then
        local numSpecs = GetNumSpecializations and GetNumSpecializations() or 0
        for i = 1, numSpecs do
            local bound = VFlow.SpecBinding.get(i)
            pageState["specBinding_" .. i] = bound or ""
        end
    end
end

local function getProfileDropdownItems()
    if not VFlow.Store or not VFlow.Store.listProfiles then
        return { { DEFAULT_PROFILE, DEFAULT_PROFILE } }
    end
    local items = {}
    for _, name in ipairs(VFlow.Store.listProfiles()) do
        table.insert(items, { name, name })
    end
    return items
end

local function getModuleDropdownItems()
    local items = { { L["All modules"], "*" } }
    if not VFlow.Store or not VFlow.Store.listModules then
        return items
    end
    for _, moduleKey in ipairs(VFlow.Store.listModules()) do
        table.insert(items, { moduleKey, moduleKey })
    end
    return items
end

local function normalizeSelection(value, items, fallback)
    for _, item in ipairs(items or {}) do
        if item[2] == value then
            return value
        end
    end
    return fallback
end

local function buildExportPayload(scope)
    local modules = {}
    if not VFlow.Store or not VFlow.Store.getModuleData then
        return nil, L["Store unavailable"]
    end
    if scope == "*" then
        for _, moduleKey in ipairs(VFlow.Store.listModules()) do
            local data = VFlow.Store.getModuleData(moduleKey)
            if type(data) == "table" then
                modules[moduleKey] = data
            end
        end
    else
        local data = VFlow.Store.getModuleData(scope)
        if type(data) == "table" then
            modules[scope] = data
        end
    end
    local hasModule = false
    for _ in pairs(modules) do
        hasModule = true
        break
    end
    if not hasModule then
        return nil, L["No exportable module data for current selection"]
    end
    return {
        magic = "VFLOWCFG",
        version = 1,
        profile = VFlow.Store.getCurrentProfile(),
        scope = scope,
        time = time(),
        modules = modules,
    }
end

local function encodePayload(payload)
    if not LibSerialize or not LibDeflate then
        return nil, L["LibSerialize or LibDeflate not loaded, import/export unavailable."]
    end
    local serialized = LibSerialize:Serialize(payload)
    if type(serialized) ~= "string" or serialized == "" then
        return nil, L["Serialization failed"]
    end
    local compressed = LibDeflate:CompressDeflate(serialized, { level = 9 })
    if type(compressed) ~= "string" then
        return nil, L["Compression failed"]
    end
    local encoded = LibDeflate:EncodeForPrint(compressed)
    if type(encoded) ~= "string" or encoded == "" then
        return nil, L["Encoding failed"]
    end
    return EXPORT_PREFIX .. encoded
end

local function decodePayload(text)
    if not LibSerialize or not LibDeflate then
        return nil, L["LibSerialize or LibDeflate not loaded, import/export unavailable."]
    end
    local raw = trim(text)
    if raw == "" then
        return nil, L["Import text is empty"]
    end
    if raw:sub(1, #EXPORT_PREFIX) == EXPORT_PREFIX then
        raw = raw:sub(#EXPORT_PREFIX + 1)
    end
    local compressed = LibDeflate:DecodeForPrint(raw)
    if not compressed then
        return nil, L["Decoding failed"]
    end
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then
        return nil, L["Decompression failed"]
    end
    local ok, payload = LibSerialize:Deserialize(serialized)
    if not ok or type(payload) ~= "table" then
        return nil, L["Deserialization failed"]
    end
    if payload.magic ~= "VFLOWCFG" or type(payload.modules) ~= "table" then
        return nil, L["Import data format invalid"]
    end
    return payload
end

local function applyImportPayload(payload, scope)
    if not VFlow.Store or not VFlow.Store.setModuleData then
        return false, 0, L["Store unavailable"]
    end
    local applied = 0
    if scope == "*" then
        for moduleKey, data in pairs(payload.modules) do
            if type(moduleKey) == "string" and type(data) == "table" then
                local ok = VFlow.Store.setModuleData(moduleKey, data)
                if ok then
                    applied = applied + 1
                end
            end
        end
    else
        local data = payload.modules[scope]
        if type(data) ~= "table" then
            return false, 0, L["Import pack does not contain target module"]
        end
        local ok = VFlow.Store.setModuleData(scope, data)
        if ok then
            applied = 1
        end
    end
    if applied == 0 then
        return false, 0, L["No module imported successfully"]
    end
    return true, applied
end

local function copySourceToCurrent(sourceProfile)
    if not VFlow.Store then
        return false, 0, L["Store unavailable"]
    end
    local source = trim(sourceProfile)
    if source == "" then
        return false, 0, L["Select source config"]
    end
    local current = VFlow.Store.getCurrentProfile()
    if source == current then
        return false, 0, L["Source same as current"]
    end
    local modules = VFlow.Store.listModules(source)
    local copied = 0
    for _, moduleKey in ipairs(modules) do
        local data = VFlow.Store.getModuleData(moduleKey, source)
        if type(data) == "table" then
            local ok = VFlow.Store.setModuleData(moduleKey, data, current)
            if ok then
                copied = copied + 1
            end
        end
    end
    if copied == 0 then
        return false, 0, L["Source has no data to copy"]
    end
    return true, copied
end

local function notifyAndRefresh(container, message)
    if message and message ~= "" then
        print("|cff00ff00VFlow:|r " .. message)
    end
    if VFlow.MainUI and VFlow.MainUI.refresh then
        VFlow.MainUI.refresh()
    elseif VFlow.Grid and VFlow.Grid.refresh then
        VFlow.Grid.refresh(container)
    end
end

-- =========================================================
-- SECTION 4: 渲染
-- =========================================================

local function renderContent(container, _menuKey)
    syncPageState()
    local currentProfile = VFlow.Store and VFlow.Store.getCurrentProfile and VFlow.Store.getCurrentProfile() or
        DEFAULT_PROFILE
    local profileItems = getProfileDropdownItems()
    local moduleItems = getModuleDropdownItems()
    pageState.selectedProfile = normalizeSelection(pageState.selectedProfile, profileItems, currentProfile)
    pageState.copySourceProfile = normalizeSelection(pageState.copySourceProfile, profileItems, currentProfile)
    pageState.moduleExportScope = normalizeSelection(pageState.moduleExportScope, moduleItems, "*")
    pageState.moduleImportScope = normalizeSelection(pageState.moduleImportScope, moduleItems, "*")

    local layout = {
        { type = "title", text = L["Config Management"], cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "dropdown",
            key = "selectedProfile",
            label = L["Select config"],
            cols = 12,
            items = profileItems,
            labelOnLeft = true,
            onChange = function(cfg, selected)
                local ok, err = VFlow.Store.setCurrentProfile(selected)
                if not ok then
                    cfg.selectedProfile = VFlow.Store.getCurrentProfile()
                    print("|cffff0000VFlow:|r " .. string.format(L["Switch config failed: %s"], tostring(err)))
                    notifyAndRefresh(container)
                    return
                end
                pageState.selectedProfile = selected
                pageState.copySourceProfile = selected
                notifyAndRefresh(container, string.format(L["Switched to config: %s"], selected))
            end
        },
        {
            type = "button",
            text = L["Delete Current"],
            cols = 12,
            onClick = function()
                local current = VFlow.Store.getCurrentProfile()
                if current == DEFAULT_PROFILE then
                    print("|cffff8800VFlow:|r " .. L["Default config cannot be deleted"])
                    return
                end
                VFlow.UI.dialog(UIParent, L["Delete"], string.format(L["Confirm delete config %s?"], current), function()
                    local ok, err = VFlow.Store.deleteProfile(current)
                    if not ok then
                        print("|cffff0000VFlow:|r " .. string.format(L["Delete config failed: %s"], tostring(err)))
                        return
                    end
                    pageState.selectedProfile = VFlow.Store.getCurrentProfile()
                    pageState.copySourceProfile = pageState.selectedProfile
                    notifyAndRefresh(container, string.format(L["Deleted config: %s"], current))
                end, nil, { destructive = true })
            end
        },
        { type = "input", key = "newProfileName", label = L["New config name"], cols = 12, labelOnLeft = true },
        {
            type = "button",
            text = L["Create config"],
            cols = 12,
            onClick = function(cfg)
                local name = trim(cfg.newProfileName)
                local ok, err = VFlow.Store.createProfile(name)
                if not ok then
                    print("|cffff0000VFlow:|r " .. string.format(L["Create config failed: %s"], tostring(err)))
                    return
                end
                local switched, switchErr = VFlow.Store.setCurrentProfile(name)
                if not switched then
                    print("|cffff0000VFlow:|r " .. string.format(L["Switch config failed: %s"], tostring(switchErr)))
                    return
                end
                cfg.newProfileName = ""
                pageState.selectedProfile = name
                pageState.copySourceProfile = name
                notifyAndRefresh(container, string.format(L["Created config: %s"], name))
            end
        },
        { type = "dropdown", key = "copySourceProfile", label = L["Copy from"], cols = 12, items = profileItems, labelOnLeft = true },
        {
            type = "button",
            text = L["Copy config"],
            cols = 12,
            onClick = function(cfg)
                local ok, copied, err = copySourceToCurrent(cfg.copySourceProfile)
                if not ok then
                    print("|cffff0000VFlow:|r " .. string.format(L["Copy config failed: %s"], tostring(err)))
                    return
                end
                notifyAndRefresh(container, string.format(L["Config synced to current, module count: %s"], tostring(copied)))
            end
        },
        { type = "separator", cols = 24 },
        { type = "subtitle", text = L["Export"], cols = 24 },
        { type = "dropdown", key = "moduleExportScope", label = L["Export scope"], cols = 12, items = moduleItems, labelOnLeft = true },
        {
            type = "button",
            text = L["Generate export string"],
            cols = 12,
            onClick = function(cfg)
                local payload, payloadErr = buildExportPayload(cfg.moduleExportScope)
                if not payload then
                    print("|cffff0000VFlow:|r " .. tostring(payloadErr))
                    return
                end
                local encoded, encodeErr = encodePayload(payload)
                if not encoded then
                    print("|cffff0000VFlow:|r " .. tostring(encodeErr))
                    return
                end
                cfg.exportText = encoded
                print("|cff00ff00VFlow:|r " .. L["Export string generated"])
                if VFlow.Grid and VFlow.Grid.refresh then
                    VFlow.Grid.refresh(container)
                end
            end
        },
        { type = "input", key = "exportText", label = L["Export string"], cols = 24 },
        { type = "separator", cols = 24 },
        { type = "subtitle", text = L["Import"], cols = 24 },
        { type = "dropdown", key = "moduleImportScope", label = L["Import scope"], cols = 12, items = moduleItems, labelOnLeft = true },
        {
            type = "button",
            text = L["Execute import"],
            cols = 12,
            onClick = function(cfg)
                local payload, decodeErr = decodePayload(cfg.importText)
                if not payload then
                    print("|cffff0000VFlow:|r " .. tostring(decodeErr))
                    return
                end
                local ok, count, applyErr = applyImportPayload(payload, cfg.moduleImportScope)
                if not ok then
                    print("|cffff0000VFlow:|r " .. tostring(applyErr))
                    return
                end
                notifyAndRefresh(container, string.format(L["Import complete, modules updated: %s"], tostring(count)))
            end
        },
        { type = "input", key = "importText", label = L["Import string"], cols = 24 },
    }

    if not LibSerialize or not LibDeflate then
        table.insert(layout, {
            type = "description",
            text = L["LibSerialize or LibDeflate not loaded, import/export unavailable."],
            cols = 24
        })
    end

    -- 专精绑定区块
    if VFlow.SpecBinding then
        table.insert(layout, { type = "separator", cols = 24 })
        table.insert(layout, { type = "subtitle", text = L["Spec Binding"], cols = 24 })
        local specProfileItems = { { L["Not bound"], "" } }
        for _, name in ipairs(VFlow.Store.listProfiles()) do
            table.insert(specProfileItems, { name, name })
        end
        local numSpecs = GetNumSpecializations and GetNumSpecializations() or 0
        for i = 1, numSpecs do
            local _, specName = GetSpecializationInfo(i)
            local specIndex = i
            table.insert(layout, {
                type = "dropdown",
                key = "specBinding_" .. specIndex,
                label = specName or ("专精 " .. specIndex),
                cols = 24,
                labelOnLeft = true,
                items = specProfileItems,
                onChange = function(cfg, value)
                    local profileName = (value ~= "") and value or nil
                    VFlow.SpecBinding.set(specIndex, profileName)
                end,
            })
        end
    end

    table.insert(layout, {
        type = "description",
        text = L["Some settings require /reload to take effect"],
        cols = 24
    })

    if VFlow.Grid and VFlow.Grid.render then
        VFlow.Grid.render(container, layout, pageState, nil)
    end
end

-- =========================================================
-- SECTION 5: 公共接口
-- =========================================================

if not VFlow.Modules then
    VFlow.Modules = {}
end

VFlow.Modules.GeneralConfig = {
    renderContent = renderContent,
}

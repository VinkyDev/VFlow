local VFlow = _G.VFlow
if not VFlow then return end

local MODULE_KEY = "VFlow.GeneralConfig"
local EXPORT_PREFIX = "VFLOWCFG1:"
local DEFAULT_PROFILE = "default"

VFlow.registerModule(MODULE_KEY, {
    name = "配置",
    description = "通用设置-配置",
})

local LibSerialize = LibStub and LibStub("LibSerialize", true)
local LibDeflate = LibStub and LibStub("LibDeflate", true)

local pageState = {
    selectedProfile = DEFAULT_PROFILE,
    newProfileName = "",
    copySourceProfile = DEFAULT_PROFILE,
    moduleExportScope = "*",
    moduleImportScope = "*",
    exportText = "",
    importText = "",
}

local function trim(value)
    if type(value) ~= "string" then
        return ""
    end
    return (value:gsub("^%s*(.-)%s*$", "%1"))
end

local function syncPageState()
    if not VFlow.Store then
        return
    end
    local current = VFlow.Store.getCurrentProfile()
    pageState.selectedProfile = current
    if not pageState.copySourceProfile or pageState.copySourceProfile == "" then
        pageState.copySourceProfile = current
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
    local items = { { "全部模块", "*" } }
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
        return nil, "Store不可用"
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
        return nil, "当前选择没有可导出的模块数据"
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
        return nil, "LibSerialize/LibDeflate 未加载"
    end
    local serialized = LibSerialize:Serialize(payload)
    if type(serialized) ~= "string" or serialized == "" then
        return nil, "序列化失败"
    end
    local compressed = LibDeflate:CompressDeflate(serialized, { level = 9 })
    if type(compressed) ~= "string" then
        return nil, "压缩失败"
    end
    local encoded = LibDeflate:EncodeForPrint(compressed)
    if type(encoded) ~= "string" or encoded == "" then
        return nil, "编码失败"
    end
    return EXPORT_PREFIX .. encoded
end

local function decodePayload(text)
    if not LibSerialize or not LibDeflate then
        return nil, "LibSerialize/LibDeflate 未加载"
    end
    local raw = trim(text)
    if raw == "" then
        return nil, "导入文本为空"
    end
    if raw:sub(1, #EXPORT_PREFIX) == EXPORT_PREFIX then
        raw = raw:sub(#EXPORT_PREFIX + 1)
    end
    local compressed = LibDeflate:DecodeForPrint(raw)
    if not compressed then
        return nil, "解码失败"
    end
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then
        return nil, "解压失败"
    end
    local ok, payload = LibSerialize:Deserialize(serialized)
    if not ok or type(payload) ~= "table" then
        return nil, "反序列化失败"
    end
    if payload.magic ~= "VFLOWCFG" or type(payload.modules) ~= "table" then
        return nil, "导入数据格式无效"
    end
    return payload
end

local function applyImportPayload(payload, scope)
    if not VFlow.Store or not VFlow.Store.setModuleData then
        return false, 0, "Store不可用"
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
            return false, 0, "导入包不包含目标模块"
        end
        local ok = VFlow.Store.setModuleData(scope, data)
        if ok then
            applied = 1
        end
    end
    if applied == 0 then
        return false, 0, "没有成功导入任何模块"
    end
    return true, applied
end

local function copySourceToCurrent(sourceProfile)
    if not VFlow.Store then
        return false, 0, "Store不可用"
    end
    local source = trim(sourceProfile)
    if source == "" then
        return false, 0, "请选择来源配置"
    end
    local current = VFlow.Store.getCurrentProfile()
    if source == current then
        return false, 0, "来源配置与当前配置相同"
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
        return false, 0, "来源配置没有可复制数据"
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

local function renderContent(container, menuKey)
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
        { type = "title", text = "配置管理", cols = 24 },
        { type = "separator", cols = 24 },
        {
            type = "dropdown",
            key = "selectedProfile",
            label = "选择配置",
            cols = 12,
            items = profileItems,
            labelOnLeft = true,
            onChange = function(cfg, selected)
                local ok, err = VFlow.Store.setCurrentProfile(selected)
                if not ok then
                    cfg.selectedProfile = VFlow.Store.getCurrentProfile()
                    print("|cffff0000VFlow:|r 切换配置失败: " .. tostring(err))
                    notifyAndRefresh(container)
                    return
                end
                pageState.selectedProfile = selected
                pageState.copySourceProfile = selected
                notifyAndRefresh(container, "已切换到配置: " .. selected)
            end
        },
        {
            type = "button",
            text = "删除当前配置",
            cols = 12,
            onClick = function()
                local current = VFlow.Store.getCurrentProfile()
                if current == DEFAULT_PROFILE then
                    print("|cffff8800VFlow:|r 默认配置不可删除")
                    return
                end
                VFlow.UI.dialog(UIParent, "删除配置", "确认删除配置 " .. current .. " 吗？", function()
                    local ok, err = VFlow.Store.deleteProfile(current)
                    if not ok then
                        print("|cffff0000VFlow:|r 删除配置失败: " .. tostring(err))
                        return
                    end
                    pageState.selectedProfile = VFlow.Store.getCurrentProfile()
                    pageState.copySourceProfile = pageState.selectedProfile
                    notifyAndRefresh(container, "已删除配置: " .. current)
                end, nil, { destructive = true })
            end
        },
        { type = "input", key = "newProfileName", label = "新配置名", cols = 12, labelOnLeft = true },
        {
            type = "button",
            text = "新建配置",
            cols = 12,
            onClick = function(cfg)
                local name = trim(cfg.newProfileName)
                local ok, err = VFlow.Store.createProfile(name)
                if not ok then
                    print("|cffff0000VFlow:|r 新建配置失败: " .. tostring(err))
                    return
                end
                local switched, switchErr = VFlow.Store.setCurrentProfile(name)
                if not switched then
                    print("|cffff0000VFlow:|r 切换新配置失败: " .. tostring(switchErr))
                    return
                end
                cfg.newProfileName = ""
                pageState.selectedProfile = name
                pageState.copySourceProfile = name
                notifyAndRefresh(container, "已新建配置: " .. name)
            end
        },
        { type = "dropdown", key = "copySourceProfile", label = "复制来源", cols = 12, items = profileItems, labelOnLeft = true },
        {
            type = "button",
            text = "复制配置",
            cols = 12,
            onClick = function(cfg)
                local ok, copied, err = copySourceToCurrent(cfg.copySourceProfile)
                if not ok then
                    print("|cffff0000VFlow:|r 复制配置失败: " .. tostring(err))
                    return
                end
                notifyAndRefresh(container, "已将配置 " .. cfg.copySourceProfile .. " 同步到当前配置，模块数: " .. tostring(copied))
            end
        },
        { type = "separator", cols = 24 },
        { type = "subtitle", text = "导出", cols = 24 },
        { type = "dropdown", key = "moduleExportScope", label = "导出范围", cols = 12, items = moduleItems, labelOnLeft = true },
        {
            type = "button",
            text = "生成导出串",
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
                print("|cff00ff00VFlow:|r 导出串已生成")
                if VFlow.Grid and VFlow.Grid.refresh then
                    VFlow.Grid.refresh(container)
                end
            end
        },
        { type = "input", key = "exportText", label = "导出串", cols = 24 },
        { type = "separator", cols = 24 },
        { type = "subtitle", text = "导入", cols = 24 },
        { type = "dropdown", key = "moduleImportScope", label = "导入范围", cols = 12, items = moduleItems, labelOnLeft = true },
        {
            type = "button",
            text = "执行导入",
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
                notifyAndRefresh(container, "导入完成，已更新模块数: " .. tostring(count))
            end
        },
        { type = "input", key = "importText", label = "导入串", cols = 24 },
    }

    if not LibSerialize or not LibDeflate then
        table.insert(layout, {
            type = "description",
            text = "LibSerialize 或 LibDeflate 未加载，导入导出功能不可用。",
            cols = 24
        })
    end

    table.insert(layout, {
        type = "description",
        text = "部分配置需要 /reload 后才能生效",
        cols = 24
    })

    if VFlow.Grid and VFlow.Grid.render then
        VFlow.Grid.render(container, layout, pageState, nil)
    end
end

if not VFlow.Modules then VFlow.Modules = {} end
VFlow.Modules.GeneralConfig = {
    renderContent = renderContent,
}

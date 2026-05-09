-- =========================================================
-- SECTION 1: 模块入口
-- ResourceStyles — 资源样式默认值、阈值着色与运行时解析
-- =========================================================

local VFlow = _G.VFlow
if not VFlow then return end

local CR = VFlow.ClassResourceMap
local E_PT = _G.Enum and Enum.PowerType

local RS = {}

-- =========================================================
-- SECTION 2: 常量与缓存
-- =========================================================

local THRESHOLD_COLOR_KEYS = { "thresholdColor1", "thresholdColor2" }

local STYLE_KEY_TO_RUNTIME = E_PT and {
    MANA = E_PT.Mana,
    RAGE = E_PT.Rage,
    ENERGY = E_PT.Energy,
    FOCUS = E_PT.Focus,
    FURY = E_PT.Fury,
    RUNIC_POWER = E_PT.RunicPower,
    INSANITY = E_PT.Insanity,
    LUNAR_POWER = E_PT.LunarPower,
    MAELSTROM = E_PT.Maelstrom,
    COMBO_POINTS = E_PT.ComboPoints,
    RUNES = E_PT.Runes,
    SOUL_SHARDS = E_PT.SoulShards,
    HOLY_POWER = E_PT.HolyPower,
    CHI = E_PT.Chi,
    ARCANE_CHARGES = E_PT.ArcaneCharges,
    ESSENCE = E_PT.Essence,
} or {}

local POWER_TYPE_TO_STYLE_KEY = {}
for styleKey, runtimeResource in pairs(STYLE_KEY_TO_RUNTIME) do
    POWER_TYPE_TO_STYLE_KEY[runtimeResource] = styleKey
end

local cachedMaxPowerByType = {}
local thresholdColorCurveCache = {}
local resolvedStyleCacheByDb = setmetatable({}, { __mode = "k" })
local resolvedDefaultStyleCache = {}

RS.ALL_KEYS_ORDERED = {
    "MANA",
    "RAGE",
    "ENERGY",
    "FOCUS",
    "FURY",
    "RUNIC_POWER",
    "INSANITY",
    "LUNAR_POWER",
    "MAELSTROM",
    "COMBO_POINTS",
    "RUNES",
    "SOUL_SHARDS",
    "HOLY_POWER",
    "CHI",
    "ARCANE_CHARGES",
    "ESSENCE",
    "STAGGER",
    "ICICLES",
    "MAELSTROM_WEAPON",
    "SOUL_FRAGMENTS_VENGEANCE",
    "DEVOURER_SOUL",
    "TIP_OF_THE_SPEAR",
}

-- =========================================================
-- SECTION 3: 默认样式构建
-- =========================================================

local function copyColor(color, fallback)
    local src = color or fallback
    if not src then
        return nil
    end
    local base = fallback or src
    return {
        r = src.r ~= nil and src.r or base.r or 1,
        g = src.g ~= nil and src.g or base.g or 1,
        b = src.b ~= nil and src.b or base.b or 1,
        a = src.a ~= nil and src.a or base.a or 1,
    }
end

local function applyThresholdFields(out, src, overlay)
    if not src then
        return
    end
    if src.thresholdColorsEnabled ~= nil then
        out.thresholdColorsEnabled = src.thresholdColorsEnabled == true
    end
    if src.threshold1 ~= nil then
        out.threshold1 = tonumber(src.threshold1)
    end
    if src.threshold2 ~= nil then
        out.threshold2 = tonumber(src.threshold2)
    end
    for _, key in ipairs(THRESHOLD_COLOR_KEYS) do
        if src[key] then
            out[key] = copyColor(src[key], overlay and out[key] or nil)
        end
    end
end

local function cloneStyleEntry(entry)
    local out = {
        showText = entry.showText ~= false,
        showPercent = entry.showPercent == true,
        barColor = copyColor(entry.barColor, { r = 1, g = 1, b = 1, a = 1 }),
        rechargeColorCustom = entry.rechargeColorCustom == true,
    }
    if entry.rechargeBarColor then
        out.rechargeBarColor = copyColor(entry.rechargeBarColor)
    end
    if entry.overchargedBarColor then
        out.overchargedBarColor = copyColor(entry.overchargedBarColor)
    end
    applyThresholdFields(out, entry, false)
    return out
end

local function baseEntry(barColor, opts)
    opts = type(opts) == "table" and opts or {}
    local out = {
        showText = opts.showText ~= false,
        showPercent = opts.showPercent == true,
        barColor = copyColor(barColor, { r = 1, g = 1, b = 1, a = 1 }),
        rechargeColorCustom = opts.rechargeColorCustom == true,
    }
    if opts.rechargeBarColor then
        out.rechargeBarColor = copyColor(opts.rechargeBarColor)
    end
    if opts.overchargedBarColor then
        out.overchargedBarColor = copyColor(opts.overchargedBarColor)
    end
    applyThresholdFields(out, opts, false)
    return out
end

local DEFAULT_ENTRY_FALLBACK = baseEntry({ r = 0.72, g = 0.74, b = 0.82, a = 1 })

local DEFAULT_ENTRY = {
    MANA = baseEntry({ r = 0.31, g = 0.85, b = 1.00, a = 1 }, { showPercent = true }),
    RAGE = baseEntry({ r = 0.90, g = 0.29, b = 0.26, a = 1 }),
    ENERGY = baseEntry({ r = 0.98, g = 0.86, b = 0.33, a = 1 }),
    FOCUS = baseEntry({ r = 0.94, g = 0.66, b = 0.33, a = 1 }),
    FURY = baseEntry({ r = 0.73, g = 0.29, b = 0.94, a = 1 }),
    RUNIC_POWER = baseEntry({ r = 0.24, g = 0.79, b = 1.00, a = 1 }),
    INSANITY = baseEntry({ r = 0.68, g = 0.37, b = 0.92, a = 1 }),
    LUNAR_POWER = baseEntry({ r = 0.50, g = 0.66, b = 1.00, a = 1 }),
    MAELSTROM = baseEntry({ r = 0.18, g = 0.65, b = 1.00, a = 1 }),
    COMBO_POINTS = baseEntry({ r = 0.96, g = 0.79, b = 0.31, a = 1 }, {
        showText = false,
        overchargedBarColor = { r = 0.24, g = 0.60, b = 1.00, a = 1 },
    }),
    RUNES = baseEntry({ r = 0.57, g = 0.75, b = 0.96, a = 1 }, {
        showText = false,
        rechargeBarColor = { r = 0.25, g = 0.34, b = 0.46, a = 1 },
    }),
    SOUL_SHARDS = baseEntry({ r = 0.62, g = 0.43, b = 0.87, a = 1 }, {
        showText = false,
        rechargeBarColor = { r = 0.31, g = 0.20, b = 0.46, a = 1 },
    }),
    HOLY_POWER = baseEntry({ r = 0.93, g = 0.83, b = 0.50, a = 1 }, { showText = false }),
    CHI = baseEntry({ r = 0.33, g = 0.86, b = 0.77, a = 1 }, { showText = false }),
    ARCANE_CHARGES = baseEntry({ r = 0.78, g = 0.42, b = 0.98, a = 1 }, { showText = false }),
    ESSENCE = baseEntry({ r = 0.22, g = 0.77, b = 0.65, a = 1 }, {
        showText = false,
        rechargeBarColor = { r = 0.12, g = 0.41, b = 0.34, a = 1 },
    }),
    STAGGER = baseEntry({ r = 0.47, g = 0.84, b = 0.41, a = 1 }, {
        showPercent = true,
        thresholdColorsEnabled = true,
        threshold1 = 30,
        threshold2 = 60,
        thresholdColor1 = { r = 1.0, g = 0.82, b = 0.32, a = 1 },
        thresholdColor2 = { r = 0.96, g = 0.34, b = 0.34, a = 1 },
    }),
    ICICLES = baseEntry({ r = 0.98, g = 1.00, b = 1.00, a = 1 }, { showText = false }),
    MAELSTROM_WEAPON = baseEntry({ r = 0.18, g = 0.67, b = 0.96, a = 1 }, { showText = false }),
    SOUL_FRAGMENTS_VENGEANCE = baseEntry({ r = 0.50, g = 0.25, b = 0.70, a = 1 }, { showText = false }),
    DEVOURER_SOUL = baseEntry({ r = 0.38, g = 0.40, b = 0.90, a = 1 }, { showText = false }),
    TIP_OF_THE_SPEAR = baseEntry({ r = 0.62, g = 0.85, b = 0.32, a = 1 }, { showText = false }),
}

local function resolveEntryFlag(entry, key, defaultValue)
    if entry and entry[key] ~= nil then
        return entry[key] == true
    end
    return defaultValue == true
end

local function resolveEntryShowText(entry, defaults)
    if entry and entry.showText ~= nil then
        return entry.showText ~= false
    end
    return defaults.showText ~= false
end

local function buildResolvedStyle(defaults, entry)
    local out = {
        showText = resolveEntryShowText(entry, defaults),
        showPercent = resolveEntryFlag(entry, "showPercent", defaults.showPercent),
        barColor = copyColor(entry and entry.barColor or nil, defaults.barColor),
        rechargeColorCustom = resolveEntryFlag(entry, "rechargeColorCustom", defaults.rechargeColorCustom),
    }
    local rechargeBarColor = entry and entry.rechargeBarColor or defaults.rechargeBarColor
    if rechargeBarColor then
        out.rechargeBarColor = copyColor(rechargeBarColor)
    end
    local overchargedBarColor = entry and entry.overchargedBarColor or defaults.overchargedBarColor
    if overchargedBarColor then
        out.overchargedBarColor = copyColor(overchargedBarColor)
    end
    applyThresholdFields(out, defaults, false)
    applyThresholdFields(out, entry, true)
    return out
end

function RS.DefaultEntryForKey(key)
    return cloneStyleEntry(DEFAULT_ENTRY[key] or DEFAULT_ENTRY_FALLBACK)
end

function RS.BuildFullResourceStylesDefaults()
    local out = {}
    for _, key in ipairs(RS.ALL_KEYS_ORDERED) do
        out[key] = RS.DefaultEntryForKey(key)
    end
    return out
end

-- =========================================================
-- SECTION 4: 阈值着色
-- =========================================================

local function colorCurveApisReady()
    return UnitPowerPercent and C_CurveUtil and C_CurveUtil.CreateColorCurve and CreateColor
end

function RS.ResolveBarFillColor(style, cur, max, resourceKey)
    if not style or not style.thresholdColorsEnabled then
        return style and style.barColor or { r = 1, g = 1, b = 1, a = 1 }
    end
    if resourceKey == "SOUL_FRAGMENTS_VENGEANCE" then
        return style.barColor or { r = 1, g = 1, b = 1, a = 1 }
    end
    if cur == nil or max == nil then
        return style.barColor
    end
    if issecretvalue and (issecretvalue(cur) or issecretvalue(max)) then
        return style.barColor
    end
    local c = tonumber(cur)
    local m = tonumber(max)
    if not m or m <= 0 or not c then
        return style.barColor
    end
    local t1 = tonumber(style.threshold1)
    if not t1 or t1 <= 0 then
        return style.barColor
    end
    local metric = style.showPercent == true and ((c / m) * 100) or c
    local c1 = style.thresholdColor1 or style.barColor
    local t2 = tonumber(style.threshold2)
    if not t2 or t2 <= t1 then
        return metric <= t1 and style.barColor or c1
    end
    if metric <= t1 then
        return style.barColor
    end
    if metric <= t2 then
        return c1
    end
    return style.thresholdColor2 or c1
end

function RS.CacheMaxPowerForStyle(powerType)
    if type(powerType) ~= "number" then
        return
    end
    local max = UnitPowerMax("player", powerType)
    if max and max > 0 and (not issecretvalue or not issecretvalue(max)) then
        cachedMaxPowerByType[powerType] = max
    else
        cachedMaxPowerByType[powerType] = nil
    end
end

function RS.WipeThresholdColorCurveCache()
    wipe(thresholdColorCurveCache)
end

local function thresholdCurveHash(style, powerType)
    if not style or not style.thresholdColorsEnabled then
        return nil
    end
    local t1 = tonumber(style.threshold1)
    if not t1 or t1 <= 0 then
        return nil
    end
    local b = style.barColor or {}
    local c1 = style.thresholdColor1 or {}
    local c2 = style.thresholdColor2 or {}
    local parts = {
        string.format("bc:%.4f,%.4f,%.4f,%.4f", b.r or 0, b.g or 0, b.b or 0, b.a or 1),
        string.format("c1:%.4f,%.4f,%.4f,%.4f", c1.r or 0, c1.g or 0, c1.b or 0, c1.a or 1),
        string.format("c2:%.4f,%.4f,%.4f,%.4f", c2.r or 0, c2.g or 0, c2.b or 0, c2.a or 1),
        "t1:" .. tostring(t1),
        "t2:" .. tostring(tonumber(style.threshold2) or -999),
        style.showPercent == true and "pct" or "num",
        "pt:" .. tostring(powerType),
    }
    if style.showPercent ~= true then
        parts[#parts + 1] = "cmax:" .. tostring(cachedMaxPowerByType[powerType] or 0)
    end
    return table.concat(parts, "|")
end

local function thresholdUnitFraction(style, powerType, thresholdValue)
    if style.showPercent == true then
        return math.max(0, math.min(1, thresholdValue / 100))
    end
    local maxV = cachedMaxPowerByType[powerType]
    if not maxV or maxV <= 0 then
        return nil
    end
    return math.max(0, math.min(1, thresholdValue / maxV))
end

local function curvePoint(curve, x, c)
    curve:AddPoint(
        x,
        CreateColor(c.r or 1, c.g or 1, c.b or 1, c.a ~= nil and c.a or 1)
    )
end

local function buildThresholdColorCurveForStyle(style, powerType)
    if not colorCurveApisReady() then
        return nil
    end
    local t1o = tonumber(style.threshold1)
    if not t1o or t1o <= 0 then
        return nil
    end
    local t2o = tonumber(style.threshold2)
    local base = style.barColor or { r = 1, g = 1, b = 1, a = 1 }
    local col1 = style.thresholdColor1 or base
    local col2 = style.thresholdColor2 or col1
    local singleTier = (not t2o) or (t2o <= t1o)
    local curve = C_CurveUtil.CreateColorCurve()
    local EPS = 0.0001

    local function oneBreakpoint(p1)
        curvePoint(curve, 0, base)
        if p1 > EPS then
            curvePoint(curve, p1 - EPS, base)
        end
        curvePoint(curve, p1, col1)
        curvePoint(curve, 1, col1)
    end

    local function twoBreakpoints(p1, p2)
        curvePoint(curve, 0, base)
        if p1 > EPS then
            curvePoint(curve, p1 - EPS, base)
        end
        curvePoint(curve, p1, col1)
        curvePoint(curve, math.max(p1, p2 - EPS), col1)
        curvePoint(curve, p2, col2)
        curvePoint(curve, 1, col2)
    end

    if singleTier then
        local p1 = thresholdUnitFraction(style, powerType, t1o)
        if not p1 then
            return nil
        end
        oneBreakpoint(p1)
        return curve
    end

    local p1 = thresholdUnitFraction(style, powerType, t1o)
    local p2 = thresholdUnitFraction(style, powerType, t2o)
    if not p1 or not p2 then
        return nil
    end
    if p2 <= p1 then
        oneBreakpoint(p1)
    else
        twoBreakpoints(p1, p2)
    end
    return curve
end

function RS.GetOrCreateThresholdColorCurve(style, powerType)
    RS.CacheMaxPowerForStyle(powerType)
    local hash = thresholdCurveHash(style, powerType)
    if not hash then
        return nil
    end
    local curve = thresholdColorCurveCache[hash]
    if curve then
        return curve
    end
    curve = buildThresholdColorCurveForStyle(style, powerType)
    if curve then
        thresholdColorCurveCache[hash] = curve
    end
    return curve
end

function RS.TryResolveBarFillFromPowerPercent(resource, style)
    if type(resource) ~= "number" or not style or style.thresholdColorsEnabled ~= true then
        return nil
    end
    if not colorCurveApisReady() then
        return nil
    end
    local curve = RS.GetOrCreateThresholdColorCurve(style, resource)
    if not curve then
        return nil
    end
    local ok, colorResult = pcall(function()
        return UnitPowerPercent("player", resource, false, curve)
    end)
    if not ok or not colorResult or not colorResult.GetRGBA then
        return nil
    end
    local r, g, b, a = colorResult:GetRGBA()
    return { r = r or 1, g = g or 1, b = b or 1, a = a ~= nil and a or 1 }
end

-- =========================================================
-- SECTION 5: 充能着色
-- =========================================================

function RS.ResolveRechargeColorForBase(style, baseColor)
    local bc = baseColor or style.barColor
    return RS.ResolveRechargeBarColor({
        rechargeColorCustom = style.rechargeColorCustom,
        rechargeBarColor = style.rechargeBarColor,
    }, bc)
end

function RS.DimBarColor(c, factor)
    factor = factor or 0.5
    if not c then
        return { r = 0.5, g = 0.5, b = 0.5, a = 1 }
    end
    return {
        r = (c.r or 1) * factor,
        g = (c.g or 1) * factor,
        b = (c.b or 1) * factor,
        a = c.a ~= nil and c.a or 1,
    }
end

function RS.RuntimeUsesEssenceRechargeTicker(resource)
    return type(resource) == "number" and E_PT and resource == E_PT.Essence
end

function RS.StyleKeyHasRechargeColorOption(styleKey)
    return styleKey == "ESSENCE" or styleKey == "RUNES" or styleKey == "SOUL_SHARDS"
end

function RS.StyleKeyHasOverchargedColorOption(styleKey)
    return styleKey == "COMBO_POINTS"
end

function RS.ResolveRechargeBarColor(entry, barColor)
    local custom = entry and entry.rechargeColorCustom == true
    local rc = entry and entry.rechargeBarColor
    if custom and rc and type(rc) == "table" then
        return {
            r = rc.r or 0,
            g = rc.g or 0,
            b = rc.b or 0,
            a = rc.a ~= nil and rc.a or 1,
        }
    end
    return RS.DimBarColor(barColor, 0.5)
end

function RS.ResolveOverchargedComboPointColor(style, baseColor)
    return copyColor(style and style.overchargedBarColor, baseColor or (style and style.barColor) or nil)
end

-- =========================================================
-- SECTION 6: 资源映射与样式解析
-- =========================================================

function RS.RuntimeResourceToStyleKey(resource)
    if type(resource) == "string" then
        return resource
    end
    if type(resource) == "number" then
        return POWER_TYPE_TO_STYLE_KEY[resource] or "MANA"
    end
    return "MANA"
end

function RS.StyleKeyToRuntimeResource(styleKey)
    if type(styleKey) ~= "string" then
        return styleKey
    end
    return STYLE_KEY_TO_RUNTIME[styleKey] or styleKey
end

function RS.GetDisplayKeyOrderForPlayer()
    local _, classFile = UnitClass("player")
    local classFirst, seen = CR.CollectUniqueResourceTokensForClass(classFile)
    local out = {}
    for _, key in ipairs(classFirst) do
        out[#out + 1] = key
    end
    for _, key in ipairs(RS.ALL_KEYS_ORDERED) do
        if not seen[key] then
            out[#out + 1] = key
        end
    end
    return out
end

local function getResolvedStyleCache(db)
    local cache = resolvedStyleCacheByDb[db]
    if cache then
        return cache
    end
    cache = {}
    resolvedStyleCacheByDb[db] = cache
    return cache
end

function RS.WipeResolvedStyleCache(db)
    if db then
        resolvedStyleCacheByDb[db] = nil
        return
    end
    resolvedStyleCacheByDb = setmetatable({}, { __mode = "k" })
    wipe(resolvedDefaultStyleCache)
end

function RS.WipeRuntimeCaches(db)
    RS.WipeThresholdColorCurveCache()
    RS.WipeResolvedStyleCache(db)
    wipe(cachedMaxPowerByType)
end

function RS.ResolveStyle(db, resource)
    local key = RS.RuntimeResourceToStyleKey(resource)
    local defaults = DEFAULT_ENTRY[key] or DEFAULT_ENTRY_FALLBACK
    if not db then
        local cached = resolvedDefaultStyleCache[key]
        if cached then
            return cached
        end
        cached = buildResolvedStyle(defaults, nil)
        resolvedDefaultStyleCache[key] = cached
        return cached
    end
    local cache = getResolvedStyleCache(db)
    local cached = cache[key]
    if cached then
        return cached
    end
    local entry = db.resourceStyles and db.resourceStyles[key] or nil
    cached = buildResolvedStyle(defaults, entry)
    cache[key] = cached
    return cached
end

VFlow.ResourceStyles = RS

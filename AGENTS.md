# VFlow

魔兽世界 12.0+ 插件，扩展暴雪 CooldownViewer，提供自定义技能/BUFF/物品/资源监控。

## 1. 架构总览

```
Libs → Infra → Core → Modules（严格按 index.xml 顺序加载）

Infra/   基建：Core(事件/模块)、State、Store、Pool、UI、Grid、PixelPerfect、
         BarFrameKit、ContainerAnchor、DragFrame、Utils、ModuleControlConstants
Core/    业务核心：
  Runtime/ Watchers/SpellStateWatcher、Refresh/{ViewerRefreshQueue,RefreshBus}、Viewer/ViewerRuntime
  Style/   StyleApply、StyleLayout、MasqueSupport、
           CustomHighlight（自定义高亮）、ViewerHooks（Blizzard hook 注册）、
           CooldownStyle（主入口：版本号/初始化/Store.watch）
  Skill/   SkillScanner → SkillViewModel → {Layout,GroupLayout,Style,Post}Pass、
           SkillGroups、SkillRefreshOrchestrator（RefreshBus SCOPE 编排）
  Buff/    BuffScanner、BuffGroups、ItemBuffMonitor、
           BuffRuntime（图标视图刷新）、BuffBarRuntime（条形视图刷新）
  Item/    ItemAutoData、ItemsManualOrder、ItemGroups
  CustomMonitor/ CustomMonitorGroups、CustomMonitorRuntime（生命周期/事件主入口）
    Runtime/ Constants/State/Visibility/Fonts、
             CdmRegistry（spellID↔cooldownID 映射）、AuraTracker（aura/CDM Hook）、
             Segments（StatusBar 分段）、BarFrame（创建条形帧）、
             Renderers/{Cooldown,Duration,Stack}（三种渲染模式）
  Resource/ ClassResourceMap、ResourceStyles、ResourceBars、WhirlwindTracker
  其余：MainUI、EditModeBridge、Keybind、Minimap、VisibilityControl、SpecBinding、CustomTTS
Modules/ 12 个 UI 设置页（GeneralHome/Config、Style/{Icon,Glow,Display}、
         Skills、Buffs、BuffBar、CustomMonitor、Items、SharedSettings、Resources）
Locales/ AceLocale-3.0：enUS(默认/fallback)、zhCN、zhTW
```

## 2. 关键模式

### 2.1 数据流（单向）

```
用户 UI 操作（Grid 控件）
  ↓ Grid 内部 onValueChanged
Store.set(moduleKey, "嵌套.路径", value)  -- 写代理表 + 通知
  ↓ Store.notifyChange
┌─ Grid Store.watch（dependsOn 命中 → Grid.refresh，增量）
└─ Core 模块 Store.watch（失效缓存 + RefreshBus.request，不直接渲染）
       ↓
RefreshBus（同帧合并 pending）→ ViewerRefreshQueue（OnUpdate flush）
       ↓ 按 SCOPE_ORDER 派发 11 个 SCOPE
Skill 流水线：ViewModel → LayoutPass → GroupLayoutPass → StylePass → PostPass(高亮/依赖)
       ↓
StyleApply.ApplyButtonStyleIfStale（按 _buttonStyleVersion + cfg fingerprint 幂等跳过）
```

**核心约束**：Modules 只声明布局；Core 监听 Store 并调用 RefreshBus；Pass 不写 Store。

### 2.2 Store 与 State

- **Store**（持久化，按档案 profile 隔离）：`Store.set(moduleKey, key, value)` 支持嵌套路径 `"customGroups.0.config.x"`；`Store.watch(moduleKey, owner, cb)` cb 签名 `(key, value)`。
- **State**（运行时，非持久化）：`State.update / State.watch / State.get`；预定义键：`inCombat / specID / playerClass / hasTarget / isMounted / isSkyriding / inVehicle / inPetBattle / isEditMode`。
- **跨模块只读**：`VFlow.getDBIfReady(moduleKey)`（未 init 时返回 nil，不抛错）；自身 DB 用 `VFlow.getDB(MODULE_KEY, defaults)`。
- **模块控制**：`VFlow.ModuleControlConstants.CORE_ENABLED` / `MODULE_RUNTIME_ENABLED[key]`，模块文件顶部 early-return 用。

### 2.3 Grid 声明式 UI（Infra/Grid.lua）

24 列栅格，支持的 type：
- 原子：`title / subtitle / description / button / checkbox / slider / input / dropdown / separator / spacer / colorPicker / fontPicker / texturePicker / iconButton / interactiveText / customRender / cooldownBar / iconGroup`
- 控制流：`if`、`for`（必带 `dependsOn`，否则任意键变更都会全量刷新）

```lua
Grid.render(container, layout, config, moduleKey, configPath?)
-- 标准控件带 key 时：Grid 内 onValueChanged 自动 Store.set
-- item.onChange 仅做副作用（提示等），勿对同一 key 再 Store.set
-- 改表类交互（iconButton/for 模板/button）需在回调里显式 Store.set(嵌套路径, …)
```

`dependsOn` 取 string 或 string[]；列表类自定义组扫描后用 `Utils.bumpCustomGroupsDataVersion(moduleKey, customGroups)` 写 `_dataVersion` 触发重绘。

### 2.4 ViewerRuntime / RefreshBus / Pass

- `ViewerRuntime` 收口对 Blizzard CooldownViewer 的 hooks（RefreshLayout/RefreshData/UpdateLayout/OnAcquireItemFrame），按 descriptor 的 `requestMap[trigger]` 转 RefreshBus。
- `RefreshBus` 11 个 SCOPE，固定顺序：`SKILL_GROUP_MAP → SKILL_DATA → SKILL_LAYOUT → SKILL_GROUP_LAYOUT → SKILL_STYLE → SKILL_COOLDOWN → HIGHLIGHT → DEPENDENT_LAYOUT`（+ Buff/BuffBar 域）；最多 8 个 cycle 防重入。
- Skill Pass：`SkillViewModel.BuildViewModel` 一次产物供 Layout/GroupLayout/Style/Post 复用。
- Style 入口：`StyleApply.ApplyButtonStyleIfStale(button, cfg)`，单帧幂等。

## 3. 开发规范

### 3.1 模块文件结构

```lua
--[[ Core 依赖：
  - Core/XXX/YYY.lua：职责说明
  例外：本模块在 X 处使用 Store.watch / 直接落盘，原因…
]]

-- SECTION 1: 模块注册
local VFlow = _G.VFlow
if not VFlow then return end
local L = VFlow.L
local MODULE_KEY = "VFlow.NewModule"
if not VFlow.ModuleControlConstants.CORE_ENABLED then return end
VFlow.registerModule(MODULE_KEY, { name = L["..."], description = L["..."] })

-- SECTION 2..N: 常量 / 默认 / 数据源 / 布局 / 渲染 / 公共接口
local defaults = { enabled = true, opt = 50 }
local db = VFlow.getDB(MODULE_KEY, defaults)

local function renderContent(container)
    Grid.render(container, layout, db, MODULE_KEY)
end

VFlow.Modules = VFlow.Modules or {}
VFlow.Modules.NewModule = { renderContent = renderContent }
```

- **Core 依赖注释**：每个 `Modules/*.lua` 顶部必带，列出消费的 `Core/*.lua`；使用 Store.watch/State.watch 等架构例外，用一行 `例外：…` 写明。Infra 层不写。
- **SECTION 分段**：与同目录其他模块对齐（注册→常量→默认→数据源→布局→渲染→接口）。
- **工具复用**：优先用 `VFlow.Utils`：`mergeLayouts`、`sortByName/sortByLayoutIndex`、`placeholderSpellEntry`、`trim`、`applyDefaults`、`bumpCustomGroupsDataVersion`、`setCooldownFromStartAndDuration`、`ResolveSyncedBarSpan`。

### 3.2 嵌套配置（自定义组）

```lua
if options.isCustom then
    local configPath = "customGroups." .. options.groupIndex .. ".config"
    Grid.render(container, layout, groupConfig, MODULE_KEY, configPath)
end
```

### 3.3 条件 / 循环渲染

```lua
{ type = "if", dependsOn = "dynamicLayout",
  condition = function(cfg) return cfg.dynamicLayout end, children = {...} }

{ type = "for", cols = 2, dependsOn = "spellIDs",
  dataSource = function() return getBuffList() end,
  template = { type = "iconButton",
    icon = function(d) return d.icon end,
    onClick = function(d)
        VFlow.Store.set(MODULE_KEY, configPath..".spellIDs", newValue)
    end } }
```

### 3.4 Core 监听 Store

```lua
VFlow.Store.watch(MODULE_KEY, "MyComponent", function(key, value)
    if key:find("%.x$") or key:find("%.y$") then return end  -- 位置忽略
    -- 失效缓存 + RefreshBus.request*，勿在此直接渲染
end)
```

## 4. 大文件警示（>500 行，重构高发区）

| 文件 | 估行 | 备注 |
|---|---|---|
| Core/Resource/ResourceBars.lua | ~1700 | 主/次资源条运行时 |
| Core/MainUI.lua | ~1700 | 设置主窗体 |
| Infra/UI.lua | ~1700 | 全部原子组件 |
| Core/Item/ItemGroups.lua | ~1500 | standalone+append 双布局 |
| Core/Style/StyleApply.lua | ~1500 | 按钮样式总入口 |
| Infra/DragFrame.lua | ~940 | 编辑模式+重叠环+提示 |
| Infra/Grid.lua | ~830 | 引擎+绑定+反应+小部件 |
| Core/CustomMonitor/CustomMonitorRuntime.lua | ~600 | 生命周期+事件（已按 Runtime/* 拆分） |
| Core/Buff/BuffBarRuntime.lua | ~600 | 条形 BUFF 单帧样式较重 |
| Modules/CustomMonitor/Buffs/Items | 30–40KB | layout 与对话框堆积 |

## 5. 关键原则速查

- **声明式 UI**：Modules 只声明 layout；副作用通过 Store.set 触发。
- **事件驱动**：变更 → Store.watch → RefreshBus → Pass，禁止手工调用刷新链。
- **增量更新**：Grid 用 `dependsOn`；Pass 用 `dirtySkillViewers/dirtyViewers`。
- **职责分离**：Modules=UI，Core=业务，Infra=基建。
- **嵌套路径**：`Store.set` 嵌套写入 → 精准通知。
- **帧复用**：所有可复用帧走 `Pool`。
- **幂等应用**：`ApplyButtonStyleIfStale` 按 version+fingerprint 跳过。
- **跨模块只读**：用 `getDBIfReady`，绝不主动 `getDB(other, defaults)`。
- **像素对齐**：尺寸/边距通过 `PixelPerfect` 处理。

# VFlow

## 1. 项目概述

魔兽世界 12.0+ 插件，增强暴雪内置冷却管理器，提供自定义技能/BUFF监控。

## 2. 架构

```
VFlow (全局命名空间)
├── Infra/          基建层（Core → State → Store → Pool → UI → Grid）
├── Core/           业务核心（StyleApply → StyleLayout → BuffRuntime → CooldownStyle → BuffGroups → MainUI）
├── Modules/        功能模块（SkillsModule → BuffsModule）
└── Libs/           第三方库
```

**加载顺序**：Libs → Infra → Core → Modules（严格按依赖顺序）

## 3. 核心模式

### 3.1 事件驱动架构

**配置存储（Store.lua）**：

```lua
Store.set(moduleKey, key, value)  -- 支持嵌套路径："customGroups.0.config.x"
Store.watch(moduleKey, owner, callback)  -- callback(key, value)
```

**运行时状态（State.lua）**：

```lua
VFlow.State.update(stateKey, value)
VFlow.State.watch(stateKey, owner, callback)
```

### 3.2 声明式布局（Grid.lua）

24列栅格系统，支持条件渲染和循环渲染：

```lua
Grid.render(container, layout, config, moduleKey, configPath)

-- 布局项类型
{ type = "slider", key = "width", label = "宽度", min = 20, max = 80, cols = 12 }
{ type = "checkbox", key = "enabled", label = "启用", cols = 12 }
{ type = "if", dependsOn = "enabled", condition = fn, children = {...} }
{ type = "for", dependsOn = "spellIDs", dataSource = fn, template = {...} }
Grid.fontGroup("stackFont", "堆叠文字")  -- 展开为多个布局项
```

**configPath参数**：用于嵌套配置，如`"customGroups.0.config"`

### 3.3 增量更新机制

**dependsOn机制**：

- `type = "if"`和`type = "for"`支持`dependsOn`字段
- 当依赖字段变化时，Grid自动增量刷新
- 普通组件（slider、checkbox）变化不触发刷新

**工作原理**：

```lua
// Grid.render时自动注册Store.watch
Store.watch(moduleKey, "Grid_" .. container, function(key, value)
    if shouldRefreshForChange(cache, key) then
        Grid.refresh(parent)  -- 只刷新匹配dependsOn的组件
    end
end)
```

## 4. 数据流

### 4.1 配置变更流程

```
用户操作（slider/checkbox/点击图标）
  ↓
Grid.onValueChanged / onClick回调
  ↓
Store.set(moduleKey, fullKey, value)  -- 使用嵌套路径
  ↓
Store.notifyChange(fullKey, value)
  ↓
┌─────────────────────────────────────┐
│ Grid的Store.watch（增量刷新）        │
│   └─ shouldRefreshForChange         │
│       └─ 匹配dependsOn → 刷新       │
│       └─ 不匹配 → 不刷新             │
│                                      │
│ BuffGroups的Store.watch             │
│   └─ RebuildSpellMap / 更新容器位置 │
│                                      │
│ CooldownStyle的Store.watch          │
│   └─ RequestRefresh → 实际效果更新  │
└─────────────────────────────────────┘
```

### 4.2 关键原则

- **Modules层不监听Store**：所有UI刷新由Grid的dependsOn机制处理
- **Core层监听Store**：响应配置变化，更新实际效果
- **增量更新**：只刷新变化的组件，不全量刷新
- **事件驱动**：不手动调用刷新API，通过Store.set触发事件

## 5. 开发规范

### 5.1 新增模块模板

```lua
local VFlow = _G.VFlow
local MODULE_KEY = "VFlow.NewModule"

VFlow.registerModule(MODULE_KEY, { name = "新模块", order = 40 })

local defaults = { enabled = true, someOption = 50 }
local db = VFlow.getDB(MODULE_KEY, defaults)

local function renderContent(container, menuKey)
    local layout = {
        { type = "title", text = "新模块配置", cols = 24 },
        { type = "slider", key = "someOption", label = "选项", min = 0, max = 100, cols = 12 },
    }
    Grid.render(container, layout, db, MODULE_KEY)  -- 不传onChange回调
end

VFlow.Modules = VFlow.Modules or {}
VFlow.Modules.NewModule = { renderContent = renderContent }
```

### 5.2 嵌套配置处理

```lua
-- 自定义组使用configPath
if options.isCustom then
    local configPath = "customGroups." .. options.groupIndex .. ".config"
    Grid.render(container, layout, groupConfig, MODULE_KEY, configPath)
else
    Grid.render(container, layout, groupConfig, MODULE_KEY)
end
```

### 5.3 条件渲染和循环渲染

```lua
-- 条件渲染
{ type = "if",
    dependsOn = "dynamicLayout",  -- 当dynamicLayout变化时自动刷新
    condition = function(cfg) return cfg.dynamicLayout end,
    children = { ... }
}

-- 循环渲染
{ type = "for", cols = 2,
    dependsOn = "spellIDs",  -- 当spellIDs变化时自动刷新
    dataSource = function() return getBuffList() end,
    template = {
        type = "iconButton",
        icon = function(data) return data.icon end,
        onClick = function(data)
            -- 修改配置后使用嵌套路径保存
            VFlow.Store.set(MODULE_KEY, configPath .. ".spellIDs", newValue)
        end,
    }
}
```

### 5.4 Core层监听配置

```lua
-- Core层监听Store变化，更新实际效果
VFlow.Store.watch(MODULE_KEY, "CoreComponent", function(key, value)
    // 根据key判断需要做什么
    if key:find("%.x$") or key:find("%.y$") then
        // 只更新位置，不触发全量刷新
        return
    end
    // 其他配置变化：更新实际效果
    UpdateEffect()
end)
```

## 6. 关键原则

- **声明式UI**：Modules层只定义布局，不处理刷新逻辑
- **事件驱动**：通过Store.set触发事件，不手动调用API
- **增量更新**：使用dependsOn机制，只刷新必要的组件
- **职责分离**：Modules负责UI，Core负责业务逻辑
- **嵌套路径**：Store.set支持嵌套路径，精确保存和通知
- **帧复用**：使用Pool系统，避免频繁创建/销毁帧
- **幂等应用**：样式应用函数缓存上次值，避免重复API调用


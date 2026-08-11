# 【需求文档 v1.0】Dock 点击最小化窗口模块（集成于 zeroshot）

> 状态：待评审
> 宿主：zeroshot（`~/Documents/10source/zeroshot`）
> 交付物：本需求文档 +（后续集成阶段）宿主内的功能模块源码

---

## 1. 产品定位

为 zeroshot 新增一个能力：**单击 Dock 上「当前前台已激活 app」的图标，最小化该 app 的「前台窗口」——即聚焦窗口（最近操作的窗口，取不到回退主窗口）**。恢复窗口完全交给 macOS 原生行为（再点一次 Dock 图标即恢复），本模块只做"最小化"这一个方向。

模块后台无感运行，**不新增菜单栏图标、不新增 Dock 图标**，完全由宿主设置页的一个开关驱动。

## 2. 核心交互逻辑

| 场景 | 行为 |
|------|------|
| 前台 app（含任意第三方 app）窗口可见、非全屏，单击其 Dock 图标 | 本模块最小化该 app 的聚焦窗口（最近操作的窗口）；聚焦窗口不可最小化时放行给系统 |
| 该 app 存在已最小化的窗口，单击其 Dock 图标 | **macOS 原生**恢复正常窗口，模块不干预 |
| 单击非前台 app 的 Dock 图标 | **macOS 原生**激活该 app，模块不干预 |
| 单击无窗口 Dock 项（Launchpad/废纸篓/下载/控制中心等） | 不处理 |

**先决条件**：模块只在宿主 app 运行时生效；宿主无 Dock 图标（`LSUIElement`），不受自身规则影响。

## 3. 功能需求

### FR-1 开关
- **FR-1.1** 宿主设置页新增分组「Dock」：`Toggle("单击 Dock 图标最小化窗口")`
- **FR-1.2** 默认**关闭**；开启后**立即生效并即时持久化**（无需重启）
- **FR-1.3** 持久化 key：`dockClickMinimize`（Bool，默认 false），接入现有 `SettingsStore`
- **FR-1.4** 关闭后完全恢复系统默认行为（移除事件监听）

### FR-2 事件监听与判定
- **FR-2.1** `CGEventTap`（`cghidEventTap` / `kCGEventLeftMouseDownMask`）全局监听左键单击
- **FR-2.2** 通过 `AXUIElement` 读取 `AXApplicationDockItem`，确定鼠标落点对应的 app（Dock 位置左/下/右均适配）
- **FR-2.3** 判定条件：被点击 app == 当前前台 app（`NSWorkspace.frontmostApplication`）且该 app 在当前空间存在**可见、非全屏、未最小化**窗口
- **FR-2.4** 满足条件 → 将该聚焦窗口的 `kAXMinimized` 置 true（窗口滑入 Dock）；聚焦窗口不可最小化（全屏/已最小化）时不吞事件、不回退到其他窗口，交由系统默认行为
- **FR-2.5** 未授权辅助功能时静默跳过，不做任何处理

### FR-3 特殊场景跳过
| 场景 | 处理 |
|---|---|
| 前台 app 处于全屏 | 跳过（用 `AXFullScreen` / 窗口尺寸对比屏幕判断） |
| 前台 app 当前空间无可见非全屏窗口 | 跳过，交给系统 |
| 前台 app 窗口已全部最小化 | 跳过，交给系统恢复 |
| 多显示器 | 只处理落在当前空间/当前屏幕的可见窗口 |
| 多桌面空间 | 只最小化当前空间的窗口，其它空间一律不动 |
| 事件落在菜单栏/系统区域 | 不触发 |

### FR-4 系统设置引导
- **FR-4.1** 开关文案旁或开关开启后提示：推荐开启「系统设置 → 桌面与 Dock → 最小化窗口到应用图标」，并提供一个「前往设置」按钮打开 `系统设置 → 桌面与 Dock`
- **FR-4.2** 仅提示，不强改系统设置

### FR-5 辅助功能权限引导
- **FR-5.1** 新增 `AccessibilityPermission` 权限检测（仿照宿主现有 `ScreenRecordingPermission` 的代码风格与引导模式）
- **FR-5.2** 状态判定：`AXIsProcessTrusted()`；申请：`AXIsProcessTrustedWithOptions` 弹系统授权窗
- **FR-5.3** 未授权时：开关仍可开，但模块不生效，开关旁展示 ⚠️ + 「打开系统设置授权」引导（跳转 `x-apple.systempreferences:...Privacy_Accessibility`）及"检测到已授权"刷新机制
- **FR-5.4** 授权返回 app 后自动重查，授权成功后无需重启即生效

## 4. 技术方案（宿主集成要点）

| 项 | 说明 |
|---|---|
| 宿主工程 | zeroshot，SwiftUI + AppKit，无第三方依赖，macOS 14+，`PBXFileSystemSynchronizedRootGroup`（新文件自动编译，无需改 pbxproj） |
| 新增文件 | `Zeroshot/Services/AccessibilityPermission.swift`（权限检测）、`Zeroshot/Services/DockClickMinimizer.swift`（事件 tap + 判定 + 最小化逻辑） |
| 接入 SettingsStore | 新增 `@Published var dockClickMinimize: Bool`（key `dockClickMinimize`），`didSet` 发通知（风格同 `shortcutDidChange`） |
| 接入 MenuBarController | `applicationDidFinishLaunching` 时读开关初始状态启停；监听开关通知启停 tap |
| 接入 SettingsView | 新增「Dock」Section，含开关 + 权限状态 + 系统设置引导 |
| Dock 位置刷新 | tap 触发后获取最新 Dock item 帧；对 `didActivate / activeSpaceDidChange` 做 300ms 尾沿节流重算（参考 Click2Minimize 做法） |
| 兜底 | AX 读取 Dock 列表失败时，可选 AppleScript `System Events` 兜底恢复 app 名（P1，首版可省） |
| 对现有功能影响 | 零——新增独立模块，不改动截图/编辑/热键既有逻辑 |

## 5. 非功能需求

| 项 | 目标 |
|---|---|
| 轻量 | 常驻内存增量 < 10MB，空闲 CPU≈0，仅事件唤醒 |
| 响应 | 点击到窗口开始滑入 ≤ 100ms |
| 隐私 | 无网络、无遥测、无数据收集（与宿主一致） |
| 兼容 | macOS 14+，Apple Silicon + Intel；Dock 三方位；Retina 坐标换算正确 |
| 稳定性 | 事件 tap 异常自动重建，不崩溃；无未捕获异常 |

## 6. 边界与异常处理

1. 未授权辅助功能 → 模块静默跳过并以设置页引导（FR-5），不崩溃。
2. 点击瞬间 app 恰好切前台/后台 → 以事件发生时刻的 `frontmostApplication` 为准，误判概率低且后果无害（仅多一次最小化/跳过）。
3. 全屏时单击仍被事件 tap 捕获 → 判全屏后跳过。
4. 事件 tap 失效（权限被收回/被系统暂停）→ 重试创建 tap；持续失败则设置页提示。
5. 对 Finder、系统设置等首次授权应用也按同一规则生效（属预期行为）。
6. 宿主自身无 Dock 图标 → 不会自我触发。

## 7. 验收标准

1. 设置页默认开关为关；打开后不重启即生效。
2. 任意前台 app 单击其 Dock 图标 → 聚焦窗口（最近操作的窗口）滑入 Dock；再次单击 → macOS 正常恢复。多窗口 app 只收走一个窗口。
3. 单击非前台 app / 全屏中 app / Launchpad / 废纸篓 → 无任何影响。
4. 多空间：A 空间有窗口最小化后，切到 B 空间对应 app 窗口不受影响。
5. 未授权辅助功能：开关旁有引导，点击引导跳转系统设置；授权返回后自动刷新为可用。
6. 关闭开关 → 全部系统默认行为；卸载/退出宿主 → 无残留。
7. 宿主截图、编辑、快捷键、开机自启等既有功能不受影响。

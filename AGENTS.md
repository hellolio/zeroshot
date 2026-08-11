# AGENTS.md

macOS 截图菜单栏工具(截图 + 画线/矩形/圆框/文字气泡/马赛克 + 撤销重做 + Dock 单击最小化)。SwiftUI + AppKit,无第三方依赖,零测试/零 lint 目标。文档为中文: `README.md`(用户说明)、`需求文档.md`(需求与验收)、本文件(AI/开发者构建与架构速查)。

## 构建与部署

前置: macOS 14+、Xcode 16+。没有测试/lint 命令,唯一验证 = `xcodebuild` 通过 + 手动运行。

```bash
# Debug
xcodebuild -project Zeroflow.xcodeproj -scheme Zeroflow -configuration Debug -derivedDataPath build build
# 产物一般在 build/Build/Products/Debug/Zeroflow.app
open build/Build/Products/Debug/Zeroflow.app
```

- **产物路径不可靠**: Debug 产物可能落在 `build/Build/Intermediates.noindex/ArchiveIntermediates/.../Applications/Zeroflow.app`(`cp -R` 复制这个可能是坏符号链接)。用 `find <derived>/Build -name "Zeroflow.app"` 定位,复制用 `cp -R -L` 解引用,复制前 `rm -rf` 目标。
- **dist/ 已被 gitignore**,是发布副本。部署流程: `rm -rf dist/Zeroflow.app && cp -R -L <找到的app> dist/ && pkill -f Zeroflow.app`,再 `open dist/Zeroflow.app`。
- 给 `-derivedDataPath` 的目录若无写权限,构建会直接 `BUILD FAILED`(0644/只读目录),换一个可写路径。
- **新增 .swift 文件自动纳入编译**: 工程用 `PBXFileSystemSynchronizedRootGroup`,不要手动改 pbxproj 加文件。

## 架构要点

- 入口 `Zeroflow/ZeroflowApp.swift`(`@main` 手动建 `NSApplication` + `MenuBarController`); 菜单栏 `MenuBar/MenuBarController.swift`; 服务层 `Services/`:
  - `GlobalHotkeyManager`: Carbon 全局热键,受截图总开关 `screenshotEnabled` 控制(`reapply()` 里判断)。
  - `ScreenCapture`: ScreenCaptureKit 截图; 按 displayID 缓存 `SCContentFilter`(屏幕参数变化通知里 `invalidateFilterCache()`)。
  - `CaptureCoordinator`: 权限→遮罩→捕获→编辑页 的协调器,`isActive` 防重入。
  - `DockClickMinimizer`: Dock 单击最小化(CGEventTap + AX),受 `dockClickMinimize` 开关控制。
  - `AccessibilityPermission` / `ScreenRecordingPermission`: 辅助功能 / 屏幕录制权限检测与申请。
  - `ZSLog`: 统一日志(stderr + `/tmp/zeroflow.log`)。
- 编辑页就是 `Views/EditorView.swift`(单一 1300+ 行文件)。工具: `select / pencil(画线) / rect(矩形) / ellipse(圆框) / bubble(文字气泡) / mosaic(马赛克 半径 12/18/28)`。新增其他工具/图形也先加在这个文件。

### 编辑画布模型(`Models/EditDocument.swift`)

- 所有元素存**图像坐标**(非视图坐标); `EditorView` 用 `displayRect`/`scaleFactor` + `toView`/`toImage`(及 Rect 版本)换算。改元素绘制/命中时必须走这两个函数。
- `CanvasElement` 有 4 个 case: stroke / bubble / shape / mosaic,相等比较逐字段。
- 只有 bubble / shape 可选中、移动、缩放、删除(Backspace/Delete); stroke、mosaic 提交后不可再选。
- `EditDocument` 持有撤销/重做栈(上限 50),任何修改前先 `snapshotBeforeChange()`。
- **BubbleElement / ShapeElement 的 id 不可换**: 重设位置/大小/文字时要用 `init(id:...)` 沿用原 id,否则编辑覆盖层、拖动状态(`elementDrag`)、`selectedElementID` 按 id 索引的簿记全部失效。

### 文字气泡的交互

- 创建气泡后立即进入文字编辑(自动把 `text` 缓冲区置空); 文字编辑覆盖层 `bubbleEditor` 是内缩 8pt 的白底 `TextEditor`,边缘/四角仍可拖动缩放。
- **双击**气泡进入文字编辑(单击只选中)。
- TextEditor 必须显式 `.foregroundColor(.black)`,否则深色模式下黑底白字串字看不见; 顺带 `.environment(\.colorScheme, .light)`。
- 键盘(EditorView 内 NSEvent monitor): `⌘Z`/`⇧⌘Z`/`⌘S`/`⌘C`/`⌘L`(画线)/`T`(标注); Backspace/Delete(51/117) 删除选中气泡/形状(文字编辑中不生效); Esc(53) 文字编辑中=提交并退出编辑,否则关闭窗口。
- 导出(`exportedImage()`)用 AppKit 按原图尺寸重绘,不依赖视图层级,改绘制逻辑记得同步这里。

### 马赛克

- `drawMosaic`(画布)与 `drawMosaicIntoCanvas`(导出)共用 `MosaicOverlayCache`(整图最近邻像素化叠加图按半径缓存一次),临时笔划/已提交笔划/导出共用同一张图,保证三处样式一致。改动时保持这个一致性。

### 设置(`Models/SettingsStore.swift` + `Views/SettingsView.swift`)

- 三个标签页: 通用(开机自启)/ 截图(启用截图功能、快捷键、屏幕录制权限、保存)/ Dock(单击最小化开关 + 辅助功能权限引导)。
- `screenshotEnabled`(默认关)是总开关: 关闭时全局热键不注册、菜单「立即截图」置灰、`CaptureCoordinator.startCapture` 直接忽略。
- `dockClickMinimize` 开关变化由 `DockClickMinimizer` 监听通知启停 CGEventTap; `launchAtLogin` 变化经 `SMAppService.mainApp` 注册/注销(带防重入 + 注册失败回滚)。
- 所有 UserDefaults key 与默认值见 `需求文档.md` FR-12.9。

## 调试辅助环境变量(进程环境)

| 变量 | 作用 |
|---|---|
| `ZEROFLOW_AUTO_CAPTURE=1` | 启动 1.5s 后自动触发一次截图流程 |
| `ZEROFLOW_EDITOR_DEBUG=1` | 启动 1.5s 后直接打开编辑页(合成网格图),绕过截图 |
| `ZEROFLOW_DOCK_PROBE=1` | 启动 1s 后 dump Dock 的 AX 布局到日志 |
| `ZEROFLOW_FAKE_PERMISSION=1` | 跳过真实权限检测(视为已授权) |

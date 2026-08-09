# AGENTS.md

macOS 截图菜单栏工具(截图 + 画线/文字气泡/矩形/椭圆/马赛克 + 撤销重做)。SwiftUI + AppKit,无第三方依赖,零测试/零 lint 目标。文档为中文(`README.md`、`需求文档.md`、`项目介绍.md`)。

## 构建与部署

前置: macOS 14+、Xcode 16+。没有测试/lint 命令,唯一验证 = `xcodebuild` 通过 + 手动运行。

```bash
# Debug
xcodebuild -project Zeroshot.xcodeproj -scheme Zeroshot -configuration Debug -derivedDataPath build build
# 产物一般在 build/Build/Products/Debug/Zeroshot.app
open build/Build/Products/Debug/Zeroshot.app
```

- **产物路径不可靠**: Debug 产物可能落在 `build/Build/Intermediates.noindex/ArchiveIntermediates/.../Applications/Zeroshot.app`(`cp -R` 复制这个可能是坏符号链接)。用 `find <derived>/Build -name "Zeroshot.app"` 定位,复制用 `cp -R -L` 解引用,复制前 `rm -rf` 目标。
- **dist/ 已被 gitignore**,是发布副本。部署流程: `rm -rf dist/Zeroshot.app && cp -R -L <找到的app> dist/ && pkill -f Zeroshot.app`,再 `open dist/Zeroshot.app`。
- 给 `-derivedDataPath` 的目录若无写权限,构建会直接 `BUILD FAILED`(0644/只读目录),换一个可写路径。
- **新增 .swift 文件自动纳入编译**: 工程用 `PBXFileSystemSynchronizedRootGroup`,不要手动改 pbxproj 加文件。

## 架构要点

- 入口 `Zeroshot/ZeroshotApp.swift`; 菜单栏 `MenuBar/MenuBarController.swift`; 服务层 `Services/`(热键 GlobalHotkeyManager、截屏 ScreenCapture、协调 CaptureCoordinator、日志 ZSLog)。
- 编辑页就是 `Views/EditorView.swift`(单一超 800 行文件)。新增其他工具/图形也先加在这个文件。

### 编辑画布模型(`Models/EditDocument.swift`)

- 所有元素存**图像坐标**(非视图坐标); `EditorView` 用 `displayRect`/`scaleFactor` + `toView`/`toImage`(及 Rect 版本)换算。改元素绘制/命中时必须走这两个函数。
- `CanvasElement` 有 4 个 case: stroke / bubble / shape / mosaic,相等比较逐字段。
- `EditDocument` 持有撤销/重做栈, 任何修改前先 `snapshotBeforeChange()`。
- **BubbleElement 的 id 不可换**: 重设位置/大小/文字时要用 `init(id: anchor:box:text:)` 沿用原 id,否则编辑覆盖层、拖动状态(`bubbleDrag`)、`selectedBubbleID` 按 id 索引的簿记全部失效。

### 文字气泡的交互

- 创建气泡后立即进入文字编辑(自动把 `text` 缓冲区置空); 文字编辑覆盖层 `bubbleEditor` 是内缩 8pt 的白底 `TextEditor`,边缘/四角仍可拖动缩放。
- TextEditor 必须显式 `.foregroundColor(.black)`,否则深色模式下黑底白字串字看不见; 顺带 `.environment(\.colorScheme, .light)`。
- 键盘(EditorView 内 NSEvent monitor): `⌘Z`/`⇧⌘Z`/`⌘S`/`⌘C`/`⌘L`/`T`; Backspace/Delete(51/117) 删除选中气泡(编辑中不生效); Esc 关闭窗口。
- 导出(`exportedImage()`)用 AppKit 按原图尺寸重绘,不依赖视图层级,改绘制逻辑记得同步这里。
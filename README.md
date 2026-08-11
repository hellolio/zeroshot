# zeroflow

一款免费、无弹窗的 macOS 原生截图工具。常驻菜单栏，按 `⌘⇧S` 即可截图并简单标注，安装包小、启动迅速。

## 功能

- 全局快捷键 `⌘⇧S` 任意时刻截图，支持自定义快捷键
- 框选截屏 + 画线、文字气泡标注 + 马赛克涂抹
- 撤销/重做

## 技术栈

| 项 | 选型 |
|---|---|
| 语言 | Swift 5 |
| UI | SwiftUI + AppKit |
| 屏幕捕获 | ScreenCaptureKit（macOS 14+） |
| 全局热键 | Carbon `RegisterEventHotKey` |
| 依赖 | 无（单工程） |
| 最小系统 | macOS 14.0（Sonoma）+ |

## 目录结构

```
zeroflow/
├── Zeroflow.xcodeproj/          # Xcode 工程
├── Zeroflow/                    # 源码
│   ├── ZeroflowApp.swift        # 程序入口
│   ├── MenuBar/                 # 菜单栏控制器
│   ├── Models/                  # 设置、快捷键、编辑文档模型
│   ├── Views/                   # 设置页、选区遮罩、编辑页
│   └── Services/                # 热键、截屏、编辑器协调、日志
├── 需求文档.md                  # 详细需求
├── 项目介绍.md                  # 开发者介绍
└── dist/                        # 构建产物副本
```

## 构建

前置条件：macOS 14.0+、Xcode 16+。

```bash
cd zeroflow
xcodebuild -project Zeroflow.xcodeproj -scheme Zeroflow \
  -configuration Debug -derivedDataPath build build

open build/Build/Products/Debug/Zeroflow.app
```

> 新建源文件放入 `Zeroflow/` 目录即自动纳入编译，无需改 pbxproj。已有构建副本：`dist/Zeroflow.app`（arm64）。

## License

[MIT](LICENSE)

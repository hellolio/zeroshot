# zeroshot

A free, ad-free native screenshot tool for macOS. Lives in the menu bar — press `⌘⇧S` to capture and annotate instantly. Small install size, fast startup.

## Features

- Global hotkey `⌘⇧S` to capture from anywhere; shortcut is customizable
- Region selection with line & text-bubble annotation tools
- Undo / redo (up to 50 steps)
- Save as PNG or copy to clipboard
- No Dock icon, menu bar only; optional launch at login

## Tech Stack

| Item | Choice |
|---|---|
| Language | Swift 5 |
| UI | SwiftUI + AppKit |
| Screen capture | ScreenCaptureKit (macOS 14+) |
| Global hotkey | Carbon `RegisterEventHotKey` |
| Dependencies | None (Apple only) |
| Minimum system | macOS 14.0 (Sonoma)+ |

## Structure

```
zeroshot/
├── Zeroshot.xcodeproj/          # Xcode project
├── Zeroshot/                    # Source code
│   ├── ZeroshotApp.swift        # App entry
│   ├── MenuBar/                 # Menu bar controller
│   ├── Models/                  # Settings, document models
│   ├── Views/                   # Settings, capture overlay, editor
│   └── Services/                # Hotkey, capture, coordinator, log
├── 需求文档.md                  # Requirements (Chinese)
├── 项目介绍.md                  # Dev guide (Chinese)
└── dist/                        # Prebuilt app copy
```

## Build

Requires macOS 14.0+ and Xcode 16+.

```bash
cd zeroshot
xcodebuild -project Zeroshot.xcodeproj -scheme Zeroshot \
  -configuration Debug -derivedDataPath build build

open build/Build/Products/Debug/Zeroshot.app
```

> New source files placed in `Zeroshot/` are compiled automatically (no pbxproj edits needed). A prebuilt copy exists at `dist/Zeroshot.app` (arm64).

## License

[MIT](LICENSE)
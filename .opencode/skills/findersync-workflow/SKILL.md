---
name: findersync-workflow
description: Use when developing, building, deploying, or debugging the Finder right-click context menu feature (FinderSync 扩展、右键菜单、访达扩展、新建空文件、右键菜单扩展刷新、finder-sync-settings)。Covers architecture, build/install/verify commands, the three sandbox gotchas, and the macOS Sequoia/Tahoe stale-extension bug plus the pluginkit election-cycle fix.
---

# FinderSync 右键菜单开发流程

本项目通过 FinderSync 扩展在 Finder 右键菜单注入「新建空文件」。本 skill 记录该功能的完整开发、部署、调试与排障流程。

## 架构

- 主 app（非沙盒）持有扩展: `/Applications/Zeroflow.app/Contents/PlugIns/FinderSyncExtension.appex`。
- 扩展为沙盒进程,通过 App Group `8NHN73Q43T.com.zeroflow.app` 与主 app 共享设置。
- **不要用 `UserDefaults(suiteName:)` 读 App Group**(沙盒扩展读不到,cfprefsd 报 `Container: (null)`)。双方直接读写 group container 里同一份 `finder-sync-settings.plist` 文件:
  - 主 app 写:`SettingsStore.saveFinderSharedSettings(enabled:fileName:language:)`(`Zeroflow/Models/SettingsStore.swift`)。
  - 扩展读:每次 `menu(for:)` 前重读文件,开关即时生效(`FinderSyncExtension/FinderSync.swift` 的 `FinderSyncSharedDefaults`)。
- 扩展 `menu(for:)` 在 `isEnabled()` 为 false 时返回 nil(无菜单项);开启后监控真实用户目录 `URL(fileURLWithPath: "/Users/\(NSUserName())")`,桌面与用户目录内的右键都会触发。

## 三个沙盒坑(Debug 必读)

1. **真实家目录**: 沙盒进程里 `FileManager.default.homeDirectoryForCurrentUser` 返回容器目录(`~/Library/Containers/<bundle>/Data`),直接当 `directoryURLs` 会让 Finder 完全不监控用户路径。用 `URL(fileURLWithPath: "/Users/\(NSUserName())")` 拼真实家目录。
2. **`NSMenuItem.representedObject` 跨 XPC 不保留**: 点击回调里 `sender` 拿不到自定义 `representedObject`。目标目录必须用 `FIFinderSyncController.default().targetedURL()` / `selectedItemURLs()` 重新推导(`targetDirectory()`)。
3. **右键目录无写权限**: `files.user-selected.read-write` 不覆盖 FinderSync 右键目标(`deny file-write-create`)。写文件必须加 `com.apple.security.temporary-exception.files.home-relative-path.read-write`(值 `["/"]`;不入 App Store 可接受)。

## macOS Sequoia/Tahoe 陈旧扩展 bug(核心坑)

**症状**: app 重建/覆盖安装后,设置页显示扩展已启用(绿),但 Finder 右键菜单里没有任何选项;手动去 系统设置→通用→登录项与扩展→文件提供者 把扩展「关闭→打开」一次后才恢复。

**根因**: pkd 与 Finder 持有旧的扩展实例——`FIFinderSyncController.isExtensionEnabled` 仍返回 true,但 Finder 不再对新实例调用 `menu(for:)`。手动关开的本质是切换 pluginkit 的 user election,强制 pkd 完全停止并重启扩展。

**修复(election 循环)**: 程序化复现「关闭→打开」:

```bash
pluginkit -e ignore -i com.zeroflow.app.finderSync
pluginkit -e use   -i com.zeroflow.app.finderSync
killall Finder   # 可选;多数情况下 ignore→use 已足够
```

已内置于两处:
- `scripts/install-findersync.sh`(安装/重载,支持 `--reload-only`)。
- `Zeroflow/Services/FinderSyncReloader.swift`(主 app 自愈:启动时若扩展已启用自动重载一次,带 60s 节流;设置页「刷新右键菜单扩展」按钮 force 重载)。

## 构建与部署

```bash
# 构建(必须带 -allowProvisioningUpdates,App Group 需自动生成 profile)
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild \
  -project Zeroflow.xcodeproj -scheme Zeroflow -configuration Release \
  -derivedDataPath build -allowProvisioningUpdates build

# 部署 + 登记 + 启用 + 重载扩展(含 election 循环与校验)
./scripts/install-findersync.sh Release

# 只重载扩展(不重建不部署),改完扩展代码后热验证用
./scripts/install-findersync.sh --reload-only
```

产物定位: `find build/Build -name "Zeroflow.app"`(Debug 可能落在 Intermediates.noindex 下)。

## 验证

```bash
# 登记状态(应含 com.zeroflow.app.finderSync 且为 +,路径指向 /Applications)
pluginkit -m -v -p com.apple.FinderSync | grep -i zeroflow

# 扩展是否被 Finder 加载(有进程即已加载)
pgrep -fl FinderSyncExtension

# 共享设置是否已启用(true 才有菜单)
plutil -p "$HOME/Library/Group Containers/8NHN73Q43T.com.zeroflow.app/finder-sync-settings.plist"

# 扩展日志(menu(for:) 调用/创建文件)
log show --predicate 'subsystem == "com.zeroflow.app.finderSync"' --style compact
```

最终的人工验收: 桌面/用户目录内右键,应直接出现「新建空文件」,无需再去系统设置切换扩展。App 侧重载日志看 `/tmp/zeroflow.log` 的 `FinderSyncReloader:`。

## 排障表

| 现象 | 排查 |
|---|---|
| `pluginkit -m` 查不到 | pkd 僵住: `killall pkd` 后再 `pluginkit -a <appex>`;确认 LS 无旧路径残留(见脚本)。 |
| 扩展沙盒授权缺失,登记被 pkd 静默拒绝 | `codesign -d --entitlements - <appex>` 查 `com.apple.security.app-sandbox` 是否 true。 |
| 已启用(绿)但右键无菜单 | Tahoe 陈旧扩展 bug: 跑 `install-findersync.sh --reload-only`,或设置页点「刷新右键菜单扩展」。 |
| `menu(for:)` 被调用但返回 nil | 共享设置 `finderNewFileEnabled` 为 false,或 `targetDirectory()` 为 nil(右键目标不存在/在监控目录外)。 |
| 创建失败 `deny file-write-create` | 缺 `temporary-exception.files.home-relative-path.read-write`(坑 3)。 |
| 右键菜单不显示但插件正常 | Tahoe 已知 bug,插件能被发现仍不显示时,系统设置里把扩展关/开一次(自动化的 ignore→use 即等效)。 |

#!/bin/zsh
# 重新部署 Zeroflow.app 并重新登记/启用 FinderSync 扩展。
# 用法: ./scripts/install-findersync.sh [Debug|Release]   (默认 Release)
#
# 坑位备忘:
# - pkd 内存状态会僵住,对新扩展 pluginkit -a 返回 0 却查不到 → 需先 killall pkd。
# - LS 里残留的旧路径插件记录(如 build 目录)会让 pkd 解析到无效路径而拒绝 → 必须先
#   lsregister -u 所有旧路径的 app 及其 appex,再只注册 /Applications。
set -e

LS=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
PLUGIN_ID="com.zeroflow.app.finderSync"
PLUGIN_PATH="/Applications/Zeroflow.app/Contents/PlugIns/FinderSyncExtension.appex"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

# 模拟系统设置「文件提供者」里把扩展关闭再打开：通过 pluginkit 切换用户选举状态,
# 强制 pkd 完全停止并重启扩展实例。macOS Sequoia/Tahoe 的 FinderSync 已知问题:
# 扩展显示已启用(FIFinderSyncController.isExtensionEnabled == true)但 Finder 不调用
# menu(for:)(pkd/Finder 持有陈旧实例),右键菜单为空;手动关开一次即恢复,此函数复现之。
reload_extension() {
  echo "== 重载扩展(election: ignore -> use) =="
  pluginkit -a "$PLUGIN_PATH" 2>/dev/null || true
  pluginkit -e ignore -i "$PLUGIN_ID"
  sleep 1
  pluginkit -e use -i "$PLUGIN_ID"
  sleep 2
  echo "== 重启 Finder 让扩展生效 =="
  killall Finder 2>/dev/null || true
  sleep 1
}

# 校验登记状态,最多等 12 秒;通过返回 0,失败返回 1。
verify_registration() {
  for i in 1 2 3 4 5 6; do
    sleep 2
    if pluginkit -m -v -p com.apple.FinderSync 2>/dev/null | grep -qi "${PLUGIN_ID}"; then
      pluginkit -m -v -p com.apple.FinderSync 2>/dev/null | grep -i zeroflow
      echo "登记成功 ✔"
      return 0
    fi
  done
  echo "!! 登记失败,手动执行:"
  echo "  killall pkd"
  echo "  pluginkit -a \"$PLUGIN_PATH\""
  echo "  pluginkit -e use -i $PLUGIN_ID"
  return 1
}

if [ "${1:-}" = "--reload-only" ]; then
  echo "== 仅重载扩展(不重建不部署) =="
  if [ ! -d /Applications/Zeroflow.app ]; then
    echo "!! 未安装 /Applications/Zeroflow.app,请先跑完整安装"; exit 1
  fi
  reload_extension
  verify_registration || exit 1
  sleep 2
  if pgrep -fl FinderSyncExtension >/dev/null; then
    echo "扩展已被 Finder 加载 ✔"
  else
    echo "扩展进程未起(正常:需在 Finder 中触发一次右键/打开文件夹)"
  fi
  exit 0
fi

CONFIG="${1:-Release}"

echo "== 定位构建产物 (${CONFIG}) =="
APP="$(find "$REPO/build/Build" -name "Zeroflow.app" -print0 2>/dev/null | xargs -0 stat -f "%m %N" | sort -rn | awk '{print $2}' | while read p; do
  case "$p" in *Products/${CONFIG}/Zeroflow.app) echo "$p"; break;; esac
done | head -1)"
if [ -z "$APP" ]; then echo "!! 未找到 ${CONFIG} 产物,先构建"; exit 1; fi
APPEX="$APP/Contents/PlugIns/FinderSyncExtension.appex"
echo "  产物: $APP"

echo "== 校验签名 =="
codesign --verify --strict "$APPEX" && echo "  appex OK"
codesign --verify --strict "$APP" && echo "  app OK"
codesign -d --entitlements - "$APPEX" 2>/dev/null | grep -q app-sandbox && echo "  沙盒授权 OK" || echo "  !! appex 缺沙盒授权,登记会失败"

echo "== 停止所有旧实例 =="
pkill -f "Zeroflow.app/Contents/MacOS/Zeroflow" 2>/dev/null || true
sleep 1

echo "== 清除 LS 里所有旧 Zeroflow 路径(含 build 目录、appex),避免 pkd 解析到无效路径 =="
"$LS" -dump 2>/dev/null | grep -oE "/[^ ]*Zeroflow\.app([^ ]*)*" | sort -u | while read p; do
  "$LS" -u "$p" 2>/dev/null || true
  [ -d "$p" ] && { "$LS" -u "$p/Contents/PlugIns/FinderSyncExtension.appex" 2>/dev/null || true; }
done
"$LS" -u "$APP" 2>/dev/null || true
"$LS" -u "$APPEX" 2>/dev/null || true
"$LS" -u /Applications/Zeroflow.app 2>/dev/null || true
"$LS" -u /Applications/Zeroflow.app/Contents/PlugIns/FinderSyncExtension.appex 2>/dev/null || true
sleep 1

echo "== 部署到 /Applications =="
rm -rf /Applications/Zeroflow.app
cp -R -L "$APP" /Applications/Zeroflow.app
echo "  已复制"

echo "== 登记 + 启用扩展 =="
"$LS" -f /Applications/Zeroflow.app
killall pkd 2>/dev/null || true
sleep 3
pluginkit -a /Applications/Zeroflow.app/Contents/PlugIns/FinderSyncExtension.appex
sleep 2
reload_extension

echo "== 校验登记状态(最多等 12 秒) =="
verify_registration || exit 1

sleep 2
if pgrep -fl FinderSyncExtension >/dev/null; then
  echo "扩展已被 Finder 加载 ✔"
else
  echo "扩展进程未起(正常:需在 Finder 中触发一次右键/打开文件夹)"
fi
echo "完成。桌面/文件夹右键即可看到「新建空文件」。每次重新构建后,再跑一次本脚本即可。"
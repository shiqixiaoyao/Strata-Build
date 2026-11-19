# copy lc
wget https://github.com/LiveContainer/dylibify/releases/download/1.0/dylibify
chmod +x dylibify
brew install ldid

# move lc to working folder
mv "$archive_path.xcarchive/Products/Applications" Payload

# --- Built-in host plugins ---------------------------------------------------
# LCGridLayout / LCFloatingMenu 随包分发，启动时由 LCBootstrap dlopen 进宿主进程。
if [ -d "BuiltInPlugins" ]; then
  for dylib in BuiltInPlugins/*.dylib; do
    [ -f "$dylib" ] || continue
    cp "$dylib" "Payload/LiveContainer.app/Frameworks/$(basename "$dylib")"
  done
fi

# --- Built-in JIT helper ----------------------------------------------------
# A second extension process is the only way to hold a debugger connection: a
# process cannot attach a debugger to itself. The helper is the share extension
# binary with its own Info.plist, so both processes share the same worker code.
if [ -d "Payload/LiveContainer.app/PlugIns/ShareExtension.appex" ]; then
  rm -rf "Payload/LiveContainer.app/PlugIns/JITHelper.appex"
  cp -R "Payload/LiveContainer.app/PlugIns/ShareExtension.appex" "Payload/LiveContainer.app/PlugIns/JITHelper.appex"
  python3 - "Payload/LiveContainer.app" <<'PY'
import plistlib, sys
from pathlib import Path
app = Path(sys.argv[1])
target = app / "PlugIns/JITHelper.appex"
info = plistlib.loads((target / "Info.plist").read_bytes())
main = plistlib.loads((app / "Info.plist").read_bytes())
info["CFBundleIdentifier"] = main["CFBundleIdentifier"] + ".JITHelper"
info["CFBundleDisplayName"] = "JIT Helper"
info["NSLocalNetworkUsageDescription"] = "Connect to your local development tunnel to enable JIT."
info["NSExtension"] = {
    "NSExtensionPointIdentifier": "com.apple.ar.viewer",
    "NSExtensionPrincipalClass": "StrataJITRequestHandler",
    "NSExtensionAttributes": {"NSExtensionActivationRule": "FALSEPREDICATE"},
    "NSExtensionContextClass": "NSExtensionContext",
    "NSExtensionContextHostClass": "NSExtensionContext",
}
(target / "Info.plist").write_bytes(plistlib.dumps(info))
print("JITHelper assembled")
PY
fi

# --- App Group entitlements -------------------------------------------------
# SideStore 用目标包的 entitlements 里有没有 com.apple.security.application-groups
# 来决定要不要向 Apple 注册并分配 App Group。没有声明就整步跳过，签出来的描述文件
# 不带共享容器，内置商店一启动就报「无法访问 App Group 容器」。这里给主程序和每个
# 扩展都补上，和上游发布包的签法保持一致。
ADHOC_APP_ENTITLEMENTS=.github/sidelc/LiveContainer_adhoc.xml

write_appex_entitlements() {
  appex_bundle_id="$1"
  appex_out="$2"
  # LiveProcess 自己有一份更完整的 entitlements（increased-memory-limit、HealthKit、
  # 128 个 keychain group）。用固定四键模板重签会把这些全抹掉，表现就是「内存扩容没了」。
  case "$appex_bundle_id" in
    *.LiveProcess)
      if [ -f .github/sidelc/LiveProcess_adhoc.xml ]; then
        sed "s/__APPEX_BUNDLE_ID__/$appex_bundle_id/" .github/sidelc/LiveProcess_adhoc.xml > "$appex_out"
        return 0
      fi
      ;;
  esac
  cat > "$appex_out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>application-identifier</key>
	<string>AAAAA11111.${appex_bundle_id}</string>
	<key>com.apple.developer.team-identifier</key>
	<string>AAAAA11111</string>
	<key>com.apple.security.application-groups</key>
	<array>
		<string>group.com.SideStore.SideStore</string>
	</array>
	<key>get-task-allow</key>
	<true/>
</dict>
</plist>
PLIST
}

sign_app_groups() {
  [ -f "$ADHOC_APP_ENTITLEMENTS" ] || return 0
  ldid -S"$ADHOC_APP_ENTITLEMENTS" Payload/LiveContainer.app/LiveContainer
  for appex in Payload/LiveContainer.app/PlugIns/*.appex; do
    [ -d "$appex" ] || continue
    # 扩展的可执行文件名不一定等于包名（JITHelper.appex 里叫 ShareExtension），必须问 Info.plist
    exe_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$appex/Info.plist" 2>/dev/null)
    [ -n "$exe_name" ] || exe_name=$(basename "$appex" .appex)
    [ -f "$appex/$exe_name" ] || continue
    appex_bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$appex/Info.plist" 2>/dev/null)
    [ -n "$appex_bundle_id" ] || appex_bundle_id="com.kdt.livecontainer.$exe_name"
    write_appex_entitlements "$appex_bundle_id" "/tmp/ent_$exe_name.plist"
    ldid -S"/tmp/ent_$exe_name.plist" "$appex/$exe_name"
  done
}

sign_app_groups

sign_builtin_plugins() {
  for dylib in LCGridLayout LCFloatingMenu; do
    target="Payload/LiveContainer.app/Frameworks/$dylib.dylib"
    [ -f "$target" ] || continue
    # 注意 -S"" 与路径之间必须有空格：写成 -S"$target" 会被 ldid 当成
    # 「用这个 dylib 当 entitlements 文件」，签名直接失败且不报错，
    # 结果就是插件没签名、dlopen 当场返回 NULL。
    ldid -S"" "$target"
  done
}

sign_builtin_plugins

# --- 内置商店的中文表 --------------------------------------------------------
# SideStore 0.7 自己没有本地化资源，界面文案就是 SwiftUI 里的字面量，所以
# 「汉化」等于给宿主表补上商店那批键。词条来自已验证可用的 v19 表（2443 条，
# 其中 2107 条是商店文案），合并时以本体的键优先，只补缺。
merge_zh_hans() {
  [ -f Resources/SideStoreZhHans/Localizable.strings ] || return 0
  python3 - <<'PY'
import plistlib
src = 'Resources/SideStoreZhHans/Localizable.strings'
dst = 'Payload/LiveContainer.app/zh-Hans.lproj/Localizable.strings'
base = plistlib.load(open(dst, 'rb'))
extra = plistlib.load(open(src, 'rb'))
added = 0
for k, v in extra.items():
    if k not in base:
        base[k] = v
        added += 1
plistlib.dump(base, open(dst, 'wb'), fmt=plistlib.FMT_BINARY)
print('zh-Hans merged: +%d of %d -> %d entries' % (added, len(extra), len(base)))
PY
}

merge_zh_hans

# temporarily move sidestore support framrwork to tmp before zip
mkdir tmp
mv Payload/LiveContainer.app/Frameworks/SideStoreSupport.framework ./tmp

zip -r "$scheme.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"

mv ./tmp/SideStoreSupport.framework Payload/LiveContainer.app/Frameworks

# put sidestore related keys into Info.plist and settings bundle
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups array' ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c 'Add :ALTAppGroups: string group.com.SideStore.SideStore' ./Payload/LiveContainer.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1 dict" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLName string com.kdt.livecontainer.sidestoreurlscheme" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:1:CFBundleURLSchemes:0 string sidestore" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2 dict" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLName string com.kdt.livecontainer.sidestorebackupurlscheme" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:2:CFBundleURLSchemes:0 string sidestore-com.kdt.livecontainer" ./Payload/LiveContainer.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :INIntentsSupported array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :INIntentsSupported:0 string RefreshAllIntent" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :INIntentsSupported:1 string ViewAppIntent" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes array" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes:0 string RefreshAllIntent" ./Payload/LiveContainer.app/Info.plist
/usr/libexec/PlistBuddy -c "Add :NSUserActivityTypes:1 string ViewAppIntent" ./Payload/LiveContainer.app/Info.plist

/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Type string PSToggleSwitchSpecifier" ./Payload/LiveContainer.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Title string Open SideStore" ./Payload/LiveContainer.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:Key string LCOpenSideStore" ./Payload/LiveContainer.app/Settings.bundle/Root.plist
/usr/libexec/PlistBuddy -c "Add :PreferenceSpecifiers:3:DefaultValue bool false" ./Payload/LiveContainer.app/Settings.bundle/Root.plist

# download SideStore
cd tmp
wget https://github.com/LiveContainer/SideStore/releases/download/nightly/SideStore.ipa
unzip SideStore.ipa
cd ..

# SideStore
mv ./tmp/Payload/SideStore.app ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework
./dylibify ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore.dylib
rm ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
mv ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore.dylib ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
ldid -S"" ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/SideStore
cp ./.github/sidelc/LCAppInfo.plist ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/

# --- 商店自己的 bundle 也放一份中文表 ----------------------------------------
# 商店里有一部分文案按 Bundle(for:) 查，主程序表覆盖不到，和 v19 一样两边都放。
SS_FW=./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework
if [ -d ./Payload/LiveContainer.app/zh-Hans.lproj ]; then
  mkdir -p "$SS_FW/zh-Hans.lproj"
  cp ./Payload/LiveContainer.app/zh-Hans.lproj/Localizable.strings "$SS_FW/zh-Hans.lproj/"
  [ -f ./Payload/LiveContainer.app/zh-Hans.lproj/Localizable.stringsdict ] && \
    cp ./Payload/LiveContainer.app/zh-Hans.lproj/Localizable.stringsdict "$SS_FW/zh-Hans.lproj/"
  echo "store bundle zh-Hans: $(ls -l "$SS_FW/zh-Hans.lproj/Localizable.strings" | awk '{print $5}') bytes"
fi

# copy intents
cp ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Intents.intentdefinition ./Payload/LiveContainer.app/
cp ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/ViewApp.intentdefinition ./Payload/LiveContainer.app/
cp -r ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/Metadata.appintents ./Payload/LiveContainer.app/Metadata.appintents
sed -i '' 's/9SideStore20RefreshAllAppsIntentV/16SideStoreSupport20RefreshAllAppsIntentV/g' ./Payload/LiveContainer.app/Metadata.appintents/extract.actionsdata
sed -i '' 's/9SideStore26RefreshAllAppsWidgetIntentV/16SideStoreSupport26RefreshAllAppsWidgetIntentV/g' ./Payload/LiveContainer.app/Metadata.appintents/extract.actionsdata

# AltWidgetExtension
mv ./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework/PlugIns/AltWidgetExtension.appex ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.kdt.livecontainer.LiveWidget"  ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable LiveWidgetExtension"  ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/Info.plist
mv ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/AltWidgetExtension ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension

# Sign
rm -r .zsign_cache
find payloadlc/Payload -type d -name "_CodeSignature" -exec rm -r {} +

ldid -S.github/sidelc/LiveWidgetExtension_adhoc.xml ./Payload/LiveContainer.app/PlugIns/LiveWidgetExtension.appex/LiveWidgetExtension

# package
zip -r "$scheme+SideStore.ipa" "Payload" -x "._*" -x ".DS_Store" -x "__MACOSX"
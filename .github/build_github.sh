# copy lc
wget https://github.com/LiveContainer/dylibify/releases/download/1.0/dylibify
chmod +x dylibify
brew install ldid

# move lc to working folder
mv "$archive_path.xcarchive/Products/Applications" Payload

# --- App Group entitlements -------------------------------------------------
# SideStore 用目标包的 entitlements 里有没有 com.apple.security.application-groups
# 来决定要不要向 Apple 注册并分配 App Group。没有声明就整步跳过，签出来的描述文件
# 不带共享容器，内置商店一启动就报「无法访问 App Group 容器」。这里给主程序和每个
# 扩展都补上，和上游发布包的签法保持一致。
ADHOC_APP_ENTITLEMENTS=.github/sidelc/LiveContainer_adhoc.xml

write_appex_entitlements() {
  appex_bundle_id="$1"
  appex_out="$2"
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

# SideStore 访客进程里 NSBundle.mainBundle 会被换成 SideStoreApp.framework，
# 而这个 framework 本身没有 .lproj，所以所有本地化查询都会回落到英文原文。
# 把主 bundle 编译出的中文表复制进去（en 也放一份，避免语言解析回落到英文）。
SIDESTORE_FW=./Payload/LiveContainer.app/Frameworks/SideStoreApp.framework
# 每个语言拷自己的表：原来两种语言都拷中文表，英文系统会看到中文。
for loc in zh-Hans en; do
  src_lproj="./Payload/LiveContainer.app/$loc.lproj"
  [ -d "$src_lproj" ] || continue
  mkdir -p "$SIDESTORE_FW/$loc.lproj"
  [ -f "$src_lproj/Localizable.strings" ] && cp "$src_lproj/Localizable.strings" "$SIDESTORE_FW/$loc.lproj/"
  [ -f "$src_lproj/Localizable.stringsdict" ] && cp "$src_lproj/Localizable.stringsdict" "$SIDESTORE_FW/$loc.lproj/"
done

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
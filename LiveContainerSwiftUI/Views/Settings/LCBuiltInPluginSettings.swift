import SwiftUI

/// 两个随包内置的宿主插件。写入 UserDefaults，下次启动由 LCBootstrap 读取。
struct LCBuiltInPluginSettings: View {
    @AppStorage("LCBuiltInGridLayoutEnabled") private var gridLayout = true
    @AppStorage("LCBuiltInFloatingMenuEnabled") private var floatingMenu = true

    var body: some View {
        List {
            Section {
                Toggle(isOn: $gridLayout) {
                    Label("Icon grid".loc, systemImage: "square.grid.3x3")
                }
                Toggle(isOn: $floatingMenu) {
                    Label("Floating menu".loc, systemImage: "menubar.rectangle")
                }
            } header: {
                Text("Built-in plugins".loc)
            } footer: {
                Text("Both plugins are injected into LiveContainer itself and only take effect after a full restart. The grid replaces the app list; the floating menu adds a side notch.".loc)
            }
        }
        .navigationTitle("Built-in plugins".loc)
        .navigationBarTitleDisplayMode(.inline)
    }
}

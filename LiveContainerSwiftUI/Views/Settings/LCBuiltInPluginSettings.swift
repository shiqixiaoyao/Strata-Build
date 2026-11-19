import SwiftUI
import UIKit

/// 两个随包内置的宿主插件。写入 UserDefaults，下次启动由 LCBootstrap 读取。
struct LCBuiltInPluginSettings: View {
    @AppStorage("LCBuiltInGridLayoutEnabled") private var gridLayout = true
    @AppStorage("LCBuiltInFloatingMenuEnabled") private var floatingMenu = true
    @State private var diagnostics = ""

    private var diagnosticsURL: URL {
        LCPath.docPath.appendingPathComponent("LCBuiltInPlugins.log")
    }

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
                Text("The grid is injected into LiveContainer itself. The floating menu ships inside TweakLoader, so it appears both in LiveContainer and inside every app it launches. Changing either switch takes effect after a full restart.".loc)
            }

            Section {
                if diagnostics.isEmpty {
                    Text("暂无诊断信息。重启一次 LiveContainer，再回到这里。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ScrollView {
                        Text(diagnostics)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 320)
                    Button {
                        UIPasteboard.general.string = diagnostics
                    } label: {
                        Label("复制诊断信息", systemImage: "doc.on.doc")
                    }
                }
            } header: {
                Text("内置插件诊断")
            } footer: {
                Text("记录内置 dylib 的加载结果、TweakLoader 里有没有 Orbit、微珠的宿主判定，以及启动 3 秒后屏幕上有没有它的窗口。每次启动重写。")
            }
        }
        .navigationTitle("Built-in plugins".loc)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadDiagnostics)
        .refreshable { reloadDiagnostics() }
    }

    private func reloadDiagnostics() {
        diagnostics = (try? String(contentsOf: diagnosticsURL, encoding: .utf8)) ?? ""
    }
}

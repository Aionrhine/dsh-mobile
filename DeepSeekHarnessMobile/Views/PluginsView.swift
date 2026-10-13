import SwiftUI
import WebKit

struct PluginsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var gatewayToggle: MobilePluginBundle?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text("安装、启用和配置插件")
                    .font(.subheadline).foregroundStyle(.secondary)
                if !store.gateway.state.isConnected {
                    Text("网关已断开，插件状态待重新连接确认")
                        .font(.subheadline).foregroundStyle(.orange)
                }
                if let notice = store.pluginNotice {
                    Text(notice).font(.subheadline).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let error = store.pluginsError {
                    ContentUnavailableView(error, systemImage: "puzzlepiece.extension",
                        description: Text("请检查网关连接后重试"))
                        .frame(maxWidth: .infinity)
                }
                if store.pluginsLoading && store.pluginCatalog == nil {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
                if let catalog = store.pluginCatalog, catalog.managementAvailable {
                    pluginSection(String(localized: "官方"), count: catalog.officialBundles.count + catalog.officialItems.count) {
                        ForEach(catalog.officialBundles) { bundle in bundleRow(bundle) }
                        ForEach(catalog.officialItems) { item in
                            NavigationLink { OfficialPluginDetailView(item: item) } label: {
                                PluginLine(icon: nil, fallback: item.id, title: item.title,
                                    subtitle: item.description, detail: false, experimental: false)
                            }.buttonStyle(.plain).frame(minHeight: 68)
                        }
                    }
                    pluginSection(String(localized: "已安装"), count: catalog.installedBundles.count) {
                        ForEach(catalog.installedBundles) { bundle in bundleRow(bundle) }
                    }
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 20)
        }
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("插件")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { store.refreshPlugins() } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 17, weight: .medium))
                }
                    .disabled(store.pluginsLoading)
                    .accessibilityLabel("刷新插件")
            }
        }
        .task { store.refreshPlugins() }
        .alert("停用移动网关？", isPresented: Binding(
            get: { gatewayToggle != nil }, set: { if !$0 { gatewayToggle = nil } }
        )) {
            Button("取消", role: .cancel) { gatewayToggle = nil }
            Button("停用", role: .destructive) {
                guard let bundle = gatewayToggle else { return }
                gatewayToggle = nil
                store.setPluginEnabled(name: bundle.name, enabled: false)
            }
        } message: {
            Text("停用后手机会断开连接。只能从 DSH Web 或 CLI 重新开启此插件。")
        }
    }

    private func pluginSection<Content: View>(
        _ title: String, count: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(.headline)
                Text("\(count)").foregroundStyle(.secondary)
            }.padding(.bottom, 4)
            content()
        }
    }

    private func bundleRow(_ bundle: MobilePluginBundle) -> some View {
        HStack(spacing: 8) {
            NavigationLink {
                PluginDetailView(store: store, name: bundle.name)
            } label: {
                PluginLine(icon: bundle.icon, fallback: bundle.name,
                    title: bundle.title, subtitle: bundle.description, detail: false,
                    experimental: bundle.experimental)
            }.buttonStyle(.plain)
            if store.pluginPendingName == bundle.name { ProgressView().controlSize(.small) }
            Toggle(bundle.title, isOn: Binding(
                get: { bundle.enabled },
                set: { requested in
                    if bundle.name == "dsh-plugin-mobile-gateway" && !requested {
                        gatewayToggle = bundle
                    } else {
                        store.setPluginEnabled(name: bundle.name, enabled: requested)
                    }
                }
            ))
            .labelsHidden()
            .tint(pluginSwitchTint(for: colorScheme))
            .disabled(!store.gateway.state.isConnected || bundle.readOnlyReason != nil ||
                store.pluginCatalog?.managementAvailable != true)
            .allowsHitTesting(store.pluginPendingName == nil)
            .accessibilityLabel("\(bundle.title)开关")
        }
        .frame(minHeight: 68)
    }
}

private struct PluginDetailView: View {
    @ObservedObject var store: AppStore
    @Environment(\.colorScheme) private var colorScheme
    let name: String
    @State private var confirmGatewayDisable = false
    @State private var selectedEntry: MobilePluginRow?

    private var bundle: MobilePluginBundle? { store.pluginCatalog?.bundles.first { $0.name == name } }

    var body: some View {
        ScrollView {
            if let bundle {
                VStack(alignment: .leading, spacing: 22) {
                    HStack(alignment: .top) {
                        PluginIcon(dataURL: bundle.icon, fallback: bundle.name).frame(width: 60, height: 60)
                        Spacer()
                        Toggle(bundle.title, isOn: Binding(
                            get: { bundle.enabled },
                            set: { requested in
                                if bundle.name == "dsh-plugin-mobile-gateway" && !requested {
                                    confirmGatewayDisable = true
                                } else { store.setPluginEnabled(name: bundle.name, enabled: requested) }
                            }
                        ))
                        .labelsHidden()
                        .tint(pluginSwitchTint(for: colorScheme))
                        .disabled(!store.gateway.state.isConnected || bundle.readOnlyReason != nil)
                        .allowsHitTesting(store.pluginPendingName == nil)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(bundle.title).font(.title2.bold())
                        if let version = bundle.version {
                            Text("v\(version)").font(.caption).foregroundStyle(.secondary)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                    Text(bundle.name).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                    if !bundle.description.isEmpty { Text(bundle.description).foregroundStyle(.secondary) }
                    if let reason = bundle.readOnlyReason { Text(reason).font(.footnote).foregroundStyle(.orange) }
                    if let error = bundle.error { Text(error).font(.footnote).foregroundStyle(.red) }
                    if let notice = store.pluginNotice { Text(notice).font(.footnote).foregroundStyle(.orange) }
                    if !store.gateway.state.isConnected {
                        Text("网关已断开，插件状态待重新连接确认")
                            .font(.footnote).foregroundStyle(.orange)
                    }
                    let entries = bundle.rows.map { row -> MobilePluginRow in
                        let entryID = row["entryId"]?.stringValue
                        let live = store.pluginCatalog?.plugins.first { $0.id == entryID }
                        return MobilePluginRow(raw: row, live: live)
                    }
                    HStack(spacing: 8) {
                        Text("包含的组件").font(.headline)
                        Text("共 \(entries.count) 个 · \(entries.filter { $0.enabled && $0.phase == "active" }.count) 运行中")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }.padding(.top, 14)
                    ForEach(entries) { entry in
                        HStack(spacing: 10) {
                            Button { selectedEntry = entry } label: {
                                HStack(spacing: 10) {
                                    PluginIcon(dataURL: entry.icon, fallback: "subagent")
                                        .frame(width: 44, height: 44)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(entry.name)
                                            .font(.subheadline.bold())
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        HStack(spacing: 5) {
                                            Circle().fill(entry.enabled && entry.phase == "active" ? .green : entry.enabled && entry.phase == "failed" ? .red : .gray)
                                                .frame(width: 7, height: 7)
                                            Text(entry.statusText).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("查看\(entry.name)详情")
                            if let entryID = entry.entryID {
                                Toggle(entry.name, isOn: Binding(
                                    get: { entry.enabled },
                                    set: { store.setPluginEnabled(name: bundle.name, enabled: $0, entryID: entryID) }
                                )).labelsHidden()
                                    .tint(pluginSwitchTint(for: colorScheme))
                                    .disabled(!store.gateway.state.isConnected || entry.readOnlyReason != nil)
                                    .allowsHitTesting(store.pluginPendingName == nil)
                            }
                            Button { selectedEntry = entry } label: {
                                Image(systemName: "chevron.right")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 30, height: 44)
                            }
                            .accessibilityLabel("查看\(entry.name)详情")
                        }
                        .frame(minHeight: 60)
                    }
                }
                .padding(22).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .navigationTitle("插件详情").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selectedEntry) { entry in
            PluginComponentSheet(entry: entry)
        }
        .alert("停用移动网关？", isPresented: $confirmGatewayDisable) {
            Button("取消", role: .cancel) {}
            Button("停用", role: .destructive) { store.setPluginEnabled(name: name, enabled: false) }
        } message: { Text("停用后手机会断开连接。只能从 DSH Web 或 CLI 重新开启此插件。") }
    }
}

private struct PluginComponentSheet: View {
    @Environment(\.dismiss) private var dismiss
    let entry: MobilePluginRow

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        PluginIcon(dataURL: entry.icon, fallback: "subagent")
                            .frame(width: 56, height: 56)
                        Text(entry.name).font(.title3.bold())
                    }
                    HStack(spacing: 7) {
                        Circle().fill(entry.enabled && entry.phase == "active" ? .green : entry.enabled && entry.phase == "failed" ? .red : .gray)
                            .frame(width: 8, height: 8)
                        Text(entry.statusText).foregroundStyle(.secondary)
                    }
                    if !entry.description.isEmpty {
                        Text(entry.description).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        componentField("组件 ID", value: entry.id)
                        if !entry.moduleName.isEmpty { componentField("模块", value: entry.moduleName) }
                        if let entryID = entry.entryID { componentField("运行条目 ID", value: entryID) }
                        if let reason = entry.readOnlyReason { componentField("不可修改原因", value: reason) }
                    }
                    .padding(.top, 8)
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("组件详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func componentField(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.subheadline.monospaced()).textSelection(.enabled)
        }
    }
}

private func pluginSwitchTint(for scheme: ColorScheme) -> Color {
    scheme == .dark
        ? Color(red: 29.0 / 255, green: 68.0 / 255, blue: 127.0 / 255)
        : Color(red: 36.0 / 255, green: 90.0 / 255, blue: 196.0 / 255)
}

private struct OfficialPluginDetailView: View {
    let item: MobileOfficialPlugin
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PluginIcon(dataURL: nil, fallback: item.id).frame(width: 60, height: 60)
                Text(item.title).font(.title2.bold())
                Text(item.description).foregroundStyle(.secondary)
                Text("配置项").font(.headline).padding(.top, 16)
                ForEach(item.namespaces, id: \.self) { namespace in
                    Text(namespace).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("插件详情").navigationBarTitleDisplayMode(.inline)
    }
}

private struct PluginLine: View {
    let icon: String?
    let fallback: String
    let title: String
    let subtitle: String
    let detail: Bool
    let experimental: Bool
    var body: some View {
        HStack(spacing: 13) {
            PluginIcon(dataURL: icon, fallback: fallback).frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(title).font(.body.bold()).foregroundStyle(.primary)
                        .lineLimit(1).truncationMode(.tail)
                    if experimental { ExperimentalPluginBadge() }
                }
                if !subtitle.isEmpty {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if detail { Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
        }
        .contentShape(Rectangle())
    }
}

private struct ExperimentalPluginBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text("实验性")
            .font(.caption.weight(.medium))
            .foregroundStyle(colorScheme == .dark ? Color(red: 0.55, green: 0.68, blue: 1) : .blue)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.blue.opacity(colorScheme == .dark ? 0.2 : 0.1), in: Capsule())
            .fixedSize()
    }
}

private struct PluginIcon: View {
    let dataURL: String?
    let fallback: String
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 13).strokeBorder(.gray.opacity(0.3))
            if let dataURL, dataURL.count < 256_000,
               dataURL.hasPrefix("data:image/"),
               let comma = dataURL.firstIndex(of: ","),
               dataURL[..<comma].hasSuffix(";base64"),
               let bytes = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])) {
                if let image = UIImage(data: bytes) {
                    Image(uiImage: image).resizable().scaledToFit().padding(11)
                } else if dataURL.hasPrefix("data:image/svg+xml;base64,") {
                    PluginSVGView(dataURL: dataURL).padding(8)
                }
            } else {
                Image(artworkName).resizable().scaledToFit().padding(8)
            }
        }
    }

    private var artworkName: String {
        switch fallback {
        case "shell": "PluginArtworkShell"
        case "agent-loop": "PluginArtworkAgentLoop"
        case "subagent": "PluginArtworkSubagent"
        case "web-search": "PluginArtworkWebSearch"
        default: "PluginArtworkDefault"
        }
    }
}

private struct PluginSVGView: UIViewRepresentable {
    let dataURL: String
    final class Coordinator { var loadedDataURL: String? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: config)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.isScrollEnabled = false
        return view
    }
    func updateUIView(_ view: WKWebView, context: Context) {
        guard context.coordinator.loadedDataURL != dataURL else { return }
        context.coordinator.loadedDataURL = dataURL
        view.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='margin:0;display:grid;place-items:center;background:transparent'><img style='max-width:100%;max-height:100%' src='\(dataURL)'></body></html>", baseURL: nil)
    }
}

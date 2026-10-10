import SwiftUI
import WebKit

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pendingPermission: DefaultPermissionChoice?
    @State private var observedGatewayState: ConnectionState?
    @State private var showsPrivacyPolicy = false

    private var gatewayState: ConnectionState {
        observedGatewayState ?? store.gateway.state
    }

    private var selectedPresetName: String {
        guard let id = store.agentPresetDefault else { return String(localized: "未读取") }
        return store.agentPresets.first(where: { $0.id == id })?.displayName ?? id
    }

    private var selectedPermissionName: String {
        guard let id = store.permissionDefault else { return String(localized: "未读取") }
        return store.permissionDefaultOptions.first(where: { $0.value == id })?.name ?? id
    }

    private var defaultsAreLoading: Bool {
        !store.defaultConfigurationLoadingKinds.isDisjoint(with: ["defaults", "agent-presets"])
    }

    private var defaultModelIsLoading: Bool {
        store.defaultConfigurationLoadingKinds.contains("default-model")
            || store.defaultConfigurationLoadingKinds.contains("save-default-model")
    }

    private var defaultModelValueText: String {
        guard let selection = store.defaultModelSelection else { return String(localized: "未读取") }
        let item = store.anyModelCatalog?.groups
            .first(where: { $0.id == selection.provider })?
            .models.first(where: { $0.id == selection.model })
        let name = item?.name ?? Self.modelDisplayName(selection.model)
        guard let effort = selection.reasoningEffort else { return name }
        let effortName = item?.reasoning?.efforts.first(where: { $0.id == effort })?.name ?? Self.reasoningEffortDisplayName(effort)
        return "\(name) · \(effortName)"
    }

    static func modelDisplayName(_ id: String) -> String {
        switch id {
        case "deepseek-chat": return "DeepSeek Chat"
        case "deepseek-reasoner": return "DeepSeek Reasoner"
        default: return id
        }
    }

    static func reasoningEffortDisplayName(_ id: String) -> String {
        switch id.lowercased() {
        case "low": return String(localized: "低")
        case "medium": return String(localized: "中")
        case "high": return String(localized: "高")
        default: return id.capitalized
        }
    }

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    AgentPresetSelectionView()
                } label: {
                    DefaultConfigurationRow(
                        title: String(localized: "Agent 预设"),
                        value: selectedPresetName,
                        isLoading: defaultsAreLoading
                    )
                }
                .disabled(!gatewayState.isConnected)

                NavigationLink {
                    DefaultModelSelectionView()
                } label: {
                    DefaultConfigurationRow(
                        title: String(localized: "默认模型"),
                        value: defaultModelValueText,
                        isLoading: defaultModelIsLoading
                    )
                }
                .disabled(!gatewayState.isConnected)

                Menu {
                    ForEach(store.permissionDefaultOptions.map(DefaultPermissionChoice.init)) { option in
                        Button {
                            pendingPermission = option
                        } label: {
                            if option.id == store.permissionDefault {
                                Label(option.title, systemImage: "checkmark")
                            } else {
                                Text(option.title)
                            }
                        }
                    }
                } label: {
                    DefaultConfigurationRow(
                        title: String(localized: "权限"),
                        value: selectedPermissionName,
                        isLoading: defaultsAreLoading
                    )
                    .contentShape(Rectangle())
                }
                .tint(.primary)
                .disabled(!gatewayState.isConnected || store.defaultConfigurationLoadingKinds.contains("set-default"))
            } header: {
                Text("新会话默认配置")
            } footer: {
                Text("与 WebUI 使用同一份部署级设置。修改只影响之后新建的会话，运行中的会话保持启动时的配置。")
            }

            Section("Mobile Gateway") {
                TextField("ws://host:3080/ws/mobile", text: $store.endpoint)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                HStack {
                    ConnectionDot(state: gatewayState)
                    Text(gatewayState.label)
                    Spacer()
                    if let port = store.gateway.serverPort {
                        Text("Port \(port)").foregroundStyle(.secondary)
                    }
                }
                Button(gatewayState.isConnected ? String(localized: "断开连接") : String(localized: "连接")) {
                    if gatewayState.isConnected {
                        store.disconnect()
                    } else {
                        store.connect()
                    }
                }
                Button("Ping 网关") { store.gateway.ping() }
            }

            if let host = store.hostSnapshot {
                Section("DSH Host") {
                    LabeledContent("版本", value: host.version ?? "—")
                    LabeledContent("Provider", value: host.provider ?? "—")
                    LabeledContent("Model", value: host.model ?? "—")
                    LabeledContent("已连接会话", value: "\(host.attachedSessions ?? 0)")
                    if let cwd = host.cwd {
                        LabeledContent {
                            Text(cwd)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        } label: {
                            Text("cwd")
                        }
                    }
                }
            }

            Section {
                Picker("界面", selection: $store.interfaceStyle) {
                    ForEach(InterfaceStyle.allCases) {
                        Text($0.title).tag($0)
                    }
                }
                .pickerStyle(.navigationLink)
                Picker("语言", selection: $store.appLanguage) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(verbatim: language.title).tag(language)
                    }
                }
                .pickerStyle(.navigationLink)
            } header: {
                Text("外观")
            } footer: {
                Text("语言设置将在重新启动应用后生效。")
            }

            Section("关于") {
                Button("隐私政策") { showsPrivacyPolicy = true }
            }
        }
        .navigationTitle("设置")
        .task {
            store.refreshDefaultConfiguration()
        }
        .onReceive(store.gateway.$state) { state in
            let wasConnected = observedGatewayState?.isConnected ?? state.isConnected
            observedGatewayState = state
            if !wasConnected && state.isConnected {
                store.refreshDefaultConfiguration()
            }
        }
        .alert(item: $pendingPermission) { option in
            Alert(
                title: Text("修改全局默认权限？"),
                message: Text(String(localized: "defaults.permission.confirm.body", defaultValue: "将新会话的默认权限改为“\(option.title)”。这会更新部署级设置，并同步影响 WebUI。")),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .default(Text("确认修改")) {
                    store.setDefaultPermission(option.id)
                }
            )
        }
        .sheet(isPresented: $showsPrivacyPolicy) {
            PrivacyPolicySheet()
        }
    }
}

private struct PrivacyPolicySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = true
    @State private var loadFailed = false
    @State private var reloadID = UUID()

    private let url = URL(string: "https://clarklevis1995.github.io/dsh-mobile/privacy/")!

    var body: some View {
        NavigationStack {
            ZStack {
                PrivacyPolicyWebView(url: url, isLoading: $isLoading, loadFailed: $loadFailed)
                    .id(reloadID)
                    .opacity(loadFailed ? 0 : 1)
                    .allowsHitTesting(!loadFailed)

                if isLoading {
                    ProgressView()
                }

                if loadFailed {
                    VStack(spacing: 12) {
                        Text("无法打开隐私政策")
                        Button("重试") {
                            loadFailed = false
                            isLoading = true
                            reloadID = UUID()
                        }
                    }
                }
            }
            .navigationTitle("隐私政策")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct PrivacyPolicyWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    @Binding var loadFailed: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(isLoading: $isLoading, loadFailed: $loadFailed)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        @Binding var loadFailed: Bool

        init(isLoading: Binding<Bool>, loadFailed: Binding<Bool>) {
            _isLoading = isLoading
            _loadFailed = loadFailed
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            isLoading = true
            loadFailed = false
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            handleLoadError(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleLoadError(error)
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if let url = navigationAction.request.url, url.scheme == "mailto" {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationResponse: WKNavigationResponse,
            decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
        ) {
            if navigationResponse.isForMainFrame,
               let response = navigationResponse.response as? HTTPURLResponse,
               response.statusCode >= 400 {
                isLoading = false
                loadFailed = true
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }

        private func handleLoadError(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            isLoading = false
            loadFailed = true
        }
    }
}

private struct DefaultConfigurationRow: View {
    let title: String
    let value: String
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            if isLoading {
                ProgressView()
                    .controlSize(.small)
            } else {
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

private struct DefaultPermissionChoice: Identifiable, Hashable {
    let id: String
    let title: String
    let description: String

    init(_ option: GatewayPermissionOption) {
        id = option.value
        title = option.name
        description = option.description ?? option.name
    }
}

private struct AgentPresetSelectionView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pendingPreset: GatewayAgentPreset?

    private var isChangingDefault: Bool {
        store.defaultConfigurationLoadingKinds.contains("set-default")
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Agent 预设")
                        .font(.title2.bold())
                    Text("预设决定 Agent 使用的工具、提示词与能力。选择后只对新建会话生效。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)

                if let error = store.agentPresetsLoadError {
                    VStack(alignment: .leading, spacing: 10) {
                        Label(error, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        Button("重试") { store.retryAgentPresets() }
                            .disabled(store.defaultConfigurationLoadingKinds.contains("agent-presets"))
                    }
                    .padding(.vertical, 12)
                }

                if store.defaultConfigurationLoadingKinds.contains("agent-presets") && store.agentPresets.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取 Agent 预设…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else if store.agentPresets.isEmpty && store.agentPresetsLoadError == nil {
                    ContentUnavailableView(
                        "没有可用的 Agent 预设",
                        systemImage: "point.3.filled.connected.trianglepath.dotted",
                        description: Text("网关暂无可用预设，可下拉刷新。")
                    )
                    .padding(.vertical, 24)
                } else {
                    ForEach(store.agentPresets) { preset in
                        AgentPresetCard(
                            preset: preset,
                            isSelected: preset.id == store.agentPresetDefault,
                            isBusy: isChangingDefault
                        ) {
                            pendingPreset = preset
                        }
                    }
                }

                if store.agentPresetsAuthorable || store.agentPresetsHasDocument {
                    Label(presetCapabilityText, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Agent 预设")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            store.refreshDefaultConfiguration()
        }
        .task {
            if store.agentPresets.isEmpty {
                store.refreshDefaultConfiguration()
            }
        }
        .alert(item: $pendingPreset) { preset in
            Alert(
                title: Text("设为全局默认预设？"),
                message: Text(String(localized: "defaults.preset.confirm.body", defaultValue: "将“\(preset.displayName)”设为新会话的默认 Agent 预设。这会更新部署级设置，并同步影响 WebUI。")),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .default(Text("设为默认")) {
                    store.setDefaultAgentPreset(preset.id)
                }
            )
        }
    }

    private var presetCapabilityText: String {
        switch (store.agentPresetsAuthorable, store.agentPresetsHasDocument) {
        case (true, true): return String(localized: "服务端支持编写自定义预设，并提供预设配置文档。")
        case (true, false): return String(localized: "服务端支持编写自定义 Agent 预设。")
        case (false, true): return String(localized: "服务端提供 Agent 预设配置文档。")
        case (false, false): return ""
        }
    }
}

private struct AgentPresetCard: View {
    let preset: GatewayAgentPreset
    let isSelected: Bool
    let isBusy: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(preset.displayName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(preset.id)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(.secondary.opacity(0.1), in: Capsule())
                    Spacer()
                    if isSelected {
                        Text("当前使用")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black, in: Capsule())
                    }
                }

                Text(preset.displayDescription)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if preset.broken == true {
                    Label("该预设存在配置错误，暂时不能设为默认值", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(isSelected ? Color.primary : Color.secondary.opacity(0.18), lineWidth: isSelected ? 1.5 : 1)
            }
        }
        .buttonStyle(.plain)
        .allowsHitTesting(!isSelected && !isBusy && preset.broken != true)
        .opacity(preset.broken == true ? 0.68 : 1)
    }
}

private struct DefaultModelSelectionView: View {
    @EnvironmentObject private var store: AppStore
    @State private var pendingChange: PendingDefaultModelChange?

    private var isBusy: Bool {
        store.defaultConfigurationLoadingKinds.contains("save-default-model")
    }
    private var modelGroups: [GatewayModelGroup] {
        store.anyModelCatalog?.groups ?? []
    }
    private var isLoadingCatalog: Bool {
        store.sessionControlLoadingKinds.contains("models") && modelGroups.isEmpty
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 7) {
                    Text("默认模型")
                        .font(.title2.bold())
                    Text("为之后新建的会话设置默认模型与思考等级。这会更新部署级设置，同步影响 WebUI，运行中的会话保持启动时的配置。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 4)

                if isLoadingCatalog {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取模型列表…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                } else if modelGroups.isEmpty {
                    ContentUnavailableView(
                        "暂无可用模型",
                        systemImage: "cpu",
                        description: Text("未能读取到模型列表，请检查网关连接后下拉重试。")
                    )
                    .padding(.vertical, 24)
                } else {
                    ForEach(modelGroups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(group.name)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                            ForEach(group.models) { model in
                                DefaultModelCard(
                                    group: group,
                                    model: model,
                                    isSelected: isDefault(group: group, model: model),
                                    currentEffort: store.defaultModelSelection?.reasoningEffort,
                                    isBusy: isBusy,
                                    onSelectModel: { select(group: group, model: model) },
                                    onSelectEffort: { effort in selectEffort(effort, group: group, model: model) }
                                )
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("默认模型")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            store.ensureModelCatalogForDefaults()
        }
        .task {
            store.ensureModelCatalogForDefaults()
        }
        .alert(item: $pendingChange) { change in
            Alert(
                title: Text("修改默认模型？"),
                message: Text(String(localized: "defaults.model.confirm.body", defaultValue: "将新会话的默认模型改为“\(change.summary)”。这会更新部署级设置，并同步影响 WebUI。")),
                primaryButton: .cancel(Text("取消")),
                secondaryButton: .default(Text("确认修改")) {
                    store.saveDefaultModel(provider: change.provider, model: change.model, reasoningEffort: change.reasoningEffort)
                }
            )
        }
    }

    private func isDefault(group: GatewayModelGroup, model: GatewayModelItem) -> Bool {
        store.defaultModelSelection?.provider == group.id && store.defaultModelSelection?.model == model.id
    }

    private func select(group: GatewayModelGroup, model: GatewayModelItem) {
        let efforts = model.reasoning?.efforts ?? []
        let retainedEffort = store.defaultModelSelection?.reasoningEffort.flatMap { current in
            efforts.contains(where: { $0.id == current }) ? current : nil
        }
        let effortId = retainedEffort ?? model.reasoning?.defaultEffort
        pendingChange = PendingDefaultModelChange(
            provider: group.id,
            providerName: group.name,
            model: model.id,
            modelName: model.name,
            reasoningEffort: effortId,
            effortName: effortId.flatMap { id in efforts.first(where: { $0.id == id })?.name }
        )
    }

    private func selectEffort(_ effort: GatewayReasoningEffort, group: GatewayModelGroup, model: GatewayModelItem) {
        pendingChange = PendingDefaultModelChange(
            provider: group.id,
            providerName: group.name,
            model: model.id,
            modelName: model.name,
            reasoningEffort: effort.id,
            effortName: effort.name
        )
    }
}

private struct PendingDefaultModelChange: Identifiable {
    let id = UUID()
    let provider: String
    let providerName: String
    let model: String
    let modelName: String
    let reasoningEffort: String?
    let effortName: String?

    var summary: String {
        var text = "\(providerName) · \(modelName)"
        if let effortName { text += " · \(effortName)" }
        return text
    }
}

private struct DefaultModelCard: View {
    let group: GatewayModelGroup
    let model: GatewayModelItem
    let isSelected: Bool
    let currentEffort: String?
    let isBusy: Bool
    let onSelectModel: () -> Void
    let onSelectEffort: (GatewayReasoningEffort) -> Void

    private var efforts: [GatewayReasoningEffort] { model.reasoning?.efforts ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.name)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Spacer()
                if isSelected {
                    Text("当前使用")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.black, in: Capsule())
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if !isBusy { onSelectModel() } }

            if !efforts.isEmpty {
                HStack(spacing: 8) {
                    Text("思考等级")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(efforts) { effort in
                        let isCurrentEffort = isSelected && effort.id == currentEffort
                        Button {
                            onSelectEffort(effort)
                        } label: {
                            Text(effort.name)
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(isCurrentEffort ? Color.primary : Color.secondary.opacity(0.12), in: Capsule())
                                .foregroundStyle(isCurrentEffort ? Color(uiColor: .systemBackground) : .primary)
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(uiColor: .secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.primary : Color.secondary.opacity(0.18), lineWidth: isSelected ? 1.5 : 1)
        }
        .opacity(isBusy ? 0.7 : 1)
    }
}

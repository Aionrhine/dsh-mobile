import XCTest
import SwiftUI
import Combine
import AVFoundation
import DeepSeekHarnessShared
@testable import DeepSeekHarnessMobile

final class VoiceInputTests: XCTestCase {
    func testEndOfStreamPreservesBufferedTailSamples() throws {
        let source = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 1, interleaved: false))
        let target = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: true))
        let converter = try XCTUnwrap(AVAudioConverter(from: source, to: target))
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: source, frameCapacity: 1024))
        input.frameLength = 1024
        let samples = try XCTUnwrap(input.floatChannelData?[0])
        for index in 0..<1024 { samples[index] = index >= 1000 ? 0.7 : 0 }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 406))
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied { inputStatus.pointee = .noDataNow; return nil }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        XCTAssertNil(error)
        XCTAssertNotEqual(status, .error)
        let tail = try finishVoicePCMConversion(converter, format: target)
        XCTAssertGreaterThan(tail.count, 0, "仅使用 noDataNow 时末尾仍有未输出的采样")
        XCTAssertTrue(tail.contains { $0 != 0 }, "最后的有声样本必须被排空到提交的 PCM 中")
        let frames = Double(output.frameLength) + Double(tail.count / 2)
        XCTAssertEqual(frames, 1024.0 / 3, accuracy: 1)
        XCTAssertTrue(try finishVoicePCMConversion(converter, format: target).isEmpty)
    }

    func testSpeechSelectionIsDeliveredRawWithoutChatModelDecoding() throws {
        let json = #"{"kind":"speech-state","requestId":"watch","selection":{"providerId":"sensevoice-local","language":"zh"}}"#
        let decoded = try GatewayClient.decodeIncomingFrame(Data(json.utf8))
        XCTAssertNil(decoded.0)
        XCTAssertEqual(decoded.1, json)
        let error = #"{"kind":"error","requestType":"speech-transcribe","requestId":"record","message":"model unavailable"}"#
        XCTAssertEqual(try GatewayClient.decodeIncomingFrame(Data(error.utf8)).1, error)
        let ordinary = try GatewayClient.decodeIncomingFrame(Data(#"{"kind":"pong"}"#.utf8))
        XCTAssertEqual(ordinary.0?.kind, "pong")
        XCTAssertNil(ordinary.1)
    }

    @MainActor
    func testAdapterDoesNotPublishUnchangedSharedSnapshots() {
        let adapter = VoiceInputAdapter()
        var updates = 0
        let observation = adapter.$state.dropFirst().sink { _ in updates += 1 }
        adapter.keyboardChanged(false)
        adapter.keyboardChanged(true)
        adapter.keyboardChanged(true)
        adapter.keyboardChanged(false)
        XCTAssertEqual(updates, 2)
        XCTAssertEqual(adapter.state.hint, "输入内容或按住说话")
        withExtendedLifetime(observation) {}
    }

    @MainActor
    func testEmptySpeechUsesToastAndAutomaticallyDismissesWithoutEditingDraft() async throws {
        let (shared, token) = try recordingStore()
        _ = shared.release(nowMilliseconds: 1500)
        _ = shared.captureFinished(id: token, pcmBase64: Data(repeating: 0, count: 16000).base64EncodedString(), nowMilliseconds: 1501)
        let adapter = VoiceInputAdapter(shared: shared)
        var draftUpdates = 0
        adapter.onDraftUpdate = { _ in draftUpdates += 1 }
        adapter.accept("""
        {"kind":"speech-transcript","requestId":"\(token)","text":""}
        """)
        XCTAssertEqual(adapter.toastMessage, "未识别到人声")
        XCTAssertNil(adapter.state.alertMessage)
        XCTAssertNil(adapter.state.error)
        XCTAssertEqual(draftUpdates, 0)
        XCTAssertFalse(adapter.state.keyboardVisible)
        try await Task.sleep(for: .milliseconds(2150))
        XCTAssertNil(adapter.toastMessage)
    }

    @MainActor
    func testSlowMicrophoneStartupDoesNotBlockOverlayOrCancellation() async throws {
        let shared = SharedVoiceInputStore()
        _ = shared.open(context: "latency", currentDraft: "")
        let opening = shared.connectionChanged(connected: true, supported: true)
        let catalog = try XCTUnwrap(opening.requests.first { $0.requestType == "speech-catalog" }?.correlationId)
        _ = shared.acceptJson(json: """
        {"kind":"speech-catalog","requestId":"\(catalog)","available":true,"selection":{"providerId":"p"},"providers":[{"id":"p","preparation":{"phase":"ready"}}]}
        """)
        let startupFinished = expectation(description: "slow hardware completed")
        let hardwareStopped = expectation(description: "cancelled hardware cleaned up")
        let overlayAppeared = expectation(description: "overlay appears while hardware is still starting")
        let recorder = SlowVoiceRecorder(startupFinished: startupFinished, stopped: hardwareStopped)
        let voice = VoiceInputAdapter(shared: shared, recorder: recorder, requestPermission: { $0(true) })
        let controller = UIHostingController(rootView: VoiceLatencyHarness(voice: voice, appeared: { overlayAppeared.fulfill() }))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true; voice.leave() }
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let began = ProcessInfo.processInfo.systemUptime
        voice.press()
        await fulfillment(of: [overlayAppeared], timeout: 0.35)
        try await Task.sleep(for: .milliseconds(60))
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        XCTAssertLessThan(elapsed, 0.35, "蒙层与主线程不能等待耗时一秒的麦克风启动")
        XCTAssertEqual(voice.state.phase, "starting")
        XCTAssertFalse(recorder.startedOnMain)
        let image = UIGraphicsImageRenderer(size: window.bounds.size).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        let attachment = XCTAttachment(image: image)
        attachment.name = "硬件仍在启动时蒙层已出现"
        attachment.lifetime = .keepAlways
        add(attachment)
        voice.cancel()
        XCTAssertEqual(voice.state.phase, "idle")
        await fulfillment(of: [startupFinished, hardwareStopped], timeout: 2)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(voice.state.phase, "idle", "迟到的启动结果不能恢复已取消的录音")
        XCTAssertTrue(recorder.discarded)
        print("VoiceInputLatency iOS recognizedToResponsiveOverlay=\(Int(elapsed * 1000))ms simulatedHardwareStartup=1000ms")
    }

    private func recordingStore() throws -> (SharedVoiceInputStore, String) {
        let shared = SharedVoiceInputStore()
        _ = shared.open(context: "swift-test", currentDraft: "原草稿")
        let opening = shared.connectionChanged(connected: true, supported: true)
        let catalog = try XCTUnwrap(opening.requests.first { $0.requestType == "speech-catalog" }?.correlationId)
        _ = shared.acceptJson(json: """
        {"kind":"speech-catalog","requestId":"\(catalog)","available":true,"selection":{"providerId":"p","language":"zh"},"providers":[{"id":"p","preparation":{"phase":"ready"}}]}
        """)
        let token = try XCTUnwrap(shared.press(nowMilliseconds: 1000).effects.first { $0.action == "permission" }?.recordingId)
        _ = shared.permissionResult(id: token, granted: true, nowMilliseconds: 1001)
        _ = shared.captureStarted(id: token, nowMilliseconds: 1002)
        return (shared, token)
    }

    func testKotlinNativeTransitionFillsDraftWithoutAgentRequest() throws {
        let (shared, token) = try recordingStore()
        _ = shared.release(nowMilliseconds: 1500)
        let audio = Data(repeating: 0, count: 16000).base64EncodedString()
        let transition = shared.captureFinished(id: token, pcmBase64: audio, nowMilliseconds: 1501)
        XCTAssertEqual(transition.requests.first?.requestType, "speech-transcribe")
        let result = shared.acceptJson(json: """
        {"kind":"speech-transcript","requestId":"\(token)","text":"构建一个应用"}
        """)
        XCTAssertEqual(result.draftUpdate, "原草稿\n构建一个应用")
        XCTAssertEqual(result.snapshot.phase, "idle")
        XCTAssertTrue(result.requests.isEmpty)
    }

    @MainActor
    func testParticleOverlayRendersSpeechSilenceAndCancellation() throws {
        let (shared, token) = try recordingStore()
        let silent = shared.snapshot()
        for index in 0..<50 { _ = shared.level(id: token, rms: Float(0.01 + Double(index % 9) * 0.006), nowMilliseconds: Int64(2640 + index * 40)) }
        _ = shared.tick(nowMilliseconds: 4600)
        let speaking = shared.snapshot()
        _ = shared.pointerMoved(verticalDistance: -100)
        let cancellation = shared.snapshot()
        _ = shared.pointerMoved(verticalDistance: 0)
        for index in 0..<60 { _ = shared.level(id: token, rms: 0, nowMilliseconds: Int64(4640 + index * 40)) }
        let paused = shared.snapshot()
        XCTAssertTrue(paused.waveformActive)
        for scheme in [ColorScheme.light, .dark] {
            let theme = scheme == .dark ? "dark" : "light"
            for (name, snapshot) in [("speaking", speaking), ("cancel", cancellation), ("silent", silent), ("paused", paused)] {
                let renderer = ImageRenderer(content: VoiceRipplePanel(state: snapshot, stop: {})
                    .frame(width: 390, height: 844 * VoiceInputInteraction.shared.OVERLAY_HEIGHT_FRACTION)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.colorScheme, scheme))
                renderer.scale = 3
                let image = try XCTUnwrap(renderer.uiImage)
                XCTAssertEqual(image.size.height, 844 * VoiceInputInteraction.shared.OVERLAY_HEIGHT_FRACTION, accuracy: 1 / renderer.scale)
                let attachment = XCTAttachment(image: image)
                attachment.name = "voice-theme-\(theme)-\(name)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
        }
    }

    @MainActor
    func testUnchangedFocusMirrorCannotDismissNativeEditingBeforeSwiftUICommits() async throws {
        var committedFocus = false
        var pendingFocus: Bool?
        let representation = SlashCommandTextView(text: .constant("转写内容"), presentation: nil,
            placeholder: "", isFocused: Binding(get: { committedFocus }, set: { pendingFocus = $0 }))
        let coordinator = representation.makeCoordinator()
        let controller = UIViewController()
        let editor = CommandTextView(frame: CGRect(x: 20, y: 80, width: 330, height: 100))
        editor.delegate = coordinator
        controller.view.addSubview(editor)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        coordinator.synchronizeFocus(editor)
        XCTAssertTrue(editor.becomeFirstResponder())
        XCTAssertEqual(pendingFocus, true)
        // 原生短按已聚焦，Binding 的新值尚未进入 SwiftUI 下一帧。
        coordinator.synchronizeFocus(editor)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(editor.isFirstResponder, "普通刷新不能把上一帧的 false 当作主动失焦")
        committedFocus = true
        coordinator.synchronizeFocus(editor)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(editor.isFirstResponder)
        committedFocus = false
        coordinator.synchronizeFocus(editor)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(editor.isFirstResponder, "明确的收起输入操作仍须生效")
    }

    @MainActor
    func testConversationPageKeepsTranscriptEditableAfterLateKeyboardHide() async throws {
        let suiteName = "VoiceConversationFocus.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = UserDefaultsAppPreferences(userDefaults: defaults)
        preferences.automaticallyConnect = false
        let session = SessionSummary(id: "voice-focus-session", title: "语音焦点回归",
            lastActivity: Date(timeIntervalSince1970: 1), isRunning: false, hasUnread: false)
        preferences.saveSessions([session])
        let shared = SharedVoiceInputStore()
        let voice = VoiceInputAdapter(shared: shared)
        let appStore = AppStore(preferences: preferences, gatewayLocalID: suiteName, voiceInput: voice)
        defer { appStore.deactivateGateway() }
        let prepared = await appStore.prepareConversation(for: session)
        XCTAssertTrue(prepared)
        let controller = UIHostingController(rootView: ConversationView().environmentObject(appStore))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        let editor = try XCTUnwrap(voiceTextView(in: controller.view))
        // 真实页面和回调，不开启硬件、不连接远端；共享状态机产生合法的转写请求 ID。
        _ = shared.open(context: session.id, currentDraft: "")
        let opening = shared.connectionChanged(connected: true, supported: true)
        let catalogID = try XCTUnwrap(opening.requests.first { $0.requestType == "speech-catalog" }?.correlationId)
        _ = shared.acceptJson(json: """
        {"kind":"speech-catalog","requestId":"\(catalogID)","available":true,"selection":{"providerId":"p"},"providers":[{"id":"p","preparation":{"phase":"ready"}}]}
        """)
        let token = try XCTUnwrap(shared.press(nowMilliseconds: 1000).effects.first { $0.action == "permission" }?.recordingId)
        _ = shared.permissionResult(id: token, granted: true, nowMilliseconds: 1001)
        _ = shared.captureStarted(id: token, nowMilliseconds: 1002)
        _ = shared.release(nowMilliseconds: 1500)
        _ = shared.captureFinished(id: token, pcmBase64: Data(repeating: 0, count: 16000).base64EncodedString(), nowMilliseconds: 1501)
        voice.draftChanged("")
        try await Task.sleep(for: .milliseconds(30))
        voice.accept("""
        {"kind":"speech-transcript","requestId":"\(token)","text":"语音转写内容"}
        """)
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertEqual(editor.text, "语音转写内容")
        XCTAssertFalse(editor.isFirstResponder, "ASR 回填不得主动聚焦或弹出键盘")
        XCTAssertFalse(voice.state.keyboardVisible)
        // 用户点选后的原生聚焦才开始编辑，不能被后续刷新或隐藏通知打断。
        XCTAssertTrue(editor.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(editor.isFirstResponder)
        // 前一轮键盘收起回调晚于新编辑会话；它不能成为新的失焦请求。
        NotificationCenter.default.post(name: UIResponder.keyboardDidHideNotification, object: nil,
            userInfo: [UIResponder.keyboardFrameEndUserInfoKey: NSValue(cgRect: CGRect(x: 0, y: 844, width: 390, height: 0))])
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(editor.isFirstResponder, "迟到的隐藏通知不能夺走转写编辑焦点")
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.insertText("修改")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(editor.text, "语音转写内容修改")
        XCTAssertTrue(editor.isFirstResponder)
        // 正常结束编辑仍应生效，重新短按聚焦后继续修改。
        window.endEditing(true)
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(editor.isFirstResponder)
        XCTAssertTrue(editor.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(80))
        editor.insertText("继续")
        XCTAssertTrue(editor.isFirstResponder)
        XCTAssertTrue(editor.text.hasSuffix("继续"))
    }

    @MainActor
    func testTranscriptKeepsSameNativeEditorAndAllowsMarkedTextEditing() async throws {
        let (shared, token) = try recordingStore()
        _ = shared.release(nowMilliseconds: 1500)
        _ = shared.captureFinished(id: token, pcmBase64: Data(repeating: 0, count: 16000).base64EncodedString(), nowMilliseconds: 1501)
        let voice = VoiceInputAdapter(shared: shared)
        let fixture = VoiceEditorFixture(voice: voice)
        let controller = UIHostingController(rootView: VoiceEditorHarness(fixture: fixture))
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        let editor = try XCTUnwrap(voiceTextView(in: controller.view))
        voice.accept("""
        {"kind":"speech-transcript","requestId":"\(token)","text":"语音文字"}
        """)
        try await Task.sleep(for: .milliseconds(100))
        controller.view.layoutIfNeeded()
        XCTAssertTrue(editor === voiceTextView(in: controller.view))
        XCTAssertFalse(editor.isFirstResponder, "回填后等待用户点选，不请求焦点")
        XCTAssertFalse(fixture.focused)
        XCTAssertEqual(editor.text, "原草稿\n语音文字")
        XCTAssertTrue(editor.becomeFirstResponder())
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertTrue(editor.isFirstResponder)
        editor.selectedRange = NSRange(location: (editor.text as NSString).length, length: 0)
        editor.setMarkedText("xiugai", selectedRange: NSRange(location: 6, length: 0))
        XCTAssertNotNil(editor.markedTextRange)
        editor.unmarkText()
        editor.insertText("修改")
        XCTAssertTrue(editor.text.hasSuffix("xiugai修改"))
        XCTAssertTrue(editor.isFirstResponder)
    }
}

@MainActor
private final class VoiceEditorFixture: ObservableObject {
    let voice: VoiceInputAdapter
    @Published var draft = "原草稿"
    @Published var focused = false
    init(voice: VoiceInputAdapter) {
        self.voice = voice
        voice.onDraftUpdate = { [weak self] in self?.draft = $0 }
    }
}

private struct VoiceEditorHarness: View {
    @ObservedObject var fixture: VoiceEditorFixture
    var body: some View {
        VoiceComposerTextInput(text: $fixture.draft, isFocused: $fixture.focused, presentation: nil,
            state: fixture.voice.state, voice: fixture.voice)
            .frame(width: 350, height: 120)
    }
}

@MainActor
private func voiceTextView(in view: UIView) -> UITextView? {
    if let editor = view as? UITextView { return editor }
    return view.subviews.lazy.compactMap { voiceTextView(in: $0) }.first
}


private struct VoiceLatencyHarness: View {
    @ObservedObject var voice: VoiceInputAdapter
    let appeared: () -> Void
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.white
            if voice.state.active {
                VoiceRipplePanel(state: voice.state, stop: {})
                    .frame(height: 844 * VoiceInputInteraction.shared.OVERLAY_HEIGHT_FRACTION)
                    .transition(.opacity)
                    .onAppear(perform: appeared)
            }
        }
        .animation(voiceOverlayAnimation(active: voice.state.active), value: voice.state.active)
    }
}

/// 故意模拟一秒的同步硬件调用，用于发现主线程阻塞和启动期间取消的竞态。
private final class SlowVoiceRecorder: VoiceAudioCapturing, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var mainThread = false
    private var didDiscard = false
    private let startupFinished: XCTestExpectation
    private let stopped: XCTestExpectation
    init(startupFinished: XCTestExpectation, stopped: XCTestExpectation) {
        self.startupFinished = startupFinished
        self.stopped = stopped
    }
    var startedOnMain: Bool { lock.lock(); defer { lock.unlock() }; return mainThread }
    var discarded: Bool { lock.lock(); defer { lock.unlock() }; return didDiscard }
    func start(id: String, level: @escaping @Sendable (Float) -> Void, failure: @escaping @Sendable () -> Void) throws {
        lock.lock(); token = id; mainThread = Thread.isMainThread; lock.unlock()
        Thread.sleep(forTimeInterval: 1)
        startupFinished.fulfill()
    }
    func stop(id: String, discard: Bool) -> Data? {
        lock.lock()
        guard token == id else { lock.unlock(); return nil }
        token = nil; didDiscard = discard
        lock.unlock()
        stopped.fulfill()
        return discard ? nil : Data(repeating: 0, count: 16000)
    }
}

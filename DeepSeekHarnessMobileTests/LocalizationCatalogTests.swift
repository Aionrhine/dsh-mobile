import XCTest
@testable import DeepSeekHarnessMobile

/// Guards the localization catalogs shipped in the app bundle: compiled
/// tables must exist, stay populated, and keep placeholder arguments intact,
/// so the UI never exposes localization identifiers to users.
final class LocalizationCatalogTests: XCTestCase {

    private func localizedTable(_ name: String, localization: String) throws -> [String: String] {
        guard let path = Bundle.main.path(forResource: name,
                                          ofType: "strings",
                                          inDirectory: nil,
                                          forLocalization: localization),
              let dict = NSDictionary(contentsOfFile: path) as? [String: String] else {
            return [:]
        }
        return dict
    }

    private func englishTable(_ name: String) throws -> [String: String] {
        try localizedTable(name, localization: "en")
    }

    func testEnglishLocalizableTableIsPresentAndPopulated() throws {
        let table = try englishTable("Localizable")
        XCTAssertFalse(table.isEmpty, "en.lproj/Localizable.strings is missing from the app bundle")
        XCTAssertGreaterThanOrEqual(table.count, 600, "English Localizable table looks truncated")

        let blank = table.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        XCTAssertTrue(blank.isEmpty, "Blank English translations for: \(blank.keys.sorted())")
        XCTAssertEqual(table["语言"], "Language")
        XCTAssertEqual(table["语言设置将在重新启动应用后生效。"],
                       "Language changes take effect after restarting the app.")
        XCTAssertEqual(table["保存"], "Save")
        XCTAssertEqual(table["探索未至之境"], "Into the Unknown")
        XCTAssertEqual(table["编辑定时任务"], "Edit scheduled task")
        XCTAssertEqual(table["请连接网关后重试。"], "Connect to the gateway and try again.")
    }

    func testAppLanguagePersistsSystemAndExplicitLanguageChoices() throws {
        let suiteName = "AppLanguageTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(AppLanguage.load(from: defaults), .system)

        AppLanguage.english.apply(to: defaults)
        XCTAssertEqual(AppLanguage.load(from: defaults), .english)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["en"])

        AppLanguage.simplifiedChinese.apply(to: defaults)
        XCTAssertEqual(AppLanguage.load(from: defaults), .simplifiedChinese)
        XCTAssertEqual(defaults.stringArray(forKey: "AppleLanguages"), ["zh-Hans"])

        AppLanguage.system.apply(to: defaults)
        XCTAssertEqual(AppLanguage.load(from: defaults), .system)
        XCTAssertNil(defaults.persistentDomain(forName: suiteName)?["AppleLanguages"])
    }

    func testFormatSpecifiersSurviveTranslation() {
        let table = try! englishTable("Localizable")
        XCTAssertEqual(table["session.remote.title"], "Remote session %@")
        XCTAssertEqual(table["history.loaded.detail"], "%lld events%@%@")
        XCTAssertTrue(table["gateway.connected.detail"]?.contains("%lld") ?? false)
    }

    func testChineseRuntimeValuesDoNotExposeLocalizationKeys() throws {
        let table = try localizedTable("Localizable", localization: "zh-Hans")
        XCTAssertFalse(table.isEmpty, "zh-Hans.lproj/Localizable.strings is missing from the app bundle")
        XCTAssertEqual(table["context.items.count"], "%lld 项上下文")
        XCTAssertEqual(table["stats.turns.steps.line"], "%lld 轮 · %lld 步")
        XCTAssertEqual(table["projection.context-injection"], "上下文注入 · %@")
        XCTAssertEqual(table["assistant.interrupted"], "生成已中断")
        XCTAssertEqual(table["control.request.rejected"], "服务端未确认 %@ 请求。")
        XCTAssertEqual(table["Input"], "输入")
    }

    func testAgentNotificationCopyIsReadableInChinese() throws {
        let table = try localizedTable("Localizable", localization: "zh-Hans")
        XCTAssertEqual(table["agent.notification.approval.title"], "需要审批")
        XCTAssertEqual(table["agent.notification.approval.body"], "%@：%@")
        XCTAssertEqual(table["agent.notification.approval.body.generic"], "%@：Agent 请求批准本次操作")
        XCTAssertEqual(table["agent.notification.execution.completed.title"], "执行完成")
        XCTAssertEqual(table["agent.notification.execution.completed.body"], "%@：Agent 已完成本次任务")
        XCTAssertEqual(table["agent.notification.execution.failed.title"], "执行失败")
        XCTAssertEqual(table["agent.notification.execution.failed.body"], "%@：打开 App 查看执行结果")

        let sessionTitle = "模拟器测试会话"
        let chinese = Locale(identifier: "zh-Hans")
        XCTAssertEqual(
            String(
                localized: "agent.notification.execution.completed.title",
                defaultValue: "执行完成",
                bundle: .main,
                locale: chinese
            ),
            "执行完成"
        )
        XCTAssertEqual(
            String(
                localized: "agent.notification.execution.completed.body",
                defaultValue: "\(sessionTitle)：Agent 已完成本次任务",
                bundle: .main,
                locale: chinese
            ),
            "模拟器测试会话：Agent 已完成本次任务"
        )
    }

    func testScheduledTaskRuleResolvesInEnglish() throws {
        let weekdays = "Mon, Wed"
        let time = "08:00"
        let zone = "Asia/Shanghai"
        // The locale argument formats substitutions; the bundle chooses the translated table.
        let englishPath = try XCTUnwrap(Bundle.main.path(forResource: "en", ofType: "lproj"))
        let englishBundle = try XCTUnwrap(Bundle(path: englishPath))
        XCTAssertEqual(
            String(
                localized: "agent.notification.execution.completed.title",
                defaultValue: "执行完成",
                bundle: englishBundle,
                locale: Locale(identifier: "en")
            ),
            "Run completed"
        )
        XCTAssertEqual(
            String(localized: "schedule.weekly.detail", bundle: englishBundle, locale: Locale(identifier: "en")),
            "Every %@ at %@ · %@"
        )
        XCTAssertEqual(
            String(
                localized: "schedule.weekly.detail",
                defaultValue: "每周 \(weekdays) · \(time) · \(zone)",
                bundle: englishBundle,
                locale: Locale(identifier: "en")
            ),
            "Every Mon, Wed at 08:00 · Asia/Shanghai"
        )
    }

    func testEnglishInfoPlistStringsShipCameraAndLocalNetworkCopy() throws {
        let table = try englishTable("InfoPlist")
        XCTAssertNotNil(table["NSCameraUsageDescription"])
        XCTAssertNotNil(table["NSLocalNetworkUsageDescription"])
    }

    @MainActor
    func testCertificateAdviceOnlyAppearsForCertificateTrustFailures() throws {
        let chinese = try localizedTable("Localizable", localization: "zh-Hans")
        let english = try englishTable("Localizable")
        XCTAssertEqual(chinese["gateway.certificate-trust.advice"],
                       "如果确认这是安全的个人服务器，请在网关中更新公网配置，并确保其公网证书有效后重试。")
        XCTAssertTrue(english["gateway.certificate-trust.advice"]?.contains("public access configuration") == true)

        let certificateError = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted)
        let offlineError = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        XCTAssertNotNil(GatewayClient.certificateTrustAdvice(for: certificateError))
        XCTAssertNil(GatewayClient.certificateTrustAdvice(for: offlineError))
    }
}

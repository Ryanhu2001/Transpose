import Foundation

@main
struct NativeVerification {
    @MainActor
    static func main() async {
        // Keep assertions deterministic on Chinese and English CI hosts.
        // The argument domain is process-local and never changes saved settings.
        UserDefaults.standard.setVolatileDomain(["appLanguage": "simplifiedChinese"], forName: UserDefaults.argumentDomain)
        do {
            let start = Date()
            var checks = 0
            guard TargetLanguage.smart.resolved(for: "读书使人进步。") == "English",
                  TargetLanguage.smart.resolved(for: "A reliable, lightweight translator.") == "Simplified Chinese",
                  TargetLanguage.japanese.resolved(for: "Hello") == "Japanese" else {
                throw AppError.message("目标语言路由错误")
            }
            checks += 3
            checks += try await runBackendChecks()
            checks += try await runCaptureChecks()
            checks += try runCaptureInteractionChecks()
            checks += try runResultPlacementChecks()
            checks += try runAppleTranslationChecks()
            checks += try runPreferenceChecks()
            checks += try await runCLIChecks()
            checks += try runLocalizationChecks()
            checks += try runStartupChecks()
            checks += try runBridgeChecks()
            checks += try runPermissionRecoveryChecks()
            checks += try runSelectionChecks()
            checks += try await runSelectionDispatchChecks()
            let data = try JSONSerialization.data(withJSONObject: ["passed": checks, "elapsed": Date().timeIntervalSince(start), "networkRequests": 0], options: [.sortedKeys])
            print(String(data: data, encoding: .utf8)!)
        } catch {
            fputs("验证失败：\(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}

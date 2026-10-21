import Foundation
import ScreenCaptureKit

/// Fake NSError fixtures only: never call the screen service or alter TCC.
func runPermissionRecoveryChecks() throws -> Int {
    struct Failure: LocalizedError {
        let reason: String
        var errorDescription: String? { "权限恢复验证：" + reason }
    }
    func require(_ value: @autoclosure () -> Bool, _ reason: String) throws -> Int {
        guard value() else { throw Failure(reason: reason) }
        return 1
    }
    var checks = 0
    let denied = NSError(domain: SCStreamErrorDomain, code: -3801, userInfo: [NSLocalizedDescriptionKey: "private system diagnostic fixture"])
    checks += try require(SCStreamError.Code.userDeclined.rawValue == -3801, "SDK userDeclined 常量")
    checks += try require(CapturePermission.recovery(for: denied, preflightGranted: false) == .grantPermission, "未授权时引导权限设置")
    checks += try require(CapturePermission.recovery(for: denied, preflightGranted: true) == .restartApplication, "预检已允许但捕获拒绝时提示重启")
    for code in [-3802, -3803, -3807, -3817, -3821, 0] {
        let failure = NSError(domain: SCStreamErrorDomain, code: code)
        checks += try require(CapturePermission.recovery(for: failure, preflightGranted: false) == nil, "其他屏幕错误 \(code) 不归类权限")
        checks += try require(CapturePermission.recovery(for: failure, preflightGranted: true) == nil, "预检不能将其他错误 \(code) 变成重启")
    }
    let otherDomain = NSError(domain: NSCocoaErrorDomain, code: -3801)
    checks += try require(CapturePermission.recovery(for: otherDomain, preflightGranted: true) == nil, "相同错误码但不同域不触发权限恢复")
    let wrapped = NSError(domain: NSCocoaErrorDomain, code: 1, userInfo: [NSUnderlyingErrorKey: denied])
    checks += try require(CapturePermission.recovery(for: wrapped, preflightGranted: true) == nil, "不根据嵌套历史错误误判")
    checks += try require(CapturePermission.recovery(for: CancellationError(), preflightGranted: true) == nil, "取消不提示权限故障")
    checks += try require(NativeBridgeRequest.allows("app_restart", fromResult: false), "设置允许显式重启应用")
    checks += try require(!NativeBridgeRequest.allows("app_restart", fromResult: true), "译文 WebView 不能触发重启")
    let message = CapturePermission.message(for: .restartApplication)
    checks += try require(!message.contains("private system diagnostic fixture") && !message.contains(SCStreamErrorDomain) && !message.contains("-3801"), "恢复文案不暴露系统诊断详情")
    let previous = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    defer { UserDefaults.standard.setVolatileDomain(previous, forName: UserDefaults.argumentDomain) }
    UserDefaults.standard.setVolatileDomain(["appLanguage": "english"], forName: UserDefaults.argumentDomain)
    checks += try require(L10n.text(CapturePermission.restartMessage).contains("Restart Transpose"), "重启提示具备英文翻译")
    checks += try require(L10n.text(CapturePermission.grantMessage).contains("System Settings"), "授权提示具备英文翻译")
    UserDefaults.standard.setVolatileDomain(["appLanguage": "simplifiedChinese"], forName: UserDefaults.argumentDomain)
    checks += try require(L10n.text(CapturePermission.restartMessage) == CapturePermission.restartMessage, "中文提示保持中文")
    return checks
}

import Foundation
import ScreenCaptureKit

/// Classify the capture service's explicit authorization denial. Other screen
/// failures (no displays, stream startup, OCR, cancellation) retain their own
/// error handling and must never be presented as a permission problem.
enum CapturePermission {
    enum Recovery: Equatable {
        case grantPermission
        case restartApplication
    }

    static let restartMessage = "屏幕录制权限尚未生效。请重新启动 Transpose 后继续圈选。"
    static let grantMessage = "圈选需要屏幕录制权限。请在系统设置中允许 Transpose，再重新启动应用。"

    static func recovery(for error: Error, preflightGranted: Bool) -> Recovery? {
        let error = error as NSError
        guard error.domain == SCStreamErrorDomain,
              error.code == SCStreamError.Code.userDeclined.rawValue else { return nil }
        return preflightGranted ? .restartApplication : .grantPermission
    }

    static func message(for recovery: Recovery) -> String {
        switch recovery {
        case .grantPermission: return grantMessage
        case .restartApplication: return restartMessage
        }
    }
}

import AppKit
import Combine
import ServiceManagement

/// The system owns this state. In particular, a registered item that still
/// needs approval must never be presented as an enabled login item.
enum LoginItemStatus: Equatable {
    case notRegistered, enabled, requiresApproval, notFound

    var isEnabled: Bool { self == .enabled }
    var isRegistered: Bool { self == .enabled || self == .requiresApproval }
}

@MainActor
protocol LoginItemService {
    var status: LoginItemStatus { get }
    func register() throws
    func unregister() throws
    func openSystemSettings()
}

@MainActor
private struct SystemLoginItemService: LoginItemService {
    var status: LoginItemStatus {
        switch SMAppService.mainApp.status {
        case .notRegistered: return .notRegistered
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        @unknown default: return .notFound
        }
    }

    func register() throws { try SMAppService.mainApp.register() }
    func unregister() throws { try SMAppService.mainApp.unregister() }
    func openSystemSettings() { SMAppService.openSystemSettingsLoginItems() }
}

@MainActor
final class LoginItemManager: ObservableObject {
    enum Problem: Equatable {
        case system(String), didNotEnable, didNotDisable
    }

    @Published private(set) var status: LoginItemStatus
    @Published private(set) var problem: Problem?
    @Published private(set) var isUpdating = false
    private let service: any LoginItemService

    init(service: (any LoginItemService)? = nil) {
        let service = service ?? SystemLoginItemService()
        self.service = service
        status = service.status
    }

    func refresh() {
        let current = service.status
        if current != status {
            status = current
            problem = nil
        }
    }

    /// Called only in response to a deliberate settings interaction. Merely
    /// opening settings or launching the application never registers anything.
    func setEnabled(_ enabled: Bool) {
        guard !isUpdating else { return }
        refresh()
        problem = nil
        guard enabled ? !status.isRegistered : status.isRegistered else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            if enabled { try service.register() }
            else { try service.unregister() }
            refresh()
            if enabled && (status == .notRegistered || status == .notFound) {
                problem = .didNotEnable
            } else if !enabled && status.isRegistered {
                problem = .didNotDisable
            }
        } catch {
            refresh()
            problem = .system(error.localizedDescription)
        }
    }

    func openSystemSettings() { service.openSystemSettings() }
}

/// Launch Services attaches `keyAELaunchedAsLogInItem` to the open-application
/// event's `keyAEPropData` parameter for login launches. Capture this while
/// handling the launch event, before scheduling any asynchronous UI work.
enum ApplicationLaunchPolicy {
    static func isLoginItemLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        guard event?.eventClass == AEEventClass(kCoreEventClass),
              event?.eventID == AEEventID(kAEOpenApplication) else { return false }
        return event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    static func shouldShowSettings(isLoginItem: Bool, arguments: [String]) -> Bool {
        arguments.contains("--settings") || !isLoginItem
    }
}

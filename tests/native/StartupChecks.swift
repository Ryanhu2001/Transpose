import AppKit

/// All mutations go to an in-memory fake. These checks never register a real
/// login item, open System Settings, or modify the user's launch preferences.
@MainActor
private final class TestLoginItemService: LoginItemService {
    var status: LoginItemStatus = .notRegistered
    var registeredStatus: LoginItemStatus = .enabled
    var unregisteredStatus: LoginItemStatus = .notRegistered
    var registrationError: Error?
    var unregistrationError: Error?
    var registrations = 0
    var unregistrations = 0
    var settingsOpens = 0

    func register() throws {
        registrations += 1
        if let registrationError { throw registrationError }
        status = registeredStatus
    }

    func unregister() throws {
        unregistrations += 1
        if let unregistrationError { throw unregistrationError }
        status = unregisteredStatus
    }

    func openSystemSettings() { settingsOpens += 1 }
}

@MainActor
func runStartupChecks() throws -> Int {
    func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws -> Int {
        guard condition() else { throw AppError.message("启动设置验证失败：\(reason)") }
        return 1
    }
    func launchEvent(_ parameter: OSType? = nil, id: AEEventID = AEEventID(kAEOpenApplication)) -> NSAppleEventDescriptor {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id,
                                          targetDescriptor: nil, returnID: AEReturnID(kAutoGenerateReturnID),
                                          transactionID: AETransactionID(kAnyTransactionID))
        if let parameter {
            event.setParam(NSAppleEventDescriptor(enumCode: parameter), forKeyword: AEKeyword(keyAEPropData))
        }
        return event
    }

    var checks = 0
    checks += try require(!ApplicationLaunchPolicy.isLoginItemLaunch(nil), "无启动事件按手动启动处理")
    checks += try require(!ApplicationLaunchPolicy.isLoginItemLaunch(launchEvent()), "普通冷启动")
    checks += try require(ApplicationLaunchPolicy.isLoginItemLaunch(launchEvent(OSType(keyAELaunchedAsLogInItem))), "识别系统登录项启动")
    checks += try require(!ApplicationLaunchPolicy.isLoginItemLaunch(launchEvent(OSType(keyAELaunchedAsServiceItem))), "不混淆服务项事件")
    checks += try require(!ApplicationLaunchPolicy.isLoginItemLaunch(launchEvent(OSType(keyAELaunchedAsLogInItem), id: AEEventID(kAEReopenApplication))), "只识别open-application启动事件")
    checks += try require(ApplicationLaunchPolicy.shouldShowSettings(isLoginItem: false, arguments: ["Transpose"]), "每次手动冷启动显示设置")
    checks += try require(!ApplicationLaunchPolicy.shouldShowSettings(isLoginItem: true, arguments: ["Transpose"]), "登录启动保持菜单栏安静")
    checks += try require(ApplicationLaunchPolicy.shouldShowSettings(isLoginItem: true, arguments: ["Transpose", "--settings"]), "显式设置参数优先")

    let service = TestLoginItemService()
    let manager = LoginItemManager(service: service)
    manager.refresh()
    checks += try require(manager.status == .notRegistered && service.registrations == 0 && service.unregistrations == 0 && service.settingsOpens == 0, "初始化与刷新不改登录项")
    manager.setEnabled(false)
    checks += try require(service.unregistrations == 0, "已关闭时不重复注销")
    manager.setEnabled(true)
    checks += try require(manager.status.isEnabled && service.registrations == 1 && manager.problem == nil, "用户开启后读取系统状态")
    manager.setEnabled(true)
    checks += try require(service.registrations == 1, "已启用时不重复注册")
    service.status = .requiresApproval
    manager.refresh()
    checks += try require(manager.status == .requiresApproval && !manager.status.isEnabled, "系统撤销批准后不误显示已启用")
    manager.setEnabled(true)
    checks += try require(service.registrations == 1 && service.settingsOpens == 0, "待批准不循环注册或自动打开系统设置")
    manager.openSystemSettings()
    checks += try require(service.settingsOpens == 1, "仅显式点击打开系统设置")
    manager.setEnabled(false)
    checks += try require(service.unregistrations == 1 && manager.status == .notRegistered, "可取消待批准的登录项")

    service.registeredStatus = .requiresApproval
    manager.setEnabled(true)
    checks += try require(manager.status == .requiresApproval && !manager.status.isEnabled && manager.problem == nil, "注册成功仍待批准时开关保持关闭")
    manager.setEnabled(false)
    service.registrationError = NSError(domain: "Transpose.Verification", code: 1, userInfo: [NSLocalizedDescriptionKey: "registration denied"])
    manager.setEnabled(true)
    checks += try require(manager.status == .notRegistered && manager.problem == .system("registration denied") && !manager.isUpdating, "注册失败保留真实状态并反馈")
    service.registrationError = nil
    service.registeredStatus = .notRegistered
    manager.setEnabled(true)
    checks += try require(manager.problem == .didNotEnable && !manager.status.isEnabled, "系统未真正启用时不报成功")
    service.registeredStatus = .enabled
    manager.setEnabled(true)
    service.unregistrationError = NSError(domain: "Transpose.Verification", code: 2, userInfo: [NSLocalizedDescriptionKey: "unregistration denied"])
    manager.setEnabled(false)
    checks += try require(manager.status.isEnabled && manager.problem == .system("unregistration denied") && !manager.isUpdating, "注销失败保持已启用状态")
    service.unregistrationError = nil
    service.unregisteredStatus = .enabled
    manager.setEnabled(false)
    checks += try require(manager.problem == .didNotDisable && manager.status.isEnabled, "系统未真正关闭时不报成功")
    service.status = .notFound
    manager.refresh()
    checks += try require(manager.status == .notFound && !manager.status.isEnabled && manager.problem == nil, "系统状态变化刷新开关并清除过期错误")
    return checks
}

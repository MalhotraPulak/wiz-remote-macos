import Foundation
import ServiceManagement

@MainActor
final class LaunchAtLoginController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var requiresApproval = false
    @Published private(set) var statusNote: String?

    private let service = SMAppService.mainApp
    private let configuredKey = "didConfigureLaunchAtLogin"

    init(enableOnFirstLaunch: Bool = false) {
        refresh()

        if enableOnFirstLaunch, !UserDefaults.standard.bool(forKey: configuredKey) {
            UserDefaults.standard.set(true, forKey: configuredKey)
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.setEnabled(true)
            }
        }
    }

    func setEnabled(_ enabled: Bool) {
        statusNote = nil

        do {
            if enabled {
                switch service.status {
                case .enabled:
                    break
                case .requiresApproval:
                    requiresApproval = true
                    statusNote = "Approve WiZ Remote in System Settings → General → Login Items."
                    SMAppService.openSystemSettingsLoginItems()
                case .notRegistered, .notFound:
                    try service.register()
                @unknown default:
                    try service.register()
                }
            } else if service.status != .notRegistered {
                try service.unregister()
            }
        } catch {
            statusNote = error.localizedDescription
        }

        refresh()
    }

    func openLoginItemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func refresh() {
        let status = service.status
        isEnabled = status == .enabled
        requiresApproval = status == .requiresApproval

        if requiresApproval, statusNote == nil {
            statusNote = "Approval is required in macOS Login Items."
        }
    }
}

import SwiftUI

/// Microphone and Accessibility with their live status, shared by Settings and onboarding.
/// The status comes from a `PermissionMonitor` that the screen polls while visible.
struct PermissionsSettingsSection: View {
    let context: SettingsContext

    var body: some View {
        Section("Permissions") {
            ForEach(Permission.allCases) { permission in
                PermissionRow(
                    permission: permission,
                    status: context.status(of: permission),
                    onRequest: { context.requestPermission(permission) }
                )
            }
        }
    }
}

struct PermissionRow: View {
    let permission: Permission
    let status: PermissionStatus
    let onRequest: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: permission.systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(permission.title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            switch status {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .notDetermined:
                Button("Grant", action: onRequest)
            case .denied:
                Button("Open Settings…", action: onRequest)
            }
        }
    }

    private var detail: String {
        switch status {
        case .granted, .notDetermined:
            return permission.reason
        case .denied:
            return "\(permission.reason) Turn on \(BuildFlavor.current.displayName) in System Settings › Privacy & Security › \(permission.title)."
        }
    }
}

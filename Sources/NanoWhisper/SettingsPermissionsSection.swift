import SwiftUI

// MARK: - Settings pane

/// Settings › Permissions: the two permissions with their live status (polled while the pane
/// is visible) and the one action each needs.
struct PermissionsPane: View {
    let context: SettingsContext

    var body: some View {
        SettingsPaneForm {
            SettingsSection {
                ForEach(Permission.allCases) { permission in
                    if permission != Permission.allCases.first {
                        GroupedRowDivider()
                    }
                    PermissionPaneRow(
                        permission: permission,
                        status: context.status(of: permission),
                        onRequest: { context.requestPermission(permission) }
                    )
                    .settingsRow()
                }
            } header: {
                Text("Access")
            } footer: {
                SettingsCaption("Both update by themselves when you change them in System Settings.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension Permission {
    /// Settings › Permissions wording. Accessibility is named by what it does for the user.
    var paneTitle: String {
        switch self {
        case .microphone: return "Microphone"
        case .accessibility: return "Typing in other apps"
        }
    }

    var paneTag: String {
        switch self {
        case .microphone: return "Required"
        case .accessibility: return "Recommended"
        }
    }

    var paneDetail: String {
        switch self {
        case .microphone:
            return "Used only while you dictate. Audio never leaves this Mac."
        case .accessibility:
            return "Pastes the text where you type. Without it, nothing is pasted; the text is kept in History if it is on. macOS calls this Accessibility."
        }
    }

    var paneSystemImage: String {
        switch self {
        case .microphone: return "mic"
        case .accessibility: return "character.cursor.ibeam"
        }
    }

    /// Button for a permission that is not granted: the system request, or System Settings.
    static func actionTitle(for status: PermissionStatus) -> String? {
        switch status {
        case .granted: return nil
        case .notDetermined: return "Allow…"
        case .denied: return "Open System Settings"
        }
    }
}

private struct PermissionPaneRow: View {
    let permission: Permission
    let status: PermissionStatus
    let onRequest: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.paneSystemImage)
                .font(.system(size: 15))
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.paneTitle)
                    Text(permission.paneTag)
                        .font(.caption)
                        .fontWeight(permission == .microphone ? .semibold : .medium)
                        .foregroundStyle(permission == .microphone ? .primary : .secondary)
                }
                SettingsCaption(permission.paneDetail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status.isGranted {
                Label("Allowed", systemImage: "checkmark")
                    .font(.callout)
                    .foregroundStyle(.green)
            } else {
                VStack(alignment: .trailing, spacing: 6) {
                    Text("Not allowed")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    if let title = Permission.actionTitle(for: status) {
                        Button(title, action: onRequest)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }
}

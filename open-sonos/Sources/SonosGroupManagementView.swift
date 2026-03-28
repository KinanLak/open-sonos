import SwiftUI

struct SonosGroupManagementView: View {
    let store: SonosStore

    var body: some View {
        if store.selectedGroupManagementOptions.isEmpty {
            Text("No speakers available to manage.")
                .foregroundStyle(.secondary)
        } else {
            ForEach(store.selectedGroupManagementOptions) { option in
                HStack {
                    Text(option.player.name)

                    if option.isCoordinator {
                        Image(systemName: "star.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Text(option.statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let actionLabel = option.actionLabel {
                        Button(actionLabel) {
                            store.groupManagementActionTapped(option)
                        }
                        .disabled(store.isPerformingAction)
                    }
                }
            }
        }
    }
}

import SwiftUI

struct SonosGroupManagementView: View {
    let store: SonosStore
    let group: SonosGroupModel
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                if store.selectedGroupManagementOptions.isEmpty {
                    Text("No speakers available to manage right now.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(store.selectedGroupManagementOptions) { option in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.player.name)
                                    .font(.subheadline.weight(.medium))

                                Text(option.statusLabel)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            if let actionLabel = option.actionLabel {
                                Button(actionLabel) {
                                    store.groupManagementActionTapped(option)
                                }
                                .buttonStyle(.bordered)
                                .disabled(store.isPerformingAction)
                            } else {
                                Text(option.statusLabel)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack {
                Text("Group")
                    .font(.subheadline.weight(.semibold))

                Spacer()

                Text(group.playerSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

import SwiftUI

struct ShortcutRecorderView: View {
    @Binding var keyCombo: KeyCombo?
    let hotkeyManager: HotkeyManager

    @State private var isRecording = false
    @State private var localMonitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            if keyCombo != nil && !isRecording {
                Button {
                    keyCombo = nil
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                }
                .buttonStyle(.plain)
                .help("Clear shortcut")
            }

            Button {
                if isRecording {
                    stopRecording()
                } else {
                    startRecording()
                }
            } label: {
                Group {
                    if isRecording {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(.red)
                                .frame(width: 6, height: 6)
                            Text("Type shortcut\u{2026}")
                                .foregroundStyle(.primary)
                        }
                    } else if let combo = keyCombo {
                        Text(combo.displayString)
                            .font(.system(.body, design: .rounded).weight(.medium))
                    } else {
                        Text("Record Shortcut")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 140, alignment: .center)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .onDisappear {
            if isRecording { stopRecording() }
        }
    }

    private func startRecording() {
        isRecording = true
        hotkeyManager.pause()

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }

            let flags = event.modifierFlags.intersection([.command, .option, .shift, .control])
            guard !flags.isEmpty else { return nil }

            keyCombo = KeyCombo(keyCode: event.keyCode, modifierFlags: event.modifierFlags)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        localMonitor = nil
        hotkeyManager.resume()
    }
}

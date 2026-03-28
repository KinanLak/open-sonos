import Carbon.HIToolbox
import Foundation
import Observation

private nonisolated(unsafe) weak var activeHotkeyManager: HotkeyManager?

private func carbonHotkeyCallback(
    _: EventHandlerCallRef?,
    event: EventRef?,
    _: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let id = hotKeyID.id
    Task { @MainActor in
        activeHotkeyManager?.handleHotKey(id: id)
    }

    return noErr
}

@MainActor
@Observable
final class HotkeyManager {
    private static let hotkeySignature: FourCharCode = 0x4F534E4F // "OSNO"
    private static let defaultsKey = "hotkeyBindings"

    var bindings: [HotkeyAction: KeyCombo] = [:]

    @ObservationIgnored private var registeredHotKeys: [UInt32: (ref: EventHotKeyRef, action: HotkeyAction)] = [:]
    @ObservationIgnored private var nextID: UInt32 = 1
    @ObservationIgnored private var eventHandlerRef: EventHandlerRef?
    @ObservationIgnored private let userDefaults: UserDefaults
    @ObservationIgnored private var isPaused = false

    @ObservationIgnored var onAction: ((HotkeyAction) -> Void)?

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        activeHotkeyManager = self
        loadBindings()
        installCarbonHandler()
        registerAll()
    }

    func setBinding(_ combo: KeyCombo?, for action: HotkeyAction) {
        if let combo {
            for (existingAction, existingCombo) in bindings where existingCombo == combo && existingAction != action {
                bindings.removeValue(forKey: existingAction)
            }
            bindings[action] = combo
        } else {
            bindings.removeValue(forKey: action)
        }

        persistBindings()
        unregisterAll()
        if !isPaused { registerAll() }
    }

    func pause() {
        isPaused = true
        unregisterAll()
    }

    func resume() {
        isPaused = false
        registerAll()
    }

    func handleHotKey(id: UInt32) {
        guard let entry = registeredHotKeys[id] else { return }
        onAction?(entry.action)
    }

    // MARK: - Carbon Event Handler

    private func installCarbonHandler() {
        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            carbonHotkeyCallback,
            1,
            &eventSpec,
            nil,
            &eventHandlerRef
        )
    }

    private func registerAll() {
        for (action, combo) in bindings {
            let id = nextID
            nextID += 1

            let hotKeyID = EventHotKeyID(signature: Self.hotkeySignature, id: id)
            var hotKeyRef: EventHotKeyRef?

            let status = RegisterEventHotKey(
                UInt32(combo.keyCode),
                combo.carbonModifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            if status == noErr, let ref = hotKeyRef {
                registeredHotKeys[id] = (ref, action)
            }
        }
    }

    private func unregisterAll() {
        for (_, entry) in registeredHotKeys {
            UnregisterEventHotKey(entry.ref)
        }
        registeredHotKeys.removeAll()
    }

    // MARK: - Persistence

    private func loadBindings() {
        guard let data = userDefaults.data(forKey: Self.defaultsKey),
              let decoded = try? JSONDecoder().decode([String: KeyCombo].self, from: data)
        else { return }

        for (rawAction, combo) in decoded {
            if let action = HotkeyAction(rawValue: rawAction) {
                bindings[action] = combo
            }
        }
    }

    private func persistBindings() {
        let encoded = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encoded) {
            userDefaults.set(data, forKey: Self.defaultsKey)
        }
    }
}

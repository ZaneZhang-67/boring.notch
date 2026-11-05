import AppKit
import Carbon

@MainActor
final class ClipboardHotKey {
    static let shared = ClipboardHotKey()

    private static let signature: OSType = 0x424E434C // "BNCL"
    private static let hotKeyID: UInt32 = 1

    private var hotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private var action: (() -> Void)?

    private init() {}

    deinit {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(action: @escaping () -> Void) throws {
        unregister()
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard status == noErr,
                      identifier.signature == ClipboardHotKey.signature,
                      identifier.id == ClipboardHotKey.hotKeyID else {
                    return OSStatus(eventNotHandledErr)
                }

                let owner = Unmanaged<ClipboardHotKey>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in owner.action?() }
                return noErr
            },
            1,
            &eventType,
            pointer,
            &eventHandler
        )
        guard handlerStatus == noErr else {
            throw HotKeyError.eventHandlerRegistrationFailed(handlerStatus)
        }

        var registeredHotKey: EventHotKeyRef?
        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_Semicolon),
            UInt32(cmdKey),
            EventHotKeyID(signature: Self.signature, id: Self.hotKeyID),
            GetApplicationEventTarget(),
            0,
            &registeredHotKey
        )
        guard registrationStatus == noErr, let registeredHotKey else {
            if let eventHandler {
                RemoveEventHandler(eventHandler)
                self.eventHandler = nil
            }
            throw HotKeyError.hotKeyRegistrationFailed(registrationStatus)
        }

        hotKey = registeredHotKey
        NSLog(
            "[ClipboardHotKey] registered Command+; keyCode=%d modifiers=%d",
            kVK_ANSI_Semicolon,
            cmdKey
        )
    }

    func unregister() {
        if let hotKey {
            UnregisterEventHotKey(hotKey)
            self.hotKey = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
        action = nil
    }
}

enum HotKeyError: LocalizedError {
    case eventHandlerRegistrationFailed(OSStatus)
    case hotKeyRegistrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .eventHandlerRegistrationFailed(let status):
            return "Unable to install clipboard hotkey event handler (OSStatus \(status))."
        case .hotKeyRegistrationFailed(let status):
            return "Unable to register the clipboard history shortcut (OSStatus \(status))."
        }
    }
}

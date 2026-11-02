import Foundation

/// How "Keep my cartridges working" turned out.
public enum CartridgeGuardOutcome: Sendable {
    /// Automatic updates were off already: nothing was written.
    case alreadyOff
    /// Written, and the printer reads back Off.
    case done
    /// Written, but the printer reads back another mode, or nothing.
    case notKept
    /// The printer doesn't let apps change the setting: nothing was written.
    case cantChange
}

/// What was done, in plain words, and the mode the printer reads back (nil when it said nothing).
public struct CartridgeGuardResult: Equatable, Sendable {
    public var outcome: CartridgeGuardOutcome
    public var readBack: FirmwareUpdateMode?
    public var text: String
}

/// "Keep my cartridges working" (roadmap 1.5; the Windows Core's `CartridgeGuard`): one button on an HP printer's Firmware
/// card that sets automatic firmware updates Off, so an HP update with "dynamic security" (which stops cartridges with non-HP
/// chips) never installs by itself, then reads the setting back and says what it did. The write is the Firmware card's own
/// Off write, byte for byte (`LedmClient.setFirmwareUpdate`). Off rather than "check, don't install": some printers install
/// when only the check is on (the LaserJet MFP M234dw does).
public enum CartridgeGuard {
    /// - Parameters:
    ///   - settings: as read just before (`LedmClient.firmwareUpdate`).
    ///   - withAuth: runs the write, asking for the admin password when the printer wants it (the settings' own way).
    public static func keepCartridgesWorking(_ ledm: LedmClient, _ settings: FirmwareUpdateSettings,
                                             withAuth: (@Sendable () async throws -> Void) async throws -> Void) async throws -> CartridgeGuardResult {
        if settings.mode == .off {
            return CartridgeGuardResult(outcome: .alreadyOff, readBack: .off,
                                        text: "Automatic firmware updates are already off on this printer, so no update installs by itself. Nothing was changed.")
        }
        guard settings.canChange, settings.choices.contains(.off), settings.configPath != nil else {
            return CartridgeGuardResult(outcome: .cantChange, readBack: settings.mode,
                                        text: "This printer doesn't let apps change its automatic firmware updates. Turn them off on its web page, under the firmware update settings.")
        }
        try await withAuth { try await ledm.setFirmwareUpdate(.off, in: settings) }
        let back = try await ledm.firmwareUpdate()
        switch back?.mode {
        case .off?:
            return CartridgeGuardResult(outcome: .done, readBack: .off,
                                        text: "Done: automatic firmware updates are off, and the printer confirms it. A firmware update now installs only if you "
                                            + "install it yourself, from the printer's web page or its control panel.")
        case let other?:
            return CartridgeGuardResult(outcome: .notKept, readBack: other,
                                        text: "The printer was asked to turn automatic updates off, but it reads back \"\(words(other))\". Turn them off on its web page.")
        case nil:
            return CartridgeGuardResult(outcome: .notKept, readBack: nil,
                                        text: "The printer took the change but didn't say what it kept. Check its firmware update settings on its web page.")
        }
    }

    private static func words(_ mode: FirmwareUpdateMode) -> String {
        switch mode {
        case .automatic: "install automatically"
        case .notify: "check, don't install"
        case .off: "off"
        }
    }
}

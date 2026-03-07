// ConsumerKeys.swift
// Boot-protocol keyboard that reports keycodes in Consumer page (0x0C).
// iOS maps consumer page usages received this way to system actions.

import Foundation

public final class ConsumerKeys: SyntheticHID {

    // MARK: - Consumer usages sent as boot-keyboard keycodes (page 0x0C, ≤ 0xFF)

    public enum Key: UInt8 {
        case acHome     = 0x40   // Consumer "Menu" → iOS home button
        case mute       = 0xE2
        case volumeUp   = 0xE9
        case volumeDown = 0xEA
        case playPause  = 0xCD
        case nextTrack  = 0xB5
        case prevTrack  = 0xB6
    }

    // MARK: - Init

    public init() {
        super.init(
            reportDescriptor: Self.reportDescriptor,
            reportSize: 8,
            vendorID: 0x05AC,
            productID: 0x0002,
            manufacturer: "Apple Inc.",
            product: "Virtual Consumer Control",
            interfaceSubClass: 0x01,
            interfaceProtocol: 0x01)
    }

    // MARK: - Key injection

    public func keyDown(_ key: Key) {
        sendReport([0, 0, key.rawValue, 0, 0, 0, 0, 0])
    }

    public func keyUp() {
        clearReport()
    }

    // MARK: - Report descriptor
    // Minimal boot-keyboard shell with Consumer page (0x0C) keycodes.

    private static let reportDescriptor: [UInt8] = [
        0x05, 0x0C,  // Usage Page (Consumer)
        0x09, 0x01,  // Usage (Consumer Control)
        0xA1, 0x01,  // Collection (Application)
        0x19, 0x00,  //   Usage Minimum (0)
        0x29, 0xFF,  //   Usage Maximum (255)
        0x15, 0x00,  //   Logical Minimum (0)
        0x25, 0xFF,  //   Logical Maximum (255)
        0x75, 0x08,  //   Report Size (8)
        0x95, 0x08,  //   Report Count (8)
        0x81, 0x00,  //   Input (Data, Array)
        0xC0,        // End Collection
    ]
}

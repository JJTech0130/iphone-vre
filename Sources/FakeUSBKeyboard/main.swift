// fake-usb-keyboard
// Instantiates a synthetic USB HID keyboard via IOUSBHostControllerInterface.
//
// Requirements:
//   • macOS 11+ (Big Sur)
//   • Signed with entitlement: com.apple.developer.usb.host-controller-interface
//
// Usage:
//   fake-usb-keyboard            – start the virtual keyboard, type keys from stdin
//   fake-usb-keyboard --demo     – type a short demo string then exit

import FakeUSBKeyboardLib
import Foundation

// Simple arg parsing
let isDemo = CommandLine.arguments.contains("--demo")

let keyboard = FakeHIDKeyboard()
do {
    try keyboard.start()
} catch {
    fputs("Failed to start fake keyboard: \(error)\n", stderr)
    exit(1)
}

print("[fake-usb-keyboard] Virtual HID keyboard running.")
print("[fake-usb-keyboard] The device will appear in System Information → USB after enumeration.")
print("[fake-usb-keyboard] Use USB passthrough in your VM to attach it to the guest.")

if isDemo {
    // Give the host time to enumerate the device
    Thread.sleep(forTimeInterval: 2.0)
    print("[fake-usb-keyboard] Typing demo text: 'hello'")

    let demoKeys: [(HIDKeycode, UInt8)] = [
        (.h, 0), (.e, 0), (.l, 0), (.l, 0), (.o, 0),
        (.space, 0),
        (.w, 0), (.o, 0), (.r, 0), (.l, 0), (.d, 0),
        (.returnKey, 0),
    ]
    for (key, mods) in demoKeys {
        keyboard.typeKey(key, modifiers: mods)
        Thread.sleep(forTimeInterval: 0.05)
    }
    Thread.sleep(forTimeInterval: 0.5)
    keyboard.stop()
    print("[fake-usb-keyboard] Demo complete.")
    exit(0)
}

// Interactive mode: read lines from stdin and type them as keypresses
print("[fake-usb-keyboard] Interactive mode — type text and press Enter. Ctrl-D to quit.")

// Mapping from ASCII characters to (HIDKeycode, needsShift)
let asciiToHID: [Character: (HIDKeycode, Bool)] = {
    var m: [Character: (HIDKeycode, Bool)] = [:]
    // a-z
    let letters: [(Character, HIDKeycode)] = [
        ("a", .a), ("b", .b), ("c", .c), ("d", .d), ("e", .e),
        ("f", .f), ("g", .g), ("h", .h), ("i", .i), ("j", .j),
        ("k", .k), ("l", .l), ("m", .m), ("n", .n), ("o", .o),
        ("p", .p), ("q", .q), ("r", .r), ("s", .s), ("t", .t),
        ("u", .u), ("v", .v), ("w", .w), ("x", .x), ("y", .y), ("z", .z),
    ]
    for (ch, kc) in letters {
        m[ch] = (kc, false)
        m[Character(ch.uppercased())] = (kc, true)
    }
    // 0-9
    let digits: [(Character, HIDKeycode)] = [
        ("0", .num0), ("1", .num1), ("2", .num2), ("3", .num3), ("4", .num4),
        ("5", .num5), ("6", .num6), ("7", .num7), ("8", .num8), ("9", .num9),
    ]
    for (ch, kc) in digits { m[ch] = (kc, false) }
    m[" "] = (.space, false)
    m["\n"] = (.returnKey, false)
    m["\t"] = (.tab, false)
    return m
}()

while let line = readLine(strippingNewline: false) {
    for ch in line {
        if let (keycode, needsShift) = asciiToHID[ch] {
            let mods: UInt8 = needsShift ? HIDModifier.leftShift.rawValue : 0
            keyboard.typeKey(keycode, modifiers: mods)
        }
    }
}

keyboard.stop()
print("[fake-usb-keyboard] Exiting.")

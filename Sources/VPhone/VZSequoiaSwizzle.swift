import AppKit
import Foundation
import ObjectiveC

let noop: @convention(c) (AnyObject, Selector) -> Void = { _, _ in }

public enum VZSequoiaSwizzle {
    public static func install() {
        noopCursorHide()
        noopNotifierLock()
    }

    // VzCore::Hardware::Usb::Darwin::usb_device_service_has_hid_pointing_device_interface incorrectly identifies
    // all HID devices as pointing devices, which causes the view to hide the cursor
    // HACK: swizzle all [NSCursor hide] calls (even legitimate ones...)
    private static func noopCursorHide() {
        guard let m = class_getClassMethod(NSCursor.self, NSSelectorFromString("hide")) else {
            return
        }
        method_setImplementation(m, unsafeBitCast(noop, to: IMP.self))
    }

    // IOUSBHostInterestNotifier uses an NSRecursiveLock to serialise interest notification delivery
    // Something that calls [IOUSBHostInterestNotifier destroy] which acquires that lock and causes a deadlock
    // HACK: simply swizzle it to return a fake lock object
    private static func noopNotifierLock() {
        guard let cls = NSClassFromString("IOUSBHostInterestNotifier"),
            let parentCls = NSClassFromString("NSRecursiveLock")
        else { return }

        for sel in [NSSelectorFromString("lock"), NSSelectorFromString("unlock")] {
            let enc = class_getInstanceMethod(parentCls, sel).flatMap { method_getTypeEncoding($0) }
            if !class_addMethod(cls, sel, unsafeBitCast(noop, to: IMP.self), enc),
                let m = class_getInstanceMethod(cls, sel)
            {
                method_setImplementation(m, unsafeBitCast(noop, to: IMP.self))
            }
        }
    }
}

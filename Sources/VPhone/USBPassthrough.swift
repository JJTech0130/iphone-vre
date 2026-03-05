import Darwin
import Dynamic
import Foundation
import IOKit
import ObjectiveC.runtime
import Virtualization

// let kFakeKeyboardVendorID  = 0x05AC
// let kFakeKeyboardProductID = 0x0001
let kFakeKeyboardVendorID = 0x1050
let kFakeKeyboardProductID = 0x0407

// Typed objc_msgSend wrappers obtained via dlsym to bypass Swift's
// "variadic function unavailable" restriction on the overlay symbol.
private typealias AllocFn = @convention(c) (AnyObject, Selector) -> Unmanaged<AnyObject>
private typealias InitWithServiceFn = @convention(c) (
    AnyObject, Selector,
    io_service_t, UnsafeMutableRawPointer?
) -> Unmanaged<AnyObject>?
private typealias InitWithConfigFn = @convention(c) (
    AnyObject, Selector,
    AnyObject, UnsafeMutableRawPointer?
) -> Unmanaged<AnyObject>?

/// Resolves `objc_msgSend` at runtime so we can safely reinterpret it as
/// a typed C function pointer.
private nonisolated(unsafe) let _msgSendPtr: UnsafeMutableRawPointer = {
    dlsym(dlopen(nil, RTLD_LAZY), "objc_msgSend")!
}()
private func msgSend<T>(_ type: T.Type) -> T { unsafeBitCast(_msgSendPtr, to: type) }

private let selAlloc = NSSelectorFromString("alloc")
private let selInitWithService = NSSelectorFromString("initWithService:error:")
private let selInitWithConfig  = NSSelectorFromString("initWithConfiguration:error:")

extension VPhoneVM {
    /// Waits for the fake keyboard to appear in IOKit, authorizes it,
    /// and passes it through to the guest via private Virtualization API.
    @MainActor
    func attachFakeKeyboardToGuest() async {
        guard let controller = virtualMachine.usbControllers.first else {
            print("[vphone] USB passthrough: no USB controller configured")
            return
        }

        print("[vphone] USB passthrough: waiting for fake keyboard IOKit service…")
        guard let service = await pollForUSBService(vendor: kFakeKeyboardVendorID,
                                                    product: kFakeKeyboardProductID) else {
            print("[vphone] USB passthrough: timed out — dumping all USB devices in IOKit:")
            //dumpUSBDevices()
            return
        }
        defer { IOObjectRelease(service) }
        print(String(format: "[vphone] USB passthrough: found service 0x%x", service))

        // Authorize for capture
        let kr = IOServiceAuthorize(service, IOOptionBits(kPrompt))
        if kr != kIOReturnSuccess {
            let errStr = String(cString: mach_error_string(kr))
            print(String(format: "[vphone] IOServiceAuthorize failed: 0x%x (%@)", kr, errStr))
        }

        // _VZIOUSBHostPassthroughDeviceConfiguration
        // initWithService:error: takes io_service_t (UInt32 scalar), so we use
        // a typed objc_msgSend cast instead of Dynamic to pass the scalar correctly.
        guard let cfgCls = NSClassFromString("_VZIOUSBHostPassthroughDeviceConfiguration") else {
            print("[vphone] _VZIOUSBHostPassthroughDeviceConfiguration not found")
            return
        }
        let allocFn  = msgSend(AllocFn.self)
        let cfgAlloc = allocFn(cfgCls as AnyObject, selAlloc).takeRetainedValue()

        let initSvcFn = msgSend(InitWithServiceFn.self)
        guard let cfgObj = initSvcFn(cfgAlloc, selInitWithService, service, nil)?.takeRetainedValue() else {
            print("[vphone] _VZIOUSBHostPassthroughDeviceConfiguration init returned nil")
            return
        }

        // _VZIOUSBHostPassthroughDevice
        guard let devCls = NSClassFromString("_VZIOUSBHostPassthroughDevice") else {
            print("[vphone] _VZIOUSBHostPassthroughDevice not found")
            return
        }
        let devAlloc   = allocFn(devCls as AnyObject, selAlloc).takeRetainedValue()
        let initCfgFn  = msgSend(InitWithConfigFn.self)
        guard let devObj = initCfgFn(devAlloc, selInitWithConfig, cfgObj, nil)?.takeRetainedValue() else {
            print("[vphone] _VZIOUSBHostPassthroughDevice init returned nil")
            return
        }
        guard let device = devObj as? VZUSBDevice else {
            print("[vphone] _VZIOUSBHostPassthroughDevice is not VZUSBDevice")
            return
        }

        // Attach to the running VM
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                controller.attach(device: device) { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            }
            print("[vphone] Fake keyboard attached to guest VM via passthrough")
        } catch {
            print("[vphone] Failed to attach fake keyboard to guest: \(error)")
        }
    }

    private func pollForUSBService(vendor: Int, product: Int,
                                   timeout: TimeInterval = 10) async -> io_service_t? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let svc = lookupUSBService(vendor: vendor, product: product) { return svc }
            try? await Task.sleep(nanoseconds: 500_000_000)
        } while Date() < deadline
        return nil
    }

    private func lookupUSBService(vendor: Int, product: Int) -> io_service_t? {
        // Try both new and old IOKit USB class names
        for className in ["IOUSBHostDevice"] {
            let matching = IOServiceMatching(className) as NSMutableDictionary
            matching["idVendor"]  = vendor
            matching["idProduct"] = product
            let svc = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            if svc != IO_OBJECT_NULL {
                print("[vphone] lookupUSBService: found via class '\(className)'")
                return svc
            }
        }
        return nil
    }

    /// Dump all IOUSBHostDevice / IOUSBDevice entries to help diagnose matching failures.
    func dumpUSBDevices() {
        for className in ["IOUSBHostDevice", "IOUSBDevice"] {
            var iter: io_iterator_t = 0
            guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                              IOServiceMatching(className), &iter) == kIOReturnSuccess
            else { continue }
            defer { IOObjectRelease(iter) }
            var svc = IOIteratorNext(iter)
            while svc != IO_OBJECT_NULL {
                let vid  = IORegistryEntryCreateCFProperty(svc, "idVendor"         as CFString, kCFAllocatorDefault, 0).map { "\($0)" } ?? "?"
                let pid  = IORegistryEntryCreateCFProperty(svc, "idProduct"        as CFString, kCFAllocatorDefault, 0).map { "\($0)" } ?? "?"
                let name = IORegistryEntryCreateCFProperty(svc, "USB Product Name" as CFString, kCFAllocatorDefault, 0).map { "\($0)" } ?? "?"
                print("[vphone] \(className): vendor=\(vid) product=\(pid) name=\(name)")
                IOObjectRelease(svc)
                svc = IOIteratorNext(iter)
            }
        }
    }
}

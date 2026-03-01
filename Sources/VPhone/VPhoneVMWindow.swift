import AppKit
import Dynamic
import Foundation
import Virtualization

// MARK: - Touch-enabled VZVirtualMachineView

struct NormalizedResult {
    var point: CGPoint
    var isInvalid: Bool
}

class VPhoneVMView: VZVirtualMachineView {
    var currentTouchSwipeAim: Int64 = 0

    // 1. Mouse dragged -> touch phase 1 (moving)
    override func mouseDragged(with event: NSEvent) {
        handleMouseDragged(event)
        super.mouseDragged(with: event)
    }

    private func handleMouseDragged(_ event: NSEvent) {
        guard let vm = self.virtualMachine,
              let devices = multiTouchDevices(vm),
              devices.count > 0 else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        let swipeAim = self.currentTouchSwipeAim

        guard let touch = makeTouch(0, 1, normalized.point, Int(swipeAim), event.timestamp) else { return }
        guard let touchEvent = makeMultiTouchEvent([touch]) else { return }

        sendMultiTouchEvents(devices[0], [touchEvent])
    }

    // 2. Mouse down -> touch phase 0 (began)
    override func mouseDown(with event: NSEvent) {
        handleMouseDown(event)
        super.mouseDown(with: event)
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let vm = self.virtualMachine,
              let devices = multiTouchDevices(vm),
              devices.count > 0 else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        let localPoint = self.convert(event.locationInWindow, from: nil)
        let edgeResult = hitTestEdge(at: localPoint)
        self.currentTouchSwipeAim = Int64(edgeResult)

        guard let touch = makeTouch(0, 0, normalized.point, edgeResult, event.timestamp) else { return }
        guard let touchEvent = makeMultiTouchEvent([touch]) else { return }

        sendMultiTouchEvents(devices[0], [touchEvent])
    }

    // 3. Right mouse down -> two-finger touch began
    override func rightMouseDown(with event: NSEvent) {
        handleRightMouseDown(event)
        super.rightMouseDown(with: event)
    }

    private func handleRightMouseDown(_ event: NSEvent) {
        guard let vm = self.virtualMachine,
              let devices = multiTouchDevices(vm),
              devices.count > 0 else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        guard !normalized.isInvalid else { return }

        let localPoint = self.convert(event.locationInWindow, from: nil)
        let edgeResult = hitTestEdge(at: localPoint)
        self.currentTouchSwipeAim = Int64(edgeResult)

        guard let touch = makeTouch(0, 0, normalized.point, edgeResult, event.timestamp),
              let touch2 = makeTouch(1, 0, normalized.point, edgeResult, event.timestamp) else { return }
        guard let touchEvent = makeMultiTouchEvent([touch, touch2]) else { return }

        sendMultiTouchEvents(devices[0], [touchEvent])
    }

    // 4. Mouse up -> touch phase 3 (ended)
    override func mouseUp(with event: NSEvent) {
        handleMouseUp(event)
        super.mouseUp(with: event)
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard let vm = self.virtualMachine,
              let devices = multiTouchDevices(vm),
              devices.count > 0 else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        let swipeAim = self.currentTouchSwipeAim

        guard let touch = makeTouch(0, 3, normalized.point, Int(swipeAim), event.timestamp) else { return }
        guard let touchEvent = makeMultiTouchEvent([touch]) else { return }

        sendMultiTouchEvents(devices[0], [touchEvent])
    }

    // 5. Right mouse up -> two-finger touch ended
    override func rightMouseUp(with event: NSEvent) {
        handleRightMouseUp(event)
        super.rightMouseUp(with: event)
    }

    private func handleRightMouseUp(_ event: NSEvent) {
        guard let vm = self.virtualMachine,
              let devices = multiTouchDevices(vm),
              devices.count > 0 else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        guard !normalized.isInvalid else { return }

        let swipeAim = self.currentTouchSwipeAim

        guard let touch = makeTouch(0, 3, normalized.point, Int(swipeAim), event.timestamp),
              let touch2 = makeTouch(1, 3, normalized.point, Int(swipeAim), event.timestamp) else { return }
        guard let touchEvent = makeMultiTouchEvent([touch, touch2]) else { return }

        sendMultiTouchEvents(devices[0], [touchEvent])
    }

    // MARK: - Coordinate normalization

    func normalizeCoordinate(_ point: CGPoint) -> NormalizedResult {
        let bounds = self.bounds

        if bounds.size.width <= 0 || bounds.size.height <= 0 {
            return NormalizedResult(point: .zero, isInvalid: true)
        }

        let localPoint = self.convert(point, from: nil)

        var nx = Double(localPoint.x / bounds.size.width)
        var ny = Double(localPoint.y / bounds.size.height)

        nx = max(0.0, min(1.0, nx))
        ny = max(0.0, min(1.0, ny))

        if !self.isFlipped {
            ny = 1.0 - ny
        }

        return NormalizedResult(point: CGPoint(x: nx, y: ny), isInvalid: false)
    }

    // MARK: - Edge detection for swipe aim

    func hitTestEdge(at point: CGPoint) -> Int {
        let bounds = self.bounds
        let width = bounds.size.width
        let height = bounds.size.height

        let distLeft = point.x
        let distRight = width - point.x

        var minDist: Double
        var edgeCode: Int

        if distRight < distLeft {
            minDist = distRight
            edgeCode = 4 // Right
        } else {
            minDist = distLeft
            edgeCode = 8 // Left
        }

        let topCode = self.isFlipped ? 2 : 1
        let bottomCode = self.isFlipped ? 1 : 2

        let distTop = point.y
        if distTop < minDist {
            minDist = distTop
            edgeCode = topCode
        }

        let distBottom = height - point.y
        if distBottom < minDist {
            minDist = distBottom
            edgeCode = bottomCode
        }

        return minDist < 32.0 ? edgeCode : 0
    }
}

// MARK: - Window management

class VPhoneWindowController {
    private var windowController: NSWindowController?

    @MainActor
    func showWindow(for vm: VZVirtualMachine) {
        let vmView: NSView
        if #available(macOS 16.0, *) {
            let view = VZVirtualMachineView()
            view.virtualMachine = vm
            view.capturesSystemKeys = true
            vmView = view
        } else {
            let view = VPhoneVMView()
            view.virtualMachine = vm
            view.capturesSystemKeys = true
            vmView = view
        }

        let pixelWidth: CGFloat = 1179
        let pixelHeight: CGFloat = 2556
        let windowSize = NSSize(width: pixelWidth, height: pixelHeight)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.contentAspectRatio = windowSize
        window.title = "vphone"
        window.contentView = vmView
        window.center()

        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        self.windowController = controller

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        DispatchQueue.main.async {
            self.windowController?.close()
            self.windowController = nil
        }
    }
}

// MARK: - Private multi-touch helpers

/// Returns the `_multiTouchDevices` array from a running VZVirtualMachine.
private func multiTouchDevices(_ vm: VZVirtualMachine) -> [AnyObject]? {
    return Dynamic(vm)._multiTouchDevices.asArray as? [AnyObject]
}

/// Creates a _VZTouch via alloc+init + KVC (avoids crash in the designated initializer).
private func makeTouch(_ index: Int, _ phase: Int, _ location: CGPoint,
                       _ swipeAim: Int, _ timestamp: TimeInterval) -> AnyObject?
{
    guard let cls = NSClassFromString("_VZTouch") as? NSObject.Type else { return nil }
    let touch = cls.init()
    touch.setValue(NSNumber(value: UInt8(clamping: index)), forKey: "_index")
    touch.setValue(NSNumber(value: phase),                  forKey: "_phase")
    touch.setValue(NSNumber(value: swipeAim),               forKey: "_swipeAim")
    touch.setValue(NSNumber(value: timestamp),              forKey: "_timestamp")
    touch.setValue(NSValue(point: location),                forKey: "_location")
    return touch
}

/// Creates a _VZMultiTouchEvent from an array of _VZTouch objects.
private func makeMultiTouchEvent(_ touches: [AnyObject]) -> AnyObject? {
    return Dynamic._VZMultiTouchEvent(touches: touches).asObject
}

/// Sends multi-touch events to a device via `sendMultiTouchEvents:`.
private func sendMultiTouchEvents(_ device: AnyObject, _ events: [AnyObject]) {
    Dynamic(device).sendMultiTouchEvents(events)
}

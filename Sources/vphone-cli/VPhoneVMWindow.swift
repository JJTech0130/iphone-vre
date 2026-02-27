import AppKit
import Foundation
import Virtualization
import VPhoneObjC

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
              let devices = VPhoneGetMultiTouchDevices(vm),
              devices.count > 0 else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        let swipeAim = self.currentTouchSwipeAim

        guard let touch = VPhoneCreateTouch(0, 1, normalized.point, Int(swipeAim), event.timestamp) else { return }
        guard let touchEvent = VPhoneCreateMultiTouchEvent([touch]) else { return }

        let device = devices[0]
        VPhoneSendMultiTouchEvents(device, [touchEvent])
    }

    // 2. Mouse down -> touch phase 0 (began)
    override func mouseDown(with event: NSEvent) {
        handleMouseDown(event)
        super.mouseDown(with: event)
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard let vm = self.virtualMachine,
              let devices = VPhoneGetMultiTouchDevices(vm),
              devices.count > 0 else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        let localPoint = self.convert(event.locationInWindow, from: nil)
        let edgeResult = hitTestEdge(at: localPoint)
        self.currentTouchSwipeAim = Int64(edgeResult)

        guard let touch = VPhoneCreateTouch(0, 0, normalized.point, edgeResult, event.timestamp) else { return }
        guard let touchEvent = VPhoneCreateMultiTouchEvent([touch]) else { return }

        let device = devices[0]
        VPhoneSendMultiTouchEvents(device, [touchEvent])
    }

    // 3. Right mouse down -> two-finger touch began
    override func rightMouseDown(with event: NSEvent) {
        handleRightMouseDown(event)
        super.rightMouseDown(with: event)
    }

    private func handleRightMouseDown(_ event: NSEvent) {
        guard let vm = self.virtualMachine,
              let devices = VPhoneGetMultiTouchDevices(vm),
              devices.count > 0 else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        guard !normalized.isInvalid else { return }

        let localPoint = self.convert(event.locationInWindow, from: nil)
        let edgeResult = hitTestEdge(at: localPoint)
        self.currentTouchSwipeAim = Int64(edgeResult)

        guard let touch = VPhoneCreateTouch(0, 0, normalized.point, edgeResult, event.timestamp),
              let touch2 = VPhoneCreateTouch(1, 0, normalized.point, edgeResult, event.timestamp) else { return }
        guard let touchEvent = VPhoneCreateMultiTouchEvent([touch, touch2]) else { return }

        let device = devices[0]
        VPhoneSendMultiTouchEvents(device, [touchEvent])
    }

    // 4. Mouse up -> touch phase 3 (ended)
    override func mouseUp(with event: NSEvent) {
        handleMouseUp(event)
        super.mouseUp(with: event)
    }

    private func handleMouseUp(_ event: NSEvent) {
        guard let vm = self.virtualMachine,
              let devices = VPhoneGetMultiTouchDevices(vm),
              devices.count > 0 else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        let swipeAim = self.currentTouchSwipeAim

        guard let touch = VPhoneCreateTouch(0, 3, normalized.point, Int(swipeAim), event.timestamp) else { return }
        guard let touchEvent = VPhoneCreateMultiTouchEvent([touch]) else { return }

        let device = devices[0]
        VPhoneSendMultiTouchEvents(device, [touchEvent])
    }

    // 5. Right mouse up -> two-finger touch ended
    override func rightMouseUp(with event: NSEvent) {
        handleRightMouseUp(event)
        super.rightMouseUp(with: event)
    }

    private func handleRightMouseUp(_ event: NSEvent) {
        guard let vm = self.virtualMachine,
              let devices = VPhoneGetMultiTouchDevices(vm),
              devices.count > 0 else { return }

        let normalized = normalizeCoordinate(event.locationInWindow)
        guard !normalized.isInvalid else { return }

        let swipeAim = self.currentTouchSwipeAim

        guard let touch = VPhoneCreateTouch(0, 3, normalized.point, Int(swipeAim), event.timestamp),
              let touch2 = VPhoneCreateTouch(1, 3, normalized.point, Int(swipeAim), event.timestamp) else { return }
        guard let touchEvent = VPhoneCreateMultiTouchEvent([touch, touch2]) else { return }

        let device = devices[0]
        VPhoneSendMultiTouchEvents(device, [touchEvent])
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

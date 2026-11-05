import AppKit
import Virtualization

/// The VM's screen, in the driver's own process (a `VZVirtualMachineView` can only show a
/// machine of its process). Lima's `RunGUI` isn't used: for external drivers Lima 2.2.1 gives
/// that call 10 seconds, and the host agent exits when it returns. Closing the window hides
/// it; the VM runs on, and HanaLima reopens it over the control socket.
///
/// The driver is a plain executable, so it has no Dock tile of its own: while the window is
/// shown the process is a regular app (Cmd-Tab, keyboard focus) with HanaLima's icon, and it
/// drops out of the Dock again when the window is hidden.
@MainActor
final class DisplayWindow: NSObject, NSWindowDelegate {
    private let window: NSWindow
    private let view = VZVirtualMachineView()
    /// Set by `dismiss()`: the VM is gone, nothing shows or captures any more.
    private(set) var isDismissed = false

    init(title: String, machine: VZMachine.Box, width: Int, height: Int) {
        let size = NSSize(width: CGFloat(width) / 2, height: CGFloat(height) / 2)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        super.init()
        window.title = title
        window.contentAspectRatio = NSSize(width: width, height: height)
        window.contentMinSize = NSSize(width: 640, height: 400)
        window.isReleasedWhenClosed = false
        window.delegate = self
        view.virtualMachine = machine.machine
        view.capturesSystemKeys = true
        view.autoresizingMask = [.width, .height]
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.center()
        if let icon = Self.appIcon { NSApplication.shared.applicationIconImage = icon }
    }

    var isShown: Bool { window.isVisible }

    /// False once dismissed.
    @discardableResult
    func show() -> Bool {
        guard !isDismissed else { return false }
        let app = NSApplication.shared
        if app.activationPolicy() != .regular { app.setActivationPolicy(.regular) }
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        window.makeFirstResponder(view)
        return true
    }

    func hide() {
        window.orderOut(nil)
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// Takes the VM out of the window before the window goes (a stopped VM renders nothing).
    func dismiss() {
        isDismissed = true
        view.virtualMachine = nil
        hide()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide()
        return false
    }

    /// The window's contents as PNG, the way Lima's vz driver captures it (the view draws on
    /// the GPU; a window capture is what works). Only while the window is on screen.
    func screenshotPNG() throws -> Data {
        guard !isDismissed else { throw DriverError("the VM has stopped") }
        guard window.isVisible else { throw DriverError("the screen window is hidden") }
        guard let image = Self.captureWindow(CGWindowID(window.windowNumber)) else {
            throw DriverError("the window couldn't be captured")
        }
        // The guest's screen only, without the title bar.
        let scale = CGFloat(image.width) / window.frame.width
        let content = view.frame  // in window coordinates, origin at the bottom left
        let rect = CGRect(x: content.minX * scale, y: (window.frame.height - content.maxY) * scale,
                          width: content.width * scale, height: content.height * scale)
        let rep = NSBitmapImageRep(cgImage: image.cropping(to: rect) ?? image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw DriverError("PNG encoding failed") }
        return png
    }

    /// `CGWindowListCreateImage`, which Lima's vz driver captures with too. The macOS 26 SDK
    /// hides it from code built for 15 and later (ScreenCaptureKit is the replacement, but that
    /// one asks for the screen-recording permission even for the process's own window), while
    /// the function itself is still there; so it's looked up at run time.
    private static func captureWindow(_ id: CGWindowID) -> CGImage? {
        typealias Function = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }  // RTLD_DEFAULT
        let create = unsafeBitCast(symbol, to: Function.self)
        let optionIncludingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0
        let shouldBeOpaque: UInt32 = 1 << 1
        return create(.null, optionIncludingWindow, id, boundsIgnoreFraming | shouldBeOpaque)?.takeRetainedValue()
    }

    /// HanaLima's icon, from the bundle the driver is shipped in (`Contents/Helpers/` → `Contents/Resources/`).
    private static var appIcon: NSImage? {
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let icns = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/AppIcon.icns")
        return NSImage(contentsOf: icns)
    }
}

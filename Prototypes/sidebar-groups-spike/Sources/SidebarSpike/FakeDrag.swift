import AppKit

/// A stand-in NSDraggingInfo, to call the outline's validateDrop/acceptDrop directly: synthetic
/// mouse events don't start an NSOutlineView drag (it checks the real mouse button).
final class FakeDrag: NSObject, NSDraggingInfo {
    let pasteboard: NSPasteboard

    init(vm: String? = nil, group: String? = nil) {
        pasteboard = NSPasteboard(name: .init("spike-\(UUID().uuidString)"))
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        if let vm { item.setString(vm, forType: .spikeVM) }
        if let group { item.setString(group, forType: .spikeGroup) }
        pasteboard.writeObjects([item])
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { [.move, .copy] }
    var draggingLocation: NSPoint { .zero }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { pasteboard }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 0 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}

import Foundation
import IOKit
import PrintCore

/// This Mac's USB devices as IOKit's registry has them (`IOUSBHostDevice`), read only, for "Plugged in, needs its driver"
/// (`NeedsDriver`): each device's vendor and product ids, the names it reports, its class and its interfaces' classes and
/// names. Its serial number (`USB Serial Number`, `kUSBSerialNumberString`) is never read. Reading the registry needs no
/// entitlement beyond the sandbox's (`com.apple.security.device.usb` is for opening a device, which this never does).
public struct IOKitUsbDevices: UsbDeviceSource {
    public init() {}

    public func devices() -> [UsbDevice] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var list: [UsbDevice] = []
        while list.count < 256 {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }
            if let d = Self.device(service) { list.append(d) }
        }
        return list
    }

    static func device(_ service: io_registry_entry_t) -> UsbDevice? {
        guard let vendor = number(service, "idVendor"), let product = number(service, "idProduct") else { return nil }
        var classes: [Int] = []
        var names: [String] = []
        var children: io_iterator_t = 0
        if IORegistryEntryGetChildIterator(service, kIOServicePlane, &children) == KERN_SUCCESS {
            defer { IOObjectRelease(children) }
            interfaces(children, depth: 0, &classes, &names)
        }
        return UsbDevice(vendorId: vendor, productId: product,
                         productName: text(service, "USB Product Name") ?? text(service, "kUSBProductString"),
                         vendorName: text(service, "USB Vendor Name") ?? text(service, "kUSBVendorString"),
                         deviceClass: number(service, "bDeviceClass") ?? 0, interfaceClasses: classes, interfaceNames: names)
    }

    /// The device's interfaces (`IOUSBHostInterface`, its children, or a configuration's below it): their classes and names.
    private static func interfaces(_ children: io_iterator_t, depth: Int, _ classes: inout [Int], _ names: inout [String]) {
        while classes.count < 32 {
            let child = IOIteratorNext(children)
            guard child != 0 else { return }
            defer { IOObjectRelease(child) }
            if IOObjectConformsTo(child, "IOUSBHostInterface") != 0 {
                if let c = number(child, "bInterfaceClass") { classes.append(c) }
                if let n = text(child, "USB Interface Name") ?? text(child, "kUSBString") { names.append(n) }
            } else if depth < 2 {
                var below: io_iterator_t = 0
                if IORegistryEntryGetChildIterator(child, kIOServicePlane, &below) == KERN_SUCCESS {
                    interfaces(below, depth: depth + 1, &classes, &names)
                    IOObjectRelease(below)
                }
            }
        }
    }

    private static func property(_ service: io_registry_entry_t, _ key: String) -> CFTypeRef? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func number(_ service: io_registry_entry_t, _ key: String) -> Int? { (property(service, key) as? NSNumber)?.intValue }

    /// A name the device reports, cut to 200 characters: it's the device's own text, untrusted.
    private static func text(_ service: io_registry_entry_t, _ key: String) -> String? {
        guard let s = property(service, key) as? String else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
        return t.isEmpty ? nil : String(t.prefix(200))
    }
}

/// Tells the app at once when a USB device is plugged in or unplugged (IOKit's first-match and terminated notifications on
/// `IOUSBHostDevice`), so a printer or scanner that needs its driver shows without waiting for the next read of the queues,
/// and one that got its driver is seen. Delivered on the main run loop; `stop` (or the watch going away) ends it.
public final class UsbDeviceWatch: @unchecked Sendable { // started, delivered and stopped on the main thread only
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []
    private let changed: @MainActor () -> Void

    public init(_ changed: @escaping @MainActor () -> Void) { self.changed = changed }

    deinit { stop() }

    /// False when IOKit gave no notifications (nothing changes then: the queue reads still look).
    @discardableResult
    public func start() -> Bool {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return false }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOServiceMatchingCallback = { refcon, iterator in
            UsbDeviceWatch.drain(iterator)
            guard let refcon else { return }
            let watch = Unmanaged<UsbDeviceWatch>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { watch.changed() }
        }
        for kind in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            var iterator: io_iterator_t = 0
            guard IOServiceAddMatchingNotification(port, kind, IOServiceMatching("IOUSBHostDevice"), callback, me, &iterator) == KERN_SUCCESS else { continue }
            Self.drain(iterator) // arms it: the devices there now aren't news
            iterators.append(iterator)
        }
        return !iterators.isEmpty
    }

    public func stop() {
        for i in iterators { IOObjectRelease(i) }
        iterators = []
        if let port {
            IONotificationPortDestroy(port)
            self.port = nil
        }
    }

    private static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 { IOObjectRelease(service) }
    }
}

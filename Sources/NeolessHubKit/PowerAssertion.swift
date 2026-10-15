import Foundation
import IOKit.pwr_mgt

/// Keeps the Neo from idle sleep while the hub serves (`PreventUserIdleSystemSleep`). It changes no system
/// setting and ends with the process; closing the lid still sleeps the Mac.
public final class PowerAssertion: @unchecked Sendable {
    private let lock = NSLock()
    private var id: IOPMAssertionID = 0
    private var held = false

    /// nil when macOS refused the assertion.
    public init?(reason: String) {
        let result = IOPMAssertionCreateWithName("PreventUserIdleSystemSleep" as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn), reason as CFString, &id)
        guard result == kIOReturnSuccess else { return nil }
        held = true
    }

    public func release() {
        lock.withLock {
            guard held else { return }
            IOPMAssertionRelease(id)
            held = false
        }
    }

    deinit { release() }
}

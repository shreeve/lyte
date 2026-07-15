import Foundation

/// Rename an UNBUNDLED process in the macOS menu bar. AppKit derives the app
/// menu title from the LaunchServices registration (argv[0] for bare
/// executables); the only way to change it is the private LS display-name
/// call — the same one Chromium and Qt use. Resolved via dlsym so we fail
/// soft if the symbol ever disappears. The bundled app (M5) won't need this.
enum ProcessName {
    static func set(_ name: String) {
        typealias GetASN = @convention(c) () -> CFTypeRef?
        typealias SetItem = @convention(c) (Int32, CFTypeRef?, CFString, CFString, UnsafeMutablePointer<CFDictionary?>?) -> OSStatus

        guard let getASNSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_LSGetCurrentApplicationASN"),
              let setItemSym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "_LSSetApplicationInformationItem") else {
            return
        }
        let getASN = unsafeBitCast(getASNSym, to: GetASN.self)
        let setItem = unsafeBitCast(setItemSym, to: SetItem.self)

        let kLSDefaultSessionID: Int32 = -2
        _ = setItem(kLSDefaultSessionID, getASN(), "LSDisplayName" as CFString, name as CFString, nil)
    }
}

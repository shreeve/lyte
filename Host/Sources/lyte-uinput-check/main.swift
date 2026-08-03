// E2 verification harness: the uinput leaf, read back from the other
// side. Creates the three virtual devices through CInputUinput, finds
// their evdev nodes by name under /sys/class/input, and asserts that
// every emitted event arrives byte-exact where it should: keys on the
// keyboard, buttons and wheels on the mouse, absolute motion on the
// tablet scaled 0…65535 against the extent. Exits nonzero on any
// mismatch. Needs read access to /dev/input/event* (run under sudo;
// the injection itself needs only the udev-rule ACL on /dev/uinput).

#if os(Linux)

import CInputUinput
import Foundation
import Glibc

struct Ev: Equatable, CustomStringConvertible {
    var type: UInt16
    var code: UInt16
    var value: Int32
    var description: String { "(\(type),\(code),\(value))" }
}

let EV_SYN: UInt16 = 0, EV_KEY: UInt16 = 1
let EV_REL: UInt16 = 2, EV_ABS: UInt16 = 3
let SYN_REPORT: UInt16 = 0
let REL_X: UInt16 = 0, REL_Y: UInt16 = 1
let REL_HWHEEL: UInt16 = 6, REL_WHEEL: UInt16 = 8
let REL_WHEEL_HI_RES: UInt16 = 0x0B, REL_HWHEEL_HI_RES: UInt16 = 0x0C
let ABS_X: UInt16 = 0, ABS_Y: UInt16 = 1
let KEY_A: UInt32 = 30
let BTN_LEFT: UInt32 = 0x110

func die(_ msg: String) -> Never {
    print("uinput-check FAIL: \(msg)")
    exit(1)
}

func findNode(named want: String) -> String? {
    let base = "/sys/class/input"
    guard let entries = try? FileManager.default
        .contentsOfDirectory(atPath: base) else { return nil }
    for entry in entries.sorted() where entry.hasPrefix("event") {
        let namePath = "\(base)/\(entry)/device/name"
        if let name = try? String(contentsOfFile: namePath,
                                  encoding: .utf8),
           name.trimmingCharacters(in: .whitespacesAndNewlines) == want {
            return "/dev/input/\(entry)"
        }
    }
    return nil
}

/// One evdev reader: nonblocking, 24-byte input_event records
/// (timeval 16 + type 2 + code 2 + value 4 on 64-bit).
final class Reader {
    let fd: Int32
    let label: String

    init(device want: String, label: String) {
        self.label = label
        var node: String?
        for _ in 0..<40 {
            if let found = findNode(named: want) { node = found; break }
            usleep(50_000)
        }
        guard let node else { die("\(label): device \"\(want)\" never appeared") }
        fd = open(node, O_RDONLY | O_NONBLOCK)
        guard fd >= 0 else {
            die("\(label): open(\(node)) errno \(errno) — run under sudo")
        }
        print("uinput-check: \(label) ← \(node)")
    }

    func poll() -> [Ev] {
        var events: [Ev] = []
        var buf = [UInt8](repeating: 0, count: 24 * 64)
        while true {
            let n = read(fd, &buf, buf.count)
            guard n > 0 else { break }
            var offset = 0
            while offset + 24 <= n {
                let type = UInt16(buf[offset + 16])
                    | UInt16(buf[offset + 17]) << 8
                let code = UInt16(buf[offset + 18])
                    | UInt16(buf[offset + 19]) << 8
                var value: Int32 = 0
                for i in 0..<4 {
                    value |= Int32(buf[offset + 20 + i]) << (8 * i)
                }
                events.append(Ev(type: type, code: code, value: value))
                offset += 24
            }
        }
        return events
    }

    func drain() { _ = poll() }

    func expect(_ wanted: [Ev], scenario: String) {
        var got: [Ev] = []
        for _ in 0..<100 {
            got += poll()
            if got.count >= wanted.count { break }
            usleep(10_000)
        }
        guard got == wanted else {
            die("\(scenario) on \(label): wanted \(wanted), got \(got)")
        }
        print("uinput-check: PASS \(scenario)")
    }
}

var err = [CChar](repeating: 0, count: 256)

guard let handle = lyte_uinput_open(&err, err.count) else {
    die("open: \(String(cString: err)) — is the udev rule installed?")
}

// Loud-failure law: absolute motion before the extent must refuse.
guard lyte_uinput_move_abs(handle, 10, 10, &err, err.count) != 0 else {
    die("absolute move before set_extent must fail loudly")
}
print("uinput-check: PASS absolute-before-extent refuses")

let kbd = Reader(device: "Lyte Virtual Keyboard", label: "keyboard")
let mouse = Reader(device: "Lyte Virtual Mouse", label: "mouse")
let tablet = Reader(device: "Lyte Virtual Tablet", label: "tablet")
usleep(200_000)
kbd.drain(); mouse.drain(); tablet.drain()

guard lyte_uinput_set_extent(handle, 2048, 1280, &err, err.count) == 0
else { die("set_extent: \(String(cString: err))") }

// Keys route to the keyboard device.
_ = lyte_uinput_key(handle, KEY_A, 1, &err, err.count)
_ = lyte_uinput_key(handle, KEY_A, 0, &err, err.count)
kbd.expect([
    Ev(type: EV_KEY, code: UInt16(KEY_A), value: 1),
    Ev(type: EV_SYN, code: SYN_REPORT, value: 0),
    Ev(type: EV_KEY, code: UInt16(KEY_A), value: 0),
    Ev(type: EV_SYN, code: SYN_REPORT, value: 0),
], scenario: "key press/release")

// Buttons route to the mouse device.
_ = lyte_uinput_key(handle, BTN_LEFT, 1, &err, err.count)
_ = lyte_uinput_key(handle, BTN_LEFT, 0, &err, err.count)
mouse.expect([
    Ev(type: EV_KEY, code: UInt16(BTN_LEFT), value: 1),
    Ev(type: EV_SYN, code: SYN_REPORT, value: 0),
    Ev(type: EV_KEY, code: UInt16(BTN_LEFT), value: 0),
    Ev(type: EV_SYN, code: SYN_REPORT, value: 0),
], scenario: "button press/release")

// Absolute motion: pixel center scales to 32767/65535 on the tablet.
_ = lyte_uinput_move_abs(handle, 1024, 640, &err, err.count)
tablet.expect([
    Ev(type: EV_ABS, code: ABS_X, value: 32767),
    Ev(type: EV_ABS, code: ABS_Y, value: 32767),
    Ev(type: EV_SYN, code: SYN_REPORT, value: 0),
], scenario: "absolute center scales exactly")

// Clamping: past-the-edge pixels pin to the axis maximum.
_ = lyte_uinput_move_abs(handle, 9999, -5, &err, err.count)
tablet.expect([
    Ev(type: EV_ABS, code: ABS_X, value: 65535),
    Ev(type: EV_ABS, code: ABS_Y, value: 0),
    Ev(type: EV_SYN, code: SYN_REPORT, value: 0),
], scenario: "absolute clamps at the edges")

// Relative motion.
_ = lyte_uinput_move_rel(handle, 5, -3, &err, err.count)
mouse.expect([
    Ev(type: EV_REL, code: REL_X, value: 5),
    Ev(type: EV_REL, code: REL_Y, value: -3),
    Ev(type: EV_SYN, code: SYN_REPORT, value: 0),
], scenario: "relative move")

// Scroll: one full detent = hi-res 120 plus one wheel click.
_ = lyte_uinput_scroll(handle, 0, 120, &err, err.count)
mouse.expect([
    Ev(type: EV_REL, code: REL_WHEEL_HI_RES, value: 120),
    Ev(type: EV_REL, code: REL_WHEEL, value: 1),
    Ev(type: EV_SYN, code: SYN_REPORT, value: 0),
], scenario: "scroll full detent")

// Two half-detents: the remainder accumulates into the second click.
_ = lyte_uinput_scroll(handle, 0, 60, &err, err.count)
_ = lyte_uinput_scroll(handle, 0, 60, &err, err.count)
mouse.expect([
    Ev(type: EV_REL, code: REL_WHEEL_HI_RES, value: 60),
    Ev(type: EV_SYN, code: SYN_REPORT, value: 0),
    Ev(type: EV_REL, code: REL_WHEEL_HI_RES, value: 60),
    Ev(type: EV_REL, code: REL_WHEEL, value: 1),
    Ev(type: EV_SYN, code: SYN_REPORT, value: 0),
], scenario: "half-detent accumulation")

lyte_uinput_free(handle)
print("uinput-check: ALL PASS")
exit(0)

#else
print("uinput-check: Linux only")
#endif

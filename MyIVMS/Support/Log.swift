import Foundation

/// Minimal logger that writes to stderr, so output is visible when running the
/// binary from a terminal (`MyIVMS.app/Contents/MacOS/MyIVMS`).
enum Log {
    static var enabled = true

    static func info(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        let line = "[MyIVMS] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

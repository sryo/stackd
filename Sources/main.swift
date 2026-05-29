import AppKit
import Foundation

let argv = CommandLine.arguments
if argv.count > 1 {
    // Client mode: forward argv to the running daemon and exit.
    exit(CLI.runClient(Array(argv.dropFirst())))
}

// Daemon mode.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()

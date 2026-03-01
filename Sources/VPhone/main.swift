import AppKit
import Foundation

let cli = VPhoneCLI.parseOrExit()

let app = NSApplication.shared
let delegate = VPhoneAppDelegate(cli: cli)
app.delegate = delegate
app.run()

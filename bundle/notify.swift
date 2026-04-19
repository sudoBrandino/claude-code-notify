import Foundation
import AppKit

// The bundle runs in two modes:
//   1. Posting a notification:  open <bundle> --args <title> <subtitle> <body> <sound>
//   2. User clicked the notification (or launched the .app directly): no args
//
// In mode 2, bring the terminal to the front instead of re-posting a
// notification with default values.

let args = CommandLine.arguments

if args.count <= 1 {
    let env = ProcessInfo.processInfo.environment
    let targetApp = env["CLAUDE_NOTIFY_CLICK_TARGET"] ?? "Ghostty"
    let targetBundleID = env["CLAUDE_NOTIFY_CLICK_BUNDLE_ID"] ?? "com.mitchellh.ghostty"

    let workspace = NSWorkspace.shared
    let url = workspace.urlForApplication(withBundleIdentifier: targetBundleID)
        ?? workspace.fullPath(forApplication: targetApp).map { URL(fileURLWithPath: $0) }

    if let url = url {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        workspace.openApplication(at: url, configuration: config) { _, _ in }
    }
    // Small delay so the async openApplication handoff completes before exit.
    Thread.sleep(forTimeInterval: 0.3)
    exit(0)
}

let title    = args[1]
let subtitle = args.count > 2 ? args[2] : ""
let body     = args.count > 3 ? args[3] : ""
let sound    = args.count > 4 ? args[4] : "Glass"

// NSUserNotification is deprecated but remains the only path that posts
// without prompting for explicit UNUserNotificationCenter authorization.
let note = NSUserNotification()
note.title = title
if !subtitle.isEmpty { note.subtitle = subtitle }
note.informativeText = body
note.soundName = sound

NSUserNotificationCenter.default.deliver(note)

// Keep the process alive long enough for the NotificationCenter daemon to
// accept the handoff from our bundle identity.
Thread.sleep(forTimeInterval: 0.5)

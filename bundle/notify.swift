import Foundation
import AppKit

// The bundle runs in two modes:
//   1. Posting:  open <bundle> --args <title> <subtitle> <body> <sound>
//   2. Click:    no args — triggered by notification click or app launch.
//
// Click mode tries to focus the specific terminal window where the Claude
// session that posted the notification was running. Falls back to plain
// terminal activation if the window match fails (or Accessibility is denied).

let args = CommandLine.arguments

// --- Posting mode -----------------------------------------------------------
if args.count > 1 {
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

    Thread.sleep(forTimeInterval: 0.5)
    exit(0)
}

// --- Click mode -------------------------------------------------------------
let env = ProcessInfo.processInfo.environment
let targetApp = env["CLAUDE_NOTIFY_CLICK_TARGET"] ?? "Ghostty"
let targetBundleID = env["CLAUDE_NOTIFY_CLICK_BUNDLE_ID"] ?? "com.mitchellh.ghostty"
let homeDir = env["HOME"] ?? NSHomeDirectory()
let stateDir = env["CLAUDE_NOTIFY_STATE_DIR"] ?? "\(homeDir)/.claude/notify-state"
let statePath = "\(stateDir)/last-session"

// Read `cwd=<path>` from the state file, if it exists.
func readSessionCwd() -> String? {
    guard let contents = try? String(contentsOfFile: statePath, encoding: .utf8) else {
        return nil
    }
    for line in contents.split(separator: "\n") {
        if line.hasPrefix("cwd=") {
            let v = String(line.dropFirst(4))
            return v.isEmpty ? nil : v
        }
    }
    return nil
}

// Try to raise the target app's window whose title contains `needle`.
// Returns true on success. Requires Accessibility permission.
func raiseWindowMatching(processName: String, needle: String) -> Bool {
    let script = """
    tell application "System Events"
      if not (exists (process "\(processName)")) then return false
      tell process "\(processName)"
        set frontmost to true
        set matched to (every window whose title contains "\(needle)")
        if (count of matched) > 0 then
          perform action "AXRaise" of (item 1 of matched)
          return true
        end if
      end tell
      return false
    end tell
    """
    var error: NSDictionary?
    guard let applescript = NSAppleScript(source: script) else { return false }
    let result = applescript.executeAndReturnError(&error)
    if error != nil { return false }
    return result.booleanValue
}

// Plain activation fallback — no Accessibility needed.
func activatePlain() {
    let workspace = NSWorkspace.shared
    let url = workspace.urlForApplication(withBundleIdentifier: targetBundleID)
        ?? workspace.fullPath(forApplication: targetApp).map { URL(fileURLWithPath: $0) }
    guard let url = url else { return }
    let config = NSWorkspace.OpenConfiguration()
    config.activates = true
    workspace.openApplication(at: url, configuration: config) { _, _ in }
}

var raised = false
if let cwd = readSessionCwd() {
    let basename = (cwd as NSString).lastPathComponent
    if !basename.isEmpty {
        // Escape double-quotes for AppleScript string literal safety.
        let needle = basename.replacingOccurrences(of: "\"", with: "\\\"")
        raised = raiseWindowMatching(processName: targetApp, needle: needle)
    }
}

if !raised {
    activatePlain()
}

Thread.sleep(forTimeInterval: 0.3)

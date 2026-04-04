import ArgumentParser
import ApplicationServices
import AppKit
import GUIVisionAgentLib
import GUIVisionAgentProtocol

struct WindowsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List all windows from running applications"
    )

    func run() throws {
        let windows = enumerateWindows()
        let response = SnapshotResponse(windows: windows)
        JSONOutput.write(response)
    }
}

// MARK: - Window enumeration (shared with SnapshotCommand)

func windowTypeFromSubrole(_ subrole: String?) -> String {
    guard let subrole else { return "window" }
    if subrole == "AXStandardWindow" { return "window" }
    if subrole == "AXDialog" || subrole == "AXSystemDialog" { return "dialog" }
    if subrole == "AXFloatingWindow" { return "window" }
    if subrole == "AXSheet" { return "dialog" }
    if subrole.contains("Menu") { return "menu" }
    if subrole.contains("Popover") { return "popover" }
    return "window"
}

func enumerateWindows() -> [WindowInfo] {
    let runningApps = NSWorkspace.shared.runningApplications
    var result: [WindowInfo] = []

    for app in runningApps {
        guard app.activationPolicy != .prohibited else { continue }
        let pid = app.processIdentifier
        let appWrapper = AXElementWrapper.application(pid: pid)
        let appName = app.localizedName ?? appWrapper.label() ?? "Unknown"

        let windowElements = appWrapper.children()
        for win in windowElements {
            guard win.role() == "AXWindow" else { continue }
            let title = win.label()
            let subrole = win.subrole()
            let windowType = windowTypeFromSubrole(subrole)
            let position = win.position() ?? .zero
            let size = win.size() ?? .zero
            let focused = win.isFocused()

            let info = WindowInfo(
                title: title,
                windowType: windowType,
                size: size,
                position: position,
                appName: appName,
                focused: focused,
                elements: nil
            )
            result.append(info)
        }
    }

    return result
}

func windowMatches(_ window: WindowInfo, filter: String) -> Bool {
    let lower = filter.lowercased()
    if let title = window.title, title.lowercased().contains(lower) { return true }
    if window.appName.lowercased().contains(lower) { return true }
    return false
}

import ArgumentParser
import Foundation
import AppKit
import GUIVisionAgentLib
import GUIVisionAgentProtocol

struct WaitResult: Codable {
    let changed: Bool
}

struct WaitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for the accessibility tree to change"
    )

    @OptionGroup var windowFilter: WindowFilter

    @Option(help: "Timeout in seconds")
    var timeout: Int = 5

    func run() throws {
        let initialData = snapshotData(windowFilter: windowFilter)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))

        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
            let currentData = snapshotData(windowFilter: windowFilter)
            if currentData != initialData {
                JSONOutput.write(WaitResult(changed: true))
                return
            }
        }

        JSONOutput.write(WaitResult(changed: false))
    }
}

private func snapshotData(windowFilter: WindowFilter) -> Data {
    var windows = enumerateWindows()
    if let filterStr = windowFilter.window {
        windows = windows.filter { windowMatches($0, filter: filterStr) }
    }

    let snapshotWindows = windows.map { win -> WindowInfo in
        guard let winElement = findWindowElementForWait(win) else {
            return win
        }
        let elements = TreeWalker.walk(
            root: winElement,
            depth: 3,
            roleFilter: nil,
            labelFilter: nil
        )
        return WindowInfo(
            title: win.title,
            windowType: win.windowType,
            size: win.size,
            position: win.position,
            appName: win.appName,
            focused: win.focused,
            elements: elements
        )
    }

    let response = SnapshotResponse(windows: snapshotWindows)
    let encoder = JSONEncoder()
    encoder.outputFormatting = []
    return (try? encoder.encode(response)) ?? Data()
}

private func findWindowElementForWait(_ win: WindowInfo) -> (any AccessibleElement)? {
    let runningApps = NSWorkspace.shared.runningApplications
    for app in runningApps {
        guard app.activationPolicy != .prohibited else { continue }
        let appName = app.localizedName ?? "Unknown"
        guard appName == win.appName else { continue }
        let appWrapper = AXElementWrapper.application(pid: app.processIdentifier)
        for child in appWrapper.children() {
            guard child.role() == "AXWindow" else { continue }
            let pos = child.position() ?? .zero
            let sz = child.size() ?? .zero
            if pos.x == win.position.x && pos.y == win.position.y &&
               sz.width == win.size.width && sz.height == win.size.height {
                return child
            }
        }
    }
    return nil
}

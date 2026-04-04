import ArgumentParser
import ApplicationServices
import AppKit
import GUIVisionAgentLib
import GUIVisionAgentProtocol

// MARK: - AXValue helpers

private func axValue(from point: CGPoint) -> AXValue {
    var pt = point
    return AXValueCreate(.cgPoint, &pt)!
}

private func axValue(from size: CGSize) -> AXValue {
    var sz = size
    return AXValueCreate(.cgSize, &sz)!
}

// MARK: - Window lookup helper

private func findTargetWindow(filter: WindowFilter) -> (window: any AccessibleElement, info: WindowInfo)? {
    // Not used directly — callers use resolveWindow
    nil
}

private func resolveWindow(
    filter: WindowFilter,
    commandName: String
) -> (window: any AccessibleElement, info: WindowInfo)? {
    guard let filterStr = filter.window else {
        JSONOutput.error("--window is required for \(commandName)")
    }

    let allWindows = enumerateWindows()
    let matches = allWindows.filter { windowMatches($0, filter: filterStr) }

    if matches.isEmpty {
        JSONOutput.error("No window matching '\(filterStr)'")
    }
    if matches.count > 1 {
        let titles = matches.map { w in
            "\(w.appName): \(w.title ?? "<untitled>")"
        }.joined(separator: "\n")
        JSONOutput.error(
            "Multiple windows match '\(filterStr)' — refine your filter",
            details: "Matches:\n\(titles)"
        )
    }

    let info = matches[0]
    // Find the live AX element for this window
    let runningApps = NSWorkspace.shared.runningApplications
    for app in runningApps {
        guard app.activationPolicy != .prohibited else { continue }
        let appName = app.localizedName ?? "Unknown"
        guard appName == info.appName else { continue }
        let appWrapper = AXElementWrapper.application(pid: app.processIdentifier)
        for child in appWrapper.children() {
            guard child.role() == "AXWindow" else { continue }
            let pos = child.position() ?? .zero
            let sz = child.size() ?? .zero
            if pos.x == info.position.x && pos.y == info.position.y &&
               sz.width == info.size.width && sz.height == info.size.height {
                return (window: child, info: info)
            }
        }
    }

    JSONOutput.error("Window '\(filterStr)' found in snapshot but could not locate live AX element")
}

// MARK: - WindowFocusCmd

struct WindowFocusCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window-focus",
        abstract: "Bring a window to front and give it focus"
    )

    @OptionGroup var windowFilter: WindowFilter

    func run() throws {
        guard let (windowElement, windowInfo) = resolveWindow(filter: windowFilter, commandName: "window-focus") else {
            return
        }

        do {
            // Activate the owning application
            let runningApps = NSWorkspace.shared.runningApplications
            if let app = runningApps.first(where: { ($0.localizedName ?? "") == windowInfo.appName }) {
                app.activate(options: [])
            }
            try windowElement.setAttribute("AXMain", value: true)
            try windowElement.setAttribute("AXFocused", value: true)
            let response = ActionResponse(success: true, message: "Window focused successfully")
            JSONOutput.write(response)
        } catch {
            let response = ActionResponse(success: false, message: "window-focus failed: \(error)")
            JSONOutput.write(response)
        }
    }
}

// MARK: - WindowResizeCmd

struct WindowResizeCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window-resize",
        abstract: "Resize a window to the given dimensions"
    )

    @OptionGroup var windowFilter: WindowFilter

    @Option(help: "New width in points")
    var width: Int

    @Option(help: "New height in points")
    var height: Int

    func run() throws {
        guard let (windowElement, _) = resolveWindow(filter: windowFilter, commandName: "window-resize") else {
            return
        }

        do {
            let newSize = CGSize(width: width, height: height)
            try windowElement.setAttribute("AXSize", value: axValue(from: newSize))
            let response = ActionResponse(success: true, message: "Window resized to \(width)×\(height)")
            JSONOutput.write(response)
        } catch {
            let response = ActionResponse(success: false, message: "window-resize failed: \(error)")
            JSONOutput.write(response)
        }
    }
}

// MARK: - WindowMoveCmd

struct WindowMoveCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window-move",
        abstract: "Move a window to the given screen position"
    )

    @OptionGroup var windowFilter: WindowFilter

    @Option(help: "New X position in points")
    var x: Int

    @Option(help: "New Y position in points")
    var y: Int

    func run() throws {
        guard let (windowElement, _) = resolveWindow(filter: windowFilter, commandName: "window-move") else {
            return
        }

        do {
            let newPoint = CGPoint(x: x, y: y)
            try windowElement.setAttribute("AXPosition", value: axValue(from: newPoint))
            let response = ActionResponse(success: true, message: "Window moved to (\(x), \(y))")
            JSONOutput.write(response)
        } catch {
            let response = ActionResponse(success: false, message: "window-move failed: \(error)")
            JSONOutput.write(response)
        }
    }
}

// MARK: - WindowCloseCmd

struct WindowCloseCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window-close",
        abstract: "Close a window via its close button"
    )

    @OptionGroup var windowFilter: WindowFilter

    func run() throws {
        guard let (windowElement, _) = resolveWindow(filter: windowFilter, commandName: "window-close") else {
            return
        }

        // Get the AXCloseButton from the window element via the underlying AXUIElement
        guard let axWrapper = windowElement as? AXElementWrapper else {
            let response = ActionResponse(success: false, message: "window-close: element is not an AXElementWrapper")
            JSONOutput.write(response)
            return
        }

        var closeButtonRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(axWrapper.element, "AXCloseButton" as CFString, &closeButtonRef)
        guard result == .success, let closeRef = closeButtonRef else {
            let response = ActionResponse(success: false, message: "window-close: could not get AXCloseButton (AX error \(result.rawValue))")
            JSONOutput.write(response)
            return
        }

        guard CFGetTypeID(closeRef) == AXUIElementGetTypeID() else {
            let response = ActionResponse(success: false, message: "window-close: AXCloseButton is not an AXUIElement")
            JSONOutput.write(response)
            return
        }

        let closeButton = AXElementWrapper(closeRef as! AXUIElement)
        do {
            try closeButton.performAction("AXPress")
            let response = ActionResponse(success: true, message: "Window closed successfully")
            JSONOutput.write(response)
        } catch {
            let response = ActionResponse(success: false, message: "window-close failed: \(error)")
            JSONOutput.write(response)
        }
    }
}

// MARK: - WindowMinimizeCmd

struct WindowMinimizeCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window-minimize",
        abstract: "Minimize a window"
    )

    @OptionGroup var windowFilter: WindowFilter

    func run() throws {
        guard let (windowElement, _) = resolveWindow(filter: windowFilter, commandName: "window-minimize") else {
            return
        }

        do {
            try windowElement.setAttribute("AXMinimized", value: true)
            let response = ActionResponse(success: true, message: "Window minimized successfully")
            JSONOutput.write(response)
        } catch {
            let response = ActionResponse(success: false, message: "window-minimize failed: \(error)")
            JSONOutput.write(response)
        }
    }
}

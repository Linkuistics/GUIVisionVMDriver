import ArgumentParser
import AppKit
import CoreGraphics
import Foundation
import GUIVisionAgentLib
import GUIVisionAgentProtocol

// MARK: - Response model

private struct ScreenshotResult: Codable {
    let path: String
    let width: Int
    let height: Int
}

// MARK: - Shared helpers

/// Resolves a WindowInfo to its CGWindowID by matching via CGWindowListCopyWindowInfo.
private func resolveCGWindowID(for info: WindowInfo) -> CGWindowID? {
    WindowCapture.findWindowID(
        appName: info.appName,
        position: info.position,
        size: info.size
    )
}

/// Writes PNG data to the given output path and returns a ScreenshotResult.
private func writePNG(_ data: Data, to outputPath: String) -> ScreenshotResult? {
    guard let nsImage = NSImage(data: data),
          let rep = nsImage.representations.first else {
        return nil
    }
    let width = rep.pixelsWide > 0 ? rep.pixelsWide : Int(nsImage.size.width)
    let height = rep.pixelsHigh > 0 ? rep.pixelsHigh : Int(nsImage.size.height)

    do {
        try data.write(to: URL(fileURLWithPath: outputPath))
        return ScreenshotResult(path: outputPath, width: width, height: height)
    } catch {
        return nil
    }
}

/// Resolves a single matching window or exits with error.
private func resolveSingleWindow(filter: WindowFilter, commandName: String) -> WindowInfo {
    guard let filterStr = filter.window else {
        JSONOutput.error("--window is required for \(commandName)")
    }

    let allWindows = enumerateWindows()
    let matches = allWindows.filter { windowMatches($0, filter: filterStr) }

    if matches.isEmpty {
        JSONOutput.error("No window matching '\(filterStr)'")
    }
    if matches.count > 1 {
        let titles = matches.map { "\($0.appName): \($0.title ?? "<untitled>")" }.joined(separator: "\n")
        JSONOutput.error(
            "Multiple windows match '\(filterStr)' — refine your filter",
            details: "Matches:\n\(titles)"
        )
    }

    return matches[0]
}

// MARK: - ScreenshotWindowCmd

struct ScreenshotWindowCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot-window",
        abstract: "Capture a screenshot of a window"
    )

    @OptionGroup var windowFilter: WindowFilter

    @Option(help: "Output file path for the PNG screenshot")
    var output: String

    func run() throws {
        let windowInfo = resolveSingleWindow(filter: windowFilter, commandName: "screenshot-window")

        guard let windowID = resolveCGWindowID(for: windowInfo) else {
            JSONOutput.error(
                "Could not find CGWindowID for window '\(windowInfo.title ?? windowInfo.appName)'"
            )
        }

        guard let pngData = WindowCapture.captureWindow(windowID: windowID) else {
            JSONOutput.error("CGWindowListCreateImage failed for window '\(windowInfo.title ?? windowInfo.appName)'")
        }

        guard let result = writePNG(pngData, to: output) else {
            JSONOutput.error("Failed to write screenshot to '\(output)'")
        }

        JSONOutput.write(result)
    }
}

// MARK: - ScreenshotRegionCmd

struct ScreenshotRegionCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot-region",
        abstract: "Capture a screenshot of a region within a window"
    )

    @OptionGroup var windowFilter: WindowFilter

    @Option(help: "X coordinate of the region (screen coordinates)")
    var x: Int

    @Option(help: "Y coordinate of the region (screen coordinates)")
    var y: Int

    @Option(help: "Width of the region")
    var width: Int

    @Option(help: "Height of the region")
    var height: Int

    @Option(help: "Output file path for the PNG screenshot")
    var output: String

    func run() throws {
        let windowInfo = resolveSingleWindow(filter: windowFilter, commandName: "screenshot-region")

        guard let windowID = resolveCGWindowID(for: windowInfo) else {
            JSONOutput.error(
                "Could not find CGWindowID for window '\(windowInfo.title ?? windowInfo.appName)'"
            )
        }

        let region = CGRect(x: x, y: y, width: width, height: height)

        guard let pngData = WindowCapture.captureRegion(windowID: windowID, region: region) else {
            JSONOutput.error("CGWindowListCreateImage failed for region \(region)")
        }

        guard let result = writePNG(pngData, to: output) else {
            JSONOutput.error("Failed to write screenshot to '\(output)'")
        }

        JSONOutput.write(result)
    }
}

// MARK: - ScreenshotElementCmd

struct ScreenshotElementCmd: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot-element",
        abstract: "Capture a screenshot of a specific accessibility element"
    )

    @OptionGroup var query: QueryOptions
    @OptionGroup var windowFilter: WindowFilter

    @Option(help: "Padding in points to add around the element bounds")
    var padding: Int = 0

    @Option(help: "Output file path for the PNG screenshot")
    var output: String

    func run() throws {
        let roleFilter: UnifiedRole? = query.role.map { RoleMapper.map(role: $0) }

        var windows = enumerateWindows()
        if let filterStr = windowFilter.window {
            windows = windows.filter { windowMatches($0, filter: filterStr) }
        }

        if windows.isEmpty {
            JSONOutput.error(
                "No matching windows found",
                details: windowFilter.window.map { "Window filter: \($0)" }
            )
        }

        var allElements: [ElementInfo] = []
        for win in windows {
            let rootElement = findWindowElementFor(win) ?? AXElementWrapper.systemWide()
            let elements = TreeWalker.walk(
                root: rootElement,
                depth: 10,
                roleFilter: roleFilter,
                labelFilter: query.label
            )
            allElements.append(contentsOf: elements)
        }

        let result = QueryResolver.resolve(
            in: allElements,
            role: roleFilter,
            label: query.label,
            id: query.id,
            index: query.index
        )

        switch result {
        case .notFound:
            JSONOutput.error("No element found matching query")

        case .multiple(let matches):
            let descriptions = matches.map { describeElem($0) }.joined(separator: "\n")
            JSONOutput.error(
                "Multiple elements matched — refine your query or use --index",
                details: "Matches:\n\(descriptions)"
            )

        case .found(let info):
            guard let position = info.position, let size = info.size else {
                JSONOutput.error(
                    "Element has no position or size — cannot capture screenshot",
                    details: describeElem(info)
                )
            }

            let elementBounds = CGRect(origin: position, size: size)

            // Find the window that contains this element
            guard let containingWindow = windows.first(where: { win in
                let winBounds = CGRect(origin: win.position, size: win.size)
                return winBounds.contains(position)
            }) else {
                JSONOutput.error(
                    "Could not find window containing element at \(position)"
                )
            }

            guard let windowID = resolveCGWindowID(for: containingWindow) else {
                JSONOutput.error(
                    "Could not find CGWindowID for window '\(containingWindow.title ?? containingWindow.appName)'"
                )
            }

            guard let pngData = WindowCapture.captureElement(
                windowID: windowID,
                elementBounds: elementBounds,
                padding: padding
            ) else {
                JSONOutput.error("CGWindowListCreateImage failed for element at \(elementBounds)")
            }

            guard let screenshotResult = writePNG(pngData, to: output) else {
                JSONOutput.error("Failed to write screenshot to '\(output)'")
            }

            JSONOutput.write(screenshotResult)
        }
    }
}

// MARK: - Private helpers

private func findWindowElementFor(_ win: WindowInfo) -> (any AccessibleElement)? {
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

private func describeElem(_ info: ElementInfo) -> String {
    var parts: [String] = [info.role.rawValue]
    if let label = info.label { parts.append("label=\(label)") }
    if let id = info.id { parts.append("id=\(id)") }
    if let pos = info.position { parts.append("pos=(\(Int(pos.x)),\(Int(pos.y)))") }
    return parts.joined(separator: " ")
}

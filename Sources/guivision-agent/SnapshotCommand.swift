import ArgumentParser
import AppKit
import GUIVisionAgentLib
import GUIVisionAgentProtocol

struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Capture an accessibility tree snapshot of windows"
    )

    @Option(help: "Output mode: interact, layout, or full")
    var mode: String = "interact"

    @OptionGroup var windowFilter: WindowFilter

    @Option(help: "Filter by element role")
    var role: String?

    @Option(help: "Filter by element label substring")
    var label: String?

    @Option(help: "Maximum tree depth to walk")
    var depth: Int = 3

    func run() throws {
        let roleFilter: UnifiedRole? = role.map { RoleMapper.map(role: $0) }

        var windows = enumerateWindows()

        if let filterStr = windowFilter.window {
            windows = windows.filter { windowMatches($0, filter: filterStr) }
        }

        let snapshotWindows = windows.map { win -> WindowInfo in
            guard let winElement = findWindowElement(matching: win) else {
                return win
            }

            let rawElements = TreeWalker.walk(
                root: winElement,
                depth: depth,
                roleFilter: roleFilter,
                labelFilter: label
            )

            let filteredElements: [ElementInfo]
            switch mode {
            case "interact":
                filteredElements = filterInteractive(rawElements)
            case "layout":
                filteredElements = filterLayout(rawElements)
            default:
                filteredElements = rawElements
            }

            return WindowInfo(
                title: win.title,
                windowType: win.windowType,
                size: win.size,
                position: win.position,
                appName: win.appName,
                focused: win.focused,
                elements: filteredElements
            )
        }

        let response = SnapshotResponse(windows: snapshotWindows)
        JSONOutput.write(response)
    }
}

// MARK: - Window element lookup

private func findWindowElement(matching win: WindowInfo) -> (any AccessibleElement)? {
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

// MARK: - Mode filters

private func isInteractive(_ element: ElementInfo) -> Bool {
    if !element.actions.isEmpty { return true }
    if element.focused { return true }
    switch element.role {
    case .button, .checkbox, .radio, .textfield, .editableText, .slider,
         .comboBox, .switch, .link, .menuItem, .tab, .disclosureTriangle,
         .colorWell, .datePicker, .spinButton:
        return true
    default:
        return false
    }
}

private func filterInteractive(_ elements: [ElementInfo]) -> [ElementInfo] {
    elements.compactMap { filterInteractiveElement($0) }
}

private func filterInteractiveElement(_ element: ElementInfo) -> ElementInfo? {
    let filteredChildren = element.children.map { filterInteractive($0) } ?? []
    let selfInteractive = isInteractive(element)

    if !selfInteractive && filteredChildren.isEmpty { return nil }

    return ElementInfo(
        role: element.role,
        label: element.label,
        value: element.value,
        description: element.description,
        id: element.id,
        enabled: element.enabled,
        focused: element.focused,
        position: element.position,
        size: element.size,
        childCount: element.childCount,
        actions: element.actions,
        platformRole: element.platformRole,
        children: filteredChildren.isEmpty ? nil : filteredChildren
    )
}

private func filterLayout(_ elements: [ElementInfo]) -> [ElementInfo] {
    elements.compactMap { filterLayoutElement($0) }
}

private func filterLayoutElement(_ element: ElementInfo) -> ElementInfo? {
    let filteredChildren = element.children.map { filterLayout($0) } ?? []
    let hasGeometry = element.position != nil && element.size != nil

    if !hasGeometry && filteredChildren.isEmpty { return nil }

    return ElementInfo(
        role: element.role,
        label: element.label,
        value: element.value,
        description: element.description,
        id: element.id,
        enabled: element.enabled,
        focused: element.focused,
        position: element.position,
        size: element.size,
        childCount: element.childCount,
        actions: element.actions,
        platformRole: element.platformRole,
        children: filteredChildren.isEmpty ? nil : filteredChildren
    )
}

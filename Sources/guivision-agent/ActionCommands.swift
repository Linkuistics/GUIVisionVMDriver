import ArgumentParser
import AppKit
import GUIVisionAgentLib
import GUIVisionAgentProtocol

// MARK: - Live element lookup

/// Walks the live AX tree to find an element matching the given `ElementInfo` by role, label, and position.
func findLiveElement(matching info: ElementInfo, in windows: [WindowInfo]) -> (any AccessibleElement)? {
    let runningApps = NSWorkspace.shared.runningApplications
    for app in runningApps {
        guard app.activationPolicy != .prohibited else { continue }
        let appWrapper = AXElementWrapper.application(pid: app.processIdentifier)
        for winElement in appWrapper.children() {
            guard winElement.role() == "AXWindow" else { continue }
            if let found = searchLiveTree(root: winElement, matching: info) {
                return found
            }
        }
    }
    return nil
}

private func searchLiveTree(root: any AccessibleElement, matching info: ElementInfo) -> (any AccessibleElement)? {
    for child in root.children() {
        if liveElementMatches(child, info: info) {
            return child
        }
        if let found = searchLiveTree(root: child, matching: info) {
            return found
        }
    }
    return nil
}

private func liveElementMatches(_ element: any AccessibleElement, info: ElementInfo) -> Bool {
    let mappedRole = RoleMapper.map(role: element.role() ?? "", subrole: element.subrole())
    guard mappedRole == info.role else { return false }

    if let infoLabel = info.label {
        guard let elementLabel = element.label(),
              elementLabel == infoLabel else { return false }
    } else {
        guard element.label() == nil else { return false }
    }

    if let infoPos = info.position, let elementPos = element.position() {
        guard elementPos.x == infoPos.x && elementPos.y == infoPos.y else { return false }
    }

    return true
}

// MARK: - Shared action resolution

private func resolveAndAct(
    queryOptions: QueryOptions,
    windowFilter: WindowFilter,
    actionName: String,
    perform: (any AccessibleElement) throws -> Void
) {
    let roleFilter: UnifiedRole? = queryOptions.role.map { RoleMapper.map(role: $0) }

    var windows = enumerateWindows()
    if let filterStr = windowFilter.window {
        windows = windows.filter { windowMatches($0, filter: filterStr) }
    }

    if windows.isEmpty {
        JSONOutput.error("No matching windows found", details: windowFilter.window.map { "Window filter: \($0)" })
    }

    var allElements: [ElementInfo] = []
    for win in windows {
        let elements = TreeWalker.walk(
            root: findWindowElementFor(win) ?? AXElementWrapper.systemWide(),
            depth: 10,
            roleFilter: roleFilter,
            labelFilter: queryOptions.label
        )
        allElements.append(contentsOf: elements)
    }

    let result = QueryResolver.resolve(
        in: allElements,
        role: roleFilter,
        label: queryOptions.label,
        id: queryOptions.id,
        index: queryOptions.index
    )

    switch result {
    case .notFound:
        JSONOutput.error("No element found matching query", details: describeQuery(queryOptions))

    case .multiple(let matches):
        let descriptions = matches.map { describeElement($0) }.joined(separator: "\n")
        JSONOutput.error(
            "Multiple elements matched — refine your query or use --index",
            details: "Matches:\n\(descriptions)"
        )

    case .found(let info):
        guard let liveElement = findLiveElement(matching: info, in: windows) else {
            JSONOutput.error("Element found in snapshot but could not locate live AX element", details: describeElement(info))
        }
        do {
            try perform(liveElement)
            let response = ActionResponse(success: true, message: "\(actionName) performed successfully")
            JSONOutput.write(response)
        } catch {
            let response = ActionResponse(success: false, message: "\(actionName) failed: \(error)")
            JSONOutput.write(response)
        }
    }
}

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

private func describeQuery(_ opts: QueryOptions) -> String {
    var parts: [String] = []
    if let r = opts.role { parts.append("role=\(r)") }
    if let l = opts.label { parts.append("label=\(l)") }
    if let i = opts.id { parts.append("id=\(i)") }
    if let idx = opts.index { parts.append("index=\(idx)") }
    return parts.joined(separator: ", ")
}

private func describeElement(_ info: ElementInfo) -> String {
    var parts: [String] = [info.role.rawValue]
    if let label = info.label { parts.append("label=\(label)") }
    if let id = info.id { parts.append("id=\(id)") }
    if let pos = info.position { parts.append("pos=(\(Int(pos.x)),\(Int(pos.y)))") }
    return parts.joined(separator: " ")
}

// MARK: - PressCommand

struct PressCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "Press (click) an accessibility element"
    )

    @OptionGroup var query: QueryOptions
    @OptionGroup var windowFilter: WindowFilter

    func run() throws {
        resolveAndAct(queryOptions: query, windowFilter: windowFilter, actionName: "press") { element in
            try ActionPerformer.press(element: element)
        }
    }
}

// MARK: - SetValueCommand

struct SetValueCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-value",
        abstract: "Set the value of an accessibility element"
    )

    @OptionGroup var query: QueryOptions
    @OptionGroup var windowFilter: WindowFilter

    @Option(help: "Value to set on the element")
    var value: String

    func run() throws {
        resolveAndAct(queryOptions: query, windowFilter: windowFilter, actionName: "set-value") { element in
            try ActionPerformer.setValue(element: element, value: value)
        }
    }
}

// MARK: - FocusElementCommand

struct FocusElementCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Focus an accessibility element"
    )

    @OptionGroup var query: QueryOptions
    @OptionGroup var windowFilter: WindowFilter

    func run() throws {
        resolveAndAct(queryOptions: query, windowFilter: windowFilter, actionName: "focus") { element in
            try ActionPerformer.focus(element: element)
        }
    }
}

// MARK: - ShowMenuCommand

struct ShowMenuCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show-menu",
        abstract: "Show the context menu for an accessibility element"
    )

    @OptionGroup var query: QueryOptions
    @OptionGroup var windowFilter: WindowFilter

    func run() throws {
        resolveAndAct(queryOptions: query, windowFilter: windowFilter, actionName: "show-menu") { element in
            try ActionPerformer.showMenu(element: element)
        }
    }
}

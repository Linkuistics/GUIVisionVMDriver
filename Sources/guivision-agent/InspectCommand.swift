import ArgumentParser
import AppKit
import GUIVisionAgentLib
import GUIVisionAgentProtocol

struct InspectCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspect a single accessibility element with detailed properties including font info"
    )

    @OptionGroup var query: QueryOptions
    @OptionGroup var windowFilter: WindowFilter

    func run() throws {
        let roleFilter: UnifiedRole? = query.role.map { RoleMapper.map(role: $0) }

        var windows = enumerateWindows()
        if let filterStr = windowFilter.window {
            windows = windows.filter { windowMatches($0, filter: filterStr) }
        }

        if windows.isEmpty {
            JSONOutput.error("No matching windows found", details: windowFilter.window.map { "Window filter: \($0)" })
        }

        var allElements: [ElementInfo] = []
        for win in windows {
            let winElement = findWindowElementForInspect(win) ?? AXElementWrapper.systemWide()
            let elements = TreeWalker.walk(
                root: winElement,
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
            JSONOutput.error("No element found matching query", details: describeInspectQuery(query))

        case .multiple(let matches):
            let descriptions = matches.map { describeInspectElement($0) }.joined(separator: "\n")
            JSONOutput.error(
                "Multiple elements matched — refine your query or use --index",
                details: "Matches:\n\(descriptions)"
            )

        case .found(let info):
            guard let liveElement = findLiveElement(matching: info, in: windows) else {
                JSONOutput.error(
                    "Element found in snapshot but could not locate live AX element",
                    details: describeInspectElement(info)
                )
            }

            let font = liveElement.fontInfo()
            let pos = liveElement.position()
            let sz = liveElement.size()
            let bounds: CGRect? = pos.flatMap { p in
                sz.map { s in CGRect(origin: p, size: s) }
            }

            let response = InspectResponse(
                element: info,
                fontFamily: font?.family,
                fontSize: font?.size,
                fontWeight: font?.weight,
                textColor: nil,
                bounds: bounds
            )
            JSONOutput.write(response)
        }
    }
}

private func findWindowElementForInspect(_ win: WindowInfo) -> (any AccessibleElement)? {
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

private func describeInspectQuery(_ opts: QueryOptions) -> String {
    var parts: [String] = []
    if let r = opts.role { parts.append("role=\(r)") }
    if let l = opts.label { parts.append("label=\(l)") }
    if let i = opts.id { parts.append("id=\(i)") }
    if let idx = opts.index { parts.append("index=\(idx)") }
    return parts.joined(separator: ", ")
}

private func describeInspectElement(_ info: ElementInfo) -> String {
    var parts: [String] = [info.role.rawValue]
    if let label = info.label { parts.append("label=\(label)") }
    if let id = info.id { parts.append("id=\(id)") }
    if let pos = info.position { parts.append("pos=(\(Int(pos.x)),\(Int(pos.y)))") }
    return parts.joined(separator: " ")
}

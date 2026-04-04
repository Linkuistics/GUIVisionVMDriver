import ArgumentParser
import Foundation
import GUIVisionAgentProtocol
import GUIVisionVMDriver

struct AgentCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Interact with the in-VM accessibility agent",
        subcommands: [
            AgentSnapshotCmd.self,
            AgentInspectCmd.self,
            AgentPressCmd.self,
            AgentSetValueCmd.self,
            AgentFocusCmd.self,
            AgentShowMenuCmd.self,
            AgentWindowsCmd.self,
            AgentWindowFocusCmd.self,
            AgentWindowResizeCmd.self,
            AgentWindowMoveCmd.self,
            AgentWindowCloseCmd.self,
            AgentWindowMinimizeCmd.self,
            AgentScreenshotElementCmd.self,
            AgentScreenshotWindowCmd.self,
            AgentWaitCmd.self,
        ]
    )
}

// MARK: - Shared Option Groups

struct AgentQueryOptions: ParsableArguments {
    @Option(name: .long, help: "Element role filter")
    var role: String?

    @Option(name: .long, help: "Element label filter")
    var label: String?

    @Option(name: .long, help: "Element ID filter")
    var id: String?

    @Option(name: .long, help: "Element index (0-based)")
    var index: Int?
}

struct AgentWindowFilter: ParsableArguments {
    @Option(name: .long, help: "Window title or app name filter")
    var window: String?
}

// MARK: - Helper

private func makeAgent(from connection: ConnectionOptions) throws -> AgentClient {
    let spec = try connection.resolve()
    let sshClient = try SSHClient(connectionSpec: spec)
    return AgentClient(sshClient: sshClient)
}

// MARK: - Snapshot

struct AgentSnapshotCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Capture accessibility element tree snapshot"
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .long, help: "Snapshot mode (full, interactive)")
    var mode: String?

    @Option(name: .long, help: "Window title or app name filter")
    var window: String?

    @Option(name: .long, help: "Element role filter")
    var role: String?

    @Option(name: .long, help: "Element label filter")
    var label: String?

    @Option(name: .long, help: "Maximum tree depth")
    var depth: Int?

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.snapshot(mode: mode, window: window, role: role, label: label, depth: depth)
        let output = try AgentFormatter.formatSnapshot(data)
        print(output)
    }
}

// MARK: - Inspect

struct AgentInspectCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "inspect",
        abstract: "Inspect a single element in detail"
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var query: AgentQueryOptions
    @OptionGroup var windowFilter: AgentWindowFilter

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.inspect(
            role: query.role,
            label: query.label,
            window: windowFilter.window,
            id: query.id,
            index: query.index
        )
        let output = try AgentFormatter.formatInspect(data)
        print(output)
    }
}

// MARK: - Press

struct AgentPressCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "press",
        abstract: "Press (activate) an element"
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var query: AgentQueryOptions
    @OptionGroup var windowFilter: AgentWindowFilter

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.press(
            role: query.role,
            label: query.label,
            window: windowFilter.window,
            id: query.id,
            index: query.index
        )
        let output = try AgentFormatter.formatAction(data)
        print(output)
    }
}

// MARK: - Set Value

struct AgentSetValueCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-value",
        abstract: "Set the value of an element"
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var query: AgentQueryOptions
    @OptionGroup var windowFilter: AgentWindowFilter

    @Option(name: .long, help: "Value to set")
    var value: String

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.setValue(
            role: query.role,
            label: query.label,
            window: windowFilter.window,
            id: query.id,
            index: query.index,
            value: value
        )
        let output = try AgentFormatter.formatAction(data)
        print(output)
    }
}

// MARK: - Focus

struct AgentFocusCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "focus",
        abstract: "Focus an element"
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var query: AgentQueryOptions
    @OptionGroup var windowFilter: AgentWindowFilter

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.focus(
            role: query.role,
            label: query.label,
            window: windowFilter.window,
            id: query.id,
            index: query.index
        )
        let output = try AgentFormatter.formatAction(data)
        print(output)
    }
}

// MARK: - Show Menu

struct AgentShowMenuCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show-menu",
        abstract: "Show the context menu of an element"
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var query: AgentQueryOptions
    @OptionGroup var windowFilter: AgentWindowFilter

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.showMenu(
            role: query.role,
            label: query.label,
            window: windowFilter.window,
            id: query.id,
            index: query.index
        )
        let output = try AgentFormatter.formatAction(data)
        print(output)
    }
}

// MARK: - Windows

struct AgentWindowsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "windows",
        abstract: "List all windows"
    )

    @OptionGroup var connection: ConnectionOptions

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.windows()
        let output = try AgentFormatter.formatWindows(data)
        print(output)
    }
}

// MARK: - Window Focus

struct AgentWindowFocusCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window-focus",
        abstract: "Focus a window"
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .long, help: "Window title or app name filter")
    var window: String

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.windowFocus(window: window)
        let output = try AgentFormatter.formatAction(data)
        print(output)
    }
}

// MARK: - Window Resize

struct AgentWindowResizeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window-resize",
        abstract: "Resize a window"
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .long, help: "Window title or app name filter")
    var window: String

    @Option(name: .long, help: "New width")
    var width: Int

    @Option(name: .long, help: "New height")
    var height: Int

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.windowResize(window: window, width: width, height: height)
        let output = try AgentFormatter.formatAction(data)
        print(output)
    }
}

// MARK: - Window Move

struct AgentWindowMoveCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window-move",
        abstract: "Move a window"
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .long, help: "Window title or app name filter")
    var window: String

    @Option(name: .long, help: "New X position")
    var x: Int

    @Option(name: .long, help: "New Y position")
    var y: Int

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.windowMove(window: window, x: x, y: y)
        let output = try AgentFormatter.formatAction(data)
        print(output)
    }
}

// MARK: - Window Close

struct AgentWindowCloseCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window-close",
        abstract: "Close a window"
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .long, help: "Window title or app name filter")
    var window: String

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.windowClose(window: window)
        let output = try AgentFormatter.formatAction(data)
        print(output)
    }
}

// MARK: - Window Minimize

struct AgentWindowMinimizeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "window-minimize",
        abstract: "Minimize a window"
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .long, help: "Window title or app name filter")
    var window: String

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.windowMinimize(window: window)
        let output = try AgentFormatter.formatAction(data)
        print(output)
    }
}

// MARK: - Screenshot Element

struct AgentScreenshotElementCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot-element",
        abstract: "Screenshot a specific element"
    )

    @OptionGroup var connection: ConnectionOptions
    @OptionGroup var query: AgentQueryOptions
    @OptionGroup var windowFilter: AgentWindowFilter

    @Option(name: .long, help: "Padding around element in pixels")
    var padding: Int?

    @Option(name: .long, help: "Output file path")
    var output: String

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.screenshotElement(
            role: query.role,
            label: query.label,
            window: windowFilter.window,
            id: query.id,
            index: query.index,
            padding: padding,
            output: output
        )
        let result = try AgentFormatter.formatAction(data)
        print(result)
        print("Screenshot saved to \(output)")
    }
}

// MARK: - Screenshot Window

struct AgentScreenshotWindowCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "screenshot-window",
        abstract: "Screenshot a window"
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .long, help: "Window title or app name filter")
    var window: String

    @Option(name: .long, help: "Output file path")
    var output: String

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.screenshotWindow(window: window, output: output)
        let result = try AgentFormatter.formatAction(data)
        print(result)
        print("Screenshot saved to \(output)")
    }
}

// MARK: - Wait

struct AgentWaitCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Wait for accessibility to be ready"
    )

    @OptionGroup var connection: ConnectionOptions

    @Option(name: .long, help: "Window title or app name filter")
    var window: String?

    @Option(name: .long, help: "Timeout in seconds")
    var timeout: Int?

    mutating func run() async throws {
        let agent = try makeAgent(from: connection)
        let data = try agent.wait(window: window, timeout: timeout)
        let output = try AgentFormatter.formatAction(data)
        print(output)
    }
}

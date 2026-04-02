import ArgumentParser
import GUIVisionVMDriver

struct InputCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "input",
        abstract: "Send keyboard and mouse input",
        subcommands: [
            KeyPressCommand.self,
            KeyDownCommand.self,
            KeyUpCommand.self,
            TypeCommand.self,
            ClickCommand.self,
            MouseDownCommand.self,
            MouseUpCommand.self,
            MoveCommand.self,
            ScrollCommand.self,
            DragCommand.self,
        ]
    )
}

struct KeyPressCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key", abstract: "Press a key")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Key name (e.g. return, tab, a, f1)")
    var key: String

    @Option(name: .shortAndLong, help: "Modifier keys (comma-separated: cmd,shift,alt,ctrl)")
    var modifiers: String?

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        let mods = modifiers?.split(separator: ",").map(String.init) ?? []
        try await capture.withConnection { conn in
            try VNCInput.pressKey(key, modifiers: mods, platform: spec.platform, connection: conn)
        }
        print("Key pressed: \(key)\(mods.isEmpty ? "" : " + \(mods.joined(separator: "+"))")")
    }
}

struct KeyDownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key-down", abstract: "Send key-down (without releasing)")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Key name (e.g. shift, cmd, a)")
    var key: String

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.keyDown(key, platform: spec.platform, connection: conn)
        }
        print("Key down: \(key)")
    }
}

struct KeyUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key-up", abstract: "Send key-up (release)")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Key name (e.g. shift, cmd, a)")
    var key: String

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.keyUp(key, platform: spec.platform, connection: conn)
        }
        print("Key up: \(key)")
    }
}

struct TypeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "type", abstract: "Type text")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Text to type")
    var text: String

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            VNCInput.typeText(text, connection: conn)
        }
        print("Typed: \(text)")
    }
}

struct ClickCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "click", abstract: "Click at coordinates")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "X coordinate")
    var x: Int

    @Argument(help: "Y coordinate")
    var y: Int

    @Option(name: .shortAndLong, help: "Mouse button (left, right, middle)")
    var button: String = "left"

    @Option(name: .shortAndLong, help: "Click count")
    var count: Int = 1

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.click(x: UInt16(x), y: UInt16(y), button: button, count: count, connection: conn)
        }
        print("Clicked at (\(x), \(y)) button=\(button) count=\(count)")
    }
}

struct MouseDownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mouse-down", abstract: "Press mouse button (without releasing)")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "X coordinate")
    var x: Int

    @Argument(help: "Y coordinate")
    var y: Int

    @Option(name: .shortAndLong, help: "Mouse button (left, right, middle)")
    var button: String = "left"

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.mouseDown(x: UInt16(x), y: UInt16(y), button: button, connection: conn)
        }
        print("Mouse down at (\(x), \(y)) button=\(button)")
    }
}

struct MouseUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "mouse-up", abstract: "Release mouse button")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "X coordinate")
    var x: Int

    @Argument(help: "Y coordinate")
    var y: Int

    @Option(name: .shortAndLong, help: "Mouse button (left, right, middle)")
    var button: String = "left"

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.mouseUp(x: UInt16(x), y: UInt16(y), button: button, connection: conn)
        }
        print("Mouse up at (\(x), \(y)) button=\(button)")
    }
}

struct MoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "move", abstract: "Move mouse")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "X coordinate")
    var x: Int

    @Argument(help: "Y coordinate")
    var y: Int

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            VNCInput.mouseMove(x: UInt16(x), y: UInt16(y), connection: conn)
        }
        print("Mouse moved to (\(x), \(y))")
    }
}

struct ScrollCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "scroll", abstract: "Scroll at coordinates")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "X coordinate")
    var x: Int

    @Argument(help: "Y coordinate")
    var y: Int

    @Option(name: .long, help: "Horizontal scroll amount (negative=left)")
    var dx: Int = 0

    @Option(name: .long, help: "Vertical scroll amount (negative=up)")
    var dy: Int = 0

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            VNCInput.scroll(x: UInt16(x), y: UInt16(y), deltaX: dx, deltaY: dy, connection: conn)
        }
        print("Scrolled at (\(x), \(y)) dx=\(dx) dy=\(dy)")
    }
}

struct DragCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "drag", abstract: "Drag from one point to another")

    @OptionGroup var connection: ConnectionOptions

    @Argument(help: "Start X")
    var fromX: Int

    @Argument(help: "Start Y")
    var fromY: Int

    @Argument(help: "End X")
    var toX: Int

    @Argument(help: "End Y")
    var toY: Int

    @Option(name: .shortAndLong, help: "Mouse button")
    var button: String = "left"

    @Option(name: .shortAndLong, help: "Number of interpolation steps")
    var steps: Int = 10

    mutating func run() async throws {
        let spec = try connection.resolve()
        let capture = VNCCapture(spec: spec.vnc)
        try await capture.connect()
        defer { Task { await capture.disconnect() } }

        try await capture.withConnection { conn in
            try VNCInput.drag(fromX: UInt16(fromX), fromY: UInt16(fromY),
                              toX: UInt16(toX), toY: UInt16(toY),
                              button: button, steps: steps, connection: conn)
        }
        print("Dragged from (\(fromX),\(fromY)) to (\(toX),\(toY))")
    }
}

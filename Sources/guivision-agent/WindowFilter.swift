import ArgumentParser

struct WindowFilter: ParsableArguments {
    @Option(help: "Filter by window title substring or app name")
    var window: String?
}

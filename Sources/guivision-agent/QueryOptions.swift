import ArgumentParser

struct QueryOptions: ParsableArguments {
    @Option(help: "Filter by element role")
    var role: String?

    @Option(help: "Filter by element label")
    var label: String?

    @Option(help: "Filter by element identifier")
    var id: String?

    @Option(help: "Select element by index")
    var index: Int?
}

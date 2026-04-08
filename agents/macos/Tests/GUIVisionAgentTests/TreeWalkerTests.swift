import Testing
import CoreGraphics
import GUIVisionAgentLib
import GUIVisionAgentProtocol

// MARK: - Full-depth walking

@Test func walkThreeLevelTreeReturnsAllElements() {
    let leaf1 = MockAccessibleElement(role: "AXStaticText", label: "Leaf1")
    let leaf2 = MockAccessibleElement(role: "AXStaticText", label: "Leaf2")
    let mid = MockAccessibleElement(role: "AXGroup", label: "Mid", children: [leaf1, leaf2])
    let root = MockAccessibleElement(role: "AXWindow", label: "Root", children: [mid])

    let result = TreeWalker.walk(root: root, depth: 3)

    // Root has 1 child (mid), mid has 2 children (leaf1, leaf2)
    #expect(result.count == 1) // walk returns root's children
    let midInfo = result[0]
    #expect(midInfo.role == .group)
    #expect(midInfo.label == "Mid")
    #expect(midInfo.children?.count == 2)
    #expect(midInfo.children?[0].role == .text)
    #expect(midInfo.children?[0].label == "Leaf1")
    #expect(midInfo.children?[1].label == "Leaf2")
}

// MARK: - Depth limiting

@Test func walkDepthOneReturnsOnlyTopLevelChildren() {
    let leaf = MockAccessibleElement(role: "AXStaticText", label: "Leaf")
    let mid = MockAccessibleElement(role: "AXGroup", label: "Mid", children: [leaf])
    let root = MockAccessibleElement(role: "AXWindow", label: "Root", children: [mid])

    let result = TreeWalker.walk(root: root, depth: 1)

    #expect(result.count == 1)
    let midInfo = result[0]
    #expect(midInfo.label == "Mid")
    // Children should be nil (depth exhausted) but childCount reflects actual count
    #expect(midInfo.children == nil)
    #expect(midInfo.childCount == 1)
}

// MARK: - Role filtering

@Test func walkFilterByRoleIncludesOnlyMatchingRole() {
    let button1 = MockAccessibleElement(role: "AXButton", label: "OK")
    let text1 = MockAccessibleElement(role: "AXStaticText", label: "Hello")
    let button2 = MockAccessibleElement(role: "AXButton", label: "Cancel")
    let group = MockAccessibleElement(role: "AXGroup", label: "Container", children: [button1, text1, button2])
    let root = MockAccessibleElement(role: "AXWindow", label: "Win", children: [group])

    let result = TreeWalker.walk(root: root, depth: 3, roleFilter: .button)

    // The group should still appear because it has matching descendants
    #expect(result.count == 1)
    let groupInfo = result[0]
    #expect(groupInfo.role == .group)
    // Only buttons should be in children
    #expect(groupInfo.children?.count == 2)
    #expect(groupInfo.children?[0].label == "OK")
    #expect(groupInfo.children?[1].label == "Cancel")
}

// MARK: - Label filtering

@Test func walkFilterByLabelCaseInsensitive() {
    let elem1 = MockAccessibleElement(role: "AXButton", label: "Save Document")
    let elem2 = MockAccessibleElement(role: "AXButton", label: "Cancel")
    let elem3 = MockAccessibleElement(role: "AXButton", label: "save as")
    let root = MockAccessibleElement(role: "AXWindow", label: "Win", children: [elem1, elem2, elem3])

    let result = TreeWalker.walk(root: root, depth: 2, labelFilter: "save")

    // Only elements with "save" (case-insensitive) in their label
    #expect(result.count == 2)
    #expect(result[0].label == "Save Document")
    #expect(result[1].label == "save as")
}

// MARK: - Element conversion

@Test func walkConvertsAccessibleElementToElementInfoCorrectly() {
    let element = MockAccessibleElement(
        role: "AXButton",
        subrole: nil,
        label: "OK",
        value: "1",
        description: "Confirm button",
        identifier: "btn-ok",
        enabled: true,
        focused: true,
        position: CGPoint(x: 10, y: 20),
        size: CGSize(width: 80, height: 30),
        children: [],
        actionNames: ["AXPress"]
    )
    let root = MockAccessibleElement(role: "AXWindow", children: [element])

    let result = TreeWalker.walk(root: root, depth: 2)

    #expect(result.count == 1)
    let info = result[0]
    #expect(info.role == .button) // mapped via RoleMapper
    #expect(info.label == "OK")
    #expect(info.value == "1")
    #expect(info.description == "Confirm button")
    #expect(info.id == "btn-ok")
    #expect(info.enabled == true)
    #expect(info.focused == true)
    #expect(info.position == CGPoint(x: 10, y: 20))
    #expect(info.size == CGSize(width: 80, height: 30))
    #expect(info.actions == ["AXPress"])
    #expect(info.platformRole == "AXButton")
    #expect(info.childCount == 0)
    #expect(info.children?.count == 0)
}

// MARK: - Child count at depth limit

@Test func walkChildCountSetCorrectlyWhenDepthLimitReached() {
    let leaf1 = MockAccessibleElement(role: "AXStaticText", label: "A")
    let leaf2 = MockAccessibleElement(role: "AXStaticText", label: "B")
    let leaf3 = MockAccessibleElement(role: "AXStaticText", label: "C")
    let mid = MockAccessibleElement(role: "AXGroup", label: "Group", children: [leaf1, leaf2, leaf3])
    let root = MockAccessibleElement(role: "AXWindow", children: [mid])

    let result = TreeWalker.walk(root: root, depth: 1)

    #expect(result.count == 1)
    let midInfo = result[0]
    #expect(midInfo.childCount == 3) // actual child count
    #expect(midInfo.children == nil) // not expanded due to depth limit
}

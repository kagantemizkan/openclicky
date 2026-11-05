//
//  MCPConnectionsTests.swift
//  Connections stay read-only and appear only when needed; a reply using
//  tools is counted properly; the cursor can be moved and its message closed.
//

import XCTest
@testable import OpenClicky

final class MCPConnectionsTests: XCTestCase {
    func testAutomaticLooksCantEditButUserTurnsCan() {
        let reading = MCPConnections.toolLists(for: [.blender], canEdit: { _ in false })
        XCTAssertFalse(reading.allowed.contains("mcp__blender__execute_blender_code"))
        XCTAssertTrue(reading.hidden.contains("mcp__blender__execute_blender_code"))

        let editing = MCPConnections.toolLists(for: [.blender], canEdit: { _ in true })
        XCTAssertTrue(editing.allowed.contains("mcp__blender__execute_blender_code"))
        XCTAssertFalse(editing.hidden.contains("mcp__blender__execute_blender_code"))
    }

    func testToolThatSendsDataOutIsNeverAllowed() {
        let lists = MCPConnections.toolLists(for: [.affinity], canEdit: { _ in true })
        XCTAssertFalse(lists.allowed.contains("mcp__affinity__report_sdk_issue"))
        XCTAssertTrue(lists.hidden.contains("mcp__affinity__report_sdk_issue"))
    }

    func testReadListHoldsNoToolThatCanWrite() {
        let writeWords = ["execute", "save", "add_", "report", "use_figma", "generate", "upload", "update",
                          "send", "weave", "jump", "_to_path", "create_new", "create_shader", "create_generative"]
        for connection in MCPConnection.all {
            for tool in connection.readTools {
                for word in writeWords {
                    XCTAssertFalse(tool.contains(word), "\(connection.id): \(tool) looks like it can write")
                }
            }
            XCTAssertTrue(Set(connection.readTools).isDisjoint(with: connection.hiddenTools), connection.id)
            XCTAssertTrue(Set(connection.readTools).isDisjoint(with: connection.writeTools), connection.id)
            XCTAssertTrue(Set(connection.writeTools).isDisjoint(with: connection.hiddenTools), connection.id)
        }
    }

    func testAttachesOnlyWhileTheAppIsInFrontOrBeingTaught() {
        let all = Set(MCPConnection.all.map(\.id))
        XCTAssertEqual(MCPConnections.connections(enabled: all, frontmostBundleId: "com.apple.Safari", lessonConnection: nil), [])
        XCTAssertEqual(
            MCPConnections.connections(enabled: all, frontmostBundleId: MCPConnection.blender.bundleId, lessonConnection: nil),
            [.blender]
        )
        XCTAssertEqual(
            MCPConnections.connections(enabled: all, frontmostBundleId: "com.apple.Safari", lessonConnection: .affinity),
            [.affinity]
        )
        XCTAssertEqual(
            MCPConnections.connections(enabled: [], frontmostBundleId: MCPConnection.blender.bundleId, lessonConnection: .blender),
            [],
            "turning a connection off wins"
        )
    }

    func testOnlyTheNeededServerDefinitionsAreCopied() {
        let settings: [String: Any] = ["mcpServers": ["blender": ["command": "uvx"], "higgsfield": ["type": "http"]]]
        let definitions = MCPConnections.serverDefinitions(for: [.blender, .figma], claudeSettings: settings)
        XCTAssertEqual(Array(definitions.keys), ["blender"])
    }

    func testRunnerPassesTheAllowlistAndKeepsBuiltInToolsOff() throws {
        let runner = ClaudeCLIRunner(binaryURL: URL(fileURLWithPath: "/usr/bin/true"))
        let plain = runner.buildArgs(systemPrompt: "s", model: "m", resumeSessionId: nil)
        XCTAssertFalse(plain.contains("--allowedTools"))
        XCTAssertEqual(plain[try XCTUnwrap(plain.firstIndex(of: "--mcp-config")) + 1], "{\"mcpServers\":{}}")

        let mcp = MCPTurnConfig(configPath: "/tmp/c.json", allowedTools: ["mcp__a__x", "mcp__a__y"], hiddenTools: ["mcp__a__z"])
        let args = runner.buildArgs(systemPrompt: "s", model: "m", resumeSessionId: nil, mcp: mcp)
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--mcp-config")) + 1], "/tmp/c.json")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--allowedTools")) + 1], "mcp__a__x,mcp__a__y")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--disallowedTools")) + 1], "mcp__a__z")
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of: "--tools")) + 1], "")
        XCTAssertTrue(args.contains("--strict-mcp-config"))
    }

    func testToolOwnerIsFoundFromItsName() {
        XCTAssertEqual(MCPConnection.owner(ofTool: "mcp__blender__search_api_docs"), .blender)
        XCTAssertNil(MCPConnection.owner(ofTool: "mcp__other__tool"))
    }

    func testAddsUpMessagesAndKeepsTheLastContext() {
        var usage = TurnUsage()
        usage.message(TokenUsage(input: 1, cacheWrite: 100, cacheRead: 0, output: 1))
        usage.message(TokenUsage(input: 1, cacheWrite: 100, cacheRead: 0, output: 9))
        usage.messageStopped()
        usage.message(TokenUsage(input: 2, cacheWrite: 10, cacheRead: 101, output: 5))
        usage.messageStopped()
        XCTAssertEqual(usage.total, TokenUsage(input: 3, cacheWrite: 110, cacheRead: 101, output: 14))
        XCTAssertEqual(usage.lastContext, 113)
        usage.result(TokenUsage(input: 9, cacheWrite: 9, cacheRead: 9, output: 9))
        XCTAssertEqual(usage.lastContext, 113, "the result line doesn't replace counted messages")
    }

    func testCaptionTextPicksReadableColour() {
        XCTAssertTrue(ThemeColor.blue.usesDarkText)
        XCTAssertFalse(ThemeColor.slate.usesDarkText)
    }

    /// Real servers through the real CLI. Uses the Claude plan, so it runs
    /// only when asked for. Prints speed and token cost. Runs a harmless
    /// script that changes nothing, with and without editing allowed.
    func testLiveConnections() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["OPENCLICKY_LIVE_MCP"] == nil, "set OPENCLICKY_LIVE_MCP to run")
        let runner = ClaudeCLIRunner(binaryURL: try ClaudeCLIRunner.locate())
        let cases: [(MCPConnection, Bool, String)] = [
            (.affinity, true, "Read the 'preamble' SDK documentation, then run execute_script with the script '1+1'. Tell me in one short sentence whether it ran and what came back."),
            (.affinity, false, "Run execute_script with the script '1+1'. Tell me in one short sentence whether it ran."),
            (.blender, true, "Run execute_blender_code with the code 'print(1)'. Tell me in one short sentence whether it ran and what came back."),
            (.figma, true, "Use whoami, then answer in one short sentence."),
        ]
        for (connection, canEdit, prompt) in cases {
            let attached = try XCTUnwrap(MCPConnections.turnConfig(for: [connection], canEdit: { _ in canEdit }))
            let began = Date()
            let firstWord = LiveClock()
            let tools = LiveClock()
            let result = try await runner.ask(
                messages: [ClaudeCLIMessage(role: .user, text: prompt)],
                systemPrompt: TutorMode.systemPrompt(
                    base: "be brief",
                    active: false,
                    connectedApps: [connection.displayName],
                    editableApps: canEdit ? [connection.displayName] : []
                ),
                model: ClaudeModel.sonnet.rawValue,
                mcp: attached.config
            ) { chunk in
                if !chunk.accumulatedText.isEmpty { firstWord.mark(began) }
                if let tool = chunk.activeTool { tools.note(tool) }
            }
            print("LIVE \(connection.id) canEdit=\(canEdit) firstWord=\(firstWord.seconds ?? -1)s total=\(Date().timeIntervalSince(began))s")
            print("LIVE \(connection.id) usage=\(String(describing: result.usage)) context=\(String(describing: result.contextTokens))")
            print("LIVE \(connection.id) tools=\(tools.notes)")
            print("LIVE \(connection.id) reply=\(result.text)")
            let hidden = Set(MCPConnections.toolLists(for: [connection], canEdit: { _ in canEdit }).hidden)
            XCTAssertTrue(hidden.isDisjoint(with: tools.notes), "Claude used a tool it wasn't offered")
        }
    }

    private final class LiveClock: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var seconds: Double?
        private(set) var notes: [String] = []

        func mark(_ began: Date) {
            lock.withLock { if seconds == nil { seconds = Date().timeIntervalSince(began) } }
        }

        func note(_ tool: String) {
            lock.withLock { notes.append(tool) }
        }
    }

    // MARK: - Moving and closing

    func testCloseButtonWinsAtTheCornerOnlyWhenClosable() {
        let caption = CGRect(x: 100, y: 100, width: 200, height: 60)
        let corner = CGPoint(x: 300, y: 160)
        XCTAssertEqual(CursorHitTest.hit(point: corner, captionFrame: caption, closable: true, arrowFrame: nil), .close)
        XCTAssertEqual(CursorHitTest.hit(point: CGPoint(x: 299, y: 159), captionFrame: caption, closable: false, arrowFrame: nil), .caption)
        XCTAssertEqual(CursorHitTest.hit(point: CGPoint(x: 150, y: 130), captionFrame: caption, closable: true, arrowFrame: nil), .caption)
        XCTAssertNil(CursorHitTest.hit(point: CGPoint(x: 10, y: 10), captionFrame: caption, closable: true, arrowFrame: nil))
    }

    @MainActor
    private func makeManager() -> (OverlayManager, UserDefaults) {
        let suite = "openclicky-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        let manager = OverlayManager(defaults: defaults)
        manager.screenFrames = { [CGRect(x: 0, y: 0, width: 1000, height: 800)] }
        return (manager, defaults)
    }

    @MainActor
    func testDraggingTheRestingArrowMakesANewHomeThatSurvivesARestart() {
        let (manager, defaults) = makeManager()
        manager.homeProvider = { CGPoint(x: 500, y: 700) }
        XCTAssertEqual(manager.cursorLocation, CGPoint(x: 500, y: 700))
        XCTAssertFalse(manager.hasCustomHome)

        manager.press(at: CGPoint(x: 505, y: 695))
        manager.drag(to: CGPoint(x: 205, y: 395))
        XCTAssertEqual(manager.cursorLocation, CGPoint(x: 200, y: 400), "the arrow keeps its place under the mouse")
        manager.release(at: CGPoint(x: 205, y: 395))
        XCTAssertTrue(manager.hasCustomHome)

        let restarted = OverlayManager(defaults: defaults)
        restarted.screenFrames = { [CGRect(x: 0, y: 0, width: 1000, height: 800)] }
        restarted.homeProvider = { CGPoint(x: 500, y: 700) }
        XCTAssertEqual(restarted.cursorLocation, CGPoint(x: 200, y: 400))
    }

    @MainActor
    func testAClickIsNotADragAndTheCursorCantLeaveTheScreens() {
        let (manager, _) = makeManager()
        manager.homeProvider = { CGPoint(x: 500, y: 700) }
        manager.press(at: CGPoint(x: 505, y: 695))
        manager.drag(to: CGPoint(x: 506, y: 695))
        manager.release(at: CGPoint(x: 506, y: 695))
        XCTAssertFalse(manager.hasCustomHome)

        manager.press(at: CGPoint(x: 505, y: 695))
        manager.drag(to: CGPoint(x: 5000, y: 695))
        XCTAssertEqual(manager.cursorLocation, CGPoint(x: 500, y: 700))
        manager.release(at: CGPoint(x: 5000, y: 695))
    }

    @MainActor
    func testTheArrowOnATargetStaysClickThroughButItsCaptionCanMoveIt() {
        let (manager, _) = makeManager()
        manager.homeProvider = { CGPoint(x: 500, y: 700) }
        manager.flyTo(BlueCursorTarget(
            globalLocation: CGPoint(x: 100, y: 100),
            displayFrame: CGRect(x: 0, y: 0, width: 1000, height: 800),
            label: nil
        ))
        let start = manager.cursorLocation
        manager.press(at: CGPoint(x: start.x + 5, y: start.y - 5))
        manager.drag(to: CGPoint(x: 300, y: 300))
        XCTAssertEqual(manager.cursorLocation, start, "a press on the arrow must reach the app underneath")
        manager.release(at: CGPoint(x: 300, y: 300))
        XCTAssertFalse(manager.hasCustomHome)

        manager.streamingResponseText = "yanıt"
        manager.captionFrame = CGRect(x: 600, y: 300, width: 200, height: 60)
        manager.press(at: CGPoint(x: 650, y: 330))
        manager.drag(to: CGPoint(x: 660, y: 340))
        manager.release(at: CGPoint(x: 660, y: 340))
        XCTAssertTrue(manager.hasCustomHome)
    }

    @MainActor
    func testCloseButtonDismissesOnlyIfReleasedOnIt() {
        let (manager, _) = makeManager()
        manager.homeProvider = { CGPoint(x: 500, y: 700) }
        var dismissals = 0
        manager.onDismissMessage = { dismissals += 1 }
        manager.streamingResponseText = "yanıt"
        manager.captionFrame = CGRect(x: 100, y: 100, width: 200, height: 60)

        let corner = CGPoint(x: 300, y: 160)
        manager.press(at: corner)
        manager.release(at: CGPoint(x: 10, y: 10))
        XCTAssertEqual(dismissals, 0)

        manager.press(at: corner)
        manager.release(at: corner)
        XCTAssertEqual(dismissals, 1)
    }

    @MainActor
    func testClicksPassThroughOnceTheCaptionIsGone() {
        let (manager, _) = makeManager()
        manager.homeProvider = { CGPoint(x: 500, y: 700) }
        manager.pointerLocation = { CGPoint(x: 150, y: 130) }
        manager.streamingResponseText = "yanıt"
        manager.captionFrame = CGRect(x: 100, y: 100, width: 200, height: 60)
        XCTAssertEqual(manager.hoveredRegion, .caption)
        manager.streamingResponseText = ""
        XCTAssertNil(manager.hoveredRegion)
    }
}

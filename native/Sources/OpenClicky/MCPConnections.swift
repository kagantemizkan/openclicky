//
//  MCPConnections.swift
//  Links to apps' MCP servers, using the definitions already in Claude Code's
//  ~/.claude.json.
//
//  Only listed tools are allowed; a tool not listed, including one a future
//  server version adds, is refused by the CLI. Tools that change things run
//  without asking, as the user chose, on turns the user started. Automatic
//  looks after a click stay read-only, because the screen starts those and
//  text on screen could try to instruct Claude.
//
//  Other known tools aren't even offered, which saves tokens (Figma's full
//  list costs about 41k), or send data elsewhere (report_sdk_issue).
//

import AppKit
import Foundation
import os

struct MCPConnection: Identifiable, Equatable {
    /// The server's name in ~/.claude.json.
    let id: String
    let displayName: String
    let bundleId: String
    let readTools: [String]
    /// Change documents, the app's view, or files. Allowed only when editing.
    let writeTools: [String]
    /// Never offered.
    let hiddenTools: [String]

    func toolNames(_ tools: [String]) -> [String] {
        tools.map { "mcp__\(id)__\($0)" }
    }

    var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
    }
}

extension MCPConnection {
    static let all: [MCPConnection] = [blender, affinity, figma]

    /// The app a tool belongs to, e.g. `mcp__blender__get_objects_summary`.
    static func owner(ofTool name: String) -> MCPConnection? {
        all.first { name.hasPrefix("mcp__\($0.id)__") }
    }

    static let blender = MCPConnection(
        id: "blender",
        displayName: "Blender",
        bundleId: "org.blenderfoundation.blender",
        readTools: [
            "get_blendfile_summary_datablocks", "get_blendfile_summary_missing_files",
            "get_blendfile_summary_of_linked_libraries", "get_blendfile_summary_path_info",
            "get_blendfile_summary_usage_guess", "get_object_detail_summary", "get_objects_summary",
            "get_python_api_docs", "get_screenshot_of_area_as_image", "get_screenshot_of_window_as_image",
            "search_api_docs", "search_manual_docs",
        ],
        writeTools: [
            "execute_blender_code", "jump_to_tab_by_name", "jump_to_tab_by_space_type",
            "jump_to_view3d_object_by_name", "jump_to_view3d_object_data_by_name",
            "render_thumbnail_to_path", "render_viewport_to_path",
        ],
        hiddenTools: [
            "execute_blender_code_for_cli", "get_blendfile_summary_datablocks_for_cli",
            "get_blendfile_summary_missing_files_for_cli", "get_blendfile_summary_of_linked_libraries_for_cli",
            "get_blendfile_summary_path_info_for_cli", "get_blendfile_summary_usage_guess_for_cli",
            "get_screenshot_of_window_as_json",
        ]
    )

    static let affinity = MCPConnection(
        id: "affinity",
        displayName: "Affinity",
        bundleId: "com.canva.affinity",
        readTools: [
            "list_library_scripts", "list_sdk_documentation", "read_library_script",
            "read_sdk_documentation_topic", "render_selection", "render_spread", "search_sdk_hints",
        ],
        writeTools: ["add_sdk_hint", "execute_script", "save_script_to_library"],
        hiddenTools: ["report_sdk_issue"]
    )

    static let figma = MCPConnection(
        id: "figma",
        displayName: "Figma",
        bundleId: "com.figma.Desktop",
        readTools: [
            "create_session", "get_design_context", "get_figjam", "get_libraries", "get_metadata",
            "get_motion_context", "get_screenshot", "get_variable_defs", "search_design_system", "whoami",
        ],
        writeTools: ["create_new_file", "generate_diagram", "generate_figma_design", "upload_assets", "use_figma"],
        hiddenTools: [
            "add_code_connect_map", "create_generative_plugin", "create_shader",
            "download_assets", "export_video", "generate_image",
            "get_code_connect_map", "get_code_connect_suggestions", "get_context_for_code_connect",
            "get_generative_plugin", "get_shader", "list_file_shaders", "list_generative_plugins", "list_shaders",
            "send_code_connect_mappings", "send_code_to_figma", "update_generative_plugin", "update_shader",
            "weave_cancel_tool_run", "weave_find_model",
            "weave_get_model_run_output", "weave_get_tool_inputs", "weave_get_tool_run_output",
            "weave_list_tools", "weave_run_model", "weave_run_tool", "weave_upload_asset",
        ]
    )
}

/// What one CLI run needs in order to reach its servers.
struct MCPTurnConfig: Equatable {
    let configPath: String
    let allowedTools: [String]
    let hiddenTools: [String]
}

enum MCPConnections {
    private static let logger = Logger(subsystem: "com.proyecto26.openclicky", category: "MCPConnections")

    /// Which connections a turn should carry. Each costs start-up time and
    /// tokens, so one attaches only while its app is in front or being taught.
    static func connections(
        enabled: Set<String>,
        frontmostBundleId: String?,
        lessonConnection: MCPConnection?
    ) -> [MCPConnection] {
        MCPConnection.all.filter { connection in
            enabled.contains(connection.id)
                && (connection.bundleId == frontmostBundleId || connection == lessonConnection)
        }
    }

    /// The server definitions for `connections`, from Claude Code's settings.
    /// A server the user hasn't set up is left out.
    static func serverDefinitions(for connections: [MCPConnection], claudeSettings: [String: Any]) -> [String: Any] {
        let servers = claudeSettings["mcpServers"] as? [String: Any] ?? [:]
        return servers.filter { name, _ in connections.contains { $0.id == name } }
    }

    static var claudeSettingsURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    private static func loadClaudeSettings() -> [String: Any] {
        guard let data = try? Data(contentsOf: claudeSettingsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        return json
    }

    /// Names of the servers defined in Claude Code's settings.
    static func definedServerNames() -> Set<String> {
        Set((loadClaudeSettings()["mcpServers"] as? [String: Any] ?? [:]).keys)
    }

    /// Which tools may run and which aren't offered, for one turn.
    static func toolLists(
        for connections: [MCPConnection],
        canEdit: (MCPConnection) -> Bool
    ) -> (allowed: [String], hidden: [String]) {
        var allowed: [String] = []
        var hidden: [String] = []
        for connection in connections {
            allowed += connection.toolNames(connection.readTools)
            hidden += connection.toolNames(connection.hiddenTools)
            if canEdit(connection) {
                allowed += connection.toolNames(connection.writeTools)
            } else {
                hidden += connection.toolNames(connection.writeTools)
            }
        }
        return (allowed, hidden)
    }

    /// Prepares a config for `connections`, or nil if none can be reached. It
    /// goes in a private file rather than the command line, where any process
    /// could read a server's headers or environment.
    static func turnConfig(
        for connections: [MCPConnection],
        canEdit: (MCPConnection) -> Bool
    ) -> (config: MCPTurnConfig, connected: [MCPConnection])? {
        guard !connections.isEmpty else { return nil }
        let definitions = serverDefinitions(for: connections, claudeSettings: loadClaudeSettings())
        let connected = connections.filter { definitions[$0.id] != nil }
        guard !connected.isEmpty else { return nil }

        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenClicky", isDirectory: true)
        let file = directory.appendingPathComponent("mcp-config.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: ["mcpServers": definitions])
            FileManager.default.createFile(atPath: file.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try data.write(to: file)
        } catch {
            logger.error("Couldn't write the MCP config: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let tools = toolLists(for: connected, canEdit: canEdit)
        return (
            MCPTurnConfig(configPath: file.path, allowedTools: tools.allowed, hiddenTools: tools.hidden),
            connected
        )
    }
}

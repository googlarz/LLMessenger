// LLMessenger/main.swift
//
// `LLMessenger --mcp` runs a headless stdio MCP server (no NSApplication, no
// polling, no adapters, no agent). Anything else launches the normal GUI app.
import Foundation

if CommandLine.arguments.contains("--mcp") {
    exit(MCPServer.runStdio())
} else {
    LLMessengerApp.main()
}

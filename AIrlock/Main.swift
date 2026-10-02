import AirlockControl
import AirlockCore
import Foundation

/// `AIrlock --mcp` runs the MCP server for the Claude plugin instead of the app, and
/// `AIrlock --watch <task>` streams a task's progress for the chat that follows it.
@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--watch") {
            Watcher.runAsProcess(socketPath: ControlSocket.path(for: .default), arguments: CommandLine.arguments)
        }
        if CommandLine.arguments.contains("--mcp") {
            MCPServer.runAsProcess(
                socketPath: ControlSocket.path(for: .default),
                appBundle: Bundle.main.bundleURL
            )
        }
        AIrlockApp.main()
    }
}

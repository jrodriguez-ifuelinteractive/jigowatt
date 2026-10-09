import Foundation
import JigowattCore

// This binary has two jobs:
//  1. SSH_ASKPASS helper: ssh runs it with a prompt argument and JIGOWATT_HOST_ID set.
//  2. MCP stdio server for coding agents (the default).
if let hostID = ProcessInfo.processInfo.environment[AskpassEnv.hostID] {
    exit(Askpass.run(hostID: hostID, prompt: CommandLine.arguments.dropFirst().joined(separator: " ")))
}

try await MCPServer.run()

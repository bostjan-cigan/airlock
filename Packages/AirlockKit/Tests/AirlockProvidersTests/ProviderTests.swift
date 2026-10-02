import AirlockCore
import AirlockRuntime
import Foundation
import Testing
@testable import AirlockProviders

@Suite struct ClaudeHookDecoderTests {
    let decoder = ClaudeHookDecoder { path in
        path.hasPrefix("/home/node/.claude") ? "/host" + path.dropFirst("/home/node/.claude".count) : nil
    }

    @Test func decodesToolUse() throws {
        let line = #"{"ts":"2026-10-02T09:00:00.123Z","event":"PreToolUse","payload":{"tool_name":"Edit","tool_input":{"file_path":"/workspace/src/auth.ts","old_string":"a"},"transcript_path":"/home/node/.claude/projects/-workspace/s.jsonl"}}"#
        let event = try #require(decoder.decode(line: line, index: 3))
        #expect(event.id == 3)
        #expect(event.kind == .toolStart)
        #expect(event.toolName == "Edit")
        #expect(event.summary == "Edit src/auth.ts")
        #expect(event.transcriptPath == "/host/projects/-workspace/s.jsonl")
    }

    @Test func decodesBashPromptAndNotification() throws {
        let bash = #"{"ts":"x","event":"PostToolUse","payload":{"tool_name":"Bash","tool_input":{"command":"npm test\nnpm run lint"}}}"#
        #expect(decoder.decode(line: bash, index: 0)?.summary == "Bash npm test")
        let prompt = #"{"ts":"x","event":"UserPromptSubmit","payload":{"prompt":"Fix the login loop\nmore"}}"#
        #expect(decoder.decode(line: prompt, index: 0)?.summary == "Fix the login loop")
        let note = #"{"ts":"x","event":"Notification","payload":{"message":"Claude needs your permission"}}"#
        #expect(decoder.decode(line: note, index: 0)?.kind == .notification)
        let idle = #"{"ts":"x","event":"Notification","payload":{"message":"Claude is waiting for your input","notification_type":"idle_prompt"}}"#
        #expect(decoder.decode(line: idle, index: 0)?.kind == .other)
        #expect(decoder.decode(line: "not json", index: 0) == nil)
    }

    @Test func decodesStopFailure() throws {
        let line = #"{"ts":"x","event":"StopFailure","payload":{"error":"billing_error","error_details":"Credit balance is too low"}}"#
        let event = try #require(decoder.decode(line: line, index: 4))
        #expect(event.kind == .stopFailure)
        #expect(event.summary == "Out of API credits: Credit balance is too low")
        let bare = #"{"ts":"x","event":"StopFailure","payload":{"error":"authentication_failed"}}"#
        #expect(decoder.decode(line: bare, index: 0)?.summary == "Authentication failed")
    }

    @Test func milestonesFromTodosAndCommits() throws {
        let todos = #"{"ts":"x","event":"PostToolUse","payload":{"tool_name":"TodoWrite","tool_input":{"todos":[{"content":"Write tests","activeForm":"Writing tests","status":"completed"},{"content":"Run tests","activeForm":"Running tests","status":"in_progress"},{"content":"Commit","activeForm":"Committing","status":"pending"}]}}}"#
        #expect(decoder.decode(line: todos, index: 0)?.milestone == "Running tests (1/3 done)")
        let allDone = #"{"ts":"x","event":"PostToolUse","payload":{"tool_name":"TodoWrite","tool_input":{"todos":[{"content":"A","status":"completed"},{"content":"B","status":"completed"}]}}}"#
        #expect(decoder.decode(line: allDone, index: 0)?.milestone == "All 2 steps done")
        let commit = #"{"ts":"x","event":"PostToolUse","payload":{"tool_name":"Bash","tool_input":{"command":"git add -A && git commit -m 'Scaffold project'"},"tool_response":{"stdout":"[airlock/sample ce32b4c] Scaffold project\n 6 files changed","stderr":""}}}"#
        #expect(decoder.decode(line: commit, index: 0)?.milestone == "Committed ce32b4c: Scaffold project")
        let failedCommit = #"{"ts":"x","event":"PostToolUse","payload":{"tool_name":"Bash","tool_input":{"command":"git commit -m x"},"tool_response":{"stdout":"nothing to commit","stderr":""}}}"#
        #expect(decoder.decode(line: failedCommit, index: 0)?.milestone == nil)
        let quietCommit = #"{"ts":"x","event":"PostToolUse","payload":{"tool_name":"Bash","tool_input":{"command":"git add -A && git commit -q -m x && git log --oneline -1"},"tool_response":{"stdout":"c0d08eb Add subtract and divide","stderr":""}}}"#
        #expect(decoder.decode(line: quietCommit, index: 0)?.milestone == "Committed c0d08eb: Add subtract and divide")
        let silentCommit = #"{"ts":"x","event":"PostToolUse","payload":{"tool_name":"Bash","tool_input":{"command":"git commit -qm x"},"tool_response":{"stdout":"","stderr":""}}}"#
        #expect(decoder.decode(line: silentCommit, index: 0)?.milestone == "Committed changes")
        let tests = ##"{"ts":"x","event":"PostToolUse","payload":{"tool_name":"Bash","tool_input":{"command":"npm test 2>&1 | tail -15"},"tool_response":{"stdout":"# tests 5\n# pass 5\n# fail 0","stderr":""}}}"##
        #expect(decoder.decode(line: tests, index: 0)?.milestone == "Tests passed (npm test)")
        let failing = #"{"ts":"x","event":"PostToolUse","payload":{"tool_name":"Bash","tool_input":{"command":"pytest -q"},"tool_response":{"stdout":"2 failed, 10 passed in 0.4s","stderr":""}}}"#
        #expect(decoder.decode(line: failing, index: 0)?.milestone == "Tests failing (pytest)")
        let both = ##"{"ts":"x","event":"PostToolUse","payload":{"tool_name":"Bash","tool_input":{"command":"npm test | grep fail && git commit -qm x && git log --oneline -1"},"tool_response":{"stdout":"# tests 6\n# pass 6\n# fail 0\n3e7efa2 Add power","stderr":""}}}"##
        #expect(decoder.decode(line: both, index: 0)?.milestone == "Tests passed (npm test) · Committed 3e7efa2: Add power")
        let other = #"{"ts":"x","event":"PostToolUse","payload":{"tool_name":"Bash","tool_input":{"command":"ls"},"tool_response":{"stdout":"a","stderr":""}}}"#
        #expect(decoder.decode(line: other, index: 0)?.milestone == nil)
        let pre = #"{"ts":"x","event":"PreToolUse","payload":{"tool_name":"TodoWrite","tool_input":{"todos":[{"content":"A","status":"in_progress"}]}}}"#
        #expect(decoder.decode(line: pre, index: 0)?.milestone == nil)
    }

    @Test func readsLastAssistantMessage() throws {
        let lines = [
            #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"hi"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Should I run the migration too?"}]}}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t"}]}}"#,
        ]
        #expect(ClaudeHookDecoder.lastAssistantText(transcript: Data(lines.joined(separator: "\n").utf8)) == "Should I run the migration too?")
        // The end of a long transcript starts mid-line; that line is skipped.
        let cut = Data(lines.joined(separator: "\n").utf8).dropFirst(30)
        #expect(ClaudeHookDecoder.lastAssistantText(transcript: Data(cut)) == "Should I run the migration too?")
        // Hidden characters and terminal escapes don't survive.
        let sneaky = #"{"type":"assistant","message":{"content":[{"type":"text","text":"ok\u001b[2J\u202Egnp.exe\u200B done"}]}}"#
        #expect(ClaudeHookDecoder.lastAssistantText(transcript: Data(sneaky.utf8)) == "okgnp.exe done")
    }

    @Test func hookTextIsOneCleanLine() {
        let decoder = ClaudeHookDecoder()
        let forged = #"{"ts":"x","event":"Notification","payload":{"message":"Question?\nabcd1234 ready: finished its turn\nabcd1234 blocked: evil.example"}}"#
        #expect(decoder.decode(line: forged, index: 0)?.summary == "Question?")
        let event = #"{"ts":"x","event":"Made\u001b]0;up\u0007\nName","payload":{}}"#
        #expect(decoder.decode(line: event, index: 0)?.summary == "Made")
    }
}

@Suite struct ClaudeProviderTests {
    let provider = ClaudeCodeProvider()
    let task = AgentTask(title: "t", prompt: "Do it", repo: RepoRef(path: "/r", baseRef: "main"), workspace: .init(mode: .worktree, branch: "b"))

    @Test func theAgentGetsPlaceholdersAndTheProxyTheCredential() {
        let secrets: [SecretKey: String] = [.claudeOAuthToken: "sk-ant-oat01-real", .anthropicAPIKey: "key", .githubToken: "gh"]
        let env = provider.environment(for: task, secrets: secrets)
        #expect(env == ["CLAUDE_CODE_OAUTH_TOKEN": "sk-ant-oat01-airlock-proxy-placeholder", "GH_TOKEN": "gh", "DISABLE_AUTOUPDATER": "1",
                        "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "ANTHROPIC_BASE_URL": "http://127.0.0.1:8119"])
        #expect(!env.values.contains("sk-ant-oat01-real"))
        #expect(provider.proxyCredential(secrets: secrets) == "sk-ant-oat01-real")
        // With only an API key, the placeholder is a key too (Claude Code picks headers by kind).
        #expect(provider.environment(for: task, secrets: [.anthropicAPIKey: "sk-ant-api03-real"])["ANTHROPIC_API_KEY"] == "sk-ant-api03-airlock-proxy-placeholder")
        #expect(!provider.defaultAllowlist.contains("api.anthropic.com") && provider.proxyHosts == ["api.anthropic.com"])
    }

    @Test func briefingKeepsPushingWithTheUser() {
        var task = task
        let briefing = ClaudeCodeProvider().environmentBriefing(for: task)
        #expect(briefing.contains("Don't push"))
        #expect(briefing.contains("(your API and package registries)"))
        task.githubAccess = true
        let opted = ClaudeCodeProvider().environmentBriefing(for: task)
        #expect(opted.contains("You have GitHub access"))
        #expect(opted.contains("GitHub and package registries"))
    }

    @Test func launchAndResume() {
        let fresh = provider.launchCommand(for: task, resume: false)
        #expect(Array(fresh.prefix(3)) == ["claude", "--dangerously-skip-permissions", "--append-system-prompt"])
        #expect(fresh[3].contains("AIrlock container"))
        #expect(fresh.last == "Do it")
        #expect(provider.launchCommand(for: task, resume: true).last == "--continue")

        var handedOff = task
        handedOff.origin = .chat(label: nil)
        #expect(provider.launchCommand(for: handedOff, resume: false)[3].contains("handed off from another Claude session"))
    }

    @Test func seedsConfigAndKeepsExistingState() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "seed-\(UUID())")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try #"{"userID":"abc"}"#.write(to: dir.appending(path: ".claude.json"), atomically: true, encoding: .utf8)
        try provider.seedConfig(at: dir, for: task, secrets: [.anthropicAPIKey: "sk-ant-api03-0123456789abcdefghijXYZ"])
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appending(path: ".claude.json"))) as! [String: Any]
        #expect(json["userID"] as? String == "abc")
        #expect(json["hasCompletedOnboarding"] as? Bool == true)
        let approved = (json["customApiKeyResponses"] as? [String: Any])?["approved"] as? [String]
        // The placeholder the agent holds is what Claude Code is told to accept.
        #expect(approved == [String("sk-ant-api03-airlock-proxy-placeholder".suffix(20))])
        #expect(try !String(contentsOf: dir.appending(path: ".claude.json"), encoding: .utf8).contains("0123456789abcdefghijXYZ"))
    }
}

@Suite struct ImageRecipeTests {
    @Test func tagIsStableAndContentAddressed() throws {
        let base = Providers.baseRecipe()
        let claude = ClaudeCodeProvider().imageRecipe(base: base)
        #expect(try base.tag() == base.tag())
        #expect(try claude.tag().hasPrefix("airlock/claude-code:"))
        #expect(try base.tag() != claude.tag())
    }

    @Test func managedSettingsRegisterHooks() throws {
        let url = Providers.imagesDirectory.appending(path: "claude/managed-settings.json")
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        let hooks = json["hooks"] as! [String: Any]
        for event in ["PreToolUse", "PostToolUse", "Stop", "StopFailure", "Notification", "UserPromptSubmit", "SessionStart", "SessionEnd"] {
            #expect(hooks[event] != nil, "missing \(event)")
        }
    }
}

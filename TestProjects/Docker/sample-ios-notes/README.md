# sample-ios-notes

A Swift package for iOS and macOS apps: a client for the notes API, plus a SwiftUI list.

**What it tests:** the Apple-platform notice. A Linux container can read and edit Swift
code for iOS, but can't build or test it, and AIrlock says so before the task starts.

**What AIrlock should detect:**
- Notice: "This is an Apple-platform project. The agent can read and edit the code, but
  can’t build or test it inside a Linux container."
- No tools to install

**Prompt:**
> Add `delete(id:)` to `NotesClient` (sends `DELETE /notes/{id}`). You can't build here, so
> keep the change small and say what to verify in Xcode. Commit.

**Pass criteria:** the New Task sheet and the `start_task` reply show the notice. The agent
makes the change without trying to install Xcode. `swift test` on your Mac passes.

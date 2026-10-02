import Foundation
#if canImport(SwiftUI)
import SwiftUI
#endif

public struct Note: Codable, Identifiable, Hashable, Sendable {
    public var id: Int
    public var text: String
}

/// Talks to the notes API from the other samples.
public struct NotesClient: Sendable {
    public var baseURL: URL
    public var session: URLSession

    public init(baseURL: URL = URL(string: "http://localhost:3000")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func notes() async throws -> [Note] {
        let (data, _) = try await session.data(from: baseURL.appending(path: "notes"))
        return try JSONDecoder().decode([Note].self, from: data)
    }

    public func add(_ text: String) async throws -> Note {
        var request = URLRequest(url: baseURL.appending(path: "notes"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.httpBody = try JSONEncoder().encode(["text": text])
        let (data, _) = try await session.data(for: request)
        return try JSONDecoder().decode(Note.self, from: data)
    }
}

#if canImport(SwiftUI)
/// The notes list, for an app target to show.
public struct NotesList: View {
    let notes: [Note]
    public init(notes: [Note]) { self.notes = notes }
    public var body: some View {
        List(notes) { Text($0.text) }
    }
}
#endif

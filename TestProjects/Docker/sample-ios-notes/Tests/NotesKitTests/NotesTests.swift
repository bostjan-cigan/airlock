import Foundation
import Testing
@testable import NotesKit

@Test func decodesNotes() throws {
    let notes = try JSONDecoder().decode([Note].self, from: Data(#"[{"id":1,"text":"hello"}]"#.utf8))
    #expect(notes == [Note(id: 1, text: "hello")])
}

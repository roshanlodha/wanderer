import Foundation
import SwiftData

@Model
final class EmailSource {
    var id: UUID = UUID()
    var sender: String
    var subject: String
    var dateReceived: Date
    var snippet: String
    
    init(sender: String, subject: String, dateReceived: Date, snippet: String) {
        self.sender = sender
        self.subject = subject
        self.dateReceived = dateReceived
        self.snippet = snippet
    }
}

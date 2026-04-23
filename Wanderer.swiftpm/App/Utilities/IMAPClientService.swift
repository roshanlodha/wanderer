import Foundation

class IMAPClientService {
    static let shared = IMAPClientService()
    
    // Note: A real implementation would use Google/Microsoft REST APIs or a pure Swift IMAP library.
    
    let travelKeywords = ["confirmation", "itinerary", "ticket", "reservation"]
    
    func fetchRecentTravelEmails(completion: @escaping (Result<[String], Error>) -> Void) {
        print("Starting background email fetch...")
        
        // Simulating network delay
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 2.0) {
            let mockHTML = """
            <html>
            <body>
            <h1>Your Flight Confirmation</h1>
            <p>Thank you for booking with us. Your reservation for flight BA123 to London is confirmed.</p>
            <p>Departure: 10:00 AM</p>
            </body>
            </html>
            """
            
            let strippedText = self.stripHTML(from: mockHTML)
            
            if self.containsTravelKeywords(text: strippedText) {
                self.saveToTemporaryCache(text: strippedText)
                completion(.success([strippedText]))
            } else {
                completion(.success([]))
            }
        }
    }
    
    private func stripHTML(from string: String) -> String {
        // Using Regex for safe background thread HTML stripping
        let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive)
        let range = NSRange(location: 0, length: string.count)
        let stripped = regex?.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: " ") ?? string
        
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func containsTravelKeywords(text: String) -> Bool {
        let lowercased = text.lowercased()
        return travelKeywords.contains { lowercased.contains($0) }
    }
    
    private func saveToTemporaryCache(text: String) {
        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("travel_emails_cache_\(UUID().uuidString).txt")
        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            print("Successfully saved parsed email to cache: \(fileURL.path)")
        } catch {
            print("Failed to save email to cache: \(error.localizedDescription)")
        }
    }
}

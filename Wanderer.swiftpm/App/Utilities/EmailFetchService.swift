import Foundation

// MARK: - Email Fetch Result

struct FetchedEmail: Identifiable {
    let id: String
    let subject: String
    let sender: String
    let date: Date
    let bodyText: String
}

// MARK: - Email Fetch Service

class EmailFetchService {
    static let shared = EmailFetchService()
    
    let travelKeywords = ["confirmation", "itinerary", "ticket", "reservation", "booking", "flight", "hotel", "check-in"]
    
    private let keychain = KeychainManager.shared
    
    // MARK: - Public API
    
    /// Fetch travel emails from all connected providers and cache the raw text.
    func fetchAllTravelEmails() async -> [FetchedEmail] {
        var allEmails: [FetchedEmail] = []
        
        if let googleToken = keychain.get(forKey: .googleAccessToken) {
            do {
                let emails = try await fetchGmailTravelEmails(accessToken: googleToken)
                allEmails.append(contentsOf: emails)
                print("[EmailFetchService] Fetched \(emails.count) travel emails from Gmail.")
            } catch {
                print("[EmailFetchService] Gmail fetch failed: \(error.localizedDescription)")
            }
        }
        
        if let msToken = keychain.get(forKey: .microsoftAccessToken) {
            do {
                let emails = try await fetchMicrosoftTravelEmails(accessToken: msToken)
                allEmails.append(contentsOf: emails)
                print("[EmailFetchService] Fetched \(emails.count) travel emails from Microsoft.")
            } catch {
                print("[EmailFetchService] Microsoft fetch failed: \(error.localizedDescription)")
            }
        }
        
        // Save all raw text to temp cache
        for email in allEmails {
            saveToTemporaryCache(email: email)
        }
        
        return allEmails
    }
    
    // MARK: - Gmail REST API
    
    private func fetchGmailTravelEmails(accessToken: String) async throws -> [FetchedEmail] {
        // Step 1: Search for messages matching travel keywords
        let query = travelKeywords.joined(separator: " OR ")
        var searchComponents = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        searchComponents.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: "10")
        ]
        
        let searchRequest = makeAuthorizedRequest(url: searchComponents.url!, token: accessToken)
        let (searchData, searchResponse) = try await URLSession.shared.data(for: searchRequest)
        
        try validateHTTPResponse(searchResponse, data: searchData, context: "Gmail search")
        
        let searchResult = try JSONDecoder().decode(GmailMessageList.self, from: searchData)
        guard let messageRefs = searchResult.messages, !messageRefs.isEmpty else {
            return []
        }
        
        // Step 2: Fetch full message for each result
        var emails: [FetchedEmail] = []
        for ref in messageRefs.prefix(10) {
            let messageURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(ref.id)?format=full")!
            let msgRequest = makeAuthorizedRequest(url: messageURL, token: accessToken)
            let (msgData, msgResponse) = try await URLSession.shared.data(for: msgRequest)
            
            try validateHTTPResponse(msgResponse, data: msgData, context: "Gmail message \(ref.id)")
            
            let message = try JSONDecoder().decode(GmailMessage.self, from: msgData)
            if let email = parsedGmailMessage(message) {
                emails.append(email)
            }
        }
        
        return emails
    }
    
    // MARK: - Microsoft Graph REST API
    
    private func fetchMicrosoftTravelEmails(accessToken: String) async throws -> [FetchedEmail] {
        let query = travelKeywords.joined(separator: " OR ")
        var searchComponents = URLComponents(string: "https://graph.microsoft.com/v1.0/me/messages")!
        searchComponents.queryItems = [
            URLQueryItem(name: "$search", value: "\"\(query)\""),
            URLQueryItem(name: "$top", value: "10"),
            URLQueryItem(name: "$select", value: "id,subject,from,receivedDateTime,body")
        ]
        
        let searchRequest = makeAuthorizedRequest(url: searchComponents.url!, token: accessToken)
        let (searchData, searchResponse) = try await URLSession.shared.data(for: searchRequest)
        
        try validateHTTPResponse(searchResponse, data: searchData, context: "Microsoft search")
        
        let result = try JSONDecoder().decode(MicrosoftMessageList.self, from: searchData)
        
        return result.value.compactMap { msg -> FetchedEmail? in
            let bodyText = stripHTML(from: msg.body.content)
            guard !bodyText.isEmpty else { return nil }
            
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let date = dateFormatter.date(from: msg.receivedDateTime) ?? Date()
            
            return FetchedEmail(
                id: msg.id,
                subject: msg.subject,
                sender: msg.from.emailAddress.address,
                date: date,
                bodyText: bodyText
            )
        }
    }
    
    // MARK: - Helpers
    
    private func makeAuthorizedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }
    
    private func validateHTTPResponse(_ response: URLResponse, data: Data, context: String) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw EmailFetchError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            print("[EmailFetchService] \(context) failed (\(httpResponse.statusCode)): \(body)")
            throw EmailFetchError.httpError(statusCode: httpResponse.statusCode)
        }
    }
    
    func stripHTML(from string: String) -> String {
        let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive)
        let range = NSRange(location: 0, length: string.utf16.count)
        let stripped = regex?.stringByReplacingMatches(in: string, options: [], range: range, withTemplate: " ") ?? string
        
        // Collapse whitespace
        let components = stripped.components(separatedBy: .whitespacesAndNewlines)
        return components.filter { !$0.isEmpty }.joined(separator: " ")
    }
    
    private func saveToTemporaryCache(email: FetchedEmail) {
        let tempDir = FileManager.default.temporaryDirectory
        let sanitizedID = email.id.replacingOccurrences(of: "/", with: "_")
        let fileURL = tempDir.appendingPathComponent("wanderer_email_\(sanitizedID).txt")
        
        let content = """
        Subject: \(email.subject)
        From: \(email.sender)
        Date: \(email.date)
        ---
        \(email.bodyText)
        """
        
        do {
            try content.write(to: fileURL, atomically: true, encoding: .utf8)
            print("[EmailFetchService] Cached: \(fileURL.lastPathComponent)")
        } catch {
            print("[EmailFetchService] Cache write failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Gmail Message Parsing
    
    private func parsedGmailMessage(_ message: GmailMessage) -> FetchedEmail? {
        let headers = message.payload.headers ?? []
        let subject = headers.first(where: { $0.name.lowercased() == "subject" })?.value ?? "(No Subject)"
        let from = headers.first(where: { $0.name.lowercased() == "from" })?.value ?? "(Unknown)"
        let dateStr = headers.first(where: { $0.name.lowercased() == "date" })?.value
        
        let date: Date
        if let dateStr = dateStr {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
            date = formatter.date(from: dateStr) ?? Date()
        } else {
            date = Date()
        }
        
        // Extract body text from parts
        let bodyText = extractGmailBody(from: message.payload)
        guard !bodyText.isEmpty else { return nil }
        
        return FetchedEmail(id: message.id, subject: subject, sender: from, date: date, bodyText: bodyText)
    }
    
    private func extractGmailBody(from payload: GmailPayload) -> String {
        // Check if the payload itself has body data
        if let bodyData = payload.body?.data, !bodyData.isEmpty {
            if let decoded = base64URLDecode(bodyData) {
                let text = payload.mimeType == "text/html" ? stripHTML(from: decoded) : decoded
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        
        // Recurse into parts, preferring text/plain over text/html
        if let parts = payload.parts {
            // Try text/plain first
            for part in parts {
                if part.mimeType == "text/plain", let data = part.body?.data, !data.isEmpty {
                    if let decoded = base64URLDecode(data) {
                        return decoded
                    }
                }
            }
            // Fall back to text/html
            for part in parts {
                if part.mimeType == "text/html", let data = part.body?.data, !data.isEmpty {
                    if let decoded = base64URLDecode(data) {
                        return stripHTML(from: decoded)
                    }
                }
            }
            // Recurse deeper (multipart/alternative etc.)
            for part in parts {
                let result = extractGmailBody(from: part)
                if !result.isEmpty { return result }
            }
        }
        
        return ""
    }
    
    private func base64URLDecode(_ string: String) -> String? {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        
        // Pad to multiple of 4
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

// MARK: - Error

enum EmailFetchError: LocalizedError {
    case invalidResponse
    case httpError(statusCode: Int)
    
    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from email server."
        case .httpError(let code):
            return "Email fetch failed with HTTP \(code)."
        }
    }
}

// MARK: - Gmail API Models

struct GmailMessageList: Codable {
    let messages: [GmailMessageRef]?
}

struct GmailMessageRef: Codable {
    let id: String
}

struct GmailMessage: Codable {
    let id: String
    let payload: GmailPayload
}

struct GmailPayload: Codable {
    let mimeType: String
    let headers: [GmailHeader]?
    let body: GmailBody?
    let parts: [GmailPayload]?
}

struct GmailHeader: Codable {
    let name: String
    let value: String
}

struct GmailBody: Codable {
    let data: String?
}

// MARK: - Microsoft Graph Models

struct MicrosoftMessageList: Codable {
    let value: [MicrosoftMessage]
}

struct MicrosoftMessage: Codable {
    let id: String
    let subject: String
    let from: MicrosoftFrom
    let receivedDateTime: String
    let body: MicrosoftBody
}

struct MicrosoftFrom: Codable {
    let emailAddress: MicrosoftEmailAddress
}

struct MicrosoftEmailAddress: Codable {
    let address: String
}

struct MicrosoftBody: Codable {
    let contentType: String
    let content: String
}

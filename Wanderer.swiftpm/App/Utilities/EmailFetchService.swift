import Foundation

// MARK: - Email Fetch Result

struct FetchedEmail: Identifiable {
    let id: String
    let subject: String
    let sender: String
    let date: Date
    let bodyText: String

    init(id: String, subject: String, sender: String, date: Date, bodyText: String) {
        self.id = id
        self.subject = subject
        self.sender = sender
        self.date = date
        self.bodyText = bodyText
    }

    init(source: EmailSource) {
        self.id = source.externalID
        self.subject = source.subject
        self.sender = source.sender
        self.date = source.dateReceived
        self.bodyText = source.bodyText
    }
    
    /// Status of extraction for this email
    enum ExtractionStatus: Equatable {
        case pending       // Not yet extracted
        case extracting    // Currently being processed
        case extracted(Int, String?) // Successfully extracted N items
        case irrelevant(String)    // LLM determined not travel-related
        case failed(String) // Extraction failed with error
    }
}

// MARK: - Email Fetch Service

class EmailFetchService {
    static let shared = EmailFetchService()
    
    /// More targeted travel-specific search queries.
    /// Uses phrase matching and category-specific terms to reduce false positives.
    /// Words like "confirmation" and "ticket" alone are far too broad.
    private let gmailSearchQuery = """
    (subject:(flight OR itinerary OR "boarding pass" OR "e-ticket" OR "travel confirmation" OR "booking confirmation" OR "reservation confirmation" OR "hotel reservation" OR "car rental" OR "trip" OR airbnb OR "check-in" OR "check in" OR "electronic travel" OR "ETA" OR visa OR passport OR cruise OR ferry OR train OR bus OR insurance OR tour OR tickets OR event OR "travel document") \
    OR from:(booking.com OR airbnb.com OR hotels.com OR expedia.com OR kayak.com OR tripadvisor.com OR united.com OR delta.com OR aa.com OR southwest.com OR jetblue.com OR amtrak.com OR vrbo.com OR marriott.com OR hilton.com OR hyatt.com OR ihg.com OR hertz.com OR avis.com OR enterprise.com OR capitalone.com OR opentable.com OR resy.com OR virginatlantic.com OR ryanair.com OR easyjet.com OR flixbus.com OR trainline.com OR scotrail.co.uk OR ukvi OR "gov.uk" OR tfl.gov.uk OR capitalonebooking.com OR chasetravel.com OR amextravel.com OR travel.americanexpress.com OR hopper.com OR skyscanner.com OR agoda.com OR priceline.com OR travelocity.com OR orbitz.com OR cheapoair.com OR kiwi.com OR trip.com))
    """
    
    /// Known non-travel sender patterns to filter out at the fetch level
    private let spamSenderPatterns = [
        "noreply@github.com", "notifications@github.com",
        "no-reply@accounts.google.com", "noreply@medium.com",
        "newsletter", "marketing", "promo", "digest",
        "noreply@slack.com", "notification@facebookmail.com",
        "info@twitter.com", "noreply@linkedin.com"
    ]
    
    private let keychain = KeychainManager.shared
    private let emailRegex = try? NSRegularExpression(
        pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
        options: [.caseInsensitive]
    )
    
    // MARK: - Public API
    
    /// Fetch travel emails from all connected providers.
    /// This ONLY fetches — no extraction happens here.
    func fetchTravelEmails() async -> [FetchedEmail] {
        var allEmails: [FetchedEmail] = []
        var connectedAccountEmails = Set<String>()
        
        if let googleToken = keychain.get(forKey: .googleAccessToken) {
            do {
                if let accountEmail = try await fetchGoogleAccountEmail(accessToken: googleToken) {
                    connectedAccountEmails.insert(accountEmail)
                }
                let emails = try await fetchGmailTravelEmails(
                    accessToken: googleToken
                )
                allEmails.append(contentsOf: emails)
                print("[EmailFetchService] Fetched \(emails.count) travel emails from Gmail.")
            } catch {
                print("[EmailFetchService] Gmail fetch failed: \(error.localizedDescription)")
            }
        }
        
        if allEmails.isEmpty {
            print("[EmailFetchService] No connected accounts or no emails found.")
        }
        
        // Filter out known spam/non-travel senders
        let filtered = allEmails.filter { email in
            let senderLower = email.sender.lowercased()
            let subjectLower = email.subject.lowercased()
            let senderAddress = normalizedEmailAddress(from: email.sender)
            
            // Exclude forwarded emails
            if subjectLower.hasPrefix("fwd:") || subjectLower.hasPrefix("fw:") {
                return false
            }

            // Exclude emails sent by the currently connected account(s)
            if let senderAddress, connectedAccountEmails.contains(senderAddress) {
                return false
            }
            
            // Exclude known non-travel senders
            for pattern in spamSenderPatterns {
                if senderLower.contains(pattern) {
                    return false
                }
            }
            
            return true
        }
        
        print("[EmailFetchService] After filtering: \(filtered.count) emails (removed \(allEmails.count - filtered.count) non-travel)")
        return filtered
    }

    private func normalizedEmailAddress(from rawValue: String) -> String? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let nsRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        if let match = emailRegex?.firstMatch(in: trimmed, options: [], range: nsRange),
           let range = Range(match.range, in: trimmed) {
            return trimmed[range].lowercased()
        }

        return trimmed.contains("@") ? trimmed.lowercased() : nil
    }

    private func fetchGoogleAccountEmail(accessToken: String) async throws -> String? {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
        let request = makeAuthorizedRequest(url: url, token: accessToken)
        let (data, response) = try await URLSession.shared.data(for: request)

        try validateHTTPResponse(response, data: data, context: "Gmail profile")

        struct GmailProfile: Codable {
            let emailAddress: String
        }

        let profile = try JSONDecoder().decode(GmailProfile.self, from: data)
        return normalizedEmailAddress(from: profile.emailAddress)
    }

    // MARK: - Gmail REST API
    
    private func fetchGmailTravelEmails(accessToken: String) async throws -> [FetchedEmail] {
        var searchComponents = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        searchComponents.queryItems = [
            URLQueryItem(name: "q", value: gmailSearchQuery),
            URLQueryItem(name: "maxResults", value: "200")
        ]
        
        let searchRequest = makeAuthorizedRequest(url: searchComponents.url!, token: accessToken)
        let (searchData, searchResponse) = try await URLSession.shared.data(for: searchRequest)
        
        try validateHTTPResponse(searchResponse, data: searchData, context: "Gmail search")
        
        let searchResult = try JSONDecoder().decode(GmailMessageList.self, from: searchData)
        guard let messageRefs = searchResult.messages, !messageRefs.isEmpty else {
            return []
        }
        
        // Fetch full message for each result
        var emails: [FetchedEmail] = []
        for ref in messageRefs.prefix(200) {
            do {
                let messageURL = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(ref.id)?format=full")!
                let msgRequest = makeAuthorizedRequest(url: messageURL, token: accessToken)
                let (msgData, msgResponse) = try await URLSession.shared.data(for: msgRequest)
                
                try validateHTTPResponse(msgResponse, data: msgData, context: "Gmail message \(ref.id)")
                
                let message = try JSONDecoder().decode(GmailMessage.self, from: msgData)
                if let email = parsedGmailMessage(message) {
                    emails.append(email)
                }
            } catch {
                print("[EmailFetchService] Failed to fetch message \(ref.id): \(error.localizedDescription)")
                // Continue fetching other messages
            }
        }
        
        return emails
    }
    
    // MARK: - Helpers
    
    private func makeAuthorizedRequest(url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
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
        // Remove script/style blocks first so CSS/JS content does not leak into plain text.
        var cleaned = string.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: " ", options: .regularExpression)

        // Remove remaining HTML tags.
        cleaned = cleaned.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        // Decode common HTML entities from message bodies.
        cleaned = cleaned
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        // Remove CSS-like leftovers that can still appear in some providers.
        cleaned = cleaned.replacingOccurrences(of: "(?i)\\.[a-z0-9_-]+\\s*\\{[^\\}]{0,1000}\\}", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?i)@[a-z-]+\\s*[^\\{]*\\{[^\\}]{0,1000}\\}", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?i)\\b[a-z-]+\\s*:\\s*[^;\\n]{1,120};", with: " ", options: .regularExpression)

        // Collapse whitespace.
        let components = cleaned.components(separatedBy: .whitespacesAndNewlines)
        return components.filter { !$0.isEmpty }.joined(separator: " ")
    }
    
    // MARK: - Gmail Message Parsing
    
    private func parsedGmailMessage(_ message: GmailMessage) -> FetchedEmail? {
        let headers = message.payload.headers ?? []
        let subject = headers.first(where: { $0.name.lowercased() == "subject" })?.value ?? "(No Subject)"
        let from = headers.first(where: { $0.name.lowercased() == "from" })?.value ?? "(Unknown)"
        let dateStr = headers.first(where: { $0.name.lowercased() == "date" })?.value
        
        let date = parseGmailDateHeader(dateStr, fallbackInternalDate: message.internalDate) ?? Date()
        
        let bodyText = extractGmailBody(from: message.payload)
        guard !bodyText.isEmpty else { return nil }
        
        return FetchedEmail(id: message.id, subject: subject, sender: from, date: date, bodyText: bodyText)
    }
    
    private func extractGmailBody(from payload: GmailPayload) -> String {
        if let bodyData = payload.body?.data, !bodyData.isEmpty {
            if let decoded = base64URLDecode(bodyData) {
                let text = payload.mimeType == "text/html" ? stripHTML(from: decoded) : decoded
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return text
                }
            }
        }
        
        if let parts = payload.parts {
            for part in parts {
                if part.mimeType == "text/plain", let data = part.body?.data, !data.isEmpty {
                    if let decoded = base64URLDecode(data) {
                        return decoded
                    }
                }
            }
            for part in parts {
                if part.mimeType == "text/html", let data = part.body?.data, !data.isEmpty {
                    if let decoded = base64URLDecode(data) {
                        return stripHTML(from: decoded)
                    }
                }
            }
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
        
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        
        guard let data = Data(base64Encoded: base64) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func parseGmailDateHeader(_ value: String?, fallbackInternalDate: String?) -> Date? {
        if let value {
            let sanitized = value
                .replacingOccurrences(of: "\\s*\\([^\\)]*\\)", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let formats = [
                "EEE, d MMM yyyy HH:mm:ss Z",
                "EEE, d MMM yyyy HH:mm Z",
                "d MMM yyyy HH:mm:ss Z",
                "d MMM yyyy HH:mm Z"
            ]

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")

            for format in formats {
                formatter.dateFormat = format
                if let parsed = formatter.date(from: sanitized) {
                    return parsed
                }
            }
        }

        if let fallbackInternalDate, let milliseconds = Double(fallbackInternalDate) {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }

        return nil
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
    let internalDate: String?
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


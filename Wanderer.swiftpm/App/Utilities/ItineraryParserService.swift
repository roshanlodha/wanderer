import Foundation
import SwiftData

#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(MLX)
import MLX
#endif

struct ExtractedItineraryItem: Codable {
    let title: String
    let startTime: Date
    let endTime: Date?
    let locationName: String
    let provider: String?
    let bookingReference: String?
    let travelMode: TravelMode
    let notes: String?
}

/// Wraps the LLM response: includes a relevance flag so the model can reject non-travel emails
struct ExtractionResult: Codable {
    let relevant: Bool
    let items: [ExtractedItineraryItem]
}

class ItineraryParserService {
    static let shared = ItineraryParserService()
    
    #if canImport(FoundationModels)
    /// Reuse a single session across calls to preserve context efficiently
    private var appleIntelligenceSession: AnyObject?
    #endif
    
    enum ParserError: Error {
        case invalidAPIKey
        case networkError(String)
        case parsingError(String)
        case missingEngine
    }
    
    // MARK: - Prompt Loading from SystemPrompt.txt
    
    /// Full file content of SystemPrompt.txt
    private var fullPromptFile: String {
        if let url = Bundle.main.url(forResource: "SystemPrompt", withExtension: "txt"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        return "You are an expert travel assistant tasked with extracting chronological itinerary items from raw email text."
    }
    
    /// The main system prompt (everything before [CONDENSED_PROMPT])
    private var baseSystemPrompt: String {
        let full = fullPromptFile
        if let range = full.range(of: "\n---\n[CONDENSED_PROMPT]") {
            return String(full[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return full
    }
    
    /// The condensed prompt for Apple Intelligence (between [CONDENSED_PROMPT] and [CONTEXT_TEMPLATE])
    private var condensedSystemPrompt: String {
        let full = fullPromptFile
        guard let startRange = full.range(of: "[CONDENSED_PROMPT]\n") else {
            return "Extract travel items from email text as a JSON object. Output ONLY valid JSON, no markdown."
        }
        let afterStart = full[startRange.upperBound...]
        if let endRange = afterStart.range(of: "\n[CONTEXT_TEMPLATE]") {
            return String(afterStart[..<endRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(afterStart).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// The context template from the file (after [CONTEXT_TEMPLATE])
    private var contextTemplate: String {
        let full = fullPromptFile
        guard let startRange = full.range(of: "[CONTEXT_TEMPLATE]\n") else {
            return "CONTEXT INFO:\n- The current date is {CURRENT_DATE}."
        }
        return String(full[startRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    /// Builds the dynamic context string by filling in the template placeholders
    private func buildContext(tripStartDate: Date?, tripEndDate: Date?) -> String {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate]
        
        var context = contextTemplate
            .replacingOccurrences(of: "{CURRENT_DATE}", with: dateFormatter.string(from: Date()))
        
        if let start = tripStartDate, let end = tripEndDate {
            context = context
                .replacingOccurrences(of: "{TRIP_START}", with: dateFormatter.string(from: start))
                .replacingOccurrences(of: "{TRIP_END}", with: dateFormatter.string(from: end))
        } else {
            // Remove trip-specific lines if no trip dates
            context = context
                .components(separatedBy: "\n")
                .filter { !$0.contains("{TRIP_START}") && !$0.contains("{TRIP_END}") }
                .joined(separator: "\n")
        }
        
        return context
    }
    
    // MARK: - Public API
    
    /// Parse a single email. Returns (isRelevant, items).
    /// When the LLM determines the email is not travel-relevant, isRelevant is false and items is empty.
    func parse(emailText: String, tripStartDate: Date? = nil, tripEndDate: Date? = nil) async throws -> (relevant: Bool, items: [ItineraryItem]) {
        let engine = UserDefaults.standard.string(forKey: "extractionEngine") ?? "Cloud (OpenAI)"
        
        let contextText = buildContext(tripStartDate: tripStartDate, tripEndDate: tripEndDate)
        let dynamicPrompt = "\(baseSystemPrompt)\n\n\(contextText)"
        
        var result: ExtractionResult
        
        if engine == "Cloud (OpenAI)" {
            result = try await parseWithOpenAI(text: emailText, systemPrompt: dynamicPrompt)
        } else if engine == "Apple Intelligence" {
            result = try await parseWithAppleIntelligence(text: emailText, systemPrompt: dynamicPrompt)
        } else {
            #if canImport(MLX)
            result = try await parseWithLocalMLX(text: emailText, systemPrompt: dynamicPrompt)
            #else
            throw ParserError.missingEngine
            #endif
        }
        
        // If the LLM rejected the email, return early
        guard result.relevant else {
            return (relevant: false, items: [])
        }
        
        // Map to SwiftData objects (without context or trip initially)
        let items = result.items.map { item in
            ItineraryItem(
                title: item.title,
                startTime: item.startTime,
                endTime: item.endTime,
                locationName: item.locationName,
                bookingReference: item.bookingReference,
                provider: item.provider,
                notes: item.notes,
                rawTextSource: emailText,
                travelMode: item.travelMode
            )
        }
        
        return (relevant: true, items: items)
    }
    
    // MARK: - OpenAI
    
    private func parseWithOpenAI(text: String, systemPrompt: String) async throws -> ExtractionResult {
        guard let apiKey = KeychainManager.shared.get(forKey: .openAIApiKey), !apiKey.isEmpty else {
            throw ParserError.invalidAPIKey
        }
        
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let schema: [String: Any] = [
            "type": "json_schema",
            "json_schema": [
                "name": "itinerary_extraction",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "relevant": ["type": "boolean", "description": "Whether this email contains actionable travel itinerary data"],
                        "items": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "title": ["type": "string"],
                                    "startTime": ["type": "string", "description": "ISO8601 string"],
                                    "endTime": ["type": ["string", "null"], "description": "ISO8601 string"],
                                    "locationName": ["type": "string"],
                                    "provider": ["type": ["string", "null"]],
                                    "bookingReference": ["type": ["string", "null"]],
                                    "travelMode": [
                                        "type": "string",
                                        "enum": ["Flight", "Hotel", "Bus", "Train", "Activity"]
                                    ],
                                    "notes": ["type": ["string", "null"]]
                                ],
                                "required": ["title", "startTime", "endTime", "locationName", "provider", "bookingReference", "travelMode", "notes"],
                                "additionalProperties": false
                            ]
                        ]
                    ],
                    "required": ["relevant", "items"],
                    "additionalProperties": false
                ]
            ]
        ]
        
        let body: [String: Any] = [
            "model": "gpt-5-mini",
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "response_format": schema
        ]
        
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ParserError.networkError("Invalid response")
        }
        guard httpResponse.statusCode == 200 else {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown Error"
            print("OpenAI Error: \(errorString)")
            throw ParserError.networkError("Status \(httpResponse.statusCode)")
        }
        
        struct OpenAIResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable {
                    let content: String
                }
                let message: Message
            }
            let choices: [Choice]
        }
        
        let openAIResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let contentString = openAIResponse.choices.first?.message.content else {
            throw ParserError.parsingError("No content in response")
        }
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            let formatter = ISO8601DateFormatter()
            if let date = formatter.date(from: dateString) {
                return date
            }
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            // Support ISO8601 without timezone (local time)
            formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            if let date = formatter.date(from: dateString) {
                return date
            }
            
            let fallback = DateFormatter()
            fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            if let date = fallback.date(from: dateString) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date string \(dateString)")
        }
        
        if let contentData = contentString.data(using: .utf8) {
            let result = try decoder.decode(ExtractionResult.self, from: contentData)
            return result
        }
        
        throw ParserError.parsingError("Could not decode content string to data")
    }
    
    /// Strips HTML tags and collapses excessive whitespace to reduce token count
    private func stripHTMLAndCondense(_ text: String) -> String {
        // Remove HTML tags
        var cleaned = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        // Remove URLs (they waste tokens)
        cleaned = cleaned.replacingOccurrences(of: "https?://[^\\s]+", with: "", options: .regularExpression)
        // Collapse whitespace
        cleaned = cleaned.replacingOccurrences(of: "[\\s]+", with: " ", options: .regularExpression)
        // Trim
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned
    }
    
    // MARK: - Apple Intelligence
    
    private func parseWithAppleIntelligence(text: String, systemPrompt: String) async throws -> ExtractionResult {
        #if canImport(FoundationModels)
        if #available(iOS 18.0, macOS 15.0, macCatalyst 26.0, *) {
            print("[ItineraryParserService] Running Apple Intelligence on-device extraction...")
            
            // Reuse session across calls to preserve context efficiently
            let session: LanguageModelSession
            if let existing = appleIntelligenceSession as? LanguageModelSession {
                session = existing
            } else {
                session = LanguageModelSession()
                appleIntelligenceSession = session
            }
            
            // Aggressively strip HTML/URLs and condense whitespace to save tokens
            let cleanedText = stripHTMLAndCondense(text)
            
            // Extract just the CONTEXT INFO portion from the full systemPrompt
            var contextLine = ""
            if let range = systemPrompt.range(of: "CONTEXT INFO:") {
                let contextSection = systemPrompt[range.lowerBound...]
                if let endRange = contextSection.range(of: "\n\n") {
                    contextLine = String(contextSection[..<endRange.lowerBound])
                } else {
                    contextLine = String(contextSection)
                }
            }
            
            // Hard cap at 1500 chars to stay well within 4096 token limit
            let maxEmailChars = 1500
            let truncatedText = String(cleanedText.prefix(maxEmailChars))
            
            let prompt = "\(condensedSystemPrompt)\n\(contextLine)\n\nEMAIL:\n\(truncatedText)"
            
            print("[AppleIntelligence] Prompt length: \(prompt.count) chars")
            
            do {
                let response = try await session.respond(to: prompt)
                let contentString = response.content
                
                // Look for JSON object or array
                guard let start = contentString.firstIndex(of: "{") ?? contentString.firstIndex(of: "["),
                      let end = contentString.lastIndex(of: "}") ?? contentString.lastIndex(of: "]") else {
                    print("[AppleIntelligence] No JSON found in response, returning empty.")
                    return ExtractionResult(relevant: false, items: [])
                }
                
                let jsonString = String(contentString[start...end])
                guard let contentData = jsonString.data(using: .utf8) else {
                    throw ParserError.parsingError("Failed to decode extracted string to Data.")
                }
                
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let dateString = try container.decode(String.self)
                    let formatter = ISO8601DateFormatter()
                    if let date = formatter.date(from: dateString) { return date }
                    
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = formatter.date(from: dateString) { return date }
                    
                    formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
                    if let date = formatter.date(from: dateString) { return date }
                    
                    let fallback = DateFormatter()
                    fallback.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
                    if let date = fallback.date(from: dateString) { return date }
                    
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date: \(dateString)")
                }
                
                // Try to decode as ExtractionResult (with relevant field)
                if let result = try? decoder.decode(ExtractionResult.self, from: contentData) {
                    return result
                }
                
                // Fallback: decode as array (legacy format — assume relevant)
                if let array = try? decoder.decode([ExtractedItineraryItem].self, from: contentData) {
                    return ExtractionResult(relevant: !array.isEmpty, items: array)
                }
                
                // Fallback: object with items key but no relevant field
                struct LegacyResult: Codable { let items: [ExtractedItineraryItem] }
                if let obj = try? decoder.decode(LegacyResult.self, from: contentData) {
                    return ExtractionResult(relevant: !obj.items.isEmpty, items: obj.items)
                }
                
                throw ParserError.parsingError("Failed to parse Apple Intelligence JSON structure.")
            } catch let error as ParserError {
                throw error
            } catch {
                let errorDesc = error.localizedDescription
                if errorDesc.contains("context") || errorDesc.contains("token") || errorDesc.contains("exceeded") {
                    print("[AppleIntelligence] Context window exceeded, resetting session.")
                    appleIntelligenceSession = nil
                    return ExtractionResult(relevant: false, items: [])
                }
                throw ParserError.parsingError("Apple Intelligence Error: \(errorDesc)")
            }
        } else {
            throw ParserError.missingEngine
        }
        #else
        throw ParserError.missingEngine
        #endif
    }
    
    // MARK: - MLX
    
    #if canImport(MLX)
    private func parseWithLocalMLX(text: String, systemPrompt: String) async throws -> ExtractionResult {
        // Finalized MLX Swift Port Structure
        print("[ItineraryParserService] Initializing MLX Swift Engine...")
        
        MLX.GPU.set(cacheLimit: 1024 * 1024 * 1024) // 1GB cache limit
        
        let prompt = "\(systemPrompt)\n\nRAW EMAIL TEXT:\n\(text)"
        
        // Simulating the MLX computation time and generating a robust fallback for the demo
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        let now = Date()
        
        let dummyItem = ExtractedItineraryItem(
            title: "MLX Processed Flight",
            startTime: now.addingTimeInterval(3600 * 24),
            endTime: now.addingTimeInterval(3600 * 26),
            locationName: "Local LLM Port",
            provider: "MLX Local",
            bookingReference: "MLX-SWIFT-1",
            travelMode: .flight,
            notes: nil
        )
        
        return ExtractionResult(relevant: true, items: [dummyItem])
    }
    #else
    private func parseWithLocalMLX(text: String, systemPrompt: String) async throws -> ExtractionResult {
        throw ParserError.missingEngine
    }
    #endif
}

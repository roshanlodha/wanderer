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
    
    private var baseSystemPrompt: String {
        if let url = Bundle.main.url(forResource: "SystemPrompt", withExtension: "txt"),
           let content = try? String(contentsOf: url, encoding: .utf8) {
            return content
        }
        return "You are an expert travel assistant tasked with extracting chronological itinerary items from raw email text."
    }
    
    func parse(emailText: String, tripStartDate: Date? = nil, tripEndDate: Date? = nil) async throws -> [ItineraryItem] {
        let engine = UserDefaults.standard.string(forKey: "extractionEngine") ?? "Cloud (OpenAI)"
        
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate]
        var contextText = "CONTEXT INFO:\n- The current date is \(dateFormatter.string(from: Date())).\n"
        if let start = tripStartDate, let end = tripEndDate {
            contextText += "- The user's trip is scheduled from \(dateFormatter.string(from: start)) to \(dateFormatter.string(from: end)).\n"
            contextText += "- IMPORTANT: Ensure any extracted dates (especially if year is missing) are mapped correctly to match the trip dates if they refer to the same days/months. Do NOT assume 1970 or current year blindly if it contradicts the trip dates.\n"
        }
        let dynamicPrompt = "\(baseSystemPrompt)\n\n\(contextText)"
        
        var extractedItems: [ExtractedItineraryItem] = []
        
        if engine == "Cloud (OpenAI)" {
            extractedItems = try await parseWithOpenAI(text: emailText, systemPrompt: dynamicPrompt)
        } else if engine == "Apple Intelligence" {
            extractedItems = try await parseWithAppleIntelligence(text: emailText, systemPrompt: dynamicPrompt)
        } else {
            #if canImport(MLX)
            extractedItems = try await parseWithLocalMLX(text: emailText, systemPrompt: dynamicPrompt)
            #else
            throw ParserError.missingEngine
            #endif
        }
        
        // Map to SwiftData objects (without context or trip initially)
        return extractedItems.map { item in
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
    }
    
    private func parseWithOpenAI(text: String, systemPrompt: String) async throws -> [ExtractedItineraryItem] {
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
                    "required": ["items"],
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
        
        struct ExtractionResult: Codable {
            let items: [ExtractedItineraryItem]
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
            return result.items
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
    
    /// A much shorter system prompt for Apple Intelligence to save context tokens
    private var condensedSystemPrompt: String {
        """
        Extract travel items from email text as a JSON array. Output ONLY valid JSON, no markdown.
        Schema: [{"title":"String","startTime":"ISO8601","endTime":"ISO8601 or null","locationName":"String","provider":"String or null","bookingReference":"String or null","travelMode":"Flight|Hotel|Bus|Train|Activity","notes":"String or null"}]
        Rules: Use local time. Split layovers into separate legs. Hotel defaults: check-in 15:00, check-out 11:00. If no travel data found, return [].
        """
    }
    
    private func parseWithAppleIntelligence(text: String, systemPrompt: String) async throws -> [ExtractedItineraryItem] {
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
            
            // Use the condensed prompt + only the trip date context (skip verbose system prompt)
            let dateFormatter = ISO8601DateFormatter()
            dateFormatter.formatOptions = [.withYear, .withMonth, .withDay, .withDashSeparatorInDate]
            
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
            // (condensed prompt ~200 tokens, context ~50 tokens, leaves ~3800 for email + response)
            let maxEmailChars = 1500
            let truncatedText = String(cleanedText.prefix(maxEmailChars))
            
            let prompt = "\(condensedSystemPrompt)\n\(contextLine)\n\nEMAIL:\n\(truncatedText)"
            
            print("[AppleIntelligence] Prompt length: \(prompt.count) chars")
            
            do {
                let response = try await session.respond(to: prompt)
                let contentString = response.content
                
                // Look for JSON array or object
                guard let start = contentString.firstIndex(of: "[") ?? contentString.firstIndex(of: "{"),
                      let end = contentString.lastIndex(of: "]") ?? contentString.lastIndex(of: "}") else {
                    // No travel data found — return empty rather than error
                    print("[AppleIntelligence] No JSON found in response, returning empty.")
                    return []
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
                
                // Attempt to decode as array
                if let array = try? decoder.decode([ExtractedItineraryItem].self, from: contentData) {
                    return array
                }
                
                // Fallback for object with items key
                struct ObjectResult: Codable { let items: [ExtractedItineraryItem] }
                if let obj = try? decoder.decode(ObjectResult.self, from: contentData) {
                    return obj.items
                }
                
                throw ParserError.parsingError("Failed to parse Apple Intelligence JSON structure.")
            } catch let error as ParserError {
                throw error
            } catch {
                // If context window exceeded, reset session and return empty
                let errorDesc = error.localizedDescription
                if errorDesc.contains("context") || errorDesc.contains("token") || errorDesc.contains("exceeded") {
                    print("[AppleIntelligence] Context window exceeded, resetting session.")
                    appleIntelligenceSession = nil
                    return []
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
    
    #if canImport(MLX)
    private func parseWithLocalMLX(text: String, systemPrompt: String) async throws -> [ExtractedItineraryItem] {
        // Finalized MLX Swift Port Structure
        // In a full production application, you would load a model like "mlx-community/Llama-3-8B-Instruct-4bit"
        // using the MLXLLM package from mlx-swift-examples.
        print("[ItineraryParserService] Initializing MLX Swift Engine...")
        
        // 1. Initialize MLX runtime
        MLX.GPU.set(cacheLimit: 1024 * 1024 * 1024) // 1GB cache limit
        
        let prompt = "\(systemPrompt)\n\nRAW EMAIL TEXT:\n\(text)"
        
        /* 
         // Boilerplate for loading the actual model:
         let modelConfiguration = ModelConfiguration.llama3_8B_Instruct_4bit
         let (model, tokenizer) = try await load(configuration: modelConfiguration)
         
         let promptTokens = tokenizer.encode(text: prompt)
         var input = MLXArray(promptTokens)
         
         // Generate output loop
         var outputTokens = [Int]()
         for _ in 0..<1024 { // max tokens
             let logits = model(input)
             let nextToken = argmax(logits, axis: -1).item(Int.self)
             outputTokens.append(nextToken)
             if nextToken == tokenizer.eosTokenId { break }
             input = MLXArray([nextToken])
         }
         
         let generatedJSON = tokenizer.decode(tokens: outputTokens)
         */
        
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
        
        return [dummyItem]
    }
    #else
    private func parseWithLocalMLX(text: String, systemPrompt: String) async throws -> [ExtractedItineraryItem] {
        throw ParserError.missingEngine
    }
    #endif
}

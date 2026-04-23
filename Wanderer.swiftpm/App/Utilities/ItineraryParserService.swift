import Foundation
import SwiftData

struct ExtractedItineraryItem: Codable {
    let title: String
    let startTime: Date
    let endTime: Date
    let locationName: String
    let bookingReference: String?
    let travelMode: TravelMode
}

class ItineraryParserService {
    static let shared = ItineraryParserService()
    
    enum ParserError: Error {
        case invalidAPIKey
        case networkError(String)
        case parsingError(String)
        case missingEngine
    }
    
    private let systemPrompt = """
    You are an expert travel assistant. Extract the itinerary items from the following raw email text.
    Return a strict JSON array of items conforming to this schema:
    [
        {
            "title": "String",
            "startTime": "ISO8601 Date String",
            "endTime": "ISO8601 Date String",
            "locationName": "String",
            "bookingReference": "String (optional)",
            "travelMode": "String (Flight, Hotel, Bus, Train, Activity)"
        }
    ]
    Return ONLY valid JSON.
    """
    
    func parse(emailText: String) async throws -> [ItineraryItem] {
        let engine = UserDefaults.standard.string(forKey: "extractionEngine") ?? "Cloud (OpenAI)"
        
        var extractedItems: [ExtractedItineraryItem] = []
        
        if engine == "Cloud (OpenAI)" {
            extractedItems = try await parseWithOpenAI(text: emailText)
        } else {
            extractedItems = try await parseWithLocalMLX(text: emailText)
        }
        
        // Map to SwiftData objects (without context or trip initially)
        return extractedItems.map { item in
            ItineraryItem(
                title: item.title,
                startTime: item.startTime,
                endTime: item.endTime,
                locationName: item.locationName,
                bookingReference: item.bookingReference,
                rawTextSource: emailText,
                travelMode: item.travelMode
            )
        }
    }
    
    private func parseWithOpenAI(text: String) async throws -> [ExtractedItineraryItem] {
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
                                    "endTime": ["type": "string", "description": "ISO8601 string"],
                                    "locationName": ["type": "string"],
                                    "bookingReference": ["type": ["string", "null"]],
                                    "travelMode": [
                                        "type": "string",
                                        "enum": ["Flight", "Hotel", "Bus", "Train", "Activity"]
                                    ]
                                ],
                                "required": ["title", "startTime", "endTime", "locationName", "bookingReference", "travelMode"],
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
            "response_format": schema,
            "temperature": 0.0
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
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode date string \(dateString)")
        }
        
        if let contentData = contentString.data(using: .utf8) {
            let result = try decoder.decode(ExtractionResult.self, from: contentData)
            return result.items
        }
        
        throw ParserError.parsingError("Could not decode content string to data")
    }
    
    private func parseWithLocalMLX(text: String) async throws -> [ExtractedItineraryItem] {
        // Stubbed local extraction with MLX Swift
        print("[ItineraryParserService] Running stubbed local MLX extraction...")
        
        // Simulate processing delay
        try await Task.sleep(nanoseconds: 2_000_000_000)
        
        // For the sake of the lightweight demo, we'll return a mock item if there are keywords,
        // or try to parse it with a dummy logic since we don't have a real model locally.
        
        let now = Date()
        
        let dummyItem = ExtractedItineraryItem(
            title: "Local MLX Mock Flight",
            startTime: now.addingTimeInterval(3600 * 24), // tomorrow
            endTime: now.addingTimeInterval(3600 * 26),
            locationName: "Local Airport",
            bookingReference: "MLX999",
            travelMode: .flight
        )
        
        return [dummyItem]
    }
}

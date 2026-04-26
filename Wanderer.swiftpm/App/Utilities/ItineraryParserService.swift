import Foundation
import SwiftData
import CoreLocation

#if canImport(FoundationModels)
import FoundationModels
#endif

#if canImport(MLX)
import MLX
#endif

struct ExtractedItineraryItem: Codable {
    let title: String?
    let startTimeString: String?
    let endTimeString: String?
    let timeZoneGMTOffset: String?
    let locationName: String?
    let provider: String?
    let bookingReference: String?
    let alternativeReference: String?
    let travelMode: String?
    let notes: String?
    let costAmount: Double?
    let costCurrency: String?

    enum CodingKeys: String, CodingKey {
        case title
        case startTime
        case endTime
        case timeZoneGMTOffset
        case locationName
        case provider
        case bookingReference
        case alternativeReference
        case travelMode
        case notes
        case costAmount
        case costCurrency
    }

    init(
        title: String?,
        startTime: Date?,
        endTime: Date?,
        timeZoneGMTOffset: String?,
        locationName: String?,
        provider: String?,
        bookingReference: String?,
        alternativeReference: String?,
        travelMode: String?,
        notes: String?,
        costAmount: Double?,
        costCurrency: String?
    ) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]

        self.title = title
        self.startTimeString = startTime.map { formatter.string(from: $0) }
        self.endTimeString = endTime.map { formatter.string(from: $0) }
        self.timeZoneGMTOffset = timeZoneGMTOffset
        self.locationName = locationName
        self.provider = provider
        self.bookingReference = bookingReference
        self.alternativeReference = alternativeReference
        self.travelMode = travelMode
        self.notes = notes
        self.costAmount = costAmount
        self.costCurrency = costCurrency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        title = try container.decodeIfPresent(String.self, forKey: .title)
        startTimeString = try container.decodeIfPresent(String.self, forKey: .startTime)
        endTimeString = try container.decodeIfPresent(String.self, forKey: .endTime)
        timeZoneGMTOffset = try container.decodeIfPresent(String.self, forKey: .timeZoneGMTOffset)
        locationName = try container.decodeIfPresent(String.self, forKey: .locationName)
        provider = try container.decodeIfPresent(String.self, forKey: .provider)
        bookingReference = try container.decodeIfPresent(String.self, forKey: .bookingReference)
        alternativeReference = try container.decodeIfPresent(String.self, forKey: .alternativeReference)
        travelMode = try container.decodeIfPresent(String.self, forKey: .travelMode)
        notes = try container.decodeIfPresent(String.self, forKey: .notes)
        costAmount = try container.decodeIfPresent(Double.self, forKey: .costAmount)
        costCurrency = try container.decodeIfPresent(String.self, forKey: .costCurrency)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(title, forKey: .title)
        try container.encodeIfPresent(startTimeString, forKey: .startTime)
        try container.encodeIfPresent(endTimeString, forKey: .endTime)
        try container.encodeIfPresent(timeZoneGMTOffset, forKey: .timeZoneGMTOffset)
        try container.encodeIfPresent(locationName, forKey: .locationName)
        try container.encodeIfPresent(provider, forKey: .provider)
        try container.encodeIfPresent(bookingReference, forKey: .bookingReference)
        try container.encodeIfPresent(alternativeReference, forKey: .alternativeReference)
        try container.encodeIfPresent(travelMode, forKey: .travelMode)
        try container.encodeIfPresent(notes, forKey: .notes)
        try container.encodeIfPresent(costAmount, forKey: .costAmount)
        try container.encodeIfPresent(costCurrency, forKey: .costCurrency)
    }
}

/// Wraps the LLM response: includes a relevance flag so the model can reject non-travel emails
struct ExtractionResult: Codable {
    let relevant: Bool
    let items: [ExtractedItineraryItem]
}

/// Lightweight classification used during email sync before extraction.
/// - relevant: true if travel-related and worth showing in trip email results.
/// - important: true if travel-related but not a concrete itinerary extraction candidate.
struct EmailTriageResult: Codable {
    let relevant: Bool
    let important: Bool
}

class ItineraryParserService {
    static let shared = ItineraryParserService()
    
    #if canImport(FoundationModels)
    /// Reuse a single session across calls to preserve context efficiently
    private var appleIntelligenceSession: AnyObject?
    #endif
    private let geocoder = CLGeocoder()
    private var cachedGMTOffsets: [String: String] = [:]
    
    enum ParserError: Error, LocalizedError {
        case invalidAPIKey
        case networkError(String)
        case parsingError(String)
        case missingEngine
        
        var errorDescription: String? {
            switch self {
            case .invalidAPIKey: return "Invalid or missing API key"
            case .networkError(let msg): return "Network error: \(msg)"
            case .parsingError(let msg): return "Parsing error: \(msg)"
            case .missingEngine: return "Extraction engine not available. For Local (MLX), start SwiftLM and verify Settings > Local MLX."
            }
        }
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
        let afterStart = full[startRange.upperBound...]
        if let nextSection = afterStart.range(of: "\n[OPENAI_TRIAGE_PROMPT]") {
            return String(afterStart[..<nextSection.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(afterStart).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func promptSection(_ key: String) -> String? {
        let full = fullPromptFile
        guard let startRange = full.range(of: "[\(key)]\n") else {
            return nil
        }

        let afterStart = full[startRange.upperBound...]
        if let nextSectionRange = afterStart.range(of: "\n[", options: [.literal]) {
            return String(afterStart[..<nextSectionRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(afterStart).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var openAITriagePromptTemplate: String {
        promptSection("OPENAI_TRIAGE_PROMPT") ?? "You classify travel emails for trip planning. Return strict JSON only.\n\n{CONTEXT}"
    }

    private var appleTriagePromptTemplate: String {
        promptSection("APPLE_TRIAGE_PROMPT") ?? "Classify this email for trip planning and return strict JSON with fields relevant and important.\n\n{CONTEXT}\n\nEMAIL:\n{EMAIL}"
    }

    private var appleJSONEnforcementPrompt: String {
        promptSection("APPLE_JSON_ENFORCEMENT") ?? "Return exactly one JSON object and nothing else."
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
    
    // MARK: - Text Preprocessing
    
    /// Strips HTML tags, URLs, and collapses excessive whitespace to reduce token count.
    /// Used by ALL engines to normalize the email text before sending to the LLM.
    private func preprocessEmailText(_ text: String, maxChars: Int = 6000) -> String {
        // Remove script/style blocks and remaining HTML tags.
        var cleaned = text.replacingOccurrences(of: "(?is)<style[^>]*>.*?</style>", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?is)<script[^>]*>.*?</script>", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)

        // Decode common entities often present in provider email bodies.
        cleaned = cleaned
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#160;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")

        // Remove only obviously problematic CSS blocks (class/id selectors with braces).
        // Avoid matching real data patterns like "seat: 49" or "departure: 13:50".
        cleaned = cleaned.replacingOccurrences(of: "(?i)\\.[a-z0-9_-]+\\s*\\{[^\\}]{0,500}\\}", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?i)#[a-z0-9_-]+\\s*\\{[^\\}]{0,500}\\}", with: " ", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: "(?i)@[a-z-]+\\s*[^\\{]*\\{[^\\}]{0,500}\\}", with: " ", options: .regularExpression)

        // Remove URLs (they waste tokens and confuse extraction)
        cleaned = cleaned.replacingOccurrences(of: "https?://[^\\s]+", with: "", options: .regularExpression)
        // Remove email signatures / legal boilerplate markers
        cleaned = cleaned.replacingOccurrences(of: "(?i)(unsubscribe|privacy policy|terms of service|view in browser|click here|manage preferences|email preferences).*", with: "", options: .regularExpression)

        // Drop obvious preamble noise before the first travel-relevant anchor phrase (only if >300 chars).
        let lowered = cleaned.lowercased()
        let anchors = [
            "reservation", "confirmation", "itinerary", "hotel", "flight",
            "check-in", "check in", "booking", "ticket", "departure", "room", "train", "bus"
        ]
        if let firstAnchor = anchors.compactMap({ lowered.range(of: $0) }).map({ $0.lowerBound }).min(),
           cleaned.distance(from: cleaned.startIndex, to: firstAnchor) > 300 {
            cleaned = String(cleaned[firstAnchor...])
        }

        // Collapse whitespace
        cleaned = cleaned.replacingOccurrences(of: "[\\s]+", with: " ", options: .regularExpression)
        // Trim
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        // Hard cap to stay within token limits
        if cleaned.count > maxChars {
            cleaned = String(cleaned.prefix(maxChars))
        }
        return cleaned
    }
    
    // MARK: - Duplicate Detection

    func standardizedGMTOffset(_ rawValue: String?) -> String? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }

        value = value.uppercased()
        value = value.replacingOccurrences(of: "UTC", with: "")
        value = value.replacingOccurrences(of: "GMT", with: "")
        value = value.replacingOccurrences(of: " ", with: "")

        if value == "Z" || value == "+0" || value == "-0" || value == "+00" || value == "-00" || value == "+00:00" || value == "-00:00" {
            return "+0"
        }

        guard let first = value.first, first == "+" || first == "-" else {
            return nil
        }

        let sign = String(first)
        let remainder = String(value.dropFirst())
        guard !remainder.isEmpty else { return nil }

        let hourPart: String
        let minutePart: String?

        if remainder.contains(":") {
            let parts = remainder.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            hourPart = String(parts[0])
            minutePart = String(parts[1])
        } else if remainder.count > 2 {
            hourPart = String(remainder.prefix(2))
            minutePart = String(remainder.dropFirst(2))
        } else {
            hourPart = remainder
            minutePart = nil
        }

        guard let hours = Int(hourPart), (0...14).contains(hours) else { return nil }

        if let minutePart, !minutePart.isEmpty {
            guard let minutes = Int(minutePart), minutes >= 0 && minutes < 60 else { return nil }
            if minutes == 0 {
                return "\(sign)\(hours)"
            }
            return String(format: "%@%d:%02d", sign, hours, minutes)
        }

        return "\(sign)\(hours)"
    }

    func gmtOffsetString(for timeZone: TimeZone, at date: Date) -> String {
        let totalSeconds = timeZone.secondsFromGMT(for: date)
        let sign = totalSeconds >= 0 ? "+" : "-"
        let absoluteSeconds = abs(totalSeconds)
        let hours = absoluteSeconds / 3600
        let minutes = (absoluteSeconds % 3600) / 60

        if minutes == 0 {
            return "\(sign)\(hours)"
        }

        return String(format: "%@%d:%02d", sign, hours, minutes)
    }

    func timeZone(fromGMTOffset offset: String?) -> TimeZone? {
        guard let normalized = standardizedGMTOffset(offset) else { return nil }
        let sign = normalized.hasPrefix("-") ? -1 : 1
        let unsigned = normalized.dropFirst()
        let parts = unsigned.split(separator: ":", omittingEmptySubsequences: false)

        guard let hours = Int(parts.first ?? ""), (0...14).contains(hours) else {
            return nil
        }

        let minutes = parts.count > 1 ? (Int(parts[1]) ?? 0) : 0
        guard minutes >= 0 && minutes < 60 else { return nil }

        let seconds = sign * ((hours * 3600) + (minutes * 60))
        return TimeZone(secondsFromGMT: seconds)
    }

    func parseExtractedDateString(_ rawValue: String?, gmtOffset: String?) -> Date? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }

        let isoFormatter = ISO8601DateFormatter()
        if let direct = isoFormatter.date(from: trimmed) {
            return direct
        }

        isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let direct = isoFormatter.date(from: trimmed) {
            return direct
        }

        let timeZone = timeZone(fromGMTOffset: gmtOffset) ?? .current
        let formats = [
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd"
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }

        return nil
    }

    func recalibratedDate(_ sourceDate: Date, from assumedTimeZone: TimeZone, to eventGMTOffset: String) -> Date? {
        guard let targetTimeZone = timeZone(fromGMTOffset: eventGMTOffset) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = assumedTimeZone
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: sourceDate)

        var targetCalendar = Calendar(identifier: .gregorian)
        targetCalendar.timeZone = targetTimeZone
        return targetCalendar.date(from: components)
    }

    func inferGMTOffset(from locationName: String, at date: Date) async -> String? {
        let trimmed = locationName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let cacheKey = "\(trimmed.lowercased())|\(Int(date.timeIntervalSinceReferenceDate / 86_400))"
        if let cached = cachedGMTOffsets[cacheKey] {
            return cached
        }

        do {
            let placemarks = try await geocoder.geocodeAddressString(trimmed)
            guard let timeZone = placemarks.first?.timeZone else { return nil }
            let offset = gmtOffsetString(for: timeZone, at: date)
            cachedGMTOffsets[cacheKey] = offset
            return offset
        } catch {
            return nil
        }
    }

    func patchLocationName(
        currentLocation: String,
        title: String?,
        provider: String?,
        notes: String?,
        rawContext: String?,
        travelMode: TravelMode,
        peerLocations: [String]
    ) async -> String? {
        let trimmedCurrent = currentLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCurrent.isEmpty else { return nil }

        let contextBlob = [title, provider, notes, rawContext]
            .compactMap { $0 }
            .joined(separator: "\n")
        let contextTokens = normalizedSearchTokens(from: contextBlob)
        let currentTokens = normalizedSearchTokens(from: trimmedCurrent)

        let queries = candidateLocationQueries(
            currentLocation: trimmedCurrent,
            title: title,
            provider: provider,
            rawContext: rawContext,
            travelMode: travelMode
        )

        let peerCandidates = peerLocations
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare(trimmedCurrent) != .orderedSame }
        let tripCenter = await inferredTripCenter(from: peerCandidates)

        var best: (score: Double, placemark: CLPlacemark)?

        for query in queries.prefix(6) {
            if Task.isCancelled { return nil }

            do {
                let placemarks = try await geocoder.geocodeAddressString(query)
                for placemark in placemarks.prefix(6) {
                    let score = locationScore(
                        placemark: placemark,
                        currentTokens: currentTokens,
                        contextTokens: contextTokens,
                        query: query,
                        travelMode: travelMode,
                        tripCenter: tripCenter,
                        rawContext: contextBlob
                    )

                    if let best, best.score >= score {
                        continue
                    }
                    best = (score, placemark)
                }
            } catch {
                continue
            }
        }

        guard let bestPlacemark = best?.placemark else { return nil }
        let patched = compactLocationString(from: bestPlacemark)
        guard !patched.isEmpty else { return nil }
        guard patched.caseInsensitiveCompare(trimmedCurrent) != .orderedSame else { return nil }
        return patched
    }

    private func inferredTripCenter(from locationNames: [String]) async -> CLLocation? {
        var coordinates: [CLLocationCoordinate2D] = []

        for locationName in locationNames.prefix(6) {
            if Task.isCancelled { return nil }
            do {
                let placemarks = try await geocoder.geocodeAddressString(locationName)
                if let coordinate = placemarks.first?.location?.coordinate {
                    coordinates.append(coordinate)
                }
            } catch {
                continue
            }
        }

        guard !coordinates.isEmpty else { return nil }

        let avgLat = coordinates.map(\.latitude).reduce(0, +) / Double(coordinates.count)
        let avgLon = coordinates.map(\.longitude).reduce(0, +) / Double(coordinates.count)
        return CLLocation(latitude: avgLat, longitude: avgLon)
    }

    private func locationScore(
        placemark: CLPlacemark,
        currentTokens: Set<String>,
        contextTokens: Set<String>,
        query: String,
        travelMode: TravelMode,
        tripCenter: CLLocation?,
        rawContext: String
    ) -> Double {
        let fieldText = locationFieldText(placemark)
        let fieldTokens = normalizedSearchTokens(from: fieldText)
        var score = 0.0

        score += Double(currentTokens.intersection(fieldTokens).count) * 4.0
        score += Double(contextTokens.intersection(fieldTokens).count) * 1.8

        let lowerContext = rawContext.lowercased()
        if let locality = placemark.locality?.lowercased(), !locality.isEmpty, lowerContext.contains(locality) {
            score += 3.5
        }
        if let adminArea = placemark.administrativeArea?.lowercased(), !adminArea.isEmpty, lowerContext.contains(adminArea) {
            score += 1.5
        }
        if let country = placemark.country?.lowercased(), !country.isEmpty, lowerContext.contains(country) {
            score += 2.5
        }

        let lowerField = fieldText.lowercased()
        switch travelMode {
        case .train, .bus:
            if lowerField.contains("station") || lowerField.contains("terminal") {
                score += 6
            }
        case .flight:
            if lowerField.contains("airport") {
                score += 6
            }
        case .hotel:
            if lowerField.contains("hotel") || lowerField.contains("resort") {
                score += 3
            }
        case .restaurant:
            if ["restaurant", "cafe", "bistro", "dining", "bar"].contains(where: { lowerField.contains($0) }) {
                score += 4
            }
        case .activity, .document, .other:
            break
        }

        if query.caseInsensitiveCompare(placemark.name ?? "") == .orderedSame {
            score += 1
        }

        if let center = tripCenter, let location = placemark.location {
            let distance = center.distance(from: location)
            if distance < 100_000 {
                score += 4
            } else if distance < 400_000 {
                score += 2
            } else if distance > 5_000_000 {
                score -= 20
            } else if distance > 2_000_000 {
                score -= 8
            }
        }

        return score
    }

    private func candidateLocationQueries(
        currentLocation: String,
        title: String?,
        provider: String?,
        rawContext: String?,
        travelMode: TravelMode
    ) -> [String] {
        var queries: [String] = [currentLocation]

        let lowerCurrent = currentLocation.lowercased()
        switch travelMode {
        case .train, .bus:
            if !lowerCurrent.contains("station") && !lowerCurrent.contains("terminal") {
                queries.append("\(currentLocation) station")
            }
        case .flight:
            if !lowerCurrent.contains("airport") {
                queries.append("\(currentLocation) airport")
            }
        case .restaurant:
            if !["restaurant", "cafe", "bistro", "bar"].contains(where: { lowerCurrent.contains($0) }) {
                queries.append("\(currentLocation) restaurant")
            }
        case .hotel:
            if !lowerCurrent.contains("hotel") {
                queries.append("\(currentLocation) hotel")
            }
        case .activity, .document, .other:
            break
        }

        if let provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty {
            queries.append("\(currentLocation), \(provider)")
        }

        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            queries.append("\(currentLocation), \(title)")
        }

        if let rawContext {
            for phrase in likelyPlacePhrases(from: rawContext).prefix(4) {
                if phrase.range(of: currentLocation, options: .caseInsensitive) != nil || currentLocation.range(of: phrase, options: .caseInsensitive) != nil {
                    queries.append(phrase)
                } else {
                    queries.append("\(currentLocation), \(phrase)")
                }
            }
        }

        var seen: Set<String> = []
        return queries.filter {
            let normalized = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { return false }
            seen.insert(normalized)
            return true
        }
    }

    private func likelyPlacePhrases(from text: String) -> [String] {
        let pattern = "(?i)(?:from|to|at|in|near|station|airport|hotel|restaurant)\\s+([A-Z][A-Za-z0-9'&.,\\-\\s]{2,60})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        let matches = regex.matches(in: text, options: [], range: range)

        var phrases: [String] = []
        for match in matches {
            guard match.numberOfRanges > 1 else { continue }
            let phrase = nsText.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if phrase.count >= 3 {
                phrases.append(phrase)
            }
        }
        return phrases
    }

    private func normalizedSearchTokens(from text: String) -> Set<String> {
        let lowercased = text.lowercased()
        let cleaned = lowercased.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        let stopwords: Set<String> = ["the", "and", "for", "with", "from", "to", "at", "in", "on", "by", "of", "is", "a", "an"]
        return Set(cleaned.split(separator: " ").map(String.init).filter { $0.count >= 3 && !stopwords.contains($0) })
    }

    private func locationFieldText(_ placemark: CLPlacemark) -> String {
        [
            placemark.name,
            placemark.subThoroughfare,
            placemark.thoroughfare,
            placemark.locality,
            placemark.subLocality,
            placemark.administrativeArea,
            placemark.postalCode,
            placemark.country
        ]
        .compactMap { $0 }
        .joined(separator: " ")
    }

    private func compactLocationString(from placemark: CLPlacemark) -> String {
        var parts: [String] = []

        if let name = placemark.name, !name.isEmpty {
            parts.append(name)
        }
        if let locality = placemark.locality, !locality.isEmpty {
            parts.append(locality)
        }
        if let admin = placemark.administrativeArea, !admin.isEmpty {
            parts.append(admin)
        }
        if let country = placemark.country, !country.isEmpty {
            parts.append(country)
        }

        var seen: Set<String> = []
        let deduped = parts.filter {
            let key = $0.lowercased()
            guard !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }

        return deduped.joined(separator: ", ")
    }
    
    /// Checks if a new item is a duplicate of any existing items in the trip.
    /// Two items are considered duplicates if they share the same travel mode and
    /// have overlapping start times within a 30-minute window, and similar titles.
    func isDuplicate(_ newItem: ItineraryItem, existingItems: [ItineraryItem]) -> Bool {
        for existing in existingItems {
            // Same travel mode
            guard newItem.travelMode == existing.travelMode else { continue }
            
            // Start times within 30 minutes of each other
            let timeDiff = abs(newItem.startTime.timeIntervalSince(existing.startTime))
            guard timeDiff < 1800 else { continue } // 30 minutes
            
            // Similar titles (case-insensitive, check if either contains the other or high overlap)
            let newTitle = newItem.title.lowercased()
            let existingTitle = existing.title.lowercased()
            
            if newTitle == existingTitle
                || newTitle.contains(existingTitle)
                || existingTitle.contains(newTitle) {
                return true
            }
            
            // Same booking reference
            if let newRef = newItem.bookingReference, !newRef.isEmpty,
               let existingRef = existing.bookingReference, !existingRef.isEmpty,
               newRef.lowercased() == existingRef.lowercased() {
                return true
            }
            
            // Same location + same time window = likely duplicate
            let newLoc = newItem.locationName.lowercased()
            let existingLoc = existing.locationName.lowercased()
            if timeDiff < 300 && (newLoc == existingLoc || newLoc.contains(existingLoc) || existingLoc.contains(newLoc)) {
                return true
            }
        }
        return false
    }
    
    // MARK: - Public API

    /// Classify a fetched email as itinerary candidate, important non-itinerary, or irrelevant.
    func classifyEmailForSearch(emailText: String, tripStartDate: Date? = nil, tripEndDate: Date? = nil) async throws -> EmailTriageResult {
        let engine = UserDefaults.standard.string(forKey: "classificationEngine") ?? "Apple Intelligence"
        let contextText = buildContext(tripStartDate: tripStartDate, tripEndDate: tripEndDate)
        let cleanedText = preprocessEmailText(emailText, maxChars: 4000)

        if engine == "Cloud (OpenAI)" {
            return try await classifyWithOpenAI(text: cleanedText, contextText: contextText)
        } else if engine == "Apple Intelligence" {
            return try await classifyWithAppleIntelligence(text: cleanedText, contextText: contextText)
        }

        // Fallback path for local engines: use extraction-style relevance and infer importance.
        let dynamicPrompt = "\(baseSystemPrompt)\n\n\(contextText)"
        #if canImport(MLX)
        let parsed = try await parseWithLocalMLX(text: cleanedText, systemPrompt: dynamicPrompt, tripStartDate: tripStartDate)
        #else
        let parsed = try await parseWithOpenAI(text: cleanedText, systemPrompt: dynamicPrompt)
        #endif

        return EmailTriageResult(relevant: parsed.relevant, important: parsed.relevant && parsed.items.isEmpty)
    }
    
    /// Parse a single email. Returns (isRelevant, items).
    /// When the LLM determines the email is not travel-relevant, isRelevant is false and items is empty.
    func parse(emailText: String, tripStartDate: Date? = nil, tripEndDate: Date? = nil) async throws -> (relevant: Bool, items: [ItineraryItem]) {
        let engine = UserDefaults.standard.string(forKey: "extractionEngine") ?? "Cloud (OpenAI)"
        
        let contextText = buildContext(tripStartDate: tripStartDate, tripEndDate: tripEndDate)
        let dynamicPrompt = "\(baseSystemPrompt)\n\n\(contextText)"
        
        // Preprocess the email text for ALL engines
        let cleanedText = preprocessEmailText(emailText)
        
        print("[ItineraryParserService] Cleaned email text: \(cleanedText.count) chars (from \(emailText.count))")
        
        var result: ExtractionResult
        
        if engine == "Cloud (OpenAI)" {
            result = try await parseWithOpenAI(text: cleanedText, systemPrompt: dynamicPrompt)
        } else if engine == "Apple Intelligence" {
            result = try await parseWithAppleIntelligence(text: cleanedText, systemPrompt: dynamicPrompt)
        } else {
            #if canImport(MLX)
            result = try await parseWithLocalMLX(text: cleanedText, systemPrompt: dynamicPrompt, tripStartDate: tripStartDate)
            #else
            throw ParserError.missingEngine
            #endif
        }
        
        // If the LLM rejected the email, return early
        guard result.relevant else {
            return (relevant: false, items: [])
        }
        
        // Map to SwiftData objects (without context or trip initially)
        var items: [ItineraryItem] = []
        for item in result.items {
            let tentativeStart = parseExtractedDateString(item.startTimeString, gmtOffset: nil) ?? Date()
            let normalizedOffset: String?
            if let explicitOffset = standardizedGMTOffset(item.timeZoneGMTOffset) {
                normalizedOffset = explicitOffset
            } else {
                normalizedOffset = await inferGMTOffset(from: item.locationName ?? "", at: tentativeStart)
            }
            guard let start = parseExtractedDateString(item.startTimeString, gmtOffset: normalizedOffset) else {
                continue
            }
            let end = parseExtractedDateString(item.endTimeString, gmtOffset: normalizedOffset)
            
            let tMode = parsedTravelMode(from: item.travelMode)
            
            items.append(ItineraryItem(
                title: item.title ?? "Unknown Travel Event",
                startTime: start,
                endTime: end,
                timeZoneGMTOffset: normalizedOffset,
                locationName: item.locationName ?? "Unknown Location",
                bookingReference: item.bookingReference,
                alternativeReference: item.alternativeReference,
                provider: item.provider,
                notes: item.notes,
                costAmount: item.costAmount,
                costCurrencyCode: item.costCurrency,
                rawTextSource: emailText,
                travelMode: tMode
            ))
        }
        
        return (relevant: true, items: items)
    }
    
    // MARK: - OpenAI

    private func selectedOpenAIModel() -> String {
        let cloudModelSelection = UserDefaults.standard.string(forKey: "extractionCloudModelSelection")
            ?? UserDefaults.standard.string(forKey: "cloudModelSelection")
            ?? "Nano"
        switch cloudModelSelection {
        case "Mini": return "gpt-5-mini"
        case "SOTA": return "gpt-5.5"
        case "Nano": fallthrough
        default: return "gpt-5-nano"
        }
    }

    private func selectedClassificationOpenAIModel() -> String {
        let cloudModelSelection = UserDefaults.standard.string(forKey: "classificationCloudModelSelection")
            ?? UserDefaults.standard.string(forKey: "extractionCloudModelSelection")
            ?? UserDefaults.standard.string(forKey: "cloudModelSelection")
            ?? "Nano"
        switch cloudModelSelection {
        case "Mini": return "gpt-5-mini"
        case "SOTA": return "gpt-5.5"
        case "Nano": fallthrough
        default: return "gpt-5-nano"
        }
    }

    private func selectedLocalMLXModel() -> String {
        let configured = UserDefaults.standard.string(forKey: "localMLXModel")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let configured, !configured.isEmpty {
            return configured
        }
        return "mlx-community/Qwen3.5-4B-Instruct-4bit"
    }

    private func shouldPreferOnDeviceLocalMLX() -> Bool {
        if UserDefaults.standard.object(forKey: "localMLXOnDeviceEnabled") == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: "localMLXOnDeviceEnabled")
    }

    private func selectedLocalMLXBaseURL() -> URL {
        let configured = UserDefaults.standard.string(forKey: "localMLXServerURL")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = "http://127.0.0.1:5413"
        return URL(string: (configured?.isEmpty == false ? configured! : fallback)) ?? URL(string: fallback)!
    }

    private func classifyWithOpenAI(text: String, contextText: String) async throws -> EmailTriageResult {
        guard let apiKey = KeychainManager.shared.get(forKey: .openAIApiKey), !apiKey.isEmpty else {
            throw ParserError.invalidAPIKey
        }

        let modelString = selectedClassificationOpenAIModel()
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let schema: [String: Any] = [
            "type": "json_schema",
            "json_schema": [
                "name": "email_triage",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "relevant": ["type": "boolean"],
                        "important": ["type": "boolean"]
                    ],
                    "required": ["relevant", "important"],
                    "additionalProperties": false
                ]
            ]
        ]

        let triageSystemPrompt = openAITriagePromptTemplate
            .replacingOccurrences(of: "{CONTEXT}", with: contextText)

        let body: [String: Any] = [
            "model": modelString,
            "messages": [
                ["role": "system", "content": triageSystemPrompt],
                ["role": "user", "content": text]
            ],
            "response_format": schema
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ParserError.networkError("Invalid response")
        }

        if httpResponse.statusCode == 429 {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return try await classifyWithOpenAI(text: text, contextText: contextText)
        }

        guard httpResponse.statusCode == 200 else {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown Error"
            print("[OpenAI:Triage] Error (\(httpResponse.statusCode)): \(errorString)")
            throw ParserError.networkError("Status \(httpResponse.statusCode)")
        }

        struct OpenAIResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable {
                    let content: String?
                    let refusal: String?
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let openAIResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let choice = openAIResponse.choices.first else {
            throw ParserError.parsingError("No choices in response")
        }

        if choice.message.refusal != nil {
            return EmailTriageResult(relevant: false, important: false)
        }

        guard let contentString = choice.message.content,
              let contentData = contentString.data(using: .utf8) else {
            throw ParserError.parsingError("No content in response")
        }

        do {
            let triage = try JSONDecoder().decode(EmailTriageResult.self, from: contentData)
            if !triage.relevant {
                return EmailTriageResult(relevant: false, important: false)
            }
            return triage
        } catch {
            throw ParserError.parsingError("Failed to decode triage response: \(error.localizedDescription)")
        }
    }

    private func classifyWithAppleIntelligence(text: String, contextText: String) async throws -> EmailTriageResult {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, macCatalyst 26.0, *) {
            let session = LanguageModelSession()
            let truncatedText = String(text.prefix(1800))
            let prompt = appleTriagePromptTemplate
                .replacingOccurrences(of: "{CONTEXT}", with: contextText)
                .replacingOccurrences(of: "{EMAIL}", with: truncatedText)
                + "\n\n"
                + appleJSONEnforcementPrompt

            let response = try await session.respond(to: prompt)
            let contentString = response.content

            guard let jsonString = extractJSONObjectString(from: contentString) else {
                throw ParserError.parsingError("Apple Intelligence classification response was not JSON")
            }

            guard let contentData = jsonString.data(using: .utf8) else {
                throw ParserError.parsingError("Could not decode Apple Intelligence classification response")
            }

            let triage = try JSONDecoder().decode(EmailTriageResult.self, from: contentData)
            if !triage.relevant {
                return EmailTriageResult(relevant: false, important: false)
            }
            return triage
        }
        throw ParserError.missingEngine
        #else
        throw ParserError.missingEngine
        #endif
    }
    
    private func parseWithOpenAI(text: String, systemPrompt: String) async throws -> ExtractionResult {
        guard let apiKey = KeychainManager.shared.get(forKey: .openAIApiKey), !apiKey.isEmpty else {
            throw ParserError.invalidAPIKey
        }
        
        let modelString = selectedOpenAIModel()
        
        let url = URL(string: "https://api.openai.com/v1/chat/completions")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        
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
                                    "timeZoneGMTOffset": ["type": ["string", "null"], "description": "GMT offset string like +1 or +5:30"],
                                    "locationName": ["type": "string"],
                                    "provider": ["type": ["string", "null"]],
                                    "bookingReference": ["type": ["string", "null"]],
                                    "alternativeReference": ["type": ["string", "null"], "description": "Any secondary/additional confirmation, locator, or reservation number in the email"],
                                    "costAmount": ["type": ["number", "null"], "description": "Total native-currency amount for this itinerary item if present"],
                                    "costCurrency": ["type": ["string", "null"], "description": "ISO 4217 currency code for costAmount, e.g. USD, EUR"],
                                    "travelMode": [
                                        "type": "string",
                                        "enum": ["Flight", "Hotel", "Bus", "Train", "Activity", "Restaurant", "Document", "Other"]
                                    ],
                                    "notes": ["type": ["string", "null"]]
                                ],
                                "required": ["title", "startTime", "endTime", "timeZoneGMTOffset", "locationName", "provider", "bookingReference", "alternativeReference", "costAmount", "costCurrency", "travelMode", "notes"],
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
            "model": modelString,
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
        
        // Handle rate limiting with retry
        if httpResponse.statusCode == 429 {
            print("[OpenAI] Rate limited, waiting 2 seconds before retry...")
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return try await parseWithOpenAI(text: text, systemPrompt: systemPrompt)
        }
        
        guard httpResponse.statusCode == 200 else {
            let errorString = String(data: data, encoding: .utf8) ?? "Unknown Error"
            print("[OpenAI] Error (\(httpResponse.statusCode)): \(errorString)")
            throw ParserError.networkError("Status \(httpResponse.statusCode)")
        }
        
        struct OpenAIResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable {
                    let content: String?
                    let refusal: String?
                }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        
        let openAIResponse = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        guard let choice = openAIResponse.choices.first else {
            throw ParserError.parsingError("No choices in response")
        }
        
        // Check for refusal
        if let refusal = choice.message.refusal {
            print("[OpenAI] Model refused: \(refusal)")
            return ExtractionResult(relevant: false, items: [])
        }
        
        guard let contentString = choice.message.content else {
            throw ParserError.parsingError("No content in response")
        }
        
        print("[OpenAI] Response: \(contentString.prefix(200))...")
        
        if let contentData = contentString.data(using: .utf8) {
            do {
                let result = try JSONDecoder().decode(ExtractionResult.self, from: contentData)
                return result
            } catch {
                print("[OpenAI] JSON decode error: \(error)")
                // Try to extract just the items array as fallback
                struct LegacyResult: Codable { let items: [ExtractedItineraryItem] }
                if let legacyResult = try? JSONDecoder().decode(LegacyResult.self, from: contentData) {
                    return ExtractionResult(relevant: !legacyResult.items.isEmpty, items: legacyResult.items)
                }
                throw ParserError.parsingError("Failed to decode LLM response: \(error.localizedDescription)")
            }
        }
        
        throw ParserError.parsingError("Could not decode content string to data")
    }
    
    // MARK: - Apple Intelligence

    private func parseWithSwiftLM(text: String, systemPrompt: String) async throws -> ExtractionResult {
        let baseURL = selectedLocalMLXBaseURL()
        let endpoint = baseURL.appending(path: "v1/chat/completions")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 90
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")

        let schema: [String: Any] = [
            "type": "json_schema",
            "json_schema": [
                "name": "itinerary_extraction",
                "strict": true,
                "schema": [
                    "type": "object",
                    "properties": [
                        "relevant": ["type": "boolean"],
                        "items": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "title": ["type": "string"],
                                    "startTime": ["type": "string"],
                                    "endTime": ["type": ["string", "null"]],
                                    "timeZoneGMTOffset": ["type": ["string", "null"]],
                                    "locationName": ["type": "string"],
                                    "provider": ["type": ["string", "null"]],
                                    "bookingReference": ["type": ["string", "null"]],
                                    "alternativeReference": ["type": ["string", "null"]],
                                    "costAmount": ["type": ["number", "null"]],
                                    "costCurrency": ["type": ["string", "null"]],
                                    "travelMode": ["type": "string"],
                                    "notes": ["type": ["string", "null"]]
                                ],
                                "required": ["title", "startTime", "endTime", "timeZoneGMTOffset", "locationName", "provider", "bookingReference", "alternativeReference", "costAmount", "costCurrency", "travelMode", "notes"],
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
            "model": selectedLocalMLXModel(),
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": text]
            ],
            "response_format": schema
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ParserError.networkError("Invalid SwiftLM response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            throw ParserError.networkError("SwiftLM status \(httpResponse.statusCode): \(bodyString)")
        }

        struct LocalResponse: Codable {
            struct Choice: Codable {
                struct Message: Codable {
                    let content: String?
                }
                let message: Message
            }
            let choices: [Choice]
        }

        let decoded = try JSONDecoder().decode(LocalResponse.self, from: data)
        guard let contentString = decoded.choices.first?.message.content,
              let contentData = contentString.data(using: .utf8) else {
            throw ParserError.parsingError("SwiftLM returned no parseable content")
        }

        return try JSONDecoder().decode(ExtractionResult.self, from: contentData)
    }

    private func extractJSONObjectString(from text: String) -> String? {
        // Fast path: whole response is already valid JSON.
        if let fullData = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: fullData),
           JSONSerialization.isValidJSONObject(object),
           let normalizedData = try? JSONSerialization.data(withJSONObject: object),
           let normalized = String(data: normalizedData, encoding: .utf8) {
            return normalized
        }

        guard let start = text.firstIndex(of: "{") else { return nil }
        var depth = 0
        var inString = false
        var isEscaped = false

        var idx = start
        while idx < text.endIndex {
            let ch = text[idx]

            if inString {
                if isEscaped {
                    isEscaped = false
                } else if ch == "\\" {
                    isEscaped = true
                } else if ch == "\"" {
                    inString = false
                }
                idx = text.index(after: idx)
                continue
            }

            if ch == "\"" {
                inString = true
                idx = text.index(after: idx)
                continue
            }

            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[start...idx])
                }
            }

            idx = text.index(after: idx)
        }

        return nil
    }
    
    private func parseWithAppleIntelligence(text: String, systemPrompt: String) async throws -> ExtractionResult {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, macCatalyst 26.0, *) {
            print("[ItineraryParserService] Running Apple Intelligence on-device extraction...")
            
            // Reuse session across calls to preserve context efficiently
            let session: LanguageModelSession
            if let existing = appleIntelligenceSession as? LanguageModelSession {
                session = existing
            } else {
                session = LanguageModelSession()
                appleIntelligenceSession = session
            }
            
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
            
            // Hard cap at 1500 chars for Apple Intelligence (much smaller context window)
            let truncatedText = String(text.prefix(1500))
            
            let aiPrompt = "\(condensedSystemPrompt)\n\(contextLine)\n\nEMAIL:\n\(truncatedText)\n\n\(appleJSONEnforcementPrompt)"
            
            print("[AppleIntelligence] Prompt length: \(aiPrompt.count) chars")
            
            do {
                let response = try await session.respond(to: aiPrompt)
                let contentString = response.content
                
                guard let jsonString = extractJSONObjectString(from: contentString) else {
                    print("[AppleIntelligence] No JSON found in response, returning empty.")
                    return ExtractionResult(relevant: false, items: [])
                }

                guard let contentData = jsonString.data(using: .utf8) else {
                    throw ParserError.parsingError("Failed to decode extracted string to Data.")
                }
                
                let decoder = JSONDecoder()
                
                // Try to decode as ExtractionResult (with relevant field)
                do {
                    let result = try decoder.decode(ExtractionResult.self, from: contentData)
                    return result
                } catch {
                    print("[AppleIntelligence] ExtractionResult decode failed: \(error)")
                }
                
                // Fallback: decode as array (legacy format — assume relevant)
                do {
                    let array = try decoder.decode([ExtractedItineraryItem].self, from: contentData)
                    return ExtractionResult(relevant: !array.isEmpty, items: array)
                } catch {
                    print("[AppleIntelligence] Array fallback decode failed: \(error)")
                }
                
                // Fallback: object with items key but no relevant field
                struct LegacyResult: Codable { let items: [ExtractedItineraryItem] }
                do {
                    let obj = try decoder.decode(LegacyResult.self, from: contentData)
                    return ExtractionResult(relevant: !obj.items.isEmpty, items: obj.items)
                } catch {
                    print("[AppleIntelligence] LegacyResult decode failed: \(error)")
                }
                
                throw ParserError.parsingError("Failed to parse Apple Intelligence JSON structure. JSON: \(jsonString)")
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
    
    private func inferredTravelMode(from lowercasedText: String) -> TravelMode? {
        if lowercasedText.contains("restaurant") || lowercasedText.contains("dinner") || lowercasedText.contains("lunch") || lowercasedText.contains("breakfast") || lowercasedText.contains("meal") || lowercasedText.contains("dining") {
            return .restaurant
        }
        if lowercasedText.contains("hotel") || lowercasedText.contains("check-in") || lowercasedText.contains("airbnb") {
            return .hotel
        }
        if lowercasedText.contains("flight") || lowercasedText.contains("airline") || lowercasedText.contains("boarding") {
            return .flight
        }
        if lowercasedText.contains("train") || lowercasedText.contains("rail") {
            return .train
        }
        if lowercasedText.contains("bus") || lowercasedText.contains("coach") {
            return .bus
        }
        if lowercasedText.contains("reservation") || lowercasedText.contains("booking") || lowercasedText.contains("ticket") || lowercasedText.contains("event") {
            return .activity
        }
        return nil
    }

    private func parsedTravelMode(from rawValue: String?) -> TravelMode {
        guard let value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return .other
        }

        let lower = value.lowercased()

        if ["restaurant", "meal", "dining", "dinner", "lunch", "breakfast", "brunch", "food", "cafe", "café"].contains(where: { lower.contains($0) }) {
            return .restaurant
        }
        if lower.contains("flight") || lower.contains("airline") {
            return .flight
        }
        if lower.contains("hotel") || lower.contains("accommodation") || lower.contains("airbnb") {
            return .hotel
        }
        if lower.contains("train") || lower.contains("rail") {
            return .train
        }
        if lower.contains("bus") || lower.contains("coach") {
            return .bus
        }
        if lower.contains("document") || lower.contains("visa") || lower.contains("insurance") || lower.contains("passport") {
            return .document
        }
        if lower.contains("activity") || lower.contains("event") || lower.contains("tour") || lower.contains("ticket") {
            return .activity
        }

        return TravelMode.allCases.first(where: { $0.rawValue.lowercased() == lower }) ?? .other
    }

    private func firstDetectedDateRange(in text: String) -> (Date, Date?)? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else {
            return nil
        }

        let nsText = text as NSString
        let matches = detector.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        guard let first = matches.first, let date = first.date else {
            return nil
        }
        return (date, first.duration > 0 ? date.addingTimeInterval(first.duration) : nil)
    }

    private func extractGMTOffset(in text: String) -> String? {
        let pattern = "(?i)(?:gmt|utc)\\s*([+-]\\d{1,2}(?::?\\d{2})?)"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else {
            return nil
        }

        let raw = nsText.substring(with: match.range(at: 1))
        if raw.count > 3 && !raw.contains(":") {
            let sign = raw.prefix(1)
            let remaining = raw.dropFirst()
            if remaining.count == 4 {
                let hh = remaining.prefix(2)
                let mm = remaining.suffix(2)
                return standardizedGMTOffset("\(sign)\(hh):\(mm)")
            }
        }

        return standardizedGMTOffset(raw)
    }

    private func extractLikelyLocation(in text: String) -> String {
        let pattern = "(?i)(?:at|in|to)\\s+([A-Z][A-Za-z0-9,.\\-\\s]{2,80})"
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return "Unknown Location"
        }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        guard let match = regex.firstMatch(in: text, options: [], range: range), match.numberOfRanges > 1 else {
            return "Unknown Location"
        }

        let location = nsText.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        return location.isEmpty ? "Unknown Location" : location
    }

    private func heuristicLocalExtraction(from text: String, tripStartDate: Date?) -> ExtractionResult {
        let lower = text.lowercased()

        guard let inferredMode = inferredTravelMode(from: lower) else {
            return ExtractionResult(relevant: false, items: [])
        }

        let dateRange = firstDetectedDateRange(in: text)
        let offset = extractGMTOffset(in: text) ?? standardizedGMTOffset(
            gmtOffsetString(for: .current, at: tripStartDate ?? Date())
        )
        let location = extractLikelyLocation(in: text)

        let startDate = dateRange?.0 ?? (tripStartDate ?? Date())
        var endDate = dateRange?.1

        if inferredMode == .hotel {
            if endDate == nil {
                endDate = startDate.addingTimeInterval(20 * 3600)
            }
        } else if endDate == nil {
            endDate = startDate.addingTimeInterval(2 * 3600)
        }

        let item = ExtractedItineraryItem(
            title: titleForHeuristicItem(mode: inferredMode, location: location),
            startTime: startDate,
            endTime: endDate,
            timeZoneGMTOffset: offset,
            locationName: location,
            provider: nil,
            bookingReference: nil,
            alternativeReference: nil,
            travelMode: inferredMode.rawValue,
            notes: "Extracted with local MLX fallback parser",
            costAmount: nil,
            costCurrency: nil
        )

        return ExtractionResult(relevant: true, items: [item])
    }

    private func titleForHeuristicItem(mode: TravelMode, location: String) -> String {
        switch mode {
        case .hotel:
            return "Check-in: \(location)"
        case .flight:
            return "Flight to \(location)"
        case .train:
            return "Train to \(location)"
        case .bus:
            return "Bus to \(location)"
        case .activity:
            return "Activity at \(location)"
        case .restaurant:
            return "Meal at \(location)"
        case .document:
            return "Document: \(location)"
        case .other:
            return "Travel event: \(location)"
        }
    }

    // MARK: - MLX
    
    #if canImport(MLX)
    private func parseWithLocalMLX(text: String, systemPrompt: String, tripStartDate: Date?) async throws -> ExtractionResult {
        let localModelID = selectedLocalMLXModel()
        let hasOnDeviceModel = LocalMLXModelManager.shared.isModelDownloaded(modelID: localModelID)

        if shouldPreferOnDeviceLocalMLX(), hasOnDeviceModel {
            print("[ItineraryParserService] Running Local (MLX) on-device inference...")
            do {
                let response = try await LocalMLXModelManager.shared.generate(
                    modelID: localModelID,
                    prompt: text,
                    systemPrompt: systemPrompt
                )
                
                guard let jsonString = extractJSONObjectString(from: response),
                      let jsonData = jsonString.data(using: .utf8) else {
                    print("[ItineraryParserService] Local MLX response was not valid JSON, falling back to heuristic.")
                    return heuristicLocalExtraction(from: text, tripStartDate: tripStartDate)
                }
                
                return try JSONDecoder().decode(ExtractionResult.self, from: jsonData)
            } catch {
                print("[ItineraryParserService] Local MLX inference failed: \(error.localizedDescription). Falling back to heuristic.")
                return heuristicLocalExtraction(from: text, tripStartDate: tripStartDate)
            }
        }

        print("[ItineraryParserService] Running Local (MLX) via SwiftLM...")
        do {
            return try await parseWithSwiftLM(text: text, systemPrompt: systemPrompt)
        } catch {
            print("[ItineraryParserService] SwiftLM call failed, falling back to heuristic parser: \(error.localizedDescription)")
            return heuristicLocalExtraction(from: text, tripStartDate: tripStartDate)
        }
    }
    #else
    private func parseWithLocalMLX(text: String, systemPrompt: String, tripStartDate: Date?) async throws -> ExtractionResult {
        throw ParserError.missingEngine
    }
    #endif
}

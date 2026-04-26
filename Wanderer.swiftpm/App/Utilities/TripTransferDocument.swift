import Foundation
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let tripBuddyTripJSON = UTType(exportedAs: "com.roshanlodha.tripbuddy.trip+json", conformingTo: .json)
}

struct TripTransferPayload: Codable {
    struct ItemPayload: Codable {
        let id: UUID
        let title: String
        let startTime: Date
        let endTime: Date?
        let timeZoneGMTOffset: String?
        let locationName: String
        let bookingReference: String?
        let alternativeReference: String?
        let provider: String?
        let notes: String?
        let costAmount: Double?
        let costCurrencyCode: String?
        let rawTextSource: String?
        let travelMode: String
    }

    struct EmailPayload: Codable {
        let externalID: String
        let sender: String
        let subject: String
        let dateReceived: Date
        let snippet: String
        let bodyText: String
        let categoryRaw: String
        let extractionStatusRaw: String
        let extractionMessage: String?
        let extractedItemCount: Int
        let isVisibleInTripEmails: Bool
    }

    let version: Int
    let exportedAt: Date
    let tripName: String
    let startDate: Date
    let endDate: Date
    let ignoreEmailsBeforeDate: Date?
    let emailSearchStartDate: Date?
    let emailSearchEndDate: Date?
    let items: [ItemPayload]
    let emailSources: [EmailPayload]

    init(trip: Trip) {
        version = 2
        exportedAt = Date()
        tripName = trip.name
        startDate = trip.startDate
        endDate = trip.endDate
        ignoreEmailsBeforeDate = trip.ignoreEmailsBeforeDate
        emailSearchStartDate = trip.emailSearchStartDate
        emailSearchEndDate = trip.emailSearchEndDate
        items = trip.items.map { item in
            ItemPayload(
                id: item.id,
                title: item.title,
                startTime: item.startTime,
                endTime: item.endTime,
                timeZoneGMTOffset: item.timeZoneGMTOffset,
                locationName: item.locationName,
                bookingReference: item.bookingReference,
                alternativeReference: item.alternativeReference,
                provider: item.provider,
                notes: item.notes,
                costAmount: item.costAmount,
                costCurrencyCode: item.costCurrencyCode,
                rawTextSource: item.rawTextSource,
                travelMode: item.travelMode.rawValue
            )
        }
        emailSources = trip.emailSources.map { source in
            EmailPayload(
                externalID: source.externalID,
                sender: source.sender,
                subject: source.subject,
                dateReceived: source.dateReceived,
                snippet: source.snippet,
                bodyText: source.bodyText,
                categoryRaw: source.categoryRaw,
                extractionStatusRaw: source.extractionStatusRaw,
                extractionMessage: source.extractionMessage,
                extractedItemCount: source.extractedItemCount,
                isVisibleInTripEmails: source.isVisibleInTripEmails
            )
        }
    }
}

struct TripTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.tripBuddyTripJSON, .json] }
    static var writableContentTypes: [UTType] { [.tripBuddyTripJSON, .json] }

    var payload: TripTransferPayload

    init(payload: TripTransferPayload) {
        self.payload = payload
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        payload = try decoder.decode(TripTransferPayload.self, from: data)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        return .init(regularFileWithContents: data)
    }
}

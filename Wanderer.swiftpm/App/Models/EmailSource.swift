import Foundation
import SwiftData

@Model
final class EmailSource {
    var id: UUID = UUID()
    var externalID: String
    var sender: String
    var subject: String
    var dateReceived: Date
    var snippet: String
    var bodyText: String
    var categoryRaw: String
    var extractionStatusRaw: String
    var extractionMessage: String?
    var extractedItemCount: Int
    var isVisibleInTripEmails: Bool

    var trip: Trip?

    init(
        externalID: String,
        sender: String,
        subject: String,
        dateReceived: Date,
        snippet: String,
        bodyText: String,
        categoryRaw: String = "itinerary",
        extractionStatusRaw: String = "pending",
        extractionMessage: String? = nil,
        extractedItemCount: Int = 0,
        isVisibleInTripEmails: Bool = true
    ) {
        self.externalID = externalID
        self.sender = sender
        self.subject = subject
        self.dateReceived = dateReceived
        self.snippet = snippet
        self.bodyText = bodyText
        self.categoryRaw = categoryRaw
        self.extractionStatusRaw = extractionStatusRaw
        self.extractionMessage = extractionMessage
        self.extractedItemCount = extractedItemCount
        self.isVisibleInTripEmails = isVisibleInTripEmails
    }
}

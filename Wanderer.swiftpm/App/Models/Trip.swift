import Foundation
import SwiftData

@Model
final class Trip {
    var id: UUID = UUID()
    var name: String
    var startDate: Date
    var endDate: Date
    var ignoreEmailsBeforeDate: Date?
    var emailSearchStartDate: Date?
    var emailSearchEndDate: Date?
    
    @Relationship(deleteRule: .cascade, inverse: \ItineraryItem.trip)
    var items: [ItineraryItem] = []

    @Relationship(deleteRule: .cascade, inverse: \EmailSource.trip)
    var emailSources: [EmailSource] = []
    
    init(
        name: String,
        startDate: Date,
        endDate: Date,
        ignoreEmailsBeforeDate: Date? = nil,
        emailSearchStartDate: Date? = nil,
        emailSearchEndDate: Date? = nil
    ) {
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.ignoreEmailsBeforeDate = ignoreEmailsBeforeDate
        self.emailSearchStartDate = emailSearchStartDate
        self.emailSearchEndDate = emailSearchEndDate
    }
}

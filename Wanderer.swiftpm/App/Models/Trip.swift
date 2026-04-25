import Foundation
import SwiftData

@Model
final class Trip {
    var id: UUID = UUID()
    var name: String
    var startDate: Date
    var endDate: Date
    var emailSearchStartDate: Date?
    var emailSearchEndDate: Date?
    
    @Relationship(deleteRule: .cascade, inverse: \ItineraryItem.trip)
    var items: [ItineraryItem] = []
    
    init(
        name: String,
        startDate: Date,
        endDate: Date,
        emailSearchStartDate: Date? = nil,
        emailSearchEndDate: Date? = nil
    ) {
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        self.emailSearchStartDate = emailSearchStartDate
        self.emailSearchEndDate = emailSearchEndDate
    }
}

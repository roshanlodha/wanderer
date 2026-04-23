import Foundation
import SwiftData

@Model
final class Trip {
    var id: UUID = UUID()
    var name: String
    var startDate: Date
    var endDate: Date
    
    @Relationship(deleteRule: .cascade, inverse: \ItineraryItem.trip)
    var items: [ItineraryItem] = []
    
    init(name: String, startDate: Date, endDate: Date) {
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
    }
}

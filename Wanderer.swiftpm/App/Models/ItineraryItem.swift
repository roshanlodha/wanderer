import Foundation
import SwiftData

enum TravelMode: String, Codable, CaseIterable {
    case flight = "Flight"
    case hotel = "Hotel"
    case bus = "Bus"
    case train = "Train"
    case activity = "Activity"
    
    var icon: String {
        switch self {
        case .flight: return "airplane"
        case .hotel: return "bed.double.fill"
        case .bus: return "bus.fill"
        case .train: return "train.side.front.car"
        case .activity: return "ticket.fill"
        }
    }
}

@Model
final class ItineraryItem {
    var id: UUID = UUID()
    var title: String
    var startTime: Date
    var endTime: Date?
    var locationName: String
    var bookingReference: String?
    var provider: String?
    var notes: String?
    var rawTextSource: String?
    
    var travelMode: TravelMode
    
    var trip: Trip?
    var emailSource: EmailSource?
    
    init(title: String, startTime: Date, endTime: Date? = nil, locationName: String, bookingReference: String? = nil, provider: String? = nil, notes: String? = nil, rawTextSource: String? = nil, travelMode: TravelMode) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.locationName = locationName
        self.bookingReference = bookingReference
        self.provider = provider
        self.notes = notes
        self.rawTextSource = rawTextSource
        self.travelMode = travelMode
    }
}

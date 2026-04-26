import Foundation
import SwiftData

enum TravelMode: String, Codable, CaseIterable {
    case flight = "Flight"
    case hotel = "Hotel"
    case bus = "Bus"
    case train = "Train"
    case activity = "Activity"
    case restaurant = "Restaurant"
    case document = "Document"
    case other = "Other"
    
    var icon: String {
        switch self {
        case .flight: return "airplane"
        case .hotel: return "bed.double.fill"
        case .bus: return "bus.fill"
        case .train: return "train.side.front.car"
        case .activity: return "ticket.fill"
        case .restaurant: return "fork.knife.circle.fill"
        case .document: return "doc.text.fill"
        case .other: return "map.fill"
        }
    }
}

@Model
final class ItineraryItem {
    var id: UUID = UUID()
    var title: String
    var startTime: Date
    var endTime: Date?
    var timeZoneGMTOffset: String?
    var locationName: String
    var bookingReference: String?
    var alternativeReference: String?
    var provider: String?
    var notes: String?
    var rawTextSource: String?
    
    var travelMode: TravelMode
    
    var trip: Trip?
    var emailSource: EmailSource?
    
    init(title: String, startTime: Date, endTime: Date? = nil, timeZoneGMTOffset: String? = nil, locationName: String, bookingReference: String? = nil, alternativeReference: String? = nil, provider: String? = nil, notes: String? = nil, rawTextSource: String? = nil, travelMode: TravelMode) {
        self.title = title
        self.startTime = startTime
        self.endTime = endTime
        self.timeZoneGMTOffset = timeZoneGMTOffset
        self.locationName = locationName
        self.bookingReference = bookingReference
        self.alternativeReference = alternativeReference
        self.provider = provider
        self.notes = notes
        self.rawTextSource = rawTextSource
        self.travelMode = travelMode
    }
}

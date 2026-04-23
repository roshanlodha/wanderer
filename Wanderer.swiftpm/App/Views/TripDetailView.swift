import SwiftUI
import SwiftData

struct TripDetailView: View {
    let trip: Trip
    
    var sortedItems: [ItineraryItem] {
        trip.items.sorted { $0.startTime < $1.startTime }
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if trip.items.isEmpty {
                    ContentUnavailableView(
                        "No Itinerary",
                        systemImage: "calendar.badge.plus",
                        description: Text("Add items to your trip to see them here.")
                    )
                } else {
                    ForEach(sortedItems, id: \.id) { item in
                        TimelineItemView(item: item)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

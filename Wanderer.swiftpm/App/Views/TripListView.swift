import SwiftUI
import SwiftData

struct TripListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Trip.startDate, order: .forward) private var trips: [Trip]
    
    @Binding var selectedTrip: Trip?
    @State private var showSettings = false
    
    var body: some View {
        List(selection: $selectedTrip) {
            ForEach(trips) { trip in
                NavigationLink(value: trip) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(trip.name)
                            .font(.headline)
                        Text("\(trip.startDate, format: .dateTime.month().day()) - \(trip.endDate, format: .dateTime.month().day())")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
            .onDelete(perform: deleteTrips)
        }
        .navigationTitle("My Trips")
        .overlay {
            if trips.isEmpty {
                ContentUnavailableView(
                    "No Trips Yet",
                    systemImage: "airplane.departure",
                    description: Text("Add a sample trip to get started.")
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: { showSettings = true }) {
                    Label("Settings", systemImage: "gear")
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button(action: addSampleTrip) {
                    Label("Add Sample Trip", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
    
    private func addSampleTrip() {
        let newTrip = Trip(name: "Euro Trip", startDate: Date(), endDate: Date().addingTimeInterval(86400 * 14))
        
        let flight = ItineraryItem(
            title: "Flight to London",
            startTime: Date(),
            endTime: Date().addingTimeInterval(3600 * 8),
            locationName: "Heathrow Airport",
            bookingReference: "AIR123",
            travelMode: .flight
        )
        
        let train = ItineraryItem(
            title: "Eurostar to Paris",
            startTime: Date().addingTimeInterval(86400 * 4),
            endTime: Date().addingTimeInterval(86400 * 4 + 3600 * 2.5),
            locationName: "Gare du Nord",
            bookingReference: "EUR456",
            travelMode: .train
        )
        
        let hotel = ItineraryItem(
            title: "Le Meurice",
            startTime: Date().addingTimeInterval(86400 * 4 + 3600 * 4),
            endTime: Date().addingTimeInterval(86400 * 8),
            locationName: "228 Rue de Rivoli, Paris",
            bookingReference: "HOTEL789",
            travelMode: .hotel
        )
        
        newTrip.items.append(contentsOf: [flight, train, hotel])
        modelContext.insert(newTrip)
    }
    
    private func deleteTrips(offsets: IndexSet) {
        withAnimation {
            for index in offsets {
                let trip = trips[index]
                if selectedTrip == trip {
                    selectedTrip = nil
                }
                modelContext.delete(trip)
            }
        }
    }
}

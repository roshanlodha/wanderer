import SwiftUI
import SwiftData

struct TripListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Trip.startDate, order: .forward) private var trips: [Trip]
    
    @Binding var selectedTrip: Trip?
    @State private var showSettings = false
    @State private var showAddTrip = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
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
        .listStyle(horizontalSizeClass == .compact ? .insetGrouped : .sidebar)
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
            ToolbarItem {
                Button(action: { showSettings = true }) {
                    Label("Settings", systemImage: "gear")
                }
            }
            ToolbarItem {
                Button(action: { showAddTrip = true }) {
                    Label("Add Trip", systemImage: "plus")
                }
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showAddTrip) {
            AddTripView()
        }
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

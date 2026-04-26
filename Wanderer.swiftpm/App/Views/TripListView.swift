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
        Group {
            if horizontalSizeClass == .compact {
                tripList
                    .listStyle(.insetGrouped)
            } else {
                tripList
                    .listStyle(.sidebar)
            }
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
            AddTripView { createdTrip in
                selectedTrip = createdTrip
            }
        }
    }

    private var tripList: some View {
        Group {
            if horizontalSizeClass == .compact {
                List {
                    ForEach(trips) { trip in
                        Button {
                            selectedTrip = trip
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(trip.name)
                                    .font(.headline)
                                Text("\(trip.startDate, format: .dateTime.month().day()) - \(trip.endDate, format: .dateTime.month().day())")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                    }
                    .onDelete(perform: deleteTrips)
                }
            } else {
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
            }
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

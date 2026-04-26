import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTrip: Trip?
    @State private var showSettings = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    var body: some View {
        Group {
            if horizontalSizeClass == .compact {
                NavigationStack {
                    TripListView(selectedTrip: $selectedTrip)
                        .navigationDestination(for: Trip.self) { trip in
                            TripDetailView(trip: trip)
                        }
                }
            } else {
                NavigationSplitView {
                    TripListView(selectedTrip: $selectedTrip)
                } detail: {
                    if let trip = selectedTrip {
                        TripDetailView(trip: trip)
                    } else {
                        ContentUnavailableView("Select a Trip", systemImage: "map", description: Text("Choose a trip from the sidebar to view its itinerary."))
                    }
                }
                .navigationSplitViewStyle(.balanced)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

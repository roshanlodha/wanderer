import SwiftUI
import SwiftData

struct ContentView: View {
    @State private var selectedTrip: Trip?
    @State private var showSettings = false
    
    var body: some View {
        NavigationSplitView {
            TripListView(selectedTrip: $selectedTrip)
        } detail: {
            if let trip = selectedTrip {
                TripDetailView(trip: trip)
            } else {
                ContentUnavailableView("Select a Trip", systemImage: "map", description: Text("Choose a trip from the sidebar to view its itinerary."))
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
    }
}

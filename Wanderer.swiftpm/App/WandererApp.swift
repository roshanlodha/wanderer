import SwiftUI
import SwiftData

@main
struct WandererApp: App {
    @State private var authManager = AuthManager()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Trip.self,
            ItineraryItem.self,
            EmailSource.self
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    @Environment(\.scenePhase) private var scenePhase
    
    init() {
        BackgroundTaskManager.shared.registerBackgroundTasks()
    }

    var body: some Scene {
        WindowGroup {
            if authManager.isAuthenticated || authManager.isGuest {
                ContentView()
                    .environment(authManager)
            } else {
                LaunchView()
                    .environment(authManager)
            }
        }
        .modelContainer(sharedModelContainer)
        .onChange(of: scenePhase) { oldPhase, newPhase in
            if newPhase == .background {
                BackgroundTaskManager.shared.scheduleEmailFetch()
            }
        }
    }
}

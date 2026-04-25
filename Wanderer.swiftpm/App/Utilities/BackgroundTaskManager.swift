import Foundation
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    
    let emailFetchTaskIdentifier = "com.roshanlodha.Wanderer.fetchEmails"
    
    func registerBackgroundTasks() {
        #if os(iOS)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: emailFetchTaskIdentifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            self.handleEmailFetch(task: appRefreshTask)
        }
        #endif
    }
    
    func scheduleEmailFetch() {
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: emailFetchTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("[BackgroundTaskManager] Scheduled background email fetch.")
        } catch {
            print("[BackgroundTaskManager] Could not schedule: \(error)")
        }
        #endif
    }
    
    #if os(iOS)
    private func handleEmailFetch(task: BGAppRefreshTask) {
        // Schedule the next fetch immediately
        scheduleEmailFetch()
        
        let fetchTask = Task {
            let emails = await EmailFetchService.shared.fetchTravelEmails()
            print("[BackgroundTaskManager] Background fetch completed: \(emails.count) emails.")
            task.setTaskCompleted(success: true)
        }
        
        task.expirationHandler = {
            fetchTask.cancel()
            task.setTaskCompleted(success: false)
        }
    }
    #endif
}

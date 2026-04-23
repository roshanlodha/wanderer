import Foundation
#if canImport(BackgroundTasks)
import BackgroundTasks
#endif

class BackgroundTaskManager {
    static let shared = BackgroundTaskManager()
    
    let emailFetchTaskIdentifier = "com.wanderer.fetchEmails"
    
    func registerBackgroundTasks() {
        #if os(iOS) && canImport(BackgroundTasks)
        BGTaskScheduler.shared.register(forTaskWithIdentifier: emailFetchTaskIdentifier, using: nil) { task in
            guard let appRefreshTask = task as? BGAppRefreshTask else { return }
            self.handleEmailFetch(task: appRefreshTask)
        }
        #endif
    }
    
    #if os(iOS) && canImport(BackgroundTasks)
    func scheduleEmailFetch() {
        let request = BGAppRefreshTaskRequest(identifier: emailFetchTaskIdentifier)
        // Schedule next fetch in 15 minutes at the earliest
        request.earliestBeginDate = Date(timeIntervalSinceNow: 15 * 60)
        
        do {
            try BGTaskScheduler.shared.submit(request)
            print("Scheduled background task successfully.")
        } catch {
            print("Could not schedule background task: \(error)")
        }
    }
    
    private func handleEmailFetch(task: BGAppRefreshTask) {
        // Schedule the next fetch as soon as this one starts
        scheduleEmailFetch()
        
        // Setup an expiration handler to cleanly cancel if the system terminates the task early
        let fetchWorkItem = DispatchWorkItem {
            IMAPClientService.shared.fetchRecentTravelEmails { result in
                switch result {
                case .success(let emails):
                    print("Fetched \(emails.count) travel emails in background.")
                    task.setTaskCompleted(success: true)
                case .failure(let error):
                    print("Background fetch failed: \(error)")
                    task.setTaskCompleted(success: false)
                }
            }
        }
        
        task.expirationHandler = {
            fetchWorkItem.cancel()
            task.setTaskCompleted(success: false)
        }
        
        DispatchQueue.global(qos: .background).async(execute: fetchWorkItem)
    }
    #endif
}

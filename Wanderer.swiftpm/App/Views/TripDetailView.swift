import SwiftUI
import SwiftData

struct TripDetailView: View {
    let trip: Trip
    
    @Environment(\.modelContext) private var modelContext
    
    @State private var isSyncing = false
    @State private var fetchedEmails: [FetchedEmail] = []
    @State private var syncError: String?
    @State private var syncProgress: Double = 0
    @State private var syncTotal: Double = 0
    @State private var syncStatus: String = ""
    
    var groupedItems: [(Date, [ItineraryItem])] {
        let sorted = trip.items.sorted { $0.startTime < $1.startTime }
        let grouped = Dictionary(grouping: sorted) { Calendar.current.startOfDay(for: $0.startTime) }
        return grouped.sorted { $0.key < $1.key }
    }
    
    var hasConnectedEmail: Bool {
        OAuthService().isConnected(provider: .google) || OAuthService().isConnected(provider: .microsoft)
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                if trip.items.isEmpty && fetchedEmails.isEmpty {
                    ContentUnavailableView(
                        "No Itinerary",
                        systemImage: "calendar.badge.plus",
                        description: Text("Sync your email or add items manually.")
                    )
                } else {
                    // Itinerary items
                    ForEach(groupedItems, id: \.0) { date, items in
                        VStack(alignment: .leading, spacing: 16) {
                            Text(date, format: .dateTime.weekday(.wide).month().day())
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                            
                            ForEach(items, id: \.id) { item in
                                TimelineItemView(item: item)
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            modelContext.delete(item)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                    }
                    
                    if isSyncing {
                        VStack(spacing: 12) {
                            HStack {
                                Text("Syncing Emails...")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Spacer()
                                Text("\(Int(syncProgress)) / \(Int(syncTotal))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            
                            ProgressView(value: syncProgress, total: max(1, syncTotal))
                                .tint(.blue)
                            
                            Text(syncStatus)
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.05), radius: 5, x: 0, y: 2)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    
                    // Fetched email previews (before they're converted to itinerary items)
                    if !fetchedEmails.isEmpty {
                        Divider()
                            .padding(.vertical, 12)
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Emails Found")
                                .font(.headline)
                                .padding(.horizontal)
                            
                            ForEach(fetchedEmails) { email in
                                emailRow(email)
                            }
                        }
                    }
                }
            }
            .padding()
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if hasConnectedEmail {
                ToolbarItem {
                    Button {
                        syncEmailsForTrip()
                    } label: {
                        if isSyncing {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Sync Emails", systemImage: "envelope.arrow.triangle.branch")
                        }
                    }
                    .disabled(isSyncing)
                }
            }
        }
        .alert("Sync Error", isPresented: .constant(syncError != nil)) {
            Button("OK") { syncError = nil }
        } message: {
            Text(syncError ?? "")
        }
    }
    
    // MARK: - Email Row
    
    @ViewBuilder
    private func emailRow(_ email: FetchedEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(email.subject)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(2)
            
            HStack {
                Text(email.sender)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                Spacer()
                Text(email.date, format: .dateTime.month(.abbreviated).day())
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Text(email.bodyText.prefix(120) + "…")
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
        .padding(.horizontal)
    }
    
    // MARK: - Sync
    
    private func syncEmailsForTrip() {
        isSyncing = true
        syncError = nil
        
        Task {
            let emails = await EmailFetchService.shared.fetchTravelEmails()
            
            await MainActor.run {
                syncTotal = Double(emails.count)
                syncProgress = 0
            }
            
            // Extract itinerary items from fetched emails
            var newItems: [ItineraryItem] = []
            for (index, email) in emails.enumerated() {
                await MainActor.run {
                    syncStatus = "Parsing email \(index + 1) of \(emails.count)..."
                }
                do {
                    let extracted = try await ItineraryParserService.shared.parse(emailText: email.bodyText, tripStartDate: trip.startDate, tripEndDate: trip.endDate)
                    
                    for item in extracted {
                        // Check if the item's time overlaps with the trip's dates
                        // We add a 1 day buffer to account for time zones / overnight travel
                        let paddedStart = Calendar.current.date(byAdding: .day, value: -1, to: trip.startDate) ?? trip.startDate
                        let paddedEnd = Calendar.current.date(byAdding: .day, value: 1, to: trip.endDate) ?? trip.endDate
                        
                        if item.startTime <= paddedEnd && item.endTime >= paddedStart {
                            newItems.append(item)
                        }
                    }
                } catch {
                    print("Error parsing email \(email.subject): \(error)")
                }
                await MainActor.run {
                    syncProgress += 1
                }
            }
            
            await MainActor.run {
                fetchedEmails = emails
                for item in newItems {
                    trip.items.append(item)
                }
                isSyncing = false
                
                if emails.isEmpty {
                    syncError = "No travel emails found."
                } else if newItems.isEmpty {
                    syncError = "Found \(emails.count) travel emails, but no itinerary items within the dates of \(trip.name)."
                }
            }
        }
    }
}

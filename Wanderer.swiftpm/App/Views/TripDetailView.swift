import SwiftUI
import SwiftData

struct TripDetailView: View {
    let trip: Trip
    
    @State private var isSyncing = false
    @State private var fetchedEmails: [FetchedEmail] = []
    @State private var syncError: String?
    
    var sortedItems: [ItineraryItem] {
        trip.items.sorted { $0.startTime < $1.startTime }
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
                    ForEach(sortedItems, id: \.id) { item in
                        TimelineItemView(item: item)
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
                ToolbarItem(placement: .primaryAction) {
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
                .lineLimit(1)
            
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
            let searchStartDate = Calendar.current.date(byAdding: .year, value: -1, to: trip.startDate) ?? trip.startDate
            let emails = await EmailFetchService.shared.fetchTravelEmails(
                from: searchStartDate,
                to: trip.endDate
            )
            
            // Extract itinerary items from fetched emails
            var newItems: [ItineraryItem] = []
            for email in emails {
                do {
                    let extracted = try await ItineraryParserService.shared.parse(emailText: email.bodyText)
                    newItems.append(contentsOf: extracted)
                } catch {
                    print("Error parsing email \(email.subject): \(error)")
                }
            }
            
            await MainActor.run {
                fetchedEmails = emails
                for item in newItems {
                    trip.items.append(item)
                }
                isSyncing = false
                
                if emails.isEmpty {
                    syncError = "No travel emails found for \(trip.name) (\(trip.startDate.formatted(.dateTime.month().day())) – \(trip.endDate.formatted(.dateTime.month().day())))."
                } else if newItems.isEmpty {
                    syncError = "Found \(emails.count) emails, but could not extract any itinerary items."
                }
            }
        }
    }
}

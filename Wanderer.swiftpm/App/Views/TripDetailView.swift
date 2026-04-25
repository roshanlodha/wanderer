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
    @State private var showAddItemSheet = false
    
    // Manual add form state
    @State private var manualTitle = ""
    @State private var manualStartTime = Date()
    @State private var manualEndTime = Date()
    @State private var manualHasEndTime = false
    @State private var manualLocation = ""
    @State private var manualProvider = ""
    @State private var manualBookingRef = ""
    @State private var manualNotes = ""
    @State private var manualTravelMode: TravelMode = .activity
    
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
                if isSyncing {
                    syncProgressView
                }
                
                if !isSyncing && trip.items.isEmpty && fetchedEmails.isEmpty {
                    emptyStateView
                } else {
                    // Itinerary items
                    ForEach(groupedItems, id: \.0) { date, items in
                        VStack(alignment: .leading, spacing: 16) {
                            Text(date, format: .dateTime.weekday(.wide).month().day())
                                .font(.headline)
                                .foregroundColor(.secondary)
                                .padding(.top, 8)
                            
                            ForEach(items, id: \.id) { item in
                                HStack(alignment: .top) {
                                    TimelineItemView(item: item)
                                    
                                    Button {
                                        deleteItem(item)
                                    } label: {
                                        Image(systemName: "trash.circle.fill")
                                            .font(.title3)
                                            .foregroundColor(.red.opacity(0.6))
                                    }
                                    .buttonStyle(.plain)
                                    .padding(.top, 8)
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        deleteItem(item)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                    
                    // Fetched email previews
                    if !fetchedEmails.isEmpty {
                        emailsSection
                    }
                }
            }
            .padding()
        }
        .navigationTitle(trip.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showAddItemSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                }
                
                if hasConnectedEmail {
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
        .sheet(isPresented: $showAddItemSheet) {
            addItemSheet
        }
    }
    
    // MARK: - Sync Progress View
    
    private var syncProgressView: some View {
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
        .padding(.vertical, 32)
    }
    
    // MARK: - Empty State
    
    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("No Itinerary", systemImage: "calendar.badge.plus")
        } description: {
            Text("Sync your email or add items manually.")
        } actions: {
            HStack(spacing: 16) {
                if hasConnectedEmail {
                    Button(action: { syncEmailsForTrip() }) {
                        Label("Sync Email", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(action: { showAddItemSheet = true }) {
                    Label("Add Manually", systemImage: "plus")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 8)
        }
    }
    
    // MARK: - Emails Section
    
    private var emailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 12)
            
            HStack {
                Text("Emails Found")
                    .font(.headline)
                Spacer()
                Text("\(fetchedEmails.count)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.blue)
                    .clipShape(Capsule())
            }
            .padding(.horizontal)
            
            ForEach(fetchedEmails) { email in
                emailRow(email)
            }
        }
    }
    
    // MARK: - Email Row
    
    @ViewBuilder
    private func emailRow(_ email: FetchedEmail) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
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
                
                VStack(spacing: 8) {
                    // Reparse button
                    Button {
                        reparseEmail(email)
                    } label: {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    
                    // Remove email button
                    Button {
                        removeEmail(email)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.red)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.leading, 4)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
        .padding(.horizontal)
    }
    
    // MARK: - Add Item Sheet
    
    private var addItemSheet: some View {
        NavigationView {
            Form {
                Section("Event Details") {
                    TextField("Title", text: $manualTitle)
                    
                    Picker("Type", selection: $manualTravelMode) {
                        ForEach(TravelMode.allCases, id: \.self) { mode in
                            Label(mode.rawValue, systemImage: mode.icon)
                                .tag(mode)
                        }
                    }
                    
                    DatePicker("Start Time", selection: $manualStartTime)
                    
                    Toggle("Has End Time", isOn: $manualHasEndTime)
                    if manualHasEndTime {
                        DatePicker("End Time", selection: $manualEndTime)
                    }
                }
                
                Section("Location & Provider") {
                    TextField("Location", text: $manualLocation)
                    TextField("Provider (optional)", text: $manualProvider)
                    TextField("Booking Reference (optional)", text: $manualBookingRef)
                }
                
                Section("Notes") {
                    TextField("Notes (optional)", text: $manualNotes, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("Add Event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        showAddItemSheet = false
                        resetManualForm()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        addManualItem()
                    }
                    .disabled(manualTitle.isEmpty || manualLocation.isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
    }
    
    // MARK: - Actions
    
    private func deleteItem(_ item: ItineraryItem) {
        withAnimation {
            if let index = trip.items.firstIndex(where: { $0.id == item.id }) {
                trip.items.remove(at: index)
            }
            modelContext.delete(item)
        }
    }
    
    private func removeEmail(_ email: FetchedEmail) {
        withAnimation {
            fetchedEmails.removeAll { $0.id == email.id }
        }
    }
    
    private func reparseEmail(_ email: FetchedEmail) {
        Task {
            await MainActor.run {
                syncStatus = "Re-parsing: \(email.subject.prefix(40))..."
                isSyncing = true
                syncTotal = 1
                syncProgress = 0
            }
            
            do {
                let result = try await ItineraryParserService.shared.parse(
                    emailText: email.bodyText,
                    tripStartDate: trip.startDate,
                    tripEndDate: trip.endDate
                )
                
                await MainActor.run {
                    if result.relevant {
                        let filtered = filterItemsForTrip(result.items)
                        for item in filtered {
                            trip.items.append(item)
                        }
                        if filtered.isEmpty {
                            syncError = "Re-parsed email, but no items matched the trip dates."
                        }
                    } else {
                        syncError = "LLM determined this email has no actionable travel data."
                    }
                    syncProgress = 1
                    isSyncing = false
                }
            } catch {
                await MainActor.run {
                    syncError = "Re-parse failed: \(error.localizedDescription)"
                    isSyncing = false
                }
            }
        }
    }
    
    private func addManualItem() {
        let item = ItineraryItem(
            title: manualTitle,
            startTime: manualStartTime,
            endTime: manualHasEndTime ? manualEndTime : nil,
            locationName: manualLocation,
            bookingReference: manualBookingRef.isEmpty ? nil : manualBookingRef,
            provider: manualProvider.isEmpty ? nil : manualProvider,
            notes: manualNotes.isEmpty ? nil : manualNotes,
            rawTextSource: nil,
            travelMode: manualTravelMode
        )
        trip.items.append(item)
        showAddItemSheet = false
        resetManualForm()
    }
    
    private func resetManualForm() {
        manualTitle = ""
        manualStartTime = Date()
        manualEndTime = Date()
        manualHasEndTime = false
        manualLocation = ""
        manualProvider = ""
        manualBookingRef = ""
        manualNotes = ""
        manualTravelMode = .activity
    }
    
    // MARK: - Date Filtering Helper
    
    private func filterItemsForTrip(_ items: [ItineraryItem]) -> [ItineraryItem] {
        let startOfDay = Calendar.current.startOfDay(for: trip.startDate)
        let endOfDay = Calendar.current.startOfDay(for: trip.endDate).addingTimeInterval(86400 - 1)
        let paddedStart = Calendar.current.date(byAdding: .day, value: -2, to: startOfDay) ?? startOfDay
        let paddedEnd = Calendar.current.date(byAdding: .day, value: 2, to: endOfDay) ?? endOfDay
        
        return items.filter { item in
            let itemEndTime = item.endTime ?? item.startTime
            return item.startTime <= paddedEnd && itemEndTime >= paddedStart
        }
    }
    
    // MARK: - Sync
    
    private func syncEmailsForTrip() {
        isSyncing = true
        syncError = nil
        
        Task {
            await MainActor.run {
                syncStatus = "Fetching travel emails..."
                syncTotal = 1
                syncProgress = 0
            }
            
            let allEmails = await EmailFetchService.shared.fetchTravelEmails()
            // Filter out forwarded emails as requested by user
            let emails = allEmails.filter { 
                let lowerSubject = $0.subject.lowercased()
                return !lowerSubject.hasPrefix("fwd:") && !lowerSubject.hasPrefix("fw:")
            }
            
            await MainActor.run {
                fetchedEmails = emails
                syncStatus = "Identifying emails..."
                syncTotal = Double(max(1, emails.count))
                syncProgress = 0
            }
            
            // Parse each email and add items IMMEDIATELY as they're extracted
            var parseErrorCount = 0
            var totalExtractedBeforeFilter = 0
            var totalAddedItems = 0
            var rejectedByLLM = 0
            
            for (index, email) in emails.enumerated() {
                await MainActor.run {
                    syncStatus = "Parsing email \(index + 1) of \(emails.count)..."
                }
                do {
                    let result = try await ItineraryParserService.shared.parse(
                        emailText: email.bodyText,
                        tripStartDate: trip.startDate,
                        tripEndDate: trip.endDate
                    )
                    
                    if !result.relevant {
                        rejectedByLLM += 1
                        await MainActor.run {
                            syncProgress += 1
                        }
                        continue
                    }
                    
                    totalExtractedBeforeFilter += result.items.count
                    let filtered = filterItemsForTrip(result.items)
                    
                    // Add items to the trip IMMEDIATELY after each email is parsed
                    await MainActor.run {
                        for item in filtered {
                            trip.items.append(item)
                        }
                        totalAddedItems += filtered.count
                        syncProgress += 1
                    }
                } catch {
                    parseErrorCount += 1
                    print("Error parsing email \(email.subject): \(error)")
                    await MainActor.run {
                        syncProgress += 1
                    }
                }
            }
            
            await MainActor.run {
                isSyncing = false
                
                if emails.isEmpty {
                    syncError = "No travel emails found."
                } else if parseErrorCount == emails.count {
                    syncError = "Found \(emails.count) travel emails, but all failed to parse. Check your API key and extraction engine in Settings."
                } else if totalAddedItems == 0 && totalExtractedBeforeFilter > 0 {
                    syncError = "Extracted \(totalExtractedBeforeFilter) items from \(emails.count) emails, but none matched the dates of \(trip.name). Check your trip dates."
                } else if totalAddedItems == 0 {
                    var msg = "Found \(emails.count) travel emails, but no itinerary items could be extracted."
                    if rejectedByLLM > 0 {
                        msg += " \(rejectedByLLM) emails were determined to be non-travel content."
                    }
                    if parseErrorCount > 0 {
                        msg += " \(parseErrorCount) emails failed to parse."
                    }
                    syncError = msg
                }
            }
        }
    }
}

import SwiftUI
import SwiftData

struct TripDetailView: View {
    let trip: Trip
    
    @Environment(\.modelContext) private var modelContext
    
    // Sync state
    @State private var isFetchingEmails = false
    @State private var isExtracting = false
    @State private var itineraryEmails: [FetchedEmail] = []
    @State private var importantDocuments: [FetchedEmail] = []
    @State private var otherEmails: [FetchedEmail] = []
    @State private var emailStatuses: [String: FetchedEmail.ExtractionStatus] = [:]
    @State private var expandedEmailIds: Set<String> = []
    @State private var syncError: String?
    @State private var syncProgress: Double = 0
    @State private var syncTotal: Double = 0
    @State private var syncStatus: String = ""
    @State private var showAddItemSheet = false
    @State private var extractionTask: Task<Void, Never>?
    @State private var classificationTask: Task<Void, Never>?
    @State private var showTripSettingsSheet = false
    @State private var selectedTab: String = "itinerary"
    @AppStorage("classificationMode") private var classificationMode: String = "Smart"
    
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
    
    var isBusy: Bool {
        isFetchingEmails || isExtracting
    }

    var hasAnyEmailSections: Bool {
        !itineraryEmails.isEmpty || !importantDocuments.isEmpty || !otherEmails.isEmpty
    }
    
    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                // Progress indicator
                if isBusy {
                    syncProgressView
                }
                
                // Empty state
                if !isBusy && trip.items.isEmpty && !hasAnyEmailSections {
                    emptyStateView
                } else {
                    // Itinerary items
                    if !groupedItems.isEmpty {
                        itinerarySection
                    }
                    
                    // Fetched email previews
                    if hasAnyEmailSections {
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
                // Settings button
                Button {
                    showTripSettingsSheet = true
                } label: {
                    Image(systemName: "gear")
                        .foregroundColor(.gray)
                        .font(.title3)
                }
                
                // Green plus — manual add
                Button {
                    showAddItemSheet = true
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .foregroundColor(.green)
                        .font(.title3)
                }
                
                // Email sync button
                if hasConnectedEmail {
                    Button {
                        fetchEmails()
                    } label: {
                        if isFetchingEmails {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Sync Emails", systemImage: "envelope.arrow.triangle.branch")
                        }
                    }
                    .disabled(isBusy)
                }
            }
        }
        .alert("Sync Info", isPresented: .constant(syncError != nil)) {
            Button("OK") { syncError = nil }
        } message: {
            Text(syncError ?? "")
        }
        .sheet(isPresented: $showAddItemSheet) {
            addItemSheet
        }
        .sheet(isPresented: $showTripSettingsSheet) {
            tripSettingsSheet
        }
    }
    
    // MARK: - Itinerary Section
    
    private var itinerarySection: some View {
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
    }
    
    // MARK: - Sync Progress View
    
    private var syncProgressView: some View {
        VStack(spacing: 12) {
            HStack {
                Text(isFetchingEmails ? "Fetching Emails..." : "Extracting Itinerary...")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                if syncTotal > 0 {
                    Text("\(Int(syncProgress)) / \(Int(syncTotal))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if isFetchingEmails && classificationMode == "Smart" {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        stopClassification()
                    } label: {
                        Label("Stop Classification", systemImage: "stop.fill")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            } else if isExtracting {
                HStack {
                    Spacer()
                    Button(role: .destructive) {
                        stopParsing()
                    } label: {
                        Label("Stop Parsing", systemImage: "stop.fill")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            
            if syncTotal > 0 {
                ProgressView(value: syncProgress, total: max(1, syncTotal))
                    .tint(isExtracting ? .green : .blue)
            } else {
                ProgressView()
            }
            
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
        .padding(.vertical, 16)
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
                    Button(action: { fetchEmails() }) {
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
    
    // MARK: - Emails TabView
    
    private var emailsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
                .padding(.vertical, 12)
            
            TabView(selection: $selectedTab) {
                // Itinerary Email Tab
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Itinerary Emails")
                            .font(.headline)
                        Spacer()
                        Text("\(itineraryEmails.count)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.blue)
                            .clipShape(Capsule())
                        
                        Button {
                            extractAllEmails()
                        } label: {
                            Label("Extract All", systemImage: "sparkles")
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.green)
                        .controlSize(.small)
                        .disabled(isExtracting || itineraryEmails.isEmpty)
                    }
                    .padding(.horizontal)
                    
                    if itineraryEmails.isEmpty {
                        Text("No itinerary emails yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(itineraryEmails) { email in
                            emailRow(email)
                        }
                    }
                }
                .tag("itinerary")
                
                // Important Documents Tab
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Important Documents")
                            .font(.headline)
                        Spacer()
                        Text("\(importantDocuments.count)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.indigo)
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal)
                    
                    Text("Trip-related messages identified by AI that are not timeline events (ETAs, visas, insurance, etc.).")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    if importantDocuments.isEmpty {
                        Text("No important documents yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(importantDocuments) { email in
                            secondaryEmailRow(email, label: "Important", labelColor: .indigo) {
                                moveToItinerary(email: email)
                            }
                        }
                    }
                }
                .tag("important")
                
                // Other Tab
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Other")
                            .font(.headline)
                        Spacer()
                        Text("\(otherEmails.count)")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.gray)
                            .clipShape(Capsule())
                    }
                    .padding(.horizontal)
                    
                    Text("Emails rejected by AI as not travel-related or manually moved here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                    
                    if otherEmails.isEmpty {
                        Text("No emails in Other tab.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(otherEmails) { email in
                            secondaryEmailRow(email, label: "Rejected", labelColor: .gray) {
                                moveToItinerary(email: email)
                            }
                        }
                    }
                }
                .tag("other")
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .frame(minHeight: 300)
        }
    }

    // MARK: - Email Row
    
    @ViewBuilder
    private func emailRow(_ email: FetchedEmail) -> some View {
        let status = emailStatuses[email.id] ?? .pending
        let isExpanded = expandedEmailIds.contains(email.id)
        
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedEmailIds.remove(email.id)
                        } else {
                            expandedEmailIds.insert(email.id)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            statusIcon(for: status)
                            
                            Text(email.subject)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(isExpanded ? nil : 2)
                                .multilineTextAlignment(.leading)
                            
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        
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
                        
                        // Status text
                        statusText(for: status)
                    }
                }
                .buttonStyle(.plain)
                
                VStack(spacing: 8) {
                    // Extract / Reparse button
                    Button {
                        extractSingleEmail(email)
                    } label: {
                        Image(systemName: status == .pending ? "sparkles" : "arrow.clockwise.circle.fill")
                            .font(.title3)
                            .foregroundColor(.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(status == .extracting)
                    
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
            
            if isExpanded {
                Divider()
                    .padding(.vertical, 4)
                
                Text(email.bodyText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
        }
        .padding(12)
        .background(backgroundForStatus(status))
        .cornerRadius(10)
        .padding(.horizontal)
    }

    @ViewBuilder
    private func secondaryEmailRow(_ email: FetchedEmail, label: String, labelColor: Color, includeAction: @escaping () -> Void) -> some View {
        let isExpanded = expandedEmailIds.contains(email.id)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if isExpanded {
                            expandedEmailIds.remove(email.id)
                        } else {
                            expandedEmailIds.insert(email.id)
                        }
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(label)
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundColor(labelColor)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(labelColor.opacity(0.12))
                                .clipShape(Capsule())

                            Text(email.subject)
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .lineLimit(isExpanded ? nil : 2)
                                .multilineTextAlignment(.leading)
                        }

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
                    }
                }
                .buttonStyle(.plain)

                VStack(spacing: 8) {
                    Button {
                        includeAction()
                    } label: {
                        Label("Include in Itinerary", systemImage: "plus.circle.fill")
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

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

            if isExpanded {
                Divider()
                    .padding(.vertical, 4)

                Text(email.bodyText)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(10)
        .padding(.horizontal)
    }
    
    @ViewBuilder
    private func statusIcon(for status: FetchedEmail.ExtractionStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .font(.caption)
                .foregroundColor(.secondary)
        case .extracting:
            ProgressView()
                .controlSize(.mini)
        case .extracted:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
        case .irrelevant:
            Image(systemName: "minus.circle.fill")
                .font(.caption)
                .foregroundColor(.orange)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.caption)
                .foregroundColor(.red)
        }
    }
    
    @ViewBuilder
    private func statusText(for status: FetchedEmail.ExtractionStatus) -> some View {
        switch status {
        case .pending:
            EmptyView()
        case .extracting:
            Text("Extracting...")
                .font(.caption2)
                .foregroundColor(.blue)
        case .extracted(let count):
            Text("\(count) item\(count == 1 ? "" : "s") extracted")
                .font(.caption2)
                .foregroundColor(.green)
        case .irrelevant:
            Text("Not travel-related")
                .font(.caption2)
                .foregroundColor(.orange)
        case .failed(let msg):
            Text("Failed: \(msg)")
                .font(.caption2)
                .foregroundColor(.red)
                .lineLimit(1)
        }
    }
    
    private func backgroundForStatus(_ status: FetchedEmail.ExtractionStatus) -> Color {
        switch status {
        case .irrelevant: return Color.orange.opacity(0.05)
        case .failed: return Color.red.opacity(0.05)
        case .extracted: return Color.green.opacity(0.05)
        default: return Color(.secondarySystemGroupedBackground)
        }
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
                    Button {
                        showAddItemSheet = false
                        resetManualForm()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
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
    
    // MARK: - Trip Settings Sheet
    
    private var tripSettingsSheet: some View {
        NavigationView {
            Form {
                Section("Trip Details") {
                    TextField("Trip Name", text: Binding(
                        get: { trip.name },
                        set: { trip.name = $0 }
                    ))
                    DatePicker("Trip Start Date", selection: Binding(
                        get: { trip.startDate },
                        set: { trip.startDate = $0 }
                    ), displayedComponents: .date)
                    DatePicker("Trip End Date", selection: Binding(
                        get: { trip.endDate },
                        set: { trip.endDate = $0 }
                    ), displayedComponents: .date)
                }
                
                Section("Email Filtering") {
                    DatePicker("Ignore Emails Before", selection: Binding(
                        get: { trip.ignoreEmailsBeforeDate ?? computedIgnoreEmailsBeforeDate },
                        set: { trip.ignoreEmailsBeforeDate = $0 }
                    ), displayedComponents: .date)
                }
            }
            .navigationTitle("Trip Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showTripSettingsSheet = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        showTripSettingsSheet = false
                    }
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
            itineraryEmails.removeAll { $0.id == email.id }
            importantDocuments.removeAll { $0.id == email.id }
            emailStatuses.removeValue(forKey: email.id)
            expandedEmailIds.remove(email.id)
        }
    }

    private func moveToItinerary(email: FetchedEmail) {
        withAnimation {
            importantDocuments.removeAll { $0.id == email.id }
            otherEmails.removeAll { $0.id == email.id }

            if !itineraryEmails.contains(where: { $0.id == email.id }) {
                itineraryEmails.append(email)
                itineraryEmails.sort { $0.date > $1.date }
            }
            emailStatuses[email.id] = .pending
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

    private var computedIgnoreEmailsBeforeDate: Date {
        trip.ignoreEmailsBeforeDate ?? (Calendar.current.date(byAdding: .day, value: -7, to: trip.startDate) ?? trip.startDate)
    }

    private var effectiveIgnoreEmailsBefore: Date {
        Calendar.current.startOfDay(for: computedIgnoreEmailsBeforeDate)
    }

    private func isIgnoredByDateFilter(_ email: FetchedEmail) -> Bool {
        email.date < effectiveIgnoreEmailsBefore
    }

    private func isForwardedSubject(_ subject: String) -> Bool {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.range(of: "(?i)^(fw|fwd)\\s*[:\\-]", options: .regularExpression) != nil
    }

    private func applySecondPassItineraryFilter(_ emails: [FetchedEmail]) -> (kept: [FetchedEmail], removedCount: Int) {
        var removedCount = 0
        let kept = emails.filter { email in
            if isForwardedSubject(email.subject) {
                removedCount += 1
                return false
            }
            return true
        }
        return (kept, removedCount)
    }

    // MARK: - Phase 1: Fetch Emails (no extraction)
    
    private func fetchEmails() {
        isFetchingEmails = true
        syncError = nil
        
        classificationTask = Task {
            await MainActor.run {
                syncStatus = "Searching for travel emails..."
                syncTotal = 0
                syncProgress = 0
            }
            
            let emails = await EmailFetchService.shared.fetchTravelEmails()
            let secondPass = applySecondPassItineraryFilter(emails)
            let keptAfterDate = secondPass.kept.filter { !isIgnoredByDateFilter($0) }
            let ignoredBeforeCount = secondPass.kept.count - keptAfterDate.count

            if classificationMode == "Fast" {
                let itinerary = keptAfterDate.sorted { $0.date > $1.date }

                await MainActor.run {
                    itineraryEmails = itinerary
                    importantDocuments = []
                    emailStatuses = [:]
                    for email in itinerary {
                        emailStatuses[email.id] = .pending
                    }

                    if emails.isEmpty {
                        syncError = "No travel-related emails found. Try connecting an email account in Settings or check that you have travel confirmation emails."
                    } else {
                        var statusParts: [String] = []
                        statusParts.append("Mode: Fast")
                        statusParts.append("Itinerary: \(itinerary.count)")
                        if ignoredBeforeCount > 0 { statusParts.append("Ignored before date: \(ignoredBeforeCount)") }
                        if secondPass.removedCount > 0 { statusParts.append("FW removed: \(secondPass.removedCount)") }
                        syncStatus = statusParts.joined(separator: " · ")
                        print("[TripDetailView] Ignore emails before: \(effectiveIgnoreEmailsBefore)")
                    }
                    isFetchingEmails = false
                    classificationTask = nil
                }
                return
            }

            await MainActor.run {
                syncStatus = "Classifying \(keptAfterDate.count) emails with AI..."
                syncTotal = Double(keptAfterDate.count)
                syncProgress = 0
            }

            var itinerary: [FetchedEmail] = []
            var important: [FetchedEmail] = []
            var irrelevantCount = 0
            var wasClassificationCancelled = false

            for (index, email) in keptAfterDate.enumerated() {
                if Task.isCancelled {
                    wasClassificationCancelled = true
                    break
                }

                do {
                    let triage = try await ItineraryParserService.shared.classifyEmailForSearch(
                        emailText: "Subject: \(email.subject)\nFrom: \(email.sender)\n\n\(email.bodyText)",
                        tripStartDate: trip.startDate,
                        tripEndDate: trip.endDate
                    )

                    if triage.relevant {
                        if triage.important {
                            important.append(email)
                        } else {
                            itinerary.append(email)
                        }
                    } else {
                        irrelevantCount += 1
                    }
                } catch {
                    // Fail open to avoid losing potentially valid itinerary emails.
                    itinerary.append(email)
                    print("[TripDetailView] Triage failed for email '\(email.subject)': \(error.localizedDescription)")
                }

                await MainActor.run {
                    syncProgress = Double(index + 1)
                }
            }
            
            await MainActor.run {
                itineraryEmails = itinerary.sorted { $0.date > $1.date }
                importantDocuments = important.sorted { $0.date > $1.date }
                // Initialize all statuses to pending
                emailStatuses = [:]
                for email in itinerary {
                    emailStatuses[email.id] = .pending
                }
                isFetchingEmails = false
                classificationTask = nil
                
                if emails.isEmpty {
                    syncError = "No travel-related emails found. Try connecting an email account in Settings or check that you have travel confirmation emails."
                } else {
                    var statusParts: [String] = []
                    statusParts.append("Itinerary: \(itinerary.count)")
                    if !important.isEmpty { statusParts.append("Important: \(important.count)") }
                    if ignoredBeforeCount > 0 { statusParts.append("Ignored before date: \(ignoredBeforeCount)") }
                    if irrelevantCount > 0 { statusParts.append("Not trip-related: \(irrelevantCount)") }
                    if secondPass.removedCount > 0 { statusParts.append("FW removed: \(secondPass.removedCount)") }
                    if wasClassificationCancelled { statusParts.append("Classification stopped") }
                    syncStatus = statusParts.joined(separator: " · ")
                    print("[TripDetailView] Ignore emails before: \(effectiveIgnoreEmailsBefore)")
                }
            }
        }
    }
    
    // MARK: - Phase 2: Extract Itinerary from All Emails
    
    private func extractAllEmails() {
        let pendingEmails = itineraryEmails.filter { email in
            let status = emailStatuses[email.id] ?? .pending
            switch status {
            case .pending, .failed:
                return true
            default:
                return false
            }
        }
        
        guard !pendingEmails.isEmpty else {
            // Re-extract all if everything is already processed
            extractEmails(itineraryEmails)
            return
        }
        
        extractEmails(pendingEmails)
    }
    
    private func extractEmails(_ emails: [FetchedEmail]) {
        isExtracting = true
        syncError = nil

        extractionTask?.cancel()
        extractionTask = Task {
            await MainActor.run {
                syncStatus = "Extracting itinerary from \(emails.count) emails..."
                syncTotal = Double(emails.count)
                syncProgress = 0
            }
            
            var totalAdded = 0
            var totalRejected = 0
            var totalFailed = 0
            var totalDuplicates = 0
            var wasCancelled = false
            
            for (index, email) in emails.enumerated() {
                if Task.isCancelled {
                    wasCancelled = true
                    break
                }

                await MainActor.run {
                    syncStatus = "Extracting \(index + 1) of \(emails.count): \(email.subject.prefix(30))..."
                    emailStatuses[email.id] = .extracting
                }
                
                do {
                    let result = try await ItineraryParserService.shared.parse(
                        emailText: email.bodyText,
                        tripStartDate: trip.startDate,
                        tripEndDate: trip.endDate
                    )

                    if Task.isCancelled {
                        wasCancelled = true
                        break
                    }
                    
                    await MainActor.run {
                        if !result.relevant {
                            emailStatuses[email.id] = .irrelevant
                            totalRejected += 1
                        } else {
                            let filtered = filterItemsForTrip(result.items)
                            var addedForEmail = 0
                            
                            for item in filtered {
                                // Duplicate detection
                                if ItineraryParserService.shared.isDuplicate(item, existingItems: trip.items) {
                                    totalDuplicates += 1
                                    print("[Extraction] Skipped duplicate: \(item.title)")
                                } else {
                                    trip.items.append(item)
                                    addedForEmail += 1
                                    totalAdded += 1
                                }
                            }
                            
                            emailStatuses[email.id] = .extracted(addedForEmail)
                        }
                        syncProgress += 1
                    }
                } catch is CancellationError {
                    wasCancelled = true
                    break
                } catch {
                    totalFailed += 1
                    print("[Extraction] Error parsing email '\(email.subject)': \(error)")
                    await MainActor.run {
                        emailStatuses[email.id] = .failed(error.localizedDescription)
                        syncProgress += 1
                    }
                }
                
                // Small delay between API calls to avoid rate limiting
                if index < emails.count - 1 {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                }
            }
            
            // Auto-remove irrelevant emails from the list
            await MainActor.run {
                let irrelevantIds = emailStatuses.filter { $0.value == .irrelevant }.map { $0.key }
                otherEmails.append(contentsOf: itineraryEmails.filter { irrelevantIds.contains($0.id) })
                itineraryEmails.removeAll { irrelevantIds.contains($0.id) }
                for id in irrelevantIds {
                    emailStatuses.removeValue(forKey: id)
                }
                
                isExtracting = false
                extractionTask = nil
                
                // Build summary
                var parts: [String] = []
                if totalAdded > 0 { parts.append("✅ \(totalAdded) items added") }
                if totalDuplicates > 0 { parts.append("⏭ \(totalDuplicates) duplicates skipped") }
                if totalRejected > 0 { parts.append("🚫 \(totalRejected) non-travel emails removed") }
                if totalFailed > 0 { parts.append("❌ \(totalFailed) emails failed to parse") }
                if wasCancelled { parts.append("🛑 Parsing stopped") }
                
                if totalAdded == 0 && totalFailed > 0 {
                    syncError = parts.joined(separator: "\n") + "\n\nCheck your API key and extraction engine in Settings."
                } else if !parts.isEmpty {
                    syncStatus = parts.joined(separator: " · ")
                } else if wasCancelled {
                    syncStatus = "Parsing stopped."
                }
            }
        }
    }

    private func stopClassification() {
        classificationTask?.cancel()
        syncStatus = "Stopping classification..."
    }

    private func stopParsing() {
        extractionTask?.cancel()
        syncStatus = "Stopping parsing..."
    }
    
    // MARK: - Extract Single Email
    
    private func extractSingleEmail(_ email: FetchedEmail) {
        Task {
            await MainActor.run {
                emailStatuses[email.id] = .extracting
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
                        var addedCount = 0
                        
                        for item in filtered {
                            if !ItineraryParserService.shared.isDuplicate(item, existingItems: trip.items) {
                                trip.items.append(item)
                                addedCount += 1
                            }
                        }
                        
                        emailStatuses[email.id] = .extracted(addedCount)
                        
                        if addedCount == 0 && !filtered.isEmpty {
                            syncError = "Items were already in your itinerary (duplicates skipped)."
                        } else if filtered.isEmpty && !result.items.isEmpty {
                            syncError = "Extracted \(result.items.count) items, but none matched the trip dates."
                        }
                    } else {
                        emailStatuses[email.id] = .irrelevant
                        // Auto-remove irrelevant email
                        withAnimation {
                            itineraryEmails.removeAll { $0.id == email.id }
                            otherEmails.append(email)
                            emailStatuses.removeValue(forKey: email.id)
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    emailStatuses[email.id] = .failed(error.localizedDescription)
                }
            }
        }
    }
}

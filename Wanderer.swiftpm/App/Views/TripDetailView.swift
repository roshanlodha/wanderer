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
    @State private var selectedEmailTab: EmailTab = .itinerary
    @State private var selectedDetailTab: DetailTab = .overview
    @State private var editingItem: ItineraryItem?
    @State private var exportDocument: TripTransferDocument?
    @State private var showTripExporter = false
    @State private var showTripImporter = false
    @State private var isSourceEmailExpanded = false
    @AppStorage("classificationMode") private var classificationMode: String = "Smart"
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    
    // Manual add form state
    @State private var manualTitle = ""
    @State private var manualStartTime = Date()
    @State private var manualEndTime = Date()
    @State private var manualHasEndTime = false
    @State private var manualLocation = ""
    @State private var manualProvider = ""
    @State private var manualBookingRef = ""
    @State private var manualTimeZoneGMTOffset = ""
    @State private var manualNotes = ""
    @State private var manualTravelMode: TravelMode = .activity
    @State private var isInferringManualTimeZone = false
    @State private var isPatchingManualLocation = false
    @State private var hasReconciledTimeZones = false
    
    var groupedItems: [(Date, [ItineraryItem])] {
        let sorted = trip.items.sorted { $0.startTime < $1.startTime }
        let grouped = Dictionary(grouping: sorted) { Calendar.current.startOfDay(for: $0.startTime) }
        return grouped.sorted { $0.key < $1.key }
    }

    var estimatedCostByCurrency: [(currency: String, total: Double)] {
        let grouped = Dictionary(grouping: trip.items.compactMap { item -> (String, Double)? in
            guard let amount = item.costAmount,
                  let currency = item.costCurrencyCode?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !currency.isEmpty else {
                return nil
            }
            return (currency.uppercased(), amount)
        }, by: { $0.0 })

        return grouped
            .map { key, values in
                (currency: key, total: values.reduce(0) { $0 + $1.1 })
            }
            .sorted { $0.currency < $1.currency }
    }
    
    var hasConnectedEmail: Bool {
        OAuthService().isConnected(provider: .google)
    }
    
    var isBusy: Bool {
        isFetchingEmails || isExtracting
    }

    var hasAnyEmailSections: Bool {
        !itineraryEmails.isEmpty || !importantDocuments.isEmpty || !otherEmails.isEmpty
    }

    private var isCompactUI: Bool {
        horizontalSizeClass == .compact
    }

    private var sanitizedTripFileName: String {
        let cleaned = trip.name
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return cleaned.isEmpty ? "tripbuddy-trip" : cleaned
    }

    private enum EmailTab: String, CaseIterable {
        case itinerary
        case important
        case other

        var title: String {
            switch self {
            case .itinerary: return "Itinerary"
            case .important: return "Important"
            case .other: return "Other"
            }
        }

        var tint: Color {
            switch self {
            case .itinerary: return .blue
            case .important: return .indigo
            case .other: return .gray
            }
        }
    }

    private enum DetailTab: String, CaseIterable {
        case overview
        case calendar
        case map

        var title: String {
            switch self {
            case .overview: return "Overview"
            case .calendar: return "Calendar"
            case .map: return "Map"
            }
        }

        var systemImage: String {
            switch self {
            case .overview: return "list.bullet.rectangle"
            case .calendar: return "calendar"
            case .map: return "map"
            }
        }
    }

    private enum PersistedEmailCategory: String {
        case itinerary
        case important
        case other
    }
    
    private var secondaryGroupedBackgroundColor: Color {
        #if os(iOS)
        return Color(.secondarySystemGroupedBackground)
        #else
        return Color(NSColor.windowBackgroundColor)
        #endif
    }

    private var secondaryBackgroundColor: Color {
        #if os(iOS)
        return Color(.secondarySystemBackground)
        #else
        return Color(NSColor.controlBackgroundColor)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            detailTabPicker
                .padding(.bottom, 16)

            activeDetailContent
        }
        .padding()
        .navigationTitle(trip.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
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

                Menu {
                    Button {
                        exportDocument = TripTransferDocument(payload: TripTransferPayload(trip: trip))
                        showTripExporter = true
                    } label: {
                        Label("Export Trip JSON", systemImage: "square.and.arrow.up")
                    }

                    Button {
                        showTripImporter = true
                    } label: {
                        Label("Import Trip JSON", systemImage: "square.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "arrow.left.arrow.right.circle")
                        .foregroundColor(.orange)
                        .font(.title3)
                }
                
                // Green plus — manual add
                Button {
                    editingItem = nil
                    resetManualForm()
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
                            if isCompactUI {
                                Image(systemName: "envelope.arrow.triangle.branch")
                            } else {
                                Label("Sync Emails", systemImage: "envelope.arrow.triangle.branch")
                            }
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
        .fileExporter(
            isPresented: $showTripExporter,
            document: exportDocument,
            contentType: .tripBuddyTripJSON,
            defaultFilename: sanitizedTripFileName
        ) { result in
            if case .failure(let error) = result {
                syncError = "Trip export failed: \(error.localizedDescription)"
            }
        }
        .fileImporter(
            isPresented: $showTripImporter,
            allowedContentTypes: [.tripBuddyTripJSON, .json]
        ) { result in
            importTrip(from: result)
        }
        .onAppear {
            loadPersistedEmails()
            guard !hasReconciledTimeZones else { return }
            hasReconciledTimeZones = true
            Task {
                await reconcileTripTimeZones()
            }
        }
    }

    @ViewBuilder
    private var activeDetailContent: some View {
        switch selectedDetailTab {
        case .overview:
            ScrollView {
                overviewContent
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .calendar:
            WeeklyCalendarView(trip: trip) { item in
                prepareToEdit(item)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case .map:
            TripMapView(trip: trip) { item in
                prepareToEdit(item)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private var overviewContent: some View {
        VStack(spacing: 0) {
            if isBusy {
                syncProgressView
            }

            if !isBusy && trip.items.isEmpty && !hasAnyEmailSections {
                emptyStateView
            } else {
                if !estimatedCostByCurrency.isEmpty {
                    costEstimatorSection
                }

                if !groupedItems.isEmpty {
                    itinerarySection
                }

                if hasAnyEmailSections {
                    emailsSection
                }
            }
        }
    }

    private var detailTabPicker: some View {
        HStack(spacing: 8) {
            ForEach(DetailTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedDetailTab = tab
                    }
                } label: {
                    tabItemView(for: tab)
                }
                .font(.subheadline)
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .padding(.horizontal, 12)
                        .background(selectedDetailTab == tab ? Color.orange : secondaryGroupedBackgroundColor)
                        .foregroundColor(selectedDetailTab == tab ? .white : .primary)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal)
    }

    @ViewBuilder
    private func tabItemView(for tab: DetailTab) -> some View {
        if isCompactUI {
            Image(systemName: tab.systemImage)
        } else {
            Label(tab.title, systemImage: tab.systemImage)
        }
    }

    private func placeholderTab(title: String, systemImage: String, description: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        }
        .frame(maxWidth: .infinity, minHeight: 320)
    }
    
    // MARK: - Itinerary Section

    private var costEstimatorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Estimated Trip Cost", systemImage: "chart.bar.doc.horizontal")
                    .font(.headline)
                Spacer()
                Text("Native Currency")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(estimatedCostByCurrency, id: \.currency) { entry in
                HStack {
                    Text(entry.currency)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Spacer()
                    Text(entry.total, format: .number.precision(.fractionLength(2)))
                        .font(.subheadline)
                        .fontWeight(.medium)
                }
            }
        }
        .padding(12)
        .background(secondaryGroupedBackgroundColor)
        .cornerRadius(12)
        .padding(.horizontal)
        .padding(.bottom, 10)
    }
    
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

                        VStack(spacing: 10) {
                            Button {
                                prepareToEdit(item)
                            } label: {
                                Image(systemName: "pencil.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.blue.opacity(0.75))
                            }
                            .buttonStyle(.plain)

                            Button {
                                deleteItem(item)
                            } label: {
                                Image(systemName: "trash.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(.red.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 8)
                    }
                    .contextMenu {
                        Button {
                            prepareToEdit(item)
                        } label: {
                            Label("Edit", systemImage: "pencil")
                        }
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
            
            if syncTotal > 0 {
                ProgressView(value: syncProgress, total: max(1, syncTotal))
                    .tint(isExtracting ? .green : .blue)
            } else {
                ProgressView()
            }
            
            HStack(alignment: .center, spacing: 12) {
                Text(syncStatus)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isFetchingEmails && classificationMode == "Smart" {
                    Button(role: .destructive) {
                        stopClassification()
                    } label: {
                        Group {
                            if isCompactUI {
                                Image(systemName: "stop.fill")
                            } else {
                                Label("Stop Classification", systemImage: "stop.fill")
                            }
                        }
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } else if isExtracting {
                    Button(role: .destructive) {
                        stopParsing()
                    } label: {
                        Group {
                            if isCompactUI {
                                Image(systemName: "stop.fill")
                            } else {
                                Label("Stop Parsing", systemImage: "stop.fill")
                            }
                        }
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding()
        .background(secondaryGroupedBackgroundColor)
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
            
            HStack(spacing: 8) {
                tabButton(.itinerary, count: itineraryEmails.count)
                tabButton(.important, count: importantDocuments.count)
                tabButton(.other, count: otherEmails.count)
            }
            .padding(.horizontal)
            
            if selectedEmailTab == .itinerary {
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
                            Group {
                                if isCompactUI {
                                    Image(systemName: "sparkles")
                                } else {
                                    Label("Extract All", systemImage: "sparkles")
                                }
                            }
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
                .padding(.top, 8)
            }
            
            if selectedEmailTab == .important {
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
                            secondaryEmailRow(
                                email,
                                label: "Important",
                                labelColor: .indigo,
                                primaryAction: {
                                    moveToItinerary(email: email)
                                }
                            )
                        }
                    }
                }
                .padding(.top, 8)
            }
            
            if selectedEmailTab == .other {
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
                            secondaryEmailRow(
                                email,
                                label: "Rejected",
                                labelColor: .gray,
                                primaryActionTitle: "Include in Itinerary",
                                primaryActionSystemImage: "plus.circle.fill",
                                primaryAction: {
                                    moveToItinerary(email: email)
                                },
                                secondaryActionTitle: "Move to Important",
                                secondaryActionSystemImage: "arrow.up.circle.fill",
                                secondaryAction: {
                                    moveToImportant(email: email)
                                }
                            )
                        }
                    }
                }
                .padding(.top, 8)
            }
        }
    }

    private func tabButton(_ tab: EmailTab, count: Int) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) {
                selectedEmailTab = tab
            }
        } label: {
            HStack(spacing: 6) {
                Text(tab.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)

                Text("\(count)")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(selectedEmailTab == tab ? Color.white.opacity(0.22) : secondaryBackgroundColor)
                    .clipShape(Capsule())

            }
            .foregroundColor(selectedEmailTab == tab ? .white : .primary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(selectedEmailTab == tab ? tab.tint : secondaryGroupedBackgroundColor)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
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
    private func secondaryEmailRow(
        _ email: FetchedEmail,
        label: String,
        labelColor: Color,
        primaryActionTitle: String = "Include in Itinerary",
        primaryActionSystemImage: String = "plus.circle.fill",
        primaryAction: @escaping () -> Void,
        secondaryActionTitle: String? = nil,
        secondaryActionSystemImage: String? = nil,
        secondaryAction: (() -> Void)? = nil
    ) -> some View {
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
                        primaryAction()
                    } label: {
                        Group {
                            if isCompactUI {
                                Image(systemName: primaryActionSystemImage)
                            } else {
                                Label(primaryActionTitle, systemImage: primaryActionSystemImage)
                            }
                        }
                            .font(.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    if let secondaryActionTitle, let secondaryActionSystemImage, let secondaryAction {
                        Button {
                            secondaryAction()
                        } label: {
                            Group {
                                if isCompactUI {
                                    Image(systemName: secondaryActionSystemImage)
                                } else {
                                    Label(secondaryActionTitle, systemImage: secondaryActionSystemImage)
                                }
                            }
                                .font(.caption)
                                .fontWeight(.semibold)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

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
        .background(secondaryGroupedBackgroundColor)
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
        case .extracted(let count, let detail):
            Text(detail ?? "\(count) item\(count == 1 ? "" : "s") extracted")
                .font(.caption2)
                .foregroundColor(.green)
        case .irrelevant(let detail):
            Text(detail)
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
        default: 
            #if os(iOS)
            return Color(.secondarySystemGroupedBackground)
            #else
            return Color(NSColor.windowBackgroundColor)
            #endif
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
                    
                    DatePicker("Start Time", selection: Binding(
                        get: { manualStartTime },
                        set: { manualStartTime = $0 }
                    ))
                    
                    Toggle("Has End Time", isOn: $manualHasEndTime)
                    if manualHasEndTime {
                        DatePicker("End Time", selection: Binding(
                            get: { manualEndTime },
                            set: { manualEndTime = $0 }
                        ))
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("GMT Offset")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("e.g. +1, -5, +5:30", text: $manualTimeZoneGMTOffset)
                            .textFieldStyle(.roundedBorder)
                            #if os(iOS)
                            .textInputAutocapitalization(.never)
                            #endif
                            .autocorrectionDisabled()

                        Button {
                            inferManualTimeZone()
                        } label: {
                            if isInferringManualTimeZone {
                                ProgressView()
                            } else {
                                Label("Infer from Location", systemImage: "globe")
                            }
                        }
                        .disabled(isInferringManualTimeZone || manualLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Text("Stored as a standardized GMT offset like +1, -5, or +5:30.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }

                
                Section("Location & Provider") {
                    TextField("Location", text: $manualLocation)

                    Button {
                        patchManualLocation()
                    } label: {
                        if isPatchingManualLocation {
                            ProgressView()
                        } else {
                            Label("Patch Location", systemImage: "wand.and.stars")
                        }
                    }
                    .disabled(isPatchingManualLocation || manualLocation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    TextField("Provider (optional)", text: $manualProvider)
                    TextField("Booking Reference (optional)", text: $manualBookingRef)
                }

                Section("Notes") {
                    TextField("Notes (optional)", text: $manualNotes, axis: .vertical)
                        .lineLimit(3...6)
                }

                if editingItem != nil {
                    Section("Source Email") {
                        sourceEmailPreview
                    }
                }
            }
            .navigationTitle(editingItem == nil ? "Add Event" : "Edit Event")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        showAddItemSheet = false
                        editingItem = nil
                        resetManualForm()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(editingItem == nil ? "Add" : "Save") {
                        saveManualItem()
                    }
                    .disabled(manualTitle.isEmpty || manualLocation.isEmpty)
                    .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private var sourceEmailPreview: some View {
        if let emailSource = editingItem?.emailSource {
            VStack(alignment: .leading, spacing: 8) {
                Text(emailSource.subject)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(alignment: .firstTextBaseline) {
                    Text(emailSource.sender)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)

                    Spacer()

                    Text(emailSource.dateReceived, format: .dateTime.month(.abbreviated).day().year())
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Text(emailSource.snippet)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSourceEmailExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Source Email")
                        Image(systemName: isSourceEmailExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                if isSourceEmailExpanded {
                    if let rawSource = editingItem?.rawTextSource, !rawSource.isEmpty {
                        Text(rawSource)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(secondaryGroupedBackgroundColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .textSelection(.enabled)
                    } else {
                        Text(emailSource.bodyText)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .lineLimit(8)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(secondaryGroupedBackgroundColor)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .textSelection(.enabled)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else if let rawSource = editingItem?.rawTextSource, !rawSource.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSourceEmailExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text("Source Email")
                        Image(systemName: isSourceEmailExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)

                if isSourceEmailExpanded {
                    Text(rawSource)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(secondaryGroupedBackgroundColor)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .textSelection(.enabled)
                }
            }
        } else {
            Text("No source email is attached to this event.")
                .font(.caption)
                .foregroundColor(.secondary)
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
            otherEmails.removeAll { $0.id == email.id }
            emailStatuses.removeValue(forKey: email.id)
            expandedEmailIds.remove(email.id)
        }
        persistEmailCollections()
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
        persistEmailCollections()
    }

    private func moveToImportant(email: FetchedEmail) {
        withAnimation {
            itineraryEmails.removeAll { $0.id == email.id }
            otherEmails.removeAll { $0.id == email.id }

            if !importantDocuments.contains(where: { $0.id == email.id }) {
                importantDocuments.append(email)
                importantDocuments.sort { $0.date > $1.date }
            }
            selectedEmailTab = .important
        }
        persistEmailCollections()
    }

    private func appendEmailIfNeeded(_ email: FetchedEmail, to collection: inout [FetchedEmail]) {
        if !collection.contains(where: { $0.id == email.id }) {
            collection.append(email)
            collection.sort { $0.date > $1.date }
        }
    }

    private func importTrip(from result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let shouldStopAccess = url.startAccessingSecurityScopedResource()
            defer {
                if shouldStopAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let payload = try decoder.decode(TripTransferPayload.self, from: data)

            applyImportedTrip(payload)
            loadPersistedEmails()
            syncStatus = "Imported \(payload.items.count) items and \(payload.emailSources.count) emails from JSON."
            Task {
                await reconcileTripTimeZones()
            }
        } catch {
            syncError = "Trip import failed: \(error.localizedDescription)"
        }
    }

    private func applyImportedTrip(_ payload: TripTransferPayload) {
        trip.name = payload.tripName
        trip.startDate = payload.startDate
        trip.endDate = payload.endDate
        trip.ignoreEmailsBeforeDate = payload.ignoreEmailsBeforeDate
        trip.emailSearchStartDate = payload.emailSearchStartDate
        trip.emailSearchEndDate = payload.emailSearchEndDate

        for item in trip.items {
            modelContext.delete(item)
        }
        trip.items.removeAll()

        for source in trip.emailSources {
            modelContext.delete(source)
        }
        trip.emailSources.removeAll()

        for itemPayload in payload.items {
            let mode = TravelMode(rawValue: itemPayload.travelMode) ?? .other
            let item = ItineraryItem(
                title: itemPayload.title,
                startTime: itemPayload.startTime,
                endTime: itemPayload.endTime,
                timeZoneGMTOffset: itemPayload.timeZoneGMTOffset,
                locationName: itemPayload.locationName,
                bookingReference: itemPayload.bookingReference,
                alternativeReference: itemPayload.alternativeReference,
                provider: itemPayload.provider,
                notes: itemPayload.notes,
                costAmount: itemPayload.costAmount,
                costCurrencyCode: itemPayload.costCurrencyCode,
                rawTextSource: itemPayload.rawTextSource,
                travelMode: mode
            )
            item.id = itemPayload.id
            trip.items.append(item)
        }

        for sourcePayload in payload.emailSources {
            let source = EmailSource(
                externalID: sourcePayload.externalID,
                sender: sourcePayload.sender,
                subject: sourcePayload.subject,
                dateReceived: sourcePayload.dateReceived,
                snippet: sourcePayload.snippet,
                bodyText: sourcePayload.bodyText,
                categoryRaw: sourcePayload.categoryRaw,
                extractionStatusRaw: sourcePayload.extractionStatusRaw,
                extractionMessage: sourcePayload.extractionMessage,
                extractedItemCount: sourcePayload.extractedItemCount,
                isVisibleInTripEmails: sourcePayload.isVisibleInTripEmails
            )
            trip.emailSources.append(source)
        }
    }
    
    private func saveManualItem() {
        let timeZoneOffset = ItineraryParserService.shared.standardizedGMTOffset(manualTimeZoneGMTOffset)
        
        let startTime = fromLocalClockDate(manualStartTime, offset: timeZoneOffset)
        let endTime = manualHasEndTime ? fromLocalClockDate(manualEndTime, offset: timeZoneOffset) : nil

        if let editingItem {
            editingItem.title = manualTitle
            editingItem.startTime = startTime
            editingItem.endTime = endTime
            editingItem.timeZoneGMTOffset = timeZoneOffset
            editingItem.locationName = manualLocation
            editingItem.bookingReference = manualBookingRef.isEmpty ? nil : manualBookingRef
            editingItem.provider = manualProvider.isEmpty ? nil : manualProvider
            editingItem.notes = manualNotes.isEmpty ? nil : manualNotes
            editingItem.travelMode = manualTravelMode
        } else {
            let item = ItineraryItem(
                title: manualTitle,
                startTime: startTime,
                endTime: endTime,
                timeZoneGMTOffset: timeZoneOffset,
                locationName: manualLocation,
                bookingReference: manualBookingRef.isEmpty ? nil : manualBookingRef,
                provider: manualProvider.isEmpty ? nil : manualProvider,
                notes: manualNotes.isEmpty ? nil : manualNotes,
                rawTextSource: nil,
                travelMode: manualTravelMode
            )
            trip.items.append(item)
        }


        showAddItemSheet = false
        editingItem = nil
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
        manualTimeZoneGMTOffset = ""
        manualNotes = ""
        manualTravelMode = .activity
        isPatchingManualLocation = false
    }

    private func prepareToEdit(_ item: ItineraryItem) {
        editingItem = item
        manualTitle = item.title
        manualStartTime = toLocalClockDate(item.startTime, offset: item.timeZoneGMTOffset)
        manualEndTime = toLocalClockDate(item.endTime ?? item.startTime, offset: item.timeZoneGMTOffset)
        manualHasEndTime = item.endTime != nil

        manualLocation = item.locationName
        manualProvider = item.provider ?? ""
        manualBookingRef = item.bookingReference ?? ""
        manualTimeZoneGMTOffset = item.timeZoneGMTOffset ?? ""
        manualNotes = item.notes ?? ""
        manualTravelMode = item.travelMode
        isPatchingManualLocation = false
        showAddItemSheet = true
    }

    private func inferManualTimeZone() {
        let location = manualLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !location.isEmpty else { return }

        isInferringManualTimeZone = true
        Task {
            // Use the absolute date for inference
            let absoluteStart = fromLocalClockDate(manualStartTime, offset: manualTimeZoneGMTOffset)
            let inferred = await ItineraryParserService.shared.inferGMTOffset(from: location, at: absoluteStart)
            await MainActor.run {
                if let inferred {
                    manualTimeZoneGMTOffset = inferred
                }
                isInferringManualTimeZone = false
            }
        }
    }

    private func patchManualLocation() {
        let currentLocation = manualLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !currentLocation.isEmpty else { return }

        isPatchingManualLocation = true
        Task {
            let sourceContext = editingItem?.rawTextSource ?? editingItem?.emailSource?.bodyText
            let peerLocations = trip.items.map(\.locationName)

            let patched = await ItineraryParserService.shared.patchLocationName(
                currentLocation: currentLocation,
                title: manualTitle,
                provider: manualProvider,
                notes: manualNotes,
                rawContext: sourceContext,
                travelMode: manualTravelMode,
                peerLocations: peerLocations
            )

            await MainActor.run {
                if let patched {
                    manualLocation = patched
                }
                isPatchingManualLocation = false
            }
        }
    }

    // MARK: - Time Zone Helpers

    private func toLocalClockDate(_ date: Date, offset: String?) -> Date {
        guard let finalOffset = ItineraryParserService.shared.standardizedGMTOffset(offset),
              let tz = ItineraryParserService.shared.timeZone(fromGMTOffset: finalOffset) else {
            return date
        }
        let userOffsetString = ItineraryParserService.shared.gmtOffsetString(for: .current, at: date)
        return ItineraryParserService.shared.recalibratedDate(date, from: tz, to: userOffsetString) ?? date
    }

    private func fromLocalClockDate(_ date: Date, offset: String?) -> Date {
        guard let finalOffset = ItineraryParserService.shared.standardizedGMTOffset(offset),
              let tz = ItineraryParserService.shared.timeZone(fromGMTOffset: finalOffset) else {
            return date
        }
        return ItineraryParserService.shared.recalibratedDate(date, from: .current, to: finalOffset) ?? date
    }


    private func reconcileTripTimeZones() async {
        for item in trip.items {
            if Task.isCancelled { return }

            let existingOffset = ItineraryParserService.shared.standardizedGMTOffset(item.timeZoneGMTOffset)
            let inferredOffset: String?
            if let existingOffset {
                inferredOffset = existingOffset
            } else {
                inferredOffset = await ItineraryParserService.shared.inferGMTOffset(from: item.locationName, at: item.startTime)
            }
            guard let finalOffset = inferredOffset else { continue }

            await MainActor.run {
                if item.timeZoneGMTOffset == nil, item.rawTextSource != nil {
                    if let recalibratedStart = ItineraryParserService.shared.recalibratedDate(item.startTime, from: .current, to: finalOffset) {
                        item.startTime = recalibratedStart
                    }

                    if let endTime = item.endTime,
                       let recalibratedEnd = ItineraryParserService.shared.recalibratedDate(endTime, from: .current, to: finalOffset) {
                        item.endTime = recalibratedEnd
                    }
                }

                item.timeZoneGMTOffset = finalOffset
            }
        }
    }

    private func loadPersistedEmails() {
        let visibleSources = trip.emailSources
            .filter(\.isVisibleInTripEmails)
            .sorted { $0.dateReceived > $1.dateReceived }

        itineraryEmails = visibleSources
            .filter { $0.categoryRaw == PersistedEmailCategory.itinerary.rawValue }
            .map(FetchedEmail.init(source:))
        importantDocuments = visibleSources
            .filter { $0.categoryRaw == PersistedEmailCategory.important.rawValue }
            .map(FetchedEmail.init(source:))
        otherEmails = visibleSources
            .filter { $0.categoryRaw == PersistedEmailCategory.other.rawValue }
            .map(FetchedEmail.init(source:))

        emailStatuses = Dictionary(
            uniqueKeysWithValues: visibleSources.map { source in
                (source.externalID, extractionStatus(from: source))
            }
        )
    }

    private func extractionStatus(from source: EmailSource) -> FetchedEmail.ExtractionStatus {
        switch source.extractionStatusRaw {
        case "extracting":
            return .extracting
        case "extracted":
            return .extracted(source.extractedItemCount, source.extractionMessage)
        case "irrelevant":
            return .irrelevant(source.extractionMessage ?? "Not trip-related")
        case "failed":
            return .failed(source.extractionMessage ?? "Unknown error")
        default:
            return .pending
        }
    }

    private func persistEmailCollections() {
        for source in trip.emailSources {
            source.isVisibleInTripEmails = false
        }

        for email in itineraryEmails {
            let status = emailStatuses[email.id] ?? .pending
            let source = upsertEmailSource(for: email, category: .itinerary, status: status)
            source.isVisibleInTripEmails = true
        }

        for email in importantDocuments {
            let status = emailStatuses[email.id] ?? .pending
            let source = upsertEmailSource(for: email, category: .important, status: status)
            source.isVisibleInTripEmails = true
        }

        for email in otherEmails {
            let fallbackStatus: FetchedEmail.ExtractionStatus = emailStatuses[email.id] ?? .irrelevant("Not trip-related or manually moved")
            let source = upsertEmailSource(for: email, category: .other, status: fallbackStatus)
            source.isVisibleInTripEmails = true
        }
    }

    @discardableResult
    private func upsertEmailSource(
        for email: FetchedEmail,
        category: PersistedEmailCategory,
        status: FetchedEmail.ExtractionStatus
    ) -> EmailSource {
        let source = trip.emailSources.first(where: { $0.externalID == email.id }) ?? {
            let source = EmailSource(
                externalID: email.id,
                sender: email.sender,
                subject: email.subject,
                dateReceived: email.date,
                snippet: String(email.bodyText.prefix(280)),
                bodyText: email.bodyText
            )
            trip.emailSources.append(source)
            return source
        }()

        source.sender = email.sender
        source.subject = email.subject
        source.dateReceived = email.date
        source.snippet = String(email.bodyText.prefix(280))
        source.bodyText = email.bodyText
        source.categoryRaw = category.rawValue

        switch status {
        case .pending:
            source.extractionStatusRaw = "pending"
            source.extractionMessage = nil
            source.extractedItemCount = 0
        case .extracting:
            source.extractionStatusRaw = "extracting"
            source.extractionMessage = "Extracting..."
            source.extractedItemCount = 0
        case .extracted(let count, let message):
            source.extractionStatusRaw = "extracted"
            source.extractionMessage = message
            source.extractedItemCount = count
        case .irrelevant(let message):
            source.extractionStatusRaw = "irrelevant"
            source.extractionMessage = message
            source.extractedItemCount = 0
        case .failed(let message):
            source.extractionStatusRaw = "failed"
            source.extractionMessage = message
            source.extractedItemCount = 0
        }

        return source
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

    private func isHardFilteredSubject(_ subject: String) -> Bool {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Filter out forwarded emails: "FW:", "Fw:", etc.
        if trimmed.range(of: "(?i)^(fw|fwd)\\s*[:\\-]", options: .regularExpression) != nil {
            return true
        }
        
        // Filter out event acceptance emails
        if trimmed.range(of: "(?i)event\\s+accepted", options: .regularExpression) != nil {
            return true
        }
        
        return false
    }

    private func applySecondPassItineraryFilter(_ emails: [FetchedEmail]) -> (kept: [FetchedEmail], removedCount: Int) {
        var removedCount = 0
        let kept = emails.filter { email in
            if isHardFilteredSubject(email.subject) {
                removedCount += 1
                return false
            }
            return true
        }
        return (kept, removedCount)
    }

    private func finalStatus(
        for result: (relevant: Bool, items: [ItineraryItem]),
        filteredItems: [ItineraryItem],
        addedCount: Int,
        duplicateCount: Int
    ) -> FetchedEmail.ExtractionStatus {
        if !result.relevant {
            return .irrelevant("Not trip-related for this trip")
        }

        if result.items.isEmpty {
            return .extracted(0, "No itinerary details found")
        }

        if filteredItems.isEmpty {
            return .extracted(0, "This booking is outside the trip window")
        }

        if addedCount == 0 && duplicateCount > 0 {
            return .extracted(0, "Already in itinerary")
        }

        if addedCount > 0 && duplicateCount > 0 {
            return .extracted(addedCount, "\(addedCount) item\(addedCount == 1 ? "" : "s") extracted, \(duplicateCount) duplicate\(duplicateCount == 1 ? "" : "s") skipped")
        }

        return .extracted(addedCount, nil)
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
                    otherEmails = []
                    emailStatuses = [:]
                    for email in itinerary {
                        emailStatuses[email.id] = .pending
                    }
                    persistEmailCollections()

                    if emails.isEmpty {
                        syncError = "If you believe this is an error, please reconnect to your email in settings."
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
            var other: [FetchedEmail] = []
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
                        other.append(email)
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
                otherEmails = other.sorted { $0.date > $1.date }
                // Initialize all statuses to pending
                emailStatuses = [:]
                for email in itinerary {
                    emailStatuses[email.id] = .pending
                }
                for email in other {
                    emailStatuses[email.id] = .irrelevant("Not trip-related for this trip")
                }
                persistEmailCollections()
                isFetchingEmails = false
                classificationTask = nil
                
                if emails.isEmpty {
                    syncError = "If you believe this is an error, please reconnect to your email in settings."
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
                    persistEmailCollections()
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
                            emailStatuses[email.id] = .irrelevant("Not trip-related for this trip")
                            totalRejected += 1
                        } else {
                            let filtered = filterItemsForTrip(result.items)
                            var addedForEmail = 0
                            var duplicatesForEmail = 0
                            let source = upsertEmailSource(for: email, category: .itinerary, status: .extracting)

                            for item in filtered {
                                // Duplicate detection
                                if ItineraryParserService.shared.isDuplicate(item, existingItems: trip.items) {
                                    totalDuplicates += 1
                                    duplicatesForEmail += 1
                                    print("[Extraction] Skipped duplicate: \(item.title)")
                                } else {
                                    item.emailSource = source
                                    trip.items.append(item)
                                    addedForEmail += 1
                                    totalAdded += 1
                                }
                            }

                            emailStatuses[email.id] = finalStatus(
                                for: result,
                                filteredItems: filtered,
                                addedCount: addedForEmail,
                                duplicateCount: duplicatesForEmail
                            )
                        }
                        syncProgress += 1
                        persistEmailCollections()
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
                        persistEmailCollections()
                    }
                }
                
                // Small delay between API calls to avoid rate limiting
                if index < emails.count - 1 {
                    try? await Task.sleep(nanoseconds: 300_000_000) // 300ms
                }
            }
            
            // Auto-remove irrelevant emails from the list
            await MainActor.run {
                let irrelevantIds = emailStatuses.compactMap { id, status -> String? in
                    if case .irrelevant = status {
                        return id
                    }
                    return nil
                }
                for email in itineraryEmails where irrelevantIds.contains(email.id) {
                    appendEmailIfNeeded(email, to: &otherEmails)
                }
                itineraryEmails.removeAll { irrelevantIds.contains($0.id) }
                
                isExtracting = false
                extractionTask = nil
                persistEmailCollections()
                
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
                persistEmailCollections()
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
                        var duplicateCount = 0
                        let source = upsertEmailSource(for: email, category: .itinerary, status: .extracting)

                        for item in filtered {
                            if !ItineraryParserService.shared.isDuplicate(item, existingItems: trip.items) {
                                item.emailSource = source
                                trip.items.append(item)
                                addedCount += 1
                            } else {
                                duplicateCount += 1
                            }
                        }
                        
                        emailStatuses[email.id] = finalStatus(
                            for: result,
                            filteredItems: filtered,
                            addedCount: addedCount,
                            duplicateCount: duplicateCount
                        )
                        persistEmailCollections()
                        
                        if addedCount == 0 && duplicateCount > 0 {
                            syncError = "Items were already in your itinerary (duplicates skipped)."
                        } else if filtered.isEmpty && !result.items.isEmpty {
                            syncError = "Extracted \(result.items.count) items, but none matched the trip dates."
                        }
                    } else {
                        emailStatuses[email.id] = .irrelevant("Not trip-related for this trip")
                        // Auto-remove irrelevant email
                        withAnimation {
                            itineraryEmails.removeAll { $0.id == email.id }
                            appendEmailIfNeeded(email, to: &otherEmails)
                        }
                        persistEmailCollections()
                    }
                }
            } catch {
                await MainActor.run {
                    emailStatuses[email.id] = .failed(error.localizedDescription)
                    persistEmailCollections()
                }
            }
        }
    }
}

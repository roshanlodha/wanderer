import SwiftUI
import SwiftData

struct AddTripView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date().addingTimeInterval(86400 * 7)
    @State private var emailSearchStartDate: Date?
    @State private var emailSearchEndDate: Date?
    
    var computedEmailSearchStartDate: Date {
        emailSearchStartDate ?? (Calendar.current.date(byAdding: .day, value: -7, to: startDate) ?? startDate)
    }
    var computedEmailSearchEndDate: Date {
        emailSearchEndDate ?? (Calendar.current.date(byAdding: .day, value: 7, to: endDate) ?? endDate)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Trip Name", text: $name)
                DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                DatePicker("End Date", selection: $endDate, in: startDate..., displayedComponents: .date)

                Section("Email Search Date Range") {
                    DatePicker("Search Start", selection: Binding(
                        get: { emailSearchStartDate ?? computedEmailSearchStartDate },
                        set: { emailSearchStartDate = $0 }
                    ), displayedComponents: .date)
                    DatePicker("Search End", selection: Binding(
                        get: { emailSearchEndDate ?? computedEmailSearchEndDate },
                        set: { emailSearchEndDate = $0 }
                    ), in: (emailSearchStartDate ?? computedEmailSearchStartDate)..., displayedComponents: .date)
                }
            }
            .onChange(of: startDate) { _, newValue in
                if let current = emailSearchStartDate, current > newValue {
                    emailSearchStartDate = newValue
                }
            }
            .onChange(of: endDate) { _, newValue in
                if let current = emailSearchEndDate, current < newValue {
                    emailSearchEndDate = newValue
                }
            }
            .navigationTitle("New Trip")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: { dismiss() }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.red)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        let trip = Trip(
                            name: name,
                            startDate: startDate,
                            endDate: endDate,
                            emailSearchStartDate: emailSearchStartDate ?? computedEmailSearchStartDate,
                            emailSearchEndDate: emailSearchEndDate ?? computedEmailSearchEndDate
                        )
                        modelContext.insert(trip)
                        dismiss()
                    }
                    .disabled(name.isEmpty)
                }
            }
        }
    }
}

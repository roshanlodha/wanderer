import SwiftUI
import SwiftData

struct AddTripView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date().addingTimeInterval(86400 * 7)
    @State private var ignoreEmailsBeforeDate: Date?
    
    var computedIgnoreEmailsBeforeDate: Date {
        ignoreEmailsBeforeDate ?? (Calendar.current.date(byAdding: .day, value: -7, to: startDate) ?? startDate)
    }
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Trip Name", text: $name)
                DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                DatePicker("End Date", selection: $endDate, in: startDate..., displayedComponents: .date)

                Section("Email Filtering") {
                    DatePicker("Ignore Emails Before", selection: Binding(
                        get: { ignoreEmailsBeforeDate ?? computedIgnoreEmailsBeforeDate },
                        set: { ignoreEmailsBeforeDate = $0 }
                    ), displayedComponents: .date)
                }
            }
            .onChange(of: startDate) { _, newValue in
                if let current = ignoreEmailsBeforeDate, current > newValue {
                    ignoreEmailsBeforeDate = newValue
                }
            }
            .navigationTitle("New Trip")
            .scrollContentBackground(.hidden)
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
                            ignoreEmailsBeforeDate: ignoreEmailsBeforeDate ?? computedIgnoreEmailsBeforeDate
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

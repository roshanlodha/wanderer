import SwiftUI
import SwiftData

struct AddTripView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var startDate: Date = Date()
    @State private var endDate: Date = Date().addingTimeInterval(86400 * 7)
    @State private var emailSearchStartDate: Date = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
    @State private var emailSearchEndDate: Date = Calendar.current.date(byAdding: .day, value: 14, to: Date()) ?? Date()
    
    var body: some View {
        NavigationStack {
            Form {
                TextField("Trip Name", text: $name)
                DatePicker("Start Date", selection: $startDate, displayedComponents: .date)
                DatePicker("End Date", selection: $endDate, in: startDate..., displayedComponents: .date)

                Section("Email Search Date Range") {
                    DatePicker("Search Start", selection: $emailSearchStartDate, displayedComponents: .date)
                    DatePicker("Search End", selection: $emailSearchEndDate, in: emailSearchStartDate..., displayedComponents: .date)
                }
            }
            .onChange(of: startDate) { _, newValue in
                if emailSearchStartDate > newValue {
                    emailSearchStartDate = newValue
                }
            }
            .onChange(of: endDate) { _, newValue in
                if emailSearchEndDate < newValue {
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
                            emailSearchStartDate: emailSearchStartDate,
                            emailSearchEndDate: emailSearchEndDate
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

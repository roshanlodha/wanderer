import SwiftUI
import SwiftData

struct TimelineItemView: View {
    /// Returns the event's own local timezone, falling back to UTC (not device local) to avoid
    /// silently converting times to the viewer's zone when the event zone is unknown.
    private func eventTimeZone(for item: ItineraryItem) -> TimeZone {
        ItineraryParserService.shared.timeZone(fromGMTOffset: item.timeZoneGMTOffset) ?? TimeZone(secondsFromGMT: 0)!
    }

    private func formattedTime(_ date: Date, item: ItineraryItem) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        formatter.timeZone = eventTimeZone(for: item)
        return formatter.string(from: date)
    }

    let item: ItineraryItem
    @State private var isExpanded = false
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Time column — always shown in the event's own local timezone
            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedTime(item.startTime, item: item))
                    .font(.subheadline)
                    .fontWeight(.bold)
                if let endTime = item.endTime {
                    Text(formattedTime(endTime, item: item))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 60, alignment: .trailing)
            
            // Timeline graphics
            VStack(spacing: 0) {
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    
                    Image(systemName: item.travelMode.icon)
                        .foregroundColor(iconColor)
                        .font(.system(size: 14, weight: .semibold))
                }
                
                Rectangle()
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 2)
                    .frame(minHeight: 40)
            }
            
            // Content
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text(item.locationName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let offset = item.timeZoneGMTOffset, !offset.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "globe")
                            .foregroundColor(.teal)
                            .font(.caption)
                        Text("GMT\(offset)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let provider = item.provider, !provider.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "building.2")
                            .foregroundColor(.indigo)
                            .font(.caption)
                        Text(provider)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let ref = item.bookingReference, !ref.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "ticket")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("Ref: \(ref)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if let altRef = item.alternativeReference, !altRef.isEmpty {
                    HStack(spacing: 4) {
                        Image(systemName: "number.square")
                            .foregroundColor(.orange)
                            .font(.caption)
                        Text("Alternative Reference: \(altRef)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if let notes = item.notes, !notes.isEmpty {
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "note.text")
                            .foregroundColor(.blue)
                            .font(.caption)
                            .padding(.top, 2)
                        Text(notes)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                
                if let rawSource = item.rawTextSource, !rawSource.isEmpty {
                    Button(action: {
                        withAnimation { isExpanded.toggle() }
                    }) {
                        HStack(spacing: 4) {
                            Text("Source: Email")
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        }
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
                    }
                    .buttonStyle(.plain)
                    
                    if isExpanded {
                        Text(rawSource)
                            .font(.caption2)
                            .foregroundColor(.secondary)
                            .padding(8)
                            .background(Color.gray.opacity(0.1))
                            .cornerRadius(8)
                            .transition(.opacity)
                    }
                }
            }
            .padding(.bottom, 24)
            .padding(.top, 4)
            
            Spacer()
        }
    }
    
    private var iconColor: Color {
        switch item.travelMode {
        case .flight: return .blue
        case .hotel: return .indigo
        case .bus: return .orange
        case .train: return .teal
        case .activity: return .green
        case .restaurant: return .pink
        case .document: return .purple
        case .other: return .gray
        }
    }
}

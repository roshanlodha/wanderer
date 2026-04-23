import SwiftUI
import SwiftData

struct TimelineItemView: View {
    let item: ItineraryItem
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Time column
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.startTime, format: .dateTime.hour().minute())
                    .font(.subheadline)
                    .fontWeight(.bold)
                Text(item.endTime, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundColor(.secondary)
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
                
                HStack(spacing: 4) {
                    Image(systemName: "mappin.and.ellipse")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text(item.locationName)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
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
                
                if let rawSource = item.rawTextSource, !rawSource.isEmpty {
                    Text("Source: Email Confirmation")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .padding(.top, 2)
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
        }
    }
}

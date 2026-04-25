import SwiftUI

private struct CalendarSegment: Identifiable {
    let id: String
    let item: ItineraryItem
    let dayIndex: Int
    let dayStart: Date
    let startMinutes: CGFloat
    let endMinutes: CGFloat
    var column: Int = 0
    var totalColumns: Int = 1
}

struct WeeklyCalendarView: View {
    let trip: Trip

    @State private var weekStartDate: Date

    private let hourHeight: CGFloat = 88
    private let timeColumnWidth: CGFloat = 72
    private let dayColumnWidth: CGFloat = 170

    init(trip: Trip) {
        self.trip = trip
        _weekStartDate = State(initialValue: Self.initialWeekStart(for: trip))
    }

    private var userTimeZone: TimeZone { .current }

    private var userCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = userTimeZone
        calendar.firstWeekday = 1
        return calendar
    }

    private var weekDays: [Date] {
        (0..<7).compactMap { userCalendar.date(byAdding: .day, value: $0, to: weekStartDate) }
    }

    private var weekRangeLabel: String {
        guard let lastDay = weekDays.last else { return "" }
        let formatter = DateFormatter()
        formatter.timeZone = userTimeZone
        formatter.dateFormat = "MMM d"

        let start = formatter.string(from: weekStartDate)
        let end = formatter.string(from: lastDay)
        let year = userCalendar.component(.year, from: weekStartDate)
        return "\(start) - \(end), \(year)"
    }

    private var currentTimeZoneLabel: String {
        let abbreviation = userTimeZone.abbreviation() ?? userTimeZone.identifier
        let offset = ItineraryParserService.shared.gmtOffsetString(for: userTimeZone, at: Date())
        return "\(abbreviation) (GMT\(offset))"
    }

    private var totalGridHeight: CGFloat {
        hourHeight * 24
    }

    private var weekSegments: [CalendarSegment] {
        let startOfWeek = weekStartDate
        let endOfWeek = userCalendar.date(byAdding: .day, value: 7, to: startOfWeek) ?? startOfWeek

        var segments: [CalendarSegment] = []

        for item in trip.items {
            let itemStart = item.startTime
            let nominalEnd = item.endTime ?? itemStart.addingTimeInterval(3600)
            let itemEnd = max(nominalEnd, itemStart.addingTimeInterval(1800))

            guard itemEnd > startOfWeek, itemStart < endOfWeek else { continue }

            for (dayIndex, day) in weekDays.enumerated() {
                guard let nextDay = userCalendar.date(byAdding: .day, value: 1, to: day) else { continue }
                let segmentStart = max(itemStart, day)
                let segmentEnd = min(itemEnd, nextDay)

                guard segmentEnd > segmentStart else { continue }

                let startMinutes = CGFloat(segmentStart.timeIntervalSince(day) / 60)
                let endMinutes = CGFloat(segmentEnd.timeIntervalSince(day) / 60)

                segments.append(
                    CalendarSegment(
                        id: "\(item.id.uuidString)-\(dayIndex)-\(Int(startMinutes))",
                        item: item,
                        dayIndex: dayIndex,
                        dayStart: day,
                        startMinutes: startMinutes,
                        endMinutes: endMinutes
                    )
                )
            }
        }

        return resolveOverlaps(for: segments)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            weekdayHeader

            if trip.items.isEmpty {
                ContentUnavailableView {
                    Label("No Events Yet", systemImage: "calendar")
                } description: {
                    Text("Sync or add itinerary items to populate the calendar.")
                }
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                ScrollView([.vertical, .horizontal]) {
                    ZStack(alignment: .topLeading) {
                        backgroundGrid
                        currentTimeIndicator
                        ForEach(weekSegments) { segment in
                            segmentCard(segment)
                        }
                    }
                    .frame(
                        width: timeColumnWidth + (dayColumnWidth * CGFloat(weekDays.count)),
                        height: totalGridHeight
                    )
                }
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                )
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Calendar")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Showing everything in your current timezone: \(currentTimeZoneLabel)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 10) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            weekStartDate = userCalendar.date(byAdding: .day, value: -7, to: weekStartDate) ?? weekStartDate
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)

                    Button("Today") {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            weekStartDate = Self.initialWeekStart(for: trip)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            weekStartDate = userCalendar.date(byAdding: .day, value: 7, to: weekStartDate) ?? weekStartDate
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(alignment: .center) {
                Text(weekRangeLabel)
                    .font(.headline)

                Spacer()

                HStack(spacing: 12) {
                    legendSwatch(.flight)
                    legendSwatch(.hotel)
                    legendSwatch(.train)
                    legendSwatch(.bus)
                    legendSwatch(.activity)
                }
            }
        }
    }

    private func legendSwatch(_ mode: TravelMode) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(mode.calendarColor)
                .frame(width: 10, height: 10)
            Text(mode.rawValue)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 0) {
            Text("Time")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .frame(width: timeColumnWidth, alignment: .trailing)
                .padding(.trailing, 10)

            ForEach(Array(weekDays.enumerated()), id: \.offset) { _, date in
                VStack(spacing: 4) {
                    Text(date, format: .dateTime.weekday(.abbreviated))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(date, format: .dateTime.day())
                        .font(.headline)
                        .fontWeight(userCalendar.isDateInToday(date) ? .bold : .semibold)
                        .foregroundColor(userCalendar.isDateInToday(date) ? .orange : .primary)
                }
                .frame(width: dayColumnWidth)
            }
        }
    }

    private var backgroundGrid: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))

            ForEach(0...24, id: \.self) { hour in
                let y = CGFloat(hour) * hourHeight
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: timeColumnWidth + (dayColumnWidth * CGFloat(weekDays.count)), y: y))
                }
                .stroke(hour == 24 ? Color.clear : Color.black.opacity(0.06), lineWidth: 1)
            }

            ForEach(Array(weekDays.enumerated()), id: \.offset) { index, _ in
                let x = timeColumnWidth + (CGFloat(index) * dayColumnWidth)
                Path { path in
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: totalGridHeight))
                }
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
            }

            ForEach(0..<24, id: \.self) { hour in
                Text(hourLabel(for: hour))
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: timeColumnWidth - 12, alignment: .trailing)
                    .position(x: (timeColumnWidth - 12) / 2, y: (CGFloat(hour) * hourHeight) + 10)
            }
        }
    }

    private var currentTimeIndicator: some View {
        Group {
            if let indicator = currentTimeIndicatorPosition() {
                ZStack(alignment: .leading) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 10, height: 10)
                        .offset(x: indicator.x - 5, y: indicator.y - 5)

                    Path { path in
                        path.move(to: CGPoint(x: indicator.x, y: indicator.y))
                        path.addLine(to: CGPoint(x: timeColumnWidth + (dayColumnWidth * CGFloat(weekDays.count)), y: indicator.y))
                    }
                    .stroke(Color.red.opacity(0.75), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                }
            }
        }
    }

    private func currentTimeIndicatorPosition() -> CGPoint? {
        let now = Date()
        guard let dayIndex = weekDays.firstIndex(where: { userCalendar.isDate($0, inSameDayAs: now) }) else {
            return nil
        }

        let dayStart = weekDays[dayIndex]
        let minutes = CGFloat(now.timeIntervalSince(dayStart) / 60)
        return CGPoint(
            x: timeColumnWidth + (CGFloat(dayIndex) * dayColumnWidth),
            y: (minutes / 60) * hourHeight
        )
    }

    private func segmentCard(_ segment: CalendarSegment) -> some View {
        let widthPadding: CGFloat = 10
        let availableWidth = (dayColumnWidth - widthPadding * 2) / CGFloat(max(segment.totalColumns, 1))
        let cardWidth = max(availableWidth - 6, 54)
        let x = timeColumnWidth
            + (CGFloat(segment.dayIndex) * dayColumnWidth)
            + widthPadding
            + (CGFloat(segment.column) * availableWidth)
        let y = (segment.startMinutes / 60) * hourHeight
        let height = max(((segment.endMinutes - segment.startMinutes) / 60) * hourHeight, 36)
        let userStart = formattedTime(segment.item.startTime)
        let userEnd = formattedTime(segment.item.endTime ?? segment.item.startTime.addingTimeInterval(3600))
        let title = segment.item.title
        let location = segment.item.locationName
        let provider = segment.item.provider

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: segment.item.travelMode.icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .lineLimit(2)
            }

            Text("\(userStart) - \(userEnd)")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.92))

            if !location.isEmpty {
                Text(location)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.9))
                    .lineLimit(2)
            }

            if let provider, !provider.isEmpty {
                Text(provider)
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(width: cardWidth, height: height, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            segment.item.travelMode.calendarColor.opacity(0.95),
                            segment.item.travelMode.calendarColor.opacity(0.78)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: segment.item.travelMode.calendarColor.opacity(0.18), radius: 8, x: 0, y: 4)
        .foregroundColor(.white)
        .position(
            x: x + cardWidth / 2,
            y: y + height / 2
        )
    }

    private func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = userTimeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func hourLabel(for hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        formatter.timeZone = userTimeZone

        let date = userCalendar.date(bySettingHour: hour, minute: 0, second: 0, of: weekStartDate) ?? weekStartDate
        return formatter.string(from: date).lowercased()
    }

    private func resolveOverlaps(for segments: [CalendarSegment]) -> [CalendarSegment] {
        var resolved: [CalendarSegment] = []

        for dayIndex in 0..<7 {
            let daySegments = segments
                .filter { $0.dayIndex == dayIndex }
                .sorted {
                    if $0.startMinutes == $1.startMinutes {
                        return $0.endMinutes < $1.endMinutes
                    }
                    return $0.startMinutes < $1.startMinutes
                }

            var active: [CalendarSegment] = []
            var dayResolved: [CalendarSegment] = []

            for segment in daySegments {
                active.removeAll { $0.endMinutes <= segment.startMinutes }

                let takenColumns = Set(active.map(\.column))
                var nextColumn = 0
                while takenColumns.contains(nextColumn) {
                    nextColumn += 1
                }

                var updated = segment
                updated.column = nextColumn
                active.append(updated)
                let maxColumns = max(active.map(\.column).max() ?? 0, nextColumn) + 1

                for index in active.indices {
                    active[index].totalColumns = max(active[index].totalColumns, maxColumns)
                    if let resolvedIndex = dayResolved.firstIndex(where: { $0.id == active[index].id }) {
                        dayResolved[resolvedIndex].totalColumns = max(dayResolved[resolvedIndex].totalColumns, maxColumns)
                    }
                }
                updated.totalColumns = max(updated.totalColumns, maxColumns)
                dayResolved.append(updated)
            }

            resolved.append(contentsOf: dayResolved)
        }

        return resolved
    }

    private static func initialWeekStart(for trip: Trip) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        calendar.firstWeekday = 1

        let reference = trip.items.isEmpty ? trip.startDate : (trip.items.min(by: { $0.startTime < $1.startTime })?.startTime ?? trip.startDate)
        let components = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear], from: reference)
        return calendar.date(from: components) ?? calendar.startOfDay(for: reference)
    }
}

private extension TravelMode {
    var calendarColor: Color {
        switch self {
        case .flight: return Color(red: 0.16, green: 0.48, blue: 0.97)
        case .hotel: return Color(red: 0.43, green: 0.30, blue: 0.89)
        case .bus: return Color(red: 0.92, green: 0.52, blue: 0.20)
        case .train: return Color(red: 0.07, green: 0.63, blue: 0.68)
        case .activity: return Color(red: 0.18, green: 0.72, blue: 0.39)
        case .document: return Color(red: 0.72, green: 0.32, blue: 0.85)
        case .other: return Color.gray
        }
    }
}

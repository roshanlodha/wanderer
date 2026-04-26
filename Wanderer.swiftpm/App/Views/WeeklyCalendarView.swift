import SwiftUI

private struct AgendaDay: Identifiable {
    let id: Date
    let date: Date
    let items: [ItineraryItem]
}

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

private struct HotelDaySegment: Identifiable {
    let id: String
    let item: ItineraryItem
    let dayIndex: Int
    let dayStart: Date
    let dayEnd: Date
    var stackIndex: Int = 0
}

struct WeeklyCalendarView: View {
    let trip: Trip
    var onSelectItem: ((ItineraryItem) -> Void)? = nil

    @State private var weekStartDate: Date
    @AppStorage("calendarTimeZoneIdentifier") private var calendarTimeZoneIdentifier: String = ""
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    private let hourHeight: CGFloat = 88
    private let timeColumnWidth: CGFloat = 72
    private let dayColumnWidth: CGFloat = 170
    private let compactLayoutBreakpoint: CGFloat = 900

    init(trip: Trip) {
        self.trip = trip
        _weekStartDate = State(initialValue: Self.initialWeekStart(for: trip))
    }

    init(trip: Trip, onSelectItem: ((ItineraryItem) -> Void)? = nil) {
        self.trip = trip
        self.onSelectItem = onSelectItem
        _weekStartDate = State(initialValue: Self.initialWeekStart(for: trip))
    }

    private var calendarTimeZone: TimeZone {
        if calendarTimeZoneIdentifier.isEmpty {
            return .current
        }
        return TimeZone(identifier: calendarTimeZoneIdentifier) ?? .current
    }

    private var availableTimeZones: [TimeZone] {
        var zones: [TimeZone] = [calendarTimeZone, .current]
        if let utc = TimeZone(secondsFromGMT: 0) {
            zones.append(utc)
        }

        for item in trip.items {
            if let tz = ItineraryParserService.shared.timeZone(fromGMTOffset: item.timeZoneGMTOffset) {
                zones.append(tz)
            }
        }

        var seen = Set<String>()
        return zones
            .filter { seen.insert($0.identifier).inserted }
            .sorted { $0.secondsFromGMT() < $1.secondsFromGMT() }
    }

    private var userCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = calendarTimeZone
        calendar.firstWeekday = 1
        return calendar
    }

    private var weekDays: [Date] {
        (0..<7).compactMap { userCalendar.date(byAdding: .day, value: $0, to: weekStartDate) }
    }

    private var weekRangeLabel: String {
        guard let lastDay = weekDays.last else { return "" }
        let formatter = DateFormatter()
        formatter.timeZone = calendarTimeZone
        formatter.dateFormat = "MMM d"

        let start = formatter.string(from: weekStartDate)
        let end = formatter.string(from: lastDay)
        let year = userCalendar.component(.year, from: weekStartDate)
        return "\(start) - \(end), \(year)"
    }

    private var currentTimeZoneLabel: String {
        let abbreviation = calendarTimeZone.abbreviation() ?? calendarTimeZone.identifier
        let offset = ItineraryParserService.shared.gmtOffsetString(for: calendarTimeZone, at: Date())
        return "\(abbreviation) (GMT\(offset))"
    }

    /// Returns the event's own local timezone when available.
    private func eventTimeZone(for item: ItineraryItem) -> TimeZone {
        ItineraryParserService.shared.timeZone(fromGMTOffset: item.timeZoneGMTOffset) ?? calendarTimeZone
    }

    private var hotelLayout: (segments: [HotelDaySegment], maxStacks: Int) {
        let startOfWeek = weekStartDate
        let endOfWeek = userCalendar.date(byAdding: .day, value: 7, to: startOfWeek) ?? startOfWeek
        let hotels = trip.items.filter { $0.travelMode == .hotel }

        var unresolved: [HotelDaySegment] = []

        for hotel in hotels {
            let itemStart = hotel.startTime
            let itemEnd = max(hotel.endTime ?? hotel.startTime.addingTimeInterval(86_400), hotel.startTime.addingTimeInterval(1800))
            guard itemEnd > startOfWeek, itemStart < endOfWeek else { continue }

            for (dayIndex, day) in weekDays.enumerated() {
                guard let nextDay = userCalendar.date(byAdding: .day, value: 1, to: day) else { continue }
                let segmentStart = max(itemStart, day)
                let segmentEnd = min(itemEnd, nextDay)
                guard segmentEnd > segmentStart else { continue }

                unresolved.append(
                    HotelDaySegment(
                        id: "\(hotel.id.uuidString)-hotel-\(dayIndex)",
                        item: hotel,
                        dayIndex: dayIndex,
                        dayStart: segmentStart,
                        dayEnd: segmentEnd
                    )
                )
            }
        }

        var resolved: [HotelDaySegment] = []
        var maxStacks = 0

        for dayIndex in 0..<7 {
            let daySegments = unresolved
                .filter { $0.dayIndex == dayIndex }
                .sorted {
                    if $0.dayStart == $1.dayStart {
                        return $0.dayEnd < $1.dayEnd
                    }
                    return $0.dayStart < $1.dayStart
                }

            var active: [HotelDaySegment] = []
            for segment in daySegments {
                active.removeAll { $0.dayEnd <= segment.dayStart }
                let used = Set(active.map(\.stackIndex))

                var nextStack = 0
                while used.contains(nextStack) {
                    nextStack += 1
                }

                var updated = segment
                updated.stackIndex = nextStack
                active.append(updated)
                resolved.append(updated)
                maxStacks = max(maxStacks, nextStack + 1)
            }
        }

        return (resolved, maxStacks)
    }

    private var allDayRowHeight: CGFloat {
        guard !hotelLayout.segments.isEmpty else { return 0 }
        return CGFloat(max(hotelLayout.maxStacks, 1)) * 30 + 22
    }

    private var totalGridHeight: CGFloat {
        allDayRowHeight + (hourHeight * 24)
    }

    private var weekSegments: [CalendarSegment] {
        let startOfWeek = weekStartDate
        let endOfWeek = userCalendar.date(byAdding: .day, value: 7, to: startOfWeek) ?? startOfWeek

        var segments: [CalendarSegment] = []

        for item in trip.items where item.travelMode != .hotel {

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

    private var agendaDays: [AgendaDay] {
        let grouped = Dictionary(grouping: trip.items.sorted { $0.startTime < $1.startTime }) { userCalendar.startOfDay(for: $0.startTime) }

        return weekDays.compactMap { day in
            let dayStart = userCalendar.startOfDay(for: day)
            guard let items = grouped[dayStart], !items.isEmpty else { return nil }
            return AgendaDay(id: dayStart, date: day, items: items)
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let isCompactLayout = horizontalSizeClass == .compact || proxy.size.width < compactLayoutBreakpoint

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(isCompactLayout: isCompactLayout)

                    if trip.items.isEmpty {
                        ContentUnavailableView {
                            Label("No Events Yet", systemImage: "calendar")
                        } description: {
                            Text("Sync or add itinerary items to populate the calendar.")
                        }
                        .frame(maxWidth: .infinity, minHeight: isCompactLayout ? 280 : 360)
                    } else if isCompactLayout {
                        compactAgendaView
                    } else {
                        weekdayHeader

                        ScrollView([.vertical, .horizontal]) {
                            ZStack(alignment: .topLeading) {
                                backgroundGrid
                                ForEach(hotelLayout.segments) { segment in
                                    hotelStayCard(segment)
                                }
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
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func header(isCompactLayout: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if isCompactLayout {
                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calendar")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text(weekRangeLabel)
                            .font(.headline)
                        Text("Showing events in selected timezone")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 10) {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                weekStartDate = userCalendar.date(byAdding: .day, value: -7, to: weekStartDate) ?? weekStartDate
                            }
                        } label: {
                            Image(systemName: "chevron.left")
                                .frame(width: 18)
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
                                .frame(width: 18)
                        }
                        .buttonStyle(.bordered)

                        Spacer(minLength: 0)
                    }

                    HStack {
                        Text(currentTimeZoneLabel)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        Menu {
                            Picker("Calendar Time Zone", selection: $calendarTimeZoneIdentifier) {
                                Text("Device Time Zone").tag("")
                                ForEach(availableTimeZones, id: \.identifier) { timeZone in
                                    Text(timeZoneDisplayName(timeZone)).tag(timeZone.identifier)
                                }
                            }
                        } label: {
                            Label("Time Zone", systemImage: "globe")
                        }
                        .menuStyle(.borderlessButton)
                        .buttonStyle(.bordered)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            legendSwatch(.flight)
                            legendSwatch(.hotel)
                            legendSwatch(.train)
                            legendSwatch(.bus)
                            legendSwatch(.activity)
                        }
                        .padding(.trailing, 8)
                    }
                }
            } else {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Calendar")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Showing events in selected timezone")
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

                        Menu {
                            Picker("Calendar Time Zone", selection: $calendarTimeZoneIdentifier) {
                                Text("Device Time Zone").tag("")
                                ForEach(availableTimeZones, id: \.identifier) { timeZone in
                                    Text(timeZoneDisplayName(timeZone)).tag(timeZone.identifier)
                                }
                            }
                        } label: {
                            Label("Time Zone", systemImage: "globe")
                        }
                        .menuStyle(.borderlessButton)
                        .buttonStyle(.bordered)
                    }
                }

                HStack(alignment: .center) {
                    Text(weekRangeLabel)
                        .font(.headline)

                    Spacer()

                    Text(currentTimeZoneLabel)
                        .font(.caption)
                        .foregroundColor(.secondary)

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
    }

    private var compactAgendaView: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(agendaDays) { day in
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(day.date, format: .dateTime.weekday(.wide))
                                .font(.headline)
                            Text(day.date, format: .dateTime.month().day())
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        Text("\(day.items.count) item\(day.items.count == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    VStack(spacing: 10) {
                        ForEach(day.items) { item in
                            compactAgendaCard(for: item)
                        }
                    }
                }
                .padding(16)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
    }

    private func compactAgendaCard(for item: ItineraryItem) -> some View {
        Button {
            onSelectItem?(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(item.travelMode.calendarColor.opacity(0.15))
                        .frame(width: 34, height: 34)

                    Image(systemName: item.travelMode.icon)
                        .font(.caption)
                        .foregroundColor(item.travelMode.calendarColor)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(2)

                        Spacer(minLength: 8)

                        Text(formattedTimeRange(item))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    if !item.locationName.isEmpty {
                        Label(item.locationName, systemImage: "mappin.and.ellipse")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                    }

                    if let provider = item.provider, !provider.isEmpty {
                        Label(provider, systemImage: "building.2")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.black.opacity(0.05), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
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

            if allDayRowHeight > 0 {
                ForEach(Array(weekDays.enumerated()), id: \.offset) { index, _ in
                    Rectangle()
                        .fill(Color.black.opacity(0.03))
                        .frame(width: dayColumnWidth, height: allDayRowHeight)
                        .position(
                            x: timeColumnWidth + (CGFloat(index) * dayColumnWidth) + (dayColumnWidth / 2),
                            y: allDayRowHeight / 2
                        )
                }

                Text("All-day")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .frame(width: timeColumnWidth - 12, alignment: .trailing)
                    .position(x: (timeColumnWidth - 12) / 2, y: 12)

                Path { path in
                    path.move(to: CGPoint(x: 0, y: allDayRowHeight))
                    path.addLine(to: CGPoint(x: timeColumnWidth + (dayColumnWidth * CGFloat(weekDays.count)), y: allDayRowHeight))
                }
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
            }

            ForEach(0...24, id: \.self) { hour in
                let y = allDayRowHeight + (CGFloat(hour) * hourHeight)
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
                    .position(x: (timeColumnWidth - 12) / 2, y: allDayRowHeight + (CGFloat(hour) * hourHeight) + 10)
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
            y: allDayRowHeight + ((minutes / 60) * hourHeight)
        )
    }

    private func hotelStayCard(_ segment: HotelDaySegment) -> some View {
        let width: CGFloat = dayColumnWidth - 12
        let x = timeColumnWidth + (CGFloat(segment.dayIndex) * dayColumnWidth) + 6
        let y = 8 + (CGFloat(segment.stackIndex) * 30)

        return HStack(spacing: 6) {
            Image(systemName: segment.item.travelMode.icon)
                .font(.caption2)
            Text(segment.item.title)
                .font(.caption2)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(width: width, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(TravelMode.hotel.calendarColor.opacity(0.85))
        )
        .foregroundColor(.white)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.2), lineWidth: 1)
        )
        .position(x: x + (width / 2), y: y + 11)
        .onTapGesture {
            onSelectItem?(segment.item)
        }
    }

    private func segmentCard(_ segment: CalendarSegment) -> some View {
        let widthPadding: CGFloat = 10
        let availableWidth = (dayColumnWidth - widthPadding * 2) / CGFloat(max(segment.totalColumns, 1))
        let cardWidth = max(availableWidth - 6, 54)
        let x = timeColumnWidth
            + (CGFloat(segment.dayIndex) * dayColumnWidth)
            + widthPadding
            + (CGFloat(segment.column) * availableWidth)
        let y = allDayRowHeight + ((segment.startMinutes / 60) * hourHeight)
        let height = max(((segment.endMinutes - segment.startMinutes) / 60) * hourHeight, 36)
        let userStart = formattedTime(segment.item.startTime, item: segment.item)
        let userEnd = formattedTime(segment.item.endTime ?? segment.item.startTime.addingTimeInterval(3600), item: segment.item)
        let sourceTZ = eventTimeZone(for: segment.item)
        let sourceAbbreviation = sourceTZ.abbreviation() ?? sourceTZ.identifier
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

            if sourceTZ.identifier != calendarTimeZone.identifier {
                Text("Source TZ: \(sourceAbbreviation)")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.82))
                    .lineLimit(1)
            }

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
        .onTapGesture {
            onSelectItem?(segment.item)
        }
    }

    private func formattedTime(_ date: Date, item: ItineraryItem) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = calendarTimeZone
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: date)
    }

    private func formattedTimeRange(_ item: ItineraryItem) -> String {
        let start = formattedTime(item.startTime, item: item)
        let end = formattedTime(item.endTime ?? item.startTime.addingTimeInterval(3600), item: item)
        return "\(start) - \(end)"
    }

    private func hourLabel(for hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "ha"
        formatter.amSymbol = "AM"
        formatter.pmSymbol = "PM"
        formatter.timeZone = calendarTimeZone

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

    private func timeZoneDisplayName(_ timeZone: TimeZone) -> String {
        let abbreviation = timeZone.abbreviation() ?? timeZone.identifier
        let offset = ItineraryParserService.shared.gmtOffsetString(for: timeZone, at: Date())
        return "\(abbreviation) (GMT\(offset))"
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

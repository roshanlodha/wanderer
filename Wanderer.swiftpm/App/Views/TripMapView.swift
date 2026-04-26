import SwiftUI
import MapKit
import CoreLocation

private struct MappedItem: Identifiable {
    let id: UUID
    let item: ItineraryItem
    let coordinate: CLLocationCoordinate2D
}

struct TripMapView: View {
    let trip: Trip
    var onSelectItem: ((ItineraryItem) -> Void)? = nil

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var mappedItems: [MappedItem] = []
    @State private var isLoading = false
    @State private var unresolvedLocationsCount = 0
    @State private var geocodeTask: Task<Void, Never>?
    @State private var coordinateCache: [String: CLLocationCoordinate2D] = [:]

    private var locationSignature: String {
        trip.items
            .map { "\($0.id.uuidString)-\($0.locationName)-\($0.startTime.timeIntervalSinceReferenceDate)" }
            .sorted()
            .joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if horizontalSizeClass == .compact {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Map")
                        .font(.title2)
                        .fontWeight(.bold)
                    Text("Tap a pin to edit the same itinerary event.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            } else {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Map")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("Tap a pin to edit the same itinerary event.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }

                    Spacer()

                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }

            if trip.items.isEmpty {
                ContentUnavailableView {
                    Label("No Events Yet", systemImage: "map")
                } description: {
                    Text("Add or sync itinerary items to see them on the map.")
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            } else if mappedItems.isEmpty && !isLoading {
                ContentUnavailableView {
                    Label("No Mappable Locations", systemImage: "mappin.slash")
                } description: {
                    Text("The current itinerary items do not contain geocodable locations.")
                }
                .frame(maxWidth: .infinity, minHeight: 320)
            } else {
                Map(position: $cameraPosition) {
                    ForEach(mappedItems) { mapped in
                        Annotation(mapped.item.title, coordinate: mapped.coordinate) {
                            Button {
                                onSelectItem?(mapped.item)
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: mapped.item.travelMode.icon)
                                        .font(.caption)
                                        .padding(8)
                                        .background(mapped.item.travelMode.mapColor)
                                        .foregroundColor(.white)
                                        .clipShape(Circle())
                                    Text(mapped.item.title)
                                        .font(.caption2)
                                        .fontWeight(.semibold)
                                        .lineLimit(1)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Capsule())
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(minHeight: horizontalSizeClass == .compact ? 300 : 420)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                )
                .mapStyle(.standard(elevation: .realistic))

                if unresolvedLocationsCount > 0 {
                    Text("Could not place \(unresolvedLocationsCount) item\(unresolvedLocationsCount == 1 ? "" : "s") due to missing/ambiguous locations.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .onAppear {
            refreshMapPoints()
        }
        .onChange(of: locationSignature) { _, _ in
            refreshMapPoints()
        }
        .onDisappear {
            geocodeTask?.cancel()
        }
    }

    private func refreshMapPoints() {
        geocodeTask?.cancel()
        isLoading = true
        unresolvedLocationsCount = 0

        geocodeTask = Task {
            let candidates = trip.items
                .filter { !$0.locationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .sorted { $0.startTime < $1.startTime }

            let geocoder = CLGeocoder()
            var result: [MappedItem] = []
            var unresolved = 0

            for item in candidates {
                if Task.isCancelled { return }

                let key = item.locationName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let cached = coordinateCache[key] {
                    result.append(MappedItem(id: item.id, item: item, coordinate: cached))
                    continue
                }

                do {
                    let placemarks = try await geocoder.geocodeAddressString(item.locationName)
                    if let coordinate = placemarks.first?.location?.coordinate {
                        await MainActor.run {
                            coordinateCache[key] = coordinate
                        }
                        result.append(MappedItem(id: item.id, item: item, coordinate: coordinate))
                    } else {
                        unresolved += 1
                    }
                } catch {
                    unresolved += 1
                }
            }

            await MainActor.run {
                mappedItems = result
                unresolvedLocationsCount = unresolved
                isLoading = false
                updateCamera(for: result)
            }
        }
    }

    private func updateCamera(for points: [MappedItem]) {
        guard !points.isEmpty else {
            cameraPosition = .automatic
            return
        }

        let lats = points.map { $0.coordinate.latitude }
        let lons = points.map { $0.coordinate.longitude }

        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLon = lons.min(), let maxLon = lons.max() else {
            cameraPosition = .automatic
            return
        }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLon + maxLon) / 2
        )

        let latDelta = max((maxLat - minLat) * 1.6, 0.05)
        let lonDelta = max((maxLon - minLon) * 1.6, 0.05)

        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: latDelta, longitudeDelta: lonDelta)
        )

        cameraPosition = .region(region)
    }
}

private extension TravelMode {
    var mapColor: Color {
        switch self {
        case .flight: return Color(red: 0.16, green: 0.48, blue: 0.97)
        case .hotel: return Color(red: 0.43, green: 0.30, blue: 0.89)
        case .bus: return Color(red: 0.92, green: 0.52, blue: 0.20)
        case .train: return Color(red: 0.07, green: 0.63, blue: 0.68)
        case .activity: return Color(red: 0.18, green: 0.72, blue: 0.39)
        case .restaurant: return Color(red: 0.91, green: 0.36, blue: 0.57)
        case .document: return Color(red: 0.72, green: 0.32, blue: 0.85)
        case .other: return .gray
        }
    }
}

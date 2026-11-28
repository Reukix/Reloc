import CoreLocation
import Foundation
import MapKit

/// Unified place search result supporting both Apple `MKLocalSearch` and keyless OSM Nominatim fallback.
public struct PlaceSearchResult: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let address: String?
    public let latitude: Double
    public let longitude: Double
    public let isoCountryCode: String?
    /// True when the coordinate is guaranteed pure WGS-84 (e.g. OSM Nominatim) and must NOT undergo GCJ-02 reversal.
    public let isPureWGS84: Bool
    public let isOSMResult: Bool

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    public init(
        id: String,
        name: String,
        address: String?,
        latitude: Double,
        longitude: Double,
        isoCountryCode: String?,
        isPureWGS84: Bool,
        isOSMResult: Bool
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.isoCountryCode = isoCountryCode
        self.isPureWGS84 = isPureWGS84
        self.isOSMResult = isOSMResult
    }
}

/// Keyless OpenStreetMap Nominatim forward search fallback used when Apple `MKLocalSearch`
/// returns no matches or fails (e.g. under pure WGS-84 tiles, niche global POIs, or proxy filtering).
public enum NominatimSearchClient {
    public static func search(
        query: String,
        region: MKCoordinateRegion? = nil,
        limit: Int = 6
    ) async -> [PlaceSearchResult] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var comps = URLComponents(string: "https://nominatim.openstreetmap.org/search")
        var items: [URLQueryItem] = [
            URLQueryItem(name: "q", value: trimmed),
            URLQueryItem(name: "format", value: "jsonv2"),
            URLQueryItem(name: "addressdetails", value: "1"),
            URLQueryItem(name: "limit", value: "\(max(1, min(10, limit)))"),
            URLQueryItem(name: "accept-language", value: L10n.nominatimAcceptLanguage),
        ]
        if let region,
           region.center.latitude.isFinite,
           region.center.longitude.isFinite,
           region.span.latitudeDelta > 0,
           region.span.longitudeDelta > 0 {
            let halfLat = min(15.0, max(0.05, region.span.latitudeDelta * 1.5))
            let halfLon = min(20.0, max(0.05, region.span.longitudeDelta * 1.5))
            let left = max(-180.0, region.center.longitude - halfLon)
            let right = min(180.0, region.center.longitude + halfLon)
            let top = min(85.0, region.center.latitude + halfLat)
            let bottom = max(-85.0, region.center.latitude - halfLat)
            items.append(URLQueryItem(
                name: "viewbox",
                value: String(format: "%.5f,%.5f,%.5f,%.5f", left, top, right, bottom)
            ))
        }
        comps?.queryItems = items
        guard let url = comps?.url else { return [] }

        var req = URLRequest(url: url)
        req.timeoutInterval = 4.0
        req.setValue("Reloc/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                return []
            }
            return parseResponse(data: data)
        } catch {
            return []
        }
    }

    public static func parseResponse(data: Data) -> [PlaceSearchResult] {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        var results: [PlaceSearchResult] = []
        results.reserveCapacity(array.count)
        for (idx, item) in array.enumerated() {
            guard let latStr = item["lat"] as? String,
                  let lonStr = item["lon"] as? String,
                  let lat = Double(latStr),
                  let lon = Double(lonStr),
                  lat.isFinite, lon.isFinite,
                  (-90.0...90.0).contains(lat),
                  (-180.0...180.0).contains(lon) else {
                continue
            }
            let rawName = (item["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let displayName = (item["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let addrDict = item["address"] as? [String: Any]
            let isoCountry = (addrDict?["country_code"] as? String)?.uppercased()

            let primaryName: String
            if let rawName, !rawName.isEmpty {
                primaryName = rawName
            } else if let displayName, let firstSeg = displayName.split(separator: ",").first {
                primaryName = String(firstSeg).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                primaryName = String(format: "%.5f, %.5f", lat, lon)
            }

            let placeID = (item["place_id"] as? NSNumber)?.stringValue ?? "\(idx)"
            results.append(PlaceSearchResult(
                id: "osm-\(placeID)-\(idx)",
                name: primaryName,
                address: displayName,
                latitude: lat,
                longitude: lon,
                isoCountryCode: isoCountry,
                isPureWGS84: true,
                isOSMResult: true
            ))
        }
        return results
    }
}

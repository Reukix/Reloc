import CoreLocation
import Foundation

public struct TargetLocation: Equatable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitude: Double
    public var speedKnots: Double
    public var courseDegrees: Double

    public init(
        latitude: Double,
        longitude: Double,
        altitude: Double = 10.0,
        speedKnots: Double = 0.0,
        courseDegrees: Double = 0.0
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitude = altitude
        self.speedKnots = speedKnots
        self.courseDegrees = courseDegrees
    }
}

public enum NMEAGeneratorError: LocalizedError {
    case coordinateOutOfRange(Double)
    case encodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .coordinateOutOfRange(let value):
            return "Coordinate out of range: \(value)"
        case .encodingFailed(let reason):
            return reason
        }
    }
}

/// Faithful Swift port of accessory-location's profile.py (iAP2 identity & NMEA GGA/RMC).
public enum NMEAGenerator {
    /// Formats a decimal coordinate into NMEA DDMM.MMMM / DDDMM.MMMM + hemisphere.
    /// Uses integer minute-ten-thousandths to avoid rounding to invalid 60.0000 minutes.
    public static func formatCoordinate(_ value: Double, isLatitude: Bool) throws -> (String, String) {
        let limit = isLatitude ? 90.0 : 180.0
        guard value.isFinite, value >= -limit, value <= limit else {
            throw NMEAGeneratorError.coordinateOutOfRange(value)
        }
        let units = Int((abs(value) * 60.0 * 10000.0).rounded())
        let degrees = units / 600_000
        let minuteUnits = units % 600_000
        let minutes = Double(minuteUnits) / 10000.0
        let hemisphere = isLatitude ? (value < 0 ? "S" : "N") : (value < 0 ? "W" : "E")
        let formatted = isLatitude
            ? String(format: "%02d%07.4f", degrees, minutes)
            : String(format: "%03d%07.4f", degrees, minutes)
        return (formatted, hemisphere)
    }

    /// Computes XOR NMEA checksum and wraps body as `$<body>*<XX>\r\n`.
    public static func sentence(body: String) -> String {
        var checksum: UInt8 = 0
        for byte in body.utf8 {
            checksum ^= byte
        }
        return String(format: "$%@*%02X\r\n", body, checksum)
    }

    private static func utcTimestampStrings(for date: Date) -> (clock: String, ddmmyy: String) {
        let interval = date.timeIntervalSince1970
        let wholeSeconds = floor(interval)
        var rawTime = time_t(wholeSeconds)
        var utcTime = tm()
        gmtime_r(&rawTime, &utcTime)
        let centiseconds = min(99, max(0, Int(((interval - wholeSeconds) * 100.0).rounded(.down))))
        let clock = String(
            format: "%02d%02d%02d.%02d",
            utcTime.tm_hour,
            utcTime.tm_min,
            utcTime.tm_sec,
            centiseconds
        )
        let ddmmyy = String(
            format: "%02d%02d%02d",
            utcTime.tm_mday,
            utcTime.tm_mon + 1,
            (Int(utcTime.tm_year) + 1900) % 100
        )
        return (clock, ddmmyy)
    }

    /// Generates NMEA sentences keyed by iAP2 location sentence ID: 1 = GPGGA, 2 = GPRMC.
    public static func locationSentences(
        for location: TargetLocation,
        at date: Date = Date(),
        hdop: Double = 0.5,
        fixQuality: Int = 2
    ) throws -> [UInt16: String] {
        let (lat, north) = try formatCoordinate(location.latitude, isLatitude: true)
        let (lon, east) = try formatCoordinate(location.longitude, isLatitude: false)
        let (clock, ddmmyy) = utcTimestampStrings(for: date)

        let safeQuality = max(0, min(8, fixQuality))
        let safeHDOP = hdop.isFinite ? max(0.1, hdop) : 0.5
        let hdopStr = String(format: "%.1f", safeHDOP)
        let safeAltitude = location.altitude.isFinite ? min(50_000.0, max(-500.0, location.altitude)) : 10.0
        let altitudeStr = String(format: "%.1f", safeAltitude)
        let speedStr = String(format: "%.1f", max(0.0, location.speedKnots.isFinite ? location.speedKnots : 0.0))
        var courseNorm = location.courseDegrees.isFinite
            ? ((location.courseDegrees.truncatingRemainder(dividingBy: 360.0)) + 360.0)
                .truncatingRemainder(dividingBy: 360.0)
            : 0.0
        if courseNorm >= 359.95 {
            courseNorm = 0.0
        }
        let courseStr = String(format: "%.1f", courseNorm)
        let rmcMode = safeQuality == 2 ? "D" : "A"

        let gga = sentence(
            body: "GPGGA,\(clock),\(lat),\(north),\(lon),\(east),\(safeQuality),12,\(hdopStr),\(altitudeStr),M,0.0,M,,"
        )
        let rmc = sentence(
            body: "GPRMC,\(clock),A,\(lat),\(north),\(lon),\(east),\(speedStr),\(courseStr),\(ddmmyy),,,\(rmcMode)"
        )
        return [1: gga, 2: rmc]
    }

    /// Generates standard NMEA-0183 void/invalid-fix sentences (GGA quality=0, RMC status=V)
    /// sent right before tearing down the iAP2 link so `locationd` immediately drops the
    /// external accessory fix and falls back to internal GNSS/Wi-Fi/Cellular positioning.
    public static func voidLocationSentences(at date: Date = Date()) -> [UInt16: String] {
        let (clock, ddmmyy) = utcTimestampStrings(for: date)
        let gga = sentence(body: "GPGGA,\(clock),0000.0000,N,00000.0000,E,0,00,99.9,0.0,M,0.0,M,,")
        let rmc = sentence(body: "GPRMC,\(clock),V,,,,,0.0,0.0,\(ddmmyy),,,N")
        return [1: gga, 2: rmc]
    }

    /// Encodes `0xFFFB` LocationInformation with each NMEA sentence as parameter 0.
    public static func locationMessage(sentences: [String]) throws -> RLIAP2Message {
        var body = Data()
        for item in sentences {
            let param = try RLIAP2Parameter.encodeText(0, string: item)
            body.append(param)
        }
        return RLIAP2Message(identifier: 0xFFFB, body: body)
    }

    /// Builds `0x1D01` IdentificationInformation matching accessory-location's USB/CarKit profile.
    public static func identificationMessage(
        name: String = "Accessory Location Lab",
        model: String = "AL-1",
        manufacturer: String = "Local Research",
        serialNumber: String = "AL-LOCAL-001",
        firmwareVersion: String = "0.1",
        hardwareVersion: String = "1"
    ) throws -> RLIAP2Message {
        var body = Data()
        let strings: [(UInt16, String)] = [
            (0, name),
            (1, model),
            (2, manufacturer),
            (3, serialNumber),
            (4, firmwareVersion),
            (5, hardwareVersion),
        ]
        for (id, value) in strings {
            body.append(try RLIAP2Parameter.encodeText(id, string: value))
        }

        // MessagesSentByAccessory: 0xFFFB (LocationInformation)
        body.append(RLIAP2Parameter.encode(6, data: Data([0xFF, 0xFB])))
        // MessagesReceivedFromDevice: 0xFFFA (StartLocation), 0xFFFC (StopLocation)
        body.append(RLIAP2Parameter.encode(7, data: Data([0xFF, 0xFA, 0xFF, 0xFC])))
        // PowerProvidingCapability = None (0)
        body.append(RLIAP2Parameter.encode(8, data: Data([0x00])))
        // MaximumCurrentDrawnFromDevice = 0 mA
        body.append(RLIAP2Parameter.encode(9, data: Data([0x00, 0x00])))
        // CurrentLanguage & SupportedLanguage
        body.append(try RLIAP2Parameter.encodeText(12, string: "en"))
        body.append(try RLIAP2Parameter.encodeText(13, string: "en"))

        // USBHostTransportComponent (param 16)
        var transportComponent = Data()
        transportComponent.append(RLIAP2Parameter.encode(0, data: Data([0x00, 0x00])))
        transportComponent.append(try RLIAP2Parameter.encodeText(1, string: "Location Transport"))
        transportComponent.append(RLIAP2Parameter.encode(2, data: Data()))
        body.append(RLIAP2Parameter.encode(16, data: transportComponent))

        // LocationInformationComponent (param 22): ID 0, Name "GPS", GGA (17), RMC (18)
        var locationComponent = Data()
        locationComponent.append(RLIAP2Parameter.encode(0, data: Data([0x00, 0x00])))
        locationComponent.append(try RLIAP2Parameter.encodeText(1, string: "GPS"))
        locationComponent.append(RLIAP2Parameter.encode(17, data: Data()))
        locationComponent.append(RLIAP2Parameter.encode(18, data: Data()))
        body.append(RLIAP2Parameter.encode(22, data: locationComponent))

        return RLIAP2Message(identifier: 0x1D01, body: body)
    }
}

/// Optional GCJ-02 <-> WGS-84 coordinate conversion strictly scoped to Mainland China.
/// Uses a precise Mainland China boundary polygon with explicit exclusions for Hong Kong,
/// Macau, Kinmen, and Matsu (while Taiwan, Japan, Korea, Southeast Asia, and all other
/// overseas regions remain strictly untouched WGS-84).
public enum CoordinateTransform {
    private static let a = 6378245.0
    private static let ee = 0.00669342162296594323

    /// Mainland China outer polygon (longitude, latitude) tracing the PRC mainland land border
    /// and coastal waters (including Hainan, Zhoushan, Chongming) while excluding Taiwan,
    /// Japan, Korea, Russian Far East, Mongolia, Central/South/Southeast Asia.
    private static let mainlandChinaPolygon: [(Double, Double)] = [
        (134.85, 48.42), (133.90, 47.60), (133.20, 46.20), (133.15, 45.10),
        (131.25, 44.95), (131.15, 43.30), (130.65, 42.42), (129.80, 42.95),
        (128.05, 41.98), (126.90, 41.40), (125.95, 40.95), (124.42, 40.02),
        (124.32, 39.82), (122.90, 39.20), (121.65, 38.75), (121.10, 38.80),
        (122.80, 37.55), (122.70, 36.85), (120.70, 36.00), (119.80, 34.80),
        (121.20, 33.40), (122.40, 31.80), (122.90, 30.80), (122.50, 29.70),
        (121.80, 28.40), (121.10, 27.20), (120.40, 26.25), (119.85, 25.80),
        (119.82, 25.45), (119.65, 25.25), (119.15, 24.80), (118.26, 24.55),
        (118.18, 24.38), (117.65, 23.60), (117.15, 23.30), (115.80, 22.65),
        (114.65, 22.45), (114.32, 22.48), (113.85, 22.40), (113.70, 22.05),
        (112.90, 21.70), (111.30, 21.30), (110.80, 20.10), (110.65, 19.10),
        (109.90, 18.25), (109.10, 18.15), (108.55, 18.60), (109.00, 19.85),
        (109.50, 20.50), (109.25, 21.35), (108.05, 21.48), (106.75, 22.05),
        (105.80, 22.95), (104.00, 22.50), (102.15, 22.40), (101.60, 21.15),
        (100.10, 21.45), (98.90, 23.10), (97.55, 23.95), (98.75, 26.00),
        (98.60, 27.80), (97.35, 28.20), (95.30, 28.95), (92.00, 27.90),
        (88.90, 27.35), (88.15, 27.85), (85.90, 28.05), (83.90, 29.25),
        (81.05, 30.20), (79.10, 31.50), (78.60, 33.40), (78.10, 35.40),
        (75.50, 36.90), (73.60, 39.45), (75.30, 40.55), (78.15, 41.35),
        (80.15, 42.30), (80.25, 44.30), (82.40, 45.20), (82.80, 46.80),
        (85.55, 47.25), (85.75, 48.35), (87.35, 49.15), (90.90, 47.80),
        (91.05, 45.10), (95.80, 44.30), (96.40, 42.70), (100.80, 42.65),
        (105.00, 41.60), (111.95, 43.70), (115.60, 45.20), (119.65, 46.70),
        (116.70, 47.85), (115.50, 49.85), (119.35, 50.10), (121.45, 53.35),
        (124.20, 53.50), (126.60, 51.70), (127.25, 50.32), (127.55, 50.255), (130.30, 48.95),
        (130.95, 47.75), (132.95, 47.90), (134.25, 48.48),
    ]

    /// Explicit WGS-84 exclusion polygons for Hong Kong, Macau, Kinmen, and Matsu.
    private static let nonGCJ02Exclusions: [[(Double, Double)]] = [
        // Hong Kong (traces Shenzhen River / Deep Bay / Mirs Bay accurately)
        [
            (113.83, 22.14), (113.83, 22.40), (113.96, 22.475), (114.05, 22.506),
            (114.115, 22.518), (114.170, 22.540), (114.235, 22.540), (114.34, 22.51),
            (114.46, 22.44), (114.46, 22.14),
        ],
        // Macau (traces Gongbei / Wanzai / Hengqin channel accurately)
        [
            (113.524, 22.105), (113.524, 22.180), (113.528, 22.214),
            (113.562, 22.214), (113.605, 22.185), (113.605, 22.105),
        ],
        // Kinmen (off Xiamen)
        [
            (118.21, 24.37), (118.21, 24.53), (118.50, 24.53), (118.50, 24.37),
        ],
        // Matsu (off Fuzhou)
        [
            (119.85, 25.90), (119.85, 26.45), (120.55, 26.45), (120.55, 25.90),
        ],
    ]

    private static func pointInPolygon(lon: Double, lat: Double, polygon: [(Double, Double)]) -> Bool {
        var inside = false
        var j = polygon.count - 1
        for i in 0..<polygon.count {
            let (xi, yi) = polygon[i]
            let (xj, yj) = polygon[j]
            if ((yi > lat) != (yj > lat)) && (lon < (xj - xi) * (lat - yi) / (yj - yi) + xi) {
                inside.toggle()
            }
            j = i
        }
        return inside
    }

    /// True if the coordinate falls inside Mainland China (where GCJ-02 applies on domestic maps).
    public static func isInMainlandChina(lat: Double, lon: Double) -> Bool {
        guard lat.isFinite, lon.isFinite,
              lon >= 73.4, lon <= 135.1,
              lat >= 18.0, lat <= 53.6 else {
            return false
        }
        guard pointInPolygon(lon: lon, lat: lat, polygon: mainlandChinaPolygon) else {
            return false
        }
        for exclusion in nonGCJ02Exclusions {
            if pointInPolygon(lon: lon, lat: lat, polygon: exclusion) {
                return false
            }
        }
        return true
    }

    public static func isOutsideChina(lat: Double, lon: Double) -> Bool {
        !isInMainlandChina(lat: lat, lon: lon)
    }

    /// Determines whether GCJ-02 conversion should apply, giving priority to an authoritative
    /// `MKPlacemark.isoCountryCode` when available so border POIs in HK/MO/TW/JP/KR/etc.
    /// never receive unintended GCJ-02 shifts.
    public static func shouldApplyGCJ02(lat: Double, lon: Double, isoCountryCode: String? = nil) -> Bool {
        if let code = isoCountryCode?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
           !code.isEmpty,
           code != "CN" {
            return false
        }
        return isInMainlandChina(lat: lat, lon: lon)
    }

    public static func wgs84ToGCJ02(lat: Double, lon: Double) -> CLLocationCoordinate2D {
        if isOutsideChina(lat: lat, lon: lon) {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        let d = delta(lat: lat, lon: lon)
        return CLLocationCoordinate2D(latitude: lat + d.lat, longitude: lon + d.lon)
    }

    public static func gcj02ToWGS84(lat: Double, lon: Double) -> CLLocationCoordinate2D {
        // Fast outer-box rejection (slightly padded by max ~0.01° GCJ-02 shift)
        guard lat.isFinite, lon.isFinite,
              lon >= 73.3, lon <= 135.2,
              lat >= 17.9, lat <= 53.7 else {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        // 3-step fixed-point refinement gives sub-millimeter inverse accuracy,
        // and checking the Mainland China polygon in canonical WGS-84 space guarantees
        // exact bijectivity (`gcj02ToWGS84(wgs84ToGCJ02(w)) == w`) even right next to borders.
        var wgsLat = lat
        var wgsLon = lon
        for _ in 0..<3 {
            let d = delta(lat: wgsLat, lon: wgsLon)
            wgsLat = lat - d.lat
            wgsLon = lon - d.lon
        }
        guard isInMainlandChina(lat: wgsLat, lon: wgsLon) else {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return CLLocationCoordinate2D(latitude: wgsLat, longitude: wgsLon)
    }

    /// Applies optional sub-meter GPS micro-jitter (horizontal + subtle vertical) so stationary fixes feel more lifelike.
    public static func applyMicroJitter(to location: TargetLocation, radiusMeters: Double = 0.6) -> TargetLocation {
        guard radiusMeters > 0 else { return location }
        let angle = Double.random(in: 0..<(2.0 * .pi))
        let radius = Double.random(in: 0...radiusMeters)
        let dLat = (radius * cos(angle)) / 111_320.0
        let cosLat = max(0.01, cos(location.latitude * .pi / 180.0))
        let dLon = (radius * sin(angle)) / (111_320.0 * cosLat)
        let baseAlt = location.altitude.isFinite ? location.altitude : 10.0
        let dAlt = Double.random(in: -0.3...0.3)
        var copy = location
        copy.latitude = min(90.0, max(-90.0, location.latitude + dLat))
        copy.longitude = min(180.0, max(-180.0, location.longitude + dLon))
        copy.altitude = min(50_000.0, max(-500.0, baseAlt + dAlt))
        return copy
    }

    private static func delta(lat: Double, lon: Double) -> (lat: Double, lon: Double) {
        var dLat = transformLat(x: lon - 105.0, y: lat - 35.0)
        var dLon = transformLon(x: lon - 105.0, y: lat - 35.0)
        let radLat = lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1.0 - ee * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((a * (1.0 - ee)) / (magic * sqrtMagic) * .pi)
        dLon = (dLon * 180.0) / (a / sqrtMagic * cos(radLat) * .pi)
        return (dLat, dLon)
    }

    private static func transformLat(x: Double, y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLon(x: Double, y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }
}

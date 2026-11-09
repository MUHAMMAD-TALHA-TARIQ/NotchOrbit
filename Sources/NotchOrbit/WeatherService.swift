import AppKit
import Combine
import CoreLocation

// MARK: - Model

/// Weather condition derived from a WMO weather code (what Open-Meteo returns).
enum WeatherCondition: Int, Codable, Equatable {
    case clear, mainlyClear, partlyCloudy, overcast, fog
    case drizzle, freezingDrizzle, rain, heavyRain, freezingRain
    case snow, heavySnow, snowGrains, rainShowers, heavyShowers, snowShowers
    case thunderstorm, thunderstormHail, unknown

    init(wmo code: Int) {
        switch code {
        case 0:          self = .clear
        case 1:          self = .mainlyClear
        case 2:          self = .partlyCloudy
        case 3:          self = .overcast
        case 45, 48:     self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57:     self = .freezingDrizzle
        case 61, 63:     self = .rain
        case 65:         self = .heavyRain
        case 66, 67:     self = .freezingRain
        case 71, 73:     self = .snow
        case 75:         self = .heavySnow
        case 77:         self = .snowGrains
        case 80, 81:     self = .rainShowers
        case 82:         self = .heavyShowers
        case 85, 86:     self = .snowShowers
        case 95:         self = .thunderstorm
        case 96, 99:     self = .thunderstormHail
        default:         self = .unknown
        }
    }

    var title: String {
        switch self {
        case .clear:            return "Clear"
        case .mainlyClear:      return "Mainly clear"
        case .partlyCloudy:     return "Partly cloudy"
        case .overcast:         return "Overcast"
        case .fog:              return "Fog"
        case .drizzle:          return "Drizzle"
        case .freezingDrizzle:  return "Freezing drizzle"
        case .rain:             return "Rain"
        case .heavyRain:        return "Heavy rain"
        case .freezingRain:     return "Freezing rain"
        case .snow:             return "Snow"
        case .heavySnow:        return "Heavy snow"
        case .snowGrains:       return "Snow grains"
        case .rainShowers:      return "Rain showers"
        case .heavyShowers:     return "Heavy showers"
        case .snowShowers:      return "Snow showers"
        case .thunderstorm:     return "Thunderstorm"
        case .thunderstormHail: return "Thunderstorm with hail"
        case .unknown:          return "Unknown"
        }
    }

    func emoji(isDay: Bool) -> String {
        switch self {
        case .clear:            return isDay ? "☀️" : "🌙"
        case .mainlyClear:      return isDay ? "🌤️" : "🌙"
        case .partlyCloudy:     return isDay ? "⛅️" : "☁️"
        case .overcast:         return "☁️"
        case .fog:              return "🌫️"
        case .drizzle:          return isDay ? "🌦️" : "🌧️"
        case .freezingDrizzle, .freezingRain: return "🌧️"
        case .rain, .heavyRain: return "🌧️"
        case .snow, .heavySnow, .snowGrains, .snowShowers: return "🌨️"
        case .rainShowers:      return isDay ? "🌦️" : "🌧️"
        case .heavyShowers:     return "🌧️"
        case .thunderstorm, .thunderstormHail: return "⛈️"
        case .unknown:          return "🌡️"
        }
    }

    /// Multicolour SF Symbol for the condition.
    func symbolName(isDay: Bool) -> String {
        switch self {
        case .clear:            return isDay ? "sun.max.fill" : "moon.stars.fill"
        case .mainlyClear:      return isDay ? "sun.max.fill" : "moon.fill"
        case .partlyCloudy:     return isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .overcast:         return "cloud.fill"
        case .fog:              return "cloud.fog.fill"
        case .drizzle:          return "cloud.drizzle.fill"
        case .freezingDrizzle, .freezingRain: return "cloud.sleet.fill"
        case .rain:             return "cloud.rain.fill"
        case .heavyRain, .heavyShowers: return "cloud.heavyrain.fill"
        case .snow, .heavySnow, .snowGrains, .snowShowers: return "cloud.snow.fill"
        case .rainShowers:      return isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case .thunderstorm:     return "cloud.bolt.rain.fill"
        case .thunderstormHail: return "cloud.hail.fill"
        case .unknown:          return "questionmark.circle"
        }
    }
}

/// One hour of the forecast (local time at the location).
struct HourForecast: Codable, Equatable {
    var hour: Int          // 0–23
    var temperatureC: Double
    var condition: WeatherCondition
    var isDay: Bool

    /// "6 PM" / "18" depending on the user's clock style.
    var label: String {
        if HourForecast.uses12HourClock {
            let h = hour % 12 == 0 ? 12 : hour % 12
            return "\(h)\(hour < 12 ? "AM" : "PM")"
        }
        return String(format: "%02d", hour)
    }

    static let uses12HourClock: Bool = {
        let format = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: .current) ?? ""
        return format.contains("a")
    }()
}

/// One fetched observation. Temperatures are stored in Celsius and converted on display.
struct WeatherReading: Codable, Equatable {
    var condition: WeatherCondition
    var wmoCode: Int
    var isDay: Bool
    var temperatureC: Double
    var apparentC: Double?
    var humidity: Double?
    var windKmh: Double?
    var latitude: Double
    var longitude: Double
    var placeName: String?
    var fetchedAt: Date
    /// Next hours starting with the current one (up to 24). Optional so older caches still decode.
    var hourly: [HourForecast]?
    var highC: Double?
    var lowC: Double?

    /// Readings older than this are not shown.
    static let maxAge: TimeInterval = 3 * 3600

    var isStale: Bool { Date().timeIntervalSince(fetchedAt) > Self.maxAge }

    static func format(celsius: Double, unit: TemperatureUnit, withUnit: Bool = false) -> String {
        let value = unit.usesFahrenheit ? celsius * 9 / 5 + 32 : celsius
        let n = Int(value.rounded())
        return withUnit ? "\(n)°\(unit.usesFahrenheit ? "F" : "C")" : "\(n)°"
    }

    func temperature(in unit: TemperatureUnit, withUnit: Bool = false) -> String {
        Self.format(celsius: temperatureC, unit: unit, withUnit: withUnit)
    }

    func apparent(in unit: TemperatureUnit) -> String? {
        apparentC.map { Self.format(celsius: $0, unit: unit, withUnit: true) }
    }

    func emoji() -> String { condition.emoji(isDay: isDay) }
    func symbolName() -> String { condition.symbolName(isDay: isDay) }
}

// MARK: - Service

/// Fetches the current weather from Open-Meteo (free, no API key) for the user's
/// location (Core Location) or a chosen city, on a timer while weather mode is on.
final class WeatherService: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherService()

    enum Status: Equatable {
        case idle, locating, loading, ready
        case failed(String)

        var message: String {
            switch self {
            case .idle:     return "Weather is off"
            case .locating: return "Finding your location…"
            case .loading:  return "Fetching the forecast…"
            case .ready:    return "Up to date"
            case .failed(let why): return why
            }
        }
    }

    @Published private(set) var reading: WeatherReading?
    @Published private(set) var status: Status = .idle
    @Published private(set) var authorization: CLAuthorizationStatus

    /// Mirrors `AppSettings.weather`. Set by the overlay controller on every settings change.
    var settings = WeatherSettings() {
        didSet {
            guard settings != oldValue else { return }
            let locationChanged = settings.locationMode != oldValue.locationMode || settings.place != oldValue.place
            if locationChanged {
                reading = nil
                lastFix = nil
                refresh(force: true)
            } else if settings.refreshMinutes != oldValue.refreshMinutes {
                scheduleTimer()
            }
        }
    }

    /// Weather mode is enabled. The service only touches location and the network while true.
    var wanted = false {
        didSet {
            guard wanted != oldValue else { return }
            if wanted { refresh(force: false) } else { stop() }
        }
    }

    private var manager: CLLocationManager?
    private var timer: Timer?
    private var retryTimer: Timer?
    private var task: URLSessionDataTask?
    private var lastFix: CLLocationCoordinate2D?
    private var wakeObserver: NSObjectProtocol?
    private lazy var geocoder = CLGeocoder()
    private static let cacheKey = "NotchOrbit.weatherCache"
    private static let retryDelay: TimeInterval = 120

    private override init() {
        authorization = .notDetermined
        super.init()
        if let data = UserDefaults.standard.data(forKey: Self.cacheKey),
           let cached = try? JSONDecoder().decode(WeatherReading.self, from: data), !cached.isStale {
            reading = cached
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.wanted else { return }
                self.refresh(force: false)
            }
    }

    var isLocationDenied: Bool { authorization == .denied || authorization == .restricted }

    /// Core Location (and the location daemon connection behind it) is only brought up
    /// when something needs it: weather for the current location, or the Settings
    /// window showing the permission state. A chosen city never loads it.
    private func locationManager() -> CLLocationManager {
        if let manager { return manager }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        self.manager = manager
        authorization = manager.authorizationStatus
        return manager
    }

    /// Reads the current permission state (creating the location manager if needed).
    func refreshAuthorization() {
        authorization = locationManager().authorizationStatus
    }

    /// Latest reading, or nil when it is too old to trust.
    var currentReading: WeatherReading? {
        guard let reading, !reading.isStale else { return nil }
        return reading
    }

    // MARK: Refresh cycle

    /// Starts a fetch. `force` ignores a reading that is still fresh.
    func refresh(force: Bool) {
        guard wanted else { return }
        retryTimer?.invalidate(); retryTimer = nil
        scheduleTimer()
        if !force, let reading, Date().timeIntervalSince(reading.fetchedAt) < 60,
           matchesCurrentLocation(reading) {
            status = .ready
            return
        }
        switch settings.locationMode {
        case .place:
            guard let place = settings.place else {
                status = .failed("Choose a city in Settings › Weather.")
                return
            }
            fetch(latitude: place.latitude, longitude: place.longitude, placeName: place.name)
        case .current:
            requestCurrentLocation()
        }
    }

    private func matchesCurrentLocation(_ reading: WeatherReading) -> Bool {
        switch settings.locationMode {
        case .place:
            guard let place = settings.place else { return false }
            return abs(place.latitude - reading.latitude) < 0.01 && abs(place.longitude - reading.longitude) < 0.01
        case .current:
            return true
        }
    }

    private func stop() {
        timer?.invalidate(); timer = nil
        retryTimer?.invalidate(); retryTimer = nil
        task?.cancel(); task = nil
        status = .idle
    }

    private func scheduleTimer() {
        timer?.invalidate()
        guard wanted else { return }
        let interval = max(60, settings.refreshMinutes * 60)
        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in self?.refresh(force: true) }
        t.tolerance = interval * 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func scheduleRetry() {
        retryTimer?.invalidate()
        guard wanted else { return }
        let t = Timer(timeInterval: Self.retryDelay, repeats: false) { [weak self] _ in self?.refresh(force: true) }
        RunLoop.main.add(t, forMode: .common)
        retryTimer = t
    }

    // MARK: Location

    /// Asks macOS for location access (only meaningful while the status is "not determined").
    func requestLocationAccess() {
        locationManager().requestWhenInUseAuthorization()
    }

    private func requestCurrentLocation() {
        let manager = locationManager()
        switch manager.authorizationStatus {
        case .notDetermined:
            status = .locating
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            if let lastFix {
                fetch(latitude: lastFix.latitude, longitude: lastFix.longitude, placeName: reading?.placeName)
            } else {
                status = .failed("Location access is off. Allow it in System Settings › Privacy & Security › Location Services, or choose a city instead.")
            }
        default:
            status = .locating
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        guard wanted, settings.locationMode == .current else { return }
        switch authorization {
        case .notDetermined: break
        default: requestCurrentLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        lastFix = location.coordinate
        guard wanted, settings.locationMode == .current else { return }
        fetch(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude, placeName: nil)
        resolvePlaceName(for: location)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard wanted, settings.locationMode == .current else { return }
        if let lastFix {
            fetch(latitude: lastFix.latitude, longitude: lastFix.longitude, placeName: reading?.placeName)
        } else if let reading, !reading.isStale {
            // Keep showing the cached reading; try again later.
            fetch(latitude: reading.latitude, longitude: reading.longitude, placeName: reading.placeName)
        } else {
            status = .failed("Couldn't determine your location (\(error.localizedDescription)).")
            scheduleRetry()
        }
    }

    private func resolvePlaceName(for location: CLLocation) {
        geocoder.cancelGeocode()
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let self, let mark = placemarks?.first else { return }
            let name = mark.locality ?? mark.subAdministrativeArea ?? mark.administrativeArea ?? mark.name
            guard let name, var current = self.reading else { return }
            current.placeName = name
            self.reading = current
            self.cache(current)
        }
    }

    // MARK: Network

    private func fetch(latitude: Double, longitude: Double, placeName: String?) {
        task?.cancel()
        status = .loading
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,is_day,wind_speed_10m"),
            URLQueryItem(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "forecast_days", value: "2"),
            URLQueryItem(name: "timezone", value: "auto"),
        ]
        guard let url = components.url else { return }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("NotchOrbit/\(AppInfo.version)", forHTTPHeaderField: "User-Agent")
        if Debug.enabled {
            debugLog("[debug] weather fetch:", url.absoluteString)
        }
        let previousName = placeName ?? reading?.placeName
        task = URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                guard let self else { return }
                if let error {
                    if (error as NSError).code == NSURLErrorCancelled { return }
                    self.fail("Couldn't reach the weather service (\(error.localizedDescription)).")
                    return
                }
                guard let data, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                    self.fail("Weather service error (HTTP \(code)).")
                    return
                }
                guard let parsed = Self.parse(data, latitude: latitude, longitude: longitude) else {
                    self.fail("Unexpected reply from the weather service.")
                    return
                }
                var fresh = parsed
                fresh.placeName = placeName ?? (self.settings.locationMode == .current ? previousName : nil)
                self.reading = fresh
                self.status = .ready
                self.cache(fresh)
                if Debug.enabled {
                    debugLog("[debug] weather:", fresh)
                }
            }
        }
        task?.resume()
    }

    private func fail(_ message: String) {
        status = .failed(message)
        scheduleRetry()
    }

    private static func parse(_ data: Data, latitude: Double, longitude: Double) -> WeatherReading? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let current = root["current"] as? [String: Any],
              let temp = (current["temperature_2m"] as? NSNumber)?.doubleValue,
              let code = (current["weather_code"] as? NSNumber)?.intValue else { return nil }
        let isDay = ((current["is_day"] as? NSNumber)?.intValue ?? 1) != 0
        var reading = WeatherReading(condition: WeatherCondition(wmo: code), wmoCode: code, isDay: isDay,
                                     temperatureC: temp,
                                     apparentC: (current["apparent_temperature"] as? NSNumber)?.doubleValue,
                                     humidity: (current["relative_humidity_2m"] as? NSNumber)?.doubleValue,
                                     windKmh: (current["wind_speed_10m"] as? NSNumber)?.doubleValue,
                                     latitude: latitude, longitude: longitude, placeName: nil, fetchedAt: Date())

        // Hourly: times are ISO strings in the location's local zone ("2026-11-02T05:00"),
        // as is `current.time`, so string comparison picks out "this hour onwards".
        if let hourly = root["hourly"] as? [String: Any],
           let times = hourly["time"] as? [String],
           let temps = hourly["temperature_2m"] as? [Any],
           let codes = hourly["weather_code"] as? [Any],
           let days = hourly["is_day"] as? [Any],
           let now = current["time"] as? String, now.count >= 13 {
            let thisHour = String(now.prefix(13)) + ":00"
            var list: [HourForecast] = []
            for (i, t) in times.enumerated() where t >= thisHour && list.count < 24 {
                guard i < temps.count, i < codes.count, i < days.count,
                      let temp = (temps[i] as? NSNumber)?.doubleValue,
                      let code = (codes[i] as? NSNumber)?.intValue,
                      let hour = Int(t.dropFirst(11).prefix(2)) else { continue }
                let day = ((days[i] as? NSNumber)?.intValue ?? 1) != 0
                list.append(HourForecast(hour: hour, temperatureC: temp, condition: WeatherCondition(wmo: code), isDay: day))
            }
            reading.hourly = list
        }
        if let daily = root["daily"] as? [String: Any] {
            reading.highC = ((daily["temperature_2m_max"] as? [Any])?.first as? NSNumber)?.doubleValue
            reading.lowC = ((daily["temperature_2m_min"] as? [Any])?.first as? NSNumber)?.doubleValue
        }
        return reading
    }

    private func cache(_ reading: WeatherReading) {
        if let data = try? JSONEncoder().encode(reading) {
            UserDefaults.standard.set(data, forKey: Self.cacheKey)
        }
    }

    // MARK: City search

    /// Looks up places matching `query` with Open-Meteo's geocoder. Completion runs on the main queue.
    static func searchPlaces(_ query: String, completion: @escaping (Result<[WeatherPlace], Error>) -> Void) {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = components.url else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        URLSession.shared.dataTask(with: request) { data, _, error in
            let result: Result<[WeatherPlace], Error>
            if let error {
                result = .failure(error)
            } else if let data,
                      let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let items = (root["results"] as? [[String: Any]]) ?? []
                result = .success(items.compactMap { item in
                    guard let name = item["name"] as? String,
                          let lat = (item["latitude"] as? NSNumber)?.doubleValue,
                          let lon = (item["longitude"] as? NSNumber)?.doubleValue else { return nil }
                    var parts = [name]
                    if let admin = item["admin1"] as? String, admin != name { parts.append(admin) }
                    if let country = item["country"] as? String { parts.append(country) }
                    return WeatherPlace(name: parts.joined(separator: ", "), latitude: lat, longitude: lon)
                })
            } else {
                result = .failure(URLError(.badServerResponse))
            }
            DispatchQueue.main.async { completion(result) }
        }.resume()
    }
}

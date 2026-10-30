import CoreLocation
import Foundation

struct Weather: Equatable {
    var temperature: Int
    var high: Int
    var low: Int
    /// A WMO weather code, as used by Open-Meteo.
    var code: Int
    var isDay: Bool
    var place: String?

    var condition: String { Self.describe(code).text }
    var symbol: String { isDay ? Self.describe(code).day : Self.describe(code).night }

    private static func describe(_ code: Int) -> (text: String, day: String, night: String) {
        switch code {
        case 0: return ("Clear", "sun.max.fill", "moon.stars.fill")
        case 1: return ("Mostly Clear", "sun.max.fill", "moon.fill")
        case 2: return ("Partly Cloudy", "cloud.sun.fill", "cloud.moon.fill")
        case 3: return ("Cloudy", "cloud.fill", "cloud.fill")
        case 45, 48: return ("Fog", "cloud.fog.fill", "cloud.fog.fill")
        case 51...57: return ("Drizzle", "cloud.drizzle.fill", "cloud.drizzle.fill")
        case 61...67, 80...82: return ("Rain", "cloud.rain.fill", "cloud.rain.fill")
        case 71...77, 85, 86: return ("Snow", "cloud.snow.fill", "cloud.snow.fill")
        case 95...99: return ("Thunderstorms", "cloud.bolt.rain.fill", "cloud.bolt.rain.fill")
        default: return ("—", "cloud.fill", "cloud.fill")
        }
    }
}

/// Current weather for where you are. Off until you turn it on.
///
/// It uses your approximate location (rounded to about a kilometre) and the free, keyless
/// Open-Meteo service, refreshing every 30 minutes while the Mac is awake. This is the only
/// feature in NotchBar that talks to a web service on its own.
@MainActor
final class WeatherStore: NSObject, ObservableObject {
    enum Access { case off, waiting, denied, on }

    @Published private(set) var access: Access = .off
    @Published private(set) var weather: Weather?

    private let location = CLLocationManager()
    private lazy var refresh = EfficientTimer(interval: 1800, tolerance: 300) { [weak self] in self?.location.requestLocation() }
    private var lastPlace: (coordinate: CLLocationCoordinate2D, name: String?)?
    private static let enabledKey = "weatherEnabled"

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyKilometer
        updateAccess()
    }

    func start() {
        switch access {
        case .on:
            location.requestLocation()
            refresh.start()
        case .waiting:
            // Turned on earlier but never answered, for example after the app's identity
            // changed. Ask again.
            location.requestWhenInUseAuthorization()
        case .off, .denied:
            break
        }
    }

    func turnOn() {
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        if location.authorizationStatus == .notDetermined {
            access = .waiting
            location.requestWhenInUseAuthorization()
        } else {
            updateAccess()
            start()
        }
    }

    func turnOff() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        refresh.stop()
        weather = nil
        access = .off
    }

    /// Sample data for snapshot rendering.
    func setPreview(_ weather: Weather) {
        self.weather = weather
        access = .on
    }

    private func updateAccess() {
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { access = .off; return }
        switch location.authorizationStatus {
        case .authorizedAlways, .authorized: access = .on
        case .notDetermined: access = .waiting
        default: access = .denied
        }
    }

    private func load(_ coordinate: CLLocationCoordinate2D) async {
        let fahrenheit = Locale.current.measurementSystem == .us
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", coordinate.latitude)),
            .init(name: "longitude", value: String(format: "%.2f", coordinate.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timezone", value: "auto"),
            .init(name: "temperature_unit", value: fahrenheit ? "fahrenheit" : "celsius"),
        ]
        struct Response: Decodable {
            struct Current: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int }
            struct Daily: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double] }
            let current: Current
            let daily: Daily
        }
        guard let (data, _) = try? await URLSession.shared.data(from: url.url!),
              let response = try? JSONDecoder().decode(Response.self, from: data) else { return }
        let place = await placeName(for: coordinate)
        weather = Weather(temperature: Int(response.current.temperature_2m.rounded()),
                          high: Int((response.daily.temperature_2m_max.first ?? 0).rounded()),
                          low: Int((response.daily.temperature_2m_min.first ?? 0).rounded()),
                          code: response.current.weather_code, isDay: response.current.is_day == 1, place: place)
    }

    /// The town name, looked up again only after moving more than a few kilometres.
    private func placeName(for coordinate: CLLocationCoordinate2D) async -> String? {
        if let last = lastPlace,
           CLLocation(latitude: last.coordinate.latitude, longitude: last.coordinate.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) < 5000 {
            return last.name
        }
        let mark = try? await CLGeocoder().reverseGeocodeLocation(CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)).first
        let name = mark?.locality ?? mark?.administrativeArea
        lastPlace = (coordinate, name)
        return name
    }
}

extension WeatherStore: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            self.updateAccess()
            self.start()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coordinate = locations.last?.coordinate else { return }
        Task { @MainActor in await self.load(coordinate) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}

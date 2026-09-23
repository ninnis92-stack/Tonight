import Foundation
import CoreLocation
import MapKit
import StoreKit
import UIKit
#if canImport(GoogleMobileAds)
import GoogleMobileAds
#endif

protocol LocationProvider { func requestCurrentLocation() async throws -> LocationResult; func search(_ query: String) async -> [LocationResult] }
protocol PlacesProvider { func places(for location: LocationResult, preferences: UserPreferences) async -> [Place] }
protocol EventsProvider { }
protocol ReviewProvider { }
protocol MapsProvider { func openMap(for place: Place) }
protocol RecommendationEngine: Sendable { func plans(for preferences: UserPreferences, places: [Place]) async -> [EveningPlan] }
@MainActor protocol SubscriptionManager: AnyObject { var state: SubscriptionStatus { get }; func purchase() async throws; func restore() async throws }
protocol AnalyticsProvider { func track(_ event: AnalyticsEvent) }
protocol AdsProvider { func sponsorContent() async -> SponsorContent?; func report(_ content: SponsorContent) }

/// Keeps the launch build free-first. A server URL can be added later without
/// putting Google, Foursquare, or Ticketmaster secrets in the iOS binary.
struct ProviderConfiguration {
    let placesBackendURL: URL?
    let eventsBackendURL: URL?

    static let freeFirst = ProviderConfiguration(
        placesBackendURL: Bundle.main.url(forResource: "PlacesBackend", withExtension: "url"),
        eventsBackendURL: Bundle.main.url(forResource: "EventsBackend", withExtension: "url")
    )
}

enum AnalyticsEvent { case onboardingCompleted, recommendationRequested, planViewed, planSaved, planShared, placeOpened, feedbackSubmitted, paywallViewed, trialStarted, subscriptionPurchased }

struct SponsorContent: Identifiable, Equatable { let id: String; let label: String; let title: String; let detail: String; let actionTitle: String; let destination: URL? }
struct AdsConfiguration { let nativeUnitID: String?
    static let current = AdsConfiguration(nativeUnitID: {
        #if DEBUG
        return "ca-app-pub-3940256099942544/3986624511"
        #else
        return Bundle.main.object(forInfoDictionaryKey: "GADNativeAdUnitID") as? String
        #endif
    }())
}

struct MockLocationProvider: LocationProvider {
    func requestCurrentLocation() async throws -> LocationResult { LocationResult(name: "Brooklyn, NY", coordinate: CLLocationCoordinate2D(latitude: 40.6782, longitude: -73.9442)) }
    func search(_ query: String) async -> [LocationResult] { [LocationResult(name: query.isEmpty ? "Brooklyn, NY" : query, coordinate: CLLocationCoordinate2D(latitude: 40.6782, longitude: -73.9442))] }
}

@MainActor final class CoreLocationProvider: NSObject, ObservableObject, LocationProvider, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<LocationResult, Error>?
    private var authorizationContinuation: CheckedContinuation<Void, Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestCurrentLocation() async throws -> LocationResult {
        if manager.authorizationStatus == .notDetermined {
            try await withCheckedThrowingContinuation { continuation in
                self.authorizationContinuation = continuation
                self.manager.requestWhenInUseAuthorization()
            }
        }
        guard manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse else { throw LocationError.permissionDenied }
        guard continuation == nil else { throw LocationError.requestInProgress }
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            self.manager.requestLocation()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(5))
                if let continuation = self.continuation { continuation.resume(throwing: LocationError.timedOut); self.continuation = nil }
            }
        }
    }

    func search(_ query: String) async -> [LocationResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = query
        let response = try? await MKLocalSearch(request: request).start()
        return response?.mapItems.compactMap { item in
            guard let coordinate = item.placemark.location?.coordinate else { return nil }
            return LocationResult(name: item.name ?? query, coordinate: coordinate)
        } ?? []
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedAlways, .authorizedWhenInUse:
                authorizationContinuation?.resume(); authorizationContinuation = nil
            case .denied, .restricted:
                authorizationContinuation?.resume(throwing: LocationError.permissionDenied); authorizationContinuation = nil
                continuation?.resume(throwing: LocationError.permissionDenied); continuation = nil
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        Task { @MainActor in continuation?.resume(returning: LocationResult(name: "Current location", coordinate: location.coordinate)); continuation = nil }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in continuation?.resume(throwing: error); continuation = nil }
    }
}

enum LocationError: Error { case permissionDenied, requestInProgress, timedOut }

struct MapKitMapsProvider: MapsProvider {
    func openMap(for place: Place) {
        guard let url = place.mapURL else { return }
        UIApplication.shared.open(url)
    }
}

struct MockPlacesProvider: PlacesProvider {
    func places(for location: LocationResult, preferences: UserPreferences) async -> [Place] { MockData.places }
}

/// Searches Apple Maps around the user's selected starting point. MapKit does
/// not require a third-party API key, so local results can improve immediately
/// while the provider-backed catalog remains optional.
struct MapKitPlacesProvider: PlacesProvider {
    func places(for location: LocationResult, preferences: UserPreferences) async -> [Place] {
        var found: [Place] = []
        for style in preferences.styles {
            for query in searchQueries(for: style) {
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.resultTypes = .pointOfInterest
                request.region = MKCoordinateRegion(
                    center: location.coordinate,
                    latitudinalMeters: preferences.radiusMiles * 3_218.69,
                    longitudinalMeters: preferences.radiusMiles * 3_218.69
                )
                guard let response = try? await MKLocalSearch(request: request).start() else { continue }
                found.append(contentsOf: response.mapItems.compactMap { makePlace(from: $0, origin: location.coordinate, style: style) })
            }
        }

        var seen = Set<String>()
        return found
            .sorted { ($0.distanceMiles ?? .greatestFiniteMagnitude) < ($1.distanceMiles ?? .greatestFiniteMagnitude) }
            .filter { place in
                let key = place.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                return seen.insert(key).inserted
            }
    }

    private func searchQueries(for style: ActivityStyle) -> [String] {
        let focused: [String] = switch style {
        case .food: ["restaurant", "dessert", "cafe"]
        case .entertainment: ["live music", "movie theater", "entertainment"]
        case .nature: ["park", "garden", "scenic overlook"]
        case .shopping: ["independent shop", "bookstore", "market"]
        case .learning: ["museum", "bookstore", "cultural center"]
        case .workspaces: ["laptop friendly cafe", "coworking space", "library"]
        case .fitness: ["fitness", "climbing gym", "recreation center"]
        case .arts: ["art gallery", "museum", "performing arts"]
        case .outdoor: ["park", "waterfront", "outdoor attraction"]
        case .indoor: ["museum", "cafe", "indoor attraction"]
        }
        // Broader queries make current-location planning resilient when a
        // neighborhood has sparse or differently categorized map results.
        return focused + ["things to do", "popular places"]
    }

    private func makePlace(from item: MKMapItem, origin: CLLocationCoordinate2D, style: ActivityStyle) -> Place? {
        guard let name = item.name, !name.isEmpty else { return nil }
        let coordinate = item.placemark.coordinate
        let distance = CLLocation(latitude: origin.latitude, longitude: origin.longitude)
            .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) / 1_609.344
        let category = categoryName(item.pointOfInterestCategory, fallback: style.rawValue)
        let priceLevel = estimatedPriceLevel(for: style)
        let mapURL = URL(string: "https://maps.apple.com/?q=\(name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? name)&ll=\(coordinate.latitude),\(coordinate.longitude)")
        return Place(
            id: "mapkit-\(coordinate.latitude)-\(coordinate.longitude)", name: name,
            category: category, neighborhood: item.placemark.locality ?? item.placemark.subLocality ?? "Nearby",
            description: "A nearby \(category.lowercased()) selected around \(item.placemark.locality ?? "your starting point").",
            emoji: emoji(for: style), rating: 0, priceLevel: priceLevel,
            estimatedCost: estimatedCost(for: style, priceLevel: priceLevel), durationMinutes: duration(for: style),
            indoorOutdoor: style == .outdoor || style == .nature ? "Outdoor" : "Indoor",
            vibeTags: vibeTags(for: style), audienceTags: ["Solo-friendly", "Friends", "Romantic"],
            activityTags: [style], mapURL: mapURL, websiteURL: item.url, source: "Apple Maps",
            openStatus: "Check hours", lastCheckedText: "Hours not verified", distanceMiles: distance
        )
    }

    private func categoryName(_ category: MKPointOfInterestCategory?, fallback: String) -> String {
        guard let category else { return fallback }
        return switch category {
        case .restaurant: "Restaurant"
        case .cafe: "Cafe"
        case .bakery: "Bakery"
        case .museum: "Museum"
        case .theater: "Theater"
        case .movieTheater: "Cinema"
        case .park: "Park"
        case .library: "Library"
        case .fitnessCenter: "Fitness"
        case .store: "Shop"
        case .nightlife: "Nightlife"
        default: fallback
        }
    }

    private func emoji(for style: ActivityStyle) -> String { switch style { case .food: "🍽️"; case .entertainment: "🎟️"; case .nature: "🌿"; case .shopping: "🛍️"; case .learning: "📚"; case .workspaces: "💻"; case .fitness: "🏃"; case .arts: "🎨"; case .outdoor: "🌤️"; case .indoor: "✨" } }
    private func estimatedPriceLevel(for style: ActivityStyle) -> Int { [.nature, .outdoor, .learning].contains(style) ? 1 : 2 }
    private func estimatedCost(for style: ActivityStyle, priceLevel: Int) -> Double { if style == .nature || style == .outdoor { return 0 }; return priceLevel == 1 ? 10 : 20 }
    private func duration(for style: ActivityStyle) -> Int { style == .food ? 75 : style == .workspaces ? 120 : 90 }
    private func vibeTags(for style: ActivityStyle) -> [String] { switch style { case .nature, .learning: ["Quiet", "Relaxed", "Scenic"]; case .fitness, .entertainment: ["Energetic", "Lively", "Adventurous"]; case .workspaces: ["Focused", "Quiet", "Creative"]; default: ["Relaxed", "Local", "Easy"] } }
}

/// Uses local, curated data until a backend is configured. This makes the
/// app fully useful at zero API cost and gives us one safe seam for a future
/// Foursquare/Google adapter hosted behind a server-side key.
struct FreeFirstPlacesProvider: PlacesProvider {
    let configuration: ProviderConfiguration
    let fallback: PlacesProvider
    let localSearch: PlacesProvider

    init(configuration: ProviderConfiguration = .freeFirst, fallback: PlacesProvider = MockPlacesProvider(), localSearch: PlacesProvider = MapKitPlacesProvider()) {
        self.configuration = configuration
        self.fallback = fallback
        self.localSearch = localSearch
    }

    func places(for location: LocationResult, preferences: UserPreferences) async -> [Place] {
        // A backend is intentionally opt-in. Until we have an approved
        // endpoint, returning curated local data avoids network and billing.
        guard configuration.placesBackendURL != nil else {
            let nearby = await localSearch.places(for: location, preferences: preferences)
            guard nearby.isEmpty else { return nearby }
            let brooklyn = CLLocation(latitude: 40.6782, longitude: -73.9442)
            let requested = CLLocation(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude)
            return requested.distance(from: brooklyn) <= 40_000
                ? await fallback.places(for: location, preferences: preferences)
                : []
        }
        // The endpoint contract will be added with the first provider account.
        // Keep the fallback deterministic if the endpoint is unavailable.
        return await fallback.places(for: location, preferences: preferences)
    }
}

final class MockSubscriptionManager: SubscriptionManager, ObservableObject {
    @Published private(set) var state: SubscriptionStatus = .free
    func purchase() async throws { state = .trial(daysRemaining: 7) }
    func restore() async throws { state = .free }
}

@MainActor final class StoreKitSubscriptionManager: SubscriptionManager, ObservableObject {
    @Published private(set) var state: SubscriptionStatus = .free
    @Published private(set) var localizedPrice: String?
    @Published private(set) var trialDescription: String?
    @Published private(set) var isProductAvailable = false
    @Published private(set) var purchaseMessage: String?
    let productID: String
    private var product: Product?
    private var updatesTask: Task<Void, Never>?

    init(productID: String = SubscriptionConfiguration.productID) {
        self.productID = productID
        updatesTask = Task { [weak self] in
            for await result in Transaction.updates {
                await self?.handle(result)
            }
        }
    }

    deinit { updatesTask?.cancel() }

    func load() async {
        product = try? await Product.products(for: [productID]).first
        isProductAvailable = product != nil
        localizedPrice = product.map { "\($0.displayPrice)/month" } ?? SubscriptionConfiguration.fallbackDisplayPrice
        if let intro = product?.subscription?.introductoryOffer, intro.paymentMode == .freeTrial {
            trialDescription = "Free trial: \(intro.period.value) \(intro.period.unit)"
        }
        await refreshEntitlement()
    }

    func purchase() async throws {
        guard let product else { throw SubscriptionError.productUnavailable }
        purchaseMessage = nil
        let result = try await product.purchase()
        switch result {
        case .success(let verification):
            let transaction = try checkVerified(verification)
            await transaction.finish()
            state = .subscribed
            purchaseMessage = "Tonight Premium is active."
        case .userCancelled: purchaseMessage = "Purchase cancelled. No charge was made."
        case .pending:
            state = .pending
            purchaseMessage = "Purchase pending approval. Premium will unlock when Apple confirms it."
        @unknown default: break
        }
    }

    func restore() async throws {
        try await AppStore.sync()
        await refreshEntitlement()
        purchaseMessage = state.isPremium ? "Tonight Premium has been restored." : "No active Tonight Premium purchase was found."
    }

    private func refreshEntitlement() async {
        var foundEntitlement = false
        for await result in Transaction.currentEntitlements {
            guard let transaction = try? checkVerified(result), transaction.productID == productID else { continue }
            foundEntitlement = true
            state = transaction.revocationDate == nil ? .subscribed : .revoked
            if state == .revoked { return }
        }
        if !foundEntitlement {
            state = .free
            if let subscription = product?.subscription, let statuses = try? await subscription.status, let status = statuses.first {
                switch status.state {
                case .expired: state = .expired
                case .inBillingRetryPeriod, .inGracePeriod: state = .billingRetry
                case .revoked: state = .revoked
                default: break
                }
            }
        }
    }

    private func handle(_ result: VerificationResult<Transaction>) async {
        guard let transaction = try? checkVerified(result), transaction.productID == productID else { return }
        await transaction.finish()
        await refreshEntitlement()
    }

    #if DEBUG
    func setDebugOverride(_ status: SubscriptionStatus) { state = status }
    #endif

    private func checkVerified<T>(_ result: VerificationResult<T>) throws -> T {
        switch result { case .verified(let value): return value; case .unverified: throw SubscriptionError.unverifiedTransaction }
    }
}

enum SubscriptionError: LocalizedError {
    case unverifiedTransaction, productUnavailable
    var errorDescription: String? {
        switch self {
        case .unverifiedTransaction: "Apple could not verify this purchase. Please try again."
        case .productUnavailable: "Tonight Premium is not available from the App Store yet. Please try again later."
        }
    }
}

enum SubscriptionConfiguration { static let productID = "com.tonight.app.monthly"; static let fallbackDisplayPrice = "$2.99/month"; static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/"); static let privacyURL = URL(string: "https://tonight-privacy.n-k-innis92.chatgpt.site/") }

@MainActor final class EntitlementManager: ObservableObject {
    let storeKit: StoreKitSubscriptionManager
    var status: SubscriptionStatus { storeKit.state }
    var localizedPrice: String? { storeKit.localizedPrice }
    var trialDescription: String? { storeKit.trialDescription }
    init() { storeKit = StoreKitSubscriptionManager() }
    func load() async { await storeKit.load() }
    func purchase() async throws { try await storeKit.purchase() }
    func restore() async throws { try await storeKit.restore() }
    #if DEBUG
    func setDebugOverride(_ status: SubscriptionStatus?) { storeKit.setDebugOverride(status ?? .free) }
    #endif
}

@MainActor final class MonetizationManager: ObservableObject {
    let entitlementManager = EntitlementManager()
    let adsEligibilityService = AdEligibilityService()
    @Published private(set) var usage: WeeklyGenerationUsage
    @Published private(set) var isEntitlementLoaded = false
    // The provider seam is wired now; it returns the Debug sponsor preview
    // until the Google SDK and production unit ID are supplied.
    let adsProvider: AdsProvider = GoogleMobileAdsProvider()
    init() {
        if let data = UserDefaults.standard.data(forKey: "weeklyGenerationUsage"), let saved = try? JSONDecoder().decode(WeeklyGenerationUsage.self, from: data) {
            // Discard the old seven-day window when upgrading to the daily allowance.
            usage = saved.resetDate.timeIntervalSinceNow > 24 * 60 * 60 ? WeeklyGenerationUsage() : saved
        } else { usage = WeeklyGenerationUsage() }
        usage.prepareForUse()
    }
    var isPremium: Bool { entitlementManager.status.isPremium }
    var canGenerate: Bool { isPremium || usage.remaining > 0 }
    var remainingFreeGenerations: Int { isPremium ? .max : usage.remaining }
    var canShowAds: Bool {
        #if DEBUG
        isEntitlementLoaded && adsEligibilityService.canShowAds(for: entitlementManager.status)
        #else
        // No production ad SDK is wired yet; never present a mock sponsor as a real ad.
        false
        #endif
    }
    func load() async { await entitlementManager.load(); isEntitlementLoaded = true; persistUsage() }
    func consumeGeneration() -> Bool { if isPremium { return true }; guard usage.consume() else { return false }; persistUsage(); return true }
    func persistUsage() { if let data = try? JSONEncoder().encode(usage) { UserDefaults.standard.set(data, forKey: "weeklyGenerationUsage") } }
}

@MainActor final class AdEligibilityService { func canShowAds(for status: SubscriptionStatus) -> Bool { !status.isPremium } }

struct LocalSponsorProvider: AdsProvider {
    static let content = SponsorContent(id: "tonight-sponsor", label: "Sponsored", title: "Make room for a better workday", detail: "A calm workspace for your next focused session.", actionTitle: "Learn more", destination: URL(string: "https://maps.apple.com/?q=workspace"))
    private static let reportedKey = "reportedSponsorIDs"
    func sponsorContent() async -> SponsorContent? {
        let reported = Set(UserDefaults.standard.stringArray(forKey: Self.reportedKey) ?? [])
        return reported.contains(Self.content.id) ? nil : Self.content
    }
    func report(_ content: SponsorContent) {
        var reported = Set(UserDefaults.standard.stringArray(forKey: Self.reportedKey) ?? [])
        reported.insert(content.id)
        UserDefaults.standard.set(Array(reported), forKey: Self.reportedKey)
    }
}

struct GoogleMobileAdsProvider: AdsProvider {
    let configuration = AdsConfiguration.current
    func sponsorContent() async -> SponsorContent? { configuration.nativeUnitID == nil ? nil : await LocalSponsorProvider().sponsorContent() }
    func report(_ content: SponsorContent) { LocalSponsorProvider().report(content) }
}

struct NoopAnalyticsProvider: AnalyticsProvider { func track(_ event: AnalyticsEvent) {} }

struct MockRecommendationEngine: RecommendationEngine, Sendable {
    func plans(for preferences: UserPreferences, places: [Place]) async -> [EveningPlan] {
        var seenPlaces = Set<String>()
        let uniquePlaces = places.filter { place in
            let key = place.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seenPlaces.insert(key).inserted
        }
        let eligible = uniquePlaces.filter { place in
            guard (place.distanceMiles ?? 0) <= preferences.radiusMiles else { return false }
            guard let ceiling = preferences.budget.ceiling else { return true }
            return place.estimatedCost <= ceiling
        }
        let ranked = eligible.sorted { score($0, preferences) > score($1, preferences) }
        var usedPlaceIDs = Set<String>()
        var usedPrimaryCategories = Set<String>()
        var pairs: [(Place, Place?)] = []

        for place in ranked where pairs.count < 3 {
            guard !usedPlaceIDs.contains(place.id) else { continue }
            guard pairs.count == 2 || usedPrimaryCategories.insert(place.category).inserted else { continue }
            let second = ranked.first { candidate in
                guard candidate.id != place.id, !usedPlaceIDs.contains(candidate.id) else { return false }
                guard candidate.category != place.category else { return false }
                guard place.durationMinutes + candidate.durationMinutes <= preferences.minutesAvailable else { return false }
                guard let ceiling = preferences.budget.ceiling else { return true }
                return place.estimatedCost + candidate.estimatedCost <= ceiling
            }
            if let second { usedPlaceIDs.formUnion([place.id, second.id]) } else { usedPlaceIDs.insert(place.id) }
            pairs.append((place, second))
        }

        return pairs.enumerated().map { index, pair in
            let (place, second) = pair
            var stops = [PlanStop(id: "\(place.id)-1", startTime: "6:30 PM", place: place, note: "Ease into the evening with something that fits your pace.", cost: place.estimatedCost)]
            if let second { stops.append(PlanStop(id: "\(place.id)-2", startTime: "8:15 PM", place: second, note: "A natural next chapter, close enough to keep things easy.", cost: second.estimatedCost)) }
            let total = min(preferences.minutesAvailable, place.durationMinutes + (second?.durationMinutes ?? 0))
            var tags = Array(place.vibeTags.prefix(3)); if let editorialTag = place.editorialTag { tags.append(editorialTag) }
            let distance = max(place.distanceMiles ?? 0, second?.distanceMiles ?? 0)
            let description = second.map { "\(place.description) Then continue to \($0.name)." } ?? place.description
            return EveningPlan(id: "plan-\(place.id)-\(second?.id ?? "single")", title: title(for: place, preferences: preferences), description: description, stops: stops, tags: tags, totalCost: place.estimatedCost + (second?.estimatedCost ?? 0), totalMinutes: total, distanceMiles: distance > 0 ? distance : 1.2 + Double(index) * 0.5, travelMinutes: travelMinutes(for: distance, transport: preferences.transport), whyItFits: "Near \(preferences.locationName), with \(preferences.mood.rawValue.lowercased()) energy and a \(preferences.budget.rawValue.lowercased()) budget.", accent: ["coral", "indigo", "sage"][index])
        }
    }
    private func score(_ place: Place, _ p: UserPreferences) -> Int { var value = Int(place.rating * 10); value += p.styles.filter { place.activityTags.contains($0) }.count * 30; if let distance = place.distanceMiles { value += max(0, 24 - Int(distance * 8)) }; if p.mood == .adventurous && place.vibeTags.contains("Hidden gem") { value += 24 }; if p.mood == .quiet && place.vibeTags.contains("Quiet") { value += 24 }; if p.mood == .lively && place.vibeTags.contains("Lively") { value += 24 }; if p.social == .date && place.audienceTags.contains("Romantic") { value += 20 }; if p.social == .solo && place.audienceTags.contains("Solo-friendly") { value += 16 }; return value }
    private func travelMinutes(for distance: Double, transport: Transport) -> Int { let minutesPerMile: Double = switch transport { case .walking: 18; case .driving: 5; case .transit: 9; case .rideshare: 6 }; return max(5, Int(max(distance, 0.4) * minutesPerMile)) }
    private func title(for place: Place, preferences: UserPreferences) -> String { switch preferences.social { case .date: "A \(place.vibeTags.first?.lowercased() ?? "good") date night"; case .solo: "A reset, your way"; case .friends: "An easy night out"; case .family: "A night everyone can enjoy" } }
}

enum MockData {
    static let places: [Place] = [
        Place(id: "bar-lula", name: "Bar Lula", category: "Neighborhood restaurant", neighborhood: "Kensington", description: "A candlelit neighborhood spot for natural wine, small plates, and lingering conversations.", emoji: "🍷", rating: 4.8, priceLevel: 2, estimatedCost: 34, durationMinutes: 95, indoorOutdoor: "Indoor", vibeTags: ["Romantic", "Relaxed", "Hidden gem"], audienceTags: ["Romantic", "Solo-friendly"], activityTags: [.food, .indoor, .arts], mapURL: URL(string: "https://maps.apple.com/?q=Bar+Lula"), websiteURL: nil, source: "Tonight mock guide"),
        Place(id: "prospect-park", name: "Prospect Park Loop", category: "Park walk", neighborhood: "Prospect Park", description: "A breezy loop with wide paths, city views, and just enough room to let the day fall away.", emoji: "🌿", rating: 4.7, priceLevel: 0, estimatedCost: 0, durationMinutes: 70, indoorOutdoor: "Outdoor", vibeTags: ["Scenic", "Quiet", "Walkable"], audienceTags: ["Solo-friendly", "Romantic", "Family-friendly"], activityTags: [.nature, .outdoor, .fitness], mapURL: URL(string: "https://maps.apple.com/?q=Prospect+Park"), websiteURL: nil, source: "Tonight mock guide"),
        Place(id: "alamo", name: "Alamo Drafthouse", category: "Cinema & dinner", neighborhood: "Downtown Brooklyn", description: "A playful film night with comfy seats, a great menu, and no planning required.", emoji: "🎞️", rating: 4.6, priceLevel: 2, estimatedCost: 24, durationMinutes: 130, indoorOutdoor: "Indoor", vibeTags: ["Lively", "Casual", "Late-night"], audienceTags: ["Family-friendly", "Solo-friendly"], activityTags: [.entertainment, .indoor, .food], mapURL: URL(string: "https://maps.apple.com/?q=Alamo+Drafthouse+Brooklyn"), websiteURL: nil, source: "Tonight mock guide"),
        Place(id: "brooklyn-museum", name: "Brooklyn Museum Late", category: "Arts & culture", neighborhood: "Prospect Heights", description: "After-hours galleries, big rooms, and a little inspiration before the city gets loud.", emoji: "🎨", rating: 4.7, priceLevel: 1, estimatedCost: 18, durationMinutes: 105, indoorOutdoor: "Indoor", vibeTags: ["Creative", "Quiet", "Adventurous"], audienceTags: ["Solo-friendly", "Romantic"], activityTags: [.arts, .learning, .indoor], mapURL: URL(string: "https://maps.apple.com/?q=Brooklyn+Museum"), websiteURL: nil, source: "Tonight mock guide"),
        Place(id: "cafe-grumpy", name: "Cafe Grumpy", category: "Laptop-friendly café", neighborhood: "Greenpoint", description: "Bright tables, excellent coffee, and the kind of calm hum that makes a focused afternoon stretch into a good evening.", emoji: "☕️", rating: 4.6, priceLevel: 1, estimatedCost: 12, durationMinutes: 120, indoorOutdoor: "Indoor", vibeTags: ["Quiet", "Creative", "Late-night"], audienceTags: ["Solo-friendly", "Freelancer-friendly"], activityTags: [.workspaces, .food, .indoor], mapURL: URL(string: "https://maps.apple.com/?q=Cafe+Grumpy+Greenpoint"), websiteURL: nil, source: "Tonight mock guide"),
        Place(id: "industry-city", name: "Industry City Work Club", category: "Coworking lounge", neighborhood: "Sunset Park", description: "A spacious work lounge with fast Wi‑Fi, comfortable seating, and enough energy to keep a creative project moving.", emoji: "💻", rating: 4.7, priceLevel: 2, estimatedCost: 20, durationMinutes: 180, indoorOutdoor: "Indoor", vibeTags: ["Focused", "Lively", "Creative"], audienceTags: ["Solo-friendly", "Freelancer-friendly"], activityTags: [.workspaces, .learning, .indoor], mapURL: URL(string: "https://maps.apple.com/?q=Industry+City+Brooklyn"), websiteURL: nil, source: "Tonight mock guide")
        ,Place(id: "greenwood-cafe", name: "Greenwood Café", category: "Neighborhood café", neighborhood: "Greenwood", description: "A warm corner table, a strong pastry case, and a steady background hum for an unhurried reset.", emoji: "🥐", rating: 4.5, priceLevel: 1, estimatedCost: 14, durationMinutes: 90, indoorOutdoor: "Indoor", vibeTags: ["Relaxed", "Quiet", "Walkable"], audienceTags: ["Solo-friendly", "Family-friendly"], activityTags: [.food, .workspaces, .indoor], mapURL: URL(string: "https://maps.apple.com/?q=Greenwood+Cafe+Brooklyn"), websiteURL: nil, source: "Tonight mock guide", editorialTag: "90-minute night")
        ,Place(id: "brooklyn-boulders", name: "Brooklyn Boulders", category: "Climbing gym", neighborhood: "Gowanus", description: "A friendly climbing session that gives an energetic night a satisfying shape, even if you are brand new.", emoji: "🧗", rating: 4.6, priceLevel: 2, estimatedCost: 26, durationMinutes: 120, indoorOutdoor: "Indoor", vibeTags: ["Energetic", "Adventurous", "Lively"], audienceTags: ["Friends", "Solo-friendly"], activityTags: [.fitness, .indoor], mapURL: URL(string: "https://maps.apple.com/?q=Brooklyn+Boulders"), websiteURL: nil, source: "Tonight mock guide", editorialTag: "Try something new")
        ,Place(id: "smorgasburg", name: "Smorgasburg Evening", category: "Food market", neighborhood: "Williamsburg", description: "A choose-your-own-adventure dinner with waterfront air, lots of small bites, and an easy social rhythm.", emoji: "🍜", rating: 4.5, priceLevel: 1, estimatedCost: 22, durationMinutes: 110, indoorOutdoor: "Outdoor", vibeTags: ["Lively", "Casual", "Creative"], audienceTags: ["Friends", "Family-friendly"], activityTags: [.food, .outdoor, .shopping], mapURL: URL(string: "https://maps.apple.com/?q=Smorgasburg+Williamsburg"), websiteURL: nil, source: "Tonight mock guide", editorialTag: "Best with friends")
        ,Place(id: "brooklyn-botanic", name: "Brooklyn Botanic Garden", category: "Garden walk", neighborhood: "Crown Heights", description: "A slower loop through fragrant gardens and quiet paths for when you want the city to soften around you.", emoji: "🌸", rating: 4.8, priceLevel: 1, estimatedCost: 20, durationMinutes: 100, indoorOutdoor: "Outdoor", vibeTags: ["Scenic", "Quiet", "Relaxed"], audienceTags: ["Romantic", "Family-friendly", "Solo-friendly"], activityTags: [.nature, .outdoor, .learning], mapURL: URL(string: "https://maps.apple.com/?q=Brooklyn+Botanic+Garden"), websiteURL: nil, source: "Tonight mock guide", editorialTag: "Rainy-day pick")
        ,Place(id: "alamo-late", name: "Late Show at Alamo", category: "Late cinema", neighborhood: "Downtown Brooklyn", description: "A low-effort, high-reward late show with dinner, a good seat, and somewhere to be for two hours.", emoji: "🍿", rating: 4.4, priceLevel: 2, estimatedCost: 28, durationMinutes: 150, indoorOutdoor: "Indoor", vibeTags: ["Lively", "Casual", "Late-night"], audienceTags: ["Solo-friendly", "Date"], activityTags: [.entertainment, .indoor, .food], mapURL: URL(string: "https://maps.apple.com/?q=Alamo+Drafthouse+Brooklyn"), websiteURL: nil, source: "Tonight mock guide", editorialTag: "Easy win")
        ,Place(id: "book-thug", name: "Book Thug Nation", category: "Used bookstore", neighborhood: "Bushwick", description: "Browse strange paperbacks, trade recommendations, and make a small night out of getting pleasantly lost.", emoji: "📚", rating: 4.6, priceLevel: 1, estimatedCost: 10, durationMinutes: 75, indoorOutdoor: "Indoor", vibeTags: ["Hidden gem", "Quiet", "Creative"], audienceTags: ["Solo-friendly", "Romantic"], activityTags: [.shopping, .learning, .indoor], mapURL: URL(string: "https://maps.apple.com/?q=Book+Thug+Nation"), websiteURL: nil, source: "Tonight mock guide", editorialTag: "Hidden gem")
        ,Place(id: "union-pool", name: "Union Pool", category: "Music venue", neighborhood: "Williamsburg", description: "A small-room show with enough edge to feel like a discovery and enough room to keep the night loose.", emoji: "🎸", rating: 4.4, priceLevel: 2, estimatedCost: 25, durationMinutes: 140, indoorOutdoor: "Indoor", vibeTags: ["Lively", "Adventurous", "Late-night"], audienceTags: ["Friends", "Solo-friendly"], activityTags: [.entertainment, .arts, .indoor], mapURL: URL(string: "https://maps.apple.com/?q=Union+Pool+Brooklyn"), websiteURL: nil, source: "Tonight mock guide", editorialTag: "Local favorite")
        ,Place(id: "red-hook-pier", name: "Red Hook Waterfront", category: "Waterfront walk", neighborhood: "Red Hook", description: "Wide-open harbor views, a little wind, and the kind of walk that makes an ordinary weeknight feel cinematic.", emoji: "🌆", rating: 4.7, priceLevel: 0, estimatedCost: 0, durationMinutes: 85, indoorOutdoor: "Outdoor", vibeTags: ["Scenic", "Quiet", "Adventurous"], audienceTags: ["Romantic", "Solo-friendly"], activityTags: [.nature, .outdoor, .fitness], mapURL: URL(string: "https://maps.apple.com/?q=Red+Hook+Waterfront"), websiteURL: nil, source: "Tonight mock guide", editorialTag: "Best sunset")
    ]
}

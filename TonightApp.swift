import SwiftUI
import Combine

@main struct TonightApp: App {
    @StateObject private var app = AppModel()
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let screen = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--tonight-preview=") })?.split(separator: "=").last.map(String.init) {
                DebugScreenPreview(screen: screen)
            } else {
                RootView().environmentObject(app)
            }
            #else
            RootView().environmentObject(app)
            #endif
        }
    }
}

#if DEBUG
@MainActor private struct DebugScreenPreview: View {
    @StateObject private var app: AppModel
    let screen: String

    init(screen: String) {
        self.screen = screen
        let model = AppModel()
        model.plans = [Self.samplePlan]
        model.savedPlans = [Self.samplePlan]
        model.collections[0].planIDs = [Self.samplePlan.id]
        if screen.hasPrefix("setup") { model.setupStep = Int(screen.dropFirst(5)) ?? 0 }
        _app = StateObject(wrappedValue: model)
    }

    var body: some View {
        Group {
            switch screen {
            case "welcome": WelcomeView()
            case "setup0", "setup1", "setup2", "setup3": SetupView()
            case "loading": LoadingView()
            case "discover": DiscoverView()
            case "main": MainTabView()
            case "detail": NavigationStack { PlanDetailView(plan: Self.samplePlan) }
            case "saved": SavedView()
            case "profile": ProfileView()
            case "paywall": PaywallView(subscription: app.monetization.entitlementManager.storeKit)
            case "feedback": FeedbackSheet(plan: Self.samplePlan)
            default: RootView()
            }
        }
        .environmentObject(app)
        .preferredColorScheme(screen == "loading" ? .dark : .light)
    }

    private static let samplePlan: EveningPlan = {
        let place = Place(
            id: "preview-cafe", name: "Greenwood Café", category: "Neighborhood café",
            neighborhood: "Brooklyn", description: "A warm corner table and good coffee.",
            emoji: "☕️", rating: 4.5, priceLevel: 1, estimatedCost: 14,
            durationMinutes: 90, indoorOutdoor: "Indoor", vibeTags: ["Relaxed"],
            audienceTags: ["Solo-friendly"], activityTags: [.food, .workspaces],
            mapURL: URL(string: "https://maps.apple.com/?q=Greenwood+Cafe+Brooklyn"),
            websiteURL: nil, source: "Tonight mock guide"
        )
        return EveningPlan(
            id: "preview-plan", title: "A slower Brooklyn evening",
            description: "Coffee, a little work, and room to unwind.",
            stops: [PlanStop(id: "preview-stop", startTime: "6:30 PM", place: place,
                             note: "Settle in and take your time.", cost: 14)],
            tags: ["Relaxed", "Solo-friendly"], totalCost: 14, totalMinutes: 90,
            distanceMiles: 1.2, travelMinutes: 12,
            whyItFits: "An easygoing evening that fits your mood", accent: "sage"
        )
    }()
}
#endif

@MainActor final class AppModel: ObservableObject {
    @Published var preferences = UserPreferences()
    @Published var plans: [EveningPlan] = []
    @Published var savedPlans: [EveningPlan] = []
    @Published var hasStarted = false
    @Published var isLoading = false
    @Published var loadingMessage = "Finding places that match your mood"
    @Published var selectedPlan: EveningPlan?
    @Published var showPaywall = false
    @Published var setupStep = 0
    @Published var feedbackByPlan: [String: PlanFeedback] = [:]
    @Published var feedbackPlan: EveningPlan?
    @Published var selectedTab = 0
    @Published var showMainTabs = false
    @Published var locationMessage = "Using Brooklyn, NY"
    @Published var generationError: String?
    @Published var collections: [SavedCollection] = [SavedCollection(id: "favorites", name: "Favorites", planIDs: [])]
    let monetization = MonetizationManager()
    private var observation = Set<AnyCancellable>()
    let engine: RecommendationEngine = MockRecommendationEngine(); let analytics: AnalyticsProvider = NoopAnalyticsProvider()
    let placesProvider: PlacesProvider = FreeFirstPlacesProvider()
    let locationProvider: LocationProvider = CoreLocationProvider()
    private var resolvedLocation: LocationResult?
    init() {
        monetization.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observation)
        monetization.entitlementManager.storeKit.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &observation)
        if let data = UserDefaults.standard.data(forKey: "savedPlans"), let saved = try? JSONDecoder().decode([EveningPlan].self, from: data) {
            savedPlans = saved
            collections[0].planIDs = saved.map(\.id)
        }
    }
    func generate() async {
        if !monetization.isEntitlementLoaded { await monetization.load() }
        guard monetization.canGenerate else { showPaywall = true; return }
        generationError = nil
        isLoading = true
        defer { isLoading = false }
        analytics.track(.recommendationRequested)
        let messages = ["Finding places near \(preferences.locationName)", "Checking distance and timing", "Building a better evening"]
        for message in messages { loadingMessage = message; try? await Task.sleep(for: .milliseconds(420)) }
        guard let location = await resolveStartingLocation() else {
            setupStep = 0
            generationError = "We couldn’t find \(preferences.locationName). Try a nearby city, neighborhood, or ZIP code. Your free plan was not used."
            return
        }
        let places = await placesProvider.places(for: location, preferences: preferences)
        let freshPlans = await engine.plans(for: preferences, places: places)
        guard !freshPlans.isEmpty else {
            setupStep = 0
            generationError = "We couldn’t find a good plan within \(Int(preferences.radiusMiles)) miles of \(preferences.locationName). Try widening the distance range, choosing another activity, or searching a nearby neighborhood. Your free plan was not used."
            return
        }
        _ = monetization.consumeGeneration()
        plans = freshPlans.sorted { feedbackAdjustment(for: $0) > feedbackAdjustment(for: $1) }
        showMainTabs = true
        selectedTab = 0
    }
    func toggleSave(_ plan: EveningPlan) { if let index = savedPlans.firstIndex(of: plan) { savedPlans.remove(at: index); collections[0].planIDs.removeAll { $0 == plan.id } } else { savedPlans.append(plan); collections[0].planIDs.append(plan.id); analytics.track(.planSaved) }; if let data = try? JSONEncoder().encode(savedPlans) { UserDefaults.standard.set(data, forKey: "savedPlans") } }
    func isSaved(_ plan: EveningPlan) -> Bool { savedPlans.contains(plan) }
    func recordFeedback(_ feedback: PlanFeedback, for plan: EveningPlan) { feedbackByPlan[plan.id] = feedback; analytics.track(.feedbackSubmitted) }
    func editPreferences() { plans = []; setupStep = 0; generationError = nil; showMainTabs = false }
    func openSavedPlans() { hasStarted = true; showMainTabs = true; selectedTab = 1 }
    func locationNameChanged() { if resolvedLocation?.name != preferences.locationName { resolvedLocation = nil; generationError = nil; locationMessage = "Using \(preferences.locationName)" } }
    private func feedbackAdjustment(for plan: EveningPlan) -> Int { switch feedbackByPlan[plan.id] { case .wouldDoThis: 20; case .tooExpensive: plan.totalCost > 25 ? -20 : 8; case .tooFar: plan.distanceMiles > 2.5 ? -20 : 8; case .tooQuiet: plan.tags.contains("Quiet") ? -15 : 8; case .notInteresting: plan.tags.contains("Creative") || plan.tags.contains("Adventurous") ? -15 : 8; case .none: 0 } }
    func useCurrentLocation() async {
        do { let result = try await locationProvider.requestCurrentLocation(); resolvedLocation = result; generationError = nil; preferences.locationName = result.name; locationMessage = "Using your approximate location" }
        catch { locationMessage = "Location unavailable — you can search manually" }
    }
    private func resolveStartingLocation() async -> LocationResult? {
        if let resolvedLocation, resolvedLocation.name == preferences.locationName { return resolvedLocation }
        if let searched = await locationProvider.search(preferences.locationName).first { resolvedLocation = LocationResult(name: preferences.locationName, coordinate: searched.coordinate); return resolvedLocation! }
        return nil
    }
}

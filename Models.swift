import Foundation
import CoreLocation

enum SocialSetting: String, CaseIterable, Codable, Identifiable {
    case solo = "Solo", date = "Date", friends = "Friends", family = "Family"
    var id: String { rawValue }
    var symbol: String { switch self { case .solo: "person.fill"; case .date: "heart.fill"; case .friends: "person.2.fill"; case .family: "figure.2.and.child.holdinghands" } }
}

enum ActivityStyle: String, CaseIterable, Codable, Identifiable {
    case indoor = "Indoor", outdoor = "Outdoor", food = "Food", entertainment = "Entertainment", nature = "Nature", shopping = "Shopping", learning = "Learning", workspaces = "Workspaces", fitness = "Fitness", arts = "Arts & culture"
    var id: String { rawValue }
    var symbol: String { switch self { case .indoor: "lamp.floor"; case .outdoor: "sun.max.fill"; case .food: "fork.knife"; case .entertainment: "ticket.fill"; case .nature: "leaf.fill"; case .shopping: "bag.fill"; case .learning: "book.fill"; case .workspaces: "laptopcomputer"; case .fitness: "figure.run"; case .arts: "paintpalette.fill" } }
}

enum Mood: String, CaseIterable, Codable, Identifiable {
    case relaxed = "Relaxed", energetic = "Energetic", quiet = "Quiet", lively = "Lively", familiar = "Familiar", adventurous = "Adventurous", casual = "Casual", upscale = "Upscale"
    var id: String { rawValue }
    var tint: String { switch self { case .relaxed, .quiet: "sage"; case .energetic, .lively: "coral"; case .familiar, .casual: "indigo"; case .adventurous, .upscale: "gold" } }
}

enum Budget: String, CaseIterable, Codable, Identifiable {
    case free = "Free", under25 = "Under $25", under50 = "Under $50", flexible = "Flexible"
    var id: String { rawValue }
    var ceiling: Double? { switch self { case .free: 0; case .under25: 25; case .under50: 50; case .flexible: nil } }
}

enum Transport: String, CaseIterable, Codable, Identifiable { case walking = "Walking", driving = "Driving", transit = "Transit", rideshare = "Rideshare"; var id: String { rawValue }; var symbol: String { switch self { case .walking: "figure.walk"; case .driving: "car.fill"; case .transit: "tram.fill"; case .rideshare: "car.2.fill" } } }

struct UserPreferences: Equatable, Codable {
    var locationName = "Brooklyn, NY"
    var social: SocialSetting = .date
    /// Activity directions to combine. The setup flow caps this at two.
    var styles: [ActivityStyle] = [.food]
    var style: ActivityStyle {
        get { styles.first ?? .food }
        set { styles = [newValue] }
    }
    var mood: Mood = .relaxed
    var budget: Budget = .under50
    var minutesAvailable = 180
    var radiusMiles = 3.0
    var transport: Transport = .walking
    init(locationName: String = "Brooklyn, NY", social: SocialSetting = .date, style: ActivityStyle = .food, mood: Mood = .relaxed, budget: Budget = .under50, minutesAvailable: Int = 180, radiusMiles: Double = 3.0, transport: Transport = .walking) {
        self.locationName = locationName; self.social = social; self.styles = [style]; self.mood = mood; self.budget = budget; self.minutesAvailable = minutesAvailable; self.radiusMiles = radiusMiles; self.transport = transport
    }
    mutating func toggleStyle(_ style: ActivityStyle) {
        if let index = styles.firstIndex(of: style) {
            guard styles.count > 1 else { return }
            styles.remove(at: index)
        } else if styles.count < 2 {
            styles.append(style)
        }
    }
}

struct Place: Identifiable, Codable, Equatable, Hashable {
    let id: String; let name: String; let category: String; let neighborhood: String; let description: String; let emoji: String; let rating: Double; let priceLevel: Int; let estimatedCost: Double; let durationMinutes: Int; let indoorOutdoor: String; let vibeTags: [String]; let audienceTags: [String]; let activityTags: [ActivityStyle]; let mapURL: URL?; let websiteURL: URL?; let source: String; let openStatus: String; let lastCheckedText: String; let editorialTag: String?; let distanceMiles: Double?
    init(id: String, name: String, category: String, neighborhood: String, description: String, emoji: String, rating: Double, priceLevel: Int, estimatedCost: Double, durationMinutes: Int, indoorOutdoor: String, vibeTags: [String], audienceTags: [String], activityTags: [ActivityStyle], mapURL: URL?, websiteURL: URL?, source: String, openStatus: String = "Check hours", lastCheckedText: String = "Hours not verified", editorialTag: String? = nil, distanceMiles: Double? = nil) { self.id = id; self.name = name; self.category = category; self.neighborhood = neighborhood; self.description = description; self.emoji = emoji; self.rating = rating; self.priceLevel = priceLevel; self.estimatedCost = estimatedCost; self.durationMinutes = durationMinutes; self.indoorOutdoor = indoorOutdoor; self.vibeTags = vibeTags; self.audienceTags = audienceTags; self.activityTags = activityTags; self.mapURL = mapURL; self.websiteURL = websiteURL; self.source = source; self.openStatus = openStatus; self.lastCheckedText = lastCheckedText; self.editorialTag = editorialTag; self.distanceMiles = distanceMiles }
}

struct PlanStop: Identifiable, Codable, Equatable, Hashable { let id: String; let startTime: String; let place: Place; let note: String; let cost: Double }
struct EveningPlan: Identifiable, Codable, Equatable, Hashable { let id: String; let title: String; let description: String; let stops: [PlanStop]; let tags: [String]; let totalCost: Double; let totalMinutes: Int; let distanceMiles: Double; let travelMinutes: Int; let whyItFits: String; let accent: String }
enum PlanFeedback: String, CaseIterable, Identifiable { case tooExpensive = "Too expensive", tooFar = "Too far", tooQuiet = "Too quiet", notInteresting = "Not interesting", wouldDoThis = "I’d do this"; var id: String { rawValue } }
struct SavedCollection: Identifiable, Equatable { let id: String; var name: String; var planIDs: [String] }

struct LocationResult: Equatable { let name: String; let coordinate: CLLocationCoordinate2D
    static func == (lhs: LocationResult, rhs: LocationResult) -> Bool { lhs.name == rhs.name && lhs.coordinate.latitude == rhs.coordinate.latitude && lhs.coordinate.longitude == rhs.coordinate.longitude }
}

enum SubscriptionStatus: Equatable { case free, trial(daysRemaining: Int), subscribed, pending, expired, billingRetry, revoked
    var isPremium: Bool { switch self { case .trial, .subscribed: true; default: false } }
}

struct WeeklyGenerationUsage: Codable, Equatable {
    static let freeLimit = 3
    var generationCount: Int = 0
    var resetDate: Date = WeeklyGenerationUsage.nextResetDate(from: .now)
    var remaining: Int { max(0, Self.freeLimit - generationCount) }
    var isResetDue: Bool { Date.now >= resetDate }
    mutating func prepareForUse(now: Date = .now) { if now >= resetDate { generationCount = 0; resetDate = Self.nextResetDate(from: now) } }
    mutating func consume(now: Date = .now) -> Bool { prepareForUse(now: now); guard generationCount < Self.freeLimit else { return false }; generationCount += 1; return true }
    static func nextResetDate(from date: Date) -> Date { Calendar.current.date(byAdding: .day, value: 1, to: date) ?? date.addingTimeInterval(24 * 60 * 60) }
}

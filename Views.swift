import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject private var app: AppModel
    // The visual system uses fixed cream surfaces and ink text. Keep system controls,
    // secondary text, sheets, and navigation chrome in the matching light appearance.
    var body: some View { Group { if !app.hasStarted { WelcomeView() } else if app.isLoading { LoadingView() } else if app.plans.isEmpty && !app.showMainTabs { SetupView() } else { MainTabView() } }.preferredColorScheme(app.isLoading ? .dark : .light).sheet(isPresented: $app.showPaywall) { PaywallView(subscription: app.monetization.entitlementManager.storeKit) } }
}

struct WelcomeView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View { GeometryReader { proxy in ZStack { Color.nightPaper.ignoresSafeArea(); ScrollView { VStack(alignment: .leading, spacing: 0) { Group { if dynamicTypeSize.isAccessibilitySize { VStack(alignment: .leading, spacing: 18) { BrandMark(); Text("A better evening starts here.").font(.caption.weight(.medium)).foregroundStyle(Color.nightMutedInk) } } else { HStack { BrandMark(); Spacer(); Text("A better evening\nstarts here.").font(.caption.weight(.medium)).multilineTextAlignment(.trailing).foregroundStyle(Color.nightMutedInk) } } }.padding(.bottom, 48); Spacer(minLength: 28); Text("What should\nwe do tonight?").font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(Color.nightInk); Text("A little inspiration, tailored to your mood, time, and the people you’re with.").font(.title3).foregroundStyle(Color.nightInk.opacity(0.65)).padding(.top, 22); Spacer(minLength: 28); PlanPreviewCard(); PrimaryButton(title: "Plan my evening") { app.hasStarted = true }.padding(.top, 24); if !app.savedPlans.isEmpty { Button { app.openSavedPlans() } label: { Label("View saved plans", systemImage: "bookmark.fill").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14).foregroundStyle(Color.nightCoral) }.buttonStyle(.plain).accessibilityHint("Opens plans saved on this device") } }.padding(24).frame(minHeight: proxy.size.height) } } } }
}

struct PlanPreviewCard: View { var body: some View { HStack(alignment: .top, spacing: 16) { Text("✦").font(.title).foregroundStyle(Color.nightCoral); VStack(alignment: .leading, spacing: 9) { Text("A slow-burn date night").font(.headline); Text("Natural wine → gallery walk → late dessert").font(.subheadline).foregroundStyle(Color.nightMutedInk); ViewThatFits(in: .horizontal) { HStack { Pill(text: "Relaxed", tint: .nightCoral); Pill(text: "$42", tint: .nightIndigo) }; VStack(alignment: .leading) { Pill(text: "Relaxed", tint: .nightCoral); Pill(text: "$42", tint: .nightIndigo) } } }; Spacer() }.padding(20).background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 24, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.nightInk.opacity(0.06))) }
}

struct SetupView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var optionColumns: [GridItem] { dynamicTypeSize.isAccessibilitySize ? [GridItem(.flexible())] : [GridItem(.flexible()), GridItem(.flexible())] }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack {
                        Button {
                            if app.setupStep > 0 { withAnimation { app.setupStep -= 1 } } else { app.hasStarted = false }
                        } label: {
                            Image(systemName: app.setupStep > 0 ? "arrow.left" : "xmark").font(.headline).padding(10).background(Color.white.opacity(0.7), in: Circle())
                        }
                        .foregroundStyle(Color.nightCoral)
                        .accessibilityLabel(app.setupStep > 0 ? "Previous step" : "Close setup")
                        Spacer()
                        Text("\(app.setupStep + 1) of 4").font(.caption.weight(.semibold)).foregroundStyle(Color.nightMutedInk)
                    }
                    ProgressView(value: Double(app.setupStep + 1), total: 4).tint(Color.nightCoral)
                    Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold))
                    Text(subtitle).foregroundStyle(Color.nightMutedInk)
                    if let error = app.generationError {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(.subheadline).foregroundStyle(Color.nightIndigo)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.nightIndigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Plan generation issue. \(error)")
                    }
                    content
                    Spacer(minLength: 20)
                    PrimaryButton(title: app.setupStep == 3 ? "Show my plans" : "Continue") {
                        if app.setupStep == 3 { Task { await app.generate() } } else { withAnimation { app.setupStep += 1 } }
                    }
                }.padding(24)
            }
            .background(Color.nightPaper.ignoresSafeArea())
            .navigationBarHidden(true)
        }
    }

    private var title: String { ["Where are you starting?", "Who’s joining?", "What sounds good?", "Set the vibe"][app.setupStep] }
    private var subtitle: String { ["Use your approximate location or search a neighborhood. We’ll look for options nearby.", "Choose the energy of your evening.", "Choose up to two directions and we’ll find the connective tissue between them.", "A few final details, then we’ll make the plan."][app.setupStep] }

    @ViewBuilder private var content: some View {
        switch app.setupStep {
        case 0:
            VStack(spacing: 12) {
                SelectionCard(title: app.locationMessage, icon: "location.fill", selected: app.locationMessage.contains("approximate")) { Task { await app.useCurrentLocation() } }
                HStack { Image(systemName: "magnifyingglass"); TextField("Search a city or neighborhood", text: $app.preferences.locationName) }
                    .padding().background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
                    .onChange(of: app.preferences.locationName) { _, _ in app.locationNameChanged() }
            }
        case 1:
            LazyVGrid(columns: optionColumns, spacing: 12) {
                ForEach(SocialSetting.allCases) { item in SelectionCard(title: item.rawValue, icon: item.symbol, selected: app.preferences.social == item) { app.preferences.social = item } }
            }
        case 2:
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Pick up to two").font(.headline)
                    Spacer()
                    Text("\(app.preferences.styles.count) of 2").font(.caption.weight(.semibold)).foregroundStyle(Color.nightCoral)
                }
                LazyVGrid(columns: optionColumns, spacing: 12) {
                    ForEach(ActivityStyle.allCases) { item in
                        SelectionCard(title: item.rawValue, icon: item.symbol, selected: app.preferences.styles.contains(item)) {
                            app.preferences.toggleStyle(item)
                        }
                        .accessibilityValue(app.preferences.styles.contains(item) ? "Selected" : "Not selected")
                        .accessibilityHint(app.preferences.styles.contains(item) && app.preferences.styles.count == 1 ? "At least one direction is required" : app.preferences.styles.count == 2 && !app.preferences.styles.contains(item) ? "Two directions already selected" : "Select or deselect this direction")
                    }
                }
                Text("Mix and match ideas like Food + Workspaces or Nature + Arts & culture.")
                    .font(.caption)
                    .foregroundStyle(Color.nightMutedInk)
            }
        default:
            VStack(alignment: .leading, spacing: 20) {
                Text("Mood").font(.headline)
                LazyVGrid(columns: optionColumns, spacing: 10) {
                    ForEach(Mood.allCases) { item in MoodOption(title: item.rawValue, selected: app.preferences.mood == item) { app.preferences.mood = item } }
                }
                Text("Budget").font(.headline)
                if dynamicTypeSize.isAccessibilitySize {
                    Picker("Budget", selection: $app.preferences.budget) { ForEach(Budget.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.menu).tint(Color.nightCoral)
                } else {
                    Picker("Budget", selection: $app.preferences.budget) { ForEach(Budget.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented)
                }
                Text("How will you get around?").font(.headline)
                LazyVGrid(columns: optionColumns, spacing: 10) {
                    ForEach(Transport.allCases) { item in
                        Button { app.preferences.transport = item } label: { VStack(spacing: 8) { Image(systemName: item.symbol); Text(item.rawValue).font(.caption) }.frame(maxWidth: .infinity).padding(.vertical, 12).background(app.preferences.transport == item ? Color.nightInk : Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 14)).foregroundStyle(app.preferences.transport == item ? Color.nightPaper : Color.nightInk) }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("How far do you want to go?").font(.headline)
                        Spacer()
                        Text("\(Int(app.preferences.radiusMiles)) mi").font(.subheadline.weight(.semibold)).foregroundStyle(Color.nightCoral)
                    }
                    Slider(value: $app.preferences.radiusMiles, in: 1...25, step: 1)
                        .tint(Color.nightCoral)
                        .accessibilityLabel("Maximum distance")
                        .accessibilityValue("\(Int(app.preferences.radiusMiles)) miles")
                    Text("Plans are searched and filtered within this range of your starting point.")
                        .font(.caption)
                        .foregroundStyle(Color.nightMutedInk)
                }
            }
        }
    }
}

struct LoadingView: View { @EnvironmentObject private var app: AppModel; var body: some View { ZStack { Color.nightInk.ignoresSafeArea(); VStack(spacing: 28) { ZStack { Circle().stroke(Color.nightPaper.opacity(0.18), lineWidth: 2).frame(width: 92, height: 92); Circle().trim(from: 0, to: 0.7).stroke(Color.nightCoral, style: StrokeStyle(lineWidth: 5, lineCap: .round)).frame(width: 92, height: 92).rotationEffect(.degrees(-90)); Text("✦").font(.title).foregroundStyle(Color.nightGold) }.accessibilityLabel("Building your evening plan"); Text(app.loadingMessage).font(.title3.weight(.semibold)).foregroundStyle(Color.nightPaper); Text("Taking a thoughtful minute.").font(.subheadline).foregroundStyle(Color.nightPaper.opacity(0.55)) } } }
}

struct MainTabView: View { @EnvironmentObject private var app: AppModel; var body: some View { TabView(selection: $app.selectedTab) { DiscoverView().tabItem { Label("Tonight", systemImage: "sparkles") }.tag(0); SavedView().tabItem { Label("Saved", systemImage: "bookmark") }.tag(1); ProfileView().tabItem { Label("Profile", systemImage: "person.crop.circle") }.tag(2) }.tint(Color.nightCoral) } }

struct DiscoverView: View { @EnvironmentObject private var app: AppModel; var body: some View { NavigationStack { ScrollView { VStack(alignment: .leading, spacing: 22) { HStack { Button { app.editPreferences() } label: { Label("Start over", systemImage: "chevron.left").font(.subheadline.weight(.semibold)).foregroundStyle(Color.nightCoral).padding(.vertical, 10).padding(.horizontal, 12).background(Color.white.opacity(0.72), in: Capsule()) }.buttonStyle(.plain).accessibilityHint("Returns to location and preference setup"); Spacer(); if !app.plans.isEmpty { Button { Task { await app.generate() } } label: { Image(systemName: "arrow.clockwise").font(.headline).foregroundStyle(Color.nightCoral).padding(10).background(.white.opacity(0.7), in: Circle()) }.accessibilityLabel("Refresh plans") } }; BrandMark(); if app.plans.isEmpty { ContentUnavailableView { Label("Ready for a new evening?", systemImage: "sparkles") } description: { Text("Your saved plans are still available. Start over when you want fresh ideas.") } actions: { Button("Build a new plan") { app.editPreferences() }.buttonStyle(.borderedProminent).tint(Color.nightCoral) } } else { VStack(alignment: .leading, spacing: 6) { Text("Good evening.").font(.subheadline).foregroundStyle(Color.nightMutedInk); Text("Here’s your night.").font(.system(.largeTitle, design: .rounded, weight: .bold)) }; VStack(alignment: .leading, spacing: 8) { Pill(text: "Near \(app.preferences.locationName)", tint: .nightIndigo); Pill(text: app.preferences.mood.rawValue, tint: .nightCoral) }; Text("Nearby recommendations from Apple Maps when available. Check hours, prices, and travel before you go.").font(.caption).foregroundStyle(Color.nightMutedInk); if !app.monetization.isPremium { Text("\(app.monetization.remainingFreeGenerations) free plans left today").font(.caption.weight(.medium)).foregroundStyle(Color.nightMutedInk) }; ForEach(Array(app.plans.enumerated()), id: \.element.id) { index, plan in PlanCard(plan: plan) { app.selectedPlan = plan }; if index == 0 && app.monetization.canShowAds { SponsorCard(provider: app.monetization.adsProvider) } } } }.padding(20) }.background(Color.nightPaper.ignoresSafeArea()).navigationDestination(item: $app.selectedPlan) { PlanDetailView(plan: $0) } } }
}

struct PlanCard: View {
    @EnvironmentObject private var app: AppModel
    let plan: EveningPlan
    let action: () -> Void
    private var isSample: Bool { plan.stops.first?.place.source == "Tonight mock guide" }
    private var hoursText: String { isSample ? "Check hours" : (plan.stops.first?.place.openStatus ?? "Check hours") }
    private var timingText: String { isSample ? "Hours not verified" : (plan.stops.first?.place.lastCheckedText ?? "Source timing") }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(plan.stops.first?.place.emoji ?? "✦").font(.system(size: 44))
                Spacer()
                Button { app.toggleSave(plan) } label: { Image(systemName: app.isSaved(plan) ? "bookmark.fill" : "bookmark").font(.title3).padding(10).background(.white.opacity(0.6), in: Circle()) }
                    .accessibilityLabel(app.isSaved(plan) ? "Remove saved plan" : "Save plan")
            }
            Text(plan.title).font(.title2.weight(.bold)).padding(.top, 20)
            Text(plan.description).font(.subheadline).foregroundStyle(Color.nightMutedInk).padding(.top, 7)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { ForEach(plan.tags, id: \.self) { Pill(text: $0) } }
                VStack(alignment: .leading, spacing: 8) { ForEach(plan.tags, id: \.self) { Pill(text: $0) } }
            }.padding(.top, 16)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Label(hoursText, systemImage: "clock"); Text("·"); Text(timingText) }
                VStack(alignment: .leading, spacing: 6) { Label(hoursText, systemImage: "clock"); Text(timingText) }
            }.font(.caption.weight(.medium)).foregroundStyle(Color.nightIndigo).padding(.top, 14)
            Divider().padding(.vertical, 16)
            ViewThatFits(in: .horizontal) {
                HStack { Label("$\(Int(plan.totalCost))", systemImage: "dollarsign.circle"); Label("\(plan.totalMinutes)m", systemImage: "clock"); Label("\(String(format: "%.1f", plan.distanceMiles)) mi", systemImage: "location") }
                VStack(alignment: .leading, spacing: 6) { Label("$\(Int(plan.totalCost))", systemImage: "dollarsign.circle"); Label("\(plan.totalMinutes)m", systemImage: "clock"); Label("\(String(format: "%.1f", plan.distanceMiles)) mi", systemImage: "location") }
            }.font(.caption.weight(.medium))
            Button("View plan", action: action).font(.headline).foregroundStyle(Color.nightCoral).padding(.top, 18)
        }
        .padding(20)
        .background(plan.accent == "coral" ? Color.nightCoral.opacity(0.13) : plan.accent == "indigo" ? Color.nightIndigo.opacity(0.12) : Color.nightSage.opacity(0.25), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }
}

struct PlanDetailView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let plan: EveningPlan
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text(plan.stops.first?.place.emoji ?? "✦").font(.system(size: 62))
                Text(plan.title).font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text(plan.description).font(.title3).foregroundStyle(Color.nightMutedInk)
                Pill(text: plan.whyItFits, tint: .nightCoral)
                Text("Your evening").font(.title2.bold())
                ForEach(plan.stops) { stop in
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            Text(stop.startTime).font(.caption.weight(.bold)).frame(width: 58, alignment: .leading)
                            stopDetails(stop)
                            Spacer()
                        }
                        VStack(alignment: .leading, spacing: 8) {
                            Text(stop.startTime).font(.caption.weight(.bold))
                            stopDetails(stop)
                        }
                    }
                }
                ViewThatFits(in: .horizontal) {
                    HStack { Label("$\(Int(plan.totalCost)) total", systemImage: "dollarsign.circle"); Label("\(plan.travelMinutes) min travel", systemImage: "figure.walk") }
                    VStack(alignment: .leading, spacing: 8) { Label("$\(Int(plan.totalCost)) total", systemImage: "dollarsign.circle"); Label("\(plan.travelMinutes) min travel", systemImage: "figure.walk") }
                }.font(.subheadline.weight(.semibold))
                Text("Preview estimate: confirm hours, prices, and travel before visiting.")
                    .font(.caption).foregroundStyle(Color.nightMutedInk)
                VStack(spacing: 10) {
                    ForEach(plan.stops) { stop in
                        Button { open(stop.place.mapURL) } label: {
                            Label("Open \(stop.place.name) in Apple Maps", systemImage: "map.fill")
                                .frame(maxWidth: .infinity).padding()
                                .background(Color.nightInk, in: RoundedRectangle(cornerRadius: 16))
                                .foregroundStyle(Color.nightPaper)
                        }
                    }
                    if let website = plan.stops.first?.place.websiteURL { Link(destination: website) { Label("Visit website", systemImage: "safari").frame(maxWidth: .infinity).padding().background(Color.nightPaper, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Color.nightInk).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.nightInk.opacity(0.14))) } }
                    ShareLink(item: shareText) { Label("Share plan", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity).padding().background(Color.nightPaper, in: RoundedRectangle(cornerRadius: 16)).foregroundStyle(Color.nightInk).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.nightInk.opacity(0.14))) }
                }
                Button { app.feedbackPlan = plan } label: { Label(app.feedbackByPlan[plan.id]?.rawValue ?? "How does this feel?", systemImage: "slider.horizontal.3").frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).foregroundStyle(Color.nightCoral) }
                Text("Data source: \(plan.stops.first?.place.source ?? "Tonight")").font(.caption).foregroundStyle(Color.nightMutedInk)
            }.padding(24)
        }
        .background(Color.nightPaper.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Label("Back", systemImage: "chevron.left")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.nightCoral)
                }
                .buttonStyle(.plain)
                Spacer()
                if !dynamicTypeSize.isAccessibilitySize {
                    Text("Plan details").font(.subheadline.weight(.semibold)).foregroundStyle(Color.nightInk)
                    Spacer()
                    Color.clear.frame(width: 56, height: 1)
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color.nightPaper)
        }
        .sheet(item: $app.feedbackPlan) { FeedbackSheet(plan: $0) }
    }
    @Environment(\.dismiss) private var dismiss
    @ViewBuilder private func stopDetails(_ stop: PlanStop) -> some View { VStack(alignment: .leading, spacing: 6) { Text(stop.place.name).font(.headline); Text(stop.note).font(.subheadline).foregroundStyle(Color.nightMutedInk); Text("$\(Int(stop.cost)) · \(stop.place.category)").font(.caption).foregroundStyle(Color.nightMutedInk) } }
    private var shareText: String { "Tonight: \(plan.title)\n\(plan.description)\n\(plan.stops.map { "\($0.startTime) · \($0.place.name)" }.joined(separator: "\n"))" }
    private func open(_ url: URL?) { guard let url else { return }; UIApplication.shared.open(url); app.analytics.track(.placeOpened) }
}

struct FeedbackSheet: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.dismiss) private var dismiss
    let plan: EveningPlan
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Tune the next one").font(.title.bold())
                Text("Your feedback helps Tonight understand your kind of evening.").foregroundStyle(Color.nightMutedInk)
                ForEach(PlanFeedback.allCases) { feedback in
                    Button { app.recordFeedback(feedback, for: plan); dismiss() } label: { HStack { Text(feedback.rawValue); Spacer(); Image(systemName: app.feedbackByPlan[plan.id] == feedback ? "checkmark.circle.fill" : "circle").foregroundStyle(Color.nightCoral) }.padding(.vertical, 8).foregroundStyle(Color.nightInk) }
                }
            }.padding(24)
        }.presentationDetents([.medium, .large]).background(Color.nightPaper)
    }
}
struct SavedView: View {
    @EnvironmentObject private var app: AppModel
    var body: some View {
        NavigationStack {
            Group {
                if app.savedPlans.isEmpty {
                    ContentUnavailableView("Nothing saved yet", systemImage: "bookmark", description: Text("Save a plan when it feels like you."))
                } else {
                    List {
                        Section("Favorites") {
                            ForEach(app.savedPlans) { plan in
                                Button { app.selectedPlan = plan } label: { VStack(alignment: .leading, spacing: 4) {
                                    Text(plan.title).font(.headline)
                                    Text("\(plan.stops.count) \(plan.stops.count == 1 ? "stop" : "stops") · $\(Int(plan.totalCost)) total").font(.caption).foregroundStyle(Color.nightMutedInk)
                                } }.foregroundStyle(Color.nightInk)
                            }
                            .onDelete { offsets in
                                let removed = offsets.map { app.savedPlans[$0] }
                                removed.forEach(app.toggleSave)
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .background(Color.nightPaper.ignoresSafeArea())
                }
            }
            .background(Color.nightPaper.ignoresSafeArea())
            .navigationTitle("Saved")
            .tint(Color.nightCoral)
            .navigationDestination(item: $app.selectedPlan) { PlanDetailView(plan: $0) }
        }
    }
}
struct ProfileView: View {
    @EnvironmentObject private var app: AppModel
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(app.preferences.locationName, systemImage: "location.fill")
                    Label(app.preferences.budget.rawValue, systemImage: "wallet.pass")
                } header: {
                    Text("Your defaults").foregroundStyle(Color.nightMutedInk)
                }
                Section {
                    Button("Edit preferences") { app.editPreferences() }
                    Button("Subscription") { app.showPaywall = true }
                } footer: {
                    Text("Tonight uses your preferences to rank nearby Apple Maps results when available. Location permission is requested only when you choose to use your current location, and precise location is never used for advertising.")
                        .foregroundStyle(Color.nightMutedInk)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.nightPaper.ignoresSafeArea())
            .navigationTitle("Profile")
            .tint(Color.nightCoral)
        }
    }
}

struct PaywallView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var subscription: StoreKitSubscriptionManager
    @State private var isBusy = false
    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack {
                    Text("Tonight Premium").font(.caption.weight(.semibold)).foregroundStyle(Color.nightCoral)
                    Spacer()
                    Button("Done") { dismiss() }.foregroundStyle(Color.nightCoral)
                }
                Text("Tonight Premium").font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("Unlimited plans, no ads, and smarter recommendations.").font(.title3).foregroundStyle(Color.nightMutedInk)
                VStack(alignment: .leading, spacing: 12) {
                    Label(subscription.localizedPrice ?? SubscriptionConfiguration.fallbackDisplayPrice, systemImage: "creditcard.fill")
                    if let trial = subscription.trialDescription { Label(trial, systemImage: "gift.fill") }
                    Label("Advanced personalization and live provider data when available", systemImage: "sparkles")
                }.font(.headline)
                if !subscription.isProductAvailable {
                    Text("Subscriptions are temporarily unavailable. You can keep using free plans.")
                        .font(.subheadline).foregroundStyle(Color.nightIndigo)
                }
                if let message = statusMessage ?? subscription.purchaseMessage {
                    Text(message).font(.subheadline).foregroundStyle(Color.nightIndigo)
                        .accessibilityAddTraits(.updatesFrequently)
                }
                PrimaryButton(title: subscription.state.isPremium ? "Premium active" : "Subscribe") {
                    Task {
                        isBusy = true
                        defer { isBusy = false }
                        do {
                            try await subscription.purchase()
                            statusMessage = subscription.purchaseMessage
                            if subscription.state.isPremium { dismiss() }
                        } catch { statusMessage = error.localizedDescription }
                    }
                }
                .disabled(isBusy || subscription.state.isPremium || !subscription.isProductAvailable)
                Button("Restore Purchases") {
                    Task {
                        isBusy = true
                        defer { isBusy = false }
                        do {
                            try await subscription.restore()
                            statusMessage = subscription.purchaseMessage
                        } catch { statusMessage = error.localizedDescription }
                    }
                }
                .disabled(isBusy)
                .frame(maxWidth: .infinity)
                .foregroundStyle(Color.nightCoral)
                HStack {
                    if let terms = SubscriptionConfiguration.termsURL { Link("Terms", destination: terms) }
                    Text("·")
                    if let privacy = SubscriptionConfiguration.privacyURL { Link("Privacy", destination: privacy) }
                }.font(.caption).foregroundStyle(Color.nightMutedInk)
                Text("Subscriptions renew automatically unless cancelled in your Apple ID settings. Prices and trial terms are shown by App Store Connect when configured.")
                    .font(.caption).foregroundStyle(Color.nightMutedInk)
            }
            .padding(24)
        }
        .presentationDetents([.medium, .large])
        .background(Color.nightPaper)
        .task { if !subscription.isProductAvailable { await subscription.load() } }
    }
}

struct SponsorCard: View {
    let provider: AdsProvider
    @State private var content: SponsorContent?
    @State private var showReportConfirmation = false

    var body: some View {
        Group {
            if let content {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(content.label.uppercased()).font(.caption2.weight(.bold)).tracking(1).foregroundStyle(Color.nightIndigo)
                            .accessibilityLabel("Sponsored content")
                        Spacer()
                        Button("Report") { provider.report(content); showReportConfirmation = true; self.content = nil }
                            .font(.caption).foregroundStyle(Color.nightMutedInk)
                            .accessibilityHint("Reports this sponsored content as inappropriate")
                    }
                    Text(content.title).font(.headline)
                    Text(content.detail).font(.subheadline).foregroundStyle(Color.nightMutedInk)
                    if let destination = content.destination {
                        Link(content.actionTitle, destination: destination).font(.subheadline.weight(.semibold)).foregroundStyle(Color.nightCoral)
                    }
                }
                .padding(16)
                .background(Color.nightIndigo.opacity(0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.nightIndigo.opacity(0.18)))
            }
        }
        .task { content = await provider.sponsorContent() }
        .alert("Report received", isPresented: $showReportConfirmation) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Thanks. This sponsored content won’t be shown again on this device.")
        }
    }
}

import SwiftUI

extension Color {
    static let nightInk = Color(red: 0.10, green: 0.08, blue: 0.14)
    static let nightMutedInk = Color(red: 0.35, green: 0.33, blue: 0.39)
    static let nightPaper = Color(red: 0.98, green: 0.96, blue: 0.92)
    static let nightCoral = Color(red: 0.96, green: 0.36, blue: 0.26)
    static let nightGold = Color(red: 0.96, green: 0.72, blue: 0.30)
    static let nightSage = Color(red: 0.72, green: 0.79, blue: 0.65)
    static let nightIndigo = Color(red: 0.29, green: 0.27, blue: 0.58)
}

struct Pill: View { let text: String; var tint: Color = .nightInk; var body: some View { Text(text).font(.caption.weight(.semibold)).foregroundStyle(tint).padding(.horizontal, 11).padding(.vertical, 7).background(tint.opacity(0.10), in: Capsule()) } }
struct PrimaryButton: View { let title: String; let action: () -> Void; var body: some View { Button(action: action) { Text(title).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 17).background(Color.nightInk, in: RoundedRectangle(cornerRadius: 18, style: .continuous)).foregroundStyle(Color.nightPaper) }.buttonStyle(.plain) } }
struct SelectionCard: View { let title: String; let icon: String; let selected: Bool; let action: () -> Void; var body: some View { Button(action: action) { VStack(spacing: 12) { Image(systemName: icon).font(.title2); Text(title).font(.subheadline.weight(.semibold)).multilineTextAlignment(.center) }.frame(maxWidth: .infinity, minHeight: 92).padding(.vertical, 8).foregroundStyle(selected ? Color.nightPaper : Color.nightInk).background(selected ? Color.nightInk : Color.nightPaper.opacity(0.65), in: RoundedRectangle(cornerRadius: 20, style: .continuous)).overlay(RoundedRectangle(cornerRadius: 20).stroke(Color.nightInk.opacity(selected ? 0 : 0.08), lineWidth: 1)) }.buttonStyle(.plain) } }
struct MoodOption: View { let title: String; let selected: Bool; let action: () -> Void; var body: some View { Button(action: action) { Text(title).font(.subheadline.weight(.medium)).frame(maxWidth: .infinity).padding(.vertical, 10).contentShape(Capsule()).foregroundStyle(selected ? Color.nightPaper : Color.nightInk).background(selected ? Color.nightInk : Color.white.opacity(0.68), in: Capsule()).overlay(Capsule().stroke(Color.nightInk.opacity(selected ? 0 : 0.10), lineWidth: 1)) }.buttonStyle(.plain) } }

struct BrandMark: View { var body: some View { HStack(spacing: 8) { Circle().fill(Color.nightCoral).frame(width: 12, height: 12); Text("tonight").font(.headline.weight(.bold)).tracking(-0.4) }.fixedSize(horizontal: true, vertical: false) } }

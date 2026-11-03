import SwiftUI

enum Theme {
    static let awake = Color(nsColor: NSColor(srgbRed: 0.98, green: 0.47, blue: 0.24, alpha: 1))
    static let panelWidth: CGFloat = 248
}

/// Everything in the popover: one big switch, what it means, and two small extras.
struct PanelView: View {
    @Environment(KeepAwake.self) private var model
    var quit: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Orb(isOn: model.isOn, label: headline, action: model.toggle)
                .padding(.top, 8)

            ZStack {
                Text(headline)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(model.problem == nil ? Color.primary : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .id(headline)
                    .transition(.blurReplace)
            }
            .animation(.smooth(duration: 0.3), value: headline)

            HStack(spacing: 8) {
                Toggle("Open at login", isOn: Binding(
                    get: { model.launchesAtLogin },
                    set: { model.setLaunchesAtLogin($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

                Spacer()

                Button(action: quit) {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .accessibilityLabel("Quit \(App.name)")
                }
                .buttonStyle(PressableStyle())
                .foregroundStyle(.secondary)
                .help("Quit \(App.name)")
                .keyboardShortcut("q", modifiers: .command)
            }
        }
        .padding(16)
        .frame(width: Theme.panelWidth)
    }

    private var headline: String {
        if let problem = model.problem { return problem }
        if model.isUnknown { return "Status unavailable" }
        return model.isOn ? "Stays awake when closed" : "Sleeps when closed"
    }
}

/// The switch: lit and warm when the Mac stays awake, quiet when it sleeps normally.
private struct Orb: View {
    var isOn: Bool
    var label: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isOn ? "sun.max.fill" : "moon.zzz.fill")
                .font(.system(size: 36, weight: .medium))
                .foregroundStyle(isOn ? Color.white : Color.secondary)
                .contentTransition(.symbolEffect(.replace.downUp))
                .frame(width: 92, height: 92)
                .background {
                    Circle()
                        .fill(isOn ? AnyShapeStyle(Theme.awake.gradient) : AnyShapeStyle(Color.primary.opacity(0.08)))
                        .shadow(color: Theme.awake.opacity(isOn ? 0.45 : 0), radius: 16)
                }
                .contentShape(Circle())
                .animation(.smooth(duration: 0.35), value: isOn)
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut(.defaultAction)
        .focusable(false)
        .accessibilityLabel("Keep awake with the lid closed")
        .accessibilityValue(isOn ? "On" : "Off")
        .accessibilityAddTraits(.isToggle)
        .help(label)
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

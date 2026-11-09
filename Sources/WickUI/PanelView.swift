import SwiftUI
import WickCore

public struct PanelView: View {
    @Bindable var model: WickModel

    public init(model: WickModel) {
        self.model = model
    }

    public var body: some View {
        VStack(spacing: 0) {
            StatusLine(model: model)
                .padding(.leading, 18)
                .padding(.trailing, 10)
                .padding(.top, 10)

            TimelineView(.periodic(from: Date(timeIntervalSinceReferenceDate: 0), by: 1)) { timeline in
                VStack(spacing: 10) {
                    Hero(model: model, date: timeline.date)
                        .padding(.horizontal, 18)
                    Ruler(model: model, date: timeline.date)
                }
            }
            .padding(.top, 8)

            Presets(model: model)
                .padding(.horizontal, Theme.panelInset)
                .padding(.top, 8)

            Group {
                if model.needsAccess {
                    AccessCard(model: model)
                        .transition(.opacity.combined(with: .offset(y: 6)))
                } else {
                    ConditionsCard(model: model)
                        .transition(.opacity.combined(with: .offset(y: -6)))
                }
            }
            .padding(.horizontal, Theme.panelInset)
            .padding(.top, 10)
            .padding(.bottom, Theme.panelInset)
        }
        .animation(.easeOut(duration: 0.2), value: model.needsAccess)
        .frame(width: Theme.panelWidth)
        .background(PanelBackground(isAwake: model.isAwake))
        .clipShape(.rect(cornerRadius: Theme.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .environment(\.colorScheme, .dark)
    }
}

// MARK: Background

private struct PanelBackground: View {
    let isAwake: Bool
    @Environment(\.accessibilityReduceMotion) private var reducesMotion
    @Environment(\.accessibilityReduceTransparency) private var reducesTransparency

    var body: some View {
        ZStack {
            if !reducesTransparency {
                VisualEffect()
            }
            Theme.canvas.opacity(reducesTransparency ? 1 : 0.92)
        }
        .overlay(alignment: .bottom) {
            // The session's light. It rises from the bottom edge like a coal catching, and is the
            // one thing in the panel that animates slowly, because it only happens on a state change.
            EllipticalGradient(
                stops: [
                    .init(color: Theme.ember.opacity(0.72), location: 0),
                    .init(color: Theme.emberDeep.opacity(0.42), location: 0.36),
                    .init(color: Theme.emberDeep.opacity(0.1), location: 0.72),
                    .init(color: .clear, location: 1),
                ],
                center: .bottom,
                startRadiusFraction: 0,
                endRadiusFraction: 1
            )
            .frame(width: Theme.panelWidth * 1.5, height: 300)
            .frame(width: Theme.panelWidth)
            .opacity(isAwake ? 1 : 0)
            .offset(y: isAwake || reducesMotion ? 0 : 70)
            .animation(.easeOut(duration: isAwake ? 0.55 : 0.25), value: isAwake)
            .allowsHitTesting(false)
        }
    }
}

struct VisualEffect: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

// MARK: Status line

private struct StatusLine: View {
    let model: WickModel

    private var text: String {
        if let problem = model.problem { return problem }
        switch model.phase {
        case .awake: return "Awake with the lid closed"
        case .awakeElsewhere: return "Awake. Turned on outside Wick"
        case .idle:
            if let end = model.lastEnd, end.reason != .stoppedByUser, end.at.timeIntervalSinceNow > -43_200 {
                return end.reason.sentence
            }
            return "Sleeps when the lid closes"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isAwake ? Theme.ember : Theme.textTertiary)
                .frame(width: 6, height: 6)
                .shadow(color: model.isAwake ? Theme.ember : .clear, radius: 4)
                .animation(.easeOut(duration: 0.2), value: model.isAwake)

            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(model.problem == nil ? Theme.textSecondary : Theme.emberHot)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 4)

            MoreMenu(model: model)
        }
    }
}

private struct MoreMenu: View {
    let model: WickModel

    var body: some View {
        Menu {
            Toggle("Show Time in Menu Bar", isOn: Binding(
                get: { model.showsTimeInMenuBar },
                set: { model.setShowsTimeInMenuBar($0) }
            ))
            Toggle("Open at Login", isOn: Binding(
                get: { model.opensAtLogin },
                set: { model.setOpensAtLogin($0) }
            ))
            Divider()
            Button("Remove Permission…") { model.removeAccess() }
            Link("Wick on GitHub", destination: WickModel.repositoryURL)
            Divider()
            Button("Quit Wick") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
    }
}

// MARK: Hero

private struct Hero: View {
    let model: WickModel
    let date: Date

    private var bigText: String {
        if let scrub = model.scrubMinutes { return Self.clock(minutes: scrub) }
        switch model.phase {
        case .awake:
            if let remaining = model.remaining(at: date) { return Durations.clock(remaining) }
            return "∞"
        case .awakeElsewhere:
            return "∞"
        case .idle:
            return model.isForever ? "∞" : Self.clock(minutes: model.minutes)
        }
    }

    private var caption: String {
        let until = model.session?.endsAt ?? (model.isForever ? nil : date.addingTimeInterval(model.minutes * 60))
        var end: Date? = until
        if let scrub = model.scrubMinutes { end = date.addingTimeInterval(scrub * 60) }

        var parts: [String] = []
        if let end {
            parts.append("until \(Self.time(end, relativeTo: date))")
        } else if model.phase == .awakeElsewhere {
            parts.append("until you turn it off")
        } else if model.session?.heldPIDs.isEmpty == false {
            parts.append("while a command runs")
        } else {
            parts.append("until you stop it")
        }
        if model.stopWhenAgentsFinish, model.phase != .awakeElsewhere { parts.append("or agents finish") }
        return parts.joined(separator: " ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text(bigText)
                    .font(.system(size: 58, weight: .light))
                    .monospacedDigit()
                    .kerning(-1.6)
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(height: 66, alignment: .leading)

                Text(caption)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            MainButton(model: model)
        }
    }

    private static func clock(minutes: Double) -> String {
        String(format: "%d:%02d", Int(minutes) / 60, Int(minutes) % 60)
    }

    private static func time(_ end: Date, relativeTo now: Date) -> String {
        let clock = end.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDate(end, inSameDayAs: now) ? clock : "\(clock) tomorrow"
    }
}

private struct MainButton: View {
    let model: WickModel

    var body: some View {
        Button(action: model.toggle) {
            Image(systemName: model.isAwake ? "stop.fill" : "play.fill")
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: 20, weight: .semibold))
                // The play triangle's visual centre sits left of its box.
                .offset(x: model.isAwake ? 0 : 1.5)
                .foregroundStyle(Theme.soot)
                .frame(width: 58, height: 58)
                .background(Circle().fill(model.isAwake ? Theme.ember : Theme.paper))
                .shadow(color: model.isAwake ? Theme.ember.opacity(0.55) : .clear, radius: 16)
                .contentShape(.circle)
                .animation(.easeOut(duration: 0.2), value: model.isAwake)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(model.isAwake ? "Stop" : "Keep awake")
        .keyboardShortcut(.return, modifiers: [])
    }
}

/// Feedback on press, not on release.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: Theme.pressDuration), value: configuration.isPressed)
    }
}

// MARK: Ruler

private struct Ruler: View {
    let model: WickModel
    let date: Date

    private var minutes: Double {
        if let remaining = model.remaining(at: date) { return remaining / 60 }
        return model.minutes
    }

    private var isOpenEnded: Bool {
        switch model.phase {
        case .awake(let session): session.endsAt == nil
        case .awakeElsewhere: true
        case .idle: model.isForever
        }
    }

    var body: some View {
        RulerView(
            minutes: minutes,
            isBurning: model.isAwake,
            isOpenEnded: isOpenEnded && model.scrubMinutes == nil,
            onScrub: { model.scrub(to: $0) },
            onCommit: { model.commitDuration($0) },
            onSettle: { model.scrubEnded() }
        )
        .frame(height: 44)
        .disabled(model.phase == .awakeElsewhere)
        .allowsHitTesting(model.phase != .awakeElsewhere)
    }
}

private struct Presets: View {
    let model: WickModel

    private static let presets: [(label: String, minutes: Double)] = [
        ("30m", 30), ("1h", 60), ("2h", 120), ("4h", 240), ("8h", 480),
    ]

    private var isAdjustable: Bool { model.phase != .awakeElsewhere }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(Self.presets, id: \.minutes) { preset in
                PresetButton(
                    label: preset.label,
                    isSelected: !model.isForever && model.phase == .idle && model.minutes == preset.minutes
                ) {
                    model.commitDuration(preset.minutes)
                }
            }
            PresetButton(label: "∞", isSelected: isOpenEndedSelected) {
                model.commitDuration(model.minutes, forever: true)
            }
            .accessibilityLabel("Until you stop it")
        }
        .disabled(!isAdjustable)
        .opacity(isAdjustable ? 1 : 0.4)
    }

    private var isOpenEndedSelected: Bool {
        if let session = model.session { return session.endsAt == nil }
        return model.isForever && model.phase == .idle
    }
}

private struct PresetButton: View {
    let label: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 13, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(isSelected || isHovered ? Theme.textPrimary : Theme.textSecondary)
                .frame(maxWidth: .infinity, minHeight: 30)
                .background {
                    Capsule().fill(isSelected ? Color.white.opacity(0.12) : .clear)
                }
                .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .onHover { isHovered = $0 }
    }
}

// MARK: Conditions

private struct ConditionsCard: View {
    let model: WickModel

    private var agentSummary: String {
        switch model.agents.count {
        case 0: return "No agents running"
        case 1: return "\(model.agents[0]) running"
        case 2: return "\(model.agents[0]) and \(model.agents[1]) running"
        default: return "\(model.agents[0]) and \(model.agents.count - 1) others running"
        }
    }

    private var batterySummary: String {
        guard let battery = model.battery else { return "" }
        return "\(battery.percent)%, \(battery.isDischarging ? "on battery" : "plugged in")"
    }

    private var batteryIcon: String {
        guard let battery = model.battery else { return "battery.100percent" }
        if !battery.isDischarging { return "battery.100percent.bolt" }
        return switch battery.percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }

    private var heatSummary: String {
        guard let celsius = model.heat.batteryCelsius else { return model.heat.word }
        let temperature = Measurement(value: celsius, unit: UnitTemperature.celsius).formatted(
            .measurement(width: .abbreviated, usage: .general, numberFormatStyle: .number.precision(.fractionLength(0)))
        )
        return "\(model.heat.word), battery \(temperature)"
    }

    private var heatIcon: String {
        model.heat.isHot ? "thermometer.high" : model.heat.isWarm ? "thermometer.medium" : "thermometer.low"
    }

    var body: some View {
        VStack(spacing: 0) {
            ConditionRow(symbol: "terminal", title: "Stop when agents finish", detail: agentSummary) {
                Toggle("Stop when agents finish", isOn: Binding(
                    get: { model.stopWhenAgentsFinish },
                    set: { model.setStopWhenAgentsFinish($0) }
                ))
                .toggleStyle(EmberSwitchStyle())
                .labelsHidden()
            }

            if model.battery != nil {
                Rectangle()
                    .fill(Theme.hairline)
                    .frame(height: 1)
                    .padding(.leading, 44)

                ConditionRow(symbol: batteryIcon, title: "Stop at low battery", detail: batterySummary) {
                    BatteryFloorMenu(model: model)
                }
            }

            Rectangle()
                .fill(Theme.hairline)
                .frame(height: 1)
                .padding(.leading, 44)

            // The one condition with nothing to switch: it's there to say so.
            ConditionRow(symbol: heatIcon, title: "Stops if it gets hot", detail: heatSummary) {
                Text("Always")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(minHeight: 28)
            }
            .accessibilityElement(children: .combine)
        }
        // No guard runs for a setting Wick did not turn on, so these conditions would be promises it can't keep.
        .disabled(model.phase == .awakeElsewhere)
        .opacity(model.phase == .awakeElsewhere ? 0.4 : 1)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Color.black.opacity(0.22))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
        }
    }
}

private struct ConditionRow<Accessory: View>: View {
    let symbol: String
    let title: String
    let detail: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            Spacer(minLength: 8)

            accessory
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .padding(.vertical, 9)
    }
}

private struct BatteryFloorMenu: View {
    let model: WickModel

    private var label: String {
        model.batteryFloor.map { "\($0)%" } ?? "Off"
    }

    var body: some View {
        Menu {
            ForEach([10, 20, 30, 50], id: \.self) { percent in
                Toggle("\(percent)%", isOn: Binding(
                    get: { model.batteryFloor == percent },
                    set: { _ in model.setBatteryFloor(percent) }
                ))
            }
            Divider()
            Toggle("Never", isOn: Binding(
                get: { model.batteryFloor == nil },
                set: { _ in model.setBatteryFloor(nil) }
            ))
        } label: {
            HStack(spacing: 3) {
                Text(label)
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
            }
            .foregroundStyle(Theme.textPrimary)
            .frame(minHeight: 28)
            .contentShape(.rect)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Battery level to stop at")
    }
}

/// A system-sized switch that lights in the brand colour whether or not the window is key.
private struct EmberSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            Capsule()
                .fill(configuration.isOn ? Theme.ember : Color.white.opacity(0.16))
                .frame(width: 34, height: 20)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Theme.paper)
                        .padding(2)
                        .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                }
                .frame(minHeight: 28)
                .contentShape(.rect)
                .animation(.spring(duration: 0.2, bounce: 0), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

// MARK: Access

private struct AccessCard: View {
    let model: WickModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("One-time permission")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.textPrimary)

            Text("macOS only lets an admin keep a closed Mac awake. Wick adds one sudoers rule that allows `pmset -a disablesleep` and nothing else, so you only enter your password this once.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Label {
                Text("Keep it out of bags while awake. A closed Mac sheds heat slowly.")
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "thermometer.medium")
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.emberHot)

            HStack(spacing: 8) {
                Button("Not Now", action: model.dismissAccess)
                    .buttonStyle(CapsuleButtonStyle(isProminent: false))
                Button("Allow…", action: model.allowAccess)
                    .buttonStyle(CapsuleButtonStyle(isProminent: true))
            }
            .padding(.top, 2)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .fill(Theme.raised)
        }
    }
}

private struct CapsuleButtonStyle: ButtonStyle {
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(isProminent ? Theme.soot : Theme.textPrimary)
            .frame(maxWidth: .infinity, minHeight: 32)
            .background(Capsule().fill(isProminent ? Theme.paper : Theme.raised))
            .contentShape(.capsule)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: Theme.pressDuration), value: configuration.isPressed)
    }
}

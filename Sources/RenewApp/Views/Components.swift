import SwiftUI
import RenewShared

enum Format {
    static func countdown(_ seconds: Int) -> String {
        let s = max(0, seconds)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    /// "today 9:00 AM", "tomorrow 9:00 AM", or "Mon 9:00 AM".
    static func dayAndTime(_ date: Date) -> String {
        let cal = Calendar.current
        let time = DateFormatter()
        time.dateStyle = .none
        time.timeStyle = .short
        let t = time.string(from: date)
        if cal.isDateInToday(date) { return "today \(t)" }
        if cal.isDateInTomorrow(date) { return "tomorrow \(t)" }
        let day = DateFormatter()
        day.setLocalizedDateFormatFromTemplate("EEE")
        return "\(day.string(from: date)) \(t)"
    }

    static func minutes(_ m: Int) -> String {
        if m < 60 { return "\(m) min" }
        let h = m / 60, rest = m % 60
        return rest == 0 ? (h == 1 ? "1 hour" : "\(h) hours") : "\(h) h \(rest) min"
    }
}

struct Banner: View {
    enum Kind { case info, warning, danger }

    let kind: Kind
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    private var tint: Color {
        switch kind {
        case .info: return .accentColor
        case .warning: return .orange
        case .danger: return .red
        }
    }

    private var symbol: String {
        switch kind {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .danger: return "shield.lefthalf.filled"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(message)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
            }
        }
        .padding(14)
        .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(tint.opacity(0.25)))
    }
}

/// Wraps children onto new lines, like text.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += s.width + spacing
            maxX = max(maxX, x - spacing)
            rowHeight = max(rowHeight, s.height)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > bounds.minX && x + s.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing
            rowHeight = max(rowHeight, s.height)
        }
    }
}

struct RuleChip: View {
    let rule: String

    var body: some View {
        let parsed = Rule.parse(rule)
        HStack(spacing: 4) {
            Image(systemName: RuleChip.symbol(parsed?.kind))
                .font(.caption2)
            Text(rule)
                .font(.callout)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
        .foregroundStyle(parsed?.kind == .allow ? Color.green : Color.primary)
    }

    static func symbol(_ kind: Rule.Kind?) -> String {
        switch kind {
        case .allow: return "checkmark.circle"
        case .keyword: return "textformat"
        default: return "nosign"
        }
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.secondary.opacity(0.15)))
    }
}

/// A rounded toggle-style button, filled when selected.
struct PillButton: View {
    let title: String
    let selected: Bool
    var minWidth: CGFloat = 64
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .frame(minWidth: minWidth)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(selected ? Color.accentColor : Color.secondary.opacity(0.12),
                            in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
    }
}

/// Hours and minutes you can type or step. Minutes step by 1 and roll over
/// into hours. The total is kept within 0…7 days (the longest session).
struct DurationPicker: View {
    @Binding var minutes: Int
    static let maxMinutes = 7 * 24 * 60

    private enum Field { case hours, minutes }
    @FocusState private var focus: Field?
    @State private var hoursText = ""
    @State private var minutesText = ""

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 6) {
                TextField("0", text: $hoursText)
                    .focused($focus, equals: .hours)
                    .frame(width: 56)
                Text("h").foregroundStyle(.secondary)
                Stepper("Hours", onIncrement: { set(minutes + 60) }, onDecrement: { set(minutes - 60) })
                    .labelsHidden()
            }
            HStack(spacing: 6) {
                TextField("0", text: $minutesText)
                    .focused($focus, equals: .minutes)
                    .frame(width: 56)
                Text("min").foregroundStyle(.secondary)
                Stepper("Minutes", onIncrement: { set(minutes + 1) }, onDecrement: { set(minutes - 1) })
                    .labelsHidden()
            }
        }
        .textFieldStyle(.roundedBorder)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .onAppear(perform: showValue)
        .onSubmit(showValue)
        // Typing updates the total right away, so Start uses what's typed even
        // before the field is committed; the text is tidied (e.g. 90 min →
        // 1 h 30 min) once editing ends.
        .onChange(of: hoursText) { _ in takeTyped() }
        .onChange(of: minutesText) { _ in takeTyped() }
        .onChange(of: focus) { f in if f == nil { showValue() } }
        .onChange(of: minutes) { m in if focus == nil || typedTotal != m { showValue() } }
    }

    private static func number(_ text: String) -> Int {
        Int(String(text.filter(\.isNumber).prefix(6))) ?? 0
    }

    private var typedTotal: Int {
        Self.clamp(Self.number(hoursText) * 60 + Self.number(minutesText))
    }

    private static func clamp(_ m: Int) -> Int { min(max(0, m), maxMinutes) }

    private func set(_ m: Int) {
        focus = nil
        minutes = Self.clamp(m)
        showValue()
    }

    private func takeTyped() {
        let t = typedTotal
        if t != minutes { minutes = t }
    }

    private func showValue() {
        let h = "\(minutes / 60)", m = "\(minutes % 60)"
        if hoursText != h { hoursText = h }
        if minutesText != m { minutesText = m }
    }
}

/// Checkboxes for the blocklists, plus an "also block" field.
struct BlocklistPicker: View {
    @ObservedObject var model: AppModel
    @Binding var selection: Set<String>
    @Binding var extra: String

    var body: some View {
        ForEach(model.sortedListNames, id: \.self) { name in
            Toggle(isOn: binding(name)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(name.capitalized).font(.body.weight(.medium))
                    Text((model.lists[name] ?? []).joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .toggleStyle(.checkbox)
        }
        Divider()
        TextField("Also block… e.g. reddit.com, youtube.com/shorts", text: $extra)
            .textFieldStyle(.roundedBorder)
    }

    private func binding(_ name: String) -> Binding<Bool> {
        Binding(get: { selection.contains(name) },
                set: { on in
                    if on { selection.insert(name) } else { selection.remove(name) }
                })
    }
}

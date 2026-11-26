import SwiftUI
import RenewShared

struct ListsView: View {
    @ObservedObject var model: AppModel
    @State private var selected: String?
    @State private var newRule = ""
    @State private var selectedRules = Set<String>()
    @State private var creating = false
    @State private var newListName = ""
    @State private var confirmingDelete = false
    @State private var confirmingReset = false
    @AppStorage("blocklistGuideExpanded") private var guideExpanded = true
    @FocusState private var addFieldFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 190)
            Divider()
            detail
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
        }
        // The shortcut lives here, not on the New List row: List rows are
        // built lazily, so a row scrolled out of view registers nothing.
        .background {
            Button("New List") { newListName = ""; creating = true }
                .keyboardShortcut("n", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .navigationTitle("Blocklists")
        .onAppear {
            model.reloadLists()
            if selected == nil { selected = model.sortedListNames.first }
        }
        .onChange(of: selected) { _ in
            newRule = ""
            selectedRules = []
        }
        .confirmationDialog("Delete “\(selected?.capitalized ?? "")”?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { deleteSelected() }
        } message: {
            Text(deleteMessage)
        }
        .confirmationDialog("Reset “\(selected?.capitalized ?? "")” to its defaults?", isPresented: $confirmingReset) {
            Button("Reset", role: .destructive) { resetSelected() }
        } message: {
            Text("Sites you added are removed and sites you removed come back.")
        }
        .alert("New blocklist", isPresented: $creating) {
            TextField("Name", text: $newListName)
            Button("Create") { createList() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give the list a short name, like “work” or “games”.")
        }
    }

    // MARK: - List column

    private var builtInNames: [String] { model.sortedListNames.filter(ListStore.isBuiltIn) }
    private var customNames: [String] { model.sortedListNames.filter { !ListStore.isBuiltIn($0) } }

    private var listColumn: some View {
        List(selection: $selected) {
            Section("Built-in") {
                ForEach(builtInNames, id: \.self, content: listRow)
            }
            Section("Your lists") {
                ForEach(customNames, id: \.self, content: listRow)
                newListRow
            }
        }
    }

    /// Sits right under your lists, so making one is a short move from them.
    private var newListRow: some View {
        Button { newListName = ""; creating = true } label: {
            Label("New List", systemImage: "plus.circle.fill")
                .foregroundStyle(Color.accentColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("New blocklist (⌘N)")
    }

    private func listRow(_ name: String) -> some View {
        HStack {
            Text(name.capitalized)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(name.capitalized)
            Spacer()
            Text("\(model.lists[name]?.count ?? 0)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .tag(name)
        .contextMenu {
            if isCustomized(name) {
                Button("Reset to Defaults…") { selected = name; confirmingReset = true }
            }
            if !ListStore.isBuiltIn(name) {
                Button("Delete…") { selected = name; confirmDelete() }
            }
        }
    }

    // MARK: - Detail

    @ViewBuilder private var detail: some View {
        if let name = selected, let rules = model.lists[name] {
            VStack(alignment: .leading, spacing: 0) {
                header(name, rules: rules)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)

                if model.session != nil {
                    InfoBanner(title: "A block session is running",
                               message: "Edits here start with your next block session. To block a site right now, add it on Block Sessions.",
                               button: "Block Sessions") { model.section = .sessions }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                }

                addField(name, rules: rules)
                    .padding(.horizontal, 20)
                    .padding(.top, 16)
                    .padding(.bottom, 12)

                Divider()
                if rules.isEmpty {
                    emptyList
                } else {
                    rulesList(name, rules: rules)
                }
                Divider()

                RuleGuide(expanded: $guideExpanded)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
            }
        } else {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                Text("Select a blocklist").foregroundStyle(.secondary)
            }
        }
    }

    private func header(_ name: String, rules: [String]) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name.capitalized).font(.title2.weight(.bold))
                Text(summary(name, rules: rules))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            if isCustomized(name) {
                Button("Reset to Defaults…") { confirmingReset = true }
            } else if !ListStore.isBuiltIn(name) {
                Button(role: .destructive) { confirmDelete() } label: {
                    Label("Delete List", systemImage: "trash")
                }
                .help("Delete this blocklist")
            }
        }
    }

    /// "Built-in, edited · 7 rules · Used by “Work” and “Evenings”".
    private func summary(_ name: String, rules: [String]) -> String {
        var parts: [String] = []
        if ListStore.isBuiltIn(name) {
            parts.append(isCustomized(name) ? "Built-in, edited" : "Built-in")
        }
        parts.append(rules.count == 1 ? "1 rule" : "\(rules.count) rules")
        parts.append(usersText(name).map { "Used by " + $0 } ?? "Not in any saved block session")
        return parts.joined(separator: " · ")
    }

    private func addField(_ name: String, rules: [String]) -> some View {
        let preview = RulePreview(newRule, existing: rules)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Add a site, part of a site, keyword:word or !exception", text: $newRule)
                    .textFieldStyle(.roundedBorder)
                    .focused($addFieldFocused)
                    .onSubmit { add(to: name) }
                    .accessibilityLabel("Add a rule")
                Button("Add") { add(to: name) }
                    .disabled(!preview.canAdd)
            }
            preview.view
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: 18, alignment: .topLeading)
        }
    }

    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: "nosign")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("Nothing blocked yet").font(.headline)
            Text("Type a site above, like reddit.com, and press Return.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private func rulesList(_ name: String, rules: [String]) -> some View {
        var sites: [ParsedRule] = [], words: [ParsedRule] = [], allowed: [ParsedRule] = []
        for rule in rules {
            let item = ParsedRule(text: rule, rule: Rule.parse(rule))
            switch item.rule?.kind {
            case .keyword: words.append(item)
            case .allow: allowed.append(item)
            default: sites.append(item)
            }
        }

        return List(selection: $selectedRules) {
            ruleSection("Blocked sites", sites, from: name)
            ruleSection("Blocked words", words, from: name)
            ruleSection("Always allowed", allowed, from: name)
        }
        .listStyle(.inset)
        .onDeleteCommand { remove(selectedRules, from: name) }
    }

    @ViewBuilder
    private func ruleSection(_ title: String, _ rules: [ParsedRule], from name: String) -> some View {
        if !rules.isEmpty {
            Section {
                ForEach(rules, id: \.text) { item in
                    let rule = item.text
                    RuleRow(rule: rule, parsed: item.rule) { remove([rule], from: name) }
                        .tag(rule)
                        .contextMenu {
                            let targets = selectedRules.contains(rule) ? selectedRules : [rule]
                            Button(targets.count > 1 ? "Remove \(targets.count) Rules" : "Remove") {
                                remove(targets, from: name)
                            }
                            Button("Copy") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(targets.sorted().joined(separator: "\n"), forType: .string)
                            }
                        }
                }
            } header: {
                Text("\(title) · \(rules.count)")
            }
        }
    }

    // MARK: - Actions

    private func add(to name: String) {
        let preview = RulePreview(newRule, existing: model.lists[name] ?? [])
        guard preview.canAdd else { return }
        do {
            _ = try ListStore.add(name, preview.newRules)
            newRule = ""
            model.reloadLists()
            addFieldFocused = true
        } catch {
            model.errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func remove(_ drop: Set<String>, from name: String) {
        guard !drop.isEmpty else { return }
        let remaining = (model.lists[name] ?? []).filter { !drop.contains($0) }
        do {
            try ListStore.set(name, remaining)
            selectedRules.subtract(drop)
            model.reloadLists()
        } catch {
            model.errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func createList() {
        let name = newListName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return }
        guard model.lists[name] == nil else {
            selected = name
            return
        }
        do {
            try ListStore.set(name, [])
            model.reloadLists()
            selected = name
            addFieldFocused = true
        } catch {
            model.errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    /// A built-in list whose rules differ from its defaults. Reads the loaded
    /// lists, not lists.json (`ListStore.isCustomized` reads the file).
    private func isCustomized(_ name: String) -> Bool {
        guard let defaults = ListStore.builtIn[name] else { return false }
        return model.lists[name] != defaults
    }

    /// "“Work” and “Evenings”", or nil if no saved block session uses the list.
    private func usersText(_ name: String) -> String? {
        let users = sessionsUsing(name).map { "“\($0.name)”" }
        return users.isEmpty ? nil : ListFormatter.localizedString(byJoining: users)
    }

    private func sessionsUsing(_ list: String) -> [BlockSession] {
        model.savedSessions.filter { $0.lists.contains(list) }
    }

    /// Asks first unless the list is empty and no saved block session uses it.
    private func confirmDelete() {
        guard let name = selected else { return }
        if sessionsUsing(name).isEmpty && (model.lists[name] ?? []).isEmpty {
            deleteSelected()
        } else {
            confirmingDelete = true
        }
    }

    private var deleteMessage: String {
        let name = selected ?? ""
        let count = model.lists[name]?.count ?? 0
        var text = count == 1 ? "Its 1 rule will be deleted." : "Its \(count) rules will be deleted."
        if let users = usersText(name) {
            text += " It's used by \(users); scheduled block sessions left with nothing to block won't start."
        }
        return text
    }

    private func deleteSelected() {
        guard let name = selected, !ListStore.isBuiltIn(name) else { return }
        try? ListStore.delete(name)
        model.selectedLists.remove(name)
        model.reloadLists()
        selected = model.sortedListNames.first
    }

    private func resetSelected() {
        guard let name = selected, ListStore.isBuiltIn(name) else { return }
        do {
            try ListStore.delete(name)
        } catch {
            model.errorMessage = "Couldn't reset: \(error.localizedDescription)"
        }
        model.reloadLists()
    }
}

// MARK: - Rule row

/// One rule: its icon, the rule, what it covers when that isn't obvious,
/// and a remove button that appears on hover.
private struct ParsedRule {
    let text: String
    let rule: Rule?
}

private struct RuleRow: View {
    let rule: String
    let parsed: Rule?
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: RuleChip.symbol(parsed?.kind))
                .foregroundStyle(parsed?.kind == .allow ? Color.green : Color.secondary)
                .frame(width: 18)
            Text(rule)
                .lineLimit(1)
                .truncationMode(.middle)
            if let parsed, let note = RuleText.rowNote(parsed) {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Remove \(rule)")
            .opacity(hovering ? 1 : 0)
            // Hidden means unclickable too: rows that slide under a still
            // pointer after a removal must not be removed by the next click.
            .allowsHitTesting(hovering)
            .accessibilityHidden(!hovering)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(parsed.map(RuleText.sentence) ?? rule)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(parsed.map(RuleText.sentence) ?? rule)
        .accessibilityAction(named: "Remove", remove)
    }
}

// MARK: - Plain-language rules

enum RuleText {
    /// What a rule does, as a full sentence.
    static func sentence(_ rule: Rule) -> String {
        switch rule.kind {
        case .block where rule.path.isEmpty:
            return "Blocks \(rule.host) and all of its subdomains."
        case .block:
            return "Blocks \(rule.host)\(rule.path) and the pages under it. The rest of \(rule.host) still works."
        case .keyword:
            return "Blocks any page whose address contains “\(rule.keyword)”."
        case .allow:
            return "Always allows \(rule.host)\(rule.path), even if another rule blocks it."
        }
    }

    /// A short note beside a rule in the list, only where the rule alone
    /// could be misread.
    static func rowNote(_ rule: Rule) -> String? {
        switch rule.kind {
        case .block where !rule.path.isEmpty: return "only this part"
        default: return nil
        }
    }
}

/// What typing in the add field would do, shown live under it.
private struct RulePreview {
    let newRules: [String]
    private let rejected: [String]
    private let duplicates: [String]
    private let isEmpty: Bool

    init(_ text: String, existing: [String]) {
        let parts = parseSites(text)
        let (valid, rejected) = canonicalRules(parts)
        let have = Set(canonicalRules(existing).valid)
        isEmpty = parts.isEmpty
        self.rejected = rejected
        newRules = valid.filter { !have.contains($0) }
        duplicates = valid.filter { have.contains($0) }
    }

    var canAdd: Bool { rejected.isEmpty && !newRules.isEmpty }

    /// Why the typed text can't be added. A bare word gets a pointer to
    /// `keyword:`, since that's usually what was meant.
    private var rejectedMessage: String {
        if rejected.count == 1 {
            let word = rejected[0]
            let bare = !word.contains(".") && !word.contains(":") && !word.hasPrefix("!")
                && word.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
            return bare
                ? "“\(word)” isn't a site. To block the word, type keyword:\(word.lowercased())"
                : "“\(word)” isn't a site. Sites need a dot, like reddit.com."
        }
        return "These aren't sites: \(rejected.map { "“\($0)”" }.joined(separator: ", ")). Sites need a dot, like reddit.com."
    }

    @ViewBuilder var view: some View {
        if isEmpty {
            Text("Separate several with spaces or commas. See How rules work below.")
                .foregroundStyle(.tertiary)
        } else if !rejected.isEmpty {
            Label {
                Text(rejectedMessage)
            } icon: {
                Image(systemName: "exclamationmark.circle.fill")
            }
            .foregroundStyle(.red)
        } else if newRules.isEmpty {
            Label(duplicates.count == 1 ? "\(duplicates[0]) is already in this list." : "These are already in this list.",
                  systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else if newRules.count == 1, let rule = Rule.parse(newRules[0]) {
            Label {
                Text(RuleText.sentence(rule) + (duplicates.isEmpty ? "" : " (\(duplicates.count) already in the list.)"))
            } icon: {
                Image(systemName: RuleChip.symbol(rule.kind))
            }
            .foregroundStyle(.secondary)
        } else {
            Label {
                Text("Adds \(newRules.count) rules: \(newRules.joined(separator: ", "))"
                     + (duplicates.isEmpty ? "" : " (\(duplicates.count) already in the list)"))
                    .lineLimit(2)
            } icon: {
                Image(systemName: "plus.circle")
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Guide

/// The four kinds of rule, each with an example and what it does.
private struct RuleGuide: View {
    @Binding var expanded: Bool

    private struct Kind: Identifiable {
        let example: String
        let title: String
        let detail: String
        let kind: Rule.Kind
        var id: String { example }
    }

    private let kinds: [Kind] = [
        Kind(example: "reddit.com", title: "A whole site",
             detail: "Type the site's address. Blocks the site and its subdomains, like old.reddit.com.",
             kind: .block),
        Kind(example: "youtube.com/shorts", title: "One part of a site",
             detail: "Add the path after the site. Blocks only that part; the rest of YouTube still works.",
             kind: .block),
        Kind(example: "keyword:casino", title: "A word in any address",
             detail: "Put `keyword:` before a word. Blocks every page whose address contains it.",
             kind: .keyword),
        Kind(example: "!music.youtube.com", title: "An exception",
             detail: "Put `!` before a site. It stays open even when another rule blocks it.",
             kind: .allow),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                    Text("How rules work").font(.headline)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")

            if expanded {
                VStack(alignment: .leading, spacing: 12) {
                    Grid(alignment: .topLeading, horizontalSpacing: 14, verticalSpacing: 10) {
                        ForEach(kinds) { kind in
                            GridRow {
                                HStack(spacing: 5) {
                                    Image(systemName: RuleChip.symbol(kind.kind))
                                        .font(.caption)
                                        .foregroundStyle(kind.kind == .allow ? Color.green : Color.secondary)
                                    Text(kind.example)
                                        .font(.callout.monospaced())
                                        .textSelection(.enabled)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.secondary.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .fixedSize()
                                .gridColumnAlignment(.leading)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(kind.title).font(.callout.weight(.semibold))
                                    Text(LocalizedStringKey(kind.detail))
                                        .font(.callout)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    Text("Exceptions win over every block rule, in every list. You can leave out `https://` and `www.`")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

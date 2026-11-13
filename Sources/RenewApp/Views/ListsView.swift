import SwiftUI
import RenewShared

struct ListsView: View {
    @ObservedObject var model: AppModel
    @State private var selected: String?
    @State private var newRule = ""
    @State private var creating = false
    @State private var newListName = ""

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selected) {
                    ForEach(model.sortedListNames, id: \.self) { name in
                        HStack {
                            Text(name.capitalized)
                            Spacer()
                            Text("\(model.lists[name]?.count ?? 0)")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        .tag(name)
                    }
                }
                Divider()
                HStack(spacing: 2) {
                    Button { newListName = ""; creating = true } label: { Image(systemName: "plus") }
                        .help("New blocklist")
                    Button { deleteSelected() } label: { Image(systemName: "minus") }
                        .help("Delete blocklist")
                        .disabled(selected == nil || ListStore.isBuiltIn(selected ?? ""))
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 170, idealWidth: 200, maxWidth: 260)

            detail
                .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Blocklists")
        .onAppear {
            model.reloadLists()
            if selected == nil { selected = model.sortedListNames.first }
        }
        .alert("New blocklist", isPresented: $creating) {
            TextField("Name", text: $newListName)
            Button("Create") { createList() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Give the list a short name, like “work” or “games”.")
        }
    }

    @ViewBuilder private var detail: some View {
        if let name = selected, let rules = model.lists[name] {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(name.capitalized).font(.title2.weight(.bold))
                    if ListStore.isBuiltIn(name) {
                        Text("Built-in").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if ListStore.isCustomized(name) {
                        Button("Reset to defaults") {
                            try? ListStore.delete(name)
                            model.reloadLists()
                        }
                    }
                }

                HStack {
                    TextField("Add a site, e.g. reddit.com or youtube.com/shorts", text: $newRule)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { add(to: name) }
                    Button("Add") { add(to: name) }
                        .disabled(newRule.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                List {
                    ForEach(rules, id: \.self) { rule in
                        HStack {
                            Image(systemName: RuleChip.symbol(Rule.parse(rule)?.kind))
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            Text(rule)
                            Spacer()
                            Button {
                                remove(rule, from: name)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Remove")
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))

                VStack(alignment: .leading, spacing: 3) {
                    Text("`reddit.com` blocks the site and its subdomains · `youtube.com/shorts` blocks just that part · `keyword:casino` blocks any URL containing the word · `!music.youtube.com` always allows")
                    Text("Changes apply to your next session. To add a site to the running session, use Focus → Block another site.")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(20)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle").font(.largeTitle).foregroundStyle(.secondary)
                Text("Select a blocklist").foregroundStyle(.secondary)
            }
        }
    }

    private func add(to name: String) {
        let parts = newRule.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        let (valid, rejected) = canonicalRules(parts)
        if !rejected.isEmpty {
            model.errorMessage = "Not a valid site: \(rejected.joined(separator: ", "))"
            return
        }
        guard !valid.isEmpty else { return }
        do {
            _ = try ListStore.add(name, valid)
            newRule = ""
            model.reloadLists()
        } catch {
            model.errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func remove(_ rule: String, from name: String) {
        let remaining = (model.lists[name] ?? []).filter { $0 != rule }
        do {
            try ListStore.set(name, remaining)
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
        } catch {
            model.errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }

    private func deleteSelected() {
        guard let name = selected, !ListStore.isBuiltIn(name) else { return }
        try? ListStore.delete(name)
        model.selectedLists.remove(name)
        model.reloadLists()
        selected = model.sortedListNames.first
    }
}

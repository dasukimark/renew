import SwiftUI
import RenewShared

struct MainView: View {
    @ObservedObject var model: AppModel

    private var sectionBinding: Binding<AppModel.Section?> {
        Binding(get: { model.section }, set: { if let s = $0 { model.section = s } })
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })
    }

    var body: some View {
        NavigationSplitView {
            List(selection: sectionBinding) {
                ForEach(AppModel.Section.allCases) { s in
                    Label(s.rawValue, systemImage: s.symbol).tag(s)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { sidebarStatus }
        } detail: {
            switch model.section {
            case .sessions: BlockSessionsView(model: model)
            case .quick: QuickBlockView(model: model)
            case .lists: ListsView(model: model)
            case .activity: ActivityView(model: model)
            case .setup: SetupView(model: model)
            }
        }
        .frame(minWidth: 780, minHeight: 560)
        .alert("Renew", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            model.refreshPermissions()
            model.reloadLists()
            model.reloadSessions()
        }
    }

    private var sidebarStatus: some View {
        HStack(spacing: 8) {
            Image(systemName: model.session != nil ? "lock.fill" : "lock.open")
                .foregroundStyle(model.session != nil ? Color.orange : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                if model.session != nil {
                    Text("Blocking").font(.callout.weight(.semibold))
                    Text("\(Format.countdown(model.secondsLeft)) left")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else if model.isLocalTest {
                    Text("Local test run").font(.callout.weight(.semibold))
                } else if !model.isInstalled {
                    Text("Not set up").font(.callout.weight(.semibold))
                } else if !model.daemonReachable {
                    Text("Service not responding").font(.callout.weight(.semibold))
                } else {
                    Text("Ready").font(.callout.weight(.semibold))
                }
            }
            Spacer()
        }
        .padding(12)
    }
}

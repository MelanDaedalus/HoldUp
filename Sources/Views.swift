import AppKit
import SwiftUI

enum Theme {
    static let background = Color(red: 0.110, green: 0.083, blue: 0.145)
    static let sidebar = Color(red: 0.146, green: 0.110, blue: 0.192)
    static let surface = Color(red: 0.194, green: 0.145, blue: 0.254)
    static let selection = Color(red: 0.286, green: 0.205, blue: 0.382)
    static let border = Color(red: 0.332, green: 0.268, blue: 0.419)
    static let ink = Color(red: 0.987, green: 0.982, blue: 0.997)
    static let secondary = Color(red: 0.833, green: 0.825, blue: 0.868)
    static let purple = Color(red: 0.778, green: 0.690, blue: 0.998)
    static let findingSurface = Color(red: 0.172, green: 0.125, blue: 0.230)
    static let quoteSurface = Color(red: 0.124, green: 0.091, blue: 0.170)
    static let purpleInk = Color(red: 0.127, green: 0.076, blue: 0.219)
}

struct AppActions {
    let openModels: () -> Void
    let accessibility: () -> Void
    let openOllama: () -> Void
    let clipboard: () -> Void
    let pasteContext: () -> Void
    let previewClipboard: () -> Void
    let sample: () -> Void
    let recordShortcut: () -> Void
    let recordClipboardShortcut: () -> Void
    let toggleShortcut: (Bool) -> Void
    let dismissPanel: () -> Void
    let finishWelcome: () -> Void
    var stopResearch: () -> Void = {}
}

struct PrimaryButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .fontWeight(.semibold)
            .padding(.horizontal, 13)
            .padding(.vertical, 7)
            .foregroundStyle(Theme.purpleInk)
            .background(Theme.purple.opacity(configuration.isPressed ? 0.80 : 1), in: RoundedRectangle(cornerRadius: 7))
            .opacity(enabled ? 1 : 0.45)
    }
}

struct Mark: View {
    var size: CGFloat = 29

    var body: some View {
        Image(systemName: "text.magnifyingglass")
            .font(.system(size: size * 0.48, weight: .semibold))
            .frame(width: size, height: size)
            .foregroundStyle(Theme.purpleInk)
            .background(Theme.purple, in: RoundedRectangle(cornerRadius: size * 0.23))
            .accessibilityHidden(true)
    }
}

struct SettingsSurface<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let control: Control

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).fontWeight(.medium)
                if let subtitle { Text(subtitle).font(.caption).foregroundStyle(Theme.secondary) }
            }
            Spacer(minLength: 8)
            control
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

struct SetupView: View {
    @ObservedObject var state: AppState
    let actions: AppActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 19) {
                HStack(spacing: 11) {
                    Mark(size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Set up Hold UP").font(.title2.bold())
                        Text("Choose how to run checks on this Mac.").foregroundStyle(Theme.secondary)
                    }
                }
                EngineOptions(state: state)
                ModelControls(state: state, actions: actions, allowsRemoval: false)
                if state.isReady, state.modelWork == nil {
                    Divider()
                    SettingRow(title: "Your first check", subtitle: state.canReadSelection
                               ? "Highlight a passage in another app and press \(state.shortcut.label)."
                               : "Copy a passage in another app, then choose Check Clipboard.") {
                        if state.canReadSelection {
                            EmptyView()
                        } else {
                            Button("Enable Selection Shortcut", action: actions.accessibility)
                        }
                    }.padding(.horizontal, -14)
                    HStack {
                        if state.canReadSelection {
                            sampleButton.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                        } else {
                            Button("Check Clipboard") {
                                actions.finishWelcome()
                                actions.clipboard()
                            }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                            sampleButton
                        }
                        Spacer()
                        Button("Done", action: actions.finishWelcome)
                    }
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 23)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.ink)
        .tint(Theme.purple)
    }

    private var sampleButton: some View {
        Button("Try a Sample") {
            actions.finishWelcome()
            actions.sample()
        }
    }
}

struct EngineOptions: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 8) {
            option(.builtIn, icon: "arrow.down.circle", title: "Download a local model",
                   info: "Compact offline model for quick flags. Source review is experimental.")
            option(.ollama, icon: "cpu", title: "Use Ollama", info: "Use an installed local model for a more detailed source review.")
        }
        .disabled(state.modelWork != nil)
    }

    private func option(_ engine: EngineChoice, icon: String, title: String, info: String) -> some View {
        let selected = state.engine == engine
        return Button {
            state.selectEngine(engine)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 17, weight: .medium))
                    .foregroundStyle(selected ? Theme.purple : Theme.secondary).frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).fontWeight(.semibold)
                    Text(info).font(.caption).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 5)
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Theme.purple : Theme.secondary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Theme.selection : Theme.surface, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? Theme.purple.opacity(0.7) : Theme.border))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct ModelControls: View {
    @ObservedObject var state: AppState
    let actions: AppActions
    var allowsRemoval = true
    @State private var confirmRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.engine == .builtIn {
                SettingsSurface {
                    SettingRow(title: state.store.asset.name,
                               subtitle: state.builtInInstalled ? "Installed on this Mac" : "Compact model · \(state.store.asset.sizeDescription)") {
                        if state.isReady {
                            Label("Ready", systemImage: "checkmark.circle").foregroundStyle(Theme.purple)
                        }
                    }
                }
                if state.modelWork == nil {
                    if !state.builtInInstalled {
                        Button("Download model", action: state.downloadModel).buttonStyle(PrimaryButton())
                    } else if allowsRemoval {
                        Button("Remove model") { confirmRemove = true }
                    }
                }
            } else {
                if !state.ollamaModels.isEmpty {
                    SettingsSurface {
                        SettingRow(title: "Installed model",
                                   subtitle: "Loads on your first check.") {
                            Picker("Installed model", selection: $state.ollamaModel) {
                                if state.ollamaModel.isEmpty { Text("Choose…").tag("") }
                                ForEach(state.ollamaModels) { model in Text(model.name).tag(model.name) }
                            }
                            .labelsHidden()
                            .frame(maxWidth: 215)
                            .disabled(state.modelWork != nil)
                        }
                    }
                } else if !state.ollamaModel.isEmpty {
                    SettingsSurface {
                        SettingRow(title: "Selected model", subtitle: state.ollamaModel) { EmptyView() }
                    }
                } else {
                    Text("Hold UP starts a separate local-only Ollama session with your installed models.")
                        .font(.callout).foregroundStyle(Theme.secondary)
                }
                if state.modelWork == nil {
                    HStack {
                        if !state.ollamaModels.isEmpty {
                            Button("Refresh list", action: state.connectOllama)
                        } else if OllamaEngine.applicationURL != nil {
                            Button(state.ollamaModel.isEmpty ? "Find installed models" : "Refresh list",
                                   action: state.connectOllama).buttonStyle(PrimaryButton())
                            Button("Open Ollama", action: actions.openOllama)
                        } else {
                            Link("Get Ollama", destination: URL(string: "https://ollama.com/download/mac")!)
                            Button("Find installed models", action: state.connectOllama)
                        }
                    }
                }
            }

            if let work = state.modelWork {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(work.label).fontWeight(.medium)
                        Spacer()
                        Button("Cancel", action: state.cancelModelWork).disabled(work == .cancelling || work == .removing)
                    }
                    if case .downloading(let bytes) = work {
                        ProgressView(value: Double(max(0, min(bytes, state.store.asset.bytes))), total: Double(state.store.asset.bytes))
                        Text("\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) of \(state.store.asset.sizeDescription)")
                            .font(.caption).foregroundStyle(Theme.secondary).monospacedDigit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .accessibilityElement(children: .contain)
            }
            if let error = state.modelError {
                Label(error, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
            } else if let note = state.modelNote {
                Text(note).font(.callout).foregroundStyle(Theme.secondary)
            }
        }
        .confirmationDialog("Remove the downloaded model?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove model", role: .destructive, action: state.removeBuiltIn)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This frees \(state.store.asset.sizeDescription). You can download the model again from Settings.")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: AppState
    let actions: AppActions
    @State private var editing: Rule?

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 9) {
                    Mark()
                    Text("Hold UP").font(.headline)
                }.padding(.bottom, 13).padding(.leading, 7)
                ForEach(SettingsSection.allCases) { section in
                    Button {
                        state.section = section
                    } label: {
                        Label(section.rawValue, systemImage: section.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 9).padding(.vertical, 7)
                            .foregroundStyle(state.section == section ? Theme.purple : Theme.ink)
                            .background(state.section == section ? Theme.selection : .clear, in: RoundedRectangle(cornerRadius: 7))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(state.section == section ? .isSelected : [])
                }
                Spacer()
                Label(state.isReady ? state.engineLabel : "Setup needed",
                      systemImage: state.isReady ? "checkmark.circle" : "circle.dashed")
                    .font(.caption).foregroundStyle(Theme.secondary)
                    .padding(.leading, 7).lineLimit(2)
            }
            .padding(13)
            .frame(width: 158)
            .frame(maxHeight: .infinity)
            .background(Theme.sidebar)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Text(state.section.rawValue).font(.title2.bold())
                    switch state.section {
                    case .general: general
                    case .rules: rules
                    case .models:
                        EngineOptions(state: state)
                        ModelControls(state: state, actions: actions)
                        if state.isReady, state.modelWork == nil { Button("Try a sample", action: actions.sample) }
                    case .privacy: privacy
                    case .about: about
                    }
                }
                .padding(23).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Theme.background)
        .foregroundStyle(Theme.ink)
        .tint(Theme.purple)
        .sheet(item: $editing) { rule in
            RuleEditor(rule: rule, existing: state.rules.contains { $0.id == rule.id }, save: saveRule) {
                state.rules.removeAll { $0.id == rule.id }
            }
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSurface {
                SettingRow(title: "Global shortcuts", subtitle: "Check a selection or copied text from another app.") {
                    Toggle("Enable global shortcut", isOn: Binding(get: { state.shortcutEnabled }, set: { actions.toggleShortcut($0) }))
                        .labelsHidden().toggleStyle(.switch)
                }
                Divider()
                SettingRow(title: "Check selection") {
                    Button(state.recordingShortcut && !state.recordingClipboardShortcut ? "Press new keys…" : state.shortcut.label,
                           action: actions.recordShortcut)
                        .accessibilityLabel("Change selection shortcut, current \(state.shortcut.label)")
                }
                Divider()
                SettingRow(title: "Check clipboard") {
                    Button(state.recordingClipboardShortcut ? "Press new keys…" : state.clipboardShortcut.label,
                           action: actions.recordClipboardShortcut)
                        .accessibilityLabel("Change clipboard shortcut, current \(state.clipboardShortcut.label)")
                }
                Divider()
                SettingRow(title: "Accessibility", subtitle: "Allows Hold UP to read a selection when you invoke it.") {
                    if state.canReadSelection { Label("Allowed", systemImage: "checkmark").foregroundStyle(Theme.purple) }
                    else { Button("Allow", action: actions.accessibility) }
                }
            }
            if let error = state.shortcutError { Text(error).foregroundStyle(Theme.secondary) }
            SettingsSurface {
                SettingRow(title: "Finding detail", subtitle: "Choose how related critiques are shown.") {
                    Picker("Finding detail", selection: $state.reviewDetail) {
                        ForEach(ReviewDetail.allCases) { detail in Text(detail.rawValue).tag(detail) }
                    }
                    .labelsHidden().fixedSize()
                }
            }
        }
    }

    private var rules: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Choose what gets flagged. Higher-priority findings appear first.").foregroundStyle(Theme.secondary)
            if state.rules.isEmpty {
                Text("Add a rule to start checking text.").foregroundStyle(Theme.secondary)
            } else {
                SettingsSurface {
                    ForEach($state.rules) { $rule in
                        HStack(alignment: .center, spacing: 10) {
                            Toggle("Enable \(rule.name)", isOn: $rule.enabled).labelsHidden().toggleStyle(.switch)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(rule.name).fontWeight(.medium)
                                Text(rule.criterion).font(.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                            }
                            Spacer(minLength: 4)
                            Picker("Priority for \(rule.name)", selection: $rule.priority) {
                                Text("Low").tag(1)
                                Text("Normal").tag(2)
                                Text("High").tag(3)
                            }
                            .labelsHidden().frame(width: 88)
                            Button("Edit") { editing = rule }.accessibilityLabel("Edit \(rule.name)")
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        if rule.id != state.rules.last?.id { Divider() }
                    }
                }
            }
            Button {
                editing = Rule(name: "", criterion: "")
            } label: { Label("Add rule", systemImage: "plus") }
        }
    }

    private var privacy: some View {
        SettingsSurface {
            SettingRow(title: "Selection access", subtitle: "The shortcut reads the current selection. Check Clipboard reads only on request.") {
                Image(systemName: "selection.pin.in.out").foregroundStyle(Theme.purple).accessibilityHidden(true)
            }
            Divider()
            SettingRow(title: "Local inference", subtitle: "Selected and pasted text is processed by the built-in model or a verified local-only Ollama session. Model downloads use the internet.") {
                Image(systemName: "cpu").foregroundStyle(Theme.purple).accessibilityHidden(true)
            }
            Divider()
            SettingRow(title: "Web lookup", subtitle: "Search Google sends the query to Google in your browser. Reviewing a page can follow up to two cited links. Comparison runs locally.") {
                Image(systemName: "globe").foregroundStyle(Theme.purple).accessibilityHidden(true)
            }
            Divider()
            SettingRow(title: "Storage", subtitle: "Rules and settings are saved. Closing the panel clears its passage and findings.") {
                Image(systemName: "lock").foregroundStyle(Theme.purple).accessibilityHidden(true)
            }
        }
    }

    private var about: some View {
        SettingsSurface {
            SettingRow(title: "Hold UP Beta",
                       subtitle: "A local reading assistant for reviewing claims and deciding what to verify.") {
                Mark()
            }
            Divider()
            SettingRow(title: "Version") {
                Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development")
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    private func saveRule(_ rule: Rule) {
        if let index = state.rules.firstIndex(where: { $0.id == rule.id }) {
            state.rules[index] = rule
        } else {
            state.rules.append(rule)
        }
    }
}

struct RuleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Rule
    @State private var confirmDelete = false
    let existing: Bool
    let save: (Rule) -> Void
    let delete: () -> Void

    init(rule: Rule, existing: Bool, save: @escaping (Rule) -> Void, delete: @escaping () -> Void) {
        _draft = State(initialValue: rule)
        self.existing = existing
        self.save = save
        self.delete = delete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(existing ? "Edit rule" : "Add a rule").font(.title2.bold())
            VStack(alignment: .leading, spacing: 4) {
                Text("Rule name").font(.caption).foregroundStyle(Theme.secondary)
                TextField("Rule name", text: $draft.name)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("What to flag").font(.caption).foregroundStyle(Theme.secondary)
                TextField("What to flag", text: $draft.criterion, axis: .vertical).lineLimit(2...5)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Example (optional)").font(.caption).foregroundStyle(Theme.secondary)
                TextField("Example (optional)", text: $draft.example, axis: .vertical).lineLimit(1...3)
            }
            HStack {
                Toggle("Enabled", isOn: $draft.enabled)
                Spacer()
                Picker("Priority", selection: $draft.priority) {
                    Text("Low").tag(1)
                    Text("Normal").tag(2)
                    Text("High").tag(3)
                }.fixedSize()
            }
            Divider()
            HStack {
                if existing { Button("Delete rule", role: .destructive) { confirmDelete = true } }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save rule") {
                    draft.name = draft.name.trimmed
                    draft.criterion = draft.criterion.trimmed
                    draft.example = draft.example.trimmed
                    save(draft)
                    dismiss()
                }.buttonStyle(PrimaryButton()).keyboardShortcut(.defaultAction)
                    .disabled(draft.name.trimmed.isEmpty || draft.criterion.trimmed.isEmpty ||
                              draft.name.count > 80 || draft.criterion.count > 360 || draft.example.count > 240)
            }
            if draft.name.count > 80 || draft.criterion.count > 360 || draft.example.count > 240 {
                Text("Use up to 80 characters for the name, 360 for the criterion, and 240 for the example.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .padding(22).frame(width: 470)
        .background(Theme.background)
        .confirmationDialog("Delete this rule?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete rule", role: .destructive) { delete(); dismiss() }
        }
    }
}

struct ReviewPanel: View {
    @ObservedObject var state: AppState
    let actions: AppActions
    @State private var editingPassage = false
    @FocusState private var passageFocused: Bool
    @State private var contextAddress = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Mark()
                Text("Hold UP").font(.headline)
                Spacer()
                if state.isReady { Label("On-device", systemImage: "cpu").font(.caption).foregroundStyle(Theme.purple) }
                Button(action: actions.dismissPanel) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 24, height: 24)
                }.buttonStyle(.plain).accessibilityLabel("Close check")
            }
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(Theme.sidebar)
            Divider()

            HStack(spacing: 8) {
                if state.evidenceClaim != nil {
                    Button {
                        state.closeEvidence()
                        actions.stopResearch()
                    } label: { Label("Back to check", systemImage: "chevron.left") }
                } else {
                    if !state.canReadSelection, state.excerpt.isEmpty, !editingPassage {
                        clipboardButton.buttonStyle(PrimaryButton())
                    } else {
                        clipboardButton
                    }
                    Button(editingPassage ? "Hide editor" : "Paste or type") {
                        editingPassage.toggle()
                        if editingPassage { passageFocused = true }
                    }
                    if !state.excerpt.isEmpty, !editingPassage, state.checkStatus != .checking, !canReviewArticle {
                        Button("Find sources") { state.openEvidence(for: state.findings.first?.quote) }
                            .keyboardShortcut("f", modifiers: [.command, .shift])
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()

            ScrollViewReader { scroll in
                ScrollView {
                    if let claim = state.evidenceClaim {
                        EvidencePane(state: state, claim: claim)
                            .id(claim)
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        localReview.id("passage-start")
                    }
                }
                .onChange(of: state.evidenceClaim) { _, claim in
                    scroll.scrollTo(claim == nil ? "passage-start" : "evidence-start", anchor: .top)
                }
                .onChange(of: state.webBusy) { wasBusy, busy in
                    if wasBusy, !busy, state.evidenceClaim != nil {
                        scroll.scrollTo("evidence-results", anchor: .top)
                    }
                }
                .onChange(of: state.loadedArticleURL) { _, url in
                    if url != nil, state.evidenceClaim == nil { scroll.scrollTo("loaded-article-action", anchor: .top) }
                }
                .onChange(of: editingPassage) { _, editing in
                    if editing { scroll.scrollTo("passage-start", anchor: .top) }
                }
                .onChange(of: state.excerpt) { _, _ in
                    scroll.scrollTo("passage-start", anchor: .top)
                }
            }
            Divider()
            HStack {
                Text(state.isReady ? state.engineLabel : "Model setup")
                    .lineLimit(1)
                Spacer()
                Text("Esc to close")
            }
            .font(.caption).foregroundStyle(Theme.secondary)
            .padding(.horizontal, 14).padding(.vertical, 8)
        }
        .background(Theme.background)
        .foregroundStyle(Theme.ink)
        .tint(Theme.purple)
        .onChange(of: state.checkStatus) { _, status in
            if status == .idle { editingPassage = false }
        }
        .onChange(of: state.excerpt) { _, _ in
            contextAddress = ""
        }
        .onExitCommand(perform: actions.dismissPanel)
    }

    private var clipboardButton: some View {
        Button("Check Clipboard") {
            editingPassage = false
            actions.clipboard()
        }
    }

    private var canReviewArticle: Bool { state.loadedArticleURL != nil && state.isReady }

    private var localReview: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editingPassage || state.excerpt.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("New passage").font(.caption).foregroundStyle(Theme.secondary)
                    TextEditor(text: $state.pastedText)
                        .font(.body).scrollContentBackground(.hidden).padding(5).frame(height: 70)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                        .focused($passageFocused)
                        .onAppear { if editingPassage { passageFocused = true } }
                        .accessibilityLabel("New passage to check")
                    if state.excerpt.isEmpty {
                        Button("Preview Clipboard") {
                            actions.previewClipboard()
                            passageFocused = true
                        }
                    }
                    Button("Check text") {
                        state.checkPasted()
                        editingPassage = false
                    }.buttonStyle(PrimaryButton())
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(state.pastedText.trimmed.isEmpty)
                }
            }
            if !editingPassage {
                if canReviewArticle, state.checkStatus != .checking {
                    Button("Review article and citations") { state.reviewLoadedArticle(for: state.findings.first?.quote) }
                        .buttonStyle(PrimaryButton())
                        .keyboardShortcut("f", modifiers: [.command, .shift])
                        .disabled(state.webBusy || state.modelWork != nil)
                        .id("loaded-article-action")
                }
                result
                if !state.excerpt.isEmpty { checkedPassage }
            }
            if !state.excerpt.isEmpty, !editingPassage {
                if !canReviewArticle, !state.context.trimmed.isEmpty, state.isReady, state.checkStatus != .checking {
                    Button("Review what the context supports", action: state.reviewContext).disabled(state.webBusy)
                }
                DisclosureGroup(state.context.isEmpty ? "Add context" : "Edit context", isExpanded: $state.contextExpanded) {
                    Text("Add the headline or nearby paragraphs to see what they clarify.")
                        .font(.caption).foregroundStyle(Theme.secondary).padding(.top, 5)
                    TextEditor(text: $state.context)
                        .font(.body).scrollContentBackground(.hidden).padding(5).frame(minHeight: 64, maxHeight: 110)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                        .accessibilityLabel("Additional context")
                    HStack {
                        Button("Check again", action: state.checkAgain).buttonStyle(PrimaryButton())
                            .disabled(state.checkStatus == .checking || !state.isReady)
                        Button("Paste context", action: actions.pasteContext)
                    }
                    TextField("Public page URL (HTTPS)", text: $contextAddress)
                    HStack {
                        Button("Load page context") { state.loadPageContext(contextAddress.trimmed) }
                            .disabled(contextAddress.trimmed.isEmpty || state.webBusy || state.checkStatus == .checking)
                        if state.webBusy { Button("Cancel", action: state.cancelWebWork) }
                    }
                    if let status = state.webStatus {
                        Text(status).font(.caption).foregroundStyle(Theme.secondary)
                    }
                }.tint(Theme.purple)
            }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }

    private var checkedPassage: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Checked passage").font(.subheadline.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text(state.source).font(.caption).foregroundStyle(Theme.secondary)
            Text(state.excerpt).lineSpacing(3).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10).background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    @ViewBuilder private var result: some View {
        switch state.checkStatus {
        case .idle:
            EmptyView()
        case .notice(let message):
            Text(message).foregroundStyle(Theme.secondary).textSelection(.enabled)
            HStack {
                if !state.isReady {
                    Button("Open Model Settings", action: actions.openModels).buttonStyle(PrimaryButton())
                } else if !state.excerpt.isEmpty {
                    Button("Check Text", action: state.checkAgain).buttonStyle(PrimaryButton())
                }
                if !state.canReadSelection, state.excerpt.isEmpty { Button("Allow Accessibility", action: actions.accessibility) }
            }
        case .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking locally…")
                Spacer()
                Button("Cancel", action: state.cancelCheck)
            }.accessibilityElement(children: .contain)
        case .findings:
            let groups = FindingGroup.make(from: state.findings, in: state.excerpt)
            ForEach(groups) { group in
                FindingCard(group: group, detail: state.reviewDetail, showsSourceButton: group.id != groups.first?.id) { quote in
                    state.openEvidence(for: quote)
                }
                .id(group.id + state.reviewDetail.rawValue)
            }
        case .noFlags:
            Label("No flags under your enabled rules", systemImage: "checkmark.circle").foregroundStyle(Theme.purple)
        case .needsContext:
            Label("More context needed", systemImage: "text.bubble")
            Text("Add a surrounding paragraph or source details and check again.").font(.callout).foregroundStyle(Theme.secondary)
        case .failed(let error):
            Label("Check failed", systemImage: "exclamationmark.circle").fontWeight(.semibold)
            Text(error).textSelection(.enabled)
            Button("Try again", action: state.checkAgain).disabled(!state.isReady)
        case .cancelled:
            Text("Check cancelled.").foregroundStyle(Theme.secondary)
            Button("Check again", action: state.checkAgain).disabled(!state.isReady)
        }
    }
}

private struct FindingCard: View {
    let group: FindingGroup
    let detail: ReviewDetail
    let showsSourceButton: Bool
    let findEvidence: (String) -> Void

    private var related: [Finding] {
        switch detail {
        case .compact: []
        case .balanced: Array(group.related.prefix(1))
        case .expanded: group.related
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            finding(group.main, primary: true)
            ForEach(related) { item in
                Divider()
                finding(item, primary: false)
            }
            if showsSourceButton {
                Button {
                    findEvidence(group.main.quote)
                } label: {
                    Label("Find sources", systemImage: "magnifyingglass")
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(14).padding(.leading, 3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.findingSurface)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.purple).frame(width: 3) }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.purple.opacity(0.32)).allowsHitTesting(false))
    }

    private func finding(_ item: Finding, primary: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(item.reason)
                .font(primary ? .title3.weight(.semibold) : .body)
                .foregroundStyle(Theme.ink).lineSpacing(3)
                .accessibilityAddTraits(primary ? .isHeader : [])
            Text(item.rule.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(primary ? Theme.purple : Theme.secondary)
            if primary || item.quote != group.main.quote {
                Text("“\(item.quote)”")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(9).background(Theme.quoteSurface, in: RoundedRectangle(cornerRadius: 6))
            }
            (Text("Verify next  ").fontWeight(.semibold) + Text(item.verify))
                .font(.callout).foregroundStyle(Theme.secondary)
        }
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

private struct EvidencePane: View {
    @ObservedObject var state: AppState
    let claim: String
    @Environment(\.openURL) private var openURL
    @FocusState private var queryFocused: Bool
    @State private var query: String
    @State private var links = ""
    @State private var searchLaunchFailed = false

    init(state: AppState, claim: String) {
        self.state = state
        self.claim = claim
        _query = State(initialValue: claim)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Claim under review").font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
                Text(claim).font(.headline).lineSpacing(3).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id("evidence-start")

            if state.webBusy {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(state.webStatus ?? "Reviewing…")
                    Spacer()
                    Button("Cancel", action: state.cancelWebWork)
                }
            } else {
                if state.reviewedEvidenceCount > 0 || state.failedEvidenceCount > 0 {
                    EvidenceResultCard(claim: claim, summary: state.evidenceSummary, citations: state.citations,
                                       detail: state.reviewDetail, suppliedContext: state.reviewedSuppliedContext,
                                       reviewedCount: state.reviewedEvidenceCount, trails: state.citationTrail)
                        .id("evidence-results")
                }
                if let status = state.webStatus { Text(status).font(.callout).foregroundStyle(Theme.secondary) }
            }

            sourceInputs.disabled(state.webBusy)
        }
        .onAppear { queryFocused = state.loadedArticleURL == nil }
    }

    private var sourceInputs: some View {
        VStack(alignment: .leading, spacing: 10) {
            if state.loadedArticleURL != nil, state.reviewedEvidenceCount == 0 {
                Button("Review article and citations") { state.reviewLoadedArticle() }
                    .buttonStyle(PrimaryButton()).disabled(!state.isReady)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Search query").font(.subheadline.weight(.semibold))
                TextField("Search query", text: $query, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                    .focused($queryFocused)
                if state.loadedArticleURL == nil {
                    searchButton.buttonStyle(PrimaryButton())
                } else {
                    searchButton.buttonStyle(.bordered)
                }
                Text("Sends this query to Google in your browser.")
                    .font(.caption).foregroundStyle(Theme.secondary)
                if searchLaunchFailed {
                    Text("Couldn’t open your browser. Copy the query to search there.").font(.callout)
                }
            }

            Divider().padding(.vertical, 3)

            VStack(alignment: .leading, spacing: 7) {
                Text("Source links").font(.subheadline.weight(.semibold))
                TextField("Paste up to 3 public HTTPS links, one per line", text: $links, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityLabel("Public source links")
                Button("Review links and citations") { state.findEvidence(addresses: addresses) }
                    .buttonStyle(.bordered)
                    .disabled(!(1...3).contains(addresses.count) || !state.isReady)
                if addresses.count > 3 {
                    Text("Use up to 3 source links per review.").font(.caption).foregroundStyle(Theme.secondary)
                } else if !state.isReady {
                    Text("Set up a local model to review sources.").font(.caption).foregroundStyle(Theme.secondary)
                }
                if !state.context.trimmed.isEmpty {
                    Button("Review supplied context", action: state.reviewContext).disabled(!state.isReady)
                }
            }
        }
    }

    private var searchButton: some View {
        Button("Search Google", systemImage: "arrow.up.right.square", action: searchGoogle)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(query.trimmed.isEmpty)
    }

    private func searchGoogle() {
        let editedQuery = query.trimmed
        guard !editedQuery.isEmpty, !state.webBusy else { return }
        // Launch Services can deliver the completion off the main actor.
        openURL(EvidenceWeb.browserSearch(editedQuery)) { @Sendable accepted in
            Task { @MainActor in searchLaunchFailed = !accepted }
        }
    }

    private var addresses: [String] {
        links.split(whereSeparator: \.isNewline).map { String($0).trimmed }.filter { !$0.isEmpty }
    }
}

private struct EvidenceResultCard: View {
    let claim: String
    let summary: EvidenceSynthesis
    let citations: [EvidenceCitation]
    let detail: ReviewDetail
    let suppliedContext: Bool
    let reviewedCount: Int
    let trails: [EvidenceTrail]
    @State private var copiedEvidence = false

    private var additional: [EvidenceCitation] {
        let passages = citations.filter { $0.id != summary.lead?.id && $0.id != summary.counterpoint?.id }
        switch detail {
        case .compact: return []
        case .balanced: return Array(passages.prefix(1))
        case .expanded: return passages
        }
    }

    private var coverage: String {
        if suppliedContext { return reviewedCount == 0 ? "Supplied context could not be reviewed" : "Based on your supplied context" }
        return "\(reviewedCount) source\(reviewedCount == 1 ? "" : "s") reviewed"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(coverage).font(.caption.weight(.medium)).foregroundStyle(Theme.secondary)
                Spacer()
                if let text = summary.copyText(for: claim) {
                    Button(copiedEvidence ? "Copied" : "Copy evidence", systemImage: copiedEvidence ? "checkmark" : "doc.on.doc") {
                        let clipboard = NSPasteboard.general
                        clipboard.clearContents()
                        copiedEvidence = clipboard.setString(text, forType: .string)
                    }.buttonStyle(.bordered)
                }
            }
            Label(summary.title, systemImage: summary.symbol)
                .font(.title2.weight(.semibold)).foregroundStyle(Theme.ink)
                .accessibilityAddTraits(.isHeader)
            if let lead = summary.lead {
                if let assessment = lead.assessment { partHeading(assessment) }
                passage(lead, label: summary.counterpoint != nil || lead.assessment != nil)
            }
            if let counterpoint = summary.counterpoint { passage(counterpoint, label: true) }
            if !summary.explanation.trimmed.isEmpty {
                Text(summary.explanation.trimmed).font(.callout).foregroundStyle(Theme.secondary).lineSpacing(2)
            }
            if summary.parts.isEmpty {
                ForEach(additional) { citation in passage(citation, label: true) }
            } else {
                ForEach(summary.parts) { part in
                    let quotes = visibleQuotes(for: part)
                    if !quotes.isEmpty {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            partHeading(part.assessment)
                            ForEach(quotes) { citation in passage(citation, label: true) }
                        }
                    }
                }
            }
            if !trails.isEmpty { citationTrail }
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.findingSurface, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(Theme.border).allowsHitTesting(false))
    }

    private func partHeading(_ assessment: EvidenceAssessment) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(assessment.dimension.title).font(.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            Text("“\(assessment.text)”").font(.headline).textSelection(.enabled).accessibilityAddTraits(.isHeader)
        }
    }

    private func visibleQuotes(for part: EvidencePart) -> [EvidenceCitation] {
        let featuredIDs = Set([summary.lead?.id, summary.counterpoint?.id].compactMap { $0 })
        let selectedCount = part.citations.filter { featuredIDs.contains($0.id) }.count
        let citedURLs = Set(trails.filter { $0.status == .reviewed }.map(\.sourceURL))
        let cited = part.citations.filter { $0.url.map(citedURLs.contains) == true }
        var seen = featuredIDs
        let quotes = (cited + part.citations).filter { seen.insert($0.id).inserted }
        let limit = detail == .expanded ? quotes.count : max(0, (detail == .balanced ? 2 : 1) - selectedCount)
        return Array(quotes.prefix(limit))
    }

    private var citationTrail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
            Text("Citation trail").font(.headline).accessibilityAddTraits(.isHeader)
            let sources = trails.reduce(into: [URL]()) { urls, trail in
                if !urls.contains(trail.sourceURL) { urls.append(trail.sourceURL) }
            }
            ForEach(sources, id: \.self) { url in
                let branches = trails.filter { $0.sourceURL == url }
                if let first = branches.first {
                    VStack(alignment: .leading, spacing: 4) {
                        Link(first.sourceTitle, destination: url).foregroundStyle(Theme.purple).font(.subheadline.weight(.medium))
                        Text(first.status.rawValue).font(.caption).foregroundStyle(Theme.secondary)
                        ForEach(branches) { branch in
                            Link("Cited by \(branch.articleTitle)", destination: branch.articleURL)
                                .font(.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
        }
    }

    private func passage(_ citation: EvidenceCitation, label: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if label {
                Text(citation.label).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.purple)
            }
            Text(citation.explanation).font(.body).lineSpacing(3).textSelection(.enabled)
            if let basis = citation.assessment, summary.counterpoint != nil || detail == .expanded {
                let details = [("Measure", basis.measure), ("Group", basis.group), ("Period", basis.period)]
                    .compactMap { label, value in value.map { "\(label) · \($0)" } }
                if !details.isEmpty {
                    Text(details.joined(separator: "   ")).font(.caption).foregroundStyle(Theme.secondary).textSelection(.enabled)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("“\(citation.quote)”").lineSpacing(3).textSelection(.enabled)
                if let url = citation.url {
                    Link(citation.title, destination: url).foregroundStyle(Theme.purple).font(.caption)
                    if let date = citation.publishedDate {
                        Text(date).foregroundStyle(Theme.secondary).font(.caption)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.quoteSurface, in: RoundedRectangle(cornerRadius: 7))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

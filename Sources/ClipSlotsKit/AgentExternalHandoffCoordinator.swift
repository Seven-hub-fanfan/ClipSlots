import Foundation
import Combine

@MainActor
public protocol AgentExternalHandoffOpening {
    func applicationAvailable(bundleID: String) -> Bool
    func openApplication(bundleID: String) async -> AgentExternalOpenOutcome
    func openURL(_ url: URL) async -> AgentExternalOpenOutcome
    func copyPrompt(_ prompt: String) -> Bool
}

public enum AgentExternalHandoffCoordinator {
    public static func prepare(provider: AgentExternalProvider, context: AgentExternalProjectContext,
                               copyFallback: Bool = true) throws -> AgentExternalLaunchPlan {
        // Validate even if the caller did not obtain this provider from a catalog.
        _ = try AgentExternalProviderCatalog(providers: [provider])
        let prompt = try context.prompt()
        var notes: [String] = []
        var targets: [AgentExternalLaunchTarget] = []
        func target(kind: AgentExternalLaunchKind, endpoint: AgentExternalURLTarget?,
                    bundle: String?) throws -> AgentExternalLaunchTarget {
            var transport: AgentExternalPromptTransport = endpoint?.promptQueryItem == nil ? .clipboard : .urlQuery
            var url = try endpoint?.url(prompt: transport == .urlQuery ? prompt : nil)
            if let candidate = url, candidate.absoluteString.utf8.count > 8192 {
                transport = .clipboard
                url = try endpoint?.url(prompt: nil)
                notes.append("The \(kind.rawValue) prompt URL is too long. Copy/paste will be used instead.")
            }
            return .init(kind: kind, url: url, bundleID: bundle, promptTransport: transport)
        }
        if provider.desktopBundleID != nil || provider.desktopTarget != nil {
            targets.append(try target(kind: .desktop, endpoint: provider.desktopTarget, bundle: provider.desktopBundleID))
        }
        if let endpoint = provider.webTarget {
            targets.append(try target(kind: .web, endpoint: endpoint, bundle: nil))
        }
        notes.append("Opening a client or copying a prompt does not mean a message was sent or MCP was connected.")
        return .init(provider: provider, context: context, prompt: prompt,
                     targets: targets, copyFallback: copyFallback, notes: notes)
    }

    /// Invoke only in response to an explicit user action. No transport sends a message.
    @MainActor
    public static func execute(_ plan: AgentExternalLaunchPlan,
                               using opener: AgentExternalHandoffOpening,
                               canContinue: @MainActor () -> Bool = { true }) async -> AgentExternalHandoffResult {
        var copied = false
        var attempts: [AgentExternalOpenOutcome] = []
        for target in plan.targets {
            guard !Task.isCancelled, canContinue() else {
                return .init(status: .failed, promptCopied: copied, attempts: attempts,
                             message: "Handoff cancelled. No message was sent.")
            }
            if target.kind == .desktop, let bundle = target.bundleID,
               !opener.applicationAvailable(bundleID: bundle) {
                attempts.append(.unsupported)
                continue
            }
            if target.promptTransport == .clipboard, !copied {
                copied = opener.copyPrompt(plan.prompt)
                guard copied else {
                    return .init(status: .failed, promptCopied: false, attempts: attempts,
                                 message: "The prompt could not be copied. No client was opened and no message was sent.")
                }
            }
            let outcome: AgentExternalOpenOutcome
            if let url = target.url { outcome = await opener.openURL(url) }
            else if let bundle = target.bundleID { outcome = await opener.openApplication(bundleID: bundle) }
            else { outcome = .unsupported }
            attempts.append(outcome)
            if outcome == .opened {
                return .init(status: target.kind == .desktop ? .openedDesktop : .openedWeb,
                    promptCopied: copied, attempts: attempts,
                    message: copied ? "Client opened. Prompt copied; paste and review it manually. No message was sent."
                        : "Client opened with a prompt URL. Delivery is unverified; no message was sent by ClipSlots.")
            }
        }
        guard !Task.isCancelled, canContinue() else {
            return .init(status: .failed, promptCopied: copied, attempts: attempts,
                         message: "Handoff cancelled. No message was sent.")
        }
        if plan.copyFallback {
            if !copied { copied = opener.copyPrompt(plan.prompt) }
            return .init(status: copied ? .copiedOnly : .failed, promptCopied: copied, attempts: attempts,
                message: copied ? "Prompt copied only. No client accepted the launch and no message was sent."
                    : "No client could be opened and the clipboard operation failed. No message was sent.")
        }
        let failed = attempts.contains { if case .failed = $0 { return true }; return false }
        return .init(status: failed ? .failed : .unsupported, promptCopied: copied, attempts: attempts,
                     message: "No configured client could be opened. No message was sent.")
    }
}

@MainActor
public final class AgentExternalHandoffPreferences {
    private let defaults: UserDefaults
    private let key: String
    public init(defaults: UserDefaults = .standard, key: String = "clipslots.agent.external.last-used") {
        self.defaults = defaults; self.key = key
    }

    public func resolve(in providers: [AgentExternalProvider]) -> String? {
        let saved = defaults.string(forKey: key)
        let selected = providers.first { $0.id == saved }?.id ?? providers.first?.id
        if let selected { defaults.set(selected, forKey: key) }
        else { defaults.removeObject(forKey: key) }
        return selected
    }

    public func select(_ id: String, in providers: [AgentExternalProvider]) -> Bool {
        guard providers.contains(where: { $0.id == id }) else { return false }
        defaults.set(id, forKey: key)
        return true
    }
}

/// Only the provider preference survives close/reopen. Results and in-flight UI state do not.
@MainActor
public final class AgentExternalHandoffSession: ObservableObject {
    @Published public private(set) var selectedProviderID: String?
    @Published public private(set) var result: AgentExternalHandoffResult?
    @Published public private(set) var isPresented = false
    @Published public private(set) var isExecuting = false
    @Published public private(set) var providers: [AgentExternalProvider]
    private let catalog: AgentExternalProviderCatalog
    private let preferences: AgentExternalHandoffPreferences
    private var generation = UUID()
    private var context: AgentExternalProjectContext

    public init(catalog: AgentExternalProviderCatalog, context: AgentExternalProjectContext,
                preferences: AgentExternalHandoffPreferences) {
        self.catalog = catalog
        self.context = context
        self.providers = catalog.visibleProviders(region: context.region, language: context.language)
        self.preferences = preferences
    }

    public var selectedProvider: AgentExternalProvider? { providers.first { $0.id == selectedProviderID } }

    public func present() {
        generation = UUID(); isPresented = true; isExecuting = false; result = nil
        selectedProviderID = preferences.resolve(in: providers)
    }

    public func update(context: AgentExternalProjectContext) {
        close()
        self.context = context
        providers = catalog.visibleProviders(region: context.region, language: context.language)
        present()
    }

    public func select(_ id: String) {
        guard isPresented, !isExecuting, preferences.select(id, in: providers) else { return }
        selectedProviderID = id; result = nil; generation = UUID()
    }

    public func close() {
        generation = UUID(); isPresented = false; isExecuting = false; result = nil
        selectedProviderID = nil
    }

    public func launch(context: AgentExternalProjectContext, using opener: AgentExternalHandoffOpening) async throws -> AgentExternalHandoffResult? {
        guard isPresented, !isExecuting, context == self.context, let provider = selectedProvider else { return nil }
        let plan = try AgentExternalHandoffCoordinator.prepare(provider: provider, context: context)
        let ticket = generation
        isExecuting = true
        let response = await AgentExternalHandoffCoordinator.execute(plan, using: opener, canContinue: { [weak self] in
            self?.isPresented == true && self?.generation == ticket
        })
        guard isPresented, generation == ticket else { return nil }
        isExecuting = false; result = response
        return response
    }

    public func copy(context: AgentExternalProjectContext, using opener: AgentExternalHandoffOpening) throws -> AgentExternalHandoffResult? {
        guard isPresented, !isExecuting, context == self.context else { return nil }
        let copied = opener.copyPrompt(try context.prompt())
        let response = AgentExternalHandoffResult(status: copied ? .copiedOnly : .failed,
            promptCopied: copied, attempts: [],
            message: copied ? "Prompt copied only. No message was sent." : "The prompt could not be copied. No message was sent.")
        result = response
        return response
    }
}

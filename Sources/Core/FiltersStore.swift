import Foundation
import Combine

/// Notification filters, mirroring Gitify's filter model
/// (gitify/src/renderer/stores/useFiltersStore.ts + utils/notifications/filters/).
@MainActor
final class FiltersStore: ObservableObject {
    /// SubjectType raw values; empty = no filter.
    @Published var subjectTypes: Set<String> { didSet { save() } }
    /// State buckets: open / closed / merged / draft / other.
    @Published var states: Set<String> { didSet { save() } }
    /// Reason codes (e.g. "mention", "review_requested").
    @Published var reasons: Set<String> { didSet { save() } }
    /// Author user types: User / Bot / Organization.
    @Published var userTypes: Set<String> { didSet { save() } }
    /// Search tokens with qualifier prefixes org:/repo:/author:.
    @Published var includeTokens: [String] { didSet { save() } }
    @Published var excludeTokens: [String] { didSet { save() } }

    static let stateBuckets = ["open", "closed", "merged", "draft", "other"]
    static let userTypeOptions = ["User", "Bot", "Organization"]
    static let searchQualifiers = ["org:", "repo:", "author:"]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        subjectTypes = Set(defaults.stringArray(forKey: "filter.subjectTypes") ?? [])
        states = Set(defaults.stringArray(forKey: "filter.states") ?? [])
        reasons = Set(defaults.stringArray(forKey: "filter.reasons") ?? [])
        userTypes = Set(defaults.stringArray(forKey: "filter.userTypes") ?? [])
        includeTokens = defaults.stringArray(forKey: "filter.includeTokens") ?? []
        excludeTokens = defaults.stringArray(forKey: "filter.excludeTokens") ?? []
    }

    var hasActiveFilters: Bool {
        !subjectTypes.isEmpty || !states.isEmpty || !reasons.isEmpty
            || !userTypes.isEmpty || !includeTokens.isEmpty || !excludeTokens.isEmpty
    }

    func reset() {
        subjectTypes = []
        states = []
        reasons = []
        userTypes = []
        includeTokens = []
        excludeTokens = []
    }

    // MARK: - Matching

    /// Applies base + detailed filters. Detailed filters (state, author, user type)
    /// only apply when enrichment is enabled, matching Gitify.
    func matches(_ notification: GHNotification, detail: SubjectDetail?, detailedEnabled: Bool) -> Bool {
        // Base filters (no enrichment required)
        if !subjectTypes.isEmpty, !subjectTypes.contains(notification.subject.type.rawValue) {
            return false
        }
        if !reasons.isEmpty, !reasons.contains(notification.reason) {
            return false
        }
        let org = notification.repository.owner.login
        let repo = notification.repository.fullName
        if !matchesSearch(qualifier: "org:", value: org) { return false }
        if !matchesSearch(qualifier: "repo:", value: repo) { return false }

        guard detailedEnabled else { return true }

        // Detailed filters
        if !states.isEmpty {
            let bucket = detail?.state?.filterBucket ?? "other"
            if !states.contains(bucket) { return false }
        }
        if !userTypes.isEmpty {
            // Unknown author types pass through (Gitify matches on enriched data only).
            if let authorType = detail?.authorType {
                let normalized = authorType == "EnterpriseUserAccount" ? "User" : authorType
                if !userTypes.contains(normalized) { return false }
            }
        }
        if !matchesSearch(qualifier: "author:", value: detail?.author) { return false }
        return true
    }

    /// Include tokens for a qualifier: value must match at least one.
    /// Exclude tokens: value must match none. Exact, case-insensitive.
    private func matchesSearch(qualifier: String, value: String?) -> Bool {
        let includes = tokens(includeTokens, qualifier: qualifier)
        let excludes = tokens(excludeTokens, qualifier: qualifier)
        guard !includes.isEmpty || !excludes.isEmpty else { return true }
        let normalized = value?.lowercased()
        if !includes.isEmpty {
            guard let normalized, includes.contains(normalized) else { return false }
        }
        if let normalized, excludes.contains(normalized) {
            return false
        }
        return true
    }

    private func tokens(_ list: [String], qualifier: String) -> Set<String> {
        Set(
            list.filter { $0.lowercased().hasPrefix(qualifier) }
                .map { String($0.dropFirst(qualifier.count)).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    private func save() {
        defaults.set(Array(subjectTypes), forKey: "filter.subjectTypes")
        defaults.set(Array(states), forKey: "filter.states")
        defaults.set(Array(reasons), forKey: "filter.reasons")
        defaults.set(Array(userTypes), forKey: "filter.userTypes")
        defaults.set(includeTokens, forKey: "filter.includeTokens")
        defaults.set(excludeTokens, forKey: "filter.excludeTokens")
    }
}

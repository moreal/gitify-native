import SwiftUI

struct FiltersView: View {
    @EnvironmentObject private var filters: FiltersStore
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var notificationsStore: NotificationsStore
    let onClose: () -> Void

    @State private var includeText = ""
    @State private var excludeText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text("Filters")
                    .font(.headline)
                Spacer()
                if filters.hasActiveFilters {
                    Button("Clear all") { filters.reset() }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            Form {
                Section("Search") {
                    TextField("Include (org:foo repo:foo/bar author:bot)", text: $includeText)
                        .onSubmit { filters.includeTokens = parseTokens(includeText) }
                    TextField("Exclude (org:foo repo:foo/bar author:bot)", text: $excludeText)
                        .onSubmit { filters.excludeTokens = parseTokens(excludeText) }
                }

                Section("Type") {
                    ForEach(subjectTypeOptions, id: \.0) { raw, title in
                        filterToggle(title, count: typeCount(raw), isOn: binding(for: raw, in: \.subjectTypes))
                    }
                }

                Section("State") {
                    ForEach(FiltersStore.stateBuckets, id: \.self) { bucket in
                        filterToggle(
                            bucket.capitalized,
                            count: stateCount(bucket),
                            isOn: binding(for: bucket, in: \.states)
                        )
                        .disabled(!settings.detailedNotifications)
                    }
                }

                Section("Author type") {
                    ForEach(FiltersStore.userTypeOptions, id: \.self) { type in
                        filterToggle(type, count: nil, isOn: binding(for: type, in: \.userTypes))
                            .disabled(!settings.detailedNotifications)
                    }
                }

                Section("Reason") {
                    ForEach(reasonOptions, id: \.0) { code, title in
                        filterToggle(title, count: reasonCount(code), isOn: binding(for: code, in: \.reasons))
                    }
                }
            }
            .formStyle(.grouped)
            // Drop the grouped form's opaque backdrop so the popover material
            // shows through, matching the notifications list surface.
            .scrollContentBackground(.hidden)
        }
        .onAppear {
            includeText = filters.includeTokens.joined(separator: " ")
            excludeText = filters.excludeTokens.joined(separator: " ")
        }
    }

    // MARK: - Rows

    private func filterToggle(_ title: String, count: Int?, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack {
                Text(title)
                Spacer()
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func binding(
        for value: String,
        in keyPath: ReferenceWritableKeyPath<FiltersStore, Set<String>>
    ) -> Binding<Bool> {
        Binding(
            get: { filters[keyPath: keyPath].contains(value) },
            set: { enabled in
                if enabled {
                    filters[keyPath: keyPath].insert(value)
                } else {
                    filters[keyPath: keyPath].remove(value)
                }
            }
        )
    }

    // MARK: - Options & counts (over the currently filtered list, like Gitify)

    private var subjectTypeOptions: [(String, String)] {
        [
            (SubjectType.issue.rawValue, "Issues"),
            (SubjectType.pullRequest.rawValue, "Pull Requests"),
            (SubjectType.discussion.rawValue, "Discussions"),
            (SubjectType.release.rawValue, "Releases"),
            (SubjectType.commit.rawValue, "Commits"),
            (SubjectType.checkSuite.rawValue, "Check Suites"),
            (SubjectType.workflowRun.rawValue, "Workflow Runs"),
            (SubjectType.repositoryInvitation.rawValue, "Invitations"),
            (SubjectType.repositoryVulnerabilityAlert.rawValue, "Security Alerts"),
        ]
    }

    private var reasonOptions: [(String, String)] {
        ReasonLabel.titles
            .map { ($0.key, $0.value) }
            .sorted { $0.1 < $1.1 }
    }

    private var visibleNotifications: [GHNotification] {
        notificationsStore.filteredGroups.flatMap(\.notifications)
    }

    private func typeCount(_ raw: String) -> Int {
        visibleNotifications.filter { $0.subject.type.rawValue == raw }.count
    }

    private func reasonCount(_ code: String) -> Int {
        visibleNotifications.filter { $0.reason == code }.count
    }

    private func stateCount(_ bucket: String) -> Int {
        visibleNotifications.filter {
            (notificationsStore.details[$0.id]?.state?.filterBucket ?? "other") == bucket
        }.count
    }

    private func parseTokens(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "," })
            .map(String.init)
            .filter { token in
                FiltersStore.searchQualifiers.contains { token.lowercased().hasPrefix($0) }
            }
    }
}

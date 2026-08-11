import Foundation

/// Enriched subject state, mirroring Gitify's state buckets
/// (gitify/src/renderer/utils/notifications/filters/state.ts).
enum SubjectState: String {
    case open, reopened
    case closed, completed, notPlanned
    case merged, mergeQueue
    case draft
    case answered, resolved, outdated, duplicate
    case success, failure, cancelled, skipped, waiting

    /// Filter bucket mapping (state.ts:66-85).
    var filterBucket: String {
        switch self {
        case .open, .reopened: "open"
        case .closed, .completed, .notPlanned, .resolved, .duplicate: "closed"
        case .merged, .mergeQueue: "merged"
        case .draft: "draft"
        case .answered, .outdated, .success, .failure, .cancelled, .skipped, .waiting: "other"
        }
    }
}

/// Extra detail fetched from the notification's subject API URL
/// (PR/Issue/Discussion — Gitify uses batched GraphQL; we use the REST subject
/// endpoint the notification already points at, cached by url+updatedAt).
struct SubjectDetail: Equatable {
    var htmlUrl: String?
    var number: Int?
    var state: SubjectState?
    /// Subject author — what author:/user-type filters match (upstream subject.author).
    var author: String?
    /// "User" | "Bot" | "Organization" (REST user.type)
    var authorType: String?
    /// Display user for avatars and profile links: the latest commenter when
    /// the notification points at a comment, else the author (upstream subject.user).
    var user: DisplayUser?

    struct DisplayUser: Equatable {
        let login: String
        var avatarUrl: String?
        var htmlUrl: String?
        var type: String?

        init?(json: [String: Any]) {
            guard let login = json["login"] as? String else { return nil }
            self.login = login
            avatarUrl = json["avatar_url"] as? String
            htmlUrl = json["html_url"] as? String
            type = json["type"] as? String
        }
    }

    static func parse(json: [String: Any], type: SubjectType) -> SubjectDetail {
        var detail = SubjectDetail(
            htmlUrl: json["html_url"] as? String,
            number: json["number"] as? Int,
            state: nil
        )
        // PR/Issue/Discussion JSON carries the user under "user";
        // commit and release JSON under "author".
        if let user = json["user"] as? [String: Any] ?? json["author"] as? [String: Any] {
            detail.author = user["login"] as? String
            detail.authorType = user["type"] as? String
            detail.user = DisplayUser(json: user)
        }
        switch type {
        case .pullRequest:
            if json["merged"] as? Bool == true {
                detail.state = .merged
            } else if json["draft"] as? Bool == true {
                detail.state = .draft
            } else if let state = json["state"] as? String {
                detail.state = state == "open" ? .open : .closed
            }
        case .issue:
            switch json["state_reason"] as? String {
            case "completed": detail.state = .completed
            case "not_planned": detail.state = .notPlanned
            case "reopened": detail.state = .reopened
            default:
                if let state = json["state"] as? String {
                    detail.state = state == "open" ? .open : .closed
                }
            }
        case .discussion:
            switch json["state_reason"] as? String {
            case "resolved": detail.state = .resolved
            case "outdated": detail.state = .outdated
            case "duplicate": detail.state = .duplicate
            case "reopened": detail.state = .open
            default:
                detail.state = json["answer_chosen_at"] is String ? .answered : .open
            }
        default:
            break
        }
        return detail
    }

    /// Overlays the latest comment on a commit detail: the commenter becomes
    /// the display user (upstream commit.ts: user = commenter ?? author).
    mutating func applyLatestComment(json: [String: Any]) {
        htmlUrl = json["html_url"] as? String ?? htmlUrl
        if let commenter = (json["user"] as? [String: Any]).flatMap(DisplayUser.init(json:)) {
            user = commenter
        }
    }

    // MARK: - CI subjects (no API URL — parsed from the notification title)

    /// CheckSuite: "<workflow> workflow run[, Attempt #N] <status> for <branch> branch"
    /// (gitify handlers/checkSuite.ts).
    static func parseCheckSuite(title: String, repoHtmlUrl: String) -> SubjectDetail? {
        let pattern = #"^(?<workflowName>.*?) workflow run(, Attempt #(?<attemptNumber>\d+))? (?<statusDisplayName>.*?) for (?<branchName>.*?) branch$"#
        guard let match = title.firstMatch(pattern: pattern) else { return nil }
        let state: SubjectState? = switch match["statusDisplayName"] {
        case "cancelled": .cancelled
        case "failed", "failed at startup": .failure
        case "skipped": .skipped
        case "succeeded": .success
        default: nil
        }
        var filters: [String] = []
        if let workflow = match["workflowName"] {
            filters.append("workflow:\"\(workflow.replacingOccurrences(of: " ", with: "+"))\"")
        }
        if let state { filters.append("is:\(state.rawValue)") }
        if let branch = match["branchName"] { filters.append("branch:\(branch)") }
        return SubjectDetail(htmlUrl: actionsURL(repoHtmlUrl: repoHtmlUrl, filters: filters), state: state)
    }

    /// WorkflowRun: "<user> requested your <status> to deploy to an environment"
    /// (gitify handlers/workflowRun.ts). "review" → waiting.
    static func parseWorkflowRun(title: String, repoHtmlUrl: String) -> SubjectDetail? {
        let pattern = #"^(?<user>.*?) requested your (?<statusDisplayName>.*?) to deploy to an environment$"#
        guard let match = title.firstMatch(pattern: pattern) else { return nil }
        let state: SubjectState? = match["statusDisplayName"] == "review" ? .waiting : nil
        let filters = state.map { ["is:\($0.rawValue)"] } ?? []
        return SubjectDetail(htmlUrl: actionsURL(repoHtmlUrl: repoHtmlUrl, filters: filters), state: state)
    }

    private static func actionsURL(repoHtmlUrl: String, filters: [String]) -> String {
        guard !filters.isEmpty else { return repoHtmlUrl + "/actions" }
        let query = filters.joined(separator: "+")
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        return repoHtmlUrl + "/actions?query=" + query
    }
}

private extension String {
    /// Named-group regex helper for the CI title parsers.
    func firstMatch(pattern: String) -> [String: String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self))
        else { return nil }
        var groups: [String: String] = [:]
        for name in ["workflowName", "attemptNumber", "statusDisplayName", "branchName", "user"] {
            let range = match.range(withName: name)
            if range.location != NSNotFound, let swiftRange = Range(range, in: self) {
                groups[name] = String(self[swiftRange])
            }
        }
        return groups
    }
}

/// Human-readable titles for notification reasons
/// (gitify/src/renderer/utils/notifications/reason.ts).
enum ReasonLabel {
    static let titles: [String: String] = [
        "approval_requested": "Approval Requested",
        "assign": "Assigned",
        "author": "Authored",
        "ci_activity": "Workflow Run Completed",
        "comment": "Commented",
        "invitation": "Invitation Received",
        "manual": "Updated",
        "member_feature_requested": "Member Feature Requested",
        "mention": "Mentioned",
        "review_requested": "Review Requested",
        "security_advisory_credit": "Security Advisory Credit Received",
        "security_alert": "Security Alert Received",
        "state_change": "State Changed",
        "subscribed": "Updated",
        "team_mention": "Team Mentioned",
    ]

    static func title(for reason: String) -> String {
        titles[reason] ?? "Unknown"
    }
}

import AppKit
import CryptoKit
import Security

/// Checks GitHub Releases for a newer build and installs it in place — the
/// zero-dependency stand-in for upstream's electron-updater (no Sparkle).
///
/// In-place install downloads the release `.zip`, verifies its published
/// SHA-256 checksum and code signature (same Developer ID team as the running
/// app), swaps the bundle on disk, and relaunches. When that isn't possible
/// (dev/ad-hoc build, translocated or read-only install location, missing
/// asset) the release page opens in the browser instead.
@MainActor
final class UpdateChecker: ObservableObject {
    struct AppRelease: Equatable {
        let version: String
        let pageURL: URL
        let zipURL: URL?
        let checksumURL: URL?
    }

    enum Phase: Equatable {
        case idle
        case checking
        /// Shown instead of idle after a check finds nothing, as feedback.
        case upToDate
        case available(AppRelease)
        case installing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle

    /// Fires when a check discovers an update worth announcing (AppDelegate
    /// delivers the system banner).
    var onUpdateAvailable: ((AppRelease) -> Void)?

    nonisolated static let repo = "moreal/gitify-native"

    nonisolated static let currentVersion =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"

    /// This build's release-notes page (the Settings footer link).
    static var releaseNotesURL: URL {
        URL(string: "https://github.com/\(repo)/releases/tag/v\(currentVersion)")!
    }

    /// First check shortly after launch, then daily. A repeating timer whose
    /// tick passed during sleep fires on wake.
    func startAutomaticChecks() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            await self?.check()
        }
        let timer = Timer(timeInterval: 24 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.check() }
        }
        timer.tolerance = 3600
        RunLoop.main.add(timer, forMode: .common)
    }

    func check(manual: Bool = false) async {
        guard phase != .checking, phase != .installing else { return }
        let previous = phase
        phase = .checking
        do {
            let latest = try await UpdateInstaller.fetchLatestRelease()
            if let latest, Self.isNewer(latest.version, than: Self.currentVersion) {
                phase = .available(latest)
                if manual || previous != .available(latest) {
                    onUpdateAvailable?(latest)
                }
            } else {
                phase = manual ? .upToDate : .idle
            }
        } catch {
            // Background checks fail quietly (offline is normal) and keep
            // whatever was known; manual checks surface the error.
            phase = manual ? .failed(error.localizedDescription) : previous
        }
    }

    func install() {
        guard case .available(let release) = phase else { return }
        guard let zipURL = release.zipURL else {
            NSWorkspace.shared.open(release.pageURL)
            return
        }
        phase = .installing
        let bundleURL = Bundle.main.bundleURL
        Task {
            // In-place install needs a replaceable, team-signed running copy;
            // otherwise the release page is the update path.
            guard let team = await UpdateInstaller.replaceableTeam(of: bundleURL) else {
                phase = .available(release)
                NSWorkspace.shared.open(release.pageURL)
                return
            }
            do {
                try await UpdateInstaller.downloadVerifyAndSwap(
                    release, zipURL: zipURL, expectedTeam: team, destination: bundleURL
                )
                UpdateInstaller.relaunch()
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    /// Numeric dotted-component compare; prerelease suffixes are ignored
    /// (the `releases/latest` endpoint never serves prereleases).
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            (version.split(separator: "-").first ?? "")
                .split(separator: ".")
                .map { Int($0) ?? 0 }
        }
        let a = parts(candidate)
        let b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}

private struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The non-isolated pipeline: release feed, download, checksum, extraction,
/// signature verification, and the on-disk bundle swap.
private enum UpdateInstaller {
    private static let session = URLSession.makeGitifySession()

    static func fetchLatestRelease() async throws -> UpdateChecker.AppRelease? {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(UpdateChecker.repo)/releases/latest")!
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 { return nil } // no releases published yet
        guard status == 200 else {
            throw UpdateError("GitHub returned HTTP \(status).")
        }

        struct Release: Decodable {
            struct Asset: Decodable {
                let name: String
                let url: URL
                enum CodingKeys: String, CodingKey {
                    case name
                    case url = "browser_download_url"
                }
            }
            let tagName: String
            let htmlURL: URL
            let assets: [Asset]
            enum CodingKeys: String, CodingKey {
                case tagName = "tag_name"
                case htmlURL = "html_url"
                case assets
            }
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        let version = release.tagName.hasPrefix("v")
            ? String(release.tagName.dropFirst())
            : release.tagName
        let zip = release.assets.first { $0.name.hasPrefix("Gitify-") && $0.name.hasSuffix(".zip") }
        let checksum = zip.flatMap { zip in
            release.assets.first { $0.name == zip.name + ".sha256" }
        }
        return UpdateChecker.AppRelease(
            version: version,
            pageURL: release.htmlURL,
            zipURL: zip?.url,
            checksumURL: checksum?.url
        )
    }

    /// The signing team when an in-place swap is possible: a Developer ID
    /// team plus a writable, non-translocated bundle. nil → browser fallback
    /// (dev/ad-hoc builds have no team).
    static func replaceableTeam(of bundleURL: URL) async -> String? {
        let fm = FileManager.default
        guard !bundleURL.path.contains("/AppTranslocation/"),
              fm.isWritableFile(atPath: bundleURL.path),
              fm.isWritableFile(atPath: bundleURL.deletingLastPathComponent().path)
        else { return nil }
        return teamIdentifier(of: bundleURL)
    }

    static func downloadVerifyAndSwap(
        _ release: UpdateChecker.AppRelease,
        zipURL: URL,
        expectedTeam: String,
        destination: URL
    ) async throws {
        let fm = FileManager.default
        // Same-volume work directory so the final swap is a rename, not a copy.
        let workDir = try fm.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: destination, create: true
        )
        defer { try? fm.removeItem(at: workDir) }

        // The tiny checksum fetch rides along with the zip download.
        async let expectedChecksum = fetchChecksum(release.checksumURL)
        let (downloaded, response) = try await session.download(from: zipURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError("Downloading the update failed.")
        }
        let zipFile = workDir.appendingPathComponent("Gitify.zip")
        try fm.moveItem(at: downloaded, to: zipFile)

        if let expected = try await expectedChecksum {
            let actual = SHA256.hash(data: try Data(contentsOf: zipFile))
                .map { String(format: "%02x", $0) }
                .joined()
            guard actual == expected else {
                throw UpdateError("The downloaded archive failed checksum verification.")
            }
        }

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-xk", zipFile.path, workDir.path]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else {
            throw UpdateError("Unpacking the update failed.")
        }
        let newApp = workDir.appendingPathComponent("Gitify.app")
        guard fm.fileExists(atPath: newApp.path) else {
            throw UpdateError("The downloaded archive doesn't contain Gitify.app.")
        }
        try verifySignature(of: newApp, expectedTeam: expectedTeam)

        // Swap: old aside → new in place → old removed with the work dir;
        // roll back if the new bundle can't be moved in.
        let oldApp = workDir.appendingPathComponent("Gitify-old.app")
        try fm.moveItem(at: destination, to: oldApp)
        do {
            try fm.moveItem(at: newApp, to: destination)
        } catch {
            try? fm.moveItem(at: oldApp, to: destination)
            throw error
        }
    }

    /// The relaunch must outlive this process: a detached shell waits out our
    /// termination, then opens the swapped bundle.
    static func relaunch() {
        let quoted = Bundle.main.bundlePath.replacingOccurrences(of: "'", with: "'\\''")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "sleep 1; /usr/bin/open '\(quoted)'"]
        try? process.run()
        NSApp.terminate(nil)
    }

    /// First whitespace-delimited token of the `.sha256` asset (shasum format).
    private static func fetchChecksum(_ url: URL?) async throws -> String? {
        guard let url else { return nil }
        let (data, _) = try await session.data(from: url)
        return String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.map(String.init)
    }

    /// The downloaded bundle must carry a valid signature from the same team
    /// as the running app — the trust anchor replacing Sparkle's EdDSA key.
    private static func verifySignature(of appURL: URL, expectedTeam: String) throws {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(appURL as CFURL, [], &staticCode) == errSecSuccess,
              let code = staticCode else {
            throw UpdateError("Couldn't read the downloaded app's signature.")
        }
        let flags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
        )
        guard SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess else {
            throw UpdateError("The downloaded app's code signature is invalid.")
        }
        guard teamIdentifier(of: code) == expectedTeam else {
            throw UpdateError("The downloaded app is signed by a different team.")
        }
    }

    private static func teamIdentifier(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        return teamIdentifier(of: code)
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(
            code, SecCSFlags(rawValue: kSecCSSigningInformation), &info
        ) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }
}

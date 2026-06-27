import Foundation
import Observation
import UIKit

struct ResumableSession {
    let game: GameInfo
    let session: SessionInfo
    let leftAt: Date
    /// The live WebRTC controller — kept alive so we can rejoin without RESUME.
    let streamController: GFNStreamController?
    /// Grace window before we stop offering to resume (GFN keeps the session ~2 min).
    static let gracePeriod: TimeInterval = 110

    var secondsRemaining: Int {
        max(0, Int(Self.gracePeriod - Date().timeIntervalSince(leftAt)))
    }
    var isExpired: Bool { secondsRemaining == 0 }
}

struct LastSessionRecord: Codable {
    let sessionId: String
    let serverIp: String
    let appId: String
    let base: String
    let createdAt: Date
}

@Observable
@MainActor
class GamesViewModel {
    var mainGames: [GameInfo] = []
    var libraryGames: [GameInfo] = []
    var activeSessions: [ActiveSessionInfo] = []
    var isLoading = false
    var showRefreshComplete = false
    var isLibraryLoading = false
    var error: String?
    var libraryError: String?
    var libraryWarning: String?

    var favoriteIds: Set<String> = []
    var preferredStoreIds: [String: String] = [:]
    var recentlyPlayedIds: [String] = []
    var streamSettings: StreamSettings = StreamSettings()
    var subscription: SubscriptionInfo? = nil
    /// Session the user left without ending — available to resume for ~2 minutes.
    var resumableSession: ResumableSession? = nil
    /// Last created session, persisted so we can resume/stop it across app launches.
    var lastSession: LastSessionRecord? = nil
    private let gamesClient = GamesClient()
    private let cloudMatchClient = CloudMatchClient()

    init() {
        if let data = UserDefaults.standard.data(forKey: "gfn.favoriteIds"),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            self.favoriteIds = Set(ids)
        }
        if let data = UserDefaults.standard.data(forKey: "gfn.preferredStores"),
           let stores = try? JSONDecoder().decode([String: String].self, from: data) {
            self.preferredStoreIds = stores
        }
        if let data = UserDefaults.standard.data(forKey: "gfn.recentlyPlayed"),
           let ids = try? JSONDecoder().decode([String].self, from: data) {
            self.recentlyPlayedIds = ids
        }
        if let data = UserDefaults.standard.data(forKey: "gfn.streamSettings"),
           let settings = try? JSONDecoder().decode(StreamSettings.self, from: data) {
            self.streamSettings = settings
        }
        if let data = UserDefaults.standard.data(forKey: "gfn.lastSession"),
           let session = try? JSONDecoder().decode(LastSessionRecord.self, from: data) {
            self.lastSession = session
        }
        // tvOS currently caps at 60 Hz; clamp any saved value to the screen maximum.
        // If Apple raises the cap in a future tvOS release this will automatically unlock.
        let screenMax = UIScreen.main.maximumFramesPerSecond
        if streamSettings.fps > screenMax {
            streamSettings.fps = screenMax
        }
    }

    // MARK: Computed — Entitled Resolutions & FPS

    /// Resolution strings available to the current account tier.
    /// Falls back to a standard preset if no subscription data is available.
    var availableResolutions: [String] {
        guard let resos = subscription?.entitledResolutions, !resos.isEmpty else {
            return ["1280x720", "1920x1080"]
        }
        let unique = Array(Set(resos.map(\.resolutionLabel)))
        return unique.sorted {
            let lw = Int($0.split(separator: "x").first ?? "") ?? 0
            let rw = Int($1.split(separator: "x").first ?? "") ?? 0
            return lw < rw
        }
    }

    /// FPS values available for the currently selected resolution, capped to the
    /// screen's maximum refresh rate. Today tvOS caps at 60 Hz; if Apple raises it
    /// in a future update this will automatically expose the higher option.
    var availableFps: [Int] {
        let maxFps = UIScreen.main.maximumFramesPerSecond
        guard let resos = subscription?.entitledResolutions, !resos.isEmpty else {
            return [30, 60].filter { $0 <= maxFps }
        }
        let parts = streamSettings.resolution.split(separator: "x").compactMap { Int($0) }
        let w = parts.first ?? 1920
        let h = parts.last  ?? 1080
        let matching = resos.filter { $0.widthInPixels == w && $0.heightInPixels == h }
        let source = matching.isEmpty ? resos : matching
        return Array(Set(source.map(\.framesPerSecond))).filter { $0 <= maxFps }.sorted()
    }

    // MARK: Computed — Games

    var continuePlaying: [GameInfo] {
        let sessionAppIds = Set(activeSessions.compactMap { $0.appId })
        return mainGames.filter { game in
            game.variants.contains { v in
                guard let appId = v.appId else { return false }
                return sessionAppIds.contains(appId)
            }
        }
    }

    var favoriteGames: [GameInfo] {
        var seen = Set<String>()
        return mainGames.filter { favoriteIds.contains($0.id) && seen.insert($0.id).inserted }
    }

    var recentlyPlayedGames: [GameInfo] {
        let activeIds = Set(continuePlaying.map { $0.id })
        return recentlyPlayedIds.compactMap { id in
            mainGames.first { $0.id == id && !activeIds.contains($0.id) }
        }
    }

    // MARK: Load

    private static let libraryCacheKey = "gfn.cache.libraryGames.v2"
    private static let mainCacheKey = "gfn.cache.mainGames.v2"

    func load(authManager: AuthManager) async {
        // Invalidate stale v1 cache from the old panels API
        UserDefaults.standard.removeObject(forKey: "gfn.cache.mainGames")
        UserDefaults.standard.removeObject(forKey: "gfn.cache.libraryGames")

        if mainGames.isEmpty, let cached = loadCache(Self.mainCacheKey, as: [GameInfo].self) {
            mainGames = cached
        }
        if libraryGames.isEmpty, let cached = loadCache(Self.libraryCacheKey, as: [GameInfo].self) {
            libraryGames = cached
        }
        let hadCache = !libraryGames.isEmpty || !mainGames.isEmpty
        isLoading = true
        isLibraryLoading = true
        error = nil
        libraryError = nil
        libraryWarning = nil
        do {
            let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl

            async let mainLoad: Void = loadMainGames(authManager: authManager, base: base)
            async let libraryLoad: Void = loadLibraryGames(authManager: authManager, base: base)
            _ = await (mainLoad, libraryLoad)

            let token = try await authManager.resolveToken()
            activeSessions = (try? await cloudMatchClient.getActiveSessions(token: token, base: base)) ?? []
            if let userId = authManager.session?.user.userId {
                let vpcId = (try? await MESClient.shared.fetchVpcId(token: token, base: base)) ?? ""
                if let sub = try? await MESClient.shared.fetchSubscription(token: token, vpcId: vpcId, userId: userId) {
                    subscription = sub
                }
            }

            saveCache(Self.mainCacheKey, data: mainGames)
            saveCache(Self.libraryCacheKey, data: libraryGames)
        } catch {
            if !hadCache { self.error = error.localizedDescription }
        }
        isLibraryLoading = false
        isLoading = false
        if hadCache {
            showRefreshComplete = true
        }
    }

    private func cacheFileUrl(_ key: String) -> URL? {
        try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("\(key).json")
    }

    private func loadCache<T: Decodable>(_ key: String, as type: T.Type) -> T? {
        guard let url = cacheFileUrl(key),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func saveCache<T: Encodable>(_ key: String, data: T) {
        guard let url = cacheFileUrl(key),
              let encoded = try? JSONEncoder().encode(data) else { return }
        try? encoded.write(to: url, options: .atomic)
    }

    private func loadMainGames(authManager: AuthManager, base: String) async {
        do {
            mainGames = try await fetchWithAuthRetry(authManager: authManager) { token in
                try await gamesClient.fetchMainGames(token: token, streamingBaseUrl: base)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadLibraryGames(authManager: AuthManager, base: String) async {
        defer { isLibraryLoading = false }
        do {
            let result = try await fetchWithAuthRetry(authManager: authManager) { token in
                try await gamesClient.fetchLibrary(token: token, streamingBaseUrl: base)
            }
            libraryGames = result.games
            libraryWarning = result.warning
        } catch {
            libraryError = error.localizedDescription
        }
    }

    func refreshLibrary(authManager: AuthManager) async {
        guard !isLibraryLoading else { return }
        isLibraryLoading = true
        libraryError = nil
        libraryWarning = nil
        defer { isLibraryLoading = false }

        do {
            let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
            let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
            let result = try await fetchWithAuthRetry(authManager: authManager) { token in
                try await gamesClient.fetchLibrary(token: token, streamingBaseUrl: base)
            }
            libraryGames = result.games
            libraryWarning = result.warning
        } catch {
            libraryError = error.localizedDescription
        }
    }

    private func fetchWithAuthRetry<T>(
        authManager: AuthManager,
        operation: (String) async throws -> T
    ) async throws -> T {
        let token = try await authManager.resolveToken()
        do {
            return try await operation(token)
        } catch GamesError.unauthorized {
            let refreshedToken = try await authManager.resolveToken(rejecting: token)
            return try await operation(refreshedToken)
        }
    }

    func refreshActiveSessions(authManager: AuthManager) async {
        guard let token = try? await authManager.resolveToken() else { return }
        let streamingUrl = authManager.session?.provider.streamingServiceUrl ?? NVIDIAAuth.defaultStreamingUrl
        let base = streamingUrl.hasSuffix("/") ? String(streamingUrl.dropLast()) : streamingUrl
        activeSessions = (try? await cloudMatchClient.getActiveSessions(token: token, base: base)) ?? []
    }

    // MARK: Recently Played

    func recordPlayed(_ game: GameInfo) {
        recentlyPlayedIds.removeAll { $0 == game.id }
        recentlyPlayedIds.insert(game.id, at: 0)
        if recentlyPlayedIds.count > 10 { recentlyPlayedIds = Array(recentlyPlayedIds.prefix(10)) }
        let data = try? JSONEncoder().encode(recentlyPlayedIds)
        UserDefaults.standard.set(data, forKey: "gfn.recentlyPlayed")
    }

    // MARK: Preferred Store

    func setPreferredStore(gameId: String, variantId: String) {
        preferredStoreIds[gameId] = variantId
        let data = try? JSONEncoder().encode(preferredStoreIds)
        UserDefaults.standard.set(data, forKey: "gfn.preferredStores")
    }

    func preferredVariantId(for game: GameInfo) -> String? {
        preferredStoreIds[game.id] ?? game.variants.first?.id
    }

    func gameWithPreferredStore(_ game: GameInfo) -> GameInfo {
        guard let preferredId = preferredStoreIds[game.id],
              let idx = game.variants.firstIndex(where: { $0.id == preferredId }),
              idx != 0 else { return game }
        var g = game
        let preferred = g.variants.remove(at: idx)
        g.variants.insert(preferred, at: 0)
        return g
    }

    // MARK: Favorites

    func toggleFavorite(_ id: String) {
        if favoriteIds.contains(id) {
            favoriteIds.remove(id)
        } else {
            favoriteIds.insert(id)
        }
        saveFavorites()
    }

    func isFavorite(_ id: String) -> Bool {
        favoriteIds.contains(id)
    }

    // MARK: Persistence

    func saveFavorites() {
        let data = try? JSONEncoder().encode(Array(favoriteIds))
        UserDefaults.standard.set(data, forKey: "gfn.favoriteIds")
    }

    func saveSettings() {
        let data = try? JSONEncoder().encode(streamSettings)
        UserDefaults.standard.set(data, forKey: "gfn.streamSettings")
    }

    func saveLastSession(_ record: LastSessionRecord) {
        lastSession = record
        let data = try? JSONEncoder().encode(record)
        UserDefaults.standard.set(data, forKey: "gfn.lastSession")
    }

    func clearLastSession() {
        lastSession = nil
        UserDefaults.standard.removeObject(forKey: "gfn.lastSession")
    }

    // MARK: Zone Auto-Selection

    private var euZones: [GFNZone] = []
    private var zoneSamples: [String: [Int]] = [:]
    private static let maxSamplesPerZone = 9
    private var backgroundProbeTask: Task<Void, Never>?

    private var probingRegion: String?

    var probeZoneCount: Int = 0
    var probeActiveCount: Int = 0
    var probeBestZone: String?
    var probeBestPing: Int?

    func startBackgroundZoneProbing() {
        let region = streamSettings.zoneRegion.rawValue
        if backgroundProbeTask != nil && probingRegion == region { return }
        backgroundProbeTask?.cancel()
        backgroundProbeTask = nil
        zoneSamples = [:]
        probingRegion = region
        probeZoneCount = 0
        probeActiveCount = 0
        probeBestZone = nil
        probeBestPing = nil
        backgroundProbeTask = Task {
            guard let zones = try? await ZoneClient.shared.fetchZones() else { return }
            euZones = zones.filter { $0.region == region }
            guard !euZones.isEmpty else { return }
            probeZoneCount = euZones.count
            probeActiveCount = euZones.count
            print("[Zones] background probing started: \(euZones.count) \(region) zones")

            var activeZones = euZones
            var index = 0
            while !Task.isCancelled {
                let batchSize = min(5, activeZones.count)
                let batch = (0..<batchSize).map { i in activeZones[(index + i) % activeZones.count] }
                await withTaskGroup(of: (String, Int?).self) { group in
                    for (i, zone) in batch.enumerated() {
                        if i > 0 {
                            try? await Task.sleep(for: .milliseconds(10))
                        }
                        group.addTask {
                            let ms = await ZoneClient.shared.singleProbe(to: zone.zoneUrl)
                            return (zone.id, ms.map { Int($0.rounded()) })
                        }
                    }
                    for await (id, ms) in group {
                        guard let ms else { continue }
                        var existing = zoneSamples[id] ?? []
                        existing.append(ms)
                        if existing.count > Self.maxSamplesPerZone {
                            existing = Array(existing.suffix(Self.maxSamplesPerZone))
                        }
                        zoneSamples[id] = existing
                    }
                }
                index += batchSize

                // After each full pass, halve until 5 or fewer remain
                if index >= activeZones.count && activeZones.count > 5 {
                    let scored = activeZones.compactMap { zone -> (GFNZone, Int)? in
                        guard let samples = zoneSamples[zone.id], !samples.isEmpty else { return nil }
                        let sorted = samples.sorted()
                        return (zone, sorted[sorted.count / 2])
                    }.sorted { $0.1 < $1.1 }
                    let keepCount = max(5, scored.count / 2)
                    activeZones = Array(scored.prefix(keepCount).map { $0.0 })
                    probeActiveCount = activeZones.count
                    print("[Zones] narrowed to \(activeZones.count) zones: \(scored.prefix(keepCount).map { "\($0.0.id)=\($0.1)ms" }.joined(separator: ", "))")
                    index = 0
                }

                // Update best zone from current samples
                let best = activeZones.compactMap { zone -> (String, Int)? in
                    guard let samples = zoneSamples[zone.id], !samples.isEmpty else { return nil }
                    let sorted = samples.sorted()
                    return (zone.id, sorted[sorted.count / 2])
                }.min { $0.1 < $1.1 }
                if let best {
                    probeBestZone = best.0
                    probeBestPing = best.1
                }

                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func scoreZone(_ samples: [Int]) -> (p50: Int, jitter: Int, score: Double)? {
        guard samples.count >= 2 else { return nil }
        let sorted = samples.sorted()
        let p50 = sorted[sorted.count / 2]
        var diffs = 0
        for i in 1..<samples.count {
            diffs += abs(samples[i] - samples[i - 1])
        }
        let jitter = diffs / (samples.count - 1)
        let score = 0.7 * Double(p50) + 0.3 * Double(jitter)
        return (p50, jitter, score)
    }

    func bestZoneUrl(onProgress: @escaping (Int, Int) -> Void) async -> String? {
        let hasData = !zoneSamples.isEmpty
        if hasData {
            return bestZoneFromAccumulated(onProgress: onProgress)
        }
        return await bestZoneFromTournament(onProgress: onProgress)
    }

    private func bestZoneFromAccumulated(onProgress: @escaping (Int, Int) -> Void) -> String? {
        var scored: [(zone: GFNZone, p50: Int, jitter: Int, score: Double)] = []
        for zone in euZones {
            guard let samples = zoneSamples[zone.id],
                  let s = scoreZone(samples) else { continue }
            scored.append((zone, s.p50, s.jitter, s.score))
        }
        guard !scored.isEmpty else { return nil }
        scored.sort { $0.score < $1.score }

        onProgress(0, scored.count)
        print("[Zones] accumulated data: \(scored.map { "\($0.zone.id) p50=\($0.p50)ms jitter=\($0.jitter)ms score=\(String(format: "%.0f", $0.score)) (\(zoneSamples[$0.zone.id]?.count ?? 0) samples)" }.joined(separator: ", "))")

        let winner = scored[0]
        onProgress(1, 1)
        print("[Zones] winner (from background): \(winner.zone.zoneUrl)")
        return winner.zone.zoneUrl
    }

    /// Fallback tournament when no background data is available yet.
    private func bestZoneFromTournament(onProgress: @escaping (Int, Int) -> Void) async -> String? {
        var candidates = euZones
        if candidates.isEmpty {
            guard let zones = try? await ZoneClient.shared.fetchZones() else { return nil }
            candidates = zones.filter { $0.region == streamSettings.zoneRegion.rawValue }
            euZones = candidates
        }
        guard !candidates.isEmpty else { return nil }
        onProgress(0, candidates.count)
        print("[Zones] tournament start: \(candidates.count) \(streamSettings.zoneRegion.rawValue) candidates")

        var round = 1
        while candidates.count > 1 {
            let samples = await measureAll(candidates, duration: 5.0)

            var scored: [(zone: GFNZone, p50: Int, jitter: Int, score: Double)] = []
            for zone in candidates {
                guard let zoneSamples = samples[zone.id],
                      let s = scoreZone(zoneSamples) else { continue }
                scored.append((zone, s.p50, s.jitter, s.score))
            }

            guard !scored.isEmpty else {
                print("[Zones] tournament round \(round): all zones unreachable")
                return nil
            }

            scored.sort { $0.score < $1.score }
            let keepCount = max(1, scored.count / 2)
            let kept = Array(scored.prefix(keepCount))
            print("[Zones] round \(round): \(scored.count)\u{2192}\(keepCount) | kept: \(kept.map { "\($0.zone.id) p50=\($0.p50)ms jitter=\($0.jitter)ms score=\(String(format: "%.0f", $0.score))" }.joined(separator: ", "))")

            candidates = kept.map { $0.zone }
            onProgress(round, candidates.count)
            round += 1
        }

        let winner = candidates[0]
        print("[Zones] winner: \(winner.zoneUrl)")
        return winner.zoneUrl
    }

    private func measureAll(_ zones: [GFNZone], duration: TimeInterval) async -> [String: [Int]] {
        await withTaskGroup(of: (String, [Int]).self) { group in
            for zone in zones {
                group.addTask {
                    let start = Date()
                    var samples: [Int] = []
                    while Date().timeIntervalSince(start) < duration {
                        if let ms = await ZoneClient.shared.singleProbe(to: zone.zoneUrl) {
                            samples.append(Int(ms.rounded()))
                        }
                    }
                    return (zone.id, samples)
                }
            }
            var result: [String: [Int]] = [:]
            for await (id, samples) in group {
                if !samples.isEmpty {
                    result[id] = samples
                }
            }
            return result
        }
    }
}

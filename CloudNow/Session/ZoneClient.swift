import Foundation

// MARK: - Zone Model

struct GFNZone: Identifiable, Equatable {
    let id: String           // e.g. "NP-AWS-US-N-Virginia-1"
    let region: String       // e.g. "US"
    let regionSuffix: String // e.g. "AWS-N-Virginia-1"
    var queuePosition: Int
    let etaMs: Double?
    let zoneUrl: String
    var pingMs: Int?
    var isMeasuring: Bool

    static let regionMeta: [String: (label: String, flag: String)] = [
        "US":   ("North America", "🇺🇸"),
        "EU":   ("Europe", "🇪🇺"),
        "JP":   ("Japan", "🇯🇵"),
        "KR":   ("South Korea", "🇰🇷"),
        "CA":   ("Canada", "🇨🇦"),
        "THAI": ("Southeast Asia", "🇹🇭"),
        "MY":   ("Malaysia", "🇲🇾"),
    ]
}

// MARK: - ZoneClient

actor ZoneClient {
    static let shared = ZoneClient()

    // MARK: Public

    /// Fetches available GFN zones and their queue depths.
    func fetchZones() async throws -> [GFNZone] {
        async let queueTask   = fetchQueueData()
        async let mappingTask = fetchMappingData()
        let (queueData, mappingData) = try await (queueTask, mappingTask)

        let nukedIds = Set(mappingData.compactMap { id, entry in entry.nuked == true ? id : nil })

        return queueData
            .filter { id, _ in id.hasPrefix("NP-") && !id.hasPrefix("NPA-") && !nukedIds.contains(id) }
            .map { zoneId, entry in
                let parts = entry.Region.split(separator: "-", maxSplits: 1).map(String.init)
                return GFNZone(
                    id: zoneId,
                    region: parts.first ?? entry.Region,
                    regionSuffix: parts.count > 1 ? parts[1] : entry.Region,
                    queuePosition: entry.QueuePosition,
                    etaMs: entry.eta,
                    zoneUrl: zoneUrl(for: zoneId),
                    pingMs: nil,
                    isMeasuring: true
                )
            }
            .sorted { $0.queuePosition < $1.queuePosition }
    }

    /// Single HEAD probe returning round-trip time in milliseconds.
    func singleProbe(to url: String) async -> Double? {
        await headProbe(url)
    }

    // MARK: Private

    private func zoneUrl(for zoneId: String) -> String {
        "https://\(zoneId.lowercased()).cloudmatchbeta.nvidiagrid.net/"
    }

    private func headProbe(_ urlString: String) async -> Double? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        let start = Date()
        return try? await {
            _ = try await URLSession.shared.data(for: req)
            return Date().timeIntervalSince(start) * 1000
        }()
    }

    // MARK: API types

    private struct QueueEntry: Decodable {
        let QueuePosition: Int
        let Region: String
        let eta: Double?
        enum CodingKeys: String, CodingKey {
            case QueuePosition
            case Region
            case eta
        }
    }

    private struct MappingEntry: Decodable {
        let nuked: Bool?
    }

    private func fetchQueueData() async throws -> [String: QueueEntry] {
        let url = URL(string: "https://api.printedwaste.com/gfn/queue/")!
        var req = URLRequest(url: url)
        req.setValue("CloudNow/1.0 tvOS", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Response: Decodable { let data: [String: QueueEntry] }
        return try JSONDecoder().decode(Response.self, from: data).data
    }

    private func fetchMappingData() async throws -> [String: MappingEntry] {
        let url = URL(string: "https://remote.printedwaste.com/config/GFN_SERVERID_TO_REGION_MAPPING")!
        var req = URLRequest(url: url)
        req.setValue("CloudNow/1.0 tvOS", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 10
        let (data, _) = try await URLSession.shared.data(for: req)
        struct Response: Decodable { let data: [String: MappingEntry] }
        return try JSONDecoder().decode(Response.self, from: data).data
    }
}


//
//  CoverArtArchiveSource.swift
//  MacTagger — Cover Art Archive 封面源
//
//  它不是独立搜索源，是 MusicBrainz 的封面伴侣：拿 release MBID 换封面。
//  MusicBrainzSource 会把 release MBID 放进 TrackCandidate.albumID。
//
//  实测行为（主会话联网侦察，2026-09-01）：
//  · GET /release/{mbid}/front → **307** → archive.org/download/… → CDN，共 2 跳，需跟随
//  · GET /release/{mbid}      → **307** → archive.org/…/index.json，返回封面清单
//  · 清单里的 image / thumbnails URL 全是 **http://**，必须自行升 https
//  · thumbnails 档位：1200 / 500 / 250（外加原图 image）
//  · 无封面的版本返回 404（很常见，需当正常情况处理而非错误）
//

import Foundation

public struct CoverArtArchiveSource: MetadataSource {

    public let id = "coverartarchive"
    public let displayName = "Cover Art Archive"
    public let capabilities: SourceCapabilities = [.artwork]

    private let http: HTTPClient

    public init() {
        // 走 archive.org CDN，给足超时；无需鉴权。
        self.http = HTTPClient(
            sourceID: "coverartarchive",
            policy: SourcePolicy(minimumInterval: 0.2,
                                 maxRetries: 2,
                                 defaultHeaders: ["Accept": "application/json"],
                                 timeout: 25)
        )
    }

    private static let base = "https://coverartarchive.org"

    // MARK: - 搜索（不支持）

    public func searchTracks(_ query: TrackQuery, limit: Int) async throws -> [TrackCandidate] {
        []   // 本源不做搜索，由 MusicBrainz 提供候选
    }

    // MARK: - 封面

    public func fetchArtwork(_ candidate: TrackCandidate, preferredSize: Int) async throws -> Data? {
        guard let mbid = candidate.albumID, !mbid.isEmpty else { return nil }
        return try await artwork(releaseMBID: mbid, preferredSize: preferredSize)
    }

    /// 按 release MBID 取封面。找不到封面返回 nil（404 是常态，不当错误）。
    public func artwork(releaseMBID mbid: String, preferredSize: Int = 1200) async throws -> Data? {
        // 先查清单挑合适档位；清单不可用时退回 /front 直取。
        if let url = try? await frontURL(releaseMBID: mbid, preferredSize: preferredSize) {
            if let data = try? await http.get(url), !data.isEmpty { return data }
        }
        guard let direct = URL(string: "\(Self.base)/release/\(mbid)/front") else { return nil }
        do {
            let data = try await http.get(direct)
            return data.isEmpty ? nil : data
        } catch SourceError.httpStatus(404) {
            return nil          // 该版本没有封面
        }
    }

    /// 从封面清单里挑出最接近目标尺寸的 front 图 URL。
    public func frontURL(releaseMBID mbid: String, preferredSize: Int = 1200) async throws -> URL? {
        guard let listURL = URL(string: "\(Self.base)/release/\(mbid)") else { return nil }

        let data: Data
        do { data = try await http.get(listURL) }
        catch SourceError.httpStatus(404) { return nil }

        let root = JSONBox(try http.parseJSON(data))
        let images = root["images"].array
        guard !images.isEmpty else { return nil }

        // 优先 front=true 的那张，没有就取第一张
        let picked = images.first { $0["front"].raw as? Bool == true } ?? images[0]

        // thumbnails 档位择优：不小于目标的最小档；都比目标小则取原图
        let thumbs = picked["thumbnails"]
        let available = ["1200": 1200, "500": 500, "250": 250]
            .compactMap { key, size -> (Int, String)? in
                guard let s = thumbs[key].string else { return nil }
                return (size, s)
            }
            .sorted { $0.0 < $1.0 }

        let chosen = available.first { $0.0 >= preferredSize }?.1
            ?? picked["image"].string
            ?? available.last?.1

        guard let raw = chosen else { return nil }
        return URL(string: Self.upgradeToHTTPS(raw))
    }

    /// 清单里的 URL 一律是 http://，升到 https 再用。
    static func upgradeToHTTPS(_ urlString: String) -> String {
        urlString.hasPrefix("http://")
            ? "https://" + urlString.dropFirst("http://".count)
            : urlString
    }
}

import Combine
import Foundation
import AppKit

struct ShixiangUpdateManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let productIdentifier: String
    let version: String
    let build: Int
    let downloadURL: String
    let sha256: String
    let minimumSystemVersion: String
    let releaseNotes: String

    var validatedDownloadURL: URL? {
        guard let url = URL(string: downloadURL), url.scheme?.lowercased() == "https" else {
            return nil
        }
        return url
    }
}

enum ShixiangUpdateStatus: Equatable, Sendable {
    case notConfigured
    case checking
    case upToDate
    case available
    case invalidManifest
    case failed

    var title: String {
        switch self {
        case .notConfigured: return "尚未配置更新源"
        case .checking: return "正在检查更新"
        case .upToDate: return "已是最新版本"
        case .available: return "发现新版本"
        case .invalidManifest: return "更新清单无效"
        case .failed: return "检查更新失败"
        }
    }

    var systemImage: String {
        switch self {
        case .notConfigured: return "lock.shield"
        case .checking: return "arrow.triangle.2.circlepath"
        case .upToDate: return "checkmark.circle.fill"
        case .available: return "arrow.down.circle.fill"
        case .invalidManifest, .failed: return "exclamationmark.triangle"
        }
    }
}

struct ShixiangUpdateCheckResult: Equatable, Sendable {
    let status: ShixiangUpdateStatus
    let manifest: ShixiangUpdateManifest?

    var detail: String {
        switch status {
        case .notConfigured:
            return "当前本地版不访问网络；正式售卖版可配置 HTTPS 更新清单。"
        case .checking:
            return "正在读取版本清单，不会访问音效索引或原始音频。"
        case .upToDate:
            return "当前安装已经是最新版本。"
        case .available:
            guard let manifest else { return "发现新版本。" }
            return "可用版本：\(manifest.version) · Build \(manifest.build)"
        case .invalidManifest:
            return "更新清单缺少必要字段，或下载地址不是 HTTPS。"
        case .failed:
            return "暂时无法读取更新清单，请稍后重试。"
        }
    }
}

struct ShixiangUpdateChecker: Sendable {
    static let productIdentifier = "com.jacksun.shixiang"

    static func evaluate(
        manifestData: Data,
        currentBuild: Int,
        decoder: JSONDecoder = configuredDecoder()
    ) -> ShixiangUpdateCheckResult {
        guard let manifest = try? decoder.decode(ShixiangUpdateManifest.self, from: manifestData),
              manifest.schemaVersion == ShixiangUpdateManifest.currentSchemaVersion,
              manifest.productIdentifier == productIdentifier,
              manifest.build >= 0,
              manifest.validatedDownloadURL != nil,
              manifest.sha256.count == 64,
              manifest.sha256.allSatisfy({ $0.isHexDigit }) else {
            return ShixiangUpdateCheckResult(status: .invalidManifest, manifest: nil)
        }

        let status: ShixiangUpdateStatus = manifest.build > currentBuild ? .available : .upToDate
        return ShixiangUpdateCheckResult(status: status, manifest: manifest)
    }

    static func configuredDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

@MainActor
final class ShixiangUpdateStore: ObservableObject {
    @Published private(set) var result: ShixiangUpdateCheckResult

    private let feedURL: URL?
    private let currentBuild: Int
    private var task: Task<Void, Never>?

    init(bundle: Bundle = .main) {
        let configuredURL = bundle.infoDictionary?["ShixiangUpdateFeedURL"] as? String
        feedURL = configuredURL.flatMap(URL.init(string:))
        currentBuild = Int(bundle.infoDictionary?["CFBundleVersion"] as? String ?? "0") ?? 0
        result = ShixiangUpdateCheckResult(status: feedURL == nil ? .notConfigured : .failed, manifest: nil)
    }

    deinit {
        task?.cancel()
    }

    func check() {
        guard let feedURL, feedURL.scheme?.lowercased() == "https" else {
            result = ShixiangUpdateCheckResult(status: .notConfigured, manifest: nil)
            return
        }

        task?.cancel()
        result = ShixiangUpdateCheckResult(status: .checking, manifest: nil)
        let build = currentBuild
        task = Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(from: feedURL)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    await MainActor.run { self?.result = ShixiangUpdateCheckResult(status: .failed, manifest: nil) }
                    return
                }
                let evaluated = ShixiangUpdateChecker.evaluate(manifestData: data, currentBuild: build)
                await MainActor.run { self?.result = evaluated }
            } catch is CancellationError {
                // A newer check superseded this request.
            } catch {
                await MainActor.run { self?.result = ShixiangUpdateCheckResult(status: .failed, manifest: nil) }
            }
        }
    }

    func openDownloadPage() {
        guard let url = result.manifest?.validatedDownloadURL else { return }
        NSWorkspace.shared.open(url)
    }
}

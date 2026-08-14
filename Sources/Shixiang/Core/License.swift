import CryptoKit
import Combine
import Foundation

enum ShixiangLicenseEdition: String, Codable, Sendable {
    case creator
    case studio
}

struct ShixiangLicenseClaims: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let productIdentifier: String
    let licenseID: String
    let edition: ShixiangLicenseEdition
    let issuedAt: Date
    let expiresAt: Date?
}

enum ShixiangLicenseStatus: String, Codable, Equatable, Sendable {
    case localEdition
    case notActivated
    case active
    case notConfigured
    case malformed
    case invalidSignature
    case wrongProduct
    case expired

    var title: String {
        switch self {
        case .localEdition: return "本地版无需激活"
        case .notActivated: return "尚未激活"
        case .active: return "已激活"
        case .notConfigured: return "正式授权尚未配置"
        case .malformed: return "许可证格式无效"
        case .invalidSignature: return "许可证签名无效"
        case .wrongProduct: return "许可证不属于拾响"
        case .expired: return "许可证已过期"
        }
    }

    var systemImage: String {
        switch self {
        case .active: return "checkmark.seal.fill"
        case .localEdition: return "internaldrive"
        case .notActivated, .notConfigured: return "lock.shield"
        case .malformed, .invalidSignature, .wrongProduct, .expired: return "exclamationmark.shield"
        }
    }

    var detail: String {
        switch self {
        case .localEdition:
            return "当前 Build 使用本地优先模式，不联网、不要求登录或激活。"
        case .notActivated:
            return "正式售卖版可以使用离线签名许可证；当前版本不会限制本地资料库。"
        case .active:
            return "离线许可证已通过本机公钥验证。"
        case .notConfigured:
            return "这份构建没有启用售卖版许可证公钥，因此不会接受许可证。"
        case .malformed:
            return "许可证内容不完整，未写入本机。"
        case .invalidSignature:
            return "许可证签名无法通过验证，未写入本机。"
        case .wrongProduct:
            return "许可证属于其他产品，未写入本机。"
        case .expired:
            return "许可证已超过有效期，未写入本机。"
        }
    }
}

struct ShixiangLicenseVerification: Equatable, Sendable {
    let status: ShixiangLicenseStatus
    let claims: ShixiangLicenseClaims?
}

struct ShixiangLicenseVerifier: Sendable {
    static let productIdentifier = "com.jacksun.shixiang"
    private static let tokenPrefix = "shixiang-v1"

    private let publicKeyData: Data?

    init(publicKeyBase64: String?) {
        if let publicKeyBase64,
           !publicKeyBase64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let data = Data(base64Encoded: publicKeyBase64),
           data.count == 32 {
            publicKeyData = data
        } else {
            publicKeyData = nil
        }
    }

    init(bundle: Bundle = .main) {
        self.init(publicKeyBase64: bundle.infoDictionary?["ShixiangLicensePublicKey"] as? String)
    }

    var isConfigured: Bool { publicKeyData != nil }

    func verify(token: String, now: Date = Date()) -> ShixiangLicenseVerification {
        guard let publicKeyData else {
            return ShixiangLicenseVerification(status: .notConfigured, claims: nil)
        }

        let parts = token.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == Self.tokenPrefix,
              let payloadData = Data(base64URL: parts[1]),
              let signatureData = Data(base64URL: parts[2]),
              !payloadData.isEmpty, !signatureData.isEmpty else {
            return ShixiangLicenseVerification(status: .malformed, claims: nil)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let claims = try? decoder.decode(ShixiangLicenseClaims.self, from: payloadData),
              claims.schemaVersion == ShixiangLicenseClaims.currentSchemaVersion else {
            return ShixiangLicenseVerification(status: .malformed, claims: nil)
        }

        guard claims.productIdentifier == Self.productIdentifier else {
            return ShixiangLicenseVerification(status: .wrongProduct, claims: claims)
        }

        do {
            let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)
            guard publicKey.isValidSignature(signatureData, for: payloadData) else {
                return ShixiangLicenseVerification(status: .invalidSignature, claims: claims)
            }
        } catch {
            return ShixiangLicenseVerification(status: .invalidSignature, claims: claims)
        }

        if let expiresAt = claims.expiresAt, expiresAt <= now {
            return ShixiangLicenseVerification(status: .expired, claims: claims)
        }

        return ShixiangLicenseVerification(status: .active, claims: claims)
    }
}

@MainActor
final class ShixiangLicenseStore: ObservableObject {
    @Published private(set) var verification: ShixiangLicenseVerification

    private let verifier: ShixiangLicenseVerifier
    private let storageURL: URL
    private var token: String?

    init(
        verifier: ShixiangLicenseVerifier = ShixiangLicenseVerifier(),
        storageURL: URL = ShixiangLicenseStore.defaultStorageURL
    ) {
        self.verifier = verifier
        self.storageURL = storageURL
        token = try? String(contentsOf: storageURL, encoding: .utf8)

        if let token {
            verification = verifier.verify(token: token)
        } else if verifier.isConfigured {
            verification = ShixiangLicenseVerification(status: .notActivated, claims: nil)
        } else {
            verification = ShixiangLicenseVerification(status: .localEdition, claims: nil)
        }
    }

    var status: ShixiangLicenseStatus { verification.status }

    @discardableResult
    func install(token newToken: String) -> Bool {
        let trimmed = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = verifier.verify(token: trimmed)
        verification = result
        guard result.status == .active else { return false }

        do {
            try FileManager.default.createDirectory(
                at: storageURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try trimmed.write(to: storageURL, atomically: true, encoding: .utf8)
            token = trimmed
            return true
        } catch {
            verification = ShixiangLicenseVerification(status: .malformed, claims: nil)
            return false
        }
    }

    func clear() {
        try? FileManager.default.removeItem(at: storageURL)
        token = nil
        verification = verifier.isConfigured
            ? ShixiangLicenseVerification(status: .notActivated, claims: nil)
            : ShixiangLicenseVerification(status: .localEdition, claims: nil)
    }

    nonisolated static var defaultStorageURL: URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return root.appendingPathComponent("Shixiang/license.token")
    }
}

private extension Data {
    init?(base64URL string: String) {
        var value = string.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}

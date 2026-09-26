import CryptoKit
import Foundation

struct Claims: Codable {
    let schemaVersion: Int
    let productIdentifier: String
    let licenseID: String
    let edition: String
    let issuedAt: Date
    let expiresAt: Date?
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("发证失败：\(message)\n".utf8))
    exit(2)
}

guard CommandLine.arguments.count >= 3 else {
    fail("用法：issue-license.swift <license-id> <creator|studio> [days|perpetual]")
}

let licenseID = CommandLine.arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
let edition = CommandLine.arguments[2].trimmingCharacters(in: .whitespacesAndNewlines)
guard !licenseID.isEmpty, !licenseID.contains(" "), ["creator", "studio"].contains(edition) else {
    fail("license-id 不能为空且不能含空格，edition 必须是 creator 或 studio")
}

let expiryArgument = CommandLine.arguments.count >= 4 ? CommandLine.arguments[3] : "perpetual"
let issuedAt = Date()
let expiresAt: Date?
if expiryArgument == "perpetual" {
    expiresAt = nil
} else if let days = Double(expiryArgument), days > 0, days.isFinite {
    expiresAt = issuedAt.addingTimeInterval(days * 24 * 60 * 60)
} else {
    fail("有效期必须是正数天数或 perpetual")
}

guard let privateKeyBase64 = ProcessInfo.processInfo.environment["SHIXIANG_LICENSE_PRIVATE_KEY_BASE64"],
      let privateKeyData = Data(base64Encoded: privateKeyBase64),
      privateKeyData.count == 32 else {
    fail("请通过 SHIXIANG_LICENSE_PRIVATE_KEY_BASE64 提供 32 字节 Ed25519 私钥；私钥不会被打印")
}

let privateKey: Curve25519.Signing.PrivateKey
do {
    privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
} catch {
    fail("私钥格式无效")
}

let claims = Claims(
    schemaVersion: 1,
    productIdentifier: "com.jacksun.shixiang",
    licenseID: licenseID,
    edition: edition,
    issuedAt: issuedAt,
    expiresAt: expiresAt
)

let encoder = JSONEncoder()
encoder.dateEncodingStrategy = .iso8601
encoder.outputFormatting = [.sortedKeys]
let payload: Data
do {
    payload = try encoder.encode(claims)
} catch {
    fail("许可证内容编码失败")
}

let signature: Data
do {
    signature = try privateKey.signature(for: payload)
} catch {
    fail("许可证签名失败")
}

func base64URL(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

print("shixiang-v1.\(base64URL(payload)).\(base64URL(signature))")

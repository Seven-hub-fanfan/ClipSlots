import Foundation
import Security
import CryptoKit

struct AppCodeIdentity: Codable, Equatable {
    let bundleID: String
    let version: String
    let path: String
    let requirement: Data
    let codeHash: String
    let signerSHA256: String?
}

/// Signature integrity, signer continuity and DR satisfaction are independent
/// checks. A changed cdhash alone does not imply a lost permission.
enum CodeIdentityInspector {
    enum Transition: String, Codable {
        case compatible, migration, rejected, unknown
    }

    static func inspect(_ url: URL) throws -> AppCodeIdentity {
        var code: SecStaticCode?
        try require(SecStaticCodeCreateWithPath(url as CFURL, [], &code))
        guard let code else { throw failure("无法读取应用签名") }
        try require(SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil))
        var info: CFDictionary?
        try require(SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info))
        guard let dictionary = info as? [String: Any],
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String,
              let plist = dictionary[kSecCodeInfoPList as String] as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              identifier == bundleID else { throw failure("应用标识与签名标识不一致") }
        var requirement: SecRequirement?
        try require(SecCodeCopyDesignatedRequirement(code, [], &requirement))
        guard let requirement else { throw failure("应用缺少代码身份要求") }
        var requirementData: CFData?
        try require(SecRequirementCopyData(requirement, [], &requirementData))
        guard let data = requirementData as Data? else { throw failure("无法读取代码身份要求") }
        let certificate = (dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first
        let signer = certificate.map { hex(Data(SHA256.hash(data: SecCertificateCopyData($0) as Data))) }
        return AppCodeIdentity(bundleID: bundleID,
            version: plist["CFBundleShortVersionString"] as? String ?? "",
            path: url.resolvingSymlinksInPath().path, requirement: data,
            codeHash: hex(dictionary[kSecCodeInfoUnique as String] as? Data ?? Data()),
            signerSHA256: signer)
    }

    static func satisfies(_ identity: AppCodeIdentity, at url: URL) -> Bool {
        var requirement: SecRequirement?
        var code: SecStaticCode?
        guard SecRequirementCreateWithData(identity.requirement as CFData, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate),
                                          requirement) == errSecSuccess
    }

    static func transition(from old: AppCodeIdentity?, to new: AppCodeIdentity,
                           satisfiesPrevious: Bool) -> Transition {
        guard let old else { return .unknown }
        guard old.bundleID == new.bundleID else { return .rejected }
        // A certificate-backed application must not silently accept a new
        // signer or an ad-hoc replacement, even if its declared DR is broad.
        if let signer = old.signerSHA256, signer != new.signerSHA256 { return .rejected }
        if satisfiesPrevious { return .compatible }
        return old.signerSHA256 == nil ? .migration : .rejected
    }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
    private static func failure(_ text: String) -> PermissionRepairCoordinator.Failure {
        .init(message: text)
    }
    private static func require(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw failure("应用签名校验失败（\(status)）："
                + ((SecCopyErrorMessageString(status, nil) as String?) ?? "未知错误"))
        }
    }
}

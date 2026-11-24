import Foundation
import os
import Security

/// Which code signatures an update may carry.
enum UpdateSignature {
    /// Code requirements of the releases; an update must satisfy one of them, and so must the
    /// running app. Adding one is how the signing certificate is changed, and it takes a bridge
    /// release: see "Changing the signing certificate" in docs/wiki/build-and-release.md.
    static let acceptedRequirements = [
        // The self-signed "Moonji Dev" certificate. Exactly the designated requirement of the
        // releases (`codesign -d -r-`), the one macOS attaches permissions to.
        #"identifier "com.moonji.nanowhisper" and certificate root = H"f863580bc89f9e0d63b1fa56b8abbaed8458b1f4""#,
    ]

    /// What the signature seals in a verified bundle's Info.plist.
    struct BundleInfo: Equatable {
        let identifier: String?
        let version: String?
    }

    /// Checks every architecture, the nested code and the resources of `bundle`, and that it
    /// satisfies one of `requirements`. Returns the sealed identifier and version.
    static func verify(_ bundle: URL, requirements: [String] = acceptedRequirements) throws -> BundleInfo {
        let requirement = try makeRequirement(anyOf: requirements)
        var code: SecStaticCode?
        try check(SecStaticCodeCreateWithPath(bundle as CFURL, [], &code), "open the bundle")
        guard let code else { throw UpdateError.signature }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate
            | kSecCSRestrictSymlinks | kSecCSRestrictToAppLike)
        try check(SecStaticCodeCheckValidity(code, flags, requirement), "verify the bundle")

        var information: CFDictionary?
        try check(SecCodeCopySigningInformation(code, [], &information), "read the bundle's Info.plist")
        let plist = (information as? [String: Any])?[kSecCodeInfoPList as String] as? [String: Any]
        return BundleInfo(
            identifier: plist?[kCFBundleIdentifierKey as String] as? String,
            version: plist?["CFBundleShortVersionString"] as? String
        )
    }

    /// Checks that the running process satisfies one of `requirements` and that its bundle has
    /// not changed since it started. Ad-hoc and unsigned builds fail here.
    static func verifyRunningApp(requirements: [String] = acceptedRequirements) throws {
        do {
            let requirement = try makeRequirement(anyOf: requirements)
            var code: SecCode?
            try check(SecCodeCopySelf([], &code), "read the running app's signature")
            guard let code else { throw UpdateError.signature }
            try check(SecCodeCheckValidity(code, [], requirement), "verify the running app")
        } catch {
            throw UpdateError.runningAppNotVerified
        }
    }

    /// With no requirement at all, nothing can be verified: this throws.
    static func makeRequirement(anyOf requirements: [String]) throws -> SecRequirement {
        let text = requirements.map { "(\($0))" }.joined(separator: " or ")
        var requirement: SecRequirement?
        try check(SecRequirementCreateWithString(text as CFString, [], &requirement), "read the requirement")
        guard let requirement else { throw UpdateError.signature }
        return requirement
    }

    private static let logger = Logger(subsystem: BuildFlavor.current.logSubsystem, category: "AutoUpdater")

    private static func check(_ status: OSStatus, _ step: String) throws {
        guard status != errSecSuccess else { return }
        logger.error("Could not \(step): \(status)")
        throw UpdateError.signature
    }
}

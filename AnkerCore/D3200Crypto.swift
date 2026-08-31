import CommonCrypto
import CryptoKit
import Foundation

enum D3200CryptoError: LocalizedError {
    case malformedHandshake
    case keyAgreementFailed
    case invalidFileKey
    case recorderRejectedFile(UInt8)
    case cipherFailure(CCCryptorStatus)

    var errorDescription: String? {
        switch self {
        case .malformedHandshake: "The recorder returned an invalid secure-session response."
        case .keyAgreementFailed: "The recorder's secure-session verification failed."
        case .invalidFileKey: "The recording key could not be verified."
        case let .recorderRejectedFile(code): "The recorder rejected the file request (code \(code))."
        case let .cipherFailure(status): "Audio decryption failed (status \(status))."
        }
    }
}

final class D3200SecureSession {
    private var privateKey: P256.KeyAgreement.PrivateKey?
    private var sessionKey: Data?

    var isReady: Bool { sessionKey?.count == 32 }

    func reset() {
        privateKey = nil
        sessionKey = nil
    }

    func beginHandshake() -> Data {
        let key = P256.KeyAgreement.PrivateKey()
        privateKey = key
        sessionKey = nil
        return key.publicKey.x963Representation
    }

    func completeHandshake(payload: Data) throws {
        guard payload.count >= 97, let privateKey else {
            throw D3200CryptoError.malformedHandshake
        }
        let devicePublicData = Data(payload[0 ..< 65])
        let deviceCheck = Data(payload[65 ..< 97])
        let devicePublic = try P256.KeyAgreement.PublicKey(x963Representation: devicePublicData)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: devicePublic)
        let sharedData = shared.withUnsafeBytes { Data($0) }
        guard Self.constantTimeEqual(sharedData, deviceCheck) else {
            throw D3200CryptoError.keyAgreementFailed
        }
        let derived = shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data([1, 2, 3]),
            sharedInfo: Data([1, 2, 3]),
            outputByteCount: 32
        )
        sessionKey = derived.withUnsafeBytes { Data($0) }
    }

    func unwrapFileKey(encrypted: Data, sessionNonce: Data) throws -> Data {
        guard let sessionKey else { throw D3200CryptoError.keyAgreementFailed }
        let plain = try Self.aesCTR(data: encrypted, key: sessionKey, iv: sessionNonce)
        let magic = Data("soundcored3200".utf8)
        guard plain.count >= magic.count + 32,
              Self.constantTimeEqual(Data(plain.prefix(magic.count)), magic)
        else { throw D3200CryptoError.invalidFileKey }
        return Data(plain.dropFirst(magic.count).prefix(32))
    }

    func decryptAudioChunk(_ data: Data, fileKey: Data, nonce: Data, sequence: UInt32) throws -> Data {
        guard nonce.count >= 12 else { throw D3200CryptoError.invalidFileKey }
        var iv = Data(nonce.prefix(12))
        let blockCounter = sequence &* 10
        iv.append(UInt8((blockCounter >> 24) & 0xFF))
        iv.append(UInt8((blockCounter >> 16) & 0xFF))
        iv.append(UInt8((blockCounter >> 8) & 0xFF))
        iv.append(UInt8(blockCounter & 0xFF))
        return try Self.aesCTR(data: data, key: fileKey, iv: iv)
    }

    private static func aesCTR(data: Data, key: Data, iv: Data) throws -> Data {
        guard [16, 24, 32].contains(key.count), iv.count == 16 else {
            throw D3200CryptoError.invalidFileKey
        }
        var cryptor: CCCryptorRef?
        let createStatus = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    key.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }
        guard createStatus == kCCSuccess, let cryptor else {
            throw D3200CryptoError.cipherFailure(createStatus)
        }
        defer { CCCryptorRelease(cryptor) }

        let outputCapacity = data.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var moved = 0
        let updateStatus = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { inputBytes in
                CCCryptorUpdate(
                    cryptor,
                    inputBytes.baseAddress,
                    data.count,
                    outputBytes.baseAddress,
                    outputCapacity,
                    &moved
                )
            }
        }
        guard updateStatus == kCCSuccess else {
            throw D3200CryptoError.cipherFailure(updateStatus)
        }
        output.count = moved
        return output
    }

    private static func constantTimeEqual(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (a, b) in zip(left, right) { difference |= a ^ b }
        return difference == 0
    }
}

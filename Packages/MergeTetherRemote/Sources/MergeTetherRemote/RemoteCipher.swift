import Foundation
import CryptoKit

@MainActor public final class RemoteCipher {
    public typealias Role = RemotePairing.Role
    nonisolated public static let maximumPayloadBytes = 131_072
    nonisolated public static let maximumFrameBytes = 262_144
    private var pairing: RemotePairing
    private let role: Role
    private let peer: Role
    private let saveEstablishedPairing: (RemotePairing) throws -> Void
    private var seen: [String: Int64] = [:]

    private struct Frame: Codable, Sendable {
        let v: Int
        let session: UUID
        let sender: String
        let senderKey: String
        let at: Int64
        let nonce: String
        let data: String
    }
    public init(pairing: RemotePairing, role: Role, saveEstablishedPairing: @escaping (RemotePairing) throws -> Void) throws {
        guard pairing.version == RemotePairing.protocolVersion, pairing.role == role,
              let bytes = Data(remoteBase64: pairing.privateKey) else { throw RemoteProtocolError.invalid }
        self.pairing = pairing; self.role = role; peer = role == .host ? .phone : .host
        _ = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes)
        self.saveEstablishedPairing = saveEstablishedPairing
    }
    public func sealInBackground<T: Encodable & Sendable>(_ payload: T, now: Date = Date()) async throws -> String {
        let codec = Codec(pairing: pairing, role: role, peer: peer)
        let wire = try await Task.detached { try codec.seal(payload, now: now) }.value
        try Task.checkCancellation()
        return wire
    }
    public func openInBackground<T: Decodable & Sendable>(_ wire: String, as: T.Type, now: Date = Date()) async throws -> T {
        let codec = Codec(pairing: pairing, role: role, peer: peer)
        let decoded = try await Task.detached { try codec.open(wire, as: T.self, now: now) }.value
        try Task.checkCancellation()
        try accept(decoded.frame, now: now)
        return decoded.value
    }
    public func seal<T: Encodable>(_ payload: T, now: Date = Date()) throws -> String {
        try Codec(pairing: pairing, role: role, peer: peer).seal(payload, now: now)
    }
    public func open<T: Decodable>(_ wire: String, as: T.Type, now: Date = Date()) throws -> T {
        let decoded = try Codec(pairing: pairing, role: role, peer: peer).open(wire, as: T.self, now: now)
        try accept(decoded.frame, now: now)
        return decoded.value
    }
    // Background work uses an immutable snapshot. Recheck trust and replay state atomically after
    // returning, since another frame may have established the peer while decoding was suspended.
    private func accept(_ frame: Frame, now: Date) throws {
        guard pairing.peerPublicKey == nil || pairing.peerPublicKey == frame.senderKey else { throw RemoteProtocolError.invalid }
        let milliseconds = now.timeIntervalSince1970 * 1000
        seen = seen.filter { entry in
            let age = milliseconds - Double(entry.value)
            return age <= 60_000
        }
        guard seen[frame.nonce] == nil else { throw RemoteProtocolError.ignored }
        guard seen.count < 2048 else { throw RemoteProtocolError.invalid }
        if pairing.peerPublicKey == nil {
            let established = try pairing.establishing(peer: frame.senderKey, now: now)
            try saveEstablishedPairing(established)
            pairing = established
        }
        seen[frame.nonce] = frame.at
    }
    private struct Codec: Sendable {
        let pairing: RemotePairing
        let role: Role
        let peer: Role
        func seal<T: Encodable>(_ payload: T, now: Date = Date()) throws -> String {
            guard let peerKey = pairing.peerPublicKey else { throw RemoteProtocolError.invalid }
            let plain = try JSONEncoder().encode(payload)
            guard plain.count <= RemoteCipher.maximumPayloadBytes else { throw RemoteProtocolError.oversized }
            let at = Int64(now.timeIntervalSince1970 * 1000)
            let aad = try authenticationData(sender: role.rawValue, senderKey: pairing.publicKey, at: at)
            let sealed = try AES.GCM.seal(plain, using: key(peerKey, sender: role), authenticating: aad)
            let frame = Frame(v: RemotePairing.protocolVersion, session: pairing.sessionID, sender: role.rawValue,
                              senderKey: pairing.publicKey, at: at, nonce: Data(sealed.nonce).remoteBase64,
                              data: (sealed.ciphertext + sealed.tag).remoteBase64)
            return String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
        }
        func open<T: Decodable>(_ wire: String, as: T.Type, now: Date = Date()) throws -> (value: T, frame: Frame) {
            guard wire.utf8.count <= RemoteCipher.maximumFrameBytes else { throw RemoteProtocolError.oversized }
            let frame = try JSONDecoder().decode(Frame.self, from: Data(wire.utf8))
            guard frame.v == RemotePairing.protocolVersion, frame.session == pairing.sessionID, frame.sender == peer.rawValue,
                  pairing.peerPublicKey == nil || pairing.peerPublicKey == frame.senderKey,
                  let nonce = Data(remoteBase64: frame.nonce), nonce.count == 12, nonce.remoteBase64 == frame.nonce,
                  let cipher = Data(remoteBase64: frame.data), cipher.count >= 16 else { throw RemoteProtocolError.invalid }
            let milliseconds = now.timeIntervalSince1970 * 1000
            guard abs(milliseconds - Double(frame.at)) <= 60_000 else { throw RemoteProtocolError.ignored }
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: cipher.dropLast(16), tag: cipher.suffix(16))
            let plain = try AES.GCM.open(box, using: key(frame.senderKey, sender: peer),
                                         authenticating: authenticationData(sender: frame.sender, senderKey: frame.senderKey, at: frame.at))
            guard plain.count <= RemoteCipher.maximumPayloadBytes else { throw RemoteProtocolError.oversized }
            let value = try JSONDecoder().decode(T.self, from: plain)
            return (value, frame)
        }
        private func key(_ peerKey: String, sender: Role) throws -> SymmetricKey {
            guard let bytes = Data(remoteBase64: peerKey), bytes.count == 32, bytes.remoteBase64 == peerKey,
                  let secret = Data(remoteBase64: pairing.secret),
                  let privateBytes = Data(remoteBase64: pairing.privateKey) else { throw RemoteProtocolError.invalid }
            let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateBytes)
            let shared = try privateKey.sharedSecretFromKeyAgreement(with: Curve25519.KeyAgreement.PublicKey(rawRepresentation: bytes))
            return shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: secret,
                sharedInfo: Data("MergeTether remote v2:\(pairing.origin.absoluteString):\(pairing.sessionID.uuidString):\(sender.rawValue)".utf8), outputByteCount: 32)
        }
        private func authenticationData(sender: String, senderKey: String, at: Int64) throws -> Data {
            try JSONSerialization.data(withJSONObject: [RemotePairing.protocolVersion, pairing.room, pairing.sessionID.uuidString, sender, senderKey, at])
        }
    }
}

import Foundation
import CryptoKit

@MainActor public final class RemoteCipher {
    public enum Role: String, Sendable { case host, phone }
    public static let maximumPayloadBytes = 131_072
    public static let maximumFrameBytes = 262_144
    private let room: String
    private let role: Role
    private let peer: Role
    private let ownKey: SymmetricKey
    private let peerKey: SymmetricKey
    private var seen: [String: Int64] = [:]

    private struct Frame: Codable {
        let v: Int
        let sender: String
        let at: Int64
        let nonce: String
        let data: String
    }

    public init(pairing: RemotePairing, role: Role) throws {
        guard let bytes = Data(remoteBase64: pairing.secret) else { throw RemoteProtocolError.invalid }
        self.room = pairing.room
        self.role = role
        peer = role == .host ? .phone : .host
        func key(_ role: Role) -> SymmetricKey {
            HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes),
                salt: Data("MergeTether remote probe v1".utf8), info: Data(role.rawValue.utf8), outputByteCount: 32)
        }
        ownKey = key(role)
        peerKey = key(peer)
    }

    public func seal<T: Encodable>(_ payload: T, now: Date = Date()) throws -> String {
        let plain = try JSONEncoder().encode(payload)
        guard plain.count <= Self.maximumPayloadBytes else { throw RemoteProtocolError.oversized }
        let at = Int64(now.timeIntervalSince1970 * 1000)
        let aad = try authenticationData(sender: role.rawValue, at: at)
        let sealed = try AES.GCM.seal(plain, using: ownKey, authenticating: aad)
        let frame = Frame(v: 1, sender: role.rawValue, at: at, nonce: Data(sealed.nonce).remoteBase64,
                          data: (sealed.ciphertext + sealed.tag).remoteBase64)
        return String(decoding: try JSONEncoder().encode(frame), as: UTF8.self)
    }

    public func open<T: Decodable>(_ wire: String, as: T.Type, now: Date = Date()) throws -> T {
        guard wire.utf8.count <= Self.maximumFrameBytes else { throw RemoteProtocolError.oversized }
        let frame = try JSONDecoder().decode(Frame.self, from: Data(wire.utf8))
        guard frame.v == 1, frame.sender == peer.rawValue,
              let nonce = Data(remoteBase64: frame.nonce), nonce.count == 12, nonce.remoteBase64 == frame.nonce,
              let cipher = Data(remoteBase64: frame.data), cipher.count >= 16 else { throw RemoteProtocolError.invalid }
        let milliseconds = now.timeIntervalSince1970 * 1000
        guard abs(milliseconds - Double(frame.at)) <= 60_000 else { throw RemoteProtocolError.ignored }
        seen = seen.filter { milliseconds - Double($0.value) <= 60_000 }
        guard seen[frame.nonce] == nil else { throw RemoteProtocolError.ignored }
        guard seen.count < 2048 else { throw RemoteProtocolError.invalid }
        let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: cipher.dropLast(16), tag: cipher.suffix(16))
        let plain = try AES.GCM.open(box, using: peerKey, authenticating: authenticationData(sender: frame.sender, at: frame.at))
        let value = try JSONDecoder().decode(T.self, from: plain)
        seen[frame.nonce] = frame.at
        return value
    }

    private func authenticationData(sender: String, at: Int64) throws -> Data {
        try JSONSerialization.data(withJSONObject: [1, room, sender, at])
    }
}

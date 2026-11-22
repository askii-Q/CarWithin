// Adapted from xmz28/ninebot_pro: NinebotPro/Networking/TailingIdentity.swift
import Foundation
import Security

/// 官方 iOS 样本为 RSA2048；只保存本 App 自己的身份，不复用官方身份或会话密文。
struct TailingIdentity {
    let key: SecKey
    let phoneID: String

    static func load() throws -> TailingIdentity {
        let service = (Bundle.main.bundleIdentifier ?? "com.hanlinzhou.SameDeviceCarPlayPoC") + ".tailing.identity.v1"
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: "identity"]
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var stored: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &stored)
        if status == errSecSuccess {
            guard let data = stored as? Data,
                  let object = try JSONSerialization.jsonObject(with: data) as? [String: String],
                  let id = object["phoneID"], UUID(uuidString: id) != nil,
                  let encoded = object["key"], let bytes = Data(base64Encoded: encoded) else {
                throw TailingError.protocolFailure("本机身份存储损坏")
            }
            var error: Unmanaged<CFError>?
            guard let key = SecKeyCreateWithData(bytes as CFData,
                [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPrivate] as CFDictionary, &error) else {
                throw error!.takeRetainedValue()
            }
            // 1.0.6 及更早版本存的是 RSA2048，官方是 RSA1024：尺寸不符就丢掉重来。
            if SecKeyGetBlockSize(key) == 128 {
                return TailingIdentity(key: key, phoneID: id)
            }
            SecItemDelete(query as CFDictionary)
        } else if status != errSecItemNotFound {
            throw TailingError.system("读取本机身份", status)
        }
        let identity = try generate()
        var error: Unmanaged<CFError>?
        guard let bytes = SecKeyCopyExternalRepresentation(identity.key, &error) else { throw error!.takeRetainedValue() }
        var item = query
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        item[kSecValueData as String] = try TailingProtocol.json([
            "phoneID": identity.phoneID, "key": (bytes as Data).base64EncodedString()
        ])
        let saved = SecItemAdd(item as CFDictionary, nil)
        // 两个同时启动的会话不能各用一个新身份。
        if saved == errSecDuplicateItem { return try load() }
        guard saved == errSecSuccess else { throw TailingError.system("保存本机身份", saved) }
        return identity
    }

    static func generate() throws -> TailingIdentity {
        var error: Unmanaged<CFError>?
        // 官方 RSAUtil 生成的就是 1024 位（`keyPairGenerator.initialize(1024)`），
        // 公钥与签名都以 base64 塞进 CLIENT_INFO 回包；位数放大到 2048 会让这一帧
        // 从约 400 字符涨到约 800 字符，某些仪表固件按固定长度收包时会直接断链。
        guard let key = SecKeyCreateRandomKey([
            kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 1024
        ] as CFDictionary, &error) else { throw error!.takeRetainedValue() }
        return TailingIdentity(key: key, phoneID: UUID().uuidString)
    }

    func publicKey() throws -> Data {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let raw = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw TailingError.protocolFailure("无法读取本机公钥")
        }
        // Security 导出 PKCS#1；线上 pubkey 为 X.509 SubjectPublicKeyInfo。
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        let bitString = Self.der(0x03, Data([0]) + (raw as Data))
        return Self.der(0x30, algorithm + bitString)
    }

    /// 生成 `encryptedHUID`。
    ///
    /// 官方 `RSAUtil.encryptHUID()` 是 `Cipher(DECRYPT_MODE, 私钥)`，也就是对 HUID 原文做
    /// `m = padding(HUID)`、`c = m^d mod n`。仪表侧验证时用我们的公钥做 `c^e mod n` 还原原文。
    /// 这条路我们完全可以用公钥正向算：`SecKeyCreateEncryptedData(pub, .rsaEncryptionPKCS1, HUID)`
    /// 的结果与仪表侧 `c^e mod n` 完全等价，而且不依赖 `SecKeyCreateSignature` 的填充语义
    /// （1.0.9 实车回包用 `.rsaSignatureDigestPKCS1v15Raw` 生成，离线用公钥还原出来是乱码，
    /// 说明那套签名路径与导出的公钥并不自洽）。
    func sign(_ huid: String) throws -> Data {
        let message = Data(huid.utf8)
        guard !message.isEmpty, message.count <= SecKeyGetBlockSize(key) - 11 else {
            throw TailingError.protocolFailure("仪表身份长度异常")
        }
        guard let publicKey = SecKeyCopyPublicKey(key) else {
            throw TailingError.protocolFailure("本机公钥缺失")
        }
        var error: Unmanaged<CFError>?
        guard let cipher = SecKeyCreateEncryptedData(publicKey, .rsaEncryptionPKCS1, message as CFData, &error) else {
            throw error!.takeRetainedValue()
        }
        return cipher as Data
    }

    /// 用私钥把密文还原，验证它与 HUID 原文一致。仪表回显的正是这段密文本身。
    func verify(_ signature: Data, huid: String) throws {
        var error: Unmanaged<CFError>?
        guard let plain = SecKeyCreateDecryptedData(key, .rsaEncryptionPKCS1, signature as CFData, &error),
              plain as Data == Data(huid.utf8) else {
            throw TailingError.protocolFailure("媒体通道身份回显校验失败")
        }
    }

    private static func der(_ tag: UInt8, _ payload: Data) -> Data {
        var header = Data([tag])
        if payload.count < 128 { header.append(UInt8(payload.count)) }
        else if payload.count < 256 { header.append(contentsOf: [0x81, UInt8(payload.count)]) }
        else { header.append(contentsOf: [0x82, UInt8(payload.count >> 8), UInt8(payload.count & 255)]) }
        return header + payload
    }
}

import Foundation
import CryptoKit
import CommonCrypto
import Security

struct Channel: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var uri: String
    var profileToken: String = ""
    var serviceIndex: Int?
}
struct Camera: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = "Novo equipamento"
    var host = ""
    var httpPort = 80
    var tls = false
    var rtspPort = 554
    var username = "admin"
    var channels: [Channel] = []
    var mediaEndpoint = ""
    var ptzEndpoint = ""
    var recordingEndpoint = ""
    var replayEndpoint = ""
    var searchEndpoint = ""
    // Optional for backward-compatible decoding of existing version-1 backups.
    var service: ServiceSettings?
    var serviceProvider: String?
    var deviceEndpoint: String { "\(tls ? "https" : "http")://\(host.contains(":") ? "[\(host)]" : host):\(httpPort)/onvif/device_service" }
    func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 160,
              !host.isEmpty, host.count <= 253, !host.contains(where: { $0.isWhitespace }),
              username.count <= 256, !host.contains("/"), !host.contains("@"), !host.contains("?"),
              (1...65535).contains(httpPort), (1...65535).contains(rtspPort),
              channels.count <= 256, Set(channels.map(\.id)).count == channels.count else {
            throw AppError.message("Confira o nome, endereço, portas e canais do equipamento.")
        }
        if let service {
            guard (1...65535).contains(service.port), service.channelNames.count <= 255,
                  service.channelNames.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.count <= 160 && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }) else {
                throw AppError.message("Porta de serviço ou lista de canais inválida.")
            }
        }
        if let serviceProvider, !["standard","intelbras"].contains(serviceProvider){throw AppError.message("Tipo de serviço inválido.")}
        for channel in channels {
            if let index=channel.serviceIndex {
                guard service != nil,(0..<255).contains(index),channel.uri.isEmpty,channel.profileToken.isEmpty,
                      !channel.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,channel.name.count<=160,
                      !channel.name.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else{
                    throw AppError.message("Canal de serviço inválido ou sem porta cadastrada.")
                }
                continue
            }
            guard !channel.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty, channel.name.count <= 160, channel.uri.count <= 4096,
                  let u = URLComponents(string: channel.uri), ["rtsp", "rtsps"].contains(u.scheme?.lowercased() ?? ""),
                  u.host?.lowercased() == host.lowercased(), u.user == nil, u.password == nil,
                  !(u.queryItems ?? []).contains(where: { ["password","passwd","pass","token","access_token","auth"].contains($0.name.lowercased()) }) else {
                throw AppError.message("O endereço RTSP deve pertencer ao equipamento e não conter senhas ou tokens. Use os campos de acesso.")
            }
        }
    }
    mutating func applyServiceInventory(_ names:[String])throws{
        guard service != nil else{throw AppError.message("Cadastre a porta de serviço antes dos canais.")}
        var updated=self
        updated.service?.channelNames=names
        updated.channels.removeAll{$0.serviceIndex != nil}
        updated.channels += names.enumerated().map{index,name in
            var value=Channel(name:name,uri:"",serviceIndex:index)
            if let old=channels.first(where:{$0.serviceIndex==index}){value.id=old.id}
            return value
        }
        try updated.validate();self=updated
    }
    mutating func applyManualServiceChannels(count:Int)throws{
        guard (1...255).contains(count) else{throw AppError.message("Informe de 1 a 255 canais, conforme o seu gravador.")}
        let names=(0..<count).map{index in channels.first(where:{$0.serviceIndex==index})?.name ?? "Canal \(index+1)"}
        try applyServiceInventory(names)
    }
    func authenticatedURI(_ uri: String, password: String) throws -> String {
        guard var u = URLComponents(string: uri), ["rtsp","rtsps"].contains(u.scheme ?? ""),
              u.host?.lowercased() == host.lowercased() else { throw AppError.message("Endereço de vídeo inválido para este equipamento.") }
        u.user = username.isEmpty ? nil : username
        u.password = username.isEmpty ? nil : password
        guard let value = u.url?.absoluteString else { throw AppError.message("Endereço RTSP inválido.") }
        return value
    }
}
struct LayoutSlot: Codable, Equatable { var cameraID: UUID; var channelID: UUID }
struct FavoriteLayout:Codable,Identifiable,Equatable {var id=UUID();var name:String;var rows:Int;var columns:Int;var slots:[Int:LayoutSlot]}
struct Configuration: Codable {
    var format = "vigia-arm"
    var version = 1
    var exportedAt = Date()
    var cameras: [Camera] = []
    var layout = 4
    var slots: [Int: LayoutSlot] = [:]
    var quality = "Equilibrado"
    var layoutColumns:Int?
    var favorites:[FavoriteLayout]?
    var columns:Int {layoutColumns ?? Int(Double(layout).squareRoot())}
    var rows:Int {columns > 0 ? (layout+columns-1)/columns : 0}
    func validate() throws {
        guard format == "vigia-arm", version == 1 else { throw AppError.message("Formato ou versão de configuração não suportado. Use um arquivo exportado pelo Vigia ARM.") }
        guard cameras.count <= 1000, Set(cameras.map(\.id)).count == cameras.count,
              (1...64).contains(layout), (1...8).contains(columns), rows <= 8, ["Econômico","Equilibrado","Detalhado"].contains(quality),
              slots.keys.allSatisfy({(0..<64).contains($0)}), (favorites?.count ?? 0)<=100 else { throw AppError.message("A configuração contém limites ou identificadores inválidos.") }
        for camera in cameras { try camera.validate() }
        for slot in slots.values {
            guard cameras.contains(where: {$0.id == slot.cameraID && $0.channels.contains(where: {$0.id == slot.channelID})}) else { throw AppError.message("O mosaico contém um canal inexistente.") }
        }
        for favorite in favorites ?? [] {
            guard !favorite.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,favorite.name.count<=160,(1...8).contains(favorite.rows),(1...8).contains(favorite.columns),favorite.slots.keys.allSatisfy({(0..<(favorite.rows*favorite.columns)).contains($0)}),favorite.slots.values.allSatisfy({slot in cameras.contains(where:{$0.id==slot.cameraID && $0.channels.contains(where:{$0.id==slot.channelID})})}) else{throw AppError.message("Favorito inválido ou com canal inexistente.")}
        }
    }
}
enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
struct BackupPayload: Codable { var configuration: Configuration; var passwords: [String:String] }
struct BackupEnvelope: Codable { var format = "vigia-arm-encrypted"; var version = 1; var iterations = 300_000; var salt: Data; var ciphertext: Data }

enum BackupCodec {
    static func key(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard (100_000...1_000_000).contains(iterations), salt.count == 16 else { throw AppError.message("Parâmetros de backup inválidos.") }
        var derived = Data(count: 32)
        let pass = Array(password.utf8)
        let result = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { s in
                pass.withUnsafeBytes { p in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), p.baseAddress?.assumingMemoryBound(to: Int8.self), pass.count,
                        s.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations), out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard result == kCCSuccess else { throw AppError.message("Não foi possível derivar a chave do backup.") }
        return SymmetricKey(data: derived)
    }
    static func encrypt(_ payload: BackupPayload, password: String) throws -> Data {
        guard password.count >= 12 else { throw AppError.message("Use uma senha de backup com pelo menos 12 caracteres.") }
        var salt = Data(count: 16)
        let result = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault,16,$0.baseAddress!) }
        guard result == errSecSuccess else { throw AppError.message("Não foi possível gerar a chave de backup.") }
        let key = try key(password: password, salt: salt, iterations: 300_000)
        let aad = Data("vigia-arm-encrypted:1:300000".utf8)
        let box = try AES.GCM.seal(JSONEncoder().encode(payload), using: key, authenticating: aad)
        return try JSONEncoder().encode(BackupEnvelope(salt: salt, ciphertext: box.combined!))
    }
    static func decode(_ data: Data, password: String?) throws -> BackupPayload {
        guard data.count <= 10_000_000 else { throw AppError.message("O arquivo excede o limite de 10 MB.") }
        if let envelope = try? JSONDecoder().decode(BackupEnvelope.self,from:data) {
            guard envelope.format == "vigia-arm-encrypted", envelope.version == 1, let password else { throw AppError.message("Informe a senha do backup criptografado.") }
            let key = try key(password:password,salt:envelope.salt,iterations:envelope.iterations)
            let plain: Data
            do { plain = try AES.GCM.open(AES.GCM.SealedBox(combined:envelope.ciphertext),using:key,authenticating:Data("vigia-arm-encrypted:1:\(envelope.iterations)".utf8)) }
            catch { throw AppError.message("Senha incorreta ou backup alterado/corrompido.") }
            let payload = try JSONDecoder().decode(BackupPayload.self,from:plain)
            try payload.configuration.validate()
            guard payload.passwords.values.allSatisfy({$0.utf8.count <= 4096}), payload.passwords.keys.allSatisfy({id in payload.configuration.cameras.contains(where:{$0.id.uuidString == id})}) else { throw AppError.message("O backup contém credenciais sem equipamento correspondente.") }
            return payload
        }
        let config: Configuration
        do { config = try JSONDecoder().decode(Configuration.self,from:data) }
        catch { throw AppError.message("Arquivo inválido. O formato do SIM Play não é o formato do Vigia ARM.") }
        try config.validate()
        return BackupPayload(configuration:config,passwords:[:])
    }
}

// Local UI lock verifier. The equipment configuration remains separate.
enum AppLockCodec {
    static let id=UUID(uuidString:"6C65319B-AB93-4C40-ADAF-1EE29F9C3E80")!
    private struct Verifier:Codable{var version:Int;var salt:Data;var digest:Data}
    static func make(_ password:String)throws->String{
        guard password.count>=8,password.utf8.count<=4096 else{throw AppError.message("Use uma senha de 8 a 4096 bytes.")}
        var salt=Data(count:16)
        guard salt.withUnsafeMutableBytes({SecRandomCopyBytes(kSecRandomDefault,16,$0.baseAddress!)}) == errSecSuccess else{throw AppError.message("Não foi possível criar a senha.")}
        let key=try BackupCodec.key(password:password,salt:salt,iterations:300_000)
        let digest=Data(HMAC<SHA256>.authenticationCode(for:Data("vigia-local-lock-v1".utf8),using:key))
        return try JSONEncoder().encode(Verifier(version:1,salt:salt,digest:digest)).base64EncodedString()
    }
    static func verify(_ password:String,stored:String)throws->Bool{
        guard password.utf8.count<=4096,let data=Data(base64Encoded:stored),data.count<=1024,
              let verifier=try? JSONDecoder().decode(Verifier.self,from:data),verifier.version==1,verifier.salt.count==16,verifier.digest.count==32 else{throw AppError.message("Não foi possível ler a proteção local no Chaves do macOS.")}
        let key=try BackupCodec.key(password:password,salt:verifier.salt,iterations:300_000)
        return HMAC<SHA256>.isValidAuthenticationCode(verifier.digest,authenticating:Data("vigia-local-lock-v1".utf8),using:key)
    }
}

protocol SecretStorage {
    func read(_ id:UUID)throws->String
    func write(_ password:String,id:UUID)throws
    func remove(_ id:UUID)
}
final class CredentialStore:SecretStorage {
    private let service = "io.github.rafaelbazzolini.vigia-arm"
    func read(_ id: UUID) throws -> String {
        let q: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString,kSecReturnData as String:true,kSecMatchLimit as String:kSecMatchLimitOne]
        var value: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary,&value)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess, let data = value as? Data, let text = String(data:data,encoding:.utf8) else { throw AppError.message("Não foi possível ler a senha no Chaves do macOS (\(status)).") }
        return text
    }
    func write(_ password: String, id: UUID) throws {
        let query: [String:Any] = [kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString]
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary,[kSecValueData as String:data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query; add[kSecValueData as String] = data;add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let created = SecItemAdd(add as CFDictionary,nil)
            guard created == errSecSuccess else { throw AppError.message("Não foi possível guardar a senha no Chaves (\(created)).") };return
        }
        guard status == errSecSuccess else { throw AppError.message("Não foi possível atualizar a senha no Chaves (\(status)).") }
    }
    func remove(_ id: UUID) { SecItemDelete([kSecClass as String:kSecClassGenericPassword,kSecAttrService as String:service,kSecAttrAccount as String:id.uuidString] as CFDictionary) }
}

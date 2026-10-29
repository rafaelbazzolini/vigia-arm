import Foundation
import CryptoKit
import Network

// Independent, read-only legacy DVRIP control client. No vendor SDK.
// Wire-format references and license attribution: docs/SERVICE_PORT.md.
// Media transport is deliberately separate; these responses are not RTSP URLs.
struct ServiceSettings: Codable, Equatable {
    var port = 37777
    var channelNames: [String] = []
    var substream: Bool?
}

protocol ServiceTransport: AnyObject {
    func write(_ data: Data) throws
    func readExactly(_ count: Int) throws -> Data
    func close()
    func refreshDeadline()
}
extension ServiceTransport { func refreshDeadline() {} }

private final class ServiceCompletion<T> {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<T, Error>?
    func finish(_ value: Result<T, Error>) {
        lock.lock(); defer { lock.unlock() }
        guard result == nil else { return }
        result = value; semaphore.signal()
    }
    func wait(until deadline: DispatchTime) throws -> T {
        guard semaphore.wait(timeout: deadline) == .success else {
            throw AppError.message("A porta de serviço não respondeu no prazo. Confira a porta e a rede.")
        }
        lock.lock(); defer { lock.unlock() }
        return try result!.get()
    }
}

// Blocking facade used exclusively on a detached task, never on the UI thread.
// A single deadline bounds DNS, connection, all reads/writes and logout together.
final class ServiceTCP: ServiceTransport {
    private let connection: NWConnection
    private var deadline: DispatchTime
    private let timeout: Double
    init(host: String, port: Int, timeout: Double = 15) throws {
        guard let port = UInt16(exactly: port), port > 0 else { throw AppError.message("Porta de serviço inválida.") }
        deadline = .now() + timeout
        self.timeout = timeout
        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let ready = ServiceCompletion<Void>()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.finish(.success(()))
            case .failed, .cancelled:
                ready.finish(.failure(AppError.message("Não foi possível conectar à porta de serviço. Confira o endereço, a porta e a rede.")))
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "vigia.service.tcp"))
        do { try ready.wait(until: deadline) }
        catch { connection.cancel(); throw error }
    }
    func write(_ data: Data) throws {
        let completion = ServiceCompletion<Void>()
        connection.send(content: data, completion: .contentProcessed { error in
            completion.finish(error == nil ? .success(()) : .failure(AppError.message("A conexão com a porta de serviço foi interrompida.")))
        })
        do { try completion.wait(until: deadline) } catch { close(); throw error }
    }
    func readExactly(_ count: Int) throws -> Data {
        guard (0...ServiceWire.limit).contains(count) else { throw ServiceWire.invalid }
        var bytes = Data()
        while bytes.count < count {
            let completion = ServiceCompletion<Data>()
            connection.receive(minimumIncompleteLength: 1, maximumLength: count - bytes.count) { data, _, _, error in
                if error == nil, let data, !data.isEmpty { completion.finish(.success(data)) }
                else { completion.finish(.failure(AppError.message("O equipamento encerrou a conexão de serviço antes da resposta completa."))) }
            }
            do { bytes.append(try completion.wait(until: deadline)) }
            catch { close(); throw error }
        }
        return bytes
    }
    func close() { connection.cancel() }
    func refreshDeadline() { deadline = .now() + timeout }
    deinit { close() }
}

enum ServiceWire {
    static let limit = 1_048_576
    static var invalid: AppError { .message("Resposta de serviço inválida ou protocolo não compatível. Este cliente experimental usa DVRIP legado.") }
    static func word(_ data: Data, _ offset: Int) -> UInt32 {
        // Called only on a validated 32-byte header.
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(data[offset + $1]) << UInt32($1 * 8) }
    }
    static func put(_ value: UInt32, into data: inout Data, at offset: Int) {
        for i in 0..<4 { data[offset+i] = UInt8(truncatingIfNeeded: value >> UInt32(i*8)) }
    }
    static var challengeRequest: Data {
        var header = Data(repeating: 0, count: 32)
        header[0] = 0xa0; header[1] = 1
        header.replaceSubrange(24..<32, with: [5,2,1,1,0,0,0xa1,0xaa])
        return header
    }
    static func challenge(_ bytes: Data) throws -> (realm: String, random: String) {
        guard bytes.count <= 8192, let text = String(data: bytes, encoding: .isoLatin1) else { throw invalid }
        var values: [String: String] = [:]
        for line in text.trimmingCharacters(in: .init(charactersIn: "\0\r\n")).components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { throw invalid }
            let key = String(parts[0])
            guard values[key] == nil else { throw invalid }
            values[key] = String(parts[1])
        }
        guard let realm = values["Realm"], let random = values["Random"], !realm.isEmpty, !random.isEmpty,
              realm.count <= 1024, random.count <= 1024,
              !(realm + random).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw invalid }
        return (realm, random)
    }
    private static func latin(_ text: String) throws -> Data {
        guard let data = text.data(using: .isoLatin1, allowLossyConversion: false) else {
            throw AppError.message("Este protocolo legado exige credenciais compatíveis com Latin-1.")
        }
        return data
    }
    private static func md5(_ text: String) throws -> String {
        Insecure.MD5.hash(data: try latin(text)).map { String(format: "%02X", $0) }.joined()
    }
    static func login(username: String, password: String, realm: String, random: String) throws -> Data {
        guard !username.isEmpty, username.count <= 256, password.utf8.count <= 4096,
              !username.contains(":"), !username.contains("&"),
              !(username + password).unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw AppError.message("Confira as credenciais para a autenticação de serviço legado.")
        }
        let digest = Array(Insecure.MD5.hash(data: try latin(password)))
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz".utf8)
        let compressed = String(decoding: (0..<8).map { alphabet[(Int(digest[$0*2]) + Int(digest[$0*2+1])) % 62] }, as: UTF8.self)
        let base = try md5("\(username):\(realm):\(password)")
        let gen2 = try md5("\(username):\(random):\(base)")
        let gen1 = try md5("\(username):\(random):\(compressed)")
        let payload = try latin(username + "&&" + gen2 + gen1)
        var header = Data(repeating: 0, count: 32)
        header[0] = 0xa0; header[1] = 5
        put(UInt32(payload.count), into: &header, at: 4)
        header.replaceSubrange(24..<32, with: [5,2,0,8,0,0,0xa1,0xaa])
        return header + payload
    }
    static func authenticatedSession(_ header: Data) throws -> UInt32 {
        guard header.count == 32, header[0] == 0xb0, header[1] <= 1 else { throw invalid }
        switch (header[8], header[9]) {
        case (0,8):
            let session = word(header,16)
            guard session != 0 else { throw invalid }; return session
        case (1,0), (1,1): throw AppError.message("Usuário ou senha recusados. Não haverá nova tentativa automática.")
        case (1,4): throw AppError.message("A conta está bloqueada no equipamento. Interrompa as tentativas e confira o gravador.")
        case (1,0x11): throw AppError.message("O equipamento ainda não foi inicializado.")
        case (3,3): throw AppError.message("O equipamento informou que este usuário já está conectado.")
        default: throw AppError.message("O gravador recusou a autenticação de serviço ou usa uma variante ainda não suportada.")
        }
    }
    static func rpc(_ method: String, params: [String: Any], id: UInt32, session: UInt32) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: ["method": method, "params": params, "id": id, "session": session], options: [.sortedKeys])
        guard payload.count <= limit else { throw invalid }
        var header = Data(repeating: 0, count: 32); header[0] = 0xf6
        put(UInt32(payload.count), into: &header, at: 4); put(id, into: &header, at: 8)
        put(UInt32(payload.count), into: &header, at: 16); put(session, into: &header, at: 24)
        return header + payload
    }
}

struct ServiceInventory {
    // nil means login succeeded but channel enumeration was not supported.
    var channelNames: [String]?
    var message: String {
        if let channelNames {
            return "Autenticação aceita • \(channelNames.count) canais identificados. Salve e abra um canal para testar o vídeo legado experimental."
        }
        return "Autenticação aceita; a consulta de canais não foi reconhecida por esta variante do gravador."
    }
}

final class ServiceClient {
    private let transport: ServiceTransport
    private var session: UInt32 = 0
    private var request: UInt32 = 0
    init(transport: ServiceTransport) { self.transport = transport }

    // Exactly one authentication attempt per explicit user action. No fallback,
    // password guessing, auto-reconnect, config writes, cloud, shell or SDK calls.
    func authenticate(username: String, password: String) throws -> UInt32 {
        try transport.write(ServiceWire.challengeRequest)
        let challengeHeader = try transport.readExactly(32)
        guard challengeHeader.count == 32, challengeHeader[0] == 0xb0, challengeHeader[1] <= 1 else { throw ServiceWire.invalid }
        let length = Int(ServiceWire.word(challengeHeader,4))
        guard (1...8192).contains(length) else { throw ServiceWire.invalid }
        let challenge = try ServiceWire.challenge(transport.readExactly(length))
        try transport.write(ServiceWire.login(username: username, password: password, realm: challenge.realm, random: challenge.random))
        let loginHeader = try transport.readExactly(32)
        session = try ServiceWire.authenticatedSession(loginHeader)
        let loginLength = Int(ServiceWire.word(loginHeader,4))
        guard loginLength <= 8192 else { throw ServiceWire.invalid }
        if loginLength > 0 { _ = try transport.readExactly(loginLength) }
        return session
    }
    func inspect(username: String, password: String) throws -> ServiceInventory {
        defer { transport.close() }
        session = try authenticate(username:username,password:password)
        defer { try? transport.write(ServiceWire.rpc("global.logout", params: [:], id: request &+ 1, session: session)) }
        let result: [String: Any]
        do { result = try call("configManager.getConfig", params: ["name": "ChannelTitle"]) }
        catch { throw AppError.message("Autenticação aceita, mas a consulta de canais falhou ou a conexão foi interrompida.") }
        guard result["result"] as? Bool == true,
              let params = result["params"] as? [String: Any], let table = params["table"] as? [[String: Any]],
              !table.isEmpty, table.count <= 255 else { return ServiceInventory(channelNames: nil) }
        let names = try table.enumerated().map { index, row -> String in
            guard let title = row["Name"] as? String, title.count <= 160,
                  !title.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw ServiceWire.invalid }
            return title.trimmingCharacters(in: .whitespaces).isEmpty ? "Canal \(index+1)" : title
        }
        return ServiceInventory(channelNames: names)
    }
    private func call(_ method: String, params: [String: Any]) throws -> [String: Any] {
        request += 1
        try transport.write(ServiceWire.rpc(method, params: params, id: request, session: session))
        // Bound callbacks and fragments; never consume an unbounded event stream.
        for _ in 0..<8 {
            var body = Data(), expected: Int?, responseID: UInt32?
            for _ in 0..<64 {
                let header = try transport.readExactly(32)
                guard header.count == 32, header[0] == 0xf6, header[1...3].allSatisfy({ $0 == 0 }),
                      ServiceWire.word(header,24) == session else { throw ServiceWire.invalid }
                let length = Int(ServiceWire.word(header,4)), total = Int(ServiceWire.word(header,16)), id = ServiceWire.word(header,8)
                guard length > 0, total > 0, total <= ServiceWire.limit, length <= total,
                      expected == nil || expected == total, responseID == nil || responseID == id,
                      body.count + length <= total else { throw ServiceWire.invalid }
                expected = total; responseID = id
                body.append(try transport.readExactly(length))
                if body.count == total { break }
            }
            guard body.count == expected, let json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw ServiceWire.invalid }
            if responseID == request {
                guard let id = json["id"] as? NSNumber, CFGetTypeID(id) != CFBooleanGetTypeID(), id.doubleValue == Double(request),
                      let sid = json["session"] as? NSNumber, CFGetTypeID(sid) != CFBooleanGetTypeID(), sid.doubleValue == Double(session) else { throw ServiceWire.invalid }
                return json
            }
            // Only skip unsolicited notifications, never another RPC reply.
            guard json["method"] as? String != nil, json["result"] == nil else { throw ServiceWire.invalid }
        }
        throw ServiceWire.invalid
    }
}

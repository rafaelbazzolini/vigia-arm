import Foundation
import CryptoKit
import Darwin

final class XMLNode {
    var name: String
    var attributes: [String:String]
    var text = ""
    var children: [XMLNode] = []
    init(_ name: String, _ attributes: [String:String] = [:]) { self.name = name.components(separatedBy:":").last!;self.attributes=attributes }
    func all(_ name: String) -> [XMLNode] { children.flatMap { ($0.name == name ? [$0] : []) + $0.all(name) } }
    func first(_ name: String) -> String { all(name).first?.text.trimmingCharacters(in:.whitespacesAndNewlines) ?? "" }
}
final class XMLTree: NSObject, XMLParserDelegate {
    let root = XMLNode("root")
    var stack: [XMLNode] = []
    static func parse(_ data: Data) throws -> XMLNode {
        guard data.count < 5_000_000 else { throw AppError.message("Resposta ONVIF muito grande.") }
        let preamble=String(decoding:data,as:UTF8.self).uppercased()
        guard !preamble.contains("<!DOCTYPE"),!preamble.contains("<!ENTITY") else{throw AppError.message("A resposta ONVIF contém declarações XML não permitidas.")}
        let tree = XMLTree();tree.stack=[tree.root]
        let parser=XMLParser(data:data);parser.delegate=tree;parser.shouldResolveExternalEntities=false
        guard parser.parse() else { throw AppError.message("Resposta ONVIF inválida.") };return tree.root
    }
    func parser(_ parser: XMLParser,didStartElement elementName: String,namespaceURI:String?,qualifiedName qName:String?,attributes attributeDict:[String:String]) {
        if stack.count > 64 {parser.abortParsing();return}
        let node=XMLNode(elementName,attributeDict);stack.last!.children.append(node);stack.append(node)
    }
    func parser(_ parser: XMLParser,foundCharacters string:String) { stack.last!.text += string }
    func parser(_ parser: XMLParser,didEndElement elementName:String,namespaceURI:String?,qualifiedName qName:String?) { if stack.count>1 {stack.removeLast()} }
}
func xmlEscape(_ text:String)->String { text.replacingOccurrences(of:"&",with:"&amp;").replacingOccurrences(of:"<",with:"&lt;").replacingOccurrences(of:">",with:"&gt;").replacingOccurrences(of:"\"",with:"&quot;").replacingOccurrences(of:"'",with:"&apos;") }
final class ONVIFAuth: NSObject,URLSessionTaskDelegate {
    let username:String;let password:String;let host:String
    init(_ camera:Camera,_ password:String){username=camera.username;self.password=password;host=camera.host}
    func urlSession(_ session:URLSession,task:URLSessionTask,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
        let method=challenge.protectionSpace.authenticationMethod
        if [NSURLAuthenticationMethodHTTPDigest,NSURLAuthenticationMethodHTTPBasic].contains(method),challenge.previousFailureCount==0,challenge.protectionSpace.host.lowercased()==host.lowercased() {
            completionHandler(.useCredential,URLCredential(user:username,password:password,persistence:.none))
        } else {completionHandler(.performDefaultHandling,nil)}
    }
    func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) { completionHandler(nil) }
}
struct RemoteRecording:Identifiable {
    var id:String;var name:String;var earliest:String="";var latest:String=""
}
struct DiscoveredDevice:Identifiable { var id:String;var host:String;var port:Int;var tls:Bool;var label:String }
struct ONVIFClient {
    let camera:Camera;let password:String
    static let deviceNS="http://www.onvif.org/ver10/device/wsdl"
    static let mediaNS="http://www.onvif.org/ver10/media/wsdl"
    func security()->String {
        guard !camera.username.isEmpty else{return ""}
        let nonce=Data((0..<20).map{_ in UInt8.random(in:0...255)})
        let date=ISO8601DateFormatter().string(from:Date())
        let digest=Data(Insecure.SHA1.hash(data:nonce+Data(date.utf8)+Data(password.utf8))).base64EncodedString()
        return """
        <wsse:Security xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd"><wsse:UsernameToken><wsse:Username>\(xmlEscape(camera.username))</wsse:Username><wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(digest)</wsse:Password><wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonce.base64EncodedString())</wsse:Nonce><wsu:Created>\(date)</wsu:Created></wsse:UsernameToken></wsse:Security>
        """
    }
    func call(endpoint:String,namespace:String,operation:String,body:String="") async throws -> XMLNode {
        guard let url=URL(string:endpoint),["http","https"].contains(url.scheme ?? ""),url.host?.lowercased()==camera.host.lowercased(),url.user==nil,url.password==nil else {throw AppError.message("O serviço ONVIF informou um endereço fora deste equipamento.")}
        var req=URLRequest(url:url);req.httpMethod="POST";req.timeoutInterval=15
        req.setValue("application/soap+xml; charset=utf-8; action=\"\(namespace)/\(operation)\"",forHTTPHeaderField:"Content-Type")
        req.setValue("\"\(namespace)/\(operation)\"",forHTTPHeaderField:"SOAPAction")
        req.httpBody=Data("<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:t=\"\(namespace)\" xmlns:tt=\"http://www.onvif.org/ver10/schema\"><s:Header>\(security())</s:Header><s:Body><t:\(operation)>\(body)</t:\(operation)></s:Body></s:Envelope>".utf8)
        let config=URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=20;config.urlCredentialStorage=nil
        let session=URLSession(configuration:config,delegate:ONVIFAuth(camera,password),delegateQueue:nil)
        defer{session.invalidateAndCancel()}
        let (data,response): (Data,URLResponse)
        do {(data,response)=try await session.data(for:req)} catch {throw AppError.message("Não foi possível acessar o ONVIF. Confira endereço, porta, rede e certificado HTTPS.")}
        guard let http=response as? HTTPURLResponse else {throw AppError.message("Resposta HTTP inválida.")}
        guard (200...299).contains(http.statusCode) else {throw AppError.message("ONVIF retornou HTTP \(http.statusCode). Confira credenciais, serviço habilitado e permissões.")}
        let tree=try XMLTree.parse(data)
        guard tree.all("Fault").isEmpty else {throw AppError.message("O equipamento recusou \(operation). Confira suporte ONVIF, permissões e o relógio do equipamento.")}
        return tree
    }
    func services() async throws -> Camera {
        var result=camera
        let tree=try await call(endpoint:camera.deviceEndpoint,namespace:Self.deviceNS,operation:"GetServices",body:"<t:IncludeCapability>false</t:IncludeCapability>")
        for service in tree.all("Service") {
            let namespace=service.first("Namespace"),endpoint=service.first("XAddr")
            guard let url=URL(string:endpoint),url.host?.lowercased()==camera.host.lowercased() else{continue}
            switch namespace {
            case Self.mediaNS:result.mediaEndpoint=endpoint
            case "http://www.onvif.org/ver20/ptz/wsdl":result.ptzEndpoint=endpoint
            case "http://www.onvif.org/ver10/recording/wsdl":result.recordingEndpoint=endpoint
            case "http://www.onvif.org/ver10/replay/wsdl":result.replayEndpoint=endpoint
            case "http://www.onvif.org/ver10/search/wsdl":result.searchEndpoint=endpoint
            default:break
            }
        }
        if result.mediaEndpoint.isEmpty {
            let caps=try await call(endpoint:camera.deviceEndpoint,namespace:Self.deviceNS,operation:"GetCapabilities",body:"<t:Category>All</t:Category>")
            result.mediaEndpoint=caps.all("Media").first?.first("XAddr") ?? ""
            result.ptzEndpoint=caps.all("PTZ").first?.first("XAddr") ?? result.ptzEndpoint
        }
        guard !result.mediaEndpoint.isEmpty else{throw AppError.message("Nenhum serviço ONVIF Media1 encontrado. Você pode cadastrar um endereço RTSP manualmente.")}
        return result
    }
    func profiles() async throws -> [Channel] {
        let profiles=try await call(endpoint:camera.mediaEndpoint,namespace:Self.mediaNS,operation:"GetProfiles")
        var channels:[Channel]=[]
        for profile in profiles.all("Profiles").prefix(256) {
            guard let token=profile.attributes["token"] else{continue}
            let result=try await call(endpoint:camera.mediaEndpoint,namespace:Self.mediaNS,operation:"GetStreamUri",body:"<t:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></t:StreamSetup><t:ProfileToken>\(xmlEscape(token))</t:ProfileToken>")
            guard var u=URLComponents(string:result.first("Uri")),["rtsp","rtsps"].contains(u.scheme ?? "") else{continue}
            if u.host=="0.0.0.0" {u.host=camera.host}
            guard u.host?.lowercased()==camera.host.lowercased() else{continue}
            u.user=nil;u.password=nil
            channels.append(Channel(name:profile.first("Name").isEmpty ? "Perfil \(channels.count+1)" : profile.first("Name"),uri:u.string ?? "",profileToken:token))
        }
        return channels
    }
    func recordings() async throws -> [RemoteRecording] {
        guard !camera.recordingEndpoint.isEmpty,!camera.replayEndpoint.isEmpty else{throw AppError.message("Este equipamento não anunciou os serviços ONVIF de gravação e reprodução (Profile G).")}
        let tree=try await call(endpoint:camera.recordingEndpoint,namespace:"http://www.onvif.org/ver10/recording/wsdl",operation:"GetRecordings")
        var items:[RemoteRecording]=[]
        for item in tree.all("RecordingItem").prefix(256) {
            let token=item.first("RecordingToken");if token.isEmpty{continue}
            let name=item.first("Name")
            items.append(RemoteRecording(id:token,name:name.isEmpty ? "Gravação \(items.count+1)" : name))
        }
        return items
    }
    func replayURI(token:String) async throws -> String {
        let tree=try await call(endpoint:camera.replayEndpoint,namespace:"http://www.onvif.org/ver10/replay/wsdl",operation:"GetReplayUri",body:"<t:StreamSetup><tt:Stream>RTP-Unicast</tt:Stream><tt:Transport><tt:Protocol>RTSP</tt:Protocol></tt:Transport></t:StreamSetup><t:RecordingToken>\(xmlEscape(token))</t:RecordingToken>")
        guard var u=URLComponents(string:tree.first("Uri")) else{throw AppError.message("O equipamento não forneceu uma URI de reprodução.")}
        u.user=nil;u.password=nil
        _=try camera.authenticatedURI(u.string ?? "",password:password)
        return u.string!
    }
    func ptz(token:String,x:Double,y:Double,z:Double) async throws {
        guard !camera.ptzEndpoint.isEmpty,!token.isEmpty else{throw AppError.message("PTZ ONVIF não disponível neste perfil.")}
        let ns="http://www.onvif.org/ver20/ptz/wsdl",target="<t:ProfileToken>\(xmlEscape(token))</t:ProfileToken>"
        _=try await call(endpoint:camera.ptzEndpoint,namespace:ns,operation:"ContinuousMove",body:target+"<t:Velocity><tt:PanTilt x=\"\(x)\" y=\"\(y)\"/><tt:Zoom x=\"\(z)\"/></t:Velocity><t:Timeout>PT0.3S</t:Timeout>")
        try? await Task.sleep(nanoseconds:250_000_000)
        _=try await call(endpoint:camera.ptzEndpoint,namespace:ns,operation:"Stop",body:target+"<t:PanTilt>true</t:PanTilt><t:Zoom>true</t:Zoom>")
    }
    static func discover() async -> [DiscoveredDevice] {
        await Task.detached {
            let fd=socket(AF_INET,SOCK_DGRAM,IPPROTO_UDP);guard fd>=0 else{return []};defer{close(fd)}
            var timeout=timeval(tv_sec:1,tv_usec:0);setsockopt(fd,SOL_SOCKET,SO_RCVTIMEO,&timeout,socklen_t(MemoryLayout.size(ofValue:timeout)))
            var ttl:UInt8=1;setsockopt(fd,IPPROTO_IP,IP_MULTICAST_TTL,&ttl,socklen_t(MemoryLayout.size(ofValue:ttl)))
            var address=sockaddr_in();address.sin_len=UInt8(MemoryLayout<sockaddr_in>.size);address.sin_family=sa_family_t(AF_INET);address.sin_port=UInt16(3702).bigEndian
            inet_pton(AF_INET,"239.255.255.250",&address.sin_addr)
            let probe="<s:Envelope xmlns:s=\"http://www.w3.org/2003/05/soap-envelope\" xmlns:a=\"http://schemas.xmlsoap.org/ws/2004/08/addressing\"><s:Header><a:MessageID>urn:uuid:\(UUID())</a:MessageID><a:To>urn:schemas-xmlsoap-org:ws:2005:04:discovery</a:To><a:Action>http://schemas.xmlsoap.org/ws/2005/04/discovery/Probe</a:Action></s:Header><s:Body><d:Probe xmlns:d=\"http://schemas.xmlsoap.org/ws/2005/04/discovery\"><d:Types xmlns:dn=\"http://www.onvif.org/ver10/network/wsdl\">dn:NetworkVideoTransmitter</d:Types></d:Probe></s:Body></s:Envelope>"
            let bytes=Array(probe.utf8)
            _=withUnsafePointer(to:&address){p in p.withMemoryRebound(to:sockaddr.self,capacity:1){sendto(fd,bytes,bytes.count,0,$0,socklen_t(MemoryLayout<sockaddr_in>.size))}}
            let end=Date().addingTimeInterval(4);var found:[String:DiscoveredDevice]=[:];var buffer=[UInt8](repeating:0,count:65535)
            while Date()<end {
                let n=recv(fd,&buffer,buffer.count,0);if n<=0{continue}
                guard let root=try? XMLTree.parse(Data(buffer.prefix(n))) else{continue}
                for match in root.all("ProbeMatch") {
                    for value in match.first("XAddrs").split(separator:" ") {
                        guard let u=URL(string:String(value)),let host=u.host,["http","https"].contains(u.scheme ?? "") else{continue}
                        found[host]=DiscoveredDevice(id:host,host:host,port:u.port ?? (u.scheme=="https" ? 443:80),tls:u.scheme=="https",label:"Equipamento ONVIF")
                    }
                }
            }
            return found.values.sorted{$0.host<$1.host}
        }.value
    }
}

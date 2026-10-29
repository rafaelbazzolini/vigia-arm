import Foundation

extension CoreTests {
    static func serviceChecks() throws {
        let login = try ServiceWire.login(username:"operator",password:"fixture-password",realm:"Login to TEST-DEVICE",random:"123456789")
        try require(String(data:login.dropFirst(32),encoding:.isoLatin1) == "operator&&6CC226D74F9BE8B259C0FABC032C9C3A307A42A6CC4EEA0E05E27D01D7EE0C69", "DVRIP login matches fixed independent digest vector")
        let challenge = try ServiceWire.challenge(Data("Realm:Login to TEST-DEVICE\r\nRandom:123456789\r\n".utf8))
        try require(challenge.realm == "Login to TEST-DEVICE" && challenge.random == "123456789", "DVRIP realm and random parsed without truncation")
        try expectFailure("Duplicate challenge fields rejected") { _ = try ServiceWire.challenge(Data("Realm:a\r\nRandom:b\r\nRandom:c\r\n".utf8)) }
        try expectFailure("Ambiguous legacy username rejected") { _ = try ServiceWire.login(username:"a&&b",password:"x",realm:"a",random:"b") }
        try expectFailure("Unsupported credential encoding rejected") { _ = try ServiceWire.login(username:"operator",password:"🔒",realm:"a",random:"b") }

        var camera = Camera(name:"Service fixture",host:"127.0.0.1")
        let old = try JSONEncoder().encode(camera)
        try require(try JSONDecoder().decode(Camera.self,from:old).service == nil,"Old backups without service settings remain compatible")
        camera.service = ServiceSettings(port:12000,channelNames:["Entrada","Garagem"])
        let rtsp=Channel(name:"RTSP fixture",uri:"rtsp://127.0.0.1/live")
        camera.channels=[rtsp]
        try camera.applyServiceInventory(["Entrada","Garagem"])
        let serviceID=camera.channels[1].id
        try camera.applyServiceInventory(["Entrada atualizada","Garagem"])
        try require(camera.channels[0]==rtsp && camera.channels[1].id==serviceID && camera.channels[1].serviceIndex==0,"Refreshing service channels preserves mosaic IDs and RTSP registrations")
        let payload = BackupPayload(configuration:Configuration(cameras:[camera]),passwords:[camera.id.uuidString:"fixture-only"])
        let backup = try BackupCodec.encrypt(payload,password:"service-backup-test")
        let decoded = try BackupCodec.decode(backup,password:"service-backup-test")
        try require(decoded.configuration.cameras[0] == camera,"Service port, playable channel IDs and inventory survive encrypted backup")
        camera.service?.port = 0
        try expectFailure("Invalid service port rejected before connection") { try camera.validate() }

        let response = try JSONSerialization.data(withJSONObject:["id":1,"session":42,"result":true,"params":["table":[["Name":"Entrada"],["Name":""]]]])
        let notify = try JSONSerialization.data(withJSONObject:["method":"client.notifyEventStream","session":42,"params":[:]])
        let fragmented = rpcFrame(Data(response.prefix(17)),total:response.count) + rpcFrame(Data(response.dropFirst(17)),total:response.count)
        let good = ScriptedService(bootstrap() + rpcFrame(notify,id:0) + fragmented)
        let inventory = try ServiceClient(transport:good).inspect(username:"operator",password:"fixture-password")
        try require(inventory.channelNames == ["Entrada","Canal 2"] && good.closed,"Fragmented RPC and unsolicited callback yield ordered channel inventory")
        let methods = try good.writes.dropFirst(2).map { packet in
            (try JSONSerialization.jsonObject(with:packet.dropFirst(32)) as? [String:Any])?["method"] as? String
        }
        try require(methods == ["configManager.getConfig","global.logout"],"Only channel read and logout sent after authentication")

        for (status,name) in [(UInt8(0),"Wrong password"),(UInt8(4),"Locked account")] {
            var bytes = bootstrap()
            // Login follows the challenge header and its variable-length body.
            let offset = 32 + Int(ServiceWire.word(bytes,4))
            bytes[offset+8] = 1; bytes[offset+9] = status
            let rejected = ScriptedService(bytes)
            try expectFailure(name + " stops service authentication") { _ = try ServiceClient(transport:rejected).inspect(username:"operator",password:"bad-fixture") }
            try require(rejected.closed && rejected.writes.count == 2,name + " never triggers credential retry or RPC")
        }
        let unsupported = try JSONSerialization.data(withJSONObject:["id":1,"session":42,"result":false,"error":["code":268632079]])
        let partial = try ServiceClient(transport:ScriptedService(bootstrap()+rpcFrame(unsupported))).inspect(username:"operator",password:"fixture-password")
        try require(partial.channelNames == nil && partial.message.contains("Autenticação aceita"),"Unsupported channel query is reported separately from successful login")
        var legacyLogin=bootstrap()
        let loginOffset=32+Int(ServiceWire.word(legacyLogin,4))
        legacyLogin[loginOffset+10]=4
        let failedQuery=ScriptedService(legacyLogin)
        let counted=try ServiceClient(transport:failedQuery).inspect(username:"operator",password:"fixture-password")
        try require(counted.channelNames==["Canal 1","Canal 2","Canal 3","Canal 4"] && counted.usedLoginChannelCount,"Login channel count recovers inventory when RPC connection closes")
        try require(failedQuery.closed && failedQuery.writes.filter{$0.prefix(2)==Data([0xa0,5])}.count==1,"Inventory fallback closes socket and never repeats authentication")
        let countedUnsupported=try ServiceClient(transport:ScriptedService(legacyLogin+rpcFrame(unsupported))).inspect(username:"operator",password:"fixture-password")
        try require(countedUnsupported.channelNames?.count==4 && countedUnsupported.message.contains("genéricos"),"Unsupported RPC uses reported count with clearly generic names")
        var refusedLogin=legacyLogin;refusedLogin[loginOffset+8]=1;refusedLogin[loginOffset+9]=0
        try expectFailure("Reported channel count never overrides rejected authentication"){_=try ServiceClient(transport:ScriptedService(refusedLogin)).inspect(username:"operator",password:"bad-fixture")}
        var manual=Camera(name:"Manual service fixture",host:"127.0.0.1")
        manual.service=ServiceSettings(port:12000)
        try manual.applyManualServiceChannels(count:4)
        let first=manual.channels[0].id
        manual.channels[0].name="Entrada personalizada"
        try manual.applyManualServiceChannels(count:8)
        try require(manual.channels.count==8 && manual.channels[0].id==first && manual.channels[0].name=="Entrada personalizada" && manual.channels[7].serviceIndex==7,"Manual service channel count preserves existing names and mosaic IDs")
        let previousManual=manual
        try expectFailure("Invalid manual count rejected"){try manual.applyManualServiceChannels(count:256)}
        try require(manual==previousManual,"Invalid manual inventory leaves configuration intact")
        var oversized = rpcFrame(Data([0]),total:ServiceWire.limit+1)
        oversized.removeLast()
        try expectFailure("Oversized RPC refused without allocating response body") { _ = try ServiceClient(transport:ScriptedService(bootstrap()+oversized)).inspect(username:"operator",password:"fixture-password") }
        var foreign = rpcFrame(response); ServiceWire.put(43,into:&foreign,at:24)
        try expectFailure("Foreign-session RPC rejected") { _ = try ServiceClient(transport:ScriptedService(bootstrap()+foreign)).inspect(username:"operator",password:"fixture-password") }
        let wrongID = try JSONSerialization.data(withJSONObject:["id":4294967297 as UInt64,"session":42,"result":true])
        try expectFailure("Overflowed JSON response ID rejected") { _ = try ServiceClient(transport:ScriptedService(bootstrap()+rpcFrame(wrongID))).inspect(username:"operator",password:"fixture-password") }
        let malicious = try JSONSerialization.data(withJSONObject:["id":1,"session":42,"result":true,"params":["table":[["Name":"a\nb"]]]])
        try expectFailure("Control characters in channel titles rejected") { _ = try ServiceClient(transport:ScriptedService(bootstrap()+rpcFrame(malicious))).inspect(username:"operator",password:"fixture-password") }
        let truncated = ScriptedService(Data(bootstrap().prefix(12)))
        try expectFailure("Truncated service response closes connection") { _ = try ServiceClient(transport:truncated).inspect(username:"operator",password:"fixture-password") }
        try require(truncated.closed,"Service connection closes on malformed handshake")
        let binding=try ServiceVideoWire.bind(session:42,channel:0)
        try require(binding[0]==0xf1 && ServiceWire.word(binding,8)==42 && binding[12]==1 && binding[13]==1,"Video socket binding contains authenticated session and one-based channel")
        let start=try ServiceVideoWire.start(channel:0,substream:true)
        try require(start[0]==0x11 && ServiceWire.word(start,4)==16 && start[8]==1 && start[32]==1,"Legacy stream request uses channel mask and substream payload")
        let extended=try ServiceVideoWire.start(channel:17,substream:false)
        try require(extended[26]==8 && String(decoding:extended.dropFirst(32),as:UTF8.self).contains("ChannelName:17\r\nStream:0\r\nOperate:1"),"Extended video channel uses explicit TCP request")
        try expectFailure("Out-of-range media channel rejected before socket binding"){_=try ServiceVideoWire.bind(session:42,channel:255)}
        var ack=Data(repeating:0,count:32);ack[0]=0xf1
        var media=Data(repeating:0,count:32);media[0]=0xbc
        let sample=Data("DHAV-fixture".utf8);ServiceWire.put(UInt32(sample.count),into:&media,at:4)
        let frame=try ServiceVideoWire.frame(ScriptedService(ack+media+sample))
        try require(frame==sample,"Media binding acknowledgement skipped and binary stream payload preserved")
        ServiceWire.put(UInt32(ServiceVideoWire.limit+1),into:&media,at:4)
        try expectFailure("Oversized video packet rejected without reading body"){_=try ServiceVideoWire.frame(ScriptedService(media))}
        var alive=Data(repeating:0,count:32);alive[0]=0xb1
        let control=ScriptedService(alive)
        try ServiceVideoWire.keepAlive(control)
        try require(control.writes.count==1 && control.writes[0][0]==0xa1,"Legacy keep-alive requests status and consumes acknowledgement")
        let source=MediaInput(uri:"",service:ServiceMediaSource(host:"127.0.0.1",port:12000,username:"operator",password:"fixture-password",channel:0,substream:true))
        try require(source.arguments().contains("dhav") && source.arguments().contains("pipe:0") && !source.arguments().joined().contains("fixture-password"),"FFmpeg receives DHAV through stdin without service credentials in process arguments")
    }
    @MainActor static func serviceMediaIntegration(port:Int,directory:URL)async throws{
        var camera=Camera(name:"Synthetic service video",host:"127.0.0.1",username:"operator")
        camera.service=ServiceSettings(port:port)
        try camera.applyServiceInventory(["Entrada TCP"])
        let source=MediaInput(uri:"",service:ServiceMediaSource(host:"127.0.0.1",port:port,username:"operator",password:"fixture-password",channel:0,substream:true))
        let video=VideoSession(camera:camera,channel:camera.channels[0],source:source)
        defer{video.stop()}
        try video.start(quality:"Econômico")
        for _ in 0..<120{if video.active{break};try await Task.sleep(nanoseconds:100_000_000)}
        try require(video.active && video.image != nil,"Service TCP → DHAV → FFmpeg → native preview yields a decoded image")
        let png=directory.appendingPathComponent("service-snapshot.png")
        try video.snapshot(to:png)
        let signature=try Data(contentsOf:png).prefix(8)
        try require(signature==Data([137,80,78,71,13,10,26,10]),"Service preview snapshot is a real PNG")
        let job=RecordingJob(destination:directory.appendingPathComponent("service-recording.mkv"))
        try job.start(input:source,duration:2)
        video.stopVideo()
        for _ in 0..<120{if !job.running{break};try await Task.sleep(nanoseconds:100_000_000)}
        if job.running{job.stop()}
        try require(!job.running && job.state=="Arquivo salvo","Service recording finalizes independently after preview stops")
        let manual=RecordingJob(destination:directory.appendingPathComponent("service-manual-stop.mkv"))
        try manual.start(input:source)
        try await Task.sleep(nanoseconds:2_000_000_000)
        manual.stop()
        for _ in 0..<70{if !manual.running{break};try await Task.sleep(nanoseconds:100_000_000)}
        try require(!manual.running && manual.state=="Arquivo salvo","Stopping live service recording signals EOF and finalizes MKV normally")
    }
    static func serviceIntegration(port:Int) async throws {
        let names = try await Task.detached {
            try ServiceClient(transport:ServiceTCP(host:"127.0.0.1",port:port,timeout:5)).inspect(username:"operator",password:"fixture-password").channelNames
        }.value
        try require(names == ["Entrada TCP","Garagem TCP"],"Real localhost TCP exchanges split headers, authenticates and enumerates channels")
        do {
            _ = try await Task.detached {
                try ServiceClient(transport:ServiceTCP(host:"127.0.0.1",port:port,timeout:5)).inspect(username:"operator",password:"incorrect-fixture-password")
            }.value
            throw AppError.message("FAIL: TCP fixture should refuse password")
        } catch {
            try require(error.localizedDescription.contains("recusados"),"Localhost server rejects bad credential without fallback")
        }
        let start = Date()
        do {
            _ = try await Task.detached {
                try ServiceClient(transport:ServiceTCP(host:"127.0.0.1",port:port,timeout:0.3)).inspect(username:"timeout-fixture",password:"fixture-password")
            }.value
            throw AppError.message("FAIL: timeout fixture should expire")
        } catch {
            try require(error.localizedDescription.contains("prazo") && Date().timeIntervalSince(start)<2,"One deadline bounds silent-server reads and closes TCP")
        }
    }
    private static func rpcFrame(_ body:Data,total:Int?=nil,id:UInt32=1)->Data {
        var header = Data(repeating:0,count:32);header[0]=0xf6
        ServiceWire.put(UInt32(body.count),into:&header,at:4);ServiceWire.put(id,into:&header,at:8)
        ServiceWire.put(UInt32(total ?? body.count),into:&header,at:16);ServiceWire.put(42,into:&header,at:24)
        return header+body
    }
    private static func bootstrap()->Data {
        let payload=Data("Realm:Login to TEST-DEVICE\r\nRandom:123456789\r\n".utf8)
        var challenge=Data(repeating:0,count:32);challenge[0]=0xb0;challenge[1]=1
        ServiceWire.put(UInt32(payload.count),into:&challenge,at:4)
        var login=Data(repeating:0,count:32);login[0]=0xb0;login[8]=0;login[9]=8
        ServiceWire.put(42,into:&login,at:16)
        return challenge+payload+login
    }
}

private final class ScriptedService:ServiceTransport {
    var bytes:Data;var writes:[Data]=[];var closed=false
    init(_ bytes:Data){self.bytes=bytes}
    func write(_ data:Data)throws{writes.append(data)}
    func readExactly(_ count:Int)throws->Data{
        guard bytes.count>=count else{throw ServiceWire.invalid}
        let result=Data(bytes.prefix(count));bytes=Data(bytes.dropFirst(count));return result
    }
    func close(){closed=true}
}

import Foundation
import CryptoKit

@main struct CoreTests {
    static var passed=0
    static func require(_ value:Bool,_ name:String)throws{guard value else{throw AppError.message("FAIL: "+name)};passed+=1;print("PASS: "+name)}
    static func expectFailure(_ name:String,_ block:()throws->Void)throws{
        do{try block()}catch{passed+=1;print("PASS: "+name);return}
        throw AppError.message("FAIL: "+name)
    }
    @MainActor static func main()async throws{
        let channel=Channel(name:"Entrada de teste",uri:"rtsp://127.0.0.1:18554/live")
        let camera=Camera(name:"Equipamento de teste",host:"127.0.0.1",httpPort:18780,username:"",channels:[channel])
        var config=Configuration(cameras:[camera],slots:[0:LayoutSlot(cameraID:camera.id,channelID:channel.id)])
        try config.validate()
        let json=try JSONEncoder().encode(config)
        let plain=try BackupCodec.decode(json,password:nil)
        try require(plain.configuration.cameras==[camera] && plain.passwords.isEmpty,"JSON configuration round-trip without credentials")
        let payload=BackupPayload(configuration:config,passwords:[camera.id.uuidString:"test-only-not-a-real-password"])
        let encrypted=try BackupCodec.encrypt(payload,password:"test-backup-password-123")
        try require(!String(decoding:encrypted,as:UTF8.self).contains("test-only-not-a-real-password"),"Encrypted backup does not expose credentials")
        let restored=try BackupCodec.decode(encrypted,password:"test-backup-password-123")
        try require(restored.configuration.cameras==[camera] && restored.passwords==payload.passwords,"Encrypted full backup round-trip")
        try expectFailure("Wrong backup password rejected"){_=try BackupCodec.decode(encrypted,password:"wrong-password-123")}
        var envelope=try JSONDecoder().decode(BackupEnvelope.self,from:encrypted);envelope.ciphertext[30]^=1
        try expectFailure("Tampered ciphertext rejected"){_=try BackupCodec.decode(JSONEncoder().encode(envelope),password:"test-backup-password-123")}
        envelope.iterations=2_000_000
        try expectFailure("Unbounded KDF parameters rejected"){_=try BackupCodec.decode(JSONEncoder().encode(envelope),password:"test-backup-password-123")}
        try expectFailure("Short backup password rejected"){_=try BackupCodec.encrypt(payload,password:"short")}
        config.cameras.append(camera)
        try expectFailure("Duplicate equipment IDs rejected"){try config.validate()}
        config.cameras=[camera];config.slots=[1:LayoutSlot(cameraID:UUID(),channelID:UUID())]
        try expectFailure("Dangling mosaic references rejected"){try config.validate()}
        var invalid=camera;invalid.channels[0].uri="rtsp://admin:secret@127.0.0.1/live"
        try expectFailure("Embedded URI passwords rejected"){try invalid.validate()}
        invalid.channels[0].uri="rtsp://127.0.0.1/live?token=secret"
        try expectFailure("URI access tokens rejected"){try invalid.validate()}
        invalid.channels[0].uri="rtsp://example.com/live"
        try expectFailure("Cross-host stream URI rejected"){try invalid.validate()}
        let xml=try XMLTree.parse(Data("<s:Envelope xmlns:s='urn:test'><s:Body><Profiles token='a'><Name>Teste &amp; canal</Name></Profiles></s:Body></s:Envelope>".utf8))
        try require(xml.first("Name")=="Teste & canal" && xml.all("Profiles").first?.attributes["token"]=="a","Namespace-independent ONVIF XML parser")
        try expectFailure("Malformed ONVIF XML rejected"){_=try XMLTree.parse(Data("<root><broken>".utf8))}
        let parser=JPEGFrames()
        try require(parser.append(Data([1,2,0xff])).isEmpty,"JPEG split start marker buffered")
        try require(parser.append(Data([0xd8,4,5,0xff])).isEmpty,"Incomplete JPEG buffered")
        let frames=parser.append(Data([0xd9,0xff,0xd8,6,0xff,0xd9]))
        try require(frames.count==2 && frames[0]==Data([0xff,0xd8,4,5,0xff,0xd9]),"Split JPEG frames reconstructed and ordered")
        try expectFailure("XML DTD and entity declarations rejected"){_=try XMLTree.parse(Data("<!DOCTYPE a [<!ENTITY secret SYSTEM 'file:///etc/passwd'>]><a>&secret;</a>".utf8))}
        let folder=FileManager.default.temporaryDirectory.appendingPathComponent("vigia-state-tests-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:folder)}
        let secrets=MemorySecrets(),state=AppState(directory:folder,secrets:secrets)
        try state.applyImport(payload,replace:true)
        try require(state.config.cameras==[camera] && secrets.values[camera.id]==payload.passwords[camera.id.uuidString],"Restore replaces configuration and credentials")
        let onDisk=try String(contentsOf:state.file)
        try require(!onDisk.contains("test-only-not-a-real-password"),"Persisted configuration excludes passwords")
        let reloaded=AppState(directory:folder,secrets:secrets)
        try require(reloaded.config.cameras==[camera],"Configuration survives app restart")
        var second=camera;second.id=UUID();second.name="Second fixture"
        var addition=payload.configuration;addition.cameras=[second];addition.slots=[:]
        try state.applyImport(BackupPayload(configuration:addition,passwords:[:]),replace:false)
        try require(state.config.cameras.count==2 && state.config.slots[0]?.cameraID==camera.id,"Merge retains existing equipment and layout")
        let prior=state.config.cameras
        var third=second;third.id=UUID()
        var update=payload.configuration;update.cameras=[camera,third];update.slots=[:]
        secrets.failOnID=third.id
        try expectFailure("Failed credential write aborts restore"){try state.applyImport(BackupPayload(configuration:update,passwords:[camera.id.uuidString:"changed-test-secret",third.id.uuidString:"third-test-secret"]),replace:true)}
        try require(state.config.cameras==prior && secrets.values[camera.id]==payload.passwords[camera.id.uuidString],"Failed restore rolls back configuration and earlier credential writes")
        var removedChannel=camera;removedChannel.channels=[]
        try state.upsert(removedChannel,password:"test-secret")
        try require(state.config.slots.isEmpty,"Editing channels removes stale mosaic references")
        if CommandLine.arguments.contains("--fixture") {
            let client=ONVIFClient(camera:camera,password:"")
            let configured=try await client.services()
            try require(!configured.mediaEndpoint.isEmpty && !configured.replayEndpoint.isEmpty,"ONVIF GetServices integration")
            let c=ONVIFClient(camera:configured,password:"")
            let profiles=try await c.profiles()
            try require(profiles.count==2 && profiles[0].profileToken=="main","ONVIF profiles and stream URI integration")
            let recordings=try await c.recordings()
            try require(recordings.count==1,"ONVIF remote recording enumeration")
            let uri=try await c.replayURI(token:recordings[0].id)
            try require(uri.hasSuffix("/replay"),"ONVIF replay URI integration")
            try await c.ptz(token:"main",x:0.2,y:0,z:0)
            try require(true,"ONVIF PTZ move and stop integration")
        }
        print("SUCCESS: \(passed) checks")
    }
}

final class MemorySecrets:SecretStorage {
    var values:[UUID:String]=[:]
    var failOnID:UUID?
    func read(_ id:UUID)throws->String{values[id] ?? ""}
    func write(_ password:String,id:UUID)throws{if failOnID==id{failOnID=nil;throw AppError.message("Simulated credential write failure")};values[id]=password}
    func remove(_ id:UUID){values.removeValue(forKey:id)}
}

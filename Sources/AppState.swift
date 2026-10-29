import Foundation
import SwiftUI
import Combine
import AppKit
import UniformTypeIdentifiers

@MainActor final class AppState:ObservableObject {
    @Published var config=Configuration()
    @Published var selectedCamera:UUID?
    @Published var selectedSlot=0 {didSet{canSnapshot=sessions[selectedSlot]?.image != nil}}
    @Published var canSnapshot=false
    @Published var sessions:[Int:VideoSession]=[:] {didSet{canSnapshot=sessions[selectedSlot]?.image != nil}}
    private var streamSubscriptions:[Int:AnyCancellable]=[:]
    private var jobSubscriptions:[UUID:AnyCancellable]=[:]
    @Published var jobs:[RecordingJob]=[]
    @Published var message:String?
    @Published var busy=false
    @Published var status="Pronto para adicionar um equipamento"
    @Published var discovery:[DiscoveredDevice]=[]
    @Published var search=""
    let secrets:SecretStorage
    let directory:URL
    var file:URL {directory.appendingPathComponent("configuration.json")}
    var cameras:[Camera]{config.cameras.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search)}}
    var current:VideoSession?{sessions[selectedSlot]}
    init(directory overrideDirectory:URL?=nil,secrets:SecretStorage=CredentialStore()) {
        self.secrets=secrets
        if let overrideDirectory{directory=overrideDirectory}
        else if let path=ProcessInfo.processInfo.environment["VIGIA_DATA_DIR"] ?? Bundle.main.object(forInfoDictionaryKey:"VigiaDataDirectory") as? String {
            directory=URL(fileURLWithPath:path,isDirectory:true)
        } else {directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VigiaARM",isDirectory:true)}
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            if FileManager.default.fileExists(atPath:file.path) {
                let data=try Data(contentsOf:file);guard data.count<10_000_000 else{throw AppError.message("Configuração local excede 10 MB.")}
                config=try JSONDecoder().decode(Configuration.self,from:data);try config.validate()
            }
        } catch{message="Não foi possível carregar a configuração. O arquivo foi preservado. \(error.localizedDescription)"}
    }
    func save() throws {
        try config.validate()
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(config).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func pruneSlots(){config.slots=config.slots.filter{_,slot in config.cameras.contains(where:{$0.id==slot.cameraID && $0.channels.contains(where:{$0.id==slot.channelID})})}}
    func report(_ error:Error){message=error.localizedDescription}
    func upsert(_ camera:Camera,password:String) throws {
        try camera.validate()
        let old=config
        let previous=try secrets.read(camera.id)
        try secrets.write(password,id:camera.id)
        if let i=config.cameras.firstIndex(where:{$0.id==camera.id}){config.cameras[i]=camera}else{config.cameras.append(camera)}
        pruneSlots()
        do{try save()}catch{config=old;try? secrets.write(previous,id:camera.id);throw error}
        selectedCamera=camera.id;status="Equipamento salvo"
    }
    func remove(_ camera:Camera) {
        let alert=NSAlert();alert.messageText="Remover \(camera.name)?";alert.informativeText="O cadastro e a senha local serão removidos. O equipamento não será alterado.";alert.addButton(withTitle:"Remover");alert.addButton(withTitle:"Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        let old=config
        for (slot,session) in sessions where session.camera.id==camera.id {session.stop();sessions.removeValue(forKey:slot)}
        config.cameras.removeAll{$0.id==camera.id};config.slots=config.slots.filter{$0.value.cameraID != camera.id}
        do{try save();secrets.remove(camera.id);selectedCamera=nil}catch{config=old;report(error)}
    }
    func setLayout(_ count:Int) {
        for (slot,session) in sessions where slot>=count {session.stop();sessions.removeValue(forKey:slot)}
        config.layout=count;if selectedSlot>=count{selectedSlot=0}
        do{try save()}catch{report(error)}
    }
    func connect(_ camera:Camera,_ channel:Channel,slot:Int?=nil) {
        let target=slot ?? selectedSlot
        do {
            let password=try secrets.read(camera.id),uri=try camera.authenticatedURI(channel.uri,password:password)
            try open(camera:camera,channel:channel,source:MediaInput(uri:uri),slot:target)
            config.slots[target]=LayoutSlot(cameraID:camera.id,channelID:channel.id);try save()
        }catch{report(error)}
    }
    func open(camera:Camera,channel:Channel,source:MediaInput,slot:Int) throws {
        sessions[slot]?.stop()
        let session=VideoSession(camera:camera,channel:channel,source:source)
        try session.start(quality:config.quality);sessions[slot]=session;selectedSlot=slot;selectedCamera=camera.id
        streamSubscriptions[slot]=session.$active.removeDuplicates().sink{[weak self,weak session] _ in
            guard let self,let session,self.selectedSlot==slot,self.sessions[slot]===session else{return}
            self.canSnapshot=session.image != nil
        }
    }
    func reconnect(){guard let s=current else{return};do{try s.start(quality:config.quality)}catch{report(error)}}
    func connectSavedLayout(){for (slot,item) in config.slots.sorted(by:{$0.key<$1.key}) where slot<config.layout {if let c=config.cameras.first(where:{$0.id==item.cameraID}),let ch=c.channels.first(where:{$0.id==item.channelID}){connect(c,ch,slot:slot)}}}
    func disconnect(_ slot:Int){sessions[slot]?.stop();sessions.removeValue(forKey:slot)}
    func stopAll(){sessions.values.forEach{$0.stop()};jobs.forEach{$0.stop()};sessions.removeAll()}
    func discover(){busy=true;status="Procurando equipamentos ONVIF na rede local…";Task{discovery=await ONVIFClient.discover();busy=false;status=discovery.isEmpty ? "Nenhum ONVIF encontrado. Você pode cadastrar por endereço.":"\(discovery.count) equipamento(s) encontrado(s)"}}
    func client(_ c:Camera)throws->ONVIFClient{ONVIFClient(camera:c,password:try secrets.read(c.id))}
    func snapshot(){guard let current else{return};let panel=NSSavePanel();panel.allowedContentTypes=[.png];panel.nameFieldStringValue="Vigia-\(Self.stamp()).png";if panel.runModal() == .OK,let url=panel.url {do{try current.snapshot(to:url);status="Imagem salva"}catch{report(error)}}}
    func record(){guard let current else{return};if let job=current.recording,job.running{job.stop();return};let panel=NSSavePanel();panel.allowedContentTypes=[UTType(filenameExtension:"mkv") ?? .movie];panel.nameFieldStringValue="Vigia-\(Self.stamp()).mkv";if panel.runModal() == .OK,let url=panel.url{do{try current.record(to:url);if let job=current.recording{track(job)}}catch{report(error)}}}
    func track(_ job:RecordingJob){
        jobs.append(job)
        jobSubscriptions[job.id]=job.$running.removeDuplicates().sink{[weak self] _ in self?.objectWillChange.send()}
    }
    func exportConfiguration(){let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="Vigia-configuracao-\(Self.stamp()).json";if panel.runModal() == .OK,let url=panel.url {do{var c=config;c.exportedAt=Date();let e=JSONEncoder();e.outputFormatting=[.prettyPrinted,.sortedKeys];try e.encode(c).write(to:url,options:.atomic);status="Configuração exportada sem senhas"}catch{report(error)}}}
    func exportBackup(password:String) async throws {
        var values:[String:String]=[:]
        for camera in config.cameras{values[camera.id.uuidString]=try secrets.read(camera.id)}
        var c=config;c.exportedAt=Date();let payload=BackupPayload(configuration:c,passwords:values)
        let data=try await Task.detached{try BackupCodec.encrypt(payload,password:password)}.value
        let panel=NSSavePanel();panel.allowedContentTypes=[UTType(filenameExtension:"vigiabackup") ?? .data];panel.nameFieldStringValue="Vigia-backup-\(Self.stamp()).vigiabackup"
        if panel.runModal() == .OK,let url=panel.url{try data.write(to:url,options:.atomic);try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:url.path);status="Backup criptografado salvo"}
    }
    func pickImport()->Data?{let p=NSOpenPanel();p.canChooseDirectories=false;p.allowsMultipleSelection=false;p.allowedContentTypes=[.json,.data];if p.runModal() == .OK,let u=p.url{do{let size=try u.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0;guard size<=10_000_000 else{throw AppError.message("Arquivo maior que 10 MB.")};return try Data(contentsOf:u)}catch{report(error)}};return nil}
    func applyImport(_ payload:BackupPayload,replace:Bool)throws {
        try payload.configuration.validate()
        let old=config;var previous:[UUID:String]=[:];var written:[UUID]=[]
        for camera in payload.configuration.cameras where payload.passwords[camera.id.uuidString] != nil{previous[camera.id]=try secrets.read(camera.id)}
        do {
            for camera in payload.configuration.cameras {if let p=payload.passwords[camera.id.uuidString]{try secrets.write(p,id:camera.id);written.append(camera.id)}}
            if replace{config=payload.configuration}else{
                for camera in payload.configuration.cameras{if let i=config.cameras.firstIndex(where:{$0.id==camera.id}){config.cameras[i]=camera}else{config.cameras.append(camera)}}
                // Retain current layout when merging equipment configurations.
            }
            pruneSlots();try save()
        }catch{config=old;for id in written{try? secrets.write(previous[id] ?? "",id:id)};throw error}
        stopAll()
        if replace{for c in old.cameras where !config.cameras.contains(where:{$0.id==c.id}){secrets.remove(c.id)}}
        selectedCamera=nil;status="\(payload.configuration.cameras.count) equipamento(s) importado(s). Conecte o mosaico quando quiser."
    }
    func openLocalRecording(){let p=NSOpenPanel();p.allowedContentTypes=[.movie,.mpeg4Movie,UTType(filenameExtension:"mkv") ?? .movie];if p.runModal() == .OK,let u=p.url{do{let c=Camera(name:"Arquivo local",host:"localhost");let channel=Channel(name:u.lastPathComponent,uri:"rtsp://localhost/");try open(camera:c,channel:channel,source:MediaInput(uri:u.path,localFile:true),slot:selectedSlot)}catch{report(error)}}}
    static func stamp()->String{let f=DateFormatter();f.dateFormat="yyyy-MM-dd_HH-mm-ss";return f.string(from:Date())}
}

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
    @Published var locked=false
    @Published var hasLockPassword=false
    @Published var lockProblem:String?
    let secrets:SecretStorage
    let directory:URL
    var file:URL {directory.appendingPathComponent("configuration.json")}
    var cameras:[Camera]{config.cameras.filter{search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.host.localizedCaseInsensitiveContains(search)}}
    var current:VideoSession?{sessions[selectedSlot]}
    func isFavoriteActive(_ favorite:FavoriteLayout)->Bool{
        guard config.layout==favorite.rows*favorite.columns,config.columns==favorite.columns,!favorite.slots.isEmpty else{return false}
        let active=sessions.filter{$0.value.active}
        guard active.count==favorite.slots.count else{return false}
        return favorite.slots.allSatisfy{slot,item in guard let session=active[slot] else{return false};return session.camera.id==item.cameraID && session.channel.id==item.channelID}
    }
    init(directory overrideDirectory:URL?=nil,secrets:SecretStorage=CredentialStore()) {
        self.secrets=secrets
        if let overrideDirectory{directory=overrideDirectory}
        else if let path=ProcessInfo.processInfo.environment["VIGIA_DATA_DIR"] ?? Bundle.main.object(forInfoDictionaryKey:"VigiaDataDirectory") as? String {
            directory=URL(fileURLWithPath:path,isDirectory:true)
        } else {directory=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("VigiaARM",isDirectory:true)}
        do{hasLockPassword = !(try secrets.read(AppLockCodec.id)).isEmpty;locked=hasLockPassword}
        catch{locked=true;hasLockPassword=true;lockProblem="Não foi possível acessar a senha no Chaves do macOS."}
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            if FileManager.default.fileExists(atPath:file.path) {
                let data=try Data(contentsOf:file);guard data.count<10_000_000 else{throw AppError.message("Configuração local excede 10 MB.")}
                config=try JSONDecoder().decode(Configuration.self,from:data);try config.validate()
            }
        } catch{message="Não foi possível carregar a configuração. O arquivo foi preservado. \(error.localizedDescription)"}
    }
    func unlock(_ password:String)throws{
        let stored=try secrets.read(AppLockCodec.id)
        guard !stored.isEmpty,try AppLockCodec.verify(password,stored:stored) else{throw AppError.message("Senha incorreta.")}
        lockProblem=nil;locked=false
    }
    func configureLock(current:String,newPassword:String)throws{
        if hasLockPassword {
            let stored=try secrets.read(AppLockCodec.id)
            guard !stored.isEmpty,try AppLockCodec.verify(current,stored:stored) else{throw AppError.message("Senha atual incorreta.")}
        }
        let value=try AppLockCodec.make(newPassword)
        try secrets.write(value,id:AppLockCodec.id);hasLockPassword=true;lockProblem=nil
    }
    func removeLock(current:String)throws{
        let stored=try secrets.read(AppLockCodec.id)
        guard !stored.isEmpty,try AppLockCodec.verify(current,stored:stored) else{throw AppError.message("Senha atual incorreta.")}
        // SecretStorage.remove has no status; verify deletion before changing UI state.
        secrets.remove(AppLockCodec.id)
        guard try secrets.read(AppLockCodec.id).isEmpty else{throw AppError.message("Não foi possível remover a senha no Chaves.")}
        hasLockPassword=false;lockProblem=nil
    }
    func save() throws {
        try config.validate()
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(config).write(to:file,options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
    }
    func pruneSlots(){
        func exists(_ slot:LayoutSlot)->Bool{config.cameras.contains(where:{$0.id==slot.cameraID && $0.channels.contains(where:{$0.id==slot.channelID})})}
        config.slots=config.slots.filter{exists($0.value)}
        if var favorites=config.favorites{for i in favorites.indices{favorites[i].slots=favorites[i].slots.filter{exists($0.value)}};config.favorites=favorites}
    }
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
        pruneSlots()
        do{try save();secrets.remove(camera.id);selectedCamera=nil}catch{config=old;report(error)}
    }
    func setLayout(_ count:Int,columns:Int?=nil) {
        for (slot,session) in sessions where slot>=count {session.stop();sessions.removeValue(forKey:slot)}
        config.layout=count;config.layoutColumns=columns;if selectedSlot>=count{selectedSlot=0}
        do{try save()}catch{report(error)}
    }
    func customLayout(){
        let alert=NSAlert();alert.messageText="Layout personalizado";alert.informativeText="Informe de 1 a 8 linhas e de 1 a 8 colunas."
        let form=NSView(frame:NSRect(x:0,y:0,width:300,height:64))
        let rowLabel=NSTextField(labelWithString:"Linhas:"),columnLabel=NSTextField(labelWithString:"Colunas:")
        rowLabel.frame=NSRect(x:0,y:37,width:95,height:20);columnLabel.frame=NSRect(x:0,y:7,width:95,height:20)
        let r=NSTextField(frame:NSRect(x:100,y:33,width:185,height:24)),c=NSTextField(frame:NSRect(x:100,y:3,width:185,height:24))
        r.stringValue="\(config.rows)";c.stringValue="\(config.columns)"
        form.addSubview(rowLabel);form.addSubview(columnLabel);form.addSubview(r);form.addSubview(c);alert.accessoryView=form
        alert.addButton(withTitle:"Aplicar");alert.addButton(withTitle:"Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        guard let rows=Int(r.stringValue),let columns=Int(c.stringValue),(1...8).contains(rows),(1...8).contains(columns) else{message="Informe linhas e colunas entre 1 e 8.";return}
        setLayout(rows*columns,columns:columns)
    }
    func saveFavorite(){
        let alert=NSAlert();alert.messageText="Salvar favorito";alert.informativeText="Salva os canais atualmente ativos e o layout."
        let field=NSTextField(frame:NSRect(x:0,y:0,width:300,height:24));field.placeholderString="Nome do favorito";alert.accessoryView=field;alert.addButton(withTitle:"Salvar");alert.addButton(withTitle:"Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        let name=field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty,name.count<=160 else{message="Informe um nome para o favorito.";return}
        let existing=(config.favorites ?? []).first(where:{$0.name.caseInsensitiveCompare(name) == .orderedSame})
        if let existing{overwriteFavorite(existing);return}
        do{try storeFavorite(name:name,id:nil)}catch{report(error)}
    }
    func storeFavorite(name:String,id:UUID?)throws{
        let trimmed=name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !trimmed.isEmpty,trimmed.count<=160 else{throw AppError.message("Informe um nome para o favorito.")}
        let active=config.slots.filter{sessions[$0.key]?.active == true && $0.key<config.layout}
        guard !active.isEmpty else{throw AppError.message("Abra pelo menos um canal antes de salvar o favorito.")}
        var favorites=config.favorites ?? []
        guard !favorites.contains(where:{$0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame}) else{throw AppError.message("Já existe um favorito com esse nome.")}
        if let id{
            guard let index=favorites.firstIndex(where:{$0.id==id}) else{throw AppError.message("Favorito não encontrado.")}
            favorites[index]=FavoriteLayout(id:id,name:trimmed,rows:config.rows,columns:config.columns,slots:active)
        }else{favorites.append(FavoriteLayout(name:trimmed,rows:config.rows,columns:config.columns,slots:active))}
        let previous=config;config.favorites=favorites
        do{try save();status="Favorito salvo"}catch{config=previous;throw error}
    }
    func overwriteFavorite(_ favorite:FavoriteLayout){
        let alert=NSAlert();alert.messageText="Sobrescrever favorito?";alert.informativeText="O layout e as câmeras salvos em ‘\(favorite.name)’ serão substituídos pelo mosaico atual.";alert.addButton(withTitle:"Sobrescrever");alert.addButton(withTitle:"Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        do{try storeFavorite(name:favorite.name,id:favorite.id)}catch{report(error)}
    }
    func renameFavorite(_ favorite:FavoriteLayout){
        let alert=NSAlert();alert.messageText="Renomear favorito";let field=NSTextField(frame:NSRect(x:0,y:0,width:300,height:24));field.stringValue=favorite.name;alert.accessoryView=field;alert.addButton(withTitle:"Salvar");alert.addButton(withTitle:"Cancelar")
        guard alert.runModal() == .alertFirstButtonReturn else{return}
        do{try setFavoriteName(favorite.id,name:field.stringValue)}catch{report(error)}
    }
    func setFavoriteName(_ id:UUID,name:String)throws{
        let name=name.trimmingCharacters(in:.whitespacesAndNewlines);var favorites=config.favorites ?? []
        guard !name.isEmpty,name.count<=160 else{throw AppError.message("Informe um nome para o favorito.")}
        guard let index=favorites.firstIndex(where:{$0.id==id}) else{throw AppError.message("Favorito não encontrado.")}
        guard !favorites.contains(where:{$0.id != id && $0.name.caseInsensitiveCompare(name) == .orderedSame}) else{throw AppError.message("Já existe um favorito com esse nome.")}
        let previous=config;favorites[index].name=name;config.favorites=favorites
        do{try save();status="Favorito renomeado"}catch{config=previous;throw error}
    }
    func loadFavorite(_ favorite:FavoriteLayout){
        stopAll();config.layout=favorite.rows*favorite.columns;config.layoutColumns=favorite.columns;config.slots=favorite.slots;selectedSlot=0
        do{try save();connectSavedLayout();status="Favorito aberto"}catch{report(error)}
    }
    func deleteFavorite(_ id:UUID){let previous=config;config.favorites?.removeAll{$0.id==id};do{try save();status="Favorito excluído"}catch{config=previous;report(error)}}
    func connect(_ camera:Camera,_ channel:Channel,slot:Int?=nil) {
        let target=slot ?? selectedSlot
        do {
            let password=try secrets.read(camera.id)
            let source:MediaInput
            if let index=channel.serviceIndex,let service=camera.service{
                try camera.validate()
                source=MediaInput(uri:"",service:ServiceMediaSource(host:camera.host,port:service.port,username:camera.username,password:password,channel:index,substream:service.substream ?? true))
            }else{source=MediaInput(uri:try camera.authenticatedURI(channel.uri,password:password))}
            try open(camera:camera,channel:channel,source:source,slot:target)
            config.slots[target]=LayoutSlot(cameraID:camera.id,channelID:channel.id);try save()
            // A click in the channel list advances; restoring saved positions does not.
            if slot == nil{selectedSlot=(target+1)%config.layout}
        }catch{report(error)}
    }
    func open(camera:Camera,channel:Channel,source:MediaInput,slot:Int) throws {
        sessions[slot]?.stop()
        let session=VideoSession(camera:camera,channel:channel,source:source)
        try session.start(quality:config.quality);sessions[slot]=session;selectedSlot=slot;selectedCamera=camera.id
        observeSession(session,slot:slot)
    }
    private func observeSession(_ session:VideoSession,slot:Int){
        streamSubscriptions[slot]=session.$active.removeDuplicates().sink{[weak self,weak session] _ in
            guard let self,let session,self.sessions[slot]===session else{return}
            self.objectWillChange.send()
            if self.selectedSlot==slot{self.canSnapshot=session.image != nil}
        }
    }
    func swapSlots(_ source:Int,_ destination:Int){
        guard source != destination,(0..<config.layout).contains(source),(0..<config.layout).contains(destination),sessions[source] != nil else{return}
        let old=config
        let a=config.slots[source],b=config.slots[destination]
        config.slots[source]=b;config.slots[destination]=a
        do{try save()}catch{config=old;report(error);return}
        let first=sessions[source],second=sessions[destination]
        streamSubscriptions.removeValue(forKey:source);streamSubscriptions.removeValue(forKey:destination)
        sessions[source]=second;sessions[destination]=first
        if let second{observeSession(second,slot:source)}
        if let first{observeSession(first,slot:destination)}
        selectedSlot=destination
    }
    func reconnect(){guard let s=current else{return};do{try s.start(quality:config.quality)}catch{report(error)}}
    func connectSavedLayout(){for (slot,item) in config.slots.sorted(by:{$0.key<$1.key}) where slot<config.layout {if let c=config.cameras.first(where:{$0.id==item.cameraID}),let ch=c.channels.first(where:{$0.id==item.channelID}){connect(c,ch,slot:slot)}}}
    func disconnect(_ slot:Int){sessions[slot]?.stop();sessions.removeValue(forKey:slot)}
    func stopAll(){sessions.values.forEach{$0.stop()};jobs.forEach{$0.stop()};sessions.removeAll()}
    func discover(){busy=true;status="Procurando equipamentos ONVIF na rede local…";Task{discovery=await ONVIFClient.discover();busy=false;status=discovery.isEmpty ? "Nenhum ONVIF encontrado. Você pode cadastrar por endereço.":"\(discovery.count) equipamento(s) encontrado(s)"}}
    func client(_ c:Camera)throws->ONVIFClient{ONVIFClient(camera:c,password:try secrets.read(c.id))}
    func snapshot(){guard let current else{return};let panel=NSSavePanel();panel.allowedContentTypes=[.png];panel.nameFieldStringValue="Vigia-\(Self.stamp()).png";if panel.runModal() == .OK,let url=panel.url {do{try current.snapshot(to:url);status="Imagem salva"}catch{report(error)}}}
    func record(){guard let current else{return};if let job=current.recording,job.running{job.stop();return};let panel=NSSavePanel();panel.allowedContentTypes=[.mpeg4Movie];panel.nameFieldStringValue="Vigia-\(Self.stamp()).mp4";if panel.runModal() == .OK,let url=panel.url{do{try current.record(to:url);if let job=current.recording{track(job)}}catch{report(error)}}}
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

import SwiftUI
import AppKit

// Explicit alias selects the stable property wrapper on SDKs that also expose a State macro.
typealias ViewState<Value> = SwiftUI.State<Value>

private let accent=Color(red:0.22,green:0.85,blue:0.78)
private let base=Color(red:0.055,green:0.075,blue:0.105)
private let panel=Color(red:0.085,green:0.11,blue:0.15)
struct PrimaryButtonStyle:ButtonStyle {
    var color:Color=accent
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration:ButtonStyleConfiguration)->some View {
        configuration.label.font(.system(size:12,weight:.semibold)).padding(.horizontal,13).padding(.vertical,9)
            .foregroundStyle(Color.black.opacity(enabled ? 1:0.5))
            .background(color.opacity(enabled ? (configuration.isPressed ? 0.7:1):0.25),in:RoundedRectangle(cornerRadius:7))
    }
}
struct ImportRequest:Identifiable{let id=UUID();let data:Data}
struct RootView:View {
    @EnvironmentObject var state:AppState
    @ViewState private var editing:Camera?
    @ViewState private var showDiscovery=false
    @ViewState private var showBackup=false
    @ViewState private var importRequest:ImportRequest?
    @ViewState private var page="Ao vivo"
    var body:some View {
        HStack(spacing:0){
            VStack(alignment:.leading,spacing:18){
                HStack(spacing:10){Image(systemName:"eye.circle.fill").font(.system(size:33)).foregroundStyle(accent);VStack(alignment:.leading,spacing:2){Text("VIGIA").font(.system(size:21,weight:.bold,design:.rounded));Text("ARM • 1.0.0").font(.system(size:10,weight:.semibold,design:.monospaced)).foregroundStyle(.secondary)}}.padding(.top,12)
                TextField("Buscar equipamento",text:$state.search).textFieldStyle(.roundedBorder)
                HStack{Text("EQUIPAMENTOS").font(.system(size:10,weight:.bold)).foregroundStyle(.secondary);Spacer();Text("\(state.config.cameras.count)").font(.caption.monospacedDigit()).foregroundStyle(accent)}
                ScrollView{
                    VStack(alignment:.leading,spacing:10){
                        ForEach(state.cameras){camera in
                            DisclosureGroup{
                                ForEach(camera.channels){channel in
                                    Button{state.connect(camera,channel)}label:{HStack{Image(systemName:"video").foregroundStyle(accent);Text(channel.name).lineLimit(1);Spacer();Image(systemName:"play.fill").font(.system(size:9)).foregroundStyle(.secondary)}.padding(.vertical,6)}.buttonStyle(.plain)
                                }
                                if camera.channels.isEmpty{Button("Configurar canais…"){editing=camera}.font(.caption).padding(.vertical,6)}
                            }label:{HStack{Image(systemName:"externaldrive.connected.to.line.below").foregroundStyle(state.selectedCamera==camera.id ? accent:.secondary);VStack(alignment:.leading,spacing:3){Text(camera.name).font(.system(size:12,weight:.semibold));Text("\(camera.channels.count) canais").font(.system(size:10)).foregroundStyle(.secondary)}}.padding(.vertical,5)}
                            .contextMenu{Button("Editar equipamento"){editing=camera};Button("Gravações"){state.selectedCamera=camera.id;page="Gravações"};Divider();Button("Remover",role:.destructive){state.remove(camera)}}
                        }
                    }
                }
                Spacer(minLength:0)
                Button{editing=Camera()}label:{Label("Adicionar equipamento",systemImage:"plus")}.buttonStyle(PrimaryButtonStyle()).frame(maxWidth:.infinity)
                Button{showDiscovery=true;state.discover()}label:{Label("Descobrir na rede",systemImage:"network")}.buttonStyle(.bordered).frame(maxWidth:.infinity)
                Divider()
                HStack(spacing:5){Circle().fill(MediaBackend.executable==nil ? Color.orange:accent).frame(width:6,height:6);Text(MediaBackend.executable==nil ? "Mecanismo ausente":"Apple Silicon • nativo").font(.system(size:10)).foregroundStyle(.secondary)}
                Text("Cliente independente • RTSP / ONVIF").font(.system(size:9)).foregroundStyle(.tertiary)
            }.padding(18).frame(width:232).background(panel)
            Rectangle().fill(.white.opacity(0.07)).frame(width:1)
            VStack(spacing:0){
                HStack(spacing:22){
                    ForEach(["Ao vivo","Gravações","Backups"],id:\.self){name in Button{page=name}label:{VStack(spacing:9){Text(name).font(.system(size:13,weight:page==name ? .semibold:.regular)).foregroundStyle(page==name ? .white:.secondary);Rectangle().fill(page==name ? accent:.clear).frame(height:2)}}.buttonStyle(.plain).fixedSize()}
                    Spacer()
                    if state.busy{ProgressView().controlSize(.small)}
                    Text("ARM64").font(.system(size:10,weight:.bold,design:.monospaced)).foregroundStyle(accent).padding(.horizontal,9).padding(.vertical,5).background(accent.opacity(0.1),in:Capsule())
                    Menu{Button("Abrir vídeo local…"){state.openLocalRecording();page="Ao vivo"};Button("Abrir pasta de configurações"){NSWorkspace.shared.open(state.directory)};Button("Sobre o Vigia ARM"){NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Vigia ARM",.applicationVersion:"1.0.0",.credits:NSAttributedString(string:"Cliente independente RTSP / ONVIF para Apple Silicon.\nVídeo com FFmpeg LGPL 2.1+. Sem código ou SDK do SIM Play.\nGravações remotas e PTZ dependem do suporte do equipamento.")])}}label:{Image(systemName:"ellipsis.circle").font(.title3)}.menuStyle(.borderlessButton).frame(width:25)
                }.padding(.horizontal,25).padding(.top,20).padding(.bottom,12)
                Divider().overlay(.white.opacity(0.04))
                if page=="Ao vivo"{liveView}else if page=="Gravações"{RecordingsView()}else{backupView}
                HStack{Circle().fill(state.busy ? Color.orange:accent).frame(width:5,height:5);Text(state.status).lineLimit(1);Spacer();Text("\(state.sessions.count) painel(is) aberto(s)").monospacedDigit()}.font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,20).padding(.vertical,10).background(panel.opacity(0.8))
            }
        }.background(base).preferredColorScheme(.dark).frame(minWidth:1120,minHeight:720)
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("VigiaNewCamera"))){_ in editing=Camera()}
        .onReceive(NotificationCenter.default.publisher(for:Notification.Name("VigiaImport"))){_ in if let bytes=state.pickImport(){importRequest=ImportRequest(data:bytes)}}
        .sheet(item:$editing){camera in CameraEditor(camera:camera).environmentObject(state)}
        .sheet(isPresented:$showDiscovery){discoveryView}
        .sheet(isPresented:$showBackup){BackupSheet().environmentObject(state)}
        .sheet(item:$importRequest){request in ImportSheet(data:request.data).environmentObject(state)}
        .alert("Vigia ARM",isPresented:Binding(get:{state.message != nil},set:{if !$0{state.message=nil}})){Button("OK"){state.message=nil}}message:{Text(state.message ?? "")}
    }
    var liveView:some View{
        VStack(spacing:16){
            HStack{
                VStack(alignment:.leading,spacing:4){Text("Sua visão, em tempo real.").font(.system(size:22,weight:.semibold));Text("Selecione um painel e abra um canal na lista à esquerda.").font(.system(size:11)).foregroundStyle(.secondary)}
                Spacer()
                Picker("Qualidade",selection:$state.config.quality){ForEach(["Econômico","Equilibrado","Detalhado"],id:\.self){Text($0)}}.labelsHidden().frame(width:135).onChange(of:state.config.quality){ do{try state.save()}catch{state.report(error)}}
                HStack(spacing:2){ForEach([1,4,9,16],id:\.self){count in Button{state.setLayout(count)}label:{Text("\(count)").font(.system(size:11,weight:.medium)).frame(width:27,height:24).background(state.config.layout==count ? accent.opacity(0.2):.clear,in:RoundedRectangle(cornerRadius:5))}.buttonStyle(.plain)}}.padding(3).background(panel,in:RoundedRectangle(cornerRadius:7))
            }
            if state.config.cameras.isEmpty {
                VStack(spacing:18){Image(systemName:"viewfinder").font(.system(size:60,weight:.ultraLight)).foregroundStyle(accent);Text("Seu monitoramento começa aqui").font(.system(size:23,weight:.semibold));Text("Cadastre uma câmera ou gravador por ONVIF ou RTSP.\nSeus acessos ficam no Chaves do macOS.").multilineTextAlignment(.center).font(.system(size:13)).foregroundStyle(.secondary);HStack{Button("Adicionar equipamento"){editing=Camera()}.buttonStyle(PrimaryButtonStyle());Button("Importar configuração"){if let bytes=state.pickImport(){importRequest=ImportRequest(data:bytes)}}}}.frame(maxWidth:.infinity,maxHeight:.infinity).background(panel.opacity(0.5),in:RoundedRectangle(cornerRadius:14))
            }else{
                let columns=Int(Double(state.config.layout).squareRoot())
                GeometryReader{geo in
                    let rows=columns
                    LazyVGrid(columns:Array(repeating:GridItem(.flexible(),spacing:8),count:columns),spacing:8){
                        ForEach(0..<state.config.layout,id:\.self){slot in
                            Group{if let session=state.sessions[slot]{VideoTile(session:session,slot:slot)}else{EmptyTile(slot:slot)}}
                                .frame(height:max(90,(geo.size.height-Double(rows-1)*8)/Double(rows)))
                                .overlay(RoundedRectangle(cornerRadius:8).stroke(state.selectedSlot==slot ? accent:Color.white.opacity(0.09),lineWidth:state.selectedSlot==slot ? 2:1))
                                .onTapGesture{state.selectedSlot=slot}
                        }
                    }
                }
            }
            HStack(spacing:12){
                Button{state.connectSavedLayout()}label:{Label("Conectar mosaico",systemImage:"play.rectangle")}
                Button{state.stopAll()}label:{Label("Desconectar",systemImage:"stop.circle")}
                Spacer()
                Button{state.snapshot()}label:{Image(systemName:"camera")}.help("Salvar imagem PNG").disabled(!state.canSnapshot)
                Button{state.record()}label:{Label(state.current?.recording?.running == true ? "Finalizar":"Gravar",systemImage:"record.circle")}.disabled(state.current==nil)
                Button{state.reconnect()}label:{Image(systemName:"arrow.clockwise")}.help("Reconectar painel").disabled(state.current==nil)
            }.buttonStyle(.bordered).controlSize(.small)
        }.padding(22)
    }
    var backupView:some View{
        VStack(alignment:.leading,spacing:24){Text("Configurações protegidas.").font(.system(size:27,weight:.semibold));Text("Leve seus equipamentos e seu mosaico para outro Mac ou guarde uma cópia de segurança.").foregroundStyle(.secondary)
            HStack(alignment:.top,spacing:20){
                backupCard(icon:"doc.text",title:"Exportar configuração",text:"Arquivo JSON com equipamentos, canais e mosaico. Não inclui senhas de acesso.",button:"Exportar JSON"){state.exportConfiguration()}
                backupCard(icon:"lock.shield",title:"Backup completo",text:"Inclui senhas, protegido com AES-256-GCM e uma senha de backup. Guarde essa senha: não há recuperação.",button:"Criar backup criptografado"){showBackup=true}
                backupCard(icon:"square.and.arrow.down",title:"Restaurar ou mesclar",text:"Confira os equipamentos antes de importar. Você escolhe mesclar ou substituir a configuração atual.",button:"Importar arquivo"){if let bytes=state.pickImport(){importRequest=ImportRequest(data:bytes)}}
            }
            Label("Formatos próprios do Vigia ARM. Arquivos do SIM Play não são compatíveis automaticamente.",systemImage:"info.circle").font(.callout).foregroundStyle(.secondary)
            if !state.jobs.isEmpty{Text("Arquivos de vídeo").font(.headline);ScrollView{ForEach(state.jobs){job in JobRow(job:job)}}}
            Spacer()
        }.padding(30).frame(maxWidth:.infinity,alignment:.leading)
    }
    func backupCard(icon:String,title:String,text:String,button:String,action:@escaping()->Void)->some View{
        VStack(alignment:.leading,spacing:15){Image(systemName:icon).font(.system(size:30)).foregroundStyle(accent);Text(title).font(.headline);Text(text).font(.callout).foregroundStyle(.secondary).frame(minHeight:85,alignment:.top);Button(button,action:action).buttonStyle(.bordered)}.padding(24).frame(maxWidth:.infinity,minHeight:255,alignment:.topLeading).background(panel,in:RoundedRectangle(cornerRadius:14))
    }
    var discoveryView:some View{
        VStack(alignment:.leading,spacing:18){Text("Equipamentos na rede").font(.title2.bold());Text("Busca ONVIF por multicast na rede local. Nenhuma senha é enviada na descoberta.").foregroundStyle(.secondary)
            if state.busy{ProgressView("Procurando…").frame(maxWidth:.infinity,minHeight:150)}else if state.discovery.isEmpty{Text("Nenhum equipamento respondeu. Verifique se ONVIF está habilitado ou cadastre pelo endereço.").frame(minHeight:150)}else{List(state.discovery){device in HStack{Image(systemName:"network");VStack(alignment:.leading){Text(device.label);Text("\(device.host):\(device.port)").font(.caption).foregroundStyle(.secondary)};Spacer();Button("Adicionar"){showDiscovery=false;var c=Camera();c.host=device.host;c.httpPort=device.port;c.tls=device.tls;DispatchQueue.main.asyncAfter(deadline:.now()+0.3){editing=c}}}}.frame(height:240)}
            HStack{Button("Buscar novamente"){state.discover()}.disabled(state.busy);Spacer();Button("Fechar"){showDiscovery=false}.keyboardShortcut(.cancelAction)}
        }.padding(25).frame(width:570)
    }
}
struct EmptyTile:View{
    let slot:Int
    var body:some View{VStack(spacing:8){Image(systemName:"plus.viewfinder").font(.system(size:27,weight:.light)).foregroundStyle(.white.opacity(0.2));Text("Painel \(slot+1)").font(.system(size:11)).foregroundStyle(.secondary)}.frame(maxWidth:.infinity,maxHeight:.infinity).background(panel.opacity(0.7),in:RoundedRectangle(cornerRadius:8))}
}
struct VideoTile:View{
    @ObservedObject var session:VideoSession
    @EnvironmentObject var state:AppState
    let slot:Int
    var body:some View{
        ZStack{
            RoundedRectangle(cornerRadius:8).fill(.black)
            if let image=session.image{Image(nsImage:image).resizable().aspectRatio(contentMode:.fit)}else{VStack(spacing:12){ProgressView().controlSize(.small);Text(session.status).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()}}
            VStack{HStack{Text(session.camera.name+" · "+session.channel.name).font(.system(size:10,weight:.medium)).lineLimit(1);Spacer();if let job=session.recording{RecordBadge(job:job)}}.padding(9).background(.black.opacity(0.55));Spacer();HStack{Circle().fill(session.active ? accent:Color.orange).frame(width:5,height:5);Text(session.status).font(.system(size:9));Spacer();Button{do{try session.toggleAudio()}catch{state.report(error)}}label:{Image(systemName:session.audioEnabled ? "speaker.wave.2.fill":"speaker.slash")}.buttonStyle(.plain).disabled(!session.active);Button{state.disconnect(slot)}label:{Image(systemName:"xmark")}.buttonStyle(.plain)}.foregroundStyle(.white.opacity(0.7)).padding(8).background(.black.opacity(0.4))}
        }.clipShape(RoundedRectangle(cornerRadius:8))
        .contextMenu{Button("Salvar imagem…"){state.selectedSlot=slot;state.snapshot()};Button("Gravar / finalizar…"){state.selectedSlot=slot;state.record()};Button("Reconectar"){state.selectedSlot=slot;state.reconnect()};Button("Desconectar"){state.disconnect(slot)};Divider();Button("PTZ: esquerda"){move(-0.2,0,0)};Button("PTZ: direita"){move(0.2,0,0)};Button("PTZ: cima"){move(0,0.2,0)};Button("PTZ: baixo"){move(0,-0.2,0)};Button("PTZ: aproximar"){move(0,0,0.2)};Button("PTZ: afastar"){move(0,0,-0.2)}}
    }
    func move(_ x:Double,_ y:Double,_ z:Double){Task{do{try await state.client(session.camera).ptz(token:session.channel.profileToken,x:x,y:y,z:z)}catch{state.report(error)}}}
}
struct RecordBadge:View{@ObservedObject var job:RecordingJob;var body:some View{if job.running{Label("REC",systemImage:"record.circle.fill").font(.system(size:9,weight:.bold)).foregroundStyle(.red)}}}
struct JobRow:View{@ObservedObject var job:RecordingJob;var body:some View{HStack{Image(systemName:job.running ? "record.circle":"film").foregroundStyle(job.running ? .red:accent);VStack(alignment:.leading){Text(job.destination.lastPathComponent).lineLimit(1);Text(job.state).font(.caption).foregroundStyle(.secondary)};Spacer();if job.running{Button("Finalizar"){job.stop()}}else{Button("Mostrar no Finder"){NSWorkspace.shared.activateFileViewerSelecting([job.destination])}}}.padding(10).background(panel,in:RoundedRectangle(cornerRadius:8))}}

struct CameraEditor:View{
    @EnvironmentObject var state:AppState
    @Environment(\.dismiss) var dismiss
    @ViewState var camera:Camera
    @ViewState private var password=""
    @ViewState private var busy=false
    @ViewState private var error:String?
    @ViewState private var channelName="Canal 1"
    @ViewState private var manualURI=""
    var body:some View{
        VStack(alignment:.leading,spacing:18){
            HStack{Image(systemName:"video.badge.plus").foregroundStyle(accent);Text("Equipamento").font(.title2.bold());Spacer();if busy{ProgressView().controlSize(.small)}}
            Form{
                TextField("Nome",text:$camera.name)
                TextField("Endereço IP ou hostname",text:$camera.host)
                HStack{TextField("Porta ONVIF",value:$camera.httpPort,formatter:NumberFormatter());Toggle("HTTPS",isOn:$camera.tls);TextField("Porta RTSP",value:$camera.rtspPort,formatter:NumberFormatter())}
                TextField("Usuário",text:$camera.username)
                SecureField("Senha do equipamento",text:$password)
            }.textFieldStyle(.roundedBorder)
            HStack{Button{query()}label:{Label("Buscar canais ONVIF",systemImage:"arrow.triangle.2.circlepath")}.disabled(busy || camera.host.isEmpty);Text("ONVIF deve estar habilitado no equipamento.").font(.caption).foregroundStyle(.secondary)}
            Divider()
            Text("Canais de vídeo").font(.headline)
            ScrollView{VStack(spacing:6){ForEach(camera.channels){channel in HStack{Image(systemName:"video").foregroundStyle(accent);VStack(alignment:.leading){Text(channel.name);Text(channel.uri).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).lineLimit(1)};Spacer();Button{camera.channels.removeAll{$0.id==channel.id}}label:{Image(systemName:"minus.circle")}.buttonStyle(.plain)}}}}.frame(height:140)
            GroupBox("Adicionar endereço RTSP manual"){
                VStack{HStack{TextField("Nome do canal",text:$channelName).frame(width:140);TextField("rtsp://endereco:554/caminho",text:$manualURI)};HStack{Menu("Preencher caminho comum"){Button("Canal principal /cam/realmonitor"){manualURI="rtsp://\(camera.host):\(camera.rtspPort)/cam/realmonitor?channel=\(camera.channels.count+1)&subtype=0"};Button("Substream /cam/realmonitor"){manualURI="rtsp://\(camera.host):\(camera.rtspPort)/cam/realmonitor?channel=\(camera.channels.count+1)&subtype=1"}};Spacer();Button("Adicionar canal"){addManual()}.disabled(manualURI.isEmpty)}}.padding(5)
            }
            if let error{Text(error).font(.callout).foregroundStyle(.orange).textSelection(.enabled)}
            Text("As senhas ficam no Chaves do macOS. RTSP e ONVIF por HTTP podem trafegar sem criptografia: use uma rede confiável ou VPN.").font(.caption).foregroundStyle(.secondary)
            HStack{Button("Cancelar"){dismiss()}.keyboardShortcut(.cancelAction);Spacer();Button("Salvar equipamento"){do{try state.upsert(camera,password:password);dismiss()}catch{self.error=error.localizedDescription}}.buttonStyle(PrimaryButtonStyle()).disabled(busy).keyboardShortcut(.defaultAction)}
        }.padding(26).frame(width:660).onAppear{do{password=try state.secrets.read(camera.id)}catch{self.error=error.localizedDescription}}
    }
    func addManual(){var updated=camera;updated.channels.append(Channel(name:channelName,uri:manualURI));do{try updated.validate();camera=updated;manualURI="";channelName="Canal \(camera.channels.count+1)";error=nil}catch{self.error=error.localizedDescription}}
    func query(){busy=true;error=nil;Task{do{
        var updated=try await ONVIFClient(camera:camera,password:password).services()
        let channels=try await ONVIFClient(camera:updated,password:password).profiles()
        guard !channels.isEmpty else{throw AppError.message("Nenhum perfil RTSP encontrado. Cadastre manualmente se o equipamento não oferecer Media1.")}
        updated.channels=channels.map{item in var value=item;if let old=camera.channels.first(where:{$0.profileToken==item.profileToken}){value.id=old.id};return value}
        // Retain manually registered channels when refreshing ONVIF profiles.
        updated.channels += camera.channels.filter{$0.profileToken.isEmpty}
        try updated.validate();camera=updated
    }catch{self.error=error.localizedDescription};busy=false}}
}

struct BackupSheet:View{
    @EnvironmentObject var state:AppState
    @Environment(\.dismiss) var dismiss
    @ViewState private var password="";@ViewState private var confirm="";@ViewState private var busy=false;@ViewState private var error:String?
    var body:some View{VStack(alignment:.leading,spacing:18){Label("Backup completo criptografado",systemImage:"lock.shield").font(.title2.bold());Text("Inclui os equipamentos, canais, mosaico e senhas de acesso. A senha abaixo protege o arquivo e não será salva pelo app.").foregroundStyle(.secondary);SecureField("Senha do backup (mínimo 12 caracteres)",text:$password);SecureField("Repetir senha",text:$confirm);Text("Guarde essa senha em um local seguro. Não é possível recuperar o backup sem ela.").font(.caption).foregroundStyle(.orange);if let error{Text(error).foregroundStyle(.orange)};HStack{Button("Cancelar"){dismiss()}.disabled(busy);Spacer();if busy{ProgressView().controlSize(.small)};Button("Salvar backup…"){busy=true;Task{do{try await state.exportBackup(password:password);dismiss()}catch{self.error=error.localizedDescription};busy=false}}.disabled(busy || password.count<12 || password != confirm).buttonStyle(PrimaryButtonStyle())}}.textFieldStyle(.roundedBorder).padding(28).frame(width:520)}
}
struct ImportSheet:View{
    let data:Data
    @EnvironmentObject var state:AppState
    @Environment(\.dismiss) var dismiss
    @ViewState private var password="";@ViewState private var payload:BackupPayload?;@ViewState private var error:String?;@ViewState private var busy=false;@ViewState private var replace=false
    var encrypted:Bool{(try? JSONDecoder().decode(BackupEnvelope.self,from:data)) != nil}
    var body:some View{VStack(alignment:.leading,spacing:18){Label("Importar configuração",systemImage:"square.and.arrow.down").font(.title2.bold())
        if encrypted && payload==nil{Text("Este backup é criptografado. Informe a senha para conferir o conteúdo.");SecureField("Senha do backup",text:$password);Button("Desbloquear"){decode()}.disabled(busy || password.isEmpty)}
        if let payload{Text("\(payload.configuration.cameras.count) equipamentos • \(payload.configuration.cameras.reduce(0){$0+$1.channels.count}) canais • \(payload.passwords.count) senhas").foregroundStyle(accent);ScrollView{VStack(alignment:.leading,spacing:8){ForEach(payload.configuration.cameras){camera in HStack{Image(systemName:"video");Text(camera.name);Spacer();Text("\(camera.channels.count) canais").foregroundStyle(.secondary)}}}}.frame(height:180);Picker("Como importar",selection:$replace){Text("Mesclar com os equipamentos atuais").tag(false);Text("Substituir a configuração atual").tag(true)}.pickerStyle(.radioGroup);Text(replace ? "Os cadastros atuais serão substituídos. Os equipamentos físicos não serão alterados. Faça um backup antes de continuar.":"Equipamentos com o mesmo identificador serão atualizados. Os demais serão adicionados. O mosaico atual será mantido.").font(.caption).foregroundStyle(replace ? .orange:.secondary)}
        if let error{Text(error).foregroundStyle(.orange)}
        HStack{Button("Cancelar"){dismiss()}.disabled(busy);Spacer();if busy{ProgressView().controlSize(.small)};if let payload{Button(replace ? "Substituir configuração":"Mesclar equipamentos"){do{try state.applyImport(payload,replace:replace);dismiss()}catch{self.error=error.localizedDescription}}.buttonStyle(PrimaryButtonStyle(color:replace ? .orange:accent))}}
    }.padding(28).frame(width:570).onAppear{if !encrypted{decode()}}}
    func decode(){busy=true;error=nil;Task{do{let bytes=data;let pass=encrypted ? password:nil;payload=try await Task.detached{try BackupCodec.decode(bytes,password:pass)}.value}catch{self.error=error.localizedDescription};busy=false}}
}

struct RecordingsView:View{
    @EnvironmentObject var state:AppState
    @ViewState private var recordings:[RemoteRecording]=[]
    @ViewState private var selected:String?
    @ViewState private var start=Date().addingTimeInterval(-3600)
    @ViewState private var end=Date()
    @ViewState private var busy=false
    @ViewState private var info="Selecione um equipamento e consulte suas gravações ONVIF."
    var camera:Camera?{state.config.cameras.first{$0.id==state.selectedCamera}}
    var body:some View{VStack(alignment:.leading,spacing:22){Text("Histórico, sob seu controle.").font(.system(size:25,weight:.semibold));Text("Reprodução e exportação de gravações do equipamento via ONVIF Profile G. A disponibilidade depende do suporte do gravador.").font(.callout).foregroundStyle(.secondary)
        HStack{Picker("Equipamento",selection:$state.selectedCamera){Text("Selecione…").tag(nil as UUID?);ForEach(state.config.cameras){Text($0.name).tag(Optional($0.id))}}.frame(maxWidth:400);Button("Consultar gravações"){query()}.disabled(camera==nil || busy);if busy{ProgressView().controlSize(.small)}}
        HStack{DatePicker("Início",selection:$start);DatePicker("Fim",selection:$end)}
        List(recordings,selection:$selected){item in HStack{Image(systemName:"film.stack").foregroundStyle(accent);Text(item.name);Spacer();Text(item.id).font(.caption.monospaced()).foregroundStyle(.secondary)}.tag(item.id)}.clipShape(RoundedRectangle(cornerRadius:10))
        Text(info).font(.callout).foregroundStyle(.secondary)
        HStack{Button("Reproduzir no painel selecionado"){play(export:false)}.disabled(camera==nil || selected==nil || busy);Button("Exportar período para MKV…"){play(export:true)}.disabled(camera==nil || selected==nil || busy || end<=start);Spacer();Button("Abrir arquivo de vídeo local…"){state.openLocalRecording()}}
        if !state.jobs.isEmpty{ScrollView{VStack{ForEach(state.jobs){job in JobRow(job:job)}}}.frame(maxHeight:160)}
    }.padding(28).onChange(of:state.selectedCamera){ recordings=[];selected=nil;info="Consulte as gravações do equipamento selecionado."}}
    func query(){guard let camera else{return};busy=true;Task{do{recordings=try await state.client(camera).recordings();selected=recordings.first?.id;info=recordings.isEmpty ? "Nenhuma gravação foi anunciada pelo equipamento.":"\(recordings.count) fonte(s) de gravação. Escolha uma e informe o período; horários exibidos no fuso deste Mac."}catch{info=error.localizedDescription};busy=false}}
    func play(export:Bool){guard let camera,let selected else{return};guard end>start else{info="O fim precisa ser posterior ao início.";return};busy=true;Task{do{
        let client=try state.client(camera),uri=try await client.replayURI(token:selected)
        let source=MediaInput(uri:try camera.authenticatedURI(uri,password:client.password),replayStart:start)
        if export{let p=NSSavePanel();p.nameFieldStringValue="Vigia-historico-\(AppState.stamp()).mkv";if p.runModal() == .OK,let url=p.url{let job=RecordingJob(destination:url);try job.start(input:source,duration:end.timeIntervalSince(start));state.track(job);info="Exportação iniciada. Aguarde Arquivo salvo antes de fechar."}}
        else{let channel=Channel(name:"Histórico • \(recordings.first{$0.id==selected}?.name ?? selected)",uri:uri);try state.open(camera:camera,channel:channel,source:source,slot:state.selectedSlot);info="Reprodução aberta no painel \(state.selectedSlot+1) da aba Ao vivo."}
    }catch{info=error.localizedDescription};busy=false}}
}

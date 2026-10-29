import Foundation
import AppKit
import AVFoundation
import Combine

struct MediaInput {
    var uri:String
    var replayStart:Date? = nil
    var localFile:Bool = false
    var service:ServiceMediaSource?
    var recordingSource:MediaInput{
        var value=self
        if value.service != nil{value.service?.substream=false}
        return value
    }
    func arguments(realtime:Bool=false)->[String] {
        if service != nil{return ["-f","dhav","-probesize","1048576","-analyzeduration","1000000","-i","pipe:0"]}
        if localFile { return (realtime ? ["-re"]:[])+["-i",uri] }
        var args=["-rtsp_transport","tcp","-timeout","12000000"]
        if let replayStart {
            let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.timeZone=TimeZone(secondsFromGMT:0);formatter.dateFormat="yyyyMMdd'T'HHmmss'Z'"
            args += ["-onvif_start",formatter.string(from:replayStart)]
            if realtime {args += ["-re"]}
        }
        return args+["-i",uri]
    }
}
enum MediaBackend {
    static var executable:URL? {
        let bundled=Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ffmpeg")
        return FileManager.default.isExecutableFile(atPath:bundled.path) ? bundled:nil
    }
    static func process(_ args:[String]) throws -> Process {
        guard let executable else{throw AppError.message("O mecanismo de vídeo não está instalado neste app. Reconstrua o pacote com um FFmpeg compatível com este Mac.")}
        let p=Process();p.executableURL=executable;p.arguments=["-hide_banner","-loglevel","error"]+args
        return p
    }
}
struct PreviewSettings {
    let width:Int
    let fps:Int
    init(quality:String){
        switch quality{
        case "Econômico":width=480;fps=4
        case "Detalhado":width=960;fps=10
        default:width=640;fps=6
        }
    }
    // Do not enlarge a camera's substream: unnecessary resampling and JPEG work.
    var filter:String{"fps=\(fps),scale=w=min(iw\\,\(width)):h=-2"}
}
// This parser is confined to one serial frame queue.
final class JPEGFrames: @unchecked Sendable {
    private var pending=Data()
    func append(_ data:Data)->[Data] {
        pending.append(data)
        var result:[Data]=[]
        let start=Data([0xff,0xd8]),end=Data([0xff,0xd9])
        while let a=pending.range(of:start), let b=pending.range(of:end,in:a.upperBound..<pending.endIndex) {
            result.append(Data(pending[a.lowerBound..<b.upperBound]));pending.removeSubrange(pending.startIndex..<b.upperBound)
        }
        if pending.count>8_000_000 {pending.removeAll(keepingCapacity:false)}
        return result
    }
}
@MainActor final class RecordingJob:ObservableObject,Identifiable {
    let id=UUID()
    @Published var state="Preparando…"
    @Published var running=false
    let destination:URL
    private var process:Process?
    private var input:Pipe?
    private var serviceFeed:ServiceMediaFeed?
    private var serviceError:String?
    init(destination:URL){self.destination=destination}
    func start(input source:MediaInput,duration:Double?=nil) throws {
        var args=["-nostdin","-n"]+source.arguments()
        if let duration {args += ["-t",String(duration)]}
        args += ["-map","0:v:0","-map","0:a?"]
        if destination.pathExtension.lowercased()=="mp4"{
            // Preserve source video quality; convert optional audio to MP4-compatible AAC.
            args += ["-c:v","copy","-c:a","aac","-b:a","128k","-avoid_negative_ts","make_zero","-movflags","+faststart","-f","mp4",destination.path]
        }else{args += ["-c","copy","-avoid_negative_ts","make_zero","-f","matroska",destination.path]}
        // stdin is reserved for FFmpeg's graceful q command; do not disable it.
        if source.service==nil{args.removeAll{$0=="-nostdin"}}
        let p=try MediaBackend.process(args)
        let feed=try source.service.map{try ServiceMediaFeed(source:$0)}
        if let feed{p.standardInput=feed.pipe}else{let pipe=Pipe();input=pipe;p.standardInput=pipe}
        p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        p.terminationHandler={ [weak self] p in DispatchQueue.main.async {
            guard let self else{return};self.running=false
            self.serviceFeed?.stop();self.serviceFeed=nil
            let count=(try? self.destination.resourceValues(forKeys:[.fileSizeKey]).fileSize) ?? 0
            self.state=self.serviceError.map{"Gravação interrompida: "+$0} ?? (p.terminationStatus==0 && count>0 ? "Arquivo salvo" : "Gravação interrompida ou indisponível (\(p.terminationStatus)). Confira o arquivo.")
            self.process=nil;self.input=nil
        }}
        do{try p.run()}catch{feed?.stop();throw error}
        process=p;serviceFeed=feed;running=true;state=duration==nil ? "Gravando":"Exportando gravação…"
        feed?.start{[weak self] message in DispatchQueue.main.async{self?.serviceError=message}}
    }
    func stop() {
        guard let process,process.isRunning else{return}
        state="Finalizando arquivo…"
        if let serviceFeed{serviceFeed.stop()}else{try? input?.fileHandleForWriting.write(contentsOf:Data("q\n".utf8))}
        DispatchQueue.main.asyncAfter(deadline:.now()+5){[weak self] in
            guard let p=self?.process,p.isRunning else{return};p.interrupt()
        }
    }
}
@MainActor final class VideoSession:ObservableObject,Identifiable {
    let id=UUID()
    @Published var image:NSImage?
    @Published var status="Conectando…"
    @Published var active=false
    @Published var recording:RecordingJob?
    @Published var audioEnabled=false
    let camera:Camera
    let channel:Channel
    let source:MediaInput
    private var process:Process?
    private var pipe:Pipe?
    private var generation=UUID()
    private let frameQueue=DispatchQueue(label:"vigia.frames",qos:.userInitiated)
    private var audio:AudioMonitor?
    private var serviceFeed:ServiceMediaFeed?
    private var serviceError:String?
    init(camera:Camera,channel:Channel,source:MediaInput){self.camera=camera;self.channel=channel;self.source=source}
    func start(quality:String,hardware:Bool=true) throws {
        stopVideo()
        let token=UUID();generation=token
        serviceError=nil
        let preview=PreviewSettings(quality:quality)
        var args=["-nostdin"]
        if hardware && source.service==nil{args += ["-hwaccel","videotoolbox"]}
        args += source.arguments(realtime:true)+["-map","0:v:0","-an","-vf",preview.filter,"-threads","2","-c:v","mjpeg","-q:v","5","-f","image2pipe","pipe:1"]
        let p=try MediaBackend.process(args),pipe=Pipe(),frames=JPEGFrames()
        let feed=try source.service.map{try ServiceMediaFeed(source:$0)}
        if let feed{p.standardInput=feed.pipe}
        p.standardOutput=pipe;p.standardError=FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler={ [weak self] handle in
            let chunk=handle.availableData
            if chunk.isEmpty {handle.readabilityHandler=nil;return}
            self?.frameQueue.async { [weak self] in
                // Only display the newest complete frame in each batch.
                guard let data=frames.append(chunk).last,let picture=NSImage(data:data) else{return}
                DispatchQueue.main.async { [weak self] in
                    guard let self,self.generation==token else{return};self.image=picture;self.status=self.source.localFile ? "Arquivo local" : (self.source.replayStart==nil ? "Ao vivo":"Histórico");self.active=true
                }
            }
        }
        p.terminationHandler={ [weak self] process in DispatchQueue.main.async {
            guard let self,self.generation==token else{return}
            self.active=false
            self.serviceFeed?.stop();self.serviceFeed=nil
            if let error=self.serviceError{self.status=error;return}
            if hardware && self.image==nil && self.source.service==nil {
                do {try self.start(quality:quality,hardware:false)} catch {self.status=error.localizedDescription}
            } else {self.status=self.source.localFile ? "Reprodução concluída":"Conexão encerrada. Confira rede, credenciais ou canal e reconecte."}
        }}
        do{try p.run()}catch{feed?.stop();throw error}
        self.process=p;self.pipe=pipe;self.serviceFeed=feed;status=source.replayStart==nil ? "Conectando…":"Buscando gravação…"
        feed?.start{[weak self] message in DispatchQueue.main.async{
            guard let self,self.generation==token else{return};self.serviceError=message;self.status=message;self.active=false
        }}
        Task { [weak self] in
            try? await Task.sleep(nanoseconds:20_000_000_000)
            guard let self,self.generation==token,self.image==nil else{return}
            self.stopVideo();self.status=self.source.service==nil ? "Sem imagem após 20 s. Confira o endereço RTSP, acesso e codec.":"Sem imagem após 20 s. O vídeo de serviço pode usar uma variante ainda não compatível."
        }
    }
    func stopVideo() {
        generation=UUID();pipe?.fileHandleForReading.readabilityHandler=nil
        serviceFeed?.stop();serviceFeed=nil
        if let p=process,p.isRunning {p.terminate()}
        process=nil;pipe=nil;active=false;audio?.stop();audio=nil;audioEnabled=false
    }
    func stop() {stopVideo();recording?.stop();status="Desconectado"}
    func record(to url:URL) throws {
        let job=RecordingJob(destination:url);try job.start(input:source.recordingSource);recording=job
    }
    func snapshot(to url:URL) throws {
        guard let image,let tiff=image.tiffRepresentation,let bitmap=NSBitmapImageRep(data:tiff),let png=bitmap.representation(using:.png,properties:[:]) else{throw AppError.message("Ainda não há imagem neste painel.")}
        try png.write(to:url,options:.atomic)
    }
    func toggleAudio() throws {
        if audioEnabled {audio?.stop();audio=nil;audioEnabled=false;return}
        let monitor=AudioMonitor();try monitor.start(source:source);audio=monitor;audioEnabled=true
    }
}
final class AudioMonitor {
    private let engine=AVAudioEngine()
    private let node=AVAudioPlayerNode()
    private var process:Process?
    private var pipe:Pipe?
    private var serviceFeed:ServiceMediaFeed?
    private let queue=DispatchQueue(label:"vigia.audio")
    private var pending=Data()
    private let lock=NSLock()
    private var scheduled=0
    func start(source:MediaInput) throws {
        let format=AVAudioFormat(standardFormatWithSampleRate:48000,channels:2)!
        engine.attach(node);engine.connect(node,to:engine.mainMixerNode,format:format)
        try engine.start();node.play()
        let p=try MediaBackend.process(["-nostdin"]+source.arguments(realtime:true)+["-vn","-ac","2","-ar","48000","-c:a","pcm_s16le","-f","s16le","pipe:1"])
        let pipe=Pipe();p.standardOutput=pipe;p.standardError=FileHandle.nullDevice
        let feed=try source.service.map{try ServiceMediaFeed(source:$0)}
        if let feed{p.standardInput=feed.pipe}
        pipe.fileHandleForReading.readabilityHandler={ [weak self] handle in
            let data=handle.availableData;if data.isEmpty {handle.readabilityHandler=nil;return}
            self?.queue.async { [weak self] in
                guard let self else{return};self.pending.append(data)
                let bytes=19200
                while self.pending.count>=bytes {
                    let chunk=Data(self.pending.prefix(bytes));self.pending.removeFirst(bytes)
                    self.lock.lock();let full=self.scheduled>=10;if !full{self.scheduled+=1};self.lock.unlock()
                    if full{continue}
                    let buffer=AVAudioPCMBuffer(pcmFormat:format,frameCapacity:4800)!;buffer.frameLength=4800
                    chunk.withUnsafeBytes{raw in
                        let samples=raw.bindMemory(to:Int16.self)
                        for frame in 0..<4800 {
                            buffer.floatChannelData![0][frame]=Float(Int16(littleEndian:samples[frame*2]))/32768
                            buffer.floatChannelData![1][frame]=Float(Int16(littleEndian:samples[frame*2+1]))/32768
                        }
                    }
                    self.node.scheduleBuffer(buffer,completionHandler:{ [weak self] in guard let self else{return};self.lock.lock();self.scheduled-=1;self.lock.unlock() })
                }
            }
        }
        do{try p.run()}catch{feed?.stop();throw error}
        self.process=p;self.pipe=pipe;serviceFeed=feed
        feed?.start{[weak self] _ in DispatchQueue.main.async{self?.stop()}}
    }
    func stop(){pipe?.fileHandleForReading.readabilityHandler=nil;serviceFeed?.stop();serviceFeed=nil;if let p=process,p.isRunning{p.terminate()};node.stop();engine.stop();process=nil;pipe=nil}
    deinit{stop()}
}

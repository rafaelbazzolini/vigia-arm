import Foundation
import Darwin

struct ServiceMediaSource {
    var host: String
    var port: Int
    var username: String
    var password: String
    var channel: Int
    var substream: Bool
}

// These are wire-format messages, not a port of a vendor SDK. Legacy video is
// experimental: authenticated control socket + session-bound media socket.
enum ServiceVideoWire {
    static let limit = 8_388_608
    static func bind(session: UInt32, channel: Int) throws -> Data {
        guard (0..<255).contains(channel), session != 0 else { throw ServiceWire.invalid }
        var header = Data(repeating:0,count:32);header[0]=0xf1
        ServiceWire.put(session,into:&header,at:8)
        header[12]=1;header[13]=UInt8(channel+1)
        return header
    }
    static func start(channel:Int,substream:Bool)throws->Data {
        guard (0..<255).contains(channel) else { throw ServiceWire.invalid }
        var header=Data(repeating:0,count:32);header[0]=0x11
        let body:Data
        if channel<16 {
            header[8+channel]=1
            var streams=Data(repeating:0,count:16);streams[channel]=substream ? 1:0;body=streams
        }else{
            header[26]=8
            body=Data("ChannelName:\(channel)\r\nStream:\(substream ? 1:0)\r\nOperate:1\r\nProtocol:tcp\r\n\r\n".utf8)
        }
        ServiceWire.put(UInt32(body.count),into:&header,at:4)
        return header+body
    }
    static func packet(_ transport:ServiceTransport)throws->(command:UInt8,header:Data,body:Data){
        let header=try transport.readExactly(32)
        guard header.count==32 else{throw ServiceWire.invalid}
        let size=Int(ServiceWire.word(header,4))
        guard size<=limit else{throw ServiceWire.invalid}
        // Read in bounded chunks; ServiceTCP limits each individual read to 1MB.
        var body=Data()
        while body.count<size{body.append(try transport.readExactly(min(65536,size-body.count)))}
        return (header[0],header,body)
    }
    static func frame(_ transport:ServiceTransport)throws->Data{
        for _ in 0..<8 {
            let packet=try packet(transport)
            if packet.command==0xbc {
                guard packet.header[16]==0,!packet.body.isEmpty else{throw AppError.message("O gravador recusou o canal de vídeo de serviço.")}
                return packet.body
            }
            // Some firmware acknowledges media binding, others do not.
            guard packet.command==0xf1 || packet.command==0xb1 else{throw ServiceWire.invalid}
        }
        throw ServiceWire.invalid
    }
    static func keepAlive(_ control:ServiceTransport)throws{
        var header=Data(repeating:0,count:32);header[0]=0xa1
        control.refreshDeadline();try control.write(header)
        for _ in 0..<16 {
            let response=try packet(control)
            if response.command==0xb1{return}
            // Start acknowledgements and status notifications may precede it.
            guard [UInt8(0x12),0xbc,0xf6].contains(response.command) else{throw ServiceWire.invalid}
        }
        throw ServiceWire.invalid
    }
}

// One bounded producer per media consumer. Closing stops both TCP sockets and
// signals EOF to FFmpeg, so recordings can finish their container normally.
final class ServiceMediaFeed {
    let pipe=Pipe()
    private let source:ServiceMediaSource
    private let lock=NSLock()
    private var stopped=false
    private var connections:[ServiceTransport]=[]
    private var launched=false
    init(source:ServiceMediaSource)throws{
        self.source=source
        let fd=pipe.fileHandleForWriting.fileDescriptor
        guard fcntl(fd,F_SETNOSIGPIPE,1) != -1,
              fcntl(fd,F_SETFL,fcntl(fd,F_GETFL)|O_NONBLOCK) != -1 else{
            throw AppError.message("Não foi possível preparar o transporte local de vídeo.")
        }
    }
    private var cancelled:Bool{lock.lock();defer{lock.unlock()};return stopped}
    private func register(_ transport:ServiceTransport)throws{
        lock.lock();defer{lock.unlock()}
        if stopped{transport.close();throw CancellationError()}
        connections.append(transport)
    }
    func start(onError:@escaping(String)->Void){
        lock.lock();guard !launched else{lock.unlock();return};launched=true;lock.unlock()
        try? pipe.fileHandleForReading.close()
        DispatchQueue.global(qos:.userInitiated).async{[self] in
            defer{
                stop()
                try? pipe.fileHandleForWriting.close()
            }
            do{
                let control=try ServiceTCP(host:source.host,port:source.port)
                try register(control)
                let session=try ServiceClient(transport:control).authenticate(username:source.username,password:source.password)
                defer{
                    var logout=Data(repeating:0,count:32);logout[0]=0x0a
                    ServiceWire.put(session,into:&logout,at:8)
                    try? control.write(logout)
                }
                let data=try ServiceTCP(host:source.host,port:source.port)
                try register(data)
                try data.write(ServiceVideoWire.bind(session:session,channel:source.channel))
                try control.write(ServiceVideoWire.start(channel:source.channel,substream:source.substream))
                var keepAlive=Date()
                while !cancelled{
                    data.refreshDeadline()
                    let frame=try ServiceVideoWire.frame(data)
                    try write(frame)
                    if Date().timeIntervalSince(keepAlive)>=10{
                        try ServiceVideoWire.keepAlive(control);keepAlive=Date()
                    }
                }
            }catch is CancellationError{}catch{if !cancelled{onError(error.localizedDescription)}}
        }
    }
    private func write(_ bytes:Data)throws{
        let fd=pipe.fileHandleForWriting.fileDescriptor
        try bytes.withUnsafeBytes{raw in
            var sent=0
            var lastProgress=Date()
            while sent<raw.count{
                if cancelled{throw CancellationError()}
                let count=Darwin.write(fd,raw.baseAddress!.advanced(by:sent),raw.count-sent)
                if count>0{sent+=count;lastProgress=Date();continue}
                if count<0 && errno==EINTR{continue}
                if count<0 && errno==EPIPE{throw CancellationError()}
                guard count<0,(errno==EAGAIN || errno==EWOULDBLOCK),Date().timeIntervalSince(lastProgress)<5 else{
                    throw AppError.message("O decodificador encerrou ou deixou de consumir o vídeo de serviço.")
                }
                var descriptor=pollfd(fd:fd,events:Int16(POLLOUT),revents:0)
                _=poll(&descriptor,1,100)
            }
        }
    }
    func stop(){
        lock.lock();stopped=true;let active=connections;connections=[];let started=launched;lock.unlock()
        for connection in active{connection.close()}
        if !started{try? pipe.fileHandleForWriting.close();try? pipe.fileHandleForReading.close()}
    }
    deinit{stop()}
}

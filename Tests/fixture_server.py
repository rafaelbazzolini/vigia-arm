#!/usr/bin/env python3
"""Local-only ONVIF/RTSP fixture. Needs a synthetic MPEG-4 test file, never real camera data."""
import argparse,base64,json,re,socket,socketserver,struct,threading,time
from http.server import BaseHTTPRequestHandler,ThreadingHTTPServer
from pathlib import Path

parser=argparse.ArgumentParser()
parser.add_argument('--video',type=Path,required=True)
parser.add_argument('--events',type=Path,required=True)
args=parser.parse_args()
raw=args.video.read_bytes()
start=raw.index(b'\x00\x00\x01\xb6')
config=raw[:start]
frames=[b'\x00\x00\x01\xb6'+part for part in raw[start:].split(b'\x00\x00\x01\xb6')[1:]]
events={'soapOperations':[],'rtspPlayCount':0,'replayClockRangeObserved':False,'ptzStopObserved':False}
lock=threading.Lock()
def save():
    with lock:args.events.write_text(json.dumps(events,indent=2))
class SOAP(BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_POST(self):
        body=self.rfile.read(int(self.headers.get('Content-Length',0))).decode()
        operation=re.search(r'<t:(\w+)>',body).group(1)
        events['soapOperations'].append(operation)
        response=''
        if operation=='GetServices':
            for name,namespace in [('media','http://www.onvif.org/ver10/media/wsdl'),('ptz','http://www.onvif.org/ver20/ptz/wsdl'),('recording','http://www.onvif.org/ver10/recording/wsdl'),('replay','http://www.onvif.org/ver10/replay/wsdl')]:
                response+=f'<t:Service><t:Namespace>{namespace}</t:Namespace><t:XAddr>http://127.0.0.1:18780/{name}</t:XAddr></t:Service>'
        elif operation=='GetProfiles':
            response='<t:Profiles token="main"><tt:Name>Teste principal</tt:Name></t:Profiles><t:Profiles token="sub"><tt:Name>Teste secundário</tt:Name></t:Profiles>'
        elif operation=='GetStreamUri':response='<t:MediaUri><tt:Uri>rtsp://127.0.0.1:18554/live</tt:Uri></t:MediaUri>'
        elif operation=='GetRecordings':response='<t:RecordingItem><tt:RecordingToken>record1</tt:RecordingToken><tt:Configuration><tt:Source><tt:Name>Histórico de teste</tt:Name></tt:Source></tt:Configuration></t:RecordingItem>'
        elif operation=='GetReplayUri':response='<t:Uri>rtsp://127.0.0.1:18554/replay</t:Uri>'
        elif operation=='Stop':events['ptzStopObserved']=True
        namespace={'ptz':'http://www.onvif.org/ver20/ptz/wsdl','recording':'http://www.onvif.org/ver10/recording/wsdl','replay':'http://www.onvif.org/ver10/replay/wsdl','media':'http://www.onvif.org/ver10/media/wsdl'}.get(self.path.strip('/'),'http://www.onvif.org/ver10/device/wsdl')
        xml=f'<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:t="{namespace}" xmlns:tt="http://www.onvif.org/ver10/schema"><s:Body><t:{operation}Response>{response}</t:{operation}Response></s:Body></s:Envelope>'.encode()
        self.send_response(200);self.send_header('Content-Type','application/soap+xml');self.send_header('Content-Length',str(len(xml)));self.end_headers();self.wfile.write(xml);save()
class RTSP(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.settimeout(40);pending=b'';playing=False;seq=0;timestamp=0;sendlock=threading.Lock();stopped=threading.Event()
        def respond(cseq,extra='',data=b''):
            with sendlock:self.request.sendall(f'RTSP/1.0 200 OK\r\nCSeq: {cseq}\r\nSession: vigiafixture\r\n{extra}Content-Length: {len(data)}\r\n\r\n'.encode()+data)
        def stream():
            nonlocal seq,timestamp
            try:
                while not stopped.is_set():
                    for frame in frames:
                        if stopped.is_set():return
                        chunks=[frame[i:i+1200] for i in range(0,len(frame),1200)]
                        for i,chunk in enumerate(chunks):
                            marker=128 if i==len(chunks)-1 else 0
                            packet=struct.pack('!BBHII',0x80,96|marker,seq%65536,timestamp%2**32,12345)+chunk;seq+=1
                            with sendlock:self.request.sendall(b'$\x00'+struct.pack('!H',len(packet))+packet)
                        timestamp+=9000;time.sleep(0.1)
            except (OSError,BrokenPipeError):pass
        try:
            while True:
                chunk=self.request.recv(65536)
                if not chunk:break
                pending+=chunk
                # Skip client RTCP interleaved packets.
                while pending.startswith(b'$') and len(pending)>=4:
                    length=int.from_bytes(pending[2:4],'big')+4
                    if len(pending)<length:break
                    pending=pending[length:]
                while b'\r\n\r\n' in pending:
                    header,pending=pending.split(b'\r\n\r\n',1);text=header.decode(errors='replace');line=text.splitlines()[0]
                    method=line.split()[0];cseq=re.search(r'CSeq:\s*(\d+)',text,re.I).group(1)
                    if method=='OPTIONS':respond(cseq,'Public: OPTIONS, DESCRIBE, SETUP, PLAY, TEARDOWN, GET_PARAMETER\r\n')
                    elif method=='DESCRIBE':
                        profile="1"
                        sdp=f'v=0\r\no=- 0 0 IN IP4 127.0.0.1\r\ns=Vigia test fixture\r\nc=IN IP4 127.0.0.1\r\nt=0 0\r\na=control:*\r\nm=video 0 RTP/AVP 96\r\na=rtpmap:96 MP4V-ES/90000\r\na=fmtp:96 profile-level-id=1;config={config.hex()}\r\na=control:trackID=0\r\n'.encode()
                        respond(cseq,'Content-Type: application/sdp\r\nContent-Base: rtsp://127.0.0.1:18554/live/\r\n',sdp)
                    elif method=='SETUP':respond(cseq,'Transport: RTP/AVP/TCP;unicast;interleaved=0-1\r\n')
                    elif method=='PLAY':
                        events['rtspPlayCount']+=1
                        if 'Range: clock=' in text and 'Require: onvif-replay' in text:events['replayClockRangeObserved']=True
                        save();respond(cseq,'RTP-Info: url=rtsp://127.0.0.1:18554/live/trackID=0;seq=0;rtptime=0\r\n')
                        if not playing:playing=True;threading.Thread(target=stream,daemon=True).start()
                    elif method=='TEARDOWN':stopped.set();respond(cseq);return
                    else:respond(cseq)
        except (OSError,AttributeError,IndexError):pass
        finally:stopped.set()
class Server(socketserver.ThreadingTCPServer):allow_reuse_address=True;daemon_threads=True
threading.Thread(target=ThreadingHTTPServer(('127.0.0.1',18780),SOAP).serve_forever,daemon=True).start()
save();print('Local ONVIF fixture :18780 and RTSP fixture :18554 ready',flush=True)
Server(('127.0.0.1',18554),RTSP).serve_forever()

"""Legacy DVRIP fixture. Synthetic credentials; listens only on loopback."""
import hashlib
import json
import socket
import socketserver
import struct
import time
import argparse
import threading
from pathlib import Path

sessions = {}
session_lock = threading.Lock()
next_session = 42
test_jpeg = None


def exact(sock, count):
    result = b''
    while len(result) < count:
        chunk = sock.recv(count - len(result))
        if not chunk:
            raise EOFError('Truncated fixture request')
        result += chunk
    return result


def word(buf, offset):
    return struct.unpack_from('<I', buf, offset)[0]


def frame(body, request_id=1, total=None, session=42):
    return struct.pack('<8I', 0xf6, len(body), request_id, 0,
                       len(body) if total is None else total, 0, session, 0) + body


def dhav_image(jpeg, index):
    extension = bytes([0x81, 0, 3, 10, 0x82, 0, 0, 0]) + struct.pack('<HH', 640, 360)
    size = 24 + len(extension) + len(jpeg) + 8
    seconds = index // 10
    date = (26 << 26) | (10 << 22) | (29 << 17) | (12 << 12) | ((seconds // 60) << 6) | (seconds % 60)
    header = b'DHAV' + bytes([0xfd, 0, 0, 0]) + struct.pack('<IIIHBB', index, size, date, (index * 100) % 65536, len(extension), 0)
    return header + extension + jpeg + b'dhav' + struct.pack('<I', size)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        global next_session
        sock = self.request
        sock.settimeout(20)
        session = None
        try:
            challenge = exact(sock, 32)
            if challenge[0] == 0xf1:
                self.media(sock, challenge)
                return
            assert challenge == bytes.fromhex('a0010000' + '00' * 20 + '050201010000a1aa')
            payload = b'Realm:Login to TEST-DEVICE\r\nRandom:123456789\r\n'
            head = bytearray(32)
            head[0:2] = b'\xb0\x01'
            struct.pack_into('<I', head, 4, len(payload))
            # Split within the binary length field and within the payload.
            for part in [head[:5], head[5:], payload[:9], payload[9:]]:
                sock.sendall(part)
            head = exact(sock, 32)
            assert head[:4] == b'\xa0\x05\0\0'
            size = word(head, 4)
            assert 0 < size <= 4096
            login = exact(sock, size).decode('latin1')
            if login.startswith('timeout-fixture&&'):
                # Wait for the client's deadline to close, rather than sleeping.
                assert sock.recv(1) == b''
                return
            h = lambda s: hashlib.md5(s.encode('latin1')).hexdigest().upper()
            d = hashlib.md5(b'fixture-password').digest()
            alphabet = '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
            compressed = ''.join(alphabet[(d[i] + d[i+1]) % 62] for i in range(0, 16, 2))
            expected = ('operator&&' + h('operator:123456789:' + h('operator:Login to TEST-DEVICE:fixture-password'))
                        + h('operator:123456789:' + compressed))
            head = bytearray(32); head[0] = 0xb0
            if login != expected:
                head[8] = 1; sock.sendall(head)
                assert sock.recv(1) == b'', 'Client retried authentication'
                return
            with session_lock:
                session = next_session; next_session += 1
                sessions[session] = {'start': threading.Event(), 'stop': threading.Event()}
            head[9] = 8; struct.pack_into('<I', head, 16, session)
            sock.sendall(head)
            head = exact(sock, 32)
            if head[0] == 0x11:
                assert word(head, 4) == 16 and head[8] == 1
                assert exact(sock, 16) == bytes([1]) + bytes(15)
                sessions[session]['start'].set()
                while True:
                    head = exact(sock, 32)
                    if head[0] == 0x0a:
                        return
                    assert head[0] == 0xa1, 'Unexpected control command'
                    response = bytearray(32); response[0] = 0xb1; sock.sendall(response)
            assert head[0] == 0xf6 and word(head, 24) == session
            size = word(head, 4); assert 0 < size <= 4096
            query = json.loads(exact(sock, size))
            assert query == {'method': 'configManager.getConfig', 'params': {'name': 'ChannelTitle'}, 'id': 1, 'session': session}
            body = json.dumps({'id': 1, 'session': session, 'result': True,
                               'params': {'table': [{'Name': 'Entrada TCP'}, {'Name': 'Garagem TCP'}]}}).encode()
            sock.sendall(frame(body[:19], total=len(body),session=session) + frame(body[19:], total=len(body),session=session))
            head = exact(sock, 32)
            size = word(head, 4); assert 0 < size <= 4096
            assert json.loads(exact(sock, size))['method'] == 'global.logout'
        except (EOFError, ConnectionError, socket.timeout):
            return
        finally:
            if session is not None:
                with session_lock:
                    state = sessions.pop(session, None)
                    if state:
                        state['stop'].set()

    def media(self, sock, header):
        assert test_jpeg is not None, 'Video fixture requires --jpeg'
        session = word(header, 8)
        with session_lock:
            state = sessions.get(session)
        assert state is not None and header[12:14] == bytes([1, 1])
        assert state['start'].wait(3), 'Control stream never requested'
        response = bytearray(32); response[0] = 0xf1; sock.sendall(response)
        for index in range(300):
            if state['stop'].is_set():
                break
            data = dhav_image(test_jpeg, index)
            response = bytearray(32); response[0] = 0xbc
            struct.pack_into('<I', response, 4, len(data))
            sock.sendall(response[:5]); sock.sendall(response[5:] + data)
            state['stop'].wait(0.1)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--jpeg', type=Path)
    args = parser.parse_args()
    if args.jpeg:
        test_jpeg = args.jpeg.read_bytes()
    with socketserver.ThreadingTCPServer(('127.0.0.1', 0), Handler) as server:
        server.daemon_threads = True
        print(server.server_address[1], flush=True)
        server.serve_forever()

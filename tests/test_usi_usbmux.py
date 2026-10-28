import contextlib
import os
import plistlib
import socket
import struct
import tempfile
import threading
import unittest

try:
    from usi_stream import usbmux as u
except ImportError:
    u=None


def read_exact(sock, size):
    value=b''
    while len(value)<size:
        block=sock.recv(size-len(value))
        if not block: raise EOFError('fake server received EOF')
        value+=block
    return value


def request(sock):
    length,version,kind,tag=struct.unpack('<IIII',read_exact(sock,16))
    return (length,version,kind,tag),plistlib.loads(read_exact(sock,length-16))


def reply(sock, value, tag, fragmented=False):
    body=plistlib.dumps(value)
    wire=struct.pack('<IIII',16+len(body),1,8,tag)+body
    if fragmented:
        for offset in range(0,len(wire),7):sock.sendall(wire[offset:offset+7])
    else:sock.sendall(wire)


@contextlib.contextmanager
def daemon(handler):
    errors=[]
    with tempfile.TemporaryDirectory() as directory:
        path=os.path.join(directory,'usbmuxd')
        listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM)
        listener.bind(path);listener.listen(1);listener.settimeout(2)
        def serve():
            try:
                conn,_=listener.accept()
                with conn:
                    conn.settimeout(2);handler(conn)
            except BaseException as exc:errors.append(exc)
        thread=threading.Thread(target=serve);thread.start()
        try:yield path
        finally:
            listener.close();thread.join(3)
            if thread.is_alive():raise AssertionError('fake daemon did not terminate')
            if errors:raise errors[0]


class Availability(unittest.TestCase):
    def test_usbmux_is_available(self):self.assertIsNotNone(u,'usbmux connector missing')


@unittest.skipIf(u is None,'not implemented')
class USBMuxTests(unittest.TestCase):
    def test_list_devices_connect_and_preserve_stream_bytes(self):
        seen=[]
        def server(conn):
            head,meta=request(conn);seen.append((head,meta))
            reply(conn,{'DeviceList':[
                {'DeviceID':2,'Properties':{'ConnectionType':'Network','SerialNumber':'do-not-log'}},
                {'DeviceID':7,'Properties':{'ConnectionType':'USB','SerialNumber':'secret'}}]},head[3],True)
            head,meta=request(conn);seen.append((head,meta))
            reply(conn,{'MessageType':'Result','Number':0},head[3],True)
            conn.sendall(b'USI2')
        with daemon(server) as path:
            with u.connect_usb(socket_path=path,timeout=1) as conn:
                self.assertEqual(read_exact(conn,4),b'USI2')
                self.assertIsNone(conn.gettimeout())
        self.assertEqual(seen[0][0][1:3],(1,8))
        self.assertEqual(seen[0][1]['MessageType'],'ListDevices')
        self.assertEqual(seen[1][1]['DeviceID'],7)
        self.assertEqual(seen[1][1]['PortNumber'],socket.htons(5558))
        self.assertEqual(seen[1][1]['MessageType'],'Connect')
        self.assertNotEqual(seen[0][0][3],seen[1][0][3])
        self.assertNotIn('SerialNumber',seen[1][1])

    def test_no_usb_device(self):
        def server(conn):
            head,_=request(conn)
            reply(conn,{'DeviceList':[{'DeviceID':1,'Properties':{'ConnectionType':'Network'}}]},head[3])
            self.assertEqual(conn.recv(1),b'')
        with daemon(server) as path,self.assertRaises(u.NoDeviceError):u.connect_usb(socket_path=path)

    def test_rejected_connect_is_sanitized(self):
        def server(conn):
            head,_=request(conn)
            reply(conn,{'DeviceList':[{'DeviceID':1,'Properties':{'ConnectionType':'USB'}}]},head[3])
            head,_=request(conn)
            reply(conn,{'MessageType':'Result','Number':3,'SerialNumber':'secret-udid'},head[3])
        with daemon(server) as path,self.assertRaises(u.USBMuxError) as caught:u.connect_usb(socket_path=path)
        self.assertNotIn('secret',str(caught.exception))

    def test_bounded_header_validation_before_body(self):
        for length,version,kind,tag in [(15,1,8,1),(1048577,1,8,1),(16,0,8,1),
                                      (16,1,7,1),(16,1,8,999)]:
            def server(conn):
                request(conn);conn.sendall(struct.pack('<IIII',length,version,kind,tag))
                self.assertEqual(conn.recv(1),b'')
            with self.subTest(length=length,version=version,kind=kind,tag=tag):
                with daemon(server) as path,self.assertRaises(u.USBMuxError):u.connect_usb(socket_path=path)

    def test_bad_plist_and_invalid_device_list(self):
        for body in [b'bad',plistlib.dumps([]),plistlib.dumps({'DeviceList':'wrong'}),
                     plistlib.dumps({'DeviceList':[{'DeviceID':True,'Properties':{'ConnectionType':'USB'}}]})]:
            def server(conn):
                head,_=request(conn)
                conn.sendall(struct.pack('<IIII',16+len(body),1,8,head[3])+body)
            with self.subTest(body=body):
                with daemon(server) as path,self.assertRaises(u.USBMuxError):u.connect_usb(socket_path=path)

    def test_timeout_and_eof_are_bounded_and_sanitized(self):
        release=threading.Event()
        def server(conn):
            request(conn);release.wait(0.15)
        with daemon(server) as path:
            try:
                with self.assertRaises(u.USBMuxError):u.connect_usb(socket_path=path,timeout=0.01)
            finally:release.set()
        def truncated(conn):request(conn);conn.sendall(b'\x10\x00')
        with daemon(truncated) as path,self.assertRaises(u.USBMuxError):u.connect_usb(socket_path=path)

    def test_invalid_port_does_not_open_socket(self):
        for port in [True,0,-1,65536,'5558']:
            with self.subTest(port=port),self.assertRaises(ValueError):u.connect_usb(port,socket_path='/not-real')

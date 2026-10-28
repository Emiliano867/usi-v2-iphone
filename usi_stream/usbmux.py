"""Direct, bounded plist usbmuxd transport. No phone identifiers are logged.

Wire reference: libimobiledevice/libusbmuxd src/libusbmuxd.c. The daemon
transaction envelope is little endian; Connect's PortNumber is htons(port).
"""
import math
import plistlib
import socket
import struct

HEADER = struct.Struct('<IIII')
MAX_REPLY = 1_048_576
SOCKET_PATH = '/var/run/usbmuxd'


class USBMuxError(OSError):
    """A sanitized local usbmuxd transport failure."""


class NoDeviceError(USBMuxError):
    """No USB-connected device is currently available."""


def _read(sock, count):
    data = bytearray()
    while len(data) < count:
        block = sock.recv(min(count - len(data), 65_536))
        if not block:
            raise USBMuxError('usbmuxd closed an incomplete reply')
        data.extend(block)
    return bytes(data)


def _request(sock, metadata, tag):
    body = plistlib.dumps(metadata, fmt=plistlib.FMT_XML)
    sock.sendall(HEADER.pack(HEADER.size + len(body), 1, 8, tag) + body)
    length, version, kind, reply_tag = HEADER.unpack(_read(sock, HEADER.size))
    if not HEADER.size <= length <= MAX_REPLY:
        raise USBMuxError('usbmuxd reply length out of bounds')
    if (version, kind, reply_tag) != (1, 8, tag):
        raise USBMuxError('invalid usbmuxd reply envelope')
    try:
        reply = plistlib.loads(_read(sock, length - HEADER.size))
    except (ValueError, TypeError, OverflowError, RecursionError) as exc:
        raise USBMuxError('invalid usbmuxd plist reply') from exc
    if not isinstance(reply, dict):
        raise USBMuxError('usbmuxd reply must be a dictionary')
    return reply


def _usb_device(reply):
    devices = reply.get('DeviceList')
    if not isinstance(devices, list):
        raise USBMuxError('invalid usbmuxd device list')
    identifiers = []
    for device in devices:
        if not isinstance(device, dict) or not isinstance(device.get('Properties'), dict):
            raise USBMuxError('invalid usbmuxd device entry')
        device_id = device.get('DeviceID')
        if type(device_id) is not int or not 0 <= device_id <= 0xffffffff:
            raise USBMuxError('invalid ephemeral device number')
        if device['Properties'].get('ConnectionType') == 'USB':
            identifiers.append(device_id)
    if not identifiers:
        raise NoDeviceError('no USB-connected phone available')
    return min(identifiers)


def connect_usb(port=5558, *, socket_path=SOCKET_PATH, timeout=3.0):
    """Connect to the first USB phone's port through the local daemon.

    ListDevices and Connect share one AF_UNIX connection. On successful Connect,
    that socket becomes the raw USI stream and is returned in blocking mode.
    Callers own it and must close it. No pairing, camera, or GUI action occurs.
    """
    if type(port) is not int or not 1 <= port <= 65535:
        raise ValueError('port must be an integer in 1..65535')
    if type(timeout) not in (float, int) or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('timeout must be positive and finite')
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        sock.connect(socket_path)
        common = {'ClientVersionString': 'USI Stream 1', 'ProgName': 'usi_stream',
                  'kLibUSBMuxVersion': 3}
        devices = _request(sock, dict(common, MessageType='ListDevices'), 1)
        device_id = _usb_device(devices)
        reply = _request(sock, dict(common, MessageType='Connect', DeviceID=device_id,
                                    PortNumber=socket.htons(port)), 2)
        if reply.get('MessageType') != 'Result' or type(reply.get('Number')) is not int:
            raise USBMuxError('invalid usbmuxd Connect result')
        if reply['Number'] != 0:
            raise USBMuxError('usbmuxd refused the phone port')
        sock.settimeout(None)
        return sock
    except USBMuxError:
        sock.close()
        raise
    except OSError as exc:
        sock.close()
        # Daemon/device contents and identifiers never enter user-facing errors.
        raise USBMuxError('usbmuxd connection failed or timed out') from exc
    except BaseException:
        sock.close()
        raise

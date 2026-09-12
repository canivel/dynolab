"""LAN-only DNS-SD. Advertisements are hints, never authentication."""
import ipaddress
import json
import socket
import sys
import threading
import time
import uuid

from .runtime import LLAMA_REVISION, lan_interfaces, private_ip
from .worker import run_hidden

SERVICE = '_dynoworker._tcp.local.'
PAIR_PORT = 50053


def local_interfaces():
    if sys.platform != 'win32':
        return lan_interfaces()
    script = """
$items = @(Get-NetIPAddress -AddressFamily IPv4 | ForEach-Object {
    $ip = $_
    $profile = Get-NetConnectionProfile -InterfaceIndex $ip.InterfaceIndex -ErrorAction SilentlyContinue
    if ($profile.NetworkCategory -eq 'Private' -and $ip.AddressState -eq 'Preferred') {
        @{address=$ip.IPAddress; prefix=[int]$ip.PrefixLength; interface=$ip.InterfaceAlias}
    }
})
ConvertTo-Json -InputObject $items -Compress
"""
    result = run_hidden(['powershell.exe', '-NoProfile', '-Command', script],
                        capture_output=True, text=True, timeout=15)
    if result.returncode:
        raise ValueError('Could not read Private LAN interfaces')
    entries = json.loads(result.stdout or '[]')
    output = []
    for item in entries:
        try:
            address = str(private_ip(item['address']))
            network = ipaddress.IPv4Network((address, item['prefix']), strict=False)
            output.append(dict(address=address, network=str(network), interface=item['interface']))
        except ValueError:
            continue
    return output


def peer_on_lan(peer, interface):
    try:
        address = private_ip(peer)
        network = ipaddress.IPv4Network(interface['network'])
        return address in network and address not in (
            network.network_address, network.broadcast_address,
            ipaddress.IPv4Address(interface['address']))
    except (ValueError, KeyError):
        return False


def safe_label(value, limit=80):
    return ''.join(c for c in str(value) if c.isprintable())[:limit]


class Advertisement:
    def __init__(self, interface, label, gpu, port=PAIR_PORT):
        from zeroconf import IPVersion, ServiceInfo, Zeroconf
        self.zc = Zeroconf(interfaces=[interface['address']], ip_version=IPVersion.V4Only)
        ident = uuid.uuid4().hex
        self.info = ServiceInfo(SERVICE, f'{ident}.{SERVICE}',
            addresses=[socket.inet_aton(interface['address'])], port=port,
            server=f'dyno-{ident}.local.', properties={
                'v': '1', 'name': safe_label(label), 'gpu': safe_label(gpu),
                'revision': LLAMA_REVISION}, host_ttl=30, other_ttl=30)
        try:
            self.zc.register_service(self.info)
        except Exception:
            self.zc.close()
            raise

    def close(self):
        self.zc.unregister_service(self.info)
        self.zc.close()


def discover(interfaces, seconds=3):
    from zeroconf import IPVersion, ServiceBrowser, Zeroconf
    if not interfaces:
        raise ValueError('No private LAN interface is available')
    found, lock = {}, threading.Lock()

    class Listener:
        def add_service(self, zc, type_, name):
            info = zc.get_service_info(type_, name, timeout=1000)
            if not info or not 1 <= info.port <= 65535:
                return
            props = {k.decode('utf-8', 'replace'): v.decode('utf-8', 'replace')
                     for k, v in info.properties.items() if isinstance(v, bytes)}
            if props.get('v') != '1' or props.get('revision') != LLAMA_REVISION:
                return
            for address in info.parsed_addresses():
                interface = next((i for i in interfaces if peer_on_lan(address, i)), None)
                if interface:
                    with lock:
                        if name not in found and len(found) >= 128:
                            return
                        found[name] = dict(name=safe_label(props.get('name', 'Dyno worker')),
                            gpu=safe_label(props.get('gpu', 'GPU')), address=address,
                            port=info.port, local_address=interface['address'])
                    break

        update_service = add_service

        def remove_service(self, zc, type_, name):
            with lock:
                found.pop(name, None)

    zc = Zeroconf(interfaces=[i['address'] for i in interfaces], ip_version=IPVersion.V4Only)
    browser = ServiceBrowser(zc, SERVICE, Listener())
    try:
        time.sleep(seconds)
        with lock:
            return list(found.values())
    finally:
        browser.cancel()
        zc.close()

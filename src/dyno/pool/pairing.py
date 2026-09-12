"""One-shot TLS pairing with out-of-band transcript verification on both screens.

DNS-SD and the initial self-signed TLS certificate are UNTRUSTED. No credential
is installed or host key trusted until both humans confirm the 128-bit code.
The code binds the certificate, coordinator public key and both random nonces.
No short numeric code or unauthenticated fingerprint from mDNS is trusted.
"""
import base64
from datetime import datetime, timedelta, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import socket
import ssl
import tempfile
import threading
import time
import uuid

from .runtime import LLAMA_REVISION
from .worker_setup import setup_request

LIMIT = 8192


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':')).encode('utf-8')


def send(stream, value):
    data = canonical(value)
    if len(data) > LIMIT:
        raise ValueError('Pairing message too large')
    try:
        stream.write(data + b'\n')
        stream.flush()
    except OSError as exc:
        raise ValueError('Pairing connection closed before completion') from exc


def receive(stream):
    try:
        line = stream.readline(LIMIT + 2)
    except OSError as exc:
        raise ValueError('Pairing connection closed before completion') from exc
    if not line.endswith(b'\n') or len(line) > LIMIT + 1:
        raise ValueError('Invalid or oversized pairing message')
    try:
        value = json.loads(line)
    except (ValueError, RecursionError) as exc:
        raise ValueError('Malformed pairing JSON') from exc
    if not isinstance(value, dict):
        raise ValueError('Expected a pairing object')
    if value.get('error'):
        raise ValueError(value['error'])
    return value


def verification_code(certificate, hello, challenge):
    digest = hashlib.sha256(b'dyno-pair-v1\0' + certificate + canonical(hello) + canonical(challenge)).hexdigest()[:32].upper()
    return ' '.join(digest[i:i+4] for i in range(0, len(digest), 4))


def server_context():
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import NameOID
    key = ec.generate_private_key(ec.SECP256R1())
    name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, 'Dyno temporary pairing')])
    now = datetime.now(timezone.utc)
    cert = (x509.CertificateBuilder().subject_name(name).issuer_name(name)
            .public_key(key.public_key()).serial_number(x509.random_serial_number())
            .not_valid_before(now - timedelta(minutes=1)).not_valid_after(now + timedelta(hours=1))
            .sign(key, hashes.SHA256()))
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    with tempfile.TemporaryDirectory(prefix='dyno-tls-') as folder:
        cert_path, key_path = Path(folder) / 'cert.pem', Path(folder) / 'key.pem'
        cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
        with key_path.open('xb') as f:
            os.chmod(key_path, 0o600)
            f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                      serialization.NoEncryption()))
        context.load_cert_chain(cert_path, key_path)
    # Ephemeral private-key files have been deleted before accepting connections.
    return context, cert.public_bytes(serialization.Encoding.DER)


class PairingServer:
    def __init__(self, address, port, allow_peer, confirm, install, notify=lambda message: None,
                 lifetime=300):
        self.context, self.certificate = server_context()
        self.allow_peer, self.confirm, self.install, self.notify = allow_peer, confirm, install, notify
        self.stopped = threading.Event()
        self.deadline = time.monotonic() + lifetime
        self.listener = socket.socket()
        if os.name == 'nt':
            self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        try:
            self.listener.bind((address, port))
            self.port = self.listener.getsockname()[1]
            self.listener.listen(1)
            self.listener.settimeout(.5)
        except OSError:
            self.listener.close()
            raise
        self.active = None
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.thread.start()

    def _run(self):
        while not self.stopped.is_set() and time.monotonic() < self.deadline:
            try:
                raw, peer = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            try:
                self.active = raw
                raw.settimeout(8)
                if not self.allow_peer(peer[0]):
                    continue
                with self.context.wrap_socket(raw, server_side=True) as connection:
                    self.active = connection
                    connection.settimeout(120)
                    with connection.makefile('rwb') as stream:
                        hello = receive(stream)
                        if (set(hello) != {'v', 'revision', 'public_key', 'nonce', 'name'} or
                                hello['v'] != 1 or hello['revision'] != LLAMA_REVISION or
                                not re.fullmatch('[0-9a-f]{64}', str(hello['nonce'])) or
                                not isinstance(hello['name'], str) or len(hello['name']) > 80):
                            raise ValueError('Invalid pairing request or incompatible runtime')
                        request = setup_request(peer[0], hello['public_key'])
                        challenge = {'nonce': secrets.token_hex(32)}
                        send(stream, challenge)
                        code = verification_code(self.certificate, hello, challenge)
                        if not self.confirm(code, hello['name'], self.stopped):
                            send(stream, {'error': 'Pairing rejected on worker'})
                            continue
                        if receive(stream) != {'confirm': True}:
                            raise ValueError('Coordinator did not confirm pairing')
                        if self.stopped.is_set() or time.monotonic() >= self.deadline or not self.allow_peer(peer[0]):
                            raise ValueError('Pairing expired or LAN changed; try again')
                        # Setup is local, user-approved and only receives the socket peer's address.
                        connection.settimeout(600)
                        result = self.install(request)
                        send(stream, {'paired': result})
                        self.notify('Paired successfully. This pairing window is now closed.')
                        self.stopped.set()
            except (OSError, ValueError, TypeError, KeyError) as exc:
                self.notify('Pairing did not complete: ' + str(exc))
            finally:
                raw.close()
                self.active = None
        if not self.stopped.is_set():
            self.notify('Pairing window expired. Open pairing again to connect another coordinator.')
        self.stopped.set()
        self.listener.close()

    def close(self):
        self.stopped.set()
        self.listener.close()
        active = self.active
        if active:
            try:
                active.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            active.close()
        if self.thread is not threading.current_thread():
            self.thread.join(timeout=2)


def pair(address, port, local_address, public_key, confirm, name=None):
    # Deliberately unauthenticated until the user verifies the transcript code.
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    hello = dict(v=1, revision=LLAMA_REVISION, public_key=public_key,
                 nonce=secrets.token_hex(32), name=(name or socket.gethostname())[:80])
    with socket.create_connection((address, port), timeout=8, source_address=(local_address, 0)) as raw:
        with context.wrap_socket(raw, server_hostname='dyno-pairing') as connection:
            connection.settimeout(600)
            with connection.makefile('rwb') as stream:
                send(stream, hello)
                challenge = receive(stream)
                if set(challenge) != {'nonce'} or not re.fullmatch('[0-9a-f]{64}', str(challenge['nonce'])):
                    raise ValueError('Invalid pairing challenge')
                code = verification_code(connection.getpeercert(binary_form=True), hello, challenge)
                accepted = bool(confirm(code))
                send(stream, {'confirm': accepted})
                if not accepted:
                    raise ValueError('Pairing cancelled; no trust was saved')
                result = receive(stream)
                if set(result) != {'paired'} or not isinstance(result['paired'], dict):
                    raise ValueError('Worker did not return a pairing result')
                return result['paired']


def store_root():
    return Path.home() / '.dyno' / 'pairs'


def new_identity(root=None):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    root = Path(root) if root is not None else store_root()
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    directory = root / uuid.uuid4().hex
    directory.mkdir(mode=0o700)
    key = Ed25519PrivateKey.generate()
    with (directory / 'identity').open('xb') as f:
        os.chmod(directory / 'identity', 0o600)
        f.write(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.OpenSSH,
                                  serialization.NoEncryption()))
    public = key.public_key().public_bytes(serialization.Encoding.OpenSSH, serialization.PublicFormat.OpenSSH).decode()
    return directory, public


def save_pair(directory, address, local_address, result):
    from .runtime import private_ip
    address, local_address = str(private_ip(address)), str(private_ip(local_address))
    user = result.get('user', '')
    if not re.fullmatch(r'[A-Za-z_][A-Za-z0-9_.-]{0,63}', user):
        raise ValueError('Worker returned an unsupported SSH username')
    host_key = setup_request(address, result.get('host_key', ''))['public_key']
    if result.get('revision') != LLAMA_REVISION:
        raise ValueError('Worker runtime version changed')
    ssh_port = result.get('ssh_port', 22)
    if type(ssh_port) is not int or not 1 <= ssh_port <= 65535:
        raise ValueError('Worker returned an invalid SSH port')
    directory = Path(directory)
    host = address if ssh_port == 22 else f'[{address}]:{ssh_port}'
    (directory / 'known_hosts').write_text(f'{host} {host_key}\n', encoding='ascii')
    os.chmod(directory / 'known_hosts', 0o600)
    record = dict(peer=address, local_address=local_address, user=user,
                  ssh_port=ssh_port, rpc_port=50052, pairing_id=directory.name)
    (directory / 'connection.json').write_text(json.dumps(record, indent=2), encoding='utf-8')
    os.chmod(directory / 'connection.json', 0o600)
    return record

"""Serve one disposable update feed over HTTPS on IPv4 loopback."""

from collections import deque
from contextlib import ExitStack
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
import ipaddress
import json
import os
from pathlib import Path
import re
import socket
import ssl
from tempfile import TemporaryDirectory
from threading import Lock, Thread


HOST = "127.0.0.1"
CHANNEL = "adoption-smoke"
UPDATES = f"/samplegame/{CHANNEL}/updates"
CURRENT = f"{UPDATES}/manifest.json"
PAYLOAD_PATH = re.compile(r"[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\Z")


def make_tls(directory):
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.x509.oid import ExtendedKeyUsageOID, NameOID

    key = ec.generate_private_key(ec.SECP256R1())
    identity = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "UE Adoption Loopback Smoke")])
    now = datetime.now(timezone.utc)
    certificate = (x509.CertificateBuilder().subject_name(identity).issuer_name(identity).public_key(key.public_key())
                   .serial_number(x509.random_serial_number()).not_valid_before(now - timedelta(minutes=2))
                   .not_valid_after(now + timedelta(hours=6))
                   .add_extension(x509.BasicConstraints(ca=True, path_length=0), critical=True)
                   .add_extension(x509.KeyUsage(True, False, False, False, False, True, True, False, False), critical=True)
                   .add_extension(x509.ExtendedKeyUsage([ExtendedKeyUsageOID.SERVER_AUTH]), critical=False)
                   .add_extension(x509.SubjectAlternativeName([x509.IPAddress(ipaddress.ip_address(HOST))]), critical=False)
                   .add_extension(x509.SubjectKeyIdentifier.from_public_key(key.public_key()), critical=False)
                   .sign(key, hashes.SHA256()))
    ca = directory / "ca.pem"
    ca.write_bytes(certificate.public_bytes(serialization.Encoding.PEM))
    private = directory / "private.pem"
    private.write_bytes(key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                          serialization.NoEncryption()))
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.load_cert_chain(ca, private)
    return tls, ca


class FeedServer(HTTPServer):
    allow_reuse_address = not hasattr(socket, "SO_EXCLUSIVEADDRUSE")

    def __init__(self, tls, feed):
        self.tls = tls
        self.feed = feed
        super().__init__((HOST, 443), FeedHandler)

    def server_bind(self):
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

    def get_request(self):
        connection, address = super().get_request()
        connection.settimeout(5)
        try:
            return self.tls.wrap_socket(connection, server_side=True), address
        except OSError:
            connection.close()
            raise


class FeedHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def headers_for(self, status, size, cache):
        self.send_response(status)
        self.send_header("Content-Length", str(size))
        self.send_header("Cache-Control", cache)
        self.send_header("Connection", "close")
        self.end_headers()

    def do_GET(self):
        feed = self.server.feed
        with feed._receipt_lock:
            self.send_route(feed)

    def send_route(self, feed):
        route = feed._routes.get(self.path)
        if route is None or self.headers.get("Host") not in (HOST, f"{HOST}:443"):
            self.headers_for(404, 0, "no-store")
            feed._record("<unpublished>", 404, 0)
            return
        data, cache = route
        if isinstance(data, bytes):
            self.headers_for(200, len(data), cache)
            self.wfile.write(data)
            feed._record(self.path, 200, len(data))
            return

        try:
            stream = data.open("rb")
        except OSError:
            self.headers_for(404, 0, "no-store")
            feed._record(self.path, 404, 0)
            return
        with stream:
            self.headers_for(200, os.fstat(stream.fileno()).st_size, cache)
            sent = 0
            for block in iter(lambda: stream.read(256 * 1024), b""):
                if not sent and self.path == feed._corrupt_route:
                    block = bytes([block[0] ^ 1]) + block[1:]
                self.wfile.write(block)
                sent += len(block)
        feed._record(self.path, 200, sent)


class LoopbackFeed:
    manifest_url = f"https://{HOST}{CURRENT}"

    def __init__(self, scratch_parent):
        self.scratch_parent = Path(scratch_parent)
        self._resources = None
        self._routes = {}
        self._latest_release = 0
        self._corrupt_route = None
        self._receipt_lock = Lock()
        self._requests = deque(maxlen=32768)

    def __enter__(self):
        if self._resources is not None:
            raise RuntimeError("The loopback feed is already running")
        with ExitStack() as setup:
            private_dir = Path(setup.enter_context(TemporaryDirectory(prefix="feed-tls-", dir=self.scratch_parent)))
            tls, ca = make_tls(private_dir)
            try:
                server = setup.enter_context(FeedServer(tls, self))
            except OSError as error:
                raise OSError(f"Loopback HTTPS requires a free {HOST}:443 ({error})") from error
            thread = Thread(target=server.serve_forever, name="ue-adoption-loopback-feed", daemon=True)
            thread.start()
            setup.callback(thread.join)
            setup.callback(server.shutdown)
            for key, value in {"SSL_CERT_FILE": str(ca), "no_proxy": HOST}.items():
                previous = os.environ.get(key)
                setup.callback(self._restore_environment, key, previous)
                os.environ[key] = value
            self._resources = setup.pop_all()
        return self

    def __exit__(self, *_args):
        self._resources.close()
        self._resources = None

    @staticmethod
    def _restore_environment(key, value):
        if value is None:
            os.environ.pop(key, None)
        else:
            os.environ[key] = value

    @property
    def requests(self):
        with self._receipt_lock:
            return tuple(self._requests)

    def _record(self, route, status, sent):
        self._requests.append(dict(method="GET", path=route, status=status, bytesSent=sent))

    def publish(self, release, raw, signature, payload_files):
        if self._resources is None or type(release) is not int or not self._latest_release < release <= 999999999:
            raise ValueError("Publish a new increasing release into a running loopback feed")
        if type(raw) is not bytes or not 0 < len(raw) <= 1024 * 1024 or type(signature) is not bytes or len(signature) != 64:
            raise ValueError("Expected a bounded manifest and raw Ed25519 signature")
        metadata = json.loads(raw)
        names = {record["path"] for record in metadata["files"]}
        if metadata["releaseId"] != release or metadata["channel"] != CHANNEL or names != set(payload_files):
            raise ValueError("Feed payload routes must match the published release manifest")
        if any(not PAYLOAD_PATH.fullmatch(name) or {".", ".."}.intersection(name.split("/")) for name in names):
            raise ValueError("Unsafe loopback feed payload path")
        version = f"{UPDATES}/versions/{release}"
        immutable = "public, max-age=31536000, immutable"
        routes = self._routes.copy()
        routes.update({CURRENT: (raw, "no-store"), f"{CURRENT}.sig": (signature, "no-store"),
                       f"{version}/manifest.json": (raw, immutable), f"{version}/manifest.json.sig": (signature, immutable)})
        for name, path in payload_files.items():
            routes[f"{version}/payload/{name}"] = (Path(path), immutable)
        self._corrupt_route = None
        self._routes = routes
        self._latest_release = release

    def set_corrupt_path(self, path):
        route = f"{UPDATES}/versions/{self._latest_release}/payload/{path}" if path is not None else None
        if route is not None and route not in self._routes:
            raise ValueError("Corruption target is not a published payload path")
        self._corrupt_route = route

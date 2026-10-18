#!/usr/bin/env python3
"""Local TLS/CONNECT Apple SSO fixture. Never forwards a network request."""

import argparse
import collections
import http.server
import json
import os
from pathlib import Path
import signal
import socketserver
import ssl
import subprocess
import tempfile
import threading
import urllib.parse


APP_ID = "69a0e57fa939f578082f8091"
HOSTS = {"spyclash.com", "app.base44.com"}
CALLBACK = "https://spyclash.com/MobileAppleAuthCallback.html?auth_provider=apple"
SSO_PATH = "/api/apps/" + APP_ID + "/auth/sso/"
FINAL_PATH = "/fixture/unrecognized-session-completion"
TOKEN = "synthetic-https-candidate-186"
BOOTSTRAP = "https://spyclash.com/functions/appleAuthBroker?action=native-bootstrap&ticket=synthetic-https-186"


def write_json(path, value):
    if not path:
        return
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


class State:
    def __init__(self, mode, final_host, report_file):
        self.mode = mode
        self.final_host = final_host
        self.report_file = report_file
        self.lock = threading.Lock()
        self.requests = []
        self.counts = collections.Counter()
        self.events = collections.Counter()
        self.sequence = 0

    def snapshot(self):
        with self.lock:
            return self._snapshot()

    def _snapshot(self):
        return {
            "fixture": "apple-native-https-fixture",
            "mode": self.mode,
            "final_host": self.final_host,
            "request_count": self.sequence,
            "counts": dict(self.counts),
            "events": dict(self.events),
            "final_route_fetches": self.counts.get("final_candidate", 0),
            "requests": list(self.requests),
        }

    def record(self, host, category, method, status):
        # Every field is a fixed classification. No URI, query or header value
        # is persisted, including malformed or unexpected incoming requests.
        with self.lock:
            self.sequence += 1
            self.counts[category] += 1
            self.requests.append({
                "sequence": self.sequence,
                "host": "spyclash" if host == "spyclash.com" else "base44",
                "category": category,
                "method": method if method in {"GET", "HEAD"} else "other",
                "status": status,
            })
            self.requests = self.requests[-256:]
            write_json(self.report_file, self._snapshot())

    def event(self, category):
        with self.lock:
            self.events[category] += 1
            write_json(self.report_file, self._snapshot())


def generate_certificates():
    temporary = tempfile.TemporaryDirectory(prefix="spyclash-apple-sso-tls-")
    folder = Path(temporary.name)
    os.chmod(folder, 0o700)
    config = folder / "server.cnf"
    config.write_text("""[req]
distinguished_name=dn
prompt=no
req_extensions=v3_req
[dn]
CN=spyclash.com
[v3_req]
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=@alt_names
[alt_names]
DNS.1=spyclash.com
DNS.2=app.base44.com
""")
    commands = [
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-sha256",
         "-days", "1", "-subj", "/CN=SpyClash ephemeral local fixture CA",
         "-addext", "basicConstraints=critical,CA:TRUE",
         "-addext", "keyUsage=critical,keyCertSign,cRLSign",
         "-keyout", str(folder / "ca.key"), "-out", str(folder / "ca.crt")],
        ["openssl", "req", "-new", "-newkey", "rsa:2048", "-nodes", "-sha256",
         "-config", str(config), "-keyout", str(folder / "server.key"),
         "-out", str(folder / "server.csr")],
        ["openssl", "x509", "-req", "-in", str(folder / "server.csr"),
         "-CA", str(folder / "ca.crt"), "-CAkey", str(folder / "ca.key"),
         "-CAcreateserial", "-days", "1", "-sha256", "-extfile", str(config),
         "-extensions", "v3_req", "-out", str(folder / "server.crt")],
    ]
    try:
        for command in commands:
            subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for file in folder.iterdir():
            os.chmod(file, 0o600)
        return temporary
    except Exception:
        temporary.cleanup()
        raise RuntimeError("Ephemeral fixture certificate generation failed") from None


def read_headers(connection):
    data = bytearray()
    # One byte at a time deliberately avoids consuming the first TLS record
    # after CONNECT when the client coalesces it with the HTTP proxy request.
    while not data.endswith(b"\r\n\r\n"):
        if len(data) >= 65536:
            raise ValueError("header_limit")
        value = connection.recv(1)
        if not value:
            raise ValueError("incomplete_request")
        data.extend(value)
    lines = bytes(data).decode("iso-8859-1").split("\r\n")
    method, target, version = lines[0].split(" ", 2)
    headers = {}
    for line in lines[1:]:
        if not line:
            continue
        name, value = line.split(":", 1)
        name = name.strip().lower()
        if name in headers:
            raise ValueError("duplicate_header")
        headers[name] = value.strip()
    return method, target, version, headers


def send_response(connection, status, body=b"", location=None, content_type="text/plain"):
    reasons = {200: "OK", 302: "Found", 400: "Bad Request", 403: "Forbidden", 405: "Method Not Allowed", 500: "Internal Server Error"}
    headers = [
        "HTTP/1.1 %d %s" % (status, reasons[status]),
        "Content-Length: %d" % len(body),
        "Content-Type: " + content_type,
        "Cache-Control: no-store",
        "Connection: close",
    ]
    if location:
        headers.append("Location: " + location)
    connection.sendall(("\r\n".join(headers) + "\r\n\r\n").encode("ascii") + body)


def response_for(host, target, mode, final_host):
    parsed = urllib.parse.urlsplit(target)
    if parsed.scheme or parsed.netloc or parsed.fragment:
        return "invalid_target", 400, None, b"Invalid fixture target", "text/plain"
    query = urllib.parse.parse_qs(parsed.query, keep_blank_values=True)
    category = "unexpected_route"
    destination = None
    login_query = urllib.parse.urlencode({"app_id": APP_ID, "from_url": CALLBACK})
    final_url = "https://" + final_host + FINAL_PATH + "?" + urllib.parse.urlencode({"access_token": TOKEN, "is_new_user": "false"})
    if host == "spyclash.com" and parsed.path == "/functions/appleAuthBroker":
        if query.get("action") == ["native-bootstrap"]:
            category = "bootstrap"
            destination = "https://spyclash.com" + SSO_PATH + "login?" + login_query
        elif query.get("action") == ["authorize"]:
            category = "broker_authorize"
            destination = "https://app.base44.com" + SSO_PATH + "callback?code=synthetic-code&state=synthetic-state"
    elif parsed.path == SSO_PATH + "login":
        if host == "spyclash.com":
            category = "spyclash_sso_login"
            destination = "https://app.base44.com" + SSO_PATH + "login?" + login_query
        else:
            category = "base44_sso_login"
            destination = "https://spyclash.com/functions/appleAuthBroker?action=authorize&state=synthetic-state"
    elif host == "app.base44.com" and parsed.path == SSO_PATH + "callback":
        category = "base44_sso_callback"
        if mode == "script":
            body = ("<!doctype html><meta charset=utf-8><script>window.location.replace(" + json.dumps(final_url) + ");</script>").encode("utf-8")
            return category, 200, None, body, "text/html"
        destination = final_url
    elif host == final_host and parsed.path == FINAL_PATH:
        return "final_candidate", 500, None, b"FAIL: credential-bearing final route was fetched", "text/plain"
    if destination:
        return category, 302, destination, b"", "text/html"
    return category, 500, None, b"Unexpected fixture route", "text/plain"


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        state = self.server.state
        self.request.settimeout(15)
        try:
            method, authority, version, headers = read_headers(self.request)
            if method != "CONNECT" or authority not in {host + ":443" for host in HOSTS}:
                state.event("rejected_connect")
                send_response(self.request, 403, b"Only fixture CONNECT destinations are allowed")
                return
            host = authority[:-4]
            state.event("accepted_connect")
            self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            with self.server.tls.wrap_socket(self.request, server_side=True) as connection:
                method, target, version, headers = read_headers(connection)
                if headers.get("host") not in {host, host + ":443"}:
                    state.event("rejected_host")
                    send_response(connection, 403, b"Host must match the fixture tunnel")
                    return
                if method != "GET":
                    state.record(host, "rejected_method", method, 405)
                    send_response(connection, 405, b"Fixture accepts GET only")
                    return
                category, status, destination, body, content_type = response_for(host, target, state.mode, state.final_host)
                state.record(host, category, method, status)
                send_response(connection, status, body, destination, content_type)
        except ssl.SSLError:
            state.event("tls_error")
        except (ValueError, OSError, UnicodeError):
            state.event("connection_error")


class LocalServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class ReportHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/report":
            body = json.dumps(self.server.state.snapshot(), indent=2).encode("utf-8")
            status = 200
        elif self.path == "/health":
            body = b'{"fixture":"apple-native-https-fixture","ready":true}'
            status = 200
        else:
            body = b'{"error":"unknown_control_route"}'
            status = 404
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=["redirect", "script"], default="redirect")
    parser.add_argument("--final-host", choices=sorted(HOSTS), default="spyclash.com")
    parser.add_argument("--proxy-port", type=int, default=0)
    parser.add_argument("--report-port", type=int, default=0)
    parser.add_argument("--ready-file")
    parser.add_argument("--report-file")
    args = parser.parse_args()
    certificates = generate_certificates()
    folder = Path(certificates.name)
    state = State(args.mode, args.final_host, args.report_file)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.minimum_version = ssl.TLSVersion.TLSv1_2
    tls.set_alpn_protocols(["http/1.1"])
    tls.load_cert_chain(str(folder / "server.crt"), str(folder / "server.key"))

    def require_fixture_sni(connection, server_name, context):
        if server_name not in HOSTS:
            raise ssl.SSLError("Only fixture TLS names are allowed")

    tls.set_servername_callback(require_fixture_sni)
    proxy = LocalServer(("127.0.0.1", args.proxy_port), ProxyHandler)
    proxy.state = state
    proxy.tls = tls
    report = http.server.ThreadingHTTPServer(("127.0.0.1", args.report_port), ReportHandler)
    report.state = state
    for server in [proxy, report]:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    ready = {
        "fixture": "apple-native-https-fixture",
        "pid": os.getpid(),
        "mode": args.mode,
        "proxy_host": "127.0.0.1",
        "proxy_port": proxy.server_address[1],
        "report_url": "http://127.0.0.1:%d/report" % report.server_address[1],
        "ca_certificate": str(folder / "ca.crt"),
        "bootstrap_url": BOOTSTRAP,
        "final_host": args.final_host,
    }
    write_json(args.ready_file, ready)
    write_json(args.report_file, state.snapshot())
    print(json.dumps(ready), flush=True)
    stop = threading.Event()
    signal.signal(signal.SIGINT, lambda *_: stop.set())
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    try:
        stop.wait()
    finally:
        proxy.shutdown()
        report.shutdown()
        proxy.server_close()
        report.server_close()
        write_json(args.report_file, state.snapshot())
        certificates.cleanup()


if __name__ == "__main__":
    main()

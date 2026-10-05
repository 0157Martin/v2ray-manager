"""Exercise production routing with real Xray and loopback-only test traffic.

The SOCKS test inbound isolates routing from protocol/TLS interoperability.
An exact-port positive control proves that a rejected request was not simply
caused by an unavailable test destination.
"""
import copy
import http.server
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time

folder, core = Path(sys.argv[1]), Path(sys.argv[2])


class Page(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.hits += 1
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"PRIVATE-TEST-DESTINATION")

    def log_message(self, *_args):
        pass


def read_exact(connection, length):
    result = b""
    while len(result) < length:
        data = connection.recv(length - len(result))
        if not data:
            raise ConnectionError("SOCKS connection closed")
        result += data
    return result


def request(port, destination_port, hostname):
    with socket.create_connection(("127.0.0.1", port), timeout=3) as connection:
        connection.settimeout(3)
        connection.sendall(b"\x05\x01\x00")
        assert read_exact(connection, 2) == b"\x05\x00"
        if hostname == "127.0.0.1":
            address = b"\x01" + socket.inet_aton(hostname)
        elif ":" in hostname:
            address = b"\x04" + socket.inet_pton(socket.AF_INET6, hostname)
        else:
            encoded = hostname.encode()
            address = b"\x03" + bytes([len(encoded)]) + encoded
        connection.sendall(b"\x05\x01\x00" + address + destination_port.to_bytes(2, "big"))
        reply = read_exact(connection, 4)
        if reply[1] != 0:
            return b""
        if reply[3] == 1:
            read_exact(connection, 6)
        elif reply[3] == 4:
            read_exact(connection, 18)
        else:
            read_exact(connection, read_exact(connection, 1)[0] + 2)
        connection.sendall(b"GET / HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        result = b""
        while True:
            data = connection.recv(4096)
            if not data:
                return result
            result += data


target = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Page)
target.hits = 0
threading.Thread(target=target.serve_forever, daemon=True).start()
base = json.loads((folder / "vmess-tcp.json").read_text(encoding="utf-8"))
try:
    for allow in (False, True):
        config = copy.deepcopy(base)
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            port = reservation.getsockname()[1]
        config["inbounds"] = [{"listen": "127.0.0.1", "port": port,
                               "protocol": "socks", "settings": {"auth": "noauth"}}]
        config["dns"] = {"hosts": {"private.test": "127.0.0.1"}}
        if allow:
            config["routing"]["rules"].insert(0, {
                "type": "field", "ip": ["127.0.0.1"],
                "port": str(target.server_port), "outboundTag": "direct"})
        path = folder / "private-routing.json"
        path.write_text(json.dumps(config), encoding="utf-8")
        with (folder / "private-routing.log").open("w", encoding="utf-8") as output:
            process = subprocess.Popen([str(core), "run", "-config", str(path)],
                                       stdout=output, stderr=output,
                                       env={**os.environ, "XRAY_LOCATION_ASSET": str(core.parent)},
                                       creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            try:
                for _ in range(100):
                    assert process.poll() is None, "Xray exited during routing test"
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                            break
                    except OSError:
                        time.sleep(0.05)
                else:
                    raise TimeoutError("Xray SOCKS listener did not open")
                for hostname in (("127.0.0.1",) if allow else
                                 ("127.0.0.1", "::ffff:127.0.0.1", "localhost", "private.test")):
                    response = b""
                    try:
                        response = request(port, target.server_port, hostname)
                    except (OSError, ConnectionError):
                        if allow:
                            raise
                    assert process.poll() is None, "Xray crashed instead of rejecting traffic"
                    if allow:
                        assert b"PRIVATE-TEST-DESTINATION" in response
                    else:
                        assert not response and target.hits == 0, "Private target was reachable"
            finally:
                process.terminate()
                process.wait(timeout=10)
        print("PASS: " + ("exact-port positive control reaches test target" if allow else
                          "real Xray rejects loopback, mapped IPv4, localhost and a private-resolving domain"), flush=True)
finally:
    target.shutdown()
    target.server_close()

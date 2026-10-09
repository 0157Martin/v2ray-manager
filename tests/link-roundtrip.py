"""Validate exported links and pass real traffic through a local REALITY client/server.

Uses only loopback listeners and generated test credentials. No remote server access.
"""
import base64
import contextlib
import http.server
import json
import os
from pathlib import Path
import re
import socket
import ssl
import subprocess
import sys
import threading
import time
from urllib.parse import parse_qs, unquote, urlsplit


def decode_link(text):
    text = re.sub(r"\x1b\[[0-9;]*m", "", text)
    link = next(line for line in text.splitlines() if line.startswith(("vless://", "trojan://", "vmess://", "hysteria2://")))
    if link.startswith("vmess://"):
        data = json.loads(base64.b64decode(link[len("vmess://") :]))
        return dict(protocol="vmess", address=data["add"], port=int(data["port"]),
                    user=data["id"], network=data["net"], security=data["tls"] or "none",
                    sni=data["sni"], path=data["path"], flow="", remark=data["ps"])
    uri = urlsplit(link)
    query = {key: value[0] for key, value in parse_qs(uri.query, keep_blank_values=True).items()}
    if uri.scheme == "hysteria2":
        return dict(protocol="hysteria", address=uri.hostname, port=uri.port, user=unquote(uri.username),
                    network="hysteria", security="tls", sni=query["sni"], path="", flow="", remark=unquote(uri.fragment))
    return dict(protocol=uri.scheme, address=uri.hostname, port=uri.port,
                user=unquote(uri.username), network=query["type"], security=query["security"],
                sni=query["sni"], path=query.get("path", query.get("serviceName", "")),
                flow=query.get("flow", ""), public=query.get("pbk"), short=query.get("sid"),
                fingerprint=query.get("fp"), remark=unquote(uri.fragment))


def check_export(folder, profile):
    server = json.loads((folder / f"{profile}.json").read_text(encoding="utf-8"))
    data = decode_link((folder / f"{profile}.link").read_text(encoding="utf-8"))
    inbound = server["inbounds"][0]
    stream = inbound["streamSettings"]
    user = inbound["settings"].get("clients", inbound["settings"].get("users"))[0]
    caddy_xhttp = profile == "vless-tls-xhttp"
    assert data["address"] == "node.test.example"
    assert data["port"] == (443 if caddy_xhttp else inbound["port"])
    assert data["protocol"] == inbound["protocol"]
    assert data["user"] == user.get("id", user.get("password", user.get("auth")))
    assert data["flow"] == user.get("flow", "")
    assert {"tcp": "raw"}.get(data["network"], data["network"]) == stream["network"]
    assert data["security"] == ("tls" if caddy_xhttp else stream["security"])
    if caddy_xhttp:
        assert inbound["listen"] == "127.0.0.1" and stream["security"] == "none"
    assert data["remark"] == "test node & 中文"
    client = json.loads((folder / f"{profile}.client.json").read_text(encoding="utf-8"))
    outbound = client["outbounds"][0]
    assert all(item["listen"] == "127.0.0.1" for item in client["inbounds"])
    assert outbound["protocol"] == data["protocol"]
    peer = outbound["settings"] if data["protocol"] == "hysteria" else outbound["settings"].get("vnext", outbound["settings"].get("servers"))[0]
    assert peer["address"] == data["address"] and peer["port"] == data["port"]
    client_user = peer["users"][0] if "users" in peer else peer
    if data["protocol"] == "hysteria":
        assert outbound["streamSettings"]["hysteriaSettings"]["auth"] == data["user"]
    else:
        assert client_user.get("id", client_user.get("password")) == data["user"]
    assert client_user.get("flow", "") == data["flow"]
    client_stream = outbound["streamSettings"]
    assert client_stream["network"] == stream["network"]
    assert client_stream["security"] == data["security"]
    if data["security"] in ("tls", "reality"):
        secure = client_stream[data["security"] + "Settings"]
        assert secure["serverName"] == data["sni"]
        assert not {"privateKey", "certificates", "target", "allowInsecure"}.intersection(secure)
        if data["security"] == "reality":
            assert secure["password"] == data["public"] and secure["shortId"] == data["short"]
    for network, key in (("xhttp", "path"), ("ws", "path"), ("grpc", "serviceName")):
        if data["network"] == network:
            assert data["path"] == stream[f"{network}Settings"][key]
            assert data["path"] == client_stream[f"{network}Settings"][key]
    if data["security"] == "reality":
        assert data["short"] in stream["realitySettings"]["shortIds"]
        assert data["sni"] in stream["realitySettings"]["serverNames"]
        assert data["public"] and data["fingerprint"] == "chrome"
    print(f"PASS: exported {profile} matches server configuration", flush=True)
    return server, data


def free_port():
    with socket.socket() as listener:
        listener.bind(("127.0.0.1", 0))
        return listener.getsockname()[1]


def wait_for_port(port, process):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError("Xray exited before opening its loopback listener")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                return
        except OSError:
            time.sleep(0.05)
    raise TimeoutError("Xray did not open its loopback listener")


def read_exact(connection, length):
    data = b""
    while len(data) < length:
        chunk = connection.recv(length - len(data))
        if not chunk:
            raise RuntimeError("Unexpected end of SOCKS response")
        data += chunk
    return data


class TestPage(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"v2ray-manager-link-roundtrip-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        pass


def real_traffic(folder, core, server, data, profile="vless-reality-raw"):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.set_ecdh_curve("X25519")
    context.set_alpn_protocols(["h2", "http/1.1"])
    context.load_cert_chain(folder / "cert.pem", folder / "key.pem")
    class TlsTarget(http.server.ThreadingHTTPServer):
        # Do TLS in the worker, so an incomplete REALITY probe cannot block accept.
        def finish_request(self, connection, address):
            connection.settimeout(3)
            try:
                with context.wrap_socket(connection, server_side=True) as secured:
                    self.RequestHandlerClass(secured, address, self)
            except (OSError, ssl.SSLError):
                pass

    target = TlsTarget(("127.0.0.1", 0), TestPage)
    target_port = target.server_port
    destination = http.server.ThreadingHTTPServer(("127.0.0.1", 0), TestPage)
    for httpd in (target, destination):
        threading.Thread(target=httpd.serve_forever, daemon=True).start()
    server_port, socks_port = free_port(), free_port()
    server["inbounds"][0]["listen"] = "127.0.0.1"
    server["log"]["loglevel"] = "debug"
    server["inbounds"][0]["port"] = server_port
    server["inbounds"][0]["streamSettings"]["realitySettings"]["target"] = f"127.0.0.1:{target_port}"
    # Production now denies loopback destinations. Only this test HTTP endpoint
    # is explicitly allowed; do not remove the remaining production deny rules.
    server["routing"]["rules"].insert(0, {
        "type": "field", "ip": ["127.0.0.1"],
        "port": str(destination.server_port), "outboundTag": "direct"
    })
    # Exercise the production native client for all REALITY transports.
    client = json.loads((folder / f"{profile}.client.json").read_text(encoding="utf-8"))
    client["log"]["loglevel"] = "debug"
    client["inbounds"] = [client["inbounds"][0]]
    client["inbounds"][0]["port"] = socks_port
    settings = client["outbounds"][0]["settings"]
    peer = settings.get("vnext", settings.get("servers"))[0]
    peer.update(address="127.0.0.1", port=server_port)
    processes = []
    try:
        with contextlib.ExitStack() as stack:
            for name, config, port in (("server", server, server_port), ("client", client, socks_port)):
                path = folder / f"roundtrip-{name}.json"
                path.write_text(json.dumps(config), encoding="utf-8")
                output = stack.enter_context((folder / f"roundtrip-{name}.log").open("w", encoding="utf-8"))
                process = subprocess.Popen([str(core), "run", "-config", str(path)], stdout=output, stderr=output,
                                           env={**os.environ, "XRAY_LOCATION_ASSET": str(core.parent)},
                                           creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                processes.append(process)
                wait_for_port(port, process)
            with socket.create_connection(("127.0.0.1", socks_port), timeout=8) as connection:
                connection.settimeout(8)
                connection.sendall(b"\x05\x01\x00")
                assert read_exact(connection, 2) == b"\x05\x00"
                connection.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + destination.server_port.to_bytes(2, "big"))
                reply = read_exact(connection, 4)
                assert reply[:2] == b"\x05\x00", reply
                if reply[3] == 1:
                    read_exact(connection, 6)
                elif reply[3] == 4:
                    read_exact(connection, 18)
                else:
                    read_exact(connection, read_exact(connection, 1)[0] + 2)
                connection.sendall(b"GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n")
                response = b""
                while True:
                    try:
                        chunk = connection.recv(4096)
                    except ConnectionResetError:
                        break
                    if not chunk:
                        break
                    response += chunk
                assert b"v2ray-manager-link-roundtrip-ok" in response
            print(f"PASS: {profile} carried real HTTP traffic over loopback", flush=True)
    except Exception:
        for name in ("server", "client"):
            log = folder / f"roundtrip-{name}.log"
            if log.exists():
                print(f"Local test {name} log:\n{log.read_text(encoding='utf-8', errors='replace')}", flush=True)
        raise
    finally:
        for process in processes:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
        destination.shutdown()
        destination.server_close()
        target.shutdown()
        target.server_close()


if __name__ == "__main__":
    folder, core = map(Path, sys.argv[1:3])
    profiles = [path.stem for path in sorted(folder.glob("*.link"))]
    # Hysteria2 now uses the official server and a sing-box client config; its
    # URI/client export is covered by unit.sh instead of Xray round trips.
    assert len(profiles) == 12
    fixtures = {profile: check_export(folder, profile) for profile in profiles}
    if "--configuration-only" in sys.argv[3:]:
        print("SKIP: live loopback traffic test was explicitly disabled; export checks alone do not prove connectivity.", flush=True)
    else:
        for profile in profiles:
            if "-reality-" in profile:
                real_traffic(folder, core, *fixtures[profile], profile=profile)

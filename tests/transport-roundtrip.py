"""Real loopback transport tests, including the generated Caddy XHTTP route.

Only generated test credentials and the fixture CA are used. No insecure TLS
option is enabled and no public listener or destination is needed.
"""
import contextlib
import http.server
import json
import os
from pathlib import Path
import runpy
import socket
import subprocess
import sys
import threading
import time

helpers = runpy.run_path(str(Path(__file__).with_name("link-roundtrip.py")))
free_port, wait_for_port, read_exact = (helpers[name] for name in ("free_port", "wait_for_port", "read_exact"))
TestPage = helpers["TestPage"]


def request(socks_port, target_port, timeout=8):
    with socket.create_connection(("127.0.0.1", socks_port), timeout=timeout) as connection:
        connection.settimeout(timeout)
        connection.sendall(b"\x05\x01\x00")
        assert read_exact(connection, 2) == b"\x05\x00"
        connection.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + target_port.to_bytes(2, "big"))
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
        response = b""
        while True:
            try:
                chunk = connection.recv(4096)
            except ConnectionResetError:
                break
            if not chunk:
                return response
            response += chunk
        return response


def stop(process):
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()


def run_profile(folder, core, profile, mode="auto", wrong_auth=False):
    server = json.loads((folder / f"{profile}.json").read_text(encoding="utf-8"))
    client = json.loads((folder / f"{profile}.client.json").read_text(encoding="utf-8"))
    server["log"]["loglevel"] = client["log"]["loglevel"] = "debug"
    caddy_bin = os.environ.get("CADDY_TEST_BIN")
    caddy_route = profile == "vless-tls-xhttp"
    if caddy_route and not caddy_bin:
        raise RuntimeError("CADDY_TEST_BIN must name a real Caddy binary for the XHTTP integration test")
    server_port, socks_port, entry_port = free_port(), free_port(), free_port()
    inbound = server["inbounds"][0]
    inbound.update(listen="127.0.0.1", port=server_port)
    client["inbounds"] = [client["inbounds"][0]]
    client["inbounds"][0]["port"] = socks_port
    outbound = client["outbounds"][0]
    peer = outbound["settings"].get("vnext", outbound["settings"].get("servers"))[0]
    peer.update(address="127.0.0.1", port=entry_port if caddy_route else server_port)
    stream = outbound["streamSettings"]
    if stream.get("security") == "tls":
        stream["tlsSettings"]["certificates"] = [{"certificateFile": str(folder / "cert.pem"), "usage": "verify"}]
        stream["tlsSettings"]["disableSystemRoot"] = True
    if caddy_route:
        stream["xhttpSettings"]["mode"] = mode
    if wrong_auth:
        stream["hysteriaSettings"]["auth"] = "invalid-credential"
    target = http.server.ThreadingHTTPServer(("127.0.0.1", 0), TestPage)
    threading.Thread(target=target.serve_forever, daemon=True).start()
    server["routing"]["rules"].insert(0, {"type": "field", "ip": ["127.0.0.1"], "port": str(target.server_port), "outboundTag": "direct"})
    label = f"{profile}-{mode}-{'negative' if wrong_auth else 'positive'}"
    processes = []
    logs = []
    try:
        with contextlib.ExitStack() as stack:
            def launch(name, args):
                path = folder / f"traffic-{label}-{name}.log"
                logs.append(path)
                output = stack.enter_context(path.open("w", encoding="utf-8"))
                process = subprocess.Popen(args, stdout=output, stderr=output,
                    env={**os.environ, "XRAY_LOCATION_ASSET": str(core.parent)},
                    creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                processes.append(process)
                return process

            path = folder / f"traffic-{label}-server.json"
            path.write_text(json.dumps(server), encoding="utf-8")
            server_process = launch("server", [str(core), "run", "-config", str(path)])
            wait_for_port(server_port, server_process)
            if caddy_route:
                site = (folder / "site.caddy").read_text(encoding="utf-8")
                site = site.replace("example.com {", f"https://example.com:{entry_port} {{\n\tbind 127.0.0.1\n\ttls {json.dumps(str(folder / 'cert.pem'))} {json.dumps(str(folder / 'key.pem'))}")
                site = site.replace("127.0.0.1:24443", f"127.0.0.1:{server_port}")
                assert "h2c://" in site, "production renderer did not produce h2c"
                path = folder / f"traffic-{label}.caddy"
                path.write_text("{\n admin off\n auto_https off\n}\n" + site, encoding="utf-8")
                process = launch("caddy", [caddy_bin, "run", "--config", str(path), "--adapter", "caddyfile"])
                wait_for_port(entry_port, process)
            path = folder / f"traffic-{label}-client.json"
            path.write_text(json.dumps(client), encoding="utf-8")
            process = launch("client", [str(core), "run", "-config", str(path)])
            wait_for_port(socks_port, process)
            try:
                body = request(socks_port, target.server_port, timeout=2 if wrong_auth else 10)
            except (OSError, RuntimeError):
                if not wrong_auth:
                    raise
                body = b""
            if wrong_auth:
                assert b"v2ray-manager-link-roundtrip-ok" not in body, "invalid credential was accepted"
            else:
                assert b"v2ray-manager-link-roundtrip-ok" in body, "traffic did not reach the controlled destination"
            print(f"PASS: {label} real traffic", flush=True)
    except Exception:
        for path in logs:
            print(path.read_text(encoding="utf-8", errors="replace"), flush=True)
        raise
    finally:
        for process in reversed(processes):
            stop(process)
        target.shutdown()
        target.server_close()


if __name__ == "__main__":
    folder, core = map(Path, sys.argv[1:3])
    if len(sys.argv) > 3:
        run_profile(folder, core, sys.argv[3])
        sys.exit(0)
    for profile in ("vmess-tcp", "vless-tls-raw", "vless-tls-ws", "vless-tls-grpc", "trojan-tls-ws", "vmess-tls-ws", "vmess-tls-grpc"):
        run_profile(folder, core, profile)
    for mode in ("auto", "packet-up", "stream-up"):
        run_profile(folder, core, "vless-tls-xhttp", mode=mode)

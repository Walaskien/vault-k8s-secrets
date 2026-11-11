"""Small HTTP service for the demo.

It reads the secret from a mounted file on every request, so a value that was
rotated in Vault shows up without restarting the pod. It never returns the
secret itself, only a short fingerprint, so the answer is safe to look at in CI logs.
"""
import hashlib
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SECRET_DIR = os.environ.get("SECRET_DIR", "/etc/app-secret")
PORT = int(os.environ.get("PORT", "8080"))


def read_secret(name):
    with open(os.path.join(SECRET_DIR, name), "rb") as f:
        return f.read()


class Handler(BaseHTTPRequestHandler):
    def reply(self, code, body):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/healthz":
            self.reply(200, {"status": "ok"})
        elif self.path == "/":
            try:
                password = read_secret("password")
                username = read_secret("username").decode()
            except OSError as exc:
                self.reply(503, {"error": "secret not mounted", "detail": exc.strerror})
                return
            self.reply(200, {
                "username": username,
                "password_sha256_12": hashlib.sha256(password).hexdigest()[:12],
                "password_length": len(password),
            })
        else:
            self.reply(404, {"error": "not found"})

    def log_message(self, fmt, *args):
        # Kubelet probes hit /healthz every few seconds, keep them out of the log.
        if self.path != "/healthz":
            super().log_message(fmt, *args)


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()

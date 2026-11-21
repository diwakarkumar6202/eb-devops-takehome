"""Small demo HTTP service for the Enterprise Bot take-home."""
import os
import socket

from flask import Flask, jsonify

app = Flask(__name__)

# In Kubernetes the chart mounts the ConfigMap at CONFIG_DIR. Mounted ConfigMap
# files update live when the ConfigMap changes; env vars do not. So prefer the
# file when present, fall back to the env var (used by plain `docker run -e`).
CONFIG_DIR = os.environ.get("CONFIG_DIR")


def setting(key: str, default: str = "unknown") -> str:
    if CONFIG_DIR:
        try:
            with open(os.path.join(CONFIG_DIR, key), encoding="utf-8") as f:
                return f.read().strip()
        except OSError:
            pass
    return os.environ.get(key, default)


@app.get("/")
def index():
    # Read per request (not at import) so config changes are picked up
    return jsonify(app=setting("APP_NAME"), version=setting("VERSION"), pod=socket.gethostname())


@app.get("/healthz")
def healthz():
    return jsonify(status="ok"), 200

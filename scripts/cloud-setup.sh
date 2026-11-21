#!/usr/bin/env bash
# Setup script for a Claude Code cloud environment that runs SWE Atlas (see CLOUD.md): paste it
# into the environment's "Setup script" box, or load it there with "Choose file". It runs as root
# on the cloud image (Ubuntu 24.04) before Claude Code starts and installs what run.sh needs:
# harbor 0.25.0 with its Modal extra, and the Modal CLI. Everything comes from PyPI; no key is
# needed here.
set -euo pipefail

# Tool environments under /opt and their commands in /usr/local/bin, so every shell finds them.
export UV_TOOL_DIR="${UV_TOOL_DIR:-/opt/uv-tools}" UV_TOOL_BIN_DIR="${UV_TOOL_BIN_DIR:-/usr/local/bin}"
command -v uv >/dev/null 2>&1 || python3 -m pip install --quiet --break-system-packages uv

# Cloud sessions send HTTPS through a proxy named in HTTPS_PROXY. modal follows that variable,
# and its api-proxy-support extra is what lets it connect through the proxy.
modal='modal[api-proxy-support]==1.6.4'
uv tool install --force --python 3.12 'harbor[modal]==0.25.0' --with "$modal"
uv tool install --force --python 3.12 "$modal"

# The proxy re-signs TLS with a CA that the session adds to the bundle SSL_CERT_FILE names, but
# modal and grpclib verify against certifi's own bundle. This hook points certifi at
# SSL_CERT_FILE when that names a file; where it does not, nothing changes.
for tool in harbor modal; do
  site="$("$UV_TOOL_DIR/$tool/bin/python" -c 'import sysconfig; print(sysconfig.get_path("purelib"))')"
  cat > "$site/certifi_ssl_cert_file.py" <<'PY'
"""Installed by SWE Atlas scripts/cloud-setup.sh: certifi.where() returns SSL_CERT_FILE when set."""
import os

_bundle = os.environ.get("SSL_CERT_FILE", "")
if os.path.isfile(_bundle):
    import certifi

    certifi.where = lambda: _bundle
PY
  echo 'import certifi_ssl_cert_file' > "$site/certifi_ssl_cert_file.pth"
done

harbor --version
modal --version

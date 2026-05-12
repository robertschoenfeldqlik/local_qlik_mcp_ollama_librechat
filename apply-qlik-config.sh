#!/usr/bin/env bash
# apply-qlik-config.sh
# Update Qlik tenant URL + OAuth Client ID in .env and librechat.yaml.
# Optionally restarts the LibreChat (api) container so changes take effect.
#
# Modes:
#   - Interactive CLI (default)
#   - Zenity GUI (if zenity is installed)
#   - Flags: --tenant-url URL --client-id ID [--restart|--no-restart]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
YAML_FILE="$SCRIPT_DIR/librechat.yaml"
COMPOSE="$SCRIPT_DIR/docker-compose.yml"

TENANT_URL_ARG=""
CLIENT_ID_ARG=""
RESTART_FLAG=""   # "yes" | "no" | "" (ask)
USE_GUI=""        # "1" forces zenity, "0" forces CLI; "" auto

# -------- args --------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tenant-url)  TENANT_URL_ARG="$2"; shift 2 ;;
        --client-id)   CLIENT_ID_ARG="$2"; shift 2 ;;
        --restart)     RESTART_FLAG="yes"; shift ;;
        --no-restart)  RESTART_FLAG="no"; shift ;;
        --gui)         USE_GUI="1"; shift ;;
        --cli)         USE_GUI="0"; shift ;;
        -h|--help)
            cat <<EOF
Usage: $0 [options]
  --tenant-url URL   Qlik Cloud tenant URL (e.g. https://x.us.qlikcloud.com)
  --client-id ID     OAuth Client ID
  --restart          Restart api container after applying (no prompt)
  --no-restart       Do not restart api container
  --gui              Force zenity GUI (errors if zenity not installed)
  --cli              Force CLI prompts (skip GUI even if zenity is present)
  -h, --help         Show this help
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# -------- read existing values --------
existing_tenant=""
existing_client=""
if [[ -f "$ENV_FILE" ]]; then
    existing_tenant=$(grep -E '^QLIK_TENANT_URL=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)
    existing_client=$(grep -E '^QLIK_OAUTH_CLIENT_ID=' "$ENV_FILE" | head -1 | cut -d= -f2- || true)
fi

# -------- decide GUI vs CLI --------
gui_available=false
if [[ "$USE_GUI" != "0" ]] && command -v zenity &>/dev/null; then
    gui_available=true
fi
if [[ "$USE_GUI" == "1" && "$gui_available" == false ]]; then
    echo "Error: --gui requested but zenity is not installed." >&2
    exit 1
fi

# -------- gather input --------
QLIK_TENANT_URL=""
QLIK_OAUTH_CLIENT_ID=""

if [[ -n "$TENANT_URL_ARG" && -n "$CLIENT_ID_ARG" ]]; then
    QLIK_TENANT_URL="$TENANT_URL_ARG"
    QLIK_OAUTH_CLIENT_ID="$CLIENT_ID_ARG"
elif [[ "$gui_available" == true && "$USE_GUI" != "0" ]]; then
    result=$(zenity --forms \
        --title="Qlik MCP Configuration" \
        --text="Update Qlik Cloud credentials" \
        --add-entry="Tenant URL (e.g. https://x.us.qlikcloud.com)" \
        --add-entry="OAuth Client ID" \
        --separator='|' 2>/dev/null) || { echo "Cancelled."; exit 1; }
    QLIK_TENANT_URL=$(echo "$result"   | awk -F'|' '{print $1}')
    QLIK_OAUTH_CLIENT_ID=$(echo "$result" | awk -F'|' '{print $2}')
else
    echo ""
    echo "=============================================="
    echo "  Qlik MCP Configuration"
    echo "=============================================="
    echo ""
    if [[ -n "$existing_tenant" ]]; then
        echo "  Current tenant URL: $existing_tenant"
    fi
    if [[ -n "$TENANT_URL_ARG" ]]; then
        QLIK_TENANT_URL="$TENANT_URL_ARG"
    else
        read -rp "  New tenant URL [press Enter to keep current]: " input
        QLIK_TENANT_URL="${input:-$existing_tenant}"
    fi

    if [[ -n "$existing_client" ]]; then
        echo "  Current Client ID:  ${existing_client:0:8}..."
    fi
    if [[ -n "$CLIENT_ID_ARG" ]]; then
        QLIK_OAUTH_CLIENT_ID="$CLIENT_ID_ARG"
    else
        read -rp "  New OAuth Client ID [press Enter to keep current]: " input
        QLIK_OAUTH_CLIENT_ID="${input:-$existing_client}"
    fi
    echo ""
fi

# -------- validate --------
QLIK_TENANT_URL="${QLIK_TENANT_URL%/}"
if [[ ! "$QLIK_TENANT_URL" =~ ^https?:// ]]; then
    echo "Error: Tenant URL must start with https:// — got: '$QLIK_TENANT_URL'" >&2
    exit 1
fi
if [[ -z "$QLIK_OAUTH_CLIENT_ID" ]]; then
    echo "Error: OAuth Client ID cannot be empty." >&2
    exit 1
fi

echo "Applying:"
echo "  Tenant:   $QLIK_TENANT_URL"
echo "  ClientID: ${QLIK_OAUTH_CLIENT_ID:0:8}..."
echo ""

# -------- apply to .env --------
if [[ -f "$ENV_FILE" ]]; then
    sed -i "s|^QLIK_TENANT_URL=.*|QLIK_TENANT_URL=${QLIK_TENANT_URL}|" "$ENV_FILE"
    sed -i "s|^QLIK_OAUTH_CLIENT_ID=.*|QLIK_OAUTH_CLIENT_ID=${QLIK_OAUTH_CLIENT_ID}|" "$ENV_FILE"
    echo "  .env updated."
else
    echo "  Warning: .env not found. Run deploy.sh first." >&2
fi

# -------- apply to librechat.yaml --------
if [[ -f "$YAML_FILE" ]]; then
    sed -i "s|url: \"https://[^\"]*\/api\/ai\/mcp\"|url: \"${QLIK_TENANT_URL}/api/ai/mcp\"|" "$YAML_FILE"
    sed -i "s|authorization_url: \"https://[^\"]*\/oauth\/authorize\"|authorization_url: \"${QLIK_TENANT_URL}/oauth/authorize\"|" "$YAML_FILE"
    sed -i "s|token_url: \"https://[^\"]*\/oauth\/token\"|token_url: \"${QLIK_TENANT_URL}/oauth/token\"|" "$YAML_FILE"
    sed -i "s|X-Agent-Id: \"[^\"]*\"|X-Agent-Id: \"${QLIK_OAUTH_CLIENT_ID}\"|" "$YAML_FILE"
    sed -i "s|client_id: \"[^\"]*\"|client_id: \"${QLIK_OAUTH_CLIENT_ID}\"|" "$YAML_FILE"
    echo "  librechat.yaml updated."
else
    echo "  Warning: librechat.yaml not found." >&2
fi

# -------- restart? --------
do_restart="no"
if [[ -n "$RESTART_FLAG" ]]; then
    do_restart="$RESTART_FLAG"
else
    read -rp "  Restart LibreChat (api) container now? [Y/n]: " ans
    if [[ "$ans" != "n" && "$ans" != "N" ]]; then
        do_restart="yes"
    fi
fi

if [[ "$do_restart" == "yes" ]]; then
    if command -v docker &>/dev/null; then
        docker compose -f "$COMPOSE" restart api
        echo "  api container restarted."
    else
        echo "  Warning: docker not found — skipped restart." >&2
    fi
fi

echo ""
echo "Done."

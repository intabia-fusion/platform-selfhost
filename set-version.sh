#!/usr/bin/env bash

# Script to update Intabia Platform version
# Usage: ./set-version.sh [--silent] [--registry <prefix>] <version>
# Example: ./set-version.sh v0.8.0
#          ./set-version.sh --silent v0.8.0
#          ./set-version.sh --silent --registry registry.example.com/myns v0.8.0

set -e

CONFIG_DIR="config"
CONFIG_FILE="$CONFIG_DIR/platform.conf"
VERSION_FILE="$CONFIG_DIR/version.txt"
TEMPLATE_VERSION_FILE="templates/version.txt"

# Default values
SILENT=false
IMAGE_PREFIX=""

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --silent)
            SILENT=true
            shift
            ;;
        --registry)
            IMAGE_PREFIX="$2"
            shift 2
            ;;
        *)
            # Assume it's the version argument
            NEW_VERSION="$1"
            shift
            ;;
    esac
done

# Get current version from template or config
get_current_version() {
    if [ -f "$VERSION_FILE" ]; then
        cat "$VERSION_FILE" | tr -d '[:space:]'
    elif [ -f "$TEMPLATE_VERSION_FILE" ]; then
        cat "$TEMPLATE_VERSION_FILE" | tr -d '[:space:]'
    else
        echo ""
    fi
}

# Check if version argument is provided
if [ -z "$NEW_VERSION" ]; then
    echo "Usage: $0 [--silent] [--registry <prefix>] <version>"
    echo "Example: $0 v0.8.0"
    echo "         $0 --silent v0.8.0"
    echo ""
    echo "Current version: $(get_current_version)"
    exit 1
fi

CURRENT_VERSION=$(get_current_version)

# Ensure config directory exists
mkdir -p "$CONFIG_DIR"

# Update version file
echo "$NEW_VERSION" > "$VERSION_FILE"
echo "Version updated: ${CURRENT_VERSION:-'(none)'} -> $NEW_VERSION"

# Update config file if it exists
if [ -f "$CONFIG_FILE" ]; then
    sed -i.bak "s/^PLATFORM_VERSION=.*/PLATFORM_VERSION=$NEW_VERSION/" "$CONFIG_FILE"
    sed -i.bak "s/^DESKTOP_CHANNEL=.*/DESKTOP_CHANNEL=$NEW_VERSION/" "$CONFIG_FILE"
    if [ -n "$IMAGE_PREFIX" ]; then
        # Stands set up before IMAGE_PREFIX existed have no such line yet.
        if grep -q '^IMAGE_PREFIX=' "$CONFIG_FILE"; then
            sed -i.bak "s|^IMAGE_PREFIX=.*|IMAGE_PREFIX=$IMAGE_PREFIX|" "$CONFIG_FILE"
        else
            echo "IMAGE_PREFIX=$IMAGE_PREFIX" >> "$CONFIG_FILE"
        fi
        echo "Image prefix: $IMAGE_PREFIX"
    fi
    rm -f "$CONFIG_FILE.bak"
    echo "Config file updated: $CONFIG_FILE"
fi

# Source config for DEV_MODE
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

DC="docker compose --env-file config/platform.conf"
if [ "$DEV_MODE" == "true" ] && [ -f "dev/compose.override.yml" ]; then
    DC="docker compose --env-file config/platform.conf -f compose.yml -f dev/compose.override.yml"
    if [ "$LIVEKIT_ENABLED" == "true" ]; then
        DC="$DC --profile livekit-dev"
    fi
elif [ "$LIVEKIT_ENABLED" == "true" ]; then
    DC="$DC --profile livekit"
fi

# Same profile as up.sh, otherwise tbank-subscriptions is never pulled or restarted here.
if [ "$PAYMENT_PROVIDER" == "tbank" ]; then
    DC="$DC --profile tbank"
fi

if [ "$WEBHOOK_ENABLED" == "true" ]; then
    DC="$DC --profile webhook"
fi

# config/qa is always bind-mounted into nginx (harmless empty dir when the feature is off); a
# missing bind-mount source would otherwise make Docker create it as a root-owned directory.
mkdir -p "$CONFIG_DIR/qa"

# QA tools (Dozzle + stand info page, test stands only): refuse to enable without a password.
if [ "$QA_TOOLS_ENABLED" == "true" ]; then
    if [ -z "$QA_TOOLS_PASSWORD" ]; then
        QA_TOOLS_PASSWORD=$(openssl rand -hex 16)
        grep -v '^QA_TOOLS_PASSWORD=' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        echo "QA_TOOLS_PASSWORD=$QA_TOOLS_PASSWORD" >> "$CONFIG_FILE"
        echo "QA tools password generated (user: qa), see QA_TOOLS_PASSWORD in $CONFIG_FILE"
    fi
    if [ -n "$QA_TOOLS_PASSWORD" ]; then
        echo "qa:$(openssl passwd -apr1 -stdin <<< "$QA_TOOLS_PASSWORD")" > "$CONFIG_DIR/qa/.htpasswd"
        DC="$DC --profile qa"
        # An explicit -f drops the implicit compose.yml, so name it unless dev mode already did.
        [[ "$DC" == *" -f "* ]] || DC="$DC -f compose.yml"
        DC="$DC -f compose.qa.yml"
    else
        echo -e "\033[1;31mWARNING: QA_TOOLS_PASSWORD is empty and openssl could not generate one; QA tools stay disabled.\033[0m"
        QA_TOOLS_ENABLED=false
    fi
fi

# Same nginx site generation as up.sh: compose mounts config/platform.nginx
if [ "$QA_TOOLS_ENABLED" == "true" ]; then
    ./qa-info.sh || echo "Warning: qa-info.sh failed"
fi
NGINX_SED_ARGS=()
[ "$WEBHOOK_ENABLED" == "true" ] && NGINX_SED_ARGS+=(-e '/# @webhook/r templates/nginx-webhook.conf')
[ "$QA_TOOLS_ENABLED" == "true" ] && NGINX_SED_ARGS+=(-e '/# @qa/r templates/nginx-qa.conf')
if [ ${#NGINX_SED_ARGS[@]} -gt 0 ]; then
    sed "${NGINX_SED_ARGS[@]}" .platform.nginx > config/platform.nginx
else
    cp .platform.nginx config/platform.nginx
fi

# Registry hiccups are common enough that one dropped layer should not fail a deploy.
pull_with_retry () {
    local attempt
    for attempt in 1 2 3; do
        $DC pull && return 0
        echo "Pull failed (attempt $attempt/3), retrying in 10s..."
        sleep 10
    done
    echo "Pull failed after 3 attempts" >&2
    return 1
}

# Handle image pulling and restart based on silent mode
if [ "$SILENT" == true ]; then
    echo "Silent mode enabled. Skipping interactive prompts."
    echo "Pulling Docker images..."
    pull_with_retry
    echo "Images pulled successfully."
    echo "Restarting services..."
    $DC up -d
    $DC exec -T nginx nginx -s reload >/dev/null 2>&1 || true
    echo "Services restarted."
else
    # Ask if user wants to pull new images
    read -p "Do you want to pull the new Docker images? (y/N): " pull_images
    case "$pull_images" in
        [Yy]* )
            echo "Pulling Docker images..."
            pull_with_retry
            echo "Images pulled successfully."
            
            read -p "Do you want to restart services with new version? (y/N): " restart
            case "$restart" in
                [Yy]* )
                    echo "Restarting services..."
                    $DC up -d
                    $DC exec -T nginx nginx -s reload >/dev/null 2>&1 || true
                    echo "Services restarted."
                    ;;
                * )
                    echo "Services not restarted. Run './up.sh' when ready."
                    ;;
            esac
            ;;
        * )
            echo "Images not pulled. Run '$DC pull' when ready."
            ;;
    esac
fi

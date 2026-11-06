#!/bin/sh
# Installs a Veritas release on a Unix host.
#
# The release is a directory that carries the node, the ERTS, and the
# datastore's own binary. This script unpacks it, gives it a service
# account, writes its configuration, and registers the service with the
# platform's service manager.
#
# The datastore is **not** registered as a service of its own: it is a
# child of the node (ADR-048), so it starts with the node and stops with it.
#
# Usage:
#
#   ops/install.sh /path/to/veritas-1.0.0-linux-x86_64.tar.gz
#
# Environment (every one has a default):
#
#   PREFIX        where the release lives            (default /usr/local)
#   DATA_DIR      the node's data and log directory  (default $PREFIX/var/veritas)
#   CONFIG_DIR    the node's configuration directory  (default /etc/veritas)
#   UNIT_DIR      where the service definition goes  (default /etc/systemd/system)
#   PORT          the port the web surface listens on (default 4000)
#   SURREAL_PORT  the port the managed datastore listens on (default: a free
#                 port of its own; see below)
#
# The web surface and the managed datastore are two listeners, so they get
# two ports. The datastore takes a free port by default — a node that fails
# to start because something else holds the port is a node that cannot be run
# beside anything — and SURREAL_PORT pins one. A pinned datastore port may
# not be the web surface's port.
#
# A per-user install needs no root:
#
#   PREFIX=$HOME/.local VERITAS_DATA=$HOME/.local/share/veritas \
#   CONFIG_DIR=$HOME/.config/veritas UNIT_DIR=$HOME/Library/LaunchAgents \
#   ops/install.sh ./veritas-1.0.0-linux-x86_64.tar.gz

set -eu

RELEASE_TARBALL="${1:-}"
PREFIX="${PREFIX:-/usr/local}"
DATA_DIR="${VERITAS_DATA:-$PREFIX/var/veritas}"
CONFIG_DIR="${CONFIG_DIR:-/etc/veritas}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
PORT="${PORT:-4000}"
SURREAL_PORT="${SURREAL_PORT:-}"

if [ -z "$RELEASE_TARBALL" ]; then
  echo "usage: $0 /path/to/veritas-release.tar.gz" >&2
  exit 2
fi

if [ ! -f "$RELEASE_TARBALL" ]; then
  echo "there is no file at $RELEASE_TARBALL" >&2
  exit 1
fi

RELEASE_HOME="$PREFIX/opt/veritas"

echo "==> unpacking $RELEASE_TARBALL into $RELEASE_HOME"
mkdir -p "$RELEASE_HOME"
tar -xzf "$RELEASE_TARBALL" -C "$RELEASE_HOME" --strip-components=1

# The datastore's binary is bundled. If it is not there, the node cannot
# start, and the operator should find that out here rather than at boot.
if [ ! -x "$RELEASE_HOME/vendor/surreal/surreal" ]; then
  echo "the release has no datastore binary at vendor/surreal/surreal." >&2
  echo "It was not built with one; see ops/RUNBOOK.md." >&2
  exit 1
fi

echo "==> the datastore binary"
"$RELEASE_HOME/vendor/surreal/surreal" version

echo "==> the data and log directories"
# The directory is created before it is handed to the service account: a
# fresh installation has no data directory yet, and chowning a directory
# that does not exist is a failure that stops the installation before it
# has unpacked anything.
mkdir -p "$DATA_DIR" "$DATA_DIR/log"

echo "==> the service account"
if [ "$(id -u)" -eq 0 ]; then
  id -u veritas >/dev/null 2>&1 || useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin veritas
  chown -R veritas:veritas "$DATA_DIR"
else
  echo "    not root: the service runs as $(id -un)"
fi

echo "==> the configuration"
mkdir -p "$CONFIG_DIR"
if [ ! -f "$CONFIG_DIR/veritas.conf" ]; then
  # Written with `printf` rather than a here-document: a here-document makes
  # the shell write a temporary file, and an installer that runs as root has
  # no business needing one to write two configuration files.
  printf '%s\n' \
    "# Veritas server configuration." \
    "#" \
    "# The node starts and supervises its own datastore; the data directory" \
    "# below is the datastore's, and it is the operator's." \
    "#" \
    "# Uncomment and set to use a store the node does not manage." \
    "# VERITAS_SURREAL_URL=http://127.0.0.1:8000" \
    > "$CONFIG_DIR/veritas.conf"
  echo "    wrote $CONFIG_DIR/veritas.conf"
else
  echo "    $CONFIG_DIR/veritas.conf exists; left alone"
fi

# Two listeners, two ports. The web surface takes PORT; the managed
# datastore takes a free port of its own unless the operator pinned one.
# A pinned datastore port that is the web surface's port is refused here
# rather than discovered at boot, when the node cannot start.
if [ -n "$SURREAL_PORT" ] && [ "$SURREAL_PORT" = "$PORT" ]; then
  echo "the managed datastore and the web surface cannot share port $PORT." >&2
  echo "Give the datastore its own port, for example SURREAL_PORT=8001." >&2
  exit 1
fi

{
  printf '%s\n' \
    "# The node's environment. Read by the service definition." \
    "#" \
    "# PORT is the web surface. The managed datastore listens on a free port of" \
    "# its own unless VERITAS_SURREAL_PORT pins one, so the two never contend" \
    "# for the same port." \
    "VERITAS_DATA_DIR=$DATA_DIR" \
    "PORT=$PORT"

  if [ -n "$SURREAL_PORT" ]; then
    printf '%s\n' "VERITAS_SURREAL_PORT=$SURREAL_PORT"
  fi
} > "$CONFIG_DIR/veritas.env"

echo "    wrote $CONFIG_DIR/veritas.env"

case "$(uname -s)" in
  Darwin)
    echo "==> the launchd agent"
    mkdir -p "$UNIT_DIR"
    for plist in com.veritas.server com.veritas.scheduler com.veritas.agent; do
      sed -e "s#/usr/local/opt/veritas#$RELEASE_HOME#g" \
          -e "s#/usr/local/var/veritas#$DATA_DIR#g" \
          -e "s#/etc/veritas#$CONFIG_DIR#g" \
          "$RELEASE_HOME/ops/launchd/$plist.plist" > "$UNIT_DIR/$plist.plist"
      launchctl unload "$UNIT_DIR/$plist.plist" 2>/dev/null || true
      launchctl load "$UNIT_DIR/$plist.plist"
      echo "    loaded $plist"
    done
    ;;

  Linux)
    echo "==> the systemd units"
    if [ "$(id -u)" -ne 0 ]; then
      echo "    not root: the units were not installed." >&2
      echo "    run this again as root, or install the units yourself from" >&2
      echo "    $RELEASE_HOME/ops/systemd/." >&2
      exit 1
    fi
    mkdir -p "$UNIT_DIR"
    for unit in veritas veritas-scheduler veritas-agent; do
      sed -e "s#/opt/veritas#$RELEASE_HOME#g" \
          -e "s#/var/lib/veritas#$DATA_DIR#g" \
          -e "s#/etc/veritas#$CONFIG_DIR#g" \
          "$RELEASE_HOME/ops/systemd/$unit.service" > "$UNIT_DIR/$unit.service"
      echo "    wrote $UNIT_DIR/$unit.service"
    done
    systemctl daemon-reload
    systemctl enable --now veritas
    ;;

  *)
    echo "    $PREFIX is not a platform this script installs a service on." >&2
    echo "    The release is unpacked and can be run by hand:" >&2
    echo "      VERITAS_ROLE=server $RELEASE_HOME/bin/veritas start" >&2
    exit 1
    ;;
esac

echo
echo "Veritas is installed."
echo "  release   $RELEASE_HOME"
echo "  data      $DATA_DIR"
echo "  config    $CONFIG_DIR"
echo
echo "The runbook is $RELEASE_HOME/ops/RUNBOOK.md"

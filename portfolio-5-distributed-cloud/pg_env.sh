# Portfolio 5: pg_env.sh (sourced by the multi-node scripts)

if [ -z "${PG_BIN:-}" ]; then
  if command -v pg_config >/dev/null 2>&1; then PG_BIN=$(pg_config --bindir)
  elif [ -d /usr/lib/postgresql/16/bin ]; then PG_BIN=/usr/lib/postgresql/16/bin
  elif command -v brew >/dev/null 2>&1; then PG_BIN="$(brew --prefix postgresql@16)/bin"
  fi
fi
BIN=$PG_BIN

# Where the extra demo clusters (standby, shards) live
if [ "$(uname)" = "Darwin" ]; then
  PGDEMO=${PGDEMO:-$HOME/pgdemo}
  PRIMARY_DIR=${PRIMARY_DIR:-$(brew --prefix 2>/dev/null)/var/postgresql@16}
else
  PGDEMO=${PGDEMO:-/var/lib/pgdemo}
  PRIMARY_DIR=${PRIMARY_DIR:-$PGDEMO/primary}
fi
mkdir -p "$PGDEMO"

# Run a server command as the OS user that owns the clusters:
# 'postgres' when this script runs as root on Linux, yourself otherwise.
if [ "$(id -u)" = "0" ] && id postgres >/dev/null 2>&1; then
  chown postgres "$PGDEMO"
  as_pg() { su postgres -c "$*"; }
else
  as_pg() { bash -c "$*"; }
fi

# Portable helpers (macOS 'date' has no %N, and there is no /proc there)
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
new_uuid() { python3 -c 'import uuid; print(uuid.uuid4())'; }

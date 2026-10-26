#!/usr/bin/env bash
# scripts/docker-build.sh — install docker (if missing) + build ivy_mooncake image
set -euo pipefail

IMAGE="ivorysql/ivy_mooncake:5.3-ubi8"
BASE="registry.highgo.com/ivorysql/ivorysql:5.3-ubi8"

# ---------- 1. install docker if missing ----------
if ! command -v docker >/dev/null 2>&1; then
    echo "==> docker not found, installing"
    if command -v apt-get >/dev/null 2>&1; then
        # Debian/Ubuntu
        sudo apt-get update
        sudo apt-get install -y ca-certificates curl gnupg
        sudo install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg \
            | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
        OS_ID=$(. /etc/os-release && echo "$ID")
        OS_CODENAME=$(. /etc/os-release && echo "${VERSION_CODENAME:-$UBUNTU_CODENAME}")
        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/${OS_ID} ${OS_CODENAME} stable" \
            | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
        sudo apt-get update
        sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif command -v dnf >/dev/null 2>&1; then
        # RHEL/Rocky/Fedora
        sudo dnf install -y dnf-plugins-core
        sudo dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    elif command -v yum >/dev/null 2>&1; then
        sudo yum install -y yum-utils
        sudo yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
        sudo yum install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
    else
        echo "ERROR: unsupported package manager. Install docker manually." >&2
        exit 1
    fi
    sudo systemctl enable --now docker
    sudo usermod -aG docker "$USER" || true
    echo "==> docker installed. You may need to logout/login for group changes; using sudo for this script."
fi

# Prefix all docker commands with sudo if current user not in docker group.
if id -nG "$USER" | grep -qw docker; then
    DOCKER="docker"
else
    DOCKER="sudo docker"
    echo "==> using sudo for docker (re-login as $USER to use docker without sudo)"
fi

$DOCKER --version

# ---------- 2. login to highgo registry ----------
echo "==> logging in to registry.highgo.com"
if ! $DOCKER pull "${BASE}" >/dev/null 2>&1; then
    echo "Cannot pull ${BASE} without auth."
    echo "Please run: $DOCKER login registry.highgo.com"
    echo "Enter highgo registry credentials when prompted, then re-run this script."
    $DOCKER login registry.highgo.com
fi

# ---------- 3. ensure submodules ----------
cd "$(dirname "$0")/.."
if [ ! -f ivy_duckdb/Makefile ] || [ ! -f ivy_moonlink/Cargo.toml ] || [ ! -d ivy_duckdb_mooncake ]; then
    echo "==> initializing submodules"
    git submodule update --init --recursive
fi

# ---------- 4. build ----------
echo "==> building ${IMAGE}"
$DOCKER build \
    --build-arg "IVORYSQL_BASE=${BASE}" \
    -t "${IMAGE}" \
    -f Dockerfile \
    .

# ---------- 5. smoke test ----------
echo "==> smoke test"
$DOCKER rm -f ivy_mooncake_smoke 2>/dev/null || true
CT=$($DOCKER run -d --name ivy_mooncake_smoke \
    -e IVORYSQL_PASSWORD=password \
    "${IMAGE}")
trap 'echo "==> container logs:"; $DOCKER logs ivy_mooncake_smoke 2>&1 | tail -50; $DOCKER stop ivy_mooncake_smoke >/dev/null 2>&1 || true' EXIT

echo "==> waiting for postgres"
for i in $(seq 1 60); do
    if $DOCKER exec "$CT" pg_isready -U ivorysql -d postgres >/dev/null 2>&1; then
        echo "    ready in ${i}s"
        break
    fi
    sleep 1
done

echo "==> CREATE EXTENSION test"
$DOCKER exec "$CT" psql -U ivorysql -d postgres -c "
CREATE EXTENSION pg_mooncake CASCADE;
SELECT extname, extversion FROM pg_extension
 WHERE extname IN ('pg_duckdb','pg_mooncake');
"

echo "==> mirror E2E test"
$DOCKER exec -i "$CT" psql -v ON_ERROR_STOP=1 -U ivorysql -d postgres <<'SQL'
CREATE TABLE t (id int PRIMARY KEY, v text);
ALTER TABLE t REPLICA IDENTITY FULL;
INSERT INTO t VALUES (1,'a'),(2,'b');
CALL mooncake.create_table('t_mirror', 't');
SELECT count(*) AS mirror_rows FROM t_mirror;
SQL

echo "==> DONE: image '${IMAGE}' built and verified."
echo "    Run:    docker run --rm \\"
echo "              -e IVORYSQL_PASSWORD=password \\"
echo "              -p 5432:5432 -p 1521:1521 \\"
echo "              -v ivy_mooncake_data:/var/lib/ivorysql/data \\"
echo "              -v ivy_mooncake_warehouse:/tmp/moonlink_iceberg \\"
echo "              ${IMAGE}"
echo "    Or:     docker compose up -d --build"

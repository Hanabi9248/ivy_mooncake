"""Execute complete actual workflow run blocks against command boundaries.

No Docker daemon, database, SQL parser or extension is run. The boundary models
documented exec stdin forwarding and psql exit modes only. No standalone
docker-build.sh execution. Standard library only; Main runs serially.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = Path(os.environ.get("DOCKER_SMOKE_WORKFLOW", ROOT / ".github/workflows/docker.yml"))
BASH = os.environ.get("BASH_EXECUTABLE", "bash")
E2E = "Verify mooncake.create_table E2E"
EXTENSION = "Verify CREATE EXTENSION pg_mooncake CASCADE"
EXPECTED_SQL = [
    "CREATE TABLE t (id int PRIMARY KEY, v text);",
    "ALTER TABLE t REPLICA IDENTITY FULL;",
    "INSERT INTO t VALUES (1,'a'),(2,'b');",
    "CALL mooncake.create_table('t_mirror', 't');",
    "SELECT count(*) FROM t_mirror;",
]

# Explicit external command boundary, not a replacement SQL implementation.
# BASH_ENV makes selection independent of host Docker/PATH aliases.
BOUNDARY = r'''
docker() {
    test "$1" = exec || return 98
    shift
    local interactive=0 stop_on_error=0 command_sql=""
    if test "$1" = -i; then interactive=1; shift; fi
    test "$1" = test || return 98
    shift
    test "$1" = psql || return 98
    shift
    while test "$#" -gt 0; do
        case "$1" in
            -v) test "$2" = ON_ERROR_STOP=1 || return 98
                stop_on_error=1; shift 2 ;;
            -U|-d) shift 2 ;;
            -c) command_sql="$2"; shift 2 ;;
            *) return 98 ;;
        esac
    done
    if test "$BOUNDARY_DOCKER_ERROR" = 1; then return 57; fi
    if test -n "$command_sql"; then
        printf '%s' "$command_sql" > "$SQL_CAPTURE"
        if test "$BOUNDARY_SQL_ERROR" = 1; then return 1; fi
        return 0
    fi
    if test "$interactive" = 1; then
        cat > "$SQL_CAPTURE"
    else
        : > "$SQL_CAPTURE"
    fi
    if test -s "$SQL_CAPTURE" && test "$BOUNDARY_SQL_ERROR" = 1 && test "$stop_on_error" = 1; then
        printf 'ERROR: explicit SQL-failure boundary\n' >&2
        return 3
    fi
}
'''


def actual_run_block(step_name):
    """Read this simple literal YAML block without a YAML package or rewrites."""
    lines = WORKFLOW.read_text(encoding="utf-8").splitlines()
    index = lines.index("      - name: " + step_name) + 1
    if lines[index] != "        run: |":
        raise AssertionError("expected the actual literal run block")
    block = []
    for line in lines[index + 1:]:
        if line and not line.startswith("          "):
            break
        block.append(line)
    return textwrap.dedent("\n".join(block)) + "\n"


class DockerSmokeWorkflow(unittest.TestCase):
    def invoke(self, name=E2E, sql_error=False, docker_error=False):
        with tempfile.TemporaryDirectory(prefix="moon-workflow-") as temporary:
            root = Path(temporary)
            environment = root / "boundary.bash"
            environment.write_text(BOUNDARY, encoding="utf-8", newline="\n")
            script = root / "actual-run.bash"
            script.write_text(actual_run_block(name), encoding="utf-8", newline="\n")
            capture = root / "sql.txt"
            env = os.environ.copy()
            env.update(BASH_ENV=environment.as_posix(), SQL_CAPTURE=capture.as_posix(),
                       BOUNDARY_SQL_ERROR=str(int(sql_error)),
                       BOUNDARY_DOCKER_ERROR=str(int(docker_error)))
            result = subprocess.run(
                [BASH, "--noprofile", "--norc", "-e", "-o", "pipefail", script.as_posix()],
                cwd=root, env=env, capture_output=True, text=True, timeout=15)
            sql = capture.read_text(encoding="utf-8") if capture.exists() else ""
            return result, [line.strip() for line in sql.splitlines() if line.strip()]

    def test_complete_e2e_sql_is_forwarded_and_succeeds(self):
        result, sql = self.invoke()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sql, EXPECTED_SQL)

    def test_forwarded_sql_error_fails_the_run_block(self):
        result, sql = self.invoke(sql_error=True)
        self.assertEqual(sql, EXPECTED_SQL)
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)

    def test_docker_error_is_preserved(self):
        result, _ = self.invoke(docker_error=True)
        self.assertEqual(result.returncode, 57)

    def test_preceding_c_query_success_control(self):
        result, sql = self.invoke(name=EXTENSION)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(sql, ["CREATE EXTENSION pg_mooncake CASCADE;",
                              "SELECT extname, extversion FROM pg_extension WHERE extname IN ('pg_duckdb','pg_mooncake');"])

    def test_preceding_c_query_error_control(self):
        result, _ = self.invoke(name=EXTENSION, sql_error=True)
        self.assertEqual(result.returncode, 1)


if __name__ == "__main__":
    unittest.main()

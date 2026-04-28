#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CREDENTIALS="${OPEN_CRM_DB_CREDENTIALS:-${SKILL_DIR}/references/credentials.env}"

if [[ -f "${CREDENTIALS}" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "${CREDENTIALS}"
  set +a
fi

if [[ -z "${DATABASE_URL:-}" ]]; then
  echo "DATABASE_URL is not set. Export it or create ${CREDENTIALS} from references/credentials.env.example." >&2
  exit 1
fi

PSQL_DATABASE_URL="${DATABASE_URL}"
if [[ "${PSQL_DATABASE_URL}" == *"sslmode=verify-full"* && "${PSQL_DATABASE_URL}" != *"sslrootcert="* ]]; then
  if [[ "${PSQL_DATABASE_URL}" == *"?"* ]]; then
    PSQL_DATABASE_URL="${PSQL_DATABASE_URL}&sslrootcert=system"
  else
    PSQL_DATABASE_URL="${PSQL_DATABASE_URL}?sslrootcert=system"
  fi
fi

if ! command -v psql >/dev/null 2>&1; then
  for candidate in /opt/homebrew/opt/libpq/bin /usr/local/opt/libpq/bin; do
    if [[ -x "${candidate}/psql" ]]; then
      PATH="${candidate}:${PATH}"
      break
    fi
  done
fi

if ! command -v psql >/dev/null 2>&1; then
  echo "psql is required but was not found on PATH." >&2
  exit 1
fi

exec psql "${PSQL_DATABASE_URL}" "$@"

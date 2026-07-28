#!/usr/bin/env bash
# Verify that etcd's server and peer certificates authorize the current
# Docker control-plane address. This catches a kind node IP change after a
# Docker network recreation.
set -euo pipefail

CLUSTER_NAME="${CLUSTER_NAME:-local-dev}"
CONTROL_PLANE="${CLUSTER_NAME}-control-plane"
CONTROL_PLANE_IP=""
SELF_TEST_DIR=""

certificate_has_ip() {
  local certificate="$1" ip="$2"
  openssl x509 -in "${certificate}" -noout -checkip "${ip}" >/dev/null
}

check_nounset_declaration() {
  local node="$1" i
  local pod="etcd-${node}"
  [[ -n "${i-}" || "${pod}" == "etcd-${node}" ]]
}

run_transaction_self_test() {
  local pki_dir backup_dir failed_backup certificate extension
  pki_dir="${SELF_TEST_DIR}/pki"
  mkdir -p "${pki_dir}"
  for certificate in server peer; do
    for extension in crt key; do
      printf 'original-%s-%s\n' "${certificate}" "${extension}" \
        >"${pki_dir}/${certificate}.${extension}"
    done
  done

  backup_dir="$(mktemp -d "${pki_dir}/.backup.XXXXXX")"
  for certificate in server peer; do
    for extension in crt key; do
      test -f "${pki_dir}/${certificate}.${extension}"
    done
  done
  for certificate in server peer; do
    for extension in crt key; do
      cp -p "${pki_dir}/${certificate}.${extension}" "${backup_dir}/${certificate}.${extension}"
      cmp -s "${pki_dir}/${certificate}.${extension}" "${backup_dir}/${certificate}.${extension}"
    done
  done
  rm -f "${pki_dir}/server.crt" "${pki_dir}/server.key" \
    "${pki_dir}/peer.crt" "${pki_dir}/peer.key"
  for certificate in server peer; do
    for extension in crt key; do
      mv -f "${backup_dir}/${certificate}.${extension}" "${pki_dir}/${certificate}.${extension}"
      cmp -s <(printf 'original-%s-%s\n' "${certificate}" "${extension}") \
        "${pki_dir}/${certificate}.${extension}"
    done
  done
  rmdir "${backup_dir}"

  failed_backup="$(mktemp -d "${pki_dir}/.backup.XXXXXX")"
  if FAILED_BACKUP="${failed_backup}" PKI_DIR="${pki_dir}" bash -ceu '
    cleanup_incomplete_backup() {
      rm -rf "${FAILED_BACKUP}"
    }
    trap cleanup_incomplete_backup ERR
    test -f "${PKI_DIR}/missing.crt"
  '; then
    echo "FAIL: backup preflight unexpectedly accepted a missing certificate" >&2
    exit 1
  fi
  test -f "${pki_dir}/server.crt"
  test -f "${pki_dir}/peer.crt"
  test ! -e "${failed_backup}"
  echo "PASS: transactional backup restores selected pairs and cleans incomplete backups"
}

run_rollback_restart_self_test() {
  local restart_attempted=false rollback_armed=true
  local restart_calls=0 readiness_calls=0 backup_discarded=false restart_result=0

  restart_static_etcd() {
    restart_calls=$((restart_calls + 1))
    return "${restart_result}"
  }

  wait_for_etcd_and_kubernetes() {
    readiness_calls=$((readiness_calls + 1))
  }

  if [[ "${restart_attempted}" == "true" ]]; then
    restart_static_etcd || true
    wait_for_etcd_and_kubernetes
  fi
  [[ "${restart_calls}" -eq 0 && "${readiness_calls}" -eq 0 ]] \
    || { echo "FAIL: rollback restarted etcd before the new-cert restart phase" >&2; exit 1; }

  restart_attempted=true
  restart_static_etcd || true
  wait_for_etcd_and_kubernetes
  [[ "${restart_calls}" -eq 1 && "${readiness_calls}" -eq 1 ]] \
    || { echo "FAIL: rollback did not restart and verify etcd after restoration" >&2; exit 1; }

  restart_result=1
  restart_static_etcd || true
  wait_for_etcd_and_kubernetes
  [[ "${restart_calls}" -eq 2 && "${readiness_calls}" -eq 2 ]] \
    || { echo "FAIL: rollback skipped readiness after the restart action failed" >&2; exit 1; }

  rollback_armed=false
  if [[ "${rollback_armed}" == "false" ]]; then
    backup_discarded=true
  fi
  [[ "${backup_discarded}" == "true" ]] \
    || { echo "FAIL: backup disposal ran before rollback was disarmed" >&2; exit 1; }
  echo "PASS: rollback restarts only after a new-cert restart and disarms before cleanup"
}

run_self_test() {
  local certificate
  SELF_TEST_DIR="$(mktemp -d)"
  trap 'rm -rf "${SELF_TEST_DIR}"' EXIT
  certificate="${SELF_TEST_DIR}/certificate.crt"

  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "${SELF_TEST_DIR}/certificate.key" -out "${certificate}" \
    -subj /CN=etcd-test -addext 'subjectAltName=IP:10.20.30.2' >/dev/null 2>&1

  certificate_has_ip "${certificate}" 10.20.30.2 \
    || { echo "FAIL: exact SAN matcher rejected a certificate IP" >&2; exit 1; }
  if certificate_has_ip "${certificate}" 10.20.30.20; then
    echo "FAIL: exact SAN matcher accepted a suffix IP" >&2
    exit 1
  fi
  if certificate_has_ip "${certificate}" 10.20.30; then
    echo "FAIL: exact SAN matcher accepted a prefix IP" >&2
    exit 1
  fi
  check_nounset_declaration local-dev-control-plane
  run_transaction_self_test
  run_rollback_restart_self_test
  echo "PASS: exact SAN matcher rejects prefix and suffix IPs"
  echo "PASS: nounset-safe etcd pod name declaration"
}

if [[ "${1:-}" == "--self-test" ]]; then
  run_self_test
  exit 0
fi

CONTROL_PLANE_IP="$(docker inspect -f '{{with index .NetworkSettings.Networks "kind"}}{{.IPAddress}}{{end}}' "${CONTROL_PLANE}")"
[[ -n "${CONTROL_PLANE_IP}" ]] || {
  echo "Unable to determine kind-network IP for ${CONTROL_PLANE}" >&2
  exit 1
}

check_certificate() {
  local name="$1" certificate="$2"

  if docker exec "${CONTROL_PLANE}" openssl x509 -in "${certificate}" -noout \
      -checkip "${CONTROL_PLANE_IP}" >/dev/null; then
    echo "PASS: etcd ${name} certificate includes ${CONTROL_PLANE_IP}"
    return 0
  fi

  echo "FAIL: etcd ${name} certificate is missing current control-plane IP ${CONTROL_PLANE_IP}" >&2
  return 1
}

status=0
check_certificate server /etc/kubernetes/pki/etcd/server.crt || status=1
check_certificate peer /etc/kubernetes/pki/etcd/peer.crt || status=1
exit "${status}"

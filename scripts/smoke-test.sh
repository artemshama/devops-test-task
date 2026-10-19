#!/usr/bin/env bash
set -Eeuo pipefail

NS="devops-demo"
PF_LOG="$(mktemp)"
BODY_FILE="$(mktemp)"
PF_PID=""

cleanup() {
  if [[ -n "$PF_PID" ]]; then
    kill "$PF_PID" 2>/dev/null || true
    wait "$PF_PID" 2>/dev/null || true
  fi
  rm -f "$PF_LOG" "$BODY_FILE"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

command -v kubectl >/dev/null || fail "kubectl не найден"
command -v curl >/dev/null || fail "curl не найден"

echo "========== NAMESPACE =========="
kubectl get namespace "$NS" >/dev/null ||
  fail "namespace отсутствует"
echo "PASS: namespace существует"

echo
echo "========== EXPRESS APP =========="
kubectl -n "$NS" rollout status deployment/express-app --timeout=120s ||
  fail "Express Deployment не готов"

APP_DESIRED="$(kubectl -n "$NS" get deployment express-app -o jsonpath='{.spec.replicas}')"
APP_READY="$(kubectl -n "$NS" get deployment express-app -o jsonpath='{.status.readyReplicas}')"

[[ "$APP_DESIRED" == "3" && "$APP_READY" == "3" ]] ||
  fail "Express: desired=$APP_DESIRED, ready=${APP_READY:-0}"
echo "PASS: 3 из 3 реплик Express готовы"

echo
echo "========== NGINX PROXY =========="
kubectl -n "$NS" rollout status deployment/nginx-proxy --timeout=120s ||
  fail "Nginx Deployment не готов"

PROXY_DESIRED="$(kubectl -n "$NS" get deployment nginx-proxy -o jsonpath='{.spec.replicas}')"
PROXY_READY="$(kubectl -n "$NS" get deployment nginx-proxy -o jsonpath='{.status.readyReplicas}')"

[[ "$PROXY_DESIRED" == "2" && "$PROXY_READY" == "2" ]] ||
  fail "Nginx: desired=$PROXY_DESIRED, ready=${PROXY_READY:-0}"
echo "PASS: 2 из 2 реплик Nginx готовы"

echo
echo "========== HTTP END-TO-END =========="
kubectl -n "$NS" port-forward service/nginx-proxy 18080:8080 >"$PF_LOG" 2>&1 &
PF_PID=$!

HTTP_OK=0
for _ in $(seq 1 30); do
  if ! kill -0 "$PF_PID" 2>/dev/null; then
    cat "$PF_LOG" >&2
    fail "port-forward завершился с ошибкой"
  fi

  if curl --silent --show-error --fail \
    http://127.0.0.1:18080/ -o "$BODY_FILE" 2>/dev/null; then
    HTTP_OK=1
    break
  fi

  sleep 1
done

[[ "$HTTP_OK" == "1" ]] || {
  cat "$PF_LOG" >&2
  fail "HTTP-запрос через прокси не удался"
}

BODY="$(cat "$BODY_FILE")"
[[ "$BODY" == "Hello World!" ]] ||
  fail "неожиданное тело ответа: $BODY"

echo "PASS: прокси вернул Hello World!"
echo
echo "ALL SMOKE TESTS PASSED"

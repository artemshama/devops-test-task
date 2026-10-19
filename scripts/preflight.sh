#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname "$0")/.."

PASS=0
WARN=0
FAIL=0
REPORT="$(mktemp)"
trap 'rm -f "$REPORT"' EXIT

check() {
    local name="$1"
    shift
    printf '\n[CHECK] %s\n' "$name"
    if "$@"; then
        printf '[PASS] %s\n' "$name"
        PASS=$((PASS + 1))
    else
        printf '[FAIL] %s\n' "$name"
        FAIL=$((FAIL + 1))
    fi
}

warn() {
    printf '[WARN] %s\n' "$1"
    WARN=$((WARN + 1))
}

section() {
    printf '\n\n========== %s ==========\n' "$1"
}

section "1. Структура проекта"

for f in \
    README.md .gitignore \
    ansible/ansible.cfg \
    ansible/playbook.yml \
    ansible/requirements.yml \
    ansible/inventory/localhost.yml \
    ansible/inventory/hosts.example.yml \
    ansible/group_vars/all.yml \
    ansible/templates/nginx-site.conf.j2 \
    ansible/files/index.html \
    app/server.js app/package.json \
    app/package-lock.json app/Dockerfile app/.dockerignore \
    proxy/Dockerfile proxy/nginx.conf proxy/.dockerignore \
    kubernetes/00-namespace.yaml \
    kubernetes/10-app-deployment.yaml \
    kubernetes/11-app-service.yaml \
    kubernetes/20-proxy-deployment.yaml \
    kubernetes/21-proxy-service.yaml \
    scripts/preflight.sh \
    scripts/smoke-test.sh
do
    if [ -f "$f" ]; then
        printf '[PASS] %s\n' "$f"
        PASS=$((PASS + 1))
    else
        printf '[FAIL] Отсутствует: %s\n' "$f"
        FAIL=$((FAIL + 1))
    fi
done

if [ -e ansible/group_vars/all.yml.old ]; then
    printf '[FAIL] Старый Vault-бэкап находится внутри проекта\n'
    FAIL=$((FAIL + 1))
fi

section "2. Git и защита секретов"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    check "git diff --check" git diff --check
    check "Проверка staged diff" git diff --cached --check

    if head -n 1 ansible/group_vars/all.yml |
        grep -q '^\$ANSIBLE_VAULT;'; then
        printf '[PASS] Ansible Vault зашифрован\n'
        PASS=$((PASS + 1))
    else
        printf '[FAIL] Ansible Vault не зашифрован\n'
        FAIL=$((FAIL + 1))
    fi

    if git check-ignore -q .venv/; then
        printf '[PASS] .venv исключён из Git\n'
        PASS=$((PASS + 1))
    else
        printf '[FAIL] .venv не исключён из Git\n'
        FAIL=$((FAIL + 1))
    fi

    if git check-ignore -q app/node_modules/; then
        printf '[PASS] node_modules исключён из Git\n'
        PASS=$((PASS + 1))
    else
        printf '[FAIL] node_modules не исключён из Git\n'
        FAIL=$((FAIL + 1))
    fi

    if git ls-files --cached --others --exclude-standard |
        grep -E '(^|/)(\.env($|\.)|vault-password\.txt$|id_ed25519($|[._-])|id_rsa($|[._-])|.*\.pem$|.*\.key$)' |
        grep -q .; then
        printf '[FAIL] Найдены потенциально чувствительные файлы в Git-кандидатах:\n'
        git ls-files --cached --others --exclude-standard |
            grep -E '(^|/)(\.env($|\.)|vault-password\.txt$|id_ed25519($|[._-])|id_rsa($|[._-])|.*\.pem$|.*\.key$)' || true
        FAIL=$((FAIL + 1))
    else
        printf '[PASS] По именам файлов секреты и приватные ключи не обнаружены\n'
        PASS=$((PASS + 1))
    fi

    if git ls-files --cached --others --exclude-standard |
        grep -E '(^|/)(\.venv|node_modules)(/|$)' |
        grep -q .; then
        printf '[FAIL] .venv или node_modules присутствует среди Git-кандидатов\n'
        FAIL=$((FAIL + 1))
    else
        printf '[PASS] В Git-кандидатах нет .venv и node_modules\n'
        PASS=$((PASS + 1))
    fi

    printf '\n--- Git status ---\n'
    git status --short --branch
else
    printf '[FAIL] Каталог не является Git-репозиторием\n'
    FAIL=$((FAIL + 1))
fi

# Дополнительная проверка содержимого файлов-кандидатов на приватные ключи.
if git ls-files --cached --others --exclude-standard |
    grep -v '^ansible/group_vars/all.yml$' |
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        if grep -IqE \
          'BEGIN (OPENSSH|RSA|EC|DSA|ENCRYPTED) PRIVATE KEY|AKIA[0-9A-Z]{16}' \
          "$f"; then
            printf 'Подозрительное содержимое: %s\n' "$f"
            exit 1
        fi
    done
then
    printf '[PASS] Маркеры приватных ключей и AWS access keys не обнаружены\n'
    PASS=$((PASS + 1))
else
    printf '[FAIL] Обнаружены маркеры потенциальных секретов\n'
    FAIL=$((FAIL + 1))
fi

section "3. Ansible"

check "Ansible установлен" .venv/bin/ansible-playbook --version

if ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" \
    .venv/bin/ansible-playbook ansible/playbook.yml \
    --syntax-check --ask-vault-pass; then
    PASS=$((PASS + 1))
    printf '[PASS] Ansible syntax check\n'
else
    FAIL=$((FAIL + 1))
    printf '[FAIL] Ansible syntax check\n'
fi

check "YAML inventory доступен" \
    .venv/bin/ansible-inventory \
    -i ansible/inventory/localhost.yml --list

section "4. Локальный Nginx и SSH"

check "nginx -t" sudo nginx -t
check "Nginx запущен" systemctl is-active --quiet nginx
check "HTML содержит My Nginx Server" \
    bash -c "curl -fsS --max-time 5 http://127.0.0.1/ | grep -Fq 'My Nginx Server'"
check "SSH конфигурация валидна" sudo sshd -t
check "Пользователь carxadmin существует" id carxadmin
check "SSH authorized_keys существует" \
    sudo test -s /home/carxadmin/.ssh/authorized_keys
check "Nginx repository configured" \
    grep -q 'nginx.org/packages/ubuntu' /etc/apt/sources.list.d/nginx.list

root_ssh_policy="$(sudo sshd -T -C user=root,host=localhost,addr=127.0.0.1 2>/dev/null | awk '$1 == "permitrootlogin" {value=$2} END {print value}')"
admin_ssh_policy="$(sudo sshd -T -C user=carxadmin,host=localhost,addr=127.0.0.1 2>/dev/null | awk '$1 == "pubkeyauthentication" {value=$2} END {print value}')"

if [ "$root_ssh_policy" = "no" ]; then
    printf '%s\n' '[PASS] SSH root login запрещён'
    PASS=$((PASS + 1))
else
    printf '%s\n' "[FAIL] SSH root login: получено значение '${root_ssh_policy:-пусто}'"
    FAIL=$((FAIL + 1))
fi

if [ "$admin_ssh_policy" = "yes" ]; then
    printf '%s\n' '[PASS] SSH public-key authentication включена'
    PASS=$((PASS + 1))
else
    printf '%s\n' "[FAIL] SSH public-key authentication: получено значение '${admin_ssh_policy:-пусто}'"
    FAIL=$((FAIL + 1))
fi

section "5. Docker"

if docker info >/dev/null 2>&1; then
    printf '[PASS] Docker daemon доступен\n'
    PASS=$((PASS + 1))
else
    printf '[FAIL] Docker daemon недоступен\n'
    FAIL=$((FAIL + 1))
fi

if docker info >/dev/null 2>&1; then
    if docker build -t devops-test-app:1.0 ./app; then
        PASS=$((PASS + 1))
        printf '[PASS] Сборка Express image\n'
    else
        FAIL=$((FAIL + 1))
        printf '[FAIL] Сборка Express image\n'
    fi

    if docker build -t devops-test-proxy:1.0 ./proxy; then
        PASS=$((PASS + 1))
        printf '[PASS] Сборка Nginx proxy image\n'
    else
        FAIL=$((FAIL + 1))
        printf '[FAIL] Сборка Nginx proxy image\n'
    fi

    check "App image присутствует" \
        docker image inspect devops-test-app:1.0
    check "Proxy image присутствует" \
        docker image inspect devops-test-proxy:1.0
fi

section "6. Kubernetes"

if kubectl cluster-info >/dev/null 2>&1; then
    printf '[PASS] Kubernetes API доступен\n'
    PASS=$((PASS + 1))
else
    printf '[FAIL] Kubernetes API недоступен\n'
    FAIL=$((FAIL + 1))
fi

if kubectl cluster-info >/dev/null 2>&1; then
    check "Проверка Kubernetes manifests" \
        kubectl apply --dry-run=client -f kubernetes/

    check "Namespace devops-demo существует" \
        kubectl get namespace devops-demo

    check "Express rollout" \
        kubectl rollout status deployment/express-app \
        -n devops-demo --timeout=120s

    check "Proxy rollout" \
        kubectl rollout status deployment/nginx-proxy \
        -n devops-demo --timeout=120s

    APP_DESIRED="$(kubectl get deployment express-app -n devops-demo \
        -o jsonpath='{.spec.replicas}')"
    APP_READY="$(kubectl get deployment express-app -n devops-demo \
        -o jsonpath='{.status.readyReplicas}')"
    PROXY_READY="$(kubectl get deployment nginx-proxy -n devops-demo \
        -o jsonpath='{.status.readyReplicas}')"

    if [ "$APP_DESIRED" = 3 ] && [ "$APP_READY" = 3 ]; then
        printf '[PASS] Express replicas: desired=3, ready=3\n'
        PASS=$((PASS + 1))
    else
        printf '[FAIL] Express replicas: desired=%s, ready=%s\n' \
            "$APP_DESIRED" "$APP_READY"
        FAIL=$((FAIL + 1))
    fi

    if [ "$PROXY_READY" = 2 ]; then
        printf '[PASS] Nginx proxy replicas: ready=2\n'
        PASS=$((PASS + 1))
    else
        printf '[FAIL] Nginx proxy ready replicas: %s\n' "$PROXY_READY"
        FAIL=$((FAIL + 1))
    fi

    printf '\n--- Pod status ---\n'
    kubectl get pods -n devops-demo -o wide
    printf '\n--- Services ---\n'
    kubectl get services -n devops-demo
fi

section "7. Сквозной тест"

if bash scripts/smoke-test.sh; then
    printf '[PASS] End-to-end smoke test\n'
    PASS=$((PASS + 1))
else
    printf '[FAIL] End-to-end smoke test\n'
    FAIL=$((FAIL + 1))
fi

section "ИТОГ"

printf 'PASS: %s\nWARN: %s\nFAIL: %s\n' "$PASS" "$WARN" "$FAIL"

if [ "$FAIL" -gt 0 ]; then
    printf '\nАудит НЕ пройден. Исправь все FAIL перед публикацией.\n'
    exit 1
fi

printf '\nВсе автоматические проверки завершились успешно.\n'
printf 'Это не заменяет ручную проверку содержимого Git diff и README.\n'

# DevOps Engineer Test Task

Решение тестового задания DevOps Engineer: настройка Nginx через Ansible,
контейнеризация ExpressJS-приложения и развёртывание приложения за Nginx
в Kubernetes.

## Структура проекта

- `ansible/` — playbook настройки сервера, inventory, шаблон Nginx и HTML.
- `app/` — ExpressJS Hello World и Dockerfile приложения.
- `proxy/` — Dockerfile и конфигурация Nginx-прокси.
- `kubernetes/` — Namespace, Deployment и Service приложения и прокси.
- `scripts/smoke-test.sh` — проверка развёртывания и HTTP-ответа через прокси.

## 1. Ansible

Требования: Ubuntu 24.04, Python, Ansible и SSH-ключ для пользователя
`carxadmin`. Playbook рассчитан на локальный запуск в Ubuntu/WSL.

Установить зависимости Ansible:

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip ansible
ansible-galaxy collection install -r ansible/requirements.yml
```

Перед запуском убедитесь, что на управляющей машине существует публичный
SSH-ключ `~/.ssh/id_ed25519_carxadmin.pub`. Если ключа нет, создайте его:

```bash
test -f ~/.ssh/id_ed25519_carxadmin.pub || ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_carxadmin -C carxadmin
```

Не перезаписывайте существующий ключ, если он уже используется.


Playbook использует зашифрованные Ansible Vault переменные из
`ansible/group_vars/all.yml`. Пароль Vault необходимо получить из
безопасного источника и не хранить в репозитории.

Проверить синтаксис:

```bash
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook ansible/playbook.yml --syntax-check --ask-vault-pass
```

Запустить настройку сервера с запросом пароля Vault:

```bash
ANSIBLE_CONFIG="$PWD/ansible/ansible.cfg" ansible-playbook ansible/playbook.yml --ask-vault-pass
```

Playbook обновляет пакеты ОС, подключает официальный репозиторий Nginx,
устанавливает Nginx, настраивает сайт с текстом `My Nginx Server`,
создаёт пользователя `carxadmin`, устанавливает его публичный SSH-ключ
и запрещает SSH-вход для root.

Для удалённого сервера следует подготовить отдельный inventory и проверить
переменные подключения перед запуском.

## 2. Сборка Docker-образов

Из корня проекта:

```bash
docker build -t devops-test-app:1.0 ./app
docker build -t devops-test-proxy:1.0 ./proxy
```

Приложение использует Node.js и ExpressJS. Контейнер приложения работает
от непривилегированного пользователя. Nginx-прокси использует образ
`nginxinc/nginx-unprivileged` и слушает порт 8080.

## 3. Развёртывание Kubernetes

Требуется работающий Kubernetes-кластер и доступная ему версия Docker-образов
`devops-test-app:1.0` и `devops-test-proxy:1.0`.

Для локального Docker Desktop с Kubernetes образы должны быть доступны
локальному кластеру. Для удалённого кластера образы необходимо загрузить
в registry и указать соответствующие адреса в Deployment.

Применить манифесты из корня проекта:

```bash
kubectl apply -f kubernetes/00-namespace.yaml
kubectl apply -f kubernetes/10-app-deployment.yaml
kubectl apply -f kubernetes/11-app-service.yaml
kubectl apply -f kubernetes/20-proxy-deployment.yaml
kubectl apply -f kubernetes/21-proxy-service.yaml
```

Проверить состояние:

```bash
kubectl -n devops-demo rollout status deployment/express-app
kubectl -n devops-demo rollout status deployment/nginx-proxy
kubectl -n devops-demo get deployments,pods,services
```

Приложение разворачивается с тремя репликами в namespace `devops-demo`.
Nginx-прокси разворачивается отдельно и обращается к приложению через
внутренний Kubernetes Service `express-app`.

## 4. Проверка HTTP через прокси

Запустить локальный проброс порта:

```bash
kubectl -n devops-demo port-forward service/nginx-proxy 18080:8080
```

В другом терминале выполнить:

```bash
curl -i http://127.0.0.1:18080/
```

Ожидаемый результат: HTTP 200 и тело ответа `Hello World!`.

Перед публикацией выполните полный набор проверок проекта:

```bash
./scripts/preflight.sh
```

Скрипт проверяет файлы проекта, Ansible, локальный Nginx и SSH, сборку Docker-образов, состояние Kubernetes и HTTP-запрос через прокси. Для Ansible потребуется пароль Vault; некоторые системные проверки могут запросить пароль `sudo`.

Для отдельной проверки уже развёрнутого приложения:

```bash
bash scripts/smoke-test.sh
```

## Безопасность

- Не публиковать пароль Ansible Vault, его файл, приватные SSH-ключи или
  незашифрованные секреты.
- Не добавлять в репозиторий `.venv`, `node_modules` и локальные файлы среды.
- Для удалённого использования Kubernetes следует применять registry,
  доступный кластеру, и подходящую политику управления образами.

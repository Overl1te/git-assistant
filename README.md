# Git Assistant with AI

Веб-система для автоматического коммита и пуша изменений в git-репозиториях с проверкой тестов, AI-сообщениями коммита (Ollama) и статусом GitHub Actions.

**Целевое железо:** Intel Core i3 (AVX2), 16 ГБ RAM, Ubuntu 22.04. LLM работает на CPU через Ollama (`qwen2.5-coder:3b`). GPU (GT 1030) не используется для модели.

## Возможности

- Dashboard со списком проектов из `config.yaml` (ветка, dirty/clean)
- **Smart Commit** — pull (опционально) → тесты → AI commit message → commit → push → проверка Actions
- **Force Commit** — то же без тестов (с предупреждением)
- **Pull** — `git pull --rebase`
- Live-логи через Server-Sent Events (SSE)
- Fallback-сообщение коммита, если Ollama недоступна: `Auto-commit: {дата}`

## Структура

```
git-assistant/
├── app.py                 # FastAPI + SSE
├── git_assistant.py       # Бизнес-логика
├── config.yaml            # Проекты и глобальные настройки
├── requirements.txt
├── templates/index.html
├── static/style.css
├── install.sh
└── README.md
```

## Требования

- Python 3.10+
- Git
- Ollama (для AI-сообщений; без неё работает fallback)
- Опционально: `GITHUB_TOKEN` для статуса Actions

---

## Установка (рекомендуется — TUI)

На Ubuntu 22.04+ достаточно одного скрипта — он спросит всё через меню (whiptail) и настроит сам:

```bash
cd /opt/git-assistant   # или путь к клону
chmod +x install.sh
./install.sh
```

Мастер устанавливает и настраивает:

1. Системные пакеты (`python3-venv`, `git`, `whiptail`, …)
2. Python venv + зависимости из `requirements.txt`
3. `config.yaml` — проекты через TUI (путь, тесты, ветка, repo)
4. Ollama + скачивание модели (по желанию)
5. `GITHUB_TOKEN` в `/etc/git-assistant.env` (по желанию)
6. systemd-сервис `git-assistant` (enable + start)
7. Порт в UFW (если firewall активен и выбран LAN-доступ)
8. Лог `/var/log/git-assistant.log`

После установки:

```bash
systemctl status git-assistant
# LAN:  http://<ip-сервера>:8080
# SSH:  ssh -L 8080:127.0.0.1:8080 user@server
journalctl -u git-assistant -f
```

Переустановка / смена настроек: снова запустите `./install.sh` (перезапишет config, env и unit).

### Ручная донастройка проектов

Добавить/править проекты можно и вручную в `config.yaml`:

```yaml
projects:
  - name: "backend"
    path: "/home/user/projects/backend"
    test_command: "pytest"
    test_timeout: 300
    auto_pull: true
    github_repo: "username/backend"
    branch: "main"
    model: "qwen2.5-coder:3b"

  - name: "frontend"
    path: "/home/user/projects/frontend"
    test_command: "npm test"
    test_timeout: 120
    auto_pull: false
    github_repo: "username/frontend"
    branch: "develop"

global:
  ollama_url: "http://localhost:11434"
  default_model: "qwen2.5-coder:3b"
  github_token_env: "GITHUB_TOKEN"
  log_file: "/var/log/git-assistant.log"
```

Поддерживаемые примеры `test_command`: `pytest`, `npm test`, `go test ./...`, `cargo test`, `make test`.

После правки config:

```bash
sudo systemctl restart git-assistant
```

### Переменные окружения

Файл `/etc/git-assistant.env` (создаёт installer):

```bash
GIT_ASSISTANT_HOST=0.0.0.0   # или 127.0.0.1 для tunnel-only
GIT_ASSISTANT_PORT=8080
GITHUB_TOKEN=ghp_xxxxxxxxxxxx
```

Токену достаточно scope `repo` / `actions:read`.

### Ручной запуск (без systemd)

```bash
source .venv/bin/activate
export GIT_ASSISTANT_HOST=0.0.0.0 GIT_ASSISTANT_PORT=8080
python3 app.py
```

### Ollama отдельно (если пропустили в мастере)

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull qwen2.5-coder:3b
curl http://localhost:11434/api/tags
```

### Nginx (опционально)

Если нужен доступ снаружи с паролем — проксируйте на порт сервиса с basic auth:

```nginx
server {
    listen 80;
    server_name git-assistant.example.com;

    auth_basic "Git Assistant";
    auth_basic_user_file /etc/nginx/.htpasswd;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header Connection "";
        proxy_buffering off;
        proxy_cache off;
        proxy_read_timeout 3600s;
    }
}
```

```bash
sudo apt install apache2-utils
sudo htpasswd -c /etc/nginx/.htpasswd admin
sudo nginx -t && sudo systemctl reload nginx
```

`proxy_buffering off` важен для SSE.

---

## Размещение файлов

На сервере Ubuntu:

```bash
sudo mkdir -p /opt/git-assistant
sudo chown "$USER":"$USER" /opt/git-assistant
# скопируйте файлы репозитория в /opt/git-assistant
cd /opt/git-assistant
./install.sh
```

На Windows (разработка):

```text
C:\Users\<you>\Documents\GitHub\git-assistant
```

---

## Использование

1. Откройте dashboard.
2. Нажмите **Обновить статус**, если нужно.
3. Если есть изменения — активны **Smart Commit** / **Force Commit**.
4. Следите за live-логами внизу страницы.
5. После завершения смотрите статус, сообщение коммита, вывод тестов и Actions.

### Пайплайн Smart Commit

1. Проверка наличия изменений
2. `git pull --rebase` (если `auto_pull: true`)
3. Запуск `test_command` (таймаут из конфига)
4. Генерация Conventional Commits через Ollama
5. `git add .` → `git commit` → проверка конфликтов → `git push`
6. Если есть `.github/workflows/` — пауза 30 с и запрос статуса Actions

Если тесты упали — коммит **не** создаётся; в UI показываются первые 50 строк вывода с кнопкой «Показать всё».

---

## API

| Метод | Путь | Описание |
|-------|------|----------|
| GET | `/` | Dashboard |
| GET | `/api/projects` | Статусы всех проектов |
| POST | `/api/projects/{name}/refresh` | Обновить один проект |
| POST | `/api/projects/{name}/smart-commit` | Старт Smart Commit → `{job_id}` |
| POST | `/api/projects/{name}/force-commit` | Старт Force Commit → `{job_id}` |
| POST | `/api/projects/{name}/pull` | Старт pull → `{job_id}` |
| GET | `/api/jobs/{job_id}` | Статус/результат job |
| GET | `/api/jobs/{job_id}/events` | SSE-лог |

Второй job для того же проекта возвращает **409**.

---

## Troubleshooting

### Ollama недоступна / пустое сообщение

- Убедитесь, что сервис запущен: `systemctl status ollama` или `ollama serve`
- Проверьте URL в `global.ollama_url`
- Модель скачана: `ollama list`
- При недоступности AI используется fallback `Auto-commit: …` — коммит всё равно пройдёт

### Permission denied на path проекта

- Пользователь, под которым крутится `git-assistant`, должен иметь права на каталог репозитория
- Проверьте `path` в `config.yaml` (абсолютный путь)

### git push / pull требует пароль или SSH

- Настройте SSH-ключ или credential helper заранее
- Для HTTPS: Personal Access Token вместо пароля

### Конфликт при rebase

- Assistant выполнит `git rebase --abort` и остановит пайплайн
- Разрешите конфликт вручную в репозитории, затем повторите

### Тесты падают / timeout

- Увеличьте `test_timeout` в `config.yaml`
- Запустите `test_command` вручную из корня проекта
- Для Force Commit тесты пропускаются (осознанно)

### GitHub Actions: 401 / unknown

- Проверьте `export GITHUB_TOKEN=...` и имя переменной в `github_token_env`
- `github_repo` должен быть в формате `owner/repo`
- Без `.github/workflows/` проверка пропускается

### SSE не обновляется за Nginx

- Добавьте `proxy_buffering off;` и длинный `proxy_read_timeout`
- Заголовок `X-Accel-Buffering: no` уже выставляется приложением

### Порт 8080 занят

- Смените `GIT_ASSISTANT_PORT` в `/etc/git-assistant.env` и перезапустите: `sudo systemctl restart git-assistant`
- Или снова запустите `./install.sh` и укажите другой порт

### Лог-файл не создаётся

```bash
sudo mkdir -p /var/log
sudo touch /var/log/git-assistant.log
sudo chown "$USER":"$USER" /var/log/git-assistant.log
```

Или укажите относительный путь `./git-assistant.log` в `config.yaml`.

---

## Лицензия

MIT — используйте свободно для личной автоматизации git-рутины.

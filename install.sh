#!/usr/bin/env bash
# Git Assistant with AI — interactive TUI installer (Ubuntu 22.04+)
# Usage: chmod +x install.sh && ./install.sh
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_DIR="${APP_DIR}/.venv"
SERVICE_NAME="git-assistant"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
ENV_FILE="/etc/git-assistant.env"
LOG_FILE="/var/log/git-assistant.log"
CONFIG_FILE="${APP_DIR}/config.yaml"
RUN_USER="$(id -un)"
RUN_UID="$(id -u)"
RUN_GID="$(id -g)"
BACKTITLE="Git Assistant with AI — Installer"

# Collected settings
GA_HOST="0.0.0.0"
GA_PORT="8080"
OLLAMA_URL="http://localhost:11434"
DEFAULT_MODEL="qwen2.5-coder:3b"
INSTALL_OLLAMA="yes"
PULL_MODEL="yes"
SETUP_SYSTEMD="yes"
START_SERVICE="yes"
OPEN_UFW="no"
GITHUB_TOKEN=""
# Projects stored as lines: name|path|test_command|test_timeout|auto_pull|github_repo|branch|model
PROJECT_LINES=()

die() {
  echo "ERROR: $*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1
}

ensure_root_helper() {
  if [[ "${EUID}" -eq 0 ]]; then
    return 0
  fi
  if ! need_cmd sudo; then
    die "Нужен sudo для установки системных пакетов и systemd"
  fi
  sudo -v || die "Не удалось получить права sudo"
}

run_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# --- UI helpers (whiptail / dialog / fallback) ---
UI_ENGINE=""

detect_ui() {
  if need_cmd whiptail; then
    UI_ENGINE="whiptail"
  elif need_cmd dialog; then
    UI_ENGINE="dialog"
  else
    UI_ENGINE="fallback"
  fi
}

ui_msg() {
  local title="$1"
  local text="$2"
  local height="${3:-12}"
  local width="${4:-70}"
  case "${UI_ENGINE}" in
    whiptail) whiptail --backtitle "${BACKTITLE}" --title "${title}" --msgbox "${text}" "${height}" "${width}" ;;
    dialog) dialog --backtitle "${BACKTITLE}" --title "${title}" --msgbox "${text}" "${height}" "${width}" ;;
    *)
      echo ""
      echo "=== ${title} ==="
      echo "${text}"
      echo ""
      read -r -p "Enter для продолжения..." _
      ;;
  esac
}

ui_yesno() {
  local title="$1"
  local text="$2"
  local height="${3:-10}"
  local width="${4:-70}"
  case "${UI_ENGINE}" in
    whiptail) whiptail --backtitle "${BACKTITLE}" --title "${title}" --yesno "${text}" "${height}" "${width}" ;;
    dialog) dialog --backtitle "${BACKTITLE}" --title "${title}" --yesno "${text}" "${height}" "${width}" ;;
    *)
      echo ""
      echo "=== ${title} ==="
      echo "${text}"
      read -r -p "Да/Нет [y/N]: " ans
      [[ "${ans}" =~ ^[YyДд] ]]
      ;;
  esac
}

ui_input() {
  local title="$1"
  local text="$2"
  local default="${3:-}"
  local height="${4:-10}"
  local width="${5:-70}"
  local result=""
  case "${UI_ENGINE}" in
    whiptail)
      result="$(whiptail --backtitle "${BACKTITLE}" --title "${title}" --inputbox "${text}" "${height}" "${width}" "${default}" 3>&1 1>&2 2>&3)" || return 1
      ;;
    dialog)
      result="$(dialog --backtitle "${BACKTITLE}" --title "${title}" --inputbox "${text}" "${height}" "${width}" "${default}" 3>&1 1>&2 2>&3)" || return 1
      ;;
    *)
      echo ""
      echo "=== ${title} ==="
      echo "${text}"
      read -r -p "[${default}]: " result
      result="${result:-$default}"
      ;;
  esac
  printf '%s' "${result}"
}

ui_password() {
  local title="$1"
  local text="$2"
  local height="${3:-10}"
  local width="${4:-70}"
  local result=""
  case "${UI_ENGINE}" in
    whiptail)
      result="$(whiptail --backtitle "${BACKTITLE}" --title "${title}" --passwordbox "${text}" "${height}" "${width}" 3>&1 1>&2 2>&3)" || return 1
      ;;
    dialog)
      result="$(dialog --backtitle "${BACKTITLE}" --title "${title}" --passwordbox "${text}" "${height}" "${width}" 3>&1 1>&2 2>&3)" || return 1
      ;;
    *)
      echo ""
      echo "=== ${title} ==="
      echo "${text}"
      read -r -s -p "Token: " result
      echo ""
      ;;
  esac
  printf '%s' "${result}"
}

ui_menu() {
  local title="$1"
  local text="$2"
  local height="$3"
  local width="$4"
  local menu_height="$5"
  shift 5
  case "${UI_ENGINE}" in
    whiptail)
      whiptail --backtitle "${BACKTITLE}" --title "${title}" --menu "${text}" "${height}" "${width}" "${menu_height}" "$@" 3>&1 1>&2 2>&3
      ;;
    dialog)
      dialog --backtitle "${BACKTITLE}" --title "${title}" --menu "${text}" "${height}" "${width}" "${menu_height}" "$@" 3>&1 1>&2 2>&3
      ;;
    *)
      echo ""
      echo "=== ${title} ==="
      echo "${text}"
      local i=1
      local keys=()
      while [[ $# -ge 2 ]]; do
        keys+=("$1")
        echo "  $1) $2"
        shift 2
        i=$((i + 1))
      done
      read -r -p "Выбор: " choice
      printf '%s' "${choice}"
      ;;
  esac
}

ui_checklist() {
  local title="$1"
  local text="$2"
  local height="$3"
  local width="$4"
  local list_height="$5"
  shift 5
  case "${UI_ENGINE}" in
    whiptail)
      whiptail --backtitle "${BACKTITLE}" --title "${title}" --checklist "${text}" "${height}" "${width}" "${list_height}" "$@" 3>&1 1>&2 2>&3
      ;;
    dialog)
      dialog --backtitle "${BACKTITLE}" --title "${title}" --checklist "${text}" "${height}" "${width}" "${list_height}" "$@" 3>&1 1>&2 2>&3
      ;;
    *)
      # fallback: return all ON tags
      local out=()
      while [[ $# -ge 3 ]]; do
        [[ "$3" == "ON" ]] && out+=("$1")
        shift 3
      done
      printf '%s' "${out[*]}"
      ;;
  esac
}

# --- Install steps ---

install_system_packages() {
  echo "[*] Проверка системных пакетов..."
  local pkgs=()
  need_cmd python3 || pkgs+=(python3)
  python3 -c "import venv" 2>/dev/null || pkgs+=(python3-venv)
  need_cmd pip3 || pkgs+=(python3-pip)
  need_cmd git || pkgs+=(git)
  need_cmd curl || pkgs+=(curl)
  need_cmd whiptail || need_cmd dialog || pkgs+=(whiptail)

  if [[ ${#pkgs[@]} -gt 0 ]]; then
    echo "[*] Установка: ${pkgs[*]}"
    run_root apt-get update -y
    run_root DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  fi
  detect_ui
}

welcome() {
  ui_msg "Добро пожаловать" \
"Этот мастер установит Git Assistant with AI:

• Python venv + зависимости
• config.yaml (проекты через TUI)
• Ollama + модель (опционально)
• systemd-сервис (автозапуск)
• лог-файл и EnvironmentFile для токена

Каталог: ${APP_DIR}
Пользователь сервиса: ${RUN_USER}

Дальше ответьте на несколько вопросов." 16 72
}

ask_network() {
  local choice
  choice="$(ui_menu "Сеть" "Как слушать веб-интерфейс?" 14 70 3 \
    "lan" "0.0.0.0 — доступ по локальному IP (LAN)" \
    "local" "127.0.0.1 — только localhost / SSH-туннель" \
    "custom" "Указать host вручную")" || die "Отменено"

  case "${choice}" in
    lan) GA_HOST="0.0.0.0" ;;
    local) GA_HOST="127.0.0.1" ;;
    custom)
      GA_HOST="$(ui_input "Host" "IP или hostname для bind:" "0.0.0.0")" || die "Отменено"
      ;;
  esac

  GA_PORT="$(ui_input "Порт" "TCP-порт веб-UI:" "8080")" || die "Отменено"
  [[ "${GA_PORT}" =~ ^[0-9]+$ ]] || die "Некорректный порт: ${GA_PORT}"
}

ask_model() {
  local choice
  choice="$(ui_menu "Модель Ollama" "Какую модель использовать по умолчанию?\n(3b — быстрее на 16 ГБ RAM)" 14 70 3 \
    "3b" "qwen2.5-coder:3b (рекомендуется)" \
    "7b" "qwen2.5-coder:7b (если хватает RAM)" \
    "custom" "Указать имя модели вручную")" || die "Отменено"

  case "${choice}" in
    3b) DEFAULT_MODEL="qwen2.5-coder:3b" ;;
    7b) DEFAULT_MODEL="qwen2.5-coder:7b" ;;
    custom)
      DEFAULT_MODEL="$(ui_input "Модель" "Имя модели Ollama:" "qwen2.5-coder:3b")" || die "Отменено"
      ;;
  esac

  OLLAMA_URL="$(ui_input "Ollama URL" "URL API Ollama:" "http://localhost:11434")" || die "Отменено"

  if ui_yesno "Ollama" "Установить Ollama, если ещё не установлена?"; then
    INSTALL_OLLAMA="yes"
  else
    INSTALL_OLLAMA="no"
  fi

  if ui_yesno "Модель" "Скачать модель ${DEFAULT_MODEL} сейчас?\n(может занять время)"; then
    PULL_MODEL="yes"
  else
    PULL_MODEL="no"
  fi
}

ask_token() {
  if ui_yesno "GitHub Token" "Добавить GITHUB_TOKEN для проверки Actions?\n(можно пропустить — Enter/Нет)"; then
    GITHUB_TOKEN="$(ui_password "GitHub Token" "Вставьте Personal Access Token\n(не отображается):")" || GITHUB_TOKEN=""
  else
    GITHUB_TOKEN=""
  fi
}

ask_projects() {
  PROJECT_LINES=()
  ui_msg "Проекты" \
"Сейчас добавьте git-репозитории, которыми будет управлять Assistant.

Для каждого укажите путь, команду тестов, ветку и т.д.
Можно добавить несколько проектов подряд.
Если пока нечего добавлять — нажмите «Нет» и отредактируйте config.yaml позже." 14 72

  while true; do
    if ! ui_yesno "Проект" "Добавить проект?\nУже добавлено: ${#PROJECT_LINES[@]}"; then
      break
    fi

    local name path test_command test_timeout auto_pull github_repo branch model
    name="$(ui_input "Имя проекта" "Короткое имя (например backend):" "backend")" || continue
    path="$(ui_input "Путь" "Абсолютный путь к git-репозиторию:" "/home/${RUN_USER}/projects/${name}")" || continue
    test_command="$(ui_input "Тесты" "Команда тестов (пусто = без тестов):" "pytest")" || continue
    test_timeout="$(ui_input "Таймаут тестов" "Секунды:" "300")" || continue
    branch="$(ui_input "Ветка" "Ветка для push/pull:" "main")" || continue
    github_repo="$(ui_input "GitHub repo" "owner/repo (пусто = без Actions):" "")" || true
    github_repo="${github_repo:-}"
    model="$(ui_input "Модель" "Модель для этого проекта (пусто = default):" "${DEFAULT_MODEL}")" || true
    model="${model:-$DEFAULT_MODEL}"

    if ui_yesno "auto_pull" "Делать git pull --rebase перед коммитом?"; then
      auto_pull="true"
    else
      auto_pull="false"
    fi

    [[ "${test_timeout}" =~ ^[0-9]+$ ]] || test_timeout="300"

    PROJECT_LINES+=("${name}|${path}|${test_command}|${test_timeout}|${auto_pull}|${github_repo}|${branch}|${model}")
  done

  if [[ ${#PROJECT_LINES[@]} -eq 0 ]]; then
    ui_msg "Проекты" "Проекты не добавлены.\nБудет записан пустой список — добавьте их в config.yaml позже." 10 70
  fi
}

ask_service_options() {
  if ui_yesno "systemd" "Установить и включить systemd-сервис\n(автозапуск при загрузке)?"; then
    SETUP_SYSTEMD="yes"
    if ui_yesno "Запуск" "Запустить сервис сразу после установки?"; then
      START_SERVICE="yes"
    else
      START_SERVICE="no"
    fi
  else
    SETUP_SYSTEMD="no"
    START_SERVICE="no"
  fi

  if [[ "${GA_HOST}" == "0.0.0.0" ]] && need_cmd ufw; then
    if ui_yesno "UFW" "Открыть порт ${GA_PORT}/tcp в UFW (если firewall активен)?"; then
      OPEN_UFW="yes"
    else
      OPEN_UFW="no"
    fi
  fi
}

yaml_escape() {
  # Minimal escape for double-quoted YAML strings
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

write_config() {
  echo "[*] Запись ${CONFIG_FILE}"
  {
    echo "# Generated by install.sh — $(date -Iseconds)"
    if [[ ${#PROJECT_LINES[@]} -eq 0 ]]; then
      echo "projects: []"
    else
      echo "projects:"
      local line name path test_command test_timeout auto_pull github_repo branch model
      for line in "${PROJECT_LINES[@]}"; do
        IFS='|' read -r name path test_command test_timeout auto_pull github_repo branch model <<<"${line}"
        echo "  - name: \"$(yaml_escape "${name}")\""
        echo "    path: \"$(yaml_escape "${path}")\""
        echo "    test_command: \"$(yaml_escape "${test_command}")\""
        echo "    test_timeout: ${test_timeout}"
        echo "    auto_pull: ${auto_pull}"
        echo "    github_repo: \"$(yaml_escape "${github_repo}")\""
        echo "    branch: \"$(yaml_escape "${branch}")\""
        echo "    model: \"$(yaml_escape "${model}")\""
      done
    fi
    echo ""
    echo "global:"
    echo "  ollama_url: \"$(yaml_escape "${OLLAMA_URL}")\""
    echo "  default_model: \"$(yaml_escape "${DEFAULT_MODEL}")\""
    echo "  github_token_env: \"GITHUB_TOKEN\""
    echo "  log_file: \"${LOG_FILE}\""
  } >"${CONFIG_FILE}"
}

setup_venv() {
  echo "[*] Создание virtualenv..."
  python3 -m venv "${VENV_DIR}"
  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
  echo "[*] Установка Python-зависимостей..."
  pip install --upgrade pip
  pip install -r "${APP_DIR}/requirements.txt"
}

setup_log() {
  echo "[*] Настройка лог-файла ${LOG_FILE}"
  run_root touch "${LOG_FILE}"
  run_root chown "${RUN_UID}:${RUN_GID}" "${LOG_FILE}"
  run_root chmod 644 "${LOG_FILE}"
}

setup_env_file() {
  echo "[*] Запись ${ENV_FILE}"
  local tmp
  tmp="$(mktemp)"
  {
    echo "# Managed by Git Assistant installer"
    echo "GIT_ASSISTANT_HOST=${GA_HOST}"
    echo "GIT_ASSISTANT_PORT=${GA_PORT}"
    if [[ -n "${GITHUB_TOKEN}" ]]; then
      echo "GITHUB_TOKEN=${GITHUB_TOKEN}"
    fi
  } >"${tmp}"
  run_root install -m 600 -o root -g root "${tmp}" "${ENV_FILE}"
  # Allow service user to read env file
  run_root chown "root:${RUN_GID}" "${ENV_FILE}"
  run_root chmod 640 "${ENV_FILE}"
  rm -f "${tmp}"
}

setup_ollama() {
  if [[ "${INSTALL_OLLAMA}" == "yes" ]]; then
    if need_cmd ollama; then
      echo "[*] Ollama уже установлена"
    else
      echo "[*] Установка Ollama..."
      curl -fsSL https://ollama.com/install.sh | run_root sh
    fi
    if need_cmd systemctl; then
      run_root systemctl enable --now ollama 2>/dev/null || true
    fi
  fi

  if [[ "${PULL_MODEL}" == "yes" ]]; then
    if need_cmd ollama; then
      echo "[*] Скачивание модели ${DEFAULT_MODEL} (это может занять время)..."
      ollama pull "${DEFAULT_MODEL}" || echo "[!] Не удалось скачать модель — можно позже: ollama pull ${DEFAULT_MODEL}"
    else
      echo "[!] ollama не найдена — пропуск pull модели"
    fi
  fi
}

setup_systemd() {
  [[ "${SETUP_SYSTEMD}" == "yes" ]] || return 0
  need_cmd systemctl || die "systemctl не найден — systemd недоступен"

  echo "[*] Установка systemd unit ${SERVICE_FILE}"
  local tmp
  tmp="$(mktemp)"
  cat >"${tmp}" <<EOF
[Unit]
Description=Git Assistant with AI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=$(id -gn)
WorkingDirectory=${APP_DIR}
EnvironmentFile=-${ENV_FILE}
Environment=PATH=${VENV_DIR}/bin:/usr/local/bin:/usr/bin
ExecStart=${VENV_DIR}/bin/python ${APP_DIR}/app.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  run_root install -m 644 "${tmp}" "${SERVICE_FILE}"
  rm -f "${tmp}"

  run_root systemctl daemon-reload
  run_root systemctl enable "${SERVICE_NAME}"

  if [[ "${START_SERVICE}" == "yes" ]]; then
    echo "[*] Запуск ${SERVICE_NAME}..."
    run_root systemctl restart "${SERVICE_NAME}"
    sleep 1
    run_root systemctl --no-pager --full status "${SERVICE_NAME}" || true
  fi
}

setup_ufw() {
  [[ "${OPEN_UFW}" == "yes" ]] || return 0
  if need_cmd ufw && run_root ufw status 2>/dev/null | grep -qi "Status: active"; then
    echo "[*] UFW: разрешаю ${GA_PORT}/tcp"
    run_root ufw allow "${GA_PORT}/tcp" comment "Git Assistant" || true
  else
    echo "[*] UFW не активен — правило не добавлялось"
  fi
}

primary_lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

show_summary() {
  local ip
  ip="$(primary_lan_ip)"
  ip="${ip:-<server-ip>}"

  local urls=""
  urls+="• Локально:  http://127.0.0.1:${GA_PORT}\n"
  if [[ "${GA_HOST}" == "0.0.0.0" ]]; then
    urls+="• По LAN:    http://${ip}:${GA_PORT}\n"
  fi
  urls+="• SSH tunnel: ssh -L ${GA_PORT}:127.0.0.1:${GA_PORT} ${RUN_USER}@${ip}\n"

  local svc=""
  if [[ "${SETUP_SYSTEMD}" == "yes" ]]; then
    svc="systemd: systemctl status ${SERVICE_NAME}
логи:     journalctl -u ${SERVICE_NAME} -f
конфиг:   ${CONFIG_FILE}
env:      ${ENV_FILE}"
  else
    svc="Запуск вручную:
  source ${VENV_DIR}/bin/activate
  python3 ${APP_DIR}/app.py"
  fi

  ui_msg "Готово" \
"Установка завершена.

Доступ:
${urls}
${svc}

Полезные команды:
  systemctl restart ${SERVICE_NAME}
  ollama list
  journalctl -u ${SERVICE_NAME} -n 100" 20 74

  echo ""
  echo "=========================================="
  echo " Git Assistant установлен"
  echo " LAN: http://${ip}:${GA_PORT}"
  echo " Local: http://127.0.0.1:${GA_PORT}"
  echo " systemctl status ${SERVICE_NAME}"
  echo "=========================================="
}

confirm_install() {
  local summary
  summary="Host: ${GA_HOST}
Port: ${GA_PORT}
Model: ${DEFAULT_MODEL}
Ollama install: ${INSTALL_OLLAMA}
Pull model: ${PULL_MODEL}
Projects: ${#PROJECT_LINES[@]}
systemd: ${SETUP_SYSTEMD}
Start now: ${START_SERVICE}
Token: $([[ -n "${GITHUB_TOKEN}" ]] && echo set || echo skip)

Продолжить установку?"
  ui_yesno "Подтверждение" "${summary}" 18 70 || die "Установка отменена"
}

main() {
  cd "${APP_DIR}"
  ensure_root_helper
  install_system_packages
  detect_ui

  welcome
  ask_network
  ask_model
  ask_token
  ask_projects
  ask_service_options
  confirm_install

  write_config
  setup_venv
  setup_log
  setup_env_file
  setup_ollama
  setup_systemd
  setup_ufw
  show_summary
}

main "$@"

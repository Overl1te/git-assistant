#!/usr/bin/env bash
# Git Assistant with AI — консольный TUI-установщик (Ubuntu 22.04+)
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
INSTALL_GH="yes"
# Projects: name|path|test_command|test_timeout|auto_pull|github_repo|branch|model
PROJECT_LINES=()

# --- Colors (OverVPN-style) ---
if [[ -t 1 ]] && [[ "${TERM:-}" != "dumb" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_GREEN=$'\033[38;5;82m'
  C_BLUE=$'\033[38;5;39m'
  C_CYAN=$'\033[38;5;51m'
  C_RED=$'\033[38;5;196m'
  C_YELLOW=$'\033[38;5;220m'
  C_WHITE=$'\033[97m'
  C_GRAY=$'\033[38;5;245m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_GREEN=""; C_BLUE=""; C_CYAN=""
  C_RED=""; C_YELLOW=""; C_WHITE=""; C_GRAY=""
fi

BOX_W=62

die() {
  echo -e "${C_RED}ERROR: $*${C_RESET}" >&2
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

# --- Console TUI primitives ---

clear_screen() {
  printf '\033[2J\033[H'
}

# Strip ANSI for visible length
_vis_len() {
  local s="$1"
  # shellcheck disable=SC2001
  s="$(printf '%s' "$s" | sed 's/\x1b\[[0-9;]*m//g')"
  printf '%s' "${#s}"
}

_pad_line() {
  local content="$1"
  local width="${2:-$BOX_W}"
  local inner=$((width - 2))
  local vis
  vis="$(_vis_len "$content")"
  local pad=$((inner - vis))
  [[ $pad -lt 0 ]] && pad=0
  printf '%s│%s%*s%s│%s\n' "${C_BLUE}" "${content}" "${pad}" "" "${C_BLUE}" "${C_RESET}"
}

_box_top() {
  local title="${1:-}"
  local width="${2:-$BOX_W}"
  local inner=$((width - 2))
  if [[ -z "${title}" ]]; then
    printf '%s┌' "${C_BLUE}"
    printf '─%.0s' $(seq 1 "${inner}")
    printf '┐%s\n' "${C_RESET}"
    return
  fi
  local t=" ${title} "
  local tlen=${#t}
  local left=$(( (inner - tlen) / 2 ))
  local right=$(( inner - tlen - left ))
  [[ $left -lt 0 ]] && left=0
  [[ $right -lt 0 ]] && right=0
  printf '%s┌' "${C_BLUE}"
  printf '─%.0s' $(seq 1 "${left}")
  printf '%s%s%s' "${C_GREEN}${C_BOLD}" "${t}" "${C_RESET}${C_BLUE}"
  printf '─%.0s' $(seq 1 "${right}")
  printf '┐%s\n' "${C_RESET}"
}

_box_bottom() {
  local footer="${1:-}"
  local width="${2:-$BOX_W}"
  local inner=$((width - 2))
  if [[ -z "${footer}" ]]; then
    printf '%s└' "${C_BLUE}"
    printf '─%.0s' $(seq 1 "${inner}")
    printf '┘%s\n' "${C_RESET}"
    return
  fi
  local t=" ${footer} "
  local tlen=${#t}
  local left=$(( (inner - tlen) / 2 ))
  local right=$(( inner - tlen - left ))
  [[ $left -lt 0 ]] && left=0
  [[ $right -lt 0 ]] && right=0
  printf '%s└' "${C_BLUE}"
  printf '─%.0s' $(seq 1 "${left}")
  printf '%s%s%s' "${C_GREEN}" "${t}" "${C_BLUE}"
  printf '─%.0s' $(seq 1 "${right}")
  printf '┘%s\n' "${C_RESET}"
}

_box_empty() {
  _pad_line " "
}

_box_text() {
  # Word-wrap plain text into box lines (no ANSI in input)
  local text="$1"
  local width="${2:-$BOX_W}"
  local max=$((width - 4))
  local line=""
  local word
  # shellcheck disable=SC2001
  text="$(printf '%s' "$text" | tr '\n' ' ')"
  for word in $text; do
    if [[ -z "${line}" ]]; then
      line="${word}"
    elif (( ${#line} + 1 + ${#word} > max )); then
      _pad_line " ${C_GREEN}${line}${C_RESET}"
      line="${word}"
    else
      line="${line} ${word}"
    fi
  done
  [[ -n "${line}" ]] && _pad_line " ${C_GREEN}${line}${C_RESET}"
}

draw_banner() {
  clear_screen
  echo ""
  echo -e "${C_CYAN}${C_BOLD}"
  cat <<'EOF'
   ██████╗ ██╗████████╗     █████╗ ███████╗███████╗██╗███████╗████████╗
  ██╔════╝ ██║╚══██╔══╝    ██╔══██╗██╔════╝██╔════╝██║██╔════╝╚══██╔══╝
  ██║  ███╗██║   ██║       ███████║███████╗███████╗██║███████╗   ██║
  ██║   ██║██║   ██║       ██╔══██║╚════██║╚════██║██║╚════██║   ██║
  ╚██████╔╝██║   ██║       ██║  ██║███████║███████║██║███████║   ██║
   ╚═════╝ ╚═╝   ╚═╝       ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝╚══════╝   ╚═╝
EOF
  echo -e "${C_RESET}"
  echo -e "  ${C_GREEN}Git Assistant with AI • консольный установщик${C_RESET}"
  echo -e "  ${C_GRAY}${APP_DIR}  ·  user: ${RUN_USER}${C_RESET}"
  echo ""
}

# ui_msg TITLE TEXT...
ui_msg() {
  local title="$1"
  shift
  local text="$*"
  draw_banner
  _box_top "${title}"
  _box_empty
  local line
  while IFS= read -r line || [[ -n "${line}" ]]; do
    if [[ -z "${line}" ]]; then
      _box_empty
    else
      _pad_line " ${C_GREEN}${line}${C_RESET}"
    fi
  done <<<"${text}"
  _box_empty
  _box_bottom "git-assistant • enter"
  echo ""
  echo -ne "  ${C_GREEN}> Enter для продолжения… ${C_RESET}"
  read -r _
}

# ui_yesno TITLE TEXT...  → exit 0=yes, 1=no
ui_yesno() {
  local title="$1"
  shift
  local text="$*"
  local choice
  while true; do
    draw_banner
    _box_top "${title}"
    _box_empty
    while IFS= read -r line || [[ -n "${line}" ]]; do
      [[ -z "${line}" ]] && _box_empty && continue
      _pad_line " ${C_GREEN}${line}${C_RESET}"
    done <<<"${text}"
    _box_empty
    _pad_line " ${C_BLUE}[1]${C_RESET}  ${C_GREEN}Да${C_RESET}"
    _pad_line " ${C_BLUE}[0]${C_RESET}  ${C_GREEN}Нет${C_RESET}"
    _box_empty
    _box_bottom "git-assistant • да / нет"
    echo ""
    echo -ne "  ${C_GREEN}> Выбор [0]: ${C_RESET}"
    read -r choice
    choice="${choice:-0}"
    case "${choice}" in
      1|y|Y|д|Д) return 0 ;;
      0|n|N|н|Н) return 1 ;;
      *) continue ;;
    esac
  done
}

# ui_input TITLE PROMPT [DEFAULT] → prints value
ui_input() {
  local title="$1"
  local prompt="$2"
  local default="${3:-}"
  local result=""
  draw_banner
  _box_top "${title}"
  _box_empty
  _pad_line " ${C_GREEN}${prompt}${C_RESET}"
  if [[ -n "${default}" ]]; then
    _pad_line " ${C_GRAY}по умолчанию: ${default}${C_RESET}"
  fi
  _box_empty
  _box_bottom "git-assistant • ввод"
  echo ""
  if [[ -n "${default}" ]]; then
    echo -ne "  ${C_GREEN}> [${default}]: ${C_RESET}"
  else
    echo -ne "  ${C_GREEN}> ${C_RESET}"
  fi
  read -r result
  result="${result:-$default}"
  printf '%s' "${result}"
}

# ui_menu TITLE  key1 "label1" key2 "label2" ...
# Prints selected key. Option [0] = cancel (return 1).
# Labels may start with "!red!" for red coloring (destructive).
ui_menu() {
  local title="$1"
  shift
  local keys=()
  local labels=()
  local styles=()
  local i=1
  while [[ $# -ge 2 ]]; do
    keys+=("$1")
    local lab="$2"
    if [[ "${lab}" == "!red!"* ]]; then
      styles+=("red")
      lab="${lab#!red!}"
    else
      styles+=("green")
    fi
    labels+=("${lab}")
    shift 2
    i=$((i + 1))
  done

  local choice idx
  while true; do
    draw_banner
    _box_top "${title}"
    _box_empty
    idx=0
    while [[ ${idx} -lt ${#keys[@]} ]]; do
      local num=$((idx + 1))
      local color="${C_GREEN}"
      [[ "${styles[$idx]}" == "red" ]] && color="${C_RED}"
      _pad_line " ${C_BLUE}[${num}]${C_RESET}  ${color}${labels[$idx]}${C_RESET}"
      idx=$((idx + 1))
    done
    _box_empty
    _pad_line " ${C_BLUE}[0]${C_RESET}  ${C_GREEN}Назад / отмена${C_RESET}"
    _box_empty
    _box_bottom "git-assistant • меню"
    echo ""
    echo -ne "  ${C_GREEN}> Выбор [0]: ${C_RESET}"
    read -r choice
    choice="${choice:-0}"
    if [[ "${choice}" == "0" ]]; then
      return 1
    fi
    if [[ "${choice}" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#keys[@]} )); then
      printf '%s' "${keys[$((choice - 1))]}"
      return 0
    fi
  done
}

log_step() {
  echo -e "  ${C_BLUE}[*]${C_RESET} ${C_GREEN}$*${C_RESET}"
}

log_warn() {
  echo -e "  ${C_YELLOW}[!]${C_RESET} $*"
}

# --- Install steps ---

install_system_packages() {
  log_step "Проверка системных пакетов..."
  local pkgs=()
  need_cmd python3 || pkgs+=(python3)
  python3 -c "import venv" 2>/dev/null || pkgs+=(python3-venv)
  need_cmd pip3 || pkgs+=(python3-pip)
  need_cmd git || pkgs+=(git)
  need_cmd curl || pkgs+=(curl)

  if [[ ${#pkgs[@]} -gt 0 ]]; then
    log_step "Установка: ${pkgs[*]}"
    run_root apt-get update -y
    run_root DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}"
  fi
}

welcome() {
  ui_msg "Добро пожаловать" \
"Этот мастер установит Git Assistant with AI:

  • Python venv + зависимости
  • config.yaml (проекты)
  • Ollama + модель (опционально)
  • GitHub CLI (gh) для Actions
  • systemd-сервис (автозапуск)

Каталог: ${APP_DIR}
Пользователь: ${RUN_USER}"
}

ask_network() {
  local choice
  choice="$(ui_menu "Сеть" \
    "lan"    "LAN — 0.0.0.0 (доступ по локальному IP)" \
    "local"  "localhost — 127.0.0.1 (только SSH-туннель)" \
    "custom" "Указать host вручную")" || die "Отменено"

  case "${choice}" in
    lan) GA_HOST="0.0.0.0" ;;
    local) GA_HOST="127.0.0.1" ;;
    custom)
      GA_HOST="$(ui_input "Host" "IP или hostname для bind" "0.0.0.0")"
      ;;
  esac

  GA_PORT="$(ui_input "Порт" "TCP-порт веб-UI" "8080")"
  [[ "${GA_PORT}" =~ ^[0-9]+$ ]] || die "Некорректный порт: ${GA_PORT}"
}

ask_model() {
  local choice
  choice="$(ui_menu "Модель Ollama" \
    "3b"     "qwen2.5-coder:3b (рекомендуется, 16 ГБ RAM)" \
    "7b"     "qwen2.5-coder:7b (если хватает памяти)" \
    "custom" "Указать имя модели вручную")" || die "Отменено"

  case "${choice}" in
    3b) DEFAULT_MODEL="qwen2.5-coder:3b" ;;
    7b) DEFAULT_MODEL="qwen2.5-coder:7b" ;;
    custom)
      DEFAULT_MODEL="$(ui_input "Модель" "Имя модели Ollama" "qwen2.5-coder:3b")"
      ;;
  esac

  OLLAMA_URL="$(ui_input "Ollama URL" "URL API Ollama" "http://localhost:11434")"

  if ui_yesno "Ollama" "Установить Ollama, если ещё не установлена?"; then
    INSTALL_OLLAMA="yes"
  else
    INSTALL_OLLAMA="no"
  fi

  if ui_yesno "Модель" "Скачать модель ${DEFAULT_MODEL} сейчас?
(может занять время и место на диске)"; then
    PULL_MODEL="yes"
  else
    PULL_MODEL="no"
  fi
}

ask_gh() {
  if ui_yesno "GitHub CLI" "Установить GitHub CLI (gh) для проверки Actions?
Авторизация: gh auth login (без токена в .env)"; then
    INSTALL_GH="yes"
  else
    INSTALL_GH="no"
  fi
}

ask_projects() {
  PROJECT_LINES=()
  ui_msg "Проекты" \
"Добавьте git-репозитории для управления.

Для каждого: путь, тесты, ветка, github_repo.
Можно пропустить и править config.yaml позже."

  while true; do
    if ! ui_yesno "Проект" "Добавить проект?
Уже добавлено: ${#PROJECT_LINES[@]}"; then
      break
    fi

    local name path test_command test_timeout auto_pull github_repo branch model
    name="$(ui_input "Имя проекта" "Короткое имя (например backend)" "backend")"
    path="$(ui_input "Путь" "Абсолютный путь к git-репозиторию" "/home/${RUN_USER}/projects/${name}")"
    test_command="$(ui_input "Тесты" "Команда тестов (пусто = без тестов)" "pytest")"
    test_timeout="$(ui_input "Таймаут" "Таймаут тестов в секундах" "300")"
    branch="$(ui_input "Ветка" "Ветка для push/pull" "main")"
    github_repo="$(ui_input "GitHub repo" "owner/repo (пусто = без Actions)" "")"
    model="$(ui_input "Модель" "Модель для проекта" "${DEFAULT_MODEL}")"
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
    ui_msg "Проекты" "Проекты не добавлены.
Будет пустой список — допишите config.yaml позже."
  fi
}

ask_service_options() {
  if ui_yesno "systemd" "Установить и включить systemd-сервис
(автозапуск при загрузке)?"; then
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
    if ui_yesno "UFW" "Открыть порт ${GA_PORT}/tcp в UFW
(если firewall активен)?"; then
      OPEN_UFW="yes"
    else
      OPEN_UFW="no"
    fi
  fi
}

yaml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "${s}"
}

write_config() {
  log_step "Запись ${CONFIG_FILE}"
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
    echo "  log_file: \"${LOG_FILE}\""
  } >"${CONFIG_FILE}"
}

setup_venv() {
  log_step "Создание virtualenv..."
  python3 -m venv "${VENV_DIR}"
  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
  log_step "Установка Python-зависимостей..."
  pip install --upgrade pip
  pip install -r "${APP_DIR}/requirements.txt"
}

setup_log() {
  log_step "Лог-файл ${LOG_FILE}"
  run_root touch "${LOG_FILE}"
  run_root chown "${RUN_UID}:${RUN_GID}" "${LOG_FILE}"
  run_root chmod 644 "${LOG_FILE}"
}

setup_env_file() {
  log_step "EnvironmentFile ${ENV_FILE}"
  local tmp home_dir
  home_dir="$(getent passwd "${RUN_USER}" | cut -d: -f6)"
  home_dir="${home_dir:-/home/${RUN_USER}}"
  tmp="$(mktemp)"
  {
    echo "# Managed by Git Assistant installer"
    echo "GIT_ASSISTANT_HOST=${GA_HOST}"
    echo "GIT_ASSISTANT_PORT=${GA_PORT}"
    echo "HOME=${home_dir}"
  } >"${tmp}"
  run_root install -m 640 -o root -g "${RUN_GID}" "${tmp}" "${ENV_FILE}"
  rm -f "${tmp}"
}

install_gh_cli() {
  if need_cmd gh; then
    log_step "gh уже установлен: $(gh --version | head -n1)"
    return 0
  fi

  log_step "Установка GitHub CLI (gh)..."
  if need_cmd apt-get; then
    run_root mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | run_root tee /usr/share/keyrings/githubcli-archive-keyring.gpg >/dev/null
    run_root chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      | run_root tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    run_root apt-get update -y
    run_root DEBIAN_FRONTEND=noninteractive apt-get install -y gh
  else
    log_warn "Не удалось установить gh автоматически"
    return 1
  fi
}

setup_gh() {
  [[ "${INSTALL_GH}" == "yes" ]] || return 0

  install_gh_cli || true

  if ! need_cmd gh; then
    ui_msg "GitHub CLI" "gh не установлен. Actions-статус будет недоступен.
Позже: установите gh и выполните gh auth login"
    return 0
  fi

  if gh auth status >/dev/null 2>&1; then
    ui_msg "GitHub CLI" "gh уже авторизован — отлично."
    return 0
  fi

  ui_msg "Авторизация gh" \
"Войдите в GitHub CLI под пользователем ${RUN_USER}.

В другом терминале выполните:

  gh auth login

GitHub.com → HTTPS → Login with a web browser

Нажмите Enter, когда закончите (или чтобы пропустить)."

  if gh auth status >/dev/null 2>&1; then
    ui_msg "GitHub CLI" "Авторизация OK."
  else
    ui_msg "GitHub CLI" \
"Пока не авторизовано. Позже:

  gh auth login
  sudo systemctl restart git-assistant

Коммиты работают и без этого — просто без статуса Actions."
  fi
}

setup_ollama() {
  if [[ "${INSTALL_OLLAMA}" == "yes" ]]; then
    if need_cmd ollama; then
      log_step "Ollama уже установлена"
    else
      log_step "Установка Ollama..."
      curl -fsSL https://ollama.com/install.sh | run_root sh
    fi
    if need_cmd systemctl; then
      run_root systemctl enable --now ollama 2>/dev/null || true
    fi
  fi

  if [[ "${PULL_MODEL}" == "yes" ]]; then
    if need_cmd ollama; then
      log_step "Скачивание модели ${DEFAULT_MODEL}..."
      ollama pull "${DEFAULT_MODEL}" || log_warn "Не удалось скачать — позже: ollama pull ${DEFAULT_MODEL}"
    else
      log_warn "ollama не найдена — пропуск pull"
    fi
  fi
}

setup_systemd() {
  [[ "${SETUP_SYSTEMD}" == "yes" ]] || return 0
  need_cmd systemctl || die "systemctl не найден — systemd недоступен"

  log_step "systemd unit ${SERVICE_FILE}"
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
    log_step "Запуск ${SERVICE_NAME}..."
    run_root systemctl restart "${SERVICE_NAME}"
    sleep 1
    run_root systemctl --no-pager --full status "${SERVICE_NAME}" || true
  fi
}

setup_ufw() {
  [[ "${OPEN_UFW}" == "yes" ]] || return 0
  if need_cmd ufw && run_root ufw status 2>/dev/null | grep -qi "Status: active"; then
    log_step "UFW: разрешаю ${GA_PORT}/tcp"
    run_root ufw allow "${GA_PORT}/tcp" comment "Git Assistant" || true
  else
    log_step "UFW не активен — правило не добавлялось"
  fi
}

primary_lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

confirm_install() {
  ui_yesno "Подтверждение" \
"Host:     ${GA_HOST}
Port:     ${GA_PORT}
Model:    ${DEFAULT_MODEL}
Ollama:   ${INSTALL_OLLAMA} / pull ${PULL_MODEL}
Projects: ${#PROJECT_LINES[@]}
systemd:  ${SETUP_SYSTEMD} / start ${START_SERVICE}
gh CLI:   ${INSTALL_GH}

Продолжить установку?" || die "Установка отменена"
}

show_summary() {
  local ip
  ip="$(primary_lan_ip)"
  ip="${ip:-<server-ip>}"

  local lines
  lines="Установка завершена.

  Local:  http://127.0.0.1:${GA_PORT}"
  if [[ "${GA_HOST}" == "0.0.0.0" ]]; then
    lines="${lines}
  LAN:    http://${ip}:${GA_PORT}"
  fi
  lines="${lines}
  Tunnel: ssh -L ${GA_PORT}:127.0.0.1:${GA_PORT} ${RUN_USER}@${ip}

  systemctl status ${SERVICE_NAME}
  journalctl -u ${SERVICE_NAME} -f
  config: ${CONFIG_FILE}"

  ui_msg "Готово" "${lines}"

  draw_banner
  _box_top "Статус"
  _box_empty
  _pad_line " ${C_GREEN}Git Assistant установлен${C_RESET}"
  _pad_line " ${C_BLUE}LAN${C_RESET}   ${C_GREEN}http://${ip}:${GA_PORT}${C_RESET}"
  _pad_line " ${C_BLUE}Local${C_RESET} ${C_GREEN}http://127.0.0.1:${GA_PORT}${C_RESET}"
  _box_empty
  _box_bottom "git-assistant • готово"
  echo ""
}

main() {
  cd "${APP_DIR}"

  draw_banner
  _box_top "Старт"
  _box_empty
  _pad_line " ${C_GREEN}Нужен sudo для пакетов / systemd / логов${C_RESET}"
  _box_empty
  _box_bottom "git-assistant"
  echo ""

  ensure_root_helper
  install_system_packages

  welcome
  ask_network
  ask_model
  ask_gh
  ask_projects
  ask_service_options
  confirm_install

  echo ""
  draw_banner
  _box_top "Установка"
  _box_empty
  _pad_line " ${C_GREEN}Идёт настройка — не прерывайте…${C_RESET}"
  _box_empty
  _box_bottom "git-assistant"
  echo ""

  write_config
  setup_venv
  setup_log
  setup_env_file
  setup_ollama
  setup_gh
  setup_systemd
  setup_ufw
  show_summary
}

main "$@"

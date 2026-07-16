#!/usr/bin/env bash
# Git Assistant with AI — installer & console TUI
#
# One-liner:
#   sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Overl1te/git-assistant/master/install.sh)" @ install
#
# Локально:
#   sudo bash install.sh @ install
#   sudo bash install.sh          # то же, что install
#
set -euo pipefail

APP_NAME="git-assistant"
INSTALL_ROOT="/opt"
APP_DIR="${INSTALL_ROOT}/${APP_NAME}"
ENV_FILE="/etc/git-assistant.env"
LOG_FILE="/var/log/git-assistant.log"
SERVICE_NAME="git-assistant"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
BIN_PATH="/usr/local/bin/${APP_NAME}"
VENV_DIR="${APP_DIR}/.venv"
CONFIG_FILE="${APP_DIR}/config.yaml"

REPO_URL="${GIT_ASSISTANT_REPO_URL:-https://github.com/Overl1te/git-assistant.git}"
REPO_RAW_BASE="${GIT_ASSISTANT_RAW_BASE:-https://raw.githubusercontent.com/Overl1te/git-assistant}"
DEFAULT_BRANCH="${GIT_ASSISTANT_BRANCH:-master}"

# Wizard defaults
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
PROJECT_LINES=()
RUN_USER=""
RUN_UID=""
RUN_GID=""

# --- Console TUI ---
readonly BOX_TL='╔' BOX_TR='╗' BOX_BL='╚' BOX_BR='╝'
readonly BOX_H='═' BOX_V='║' BOX_LT='╠' BOX_RT='╣'
readonly TUI_NC=$'\e[0m' TUI_BOLD=$'\e[1m' TUI_DIM=$'\e[2m'
readonly TUI_CYAN=$'\e[96m' TUI_GREEN=$'\e[92m' TUI_YELLOW=$'\e[93m'
readonly TUI_RED=$'\e[91m' TUI_BLUE=$'\e[94m' TUI_BRIGHT_CYAN=$'\e[1;96m'

# Always talk to the real terminal (fixes hang under bash -c / curl / pipes)
TTY="/dev/tty"

die() {
  printf '%sERROR: %s%s\n' "$TUI_RED" "$*" "$TUI_NC" >"$TTY" 2>&1 || printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

need_cmd() { command -v "$1" >/dev/null 2>&1; }

check_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Запустите от root: sudo bash -c \"\$(curl -fsSL ${REPO_RAW_BASE}/${DEFAULT_BRANCH}/install.sh)\" @ install"
  fi
}

tui_term_width() {
  local cols
  cols="$(stty size <"$TTY" 2>/dev/null | awk '{print $2}')" || true
  if [[ -z "${cols:-}" || ! "$cols" =~ ^[0-9]+$ ]]; then
    cols="${COLUMNS:-72}"
  fi
  if [[ "$cols" -gt 80 ]]; then cols=80
  elif [[ "$cols" -lt 48 ]]; then cols=48
  fi
  printf '%s' "$cols"
}

_tui_strlen() {
  local clean="$1"
  local esc=$'\033'
  while [[ "$clean" == *"${esc}["* ]]; do
    local before="${clean%%${esc}\[*}"
    local rest="${clean#*${esc}\[}"
    local after="${rest#*m}"
    [[ "$rest" == "$after" ]] && break
    clean="${before}${after}"
  done
  printf '%s' "${#clean}"
}

_tui_repeat() {
  local char="$1" count="${2:-0}" str
  [[ "${count}" -le 0 ]] 2>/dev/null && return 0
  printf -v str '%*s' "$count" ''
  printf '%s' "${str// /$char}"
}

clear_screen() {
  clear >"$TTY" 2>/dev/null || printf '\033[2J\033[H' >"$TTY"
}

draw_box_top() {
  local width="${1:-$(tui_term_width)}"
  local inner=$((width - 2))
  [[ "$inner" -lt 0 ]] && inner=0
  printf '%s%s%s%s%s\n' "$TUI_CYAN" "$BOX_TL" "$(_tui_repeat "$BOX_H" "$inner")" "$BOX_TR" "$TUI_NC" >"$TTY"
}

draw_box_bottom() {
  local width="${1:-$(tui_term_width)}"
  local inner=$((width - 2))
  [[ "$inner" -lt 0 ]] && inner=0
  printf '%s%s%s%s%s\n' "$TUI_CYAN" "$BOX_BL" "$(_tui_repeat "$BOX_H" "$inner")" "$BOX_BR" "$TUI_NC" >"$TTY"
}

draw_box_sep() {
  local width="${1:-$(tui_term_width)}"
  local inner=$((width - 2))
  [[ "$inner" -lt 0 ]] && inner=0
  printf '%s%s%s%s%s\n' "$TUI_CYAN" "$BOX_LT" "$(_tui_repeat "$BOX_H" "$inner")" "$BOX_RT" "$TUI_NC" >"$TTY"
}

draw_box_line() {
  local text="$1" width="${2:-$(tui_term_width)}"
  local inner=$((width - 2))
  local text_len padding
  text_len="$(_tui_strlen "$text")"
  padding=$((inner - text_len - 1))
  [[ "$padding" -lt 0 ]] && padding=0
  printf '%s%s%s %s%s%s%s\n' "$TUI_CYAN" "$BOX_V" "$TUI_NC" "$text" "$(_tui_repeat ' ' "$padding")" "$TUI_CYAN" "$BOX_V$TUI_NC" >"$TTY"
}

draw_box_empty() {
  draw_box_line "" "${1:-$(tui_term_width)}"
}

draw_box_center() {
  local text="$1" width="${2:-$(tui_term_width)}"
  local inner=$((width - 2))
  local text_len left right
  text_len="$(_tui_strlen "$text")"
  left=$(( (inner - text_len) / 2 ))
  right=$(( inner - text_len - left ))
  [[ "$left" -lt 0 ]] && left=0
  [[ "$right" -lt 0 ]] && right=0
  printf '%s%s%s%s%s%s%s%s%s\n' \
    "$TUI_CYAN" "$BOX_V" "$TUI_NC" \
    "$(_tui_repeat ' ' "$left")" "$text" "$(_tui_repeat ' ' "$right")" \
    "$TUI_CYAN" "$BOX_V" "$TUI_NC" >"$TTY"
}

show_banner() {
  local subtitle="${1:-установщик}"
  printf '\n' >"$TTY"
  printf '%s%s' "$TUI_BRIGHT_CYAN" "$TUI_BOLD" >"$TTY"
  cat >"$TTY" <<'EOF'
   ██████╗ ██╗████████╗     █████╗ ███████╗███████╗██╗███████╗████████╗
  ██╔════╝ ██║╚══██╔══╝    ██╔══██╗██╔════╝██╔════╝██║██╔════╝╚══██╔══╝
  ██║  ███╗██║   ██║       ███████║███████╗███████╗██║███████╗   ██║
  ██║   ██║██║   ██║       ██╔══██║╚════██║╚════██║██║╚════██║   ██║
  ╚██████╔╝██║   ██║       ██║  ██║███████║███████║██║███████║   ██║
   ╚═════╝ ╚═╝   ╚═╝       ╚═╝  ╚═╝╚══════╝╚══════╝╚═╝╚══════╝   ╚═╝
EOF
  printf '%s\n' "$TUI_NC" >"$TTY"
  printf '  %sGit Assistant with AI · %s%s\n' "$TUI_GREEN" "$subtitle" "$TUI_NC" >"$TTY"
  printf '  %s%s%s\n\n' "$TUI_DIM" "${APP_DIR}" "$TUI_NC" >"$TTY"
}

# Read a line from the real TTY (never hangs on curl|bash stdin)
ui_read() {
  local reply=""
  IFS= read -r reply <"$TTY" || true
  printf '%s' "$reply"
}

ui_press_enter() {
  local msg="${1:-Enter для продолжения…}"
  printf ' %s%s%s' "$TUI_DIM" "$msg" "$TUI_NC" >"$TTY"
  ui_read >/dev/null
}

ui_choice() {
  local label="${1:-Выбор}" default="${2:-0}" reply
  printf ' %s>%s %s [%s]: ' "$TUI_BRIGHT_CYAN" "$TUI_NC" "$label" "$default" >"$TTY"
  reply="$(ui_read)"
  if [[ -z "$reply" ]]; then
    reply="$default"
  fi
  printf '%s' "$reply"
}

ui_prompt() {
  local label="$1" default="${2:-}" reply
  if [[ -n "$default" ]]; then
    printf ' %s>%s %s [%s]: ' "$TUI_BRIGHT_CYAN" "$TUI_NC" "$label" "$default" >"$TTY"
  else
    printf ' %s>%s %s: ' "$TUI_BRIGHT_CYAN" "$TUI_NC" "$label" >"$TTY"
  fi
  reply="$(ui_read)"
  if [[ -z "$reply" ]]; then
    reply="$default"
  fi
  printf '%s' "$reply"
}

ui_msg() {
  local title="$1"
  shift
  local w line
  w="$(tui_term_width)"
  clear_screen
  show_banner "консольный TUI"
  draw_box_top "$w"
  draw_box_center "${TUI_BOLD}${title}${TUI_NC}" "$w"
  draw_box_sep "$w"
  draw_box_empty "$w"
  while IFS= read -r line || [[ -n "${line}" ]]; do
    draw_box_line "${TUI_GREEN}${line}${TUI_NC}" "$w"
  done <<<"$*"
  draw_box_empty "$w"
  draw_box_sep "$w"
  draw_box_center "${TUI_DIM}${APP_NAME} · enter${TUI_NC}" "$w"
  draw_box_bottom "$w"
  echo >"$TTY"
  ui_press_enter
}

ui_yesno() {
  local title="$1"
  shift
  local w choice
  w="$(tui_term_width)"
  while true; do
    clear_screen
    show_banner "консольный TUI"
    draw_box_top "$w"
    draw_box_center "${TUI_BOLD}${title}${TUI_NC}" "$w"
    draw_box_sep "$w"
    draw_box_empty "$w"
    while IFS= read -r line || [[ -n "${line}" ]]; do
      draw_box_line "${TUI_GREEN}${line}${TUI_NC}" "$w"
    done <<<"$*"
    draw_box_empty "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[1]${TUI_NC} ${TUI_GREEN}Да${TUI_NC}" "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[0]${TUI_NC} ${TUI_GREEN}Нет${TUI_NC}" "$w"
    draw_box_empty "$w"
    draw_box_bottom "$w"
    echo >"$TTY"
    choice="$(ui_choice "Выбор" "0")"
    case "$choice" in
      1|y|Y|д|Д) return 0 ;;
      0|n|N|н|Н) return 1 ;;
    esac
  done
}

# ui_menu TITLE key1 label1 key2 label2 ... → prints key; return 1 on cancel
ui_menu() {
  local title="$1"
  shift
  local keys=() labels=() styles=() idx w choice num
  while [[ $# -ge 2 ]]; do
    keys+=("$1")
    local lab="$2"
    if [[ "$lab" == "!red!"* ]]; then
      styles+=("red")
      lab="${lab#!red!}"
    else
      styles+=("green")
    fi
    labels+=("$lab")
    shift 2
  done

  while true; do
    w="$(tui_term_width)"
    clear_screen
    show_banner "консольный TUI"
    draw_box_top "$w"
    draw_box_center "${TUI_BOLD}${title}${TUI_NC}" "$w"
    draw_box_sep "$w"
    draw_box_empty "$w"
    idx=0
    while [[ $idx -lt ${#keys[@]} ]]; do
      num=$((idx + 1))
      if [[ "${styles[$idx]}" == "red" ]]; then
        draw_box_line " ${TUI_BRIGHT_CYAN}[${num}]${TUI_NC} ${TUI_RED}${labels[$idx]}${TUI_NC}" "$w"
      else
        draw_box_line " ${TUI_BRIGHT_CYAN}[${num}]${TUI_NC} ${TUI_GREEN}${labels[$idx]}${TUI_NC}" "$w"
      fi
      idx=$((idx + 1))
    done
    draw_box_empty "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[0]${TUI_NC} ${TUI_GREEN}Назад / отмена${TUI_NC}" "$w"
    draw_box_empty "$w"
    draw_box_sep "$w"
    draw_box_center "${TUI_DIM}${APP_NAME} · меню${TUI_NC}" "$w"
    draw_box_bottom "$w"
    echo >"$TTY"
    choice="$(ui_choice "Выбор" "0")"
    if [[ "$choice" == "0" ]]; then
      return 1
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#keys[@]} )); then
      printf '%s' "${keys[$((choice - 1))]}"
      return 0
    fi
  done
}

log_step() {
  printf '  %s[*]%s %s%s%s\n' "$TUI_BLUE" "$TUI_NC" "$TUI_GREEN" "$*" "$TUI_NC" >"$TTY"
}

log_warn() {
  printf '  %s[!]%s %s\n' "$TUI_YELLOW" "$TUI_NC" "$*" >"$TTY"
}

# --- Bootstrap / files ---

detect_run_user() {
  if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
    RUN_USER="${SUDO_USER}"
  else
    RUN_USER="$(logname 2>/dev/null || true)"
    [[ -z "$RUN_USER" || "$RUN_USER" == "root" ]] && RUN_USER="root"
  fi
  RUN_UID="$(id -u "$RUN_USER")"
  RUN_GID="$(id -g "$RUN_USER")"
}

ensure_packages() {
  log_step "Системные пакеты..."
  local pkgs=()
  local pyver
  pyver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true)"

  need_cmd curl || pkgs+=(curl)
  need_cmd git || pkgs+=(git)
  need_cmd python3 || pkgs+=(python3)
  need_cmd pip3 || pkgs+=(python3-pip)

  # Ubuntu needs versioned package for ensurepip (e.g. python3.12-venv)
  if ! python3 -c "import ensurepip" 2>/dev/null; then
    pkgs+=(python3-venv)
    [[ -n "$pyver" ]] && pkgs+=("python${pyver}-venv")
  fi

  if [[ ${#pkgs[@]} -gt 0 ]]; then
    # unique-ish
    local -A seen=()
    local uniq=()
    local p
    for p in "${pkgs[@]}"; do
      [[ -n "${seen[$p]:-}" ]] && continue
      seen[$p]=1
      uniq+=("$p")
    done
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${uniq[@]}"
  fi
}

fetch_repo() {
  log_step "Загрузка проекта в ${APP_DIR}..."
  mkdir -p "$(dirname "$APP_DIR")"
  local tmp
  tmp="$(mktemp -d)"

  if need_cmd git; then
    if [[ -d "${APP_DIR}/.git" ]]; then
      git -C "$APP_DIR" fetch --depth 1 origin "$DEFAULT_BRANCH" || true
      git -C "$APP_DIR" checkout "$DEFAULT_BRANCH" || true
      git -C "$APP_DIR" pull --ff-only origin "$DEFAULT_BRANCH" || true
    else
      rm -rf "$APP_DIR"
      git clone --depth 1 --branch "$DEFAULT_BRANCH" "$REPO_URL" "$APP_DIR"
    fi
  else
    curl -fsSL "${REPO_URL%.git}/archive/refs/heads/${DEFAULT_BRANCH}.tar.gz" -o "${tmp}/src.tgz"
    rm -rf "$APP_DIR"
    mkdir -p "$APP_DIR"
    tar -xzf "${tmp}/src.tgz" -C "$tmp"
    local extracted
    extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    cp -a "${extracted}/." "$APP_DIR/"
  fi
  rm -rf "$tmp"

  [[ -f "${APP_DIR}/app.py" ]] || die "Не удалось загрузить app.py в ${APP_DIR}"
  # Never keep repo example as live config unless missing
  if [[ ! -f "$CONFIG_FILE" && -f "${APP_DIR}/config.example.yaml" ]]; then
    cp -a "${APP_DIR}/config.example.yaml" "$CONFIG_FILE"
  fi
  # If git brought back a tracked config.yaml from old releases, don't trust it as "user config"
  chown -R "${RUN_UID}:${RUN_GID}" "$APP_DIR"
}

install_cli_wrapper() {
  log_step "CLI: ${BIN_PATH}"
  cat >"$BIN_PATH" <<EOF
#!/usr/bin/env bash
exec bash "${APP_DIR}/install.sh" "\$@"
EOF
  chmod 755 "$BIN_PATH"
  # Keep a fresh copy of install.sh in APP_DIR when launched via curl -c
  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    cp -f "${BASH_SOURCE[0]}" "${APP_DIR}/install.sh" 2>/dev/null || true
    chmod 755 "${APP_DIR}/install.sh"
  fi
}

# Persist install.sh into APP_DIR when invoked via bash -c (no BASH_SOURCE file)
persist_self_from_curl() {
  if [[ ! -f "${APP_DIR}/install.sh" ]] || [[ "${1:-}" == "force" ]]; then
    # Re-download install.sh into app dir so CLI works offline later
    curl -fsSL "${REPO_RAW_BASE}/${DEFAULT_BRANCH}/install.sh" -o "${APP_DIR}/install.sh"
    chmod 755 "${APP_DIR}/install.sh"
  fi
}

# --- Wizard ---

welcome() {
  ui_msg "Добро пожаловать" \
"Установка Git Assistant with AI

  • файлы в ${APP_DIR}
  • Python venv + зависимости
  • config.yaml (проекты)
  • Ollama + модель (опционально)
  • GitHub CLI (gh) для Actions
  • systemd + CLI: ${APP_NAME}

Пользователь сервиса: ${RUN_USER}"
}

ask_network() {
  local choice
  choice="$(ui_menu "Сеть" \
    "lan"    "LAN — 0.0.0.0 (доступ по локальному IP)" \
    "local"  "localhost — 127.0.0.1 (SSH-туннель)" \
    "custom" "Указать host вручную")" || die "Отменено"
  case "$choice" in
    lan) GA_HOST="0.0.0.0" ;;
    local) GA_HOST="127.0.0.1" ;;
    custom) GA_HOST="$(ui_prompt "Host" "0.0.0.0")" ;;
  esac
  GA_PORT="$(ui_prompt "TCP-порт веб-UI" "8080")"
  [[ "$GA_PORT" =~ ^[0-9]+$ ]] || die "Некорректный порт: $GA_PORT"
}

ask_model() {
  local choice
  choice="$(ui_menu "Модель Ollama" \
    "3b"     "qwen2.5-coder:3b (рекомендуется)" \
    "7b"     "qwen2.5-coder:7b" \
    "custom" "Указать имя вручную")" || die "Отменено"
  case "$choice" in
    3b) DEFAULT_MODEL="qwen2.5-coder:3b" ;;
    7b) DEFAULT_MODEL="qwen2.5-coder:7b" ;;
    custom) DEFAULT_MODEL="$(ui_prompt "Модель" "qwen2.5-coder:3b")" ;;
  esac
  OLLAMA_URL="$(ui_prompt "Ollama URL" "http://localhost:11434")"
  if ui_yesno "Ollama" "Установить Ollama, если ещё нет?"; then INSTALL_OLLAMA="yes"; else INSTALL_OLLAMA="no"; fi
  if ui_yesno "Модель" "Скачать ${DEFAULT_MODEL} сейчас?"; then PULL_MODEL="yes"; else PULL_MODEL="no"; fi
}

ask_gh() {
  if ui_yesno "GitHub CLI" "Установить gh для статуса Actions?
(авторизация: gh auth login)"; then
    INSTALL_GH="yes"
  else
    INSTALL_GH="no"
  fi
}

ask_projects() {
  PROJECT_LINES=()
  ui_msg "Проекты" "Добавьте git-репозитории.

Если код на Windows-ПК, а Assistant на Ubuntu —
укажите remote_host (SSH) и путь Windows, например:
  C:/Users/you/Documents/GitHub/app

Можно пропустить и править config.yaml позже."

  while true; do
    if ! ui_yesno "Проект" "Добавить проект?
Уже: ${#PROJECT_LINES[@]}"; then
      break
    fi
    local name path test_command test_timeout auto_pull github_repo branch model
    local remote_host remote_port ssh_key remote_shell
    name="$(ui_prompt "Имя" "backend")"

    if ui_yesno "Расположение" "Код на другом ПК (Windows) через SSH?
Да = remote (сервер → ваш ПК)
Нет = путь на этом Ubuntu-сервере"; then
      remote_host="$(ui_prompt "SSH host" "user@192.168.1.10")"
      remote_port="$(ui_prompt "SSH port" "22")"
      path="$(ui_prompt "Путь на удалённом ПК" "C:/Users/${RUN_USER}/Documents/GitHub/${name}")"
      remote_shell="$(ui_prompt "remote_shell (bash/powershell/cmd)" "bash")"
      ssh_key="$(ui_prompt "ssh_key на сервере (пусто=default)" "")"
    else
      remote_host=""
      remote_port="22"
      remote_shell="bash"
      ssh_key=""
      path="$(ui_prompt "Путь на этом сервере" "/home/${RUN_USER}/projects/${name}")"
    fi

    test_command="$(ui_prompt "Команда тестов" "pytest")"
    test_timeout="$(ui_prompt "Таймаут сек." "300")"
    branch="$(ui_prompt "Ветка" "main")"
    github_repo="$(ui_prompt "owner/repo (пусто=нет)" "")"
    model="$(ui_prompt "Модель" "${DEFAULT_MODEL}")"
    if ui_yesno "auto_pull" "git pull --rebase перед коммитом?"; then
      auto_pull="true"
    else
      auto_pull="false"
    fi
    [[ "$test_timeout" =~ ^[0-9]+$ ]] || test_timeout="300"
    [[ "$remote_port" =~ ^[0-9]+$ ]] || remote_port="22"
    # name|path|test|timeout|auto_pull|github|branch|model|remote_host|remote_port|ssh_key|remote_shell
    PROJECT_LINES+=("${name}|${path}|${test_command}|${test_timeout}|${auto_pull}|${github_repo}|${branch}|${model}|${remote_host}|${remote_port}|${ssh_key}|${remote_shell}")
  done
}

ask_service_options() {
  if ui_yesno "systemd" "Включить systemd-сервис (автозапуск)?"; then
    SETUP_SYSTEMD="yes"
    if ui_yesno "Запуск" "Запустить сразу после установки?"; then
      START_SERVICE="yes"
    else
      START_SERVICE="no"
    fi
  else
    SETUP_SYSTEMD="no"
    START_SERVICE="no"
  fi
  if [[ "$GA_HOST" == "0.0.0.0" ]] && need_cmd ufw; then
    if ui_yesno "UFW" "Открыть ${GA_PORT}/tcp в UFW?"; then OPEN_UFW="yes"; else OPEN_UFW="no"; fi
  fi
}

yaml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

write_config() {
  log_step "config.yaml"
  {
    echo "# Generated by install.sh — $(date -Iseconds)"
    if [[ ${#PROJECT_LINES[@]} -eq 0 ]]; then
      echo "projects: []"
    else
      echo "projects:"
      local line name path test_command test_timeout auto_pull github_repo branch model
      local remote_host remote_port ssh_key remote_shell
      for line in "${PROJECT_LINES[@]}"; do
        IFS='|' read -r name path test_command test_timeout auto_pull github_repo branch model remote_host remote_port ssh_key remote_shell <<<"$line"
        echo "  - name: \"$(yaml_escape "$name")\""
        echo "    path: \"$(yaml_escape "$path")\""
        echo "    test_command: \"$(yaml_escape "$test_command")\""
        echo "    test_timeout: ${test_timeout}"
        echo "    auto_pull: ${auto_pull}"
        echo "    github_repo: \"$(yaml_escape "$github_repo")\""
        echo "    branch: \"$(yaml_escape "$branch")\""
        echo "    model: \"$(yaml_escape "$model")\""
        if [[ -n "${remote_host}" ]]; then
          echo "    remote_host: \"$(yaml_escape "$remote_host")\""
          echo "    remote_port: ${remote_port:-22}"
          echo "    remote_shell: \"$(yaml_escape "${remote_shell:-bash}")\""
          if [[ -n "${ssh_key}" ]]; then
            echo "    ssh_key: \"$(yaml_escape "$ssh_key")\""
          fi
        fi
      done
    fi
    echo ""
    echo "global:"
    echo "  ollama_url: \"$(yaml_escape "$OLLAMA_URL")\""
    echo "  default_model: \"$(yaml_escape "$DEFAULT_MODEL")\""
    echo "  log_file: \"${LOG_FILE}\""
  } >"$CONFIG_FILE"
  chown "${RUN_UID}:${RUN_GID}" "$CONFIG_FILE"
}

setup_venv() {
  log_step "Python venv + зависимости"
  # Ensure ensurepip is present (fixes partial installs)
  if ! python3 -c "import ensurepip" 2>/dev/null; then
    local pyver
    pyver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    log_step "Доустанавливаю python${pyver}-venv..."
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "python${pyver}-venv" python3-venv || true
  fi
  rm -rf "$VENV_DIR"
  if [[ "$RUN_USER" != "root" ]]; then
    sudo -u "$RUN_USER" python3 -m venv "$VENV_DIR" || python3 -m venv "$VENV_DIR"
  else
    python3 -m venv "$VENV_DIR"
  fi
  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
  pip install --upgrade pip
  pip install -r "${APP_DIR}/requirements.txt"
  chown -R "${RUN_UID}:${RUN_GID}" "$VENV_DIR"
}

setup_log() {
  log_step "Лог ${LOG_FILE}"
  touch "$LOG_FILE"
  chown "${RUN_UID}:${RUN_GID}" "$LOG_FILE"
  chmod 644 "$LOG_FILE"
}

setup_env_file() {
  log_step "Env ${ENV_FILE}"
  local home_dir
  home_dir="$(getent passwd "$RUN_USER" | cut -d: -f6)"
  home_dir="${home_dir:-/home/${RUN_USER}}"
  cat >"$ENV_FILE" <<EOF
# Managed by ${APP_NAME} installer
GIT_ASSISTANT_HOST=${GA_HOST}
GIT_ASSISTANT_PORT=${GA_PORT}
HOME=${home_dir}
EOF
  chown "root:${RUN_GID}" "$ENV_FILE"
  chmod 640 "$ENV_FILE"
}

setup_ollama() {
  if [[ "$INSTALL_OLLAMA" == "yes" ]]; then
    if need_cmd ollama; then
      log_step "Ollama уже есть"
    else
      log_step "Установка Ollama..."
      curl -fsSL https://ollama.com/install.sh | sh
    fi
    systemctl enable --now ollama 2>/dev/null || true
  fi
  if [[ "$PULL_MODEL" == "yes" ]] && need_cmd ollama; then
    log_step "Pull ${DEFAULT_MODEL}..."
    # pull as run user when possible
    if [[ "$RUN_USER" != "root" ]]; then
      sudo -u "$RUN_USER" ollama pull "$DEFAULT_MODEL" || ollama pull "$DEFAULT_MODEL" || log_warn "pull не удался"
    else
      ollama pull "$DEFAULT_MODEL" || log_warn "pull не удался"
    fi
  fi
}

setup_gh() {
  [[ "$INSTALL_GH" == "yes" ]] || return 0
  if ! need_cmd gh; then
    log_step "Установка gh..."
    mkdir -p -m 755 /etc/apt/keyrings
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      -o /usr/share/keyrings/githubcli-archive-keyring.gpg
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      >/etc/apt/sources.list.d/github-cli.list
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y gh
  fi
  if [[ "$RUN_USER" != "root" ]] && sudo -u "$RUN_USER" gh auth status >/dev/null 2>&1; then
    ui_msg "GitHub CLI" "gh уже авторизован для ${RUN_USER}."
    return 0
  fi
  ui_msg "Авторизация gh" \
"В другом SSH-сессии под пользователем ${RUN_USER}:

  gh auth login

Затем Enter здесь (или пропустите — коммиты работают без Actions)."
}

setup_systemd() {
  [[ "$SETUP_SYSTEMD" == "yes" ]] || return 0
  log_step "systemd ${SERVICE_NAME}"
  local group
  group="$(id -gn "$RUN_USER")"
  cat >"$SERVICE_FILE" <<EOF
[Unit]
Description=Git Assistant with AI
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${group}
WorkingDirectory=${APP_DIR}
EnvironmentFile=-${ENV_FILE}
Environment=PATH=${VENV_DIR}/bin:/usr/local/bin:/usr/bin
ExecStart=${VENV_DIR}/bin/python ${APP_DIR}/app.py
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
  if [[ "$START_SERVICE" == "yes" ]]; then
    systemctl restart "$SERVICE_NAME"
    sleep 1
    systemctl --no-pager --full status "$SERVICE_NAME" || true
  fi
}

setup_ufw() {
  [[ "$OPEN_UFW" == "yes" ]] || return 0
  if need_cmd ufw && ufw status 2>/dev/null | grep -qi "Status: active"; then
    log_step "UFW allow ${GA_PORT}/tcp"
    ufw allow "${GA_PORT}/tcp" comment "Git Assistant" || true
  fi
}

primary_lan_ip() {
  hostname -I 2>/dev/null | awk '{print $1}'
}

confirm_install() {
  ui_yesno "Подтверждение" \
"Host: ${GA_HOST}
Port: ${GA_PORT}
Model: ${DEFAULT_MODEL}
Ollama: ${INSTALL_OLLAMA} / pull ${PULL_MODEL}
Projects: ${#PROJECT_LINES[@]}
systemd: ${SETUP_SYSTEMD} / start ${START_SERVICE}
gh: ${INSTALL_GH}
User: ${RUN_USER}

Продолжить?" || die "Отменено"
}

show_summary() {
  local ip
  ip="$(primary_lan_ip)"
  ip="${ip:-<server-ip>}"
  ui_msg "Готово" \
"Установка завершена.

  Local: http://127.0.0.1:${GA_PORT}
  LAN:   http://${ip}:${GA_PORT}
  Tunnel: ssh -L ${GA_PORT}:127.0.0.1:${GA_PORT} ${RUN_USER}@${ip}

  systemctl status ${SERVICE_NAME}
  ${APP_NAME} status
  ${APP_NAME}            # меню
  journalctl -u ${SERVICE_NAME} -f"
}

# --- Commands / updater / CLI ---

cmd_install() {
  check_root
  detect_run_user
  ensure_packages
  fetch_repo
  persist_self_from_curl force
  install_cli_wrapper

  welcome
  ask_network
  ask_model
  ask_gh
  ask_projects
  ask_service_options
  confirm_install

  clear_screen
  show_banner "установка…"
  echo >"$TTY"
  write_config
  setup_venv
  setup_log
  setup_env_file
  setup_ollama
  setup_gh
  setup_systemd
  setup_ufw
  printf '%s\n' "$(local_version)" >"${APP_DIR}/VERSION" 2>/dev/null || true
  show_summary
}

is_installed() {
  [[ -f "${APP_DIR}/app.py" ]]
}

local_version() {
  if [[ -d "${APP_DIR}/.git" ]]; then
    git -C "$APP_DIR" rev-parse --short HEAD 2>/dev/null || echo "unknown"
  elif [[ -f "${APP_DIR}/VERSION" ]]; then
    tr -d '[:space:]' <"${APP_DIR}/VERSION"
  else
    echo "unknown"
  fi
}

remote_version() {
  if need_cmd git; then
    git ls-remote "$REPO_URL" "refs/heads/${DEFAULT_BRANCH}" 2>/dev/null | awk '{print substr($1,1,7)}' | head -n1
  else
    echo "unknown"
  fi
}

read_env_var() {
  local key="$1" file="${2:-$ENV_FILE}"
  [[ -f "$file" ]] || return 0
  grep -E "^${key}=" "$file" 2>/dev/null | head -n1 | cut -d= -f2- || true
}

backup_user_data() {
  local stamp backup_dir
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup_dir="/var/backups/${APP_NAME}/${stamp}"
  mkdir -p "$backup_dir"
  [[ -f "$CONFIG_FILE" ]] && cp -a "$CONFIG_FILE" "${backup_dir}/config.yaml"
  [[ -f "$ENV_FILE" ]] && cp -a "$ENV_FILE" "${backup_dir}/git-assistant.env"
  [[ -f "$SERVICE_FILE" ]] && cp -a "$SERVICE_FILE" "${backup_dir}/git-assistant.service"
  printf '%s' "$backup_dir"
}

restore_config_if_missing() {
  local backup_dir="$1"
  if [[ ! -f "$CONFIG_FILE" && -f "${backup_dir}/config.yaml" ]]; then
    cp -a "${backup_dir}/config.yaml" "$CONFIG_FILE"
  fi
}

update_code_tree() {
  # Update app files while preserving config.yaml
  local backup_dir="$1"
  mkdir -p "$APP_DIR"

  # Always snapshot live config before touching the tree
  if [[ -f "$CONFIG_FILE" ]]; then
    cp -a "$CONFIG_FILE" "${backup_dir}/config.yaml"
  fi

  if [[ -d "${APP_DIR}/.git" ]]; then
    log_step "git fetch/reset ${DEFAULT_BRANCH}"
    git -C "$APP_DIR" remote set-url origin "$REPO_URL" 2>/dev/null || true
    git -C "$APP_DIR" fetch --depth 1 origin "$DEFAULT_BRANCH"
    git -C "$APP_DIR" checkout -B "$DEFAULT_BRANCH" "origin/${DEFAULT_BRANCH}"
  else
    log_step "Скачивание архива ${DEFAULT_BRANCH}"
    local tmp extracted
    tmp="$(mktemp -d)"
    curl -fsSL "${REPO_URL%.git}/archive/refs/heads/${DEFAULT_BRANCH}.tar.gz" -o "${tmp}/src.tgz"
    tar -xzf "${tmp}/src.tgz" -C "$tmp"
    extracted="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -n1)"
    rsync -a --delete \
      --exclude '.venv' \
      --exclude 'config.yaml' \
      --exclude 'git-assistant.log' \
      --exclude '*.log' \
      "${extracted}/" "${APP_DIR}/" 2>/dev/null || {
        find "$APP_DIR" -mindepth 1 -maxdepth 1 ! -name '.venv' ! -name 'config.yaml' ! -name '*.log' -exec rm -rf {} +
        cp -a "${extracted}/." "$APP_DIR/"
      }
    rm -rf "$tmp"
  fi

  # Restore user config (never leave example/demo projects as live config after update)
  if [[ -f "${backup_dir}/config.yaml" ]]; then
    cp -a "${backup_dir}/config.yaml" "$CONFIG_FILE"
  elif [[ ! -f "$CONFIG_FILE" && -f "${APP_DIR}/config.example.yaml" ]]; then
    cp -a "${APP_DIR}/config.example.yaml" "$CONFIG_FILE"
  fi

  if [[ -f "${APP_DIR}/install.sh" ]]; then
    chmod 755 "${APP_DIR}/install.sh"
  else
    persist_self_from_curl force
  fi

  detect_run_user
  chown -R "${RUN_UID}:${RUN_GID}" "$APP_DIR" 2>/dev/null || true
  chmod 755 "${APP_DIR}/install.sh" 2>/dev/null || true
}

refresh_venv_deps() {
  log_step "Обновление Python-зависимостей"
  if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
    setup_venv
    return 0
  fi
  # shellcheck disable=SC1091
  source "${VENV_DIR}/bin/activate"
  pip install --upgrade pip
  pip install -r "${APP_DIR}/requirements.txt"
}

cmd_check_update() {
  is_installed || die "Не установлено. Сначала: sudo ${APP_NAME} install"
  local local_v remote_v
  local_v="$(local_version)"
  printf '  Локальная версия:  %s%s%s\n' "$TUI_GREEN" "$local_v" "$TUI_NC" >"$TTY"
  log_step "Проверка remote ${REPO_URL} (${DEFAULT_BRANCH})..."
  remote_v="$(remote_version)"
  if [[ -z "$remote_v" || "$remote_v" == "unknown" ]]; then
    log_warn "Не удалось получить remote revision"
    return 1
  fi
  printf '  Remote версия:     %s%s%s\n' "$TUI_CYAN" "$remote_v" "$TUI_NC" >"$TTY"
  if [[ "$local_v" == "$remote_v" ]]; then
    printf '  %sУже последняя версия%s\n' "$TUI_GREEN" "$TUI_NC" >"$TTY"
    return 0
  fi
  printf '  %sДоступно обновление%s → sudo %s update\n' "$TUI_YELLOW" "$TUI_NC" "$APP_NAME" >"$TTY"
  return 2
}

cmd_update() {
  check_root
  is_installed || die "Не установлено. Сначала: sudo ${APP_NAME} install"
  detect_run_user

  local local_v remote_v backup_dir
  local_v="$(local_version)"
  remote_v="$(remote_version)"

  clear_screen
  show_banner "обновление"
  printf '  Local:  %s\n' "$local_v" >"$TTY"
  printf '  Remote: %s\n\n' "${remote_v:-unknown}" >"$TTY"

  if [[ -n "$remote_v" && "$remote_v" != "unknown" && "$local_v" == "$remote_v" ]]; then
    if ! ui_yesno "Update" "Уже последняя версия (${local_v}).
Всё равно переустановить файлы и зависимости?"; then
      return 0
    fi
  else
    ui_yesno "Update" "Обновить Git Assistant?
${local_v} → ${remote_v:-latest}

config.yaml и /etc/git-assistant.env сохранятся." || return 0
  fi

  backup_dir="$(backup_user_data)"
  log_step "Бэкап: ${backup_dir}"

  update_code_tree "$backup_dir"
  restore_config_if_missing "$backup_dir"
  ensure_packages
  refresh_venv_deps
  install_cli_wrapper
  # rewrite VERSION marker
  printf '%s\n' "$(local_version)" >"${APP_DIR}/VERSION"

  if systemctl is-enabled "$SERVICE_NAME" >/dev/null 2>&1; then
    log_step "Restart ${SERVICE_NAME}"
    systemctl daemon-reload
    systemctl restart "$SERVICE_NAME"
    sleep 1
    systemctl --no-pager --full status "$SERVICE_NAME" || true
  fi

  ui_msg "Обновление" "Готово.
Версия: $(local_version)
Бэкап: ${backup_dir}
Web: http://127.0.0.1:$(read_env_var GIT_ASSISTANT_PORT || echo 8080)"
}

cmd_info() {
  local host port ip ver projects
  host="$(read_env_var GIT_ASSISTANT_HOST)"
  port="$(read_env_var GIT_ASSISTANT_PORT)"
  host="${host:-0.0.0.0}"
  port="${port:-8080}"
  ip="$(primary_lan_ip)"
  ver="$(local_version)"
  projects="0"
  if [[ -f "$CONFIG_FILE" ]]; then
    local py="${VENV_DIR}/bin/python"
    [[ -x "$py" ]] || py="python3"
    projects="$("$py" - <<'PY' 2>/dev/null || echo 0
import yaml
from pathlib import Path
p=Path("/opt/git-assistant/config.yaml")
data=yaml.safe_load(p.read_text(encoding="utf-8")) or {}
print(len(data.get("projects") or []))
PY
)"
  fi

  printf '\n'
  printf '  %sGit Assistant%s\n' "$TUI_BOLD" "$TUI_NC"
  printf '  Version:   %s\n' "$ver"
  printf '  App dir:   %s\n' "$APP_DIR"
  printf '  Config:    %s\n' "$CONFIG_FILE"
  printf '  Env:       %s\n' "$ENV_FILE"
  printf '  Service:   %s\n' "$SERVICE_NAME"
  printf '  Bind:      %s:%s\n' "$host" "$port"
  printf '  Projects:  %s\n' "$projects"
  printf '  Local URL: http://127.0.0.1:%s\n' "$port"
  [[ -n "$ip" ]] && printf '  LAN URL:   http://%s:%s\n' "$ip" "$port"
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    printf '  Status:    %sactive%s\n' "$TUI_GREEN" "$TUI_NC"
  else
    printf '  Status:    %sinactive%s\n' "$TUI_RED" "$TUI_NC"
  fi
  printf '\n'
}

cmd_projects() {
  is_installed || die "Не установлено"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "config.yaml не найден"
    return 1
  fi
  local py="${VENV_DIR}/bin/python"
  [[ -x "$py" ]] || py="python3"
  "$py" - <<'PY'
import yaml
from pathlib import Path
data = yaml.safe_load(Path("/opt/git-assistant/config.yaml").read_text(encoding="utf-8")) or {}
projects = data.get("projects") or []
if not projects:
    print("  (нет проектов)")
else:
    for i, p in enumerate(projects, 1):
        remote = p.get("remote_host") or "-"
        print(f"  [{i}] {p.get('name')}  path={p.get('path')}  remote={remote}  branch={p.get('branch','')}")
PY
}

cmd_start() {
  check_root
  systemctl start "$SERVICE_NAME"
  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

cmd_stop() {
  check_root
  systemctl stop "$SERVICE_NAME"
  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

cmd_enable() {
  check_root
  systemctl enable --now "$SERVICE_NAME"
  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

cmd_disable() {
  check_root
  systemctl disable --now "$SERVICE_NAME" || true
  echo "disabled"
}

cmd_config_show() {
  echo "=== ${CONFIG_FILE} ==="
  if [[ -f "$CONFIG_FILE" ]]; then
    cat "$CONFIG_FILE"
  else
    echo "(нет файла)"
  fi
  echo
  echo "=== ${ENV_FILE} ==="
  if [[ -f "$ENV_FILE" ]]; then
    # hide nothing critical besides maybe future secrets; show as-is
    cat "$ENV_FILE"
  else
    echo "(нет файла)"
  fi
}

cmd_config_edit() {
  check_root
  local editor="${EDITOR:-nano}"
  [[ -f "$CONFIG_FILE" ]] || die "Нет ${CONFIG_FILE}"
  "$editor" "$CONFIG_FILE"
  if ui_yesno "Restart" "Перезапустить сервис после правки config?"; then
    systemctl restart "$SERVICE_NAME"
  fi
}

cmd_doctor() {
  echo "Git Assistant doctor"
  echo "-------------------"
  is_installed && echo "[ok] installed at ${APP_DIR}" || echo "[!!] not installed"
  [[ -x "${VENV_DIR}/bin/python" ]] && echo "[ok] venv" || echo "[!!] venv missing"
  [[ -f "$CONFIG_FILE" ]] && echo "[ok] config.yaml" || echo "[!!] config.yaml missing"
  [[ -f "$ENV_FILE" ]] && echo "[ok] env file" || echo "[!!] env file missing"
  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null && echo "[ok] service active" || echo "[!!] service not active"
  need_cmd git && echo "[ok] git" || echo "[!!] git"
  need_cmd ssh && echo "[ok] ssh" || echo "[!!] ssh"
  need_cmd curl && echo "[ok] curl" || echo "[!!] curl"
  if need_cmd ollama; then
    echo "[ok] ollama"
  else
    echo "[!!] ollama not found"
  fi
  if need_cmd gh; then
    if gh auth status >/dev/null 2>&1; then
      echo "[ok] gh authenticated"
    else
      echo "[!!] gh installed but not logged in (gh auth login)"
    fi
  else
    echo "[!!] gh not found"
  fi
  if [[ -f "$CONFIG_FILE" ]]; then
    python3 - <<'PY' 2>/dev/null || true
import yaml
from pathlib import Path
data=yaml.safe_load(Path("/opt/git-assistant/config.yaml").read_text(encoding="utf-8")) or {}
for p in data.get("projects") or []:
    if p.get("remote_host"):
        print(f"[..] remote project: {p.get('name')} -> {p.get('remote_host')}")
PY
  fi
  local port
  port="$(read_env_var GIT_ASSISTANT_PORT)"
  port="${port:-8080}"
  if curl -fsS -o /dev/null -w '' "http://127.0.0.1:${port}/" 2>/dev/null; then
    echo "[ok] web responds on :${port}"
  else
    echo "[!!] web not responding on :${port}"
  fi
}

cmd_status() {
  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

cmd_restart() {
  check_root
  systemctl restart "$SERVICE_NAME"
  systemctl --no-pager --full status "$SERVICE_NAME" || true
}

cmd_logs() {
  local n="${1:-100}"
  if [[ "${1:-}" == "-n" || "${1:-}" == "--lines" ]]; then
    n="${2:-100}"
  fi
  journalctl -u "$SERVICE_NAME" -f --no-pager -n "$n"
}

cmd_uninstall() {
  check_root
  if ! ui_yesno "Удаление" "Удалить сервис ${SERVICE_NAME}?
Файлы в ${APP_DIR} тоже будут удалены.
config можно сохранить в /var/backups заранее через update."; then
    return 0
  fi
  backup_user_data >/dev/null || true
  systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  rm -f "$BIN_PATH" "$ENV_FILE"
  rm -rf "$APP_DIR"
  ui_msg "Удалено" "Git Assistant удалён. Бэкапы: /var/backups/${APP_NAME}/"
}

menu_run() {
  echo >"$TTY"
  set +e
  "$@"
  local rc=$?
  set -e
  echo >"$TTY"
  ui_press_enter
  return "$rc"
}

show_update_menu() {
  local choice
  while true; do
    local w
    w="$(tui_term_width)"
    clear_screen
    show_banner "обновления"
    draw_box_top "$w"
    draw_box_center "${TUI_BOLD}Обновление${TUI_NC}" "$w"
    draw_box_sep "$w"
    draw_box_empty "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[1]${TUI_NC} ${TUI_GREEN}Проверить обновления${TUI_NC}" "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[2]${TUI_NC} ${TUI_GREEN}Обновить сейчас${TUI_NC}" "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[0]${TUI_NC} ${TUI_GREEN}Назад${TUI_NC}" "$w"
    draw_box_empty "$w"
    draw_box_bottom "$w"
    echo >"$TTY"
    choice="$(ui_choice "Выбор" "0")"
    case "$choice" in
      1) menu_run cmd_check_update ;;
      2) menu_run cmd_update ;;
      0|"") return ;;
    esac
  done
}

show_main_menu() {
  local w choice
  while true; do
    w="$(tui_term_width)"
    clear_screen
    show_banner "управление"
    draw_box_top "$w"
    draw_box_center "${TUI_BOLD}Главное меню${TUI_NC}" "$w"
    draw_box_sep "$w"
    draw_box_empty "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[1]${TUI_NC} ${TUI_GREEN}Статус / info${TUI_NC}" "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[2]${TUI_NC} ${TUI_GREEN}Логи (follow)${TUI_NC}" "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[3]${TUI_NC} ${TUI_GREEN}Restart / start / stop${TUI_NC}" "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[4]${TUI_NC} ${TUI_GREEN}Проекты (список)${TUI_NC}" "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[5]${TUI_NC} ${TUI_GREEN}Обновление${TUI_NC}" "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[6]${TUI_NC} ${TUI_GREEN}Doctor (диагностика)${TUI_NC}" "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[7]${TUI_NC} ${TUI_GREEN}Показать config/env${TUI_NC}" "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[8]${TUI_NC} ${TUI_GREEN}Переустановить / мастер${TUI_NC}" "$w"
    draw_box_empty "$w"
    draw_box_line " ${TUI_RED}[9]${TUI_NC} ${TUI_RED}Удалить Git Assistant${TUI_NC}" "$w"
    draw_box_line " ${TUI_BRIGHT_CYAN}[0]${TUI_NC} ${TUI_GREEN}Выход${TUI_NC}" "$w"
    draw_box_empty "$w"
    draw_box_sep "$w"
    draw_box_center "${TUI_DIM}${APP_NAME} · $(local_version) · управление${TUI_NC}" "$w"
    draw_box_bottom "$w"
    echo >"$TTY"
    choice="$(ui_choice "Выбор" "0")"
    case "$choice" in
      1)
        clear_screen
        cmd_info
        cmd_status
        echo >"$TTY"
        ui_press_enter
        ;;
      2) cmd_logs ;;
      3)
        local sub
        sub="$(ui_menu "Сервис" \
          "restart" "Restart" \
          "start" "Start" \
          "stop" "Stop")" || continue
        case "$sub" in
          restart) menu_run cmd_restart ;;
          start) menu_run cmd_start ;;
          stop) menu_run cmd_stop ;;
        esac
        ;;
      4) menu_run cmd_projects ;;
      5) show_update_menu ;;
      6) menu_run cmd_doctor ;;
      7) menu_run cmd_config_show ;;
      8) cmd_install ;;
      9) cmd_uninstall; exit 0 ;;
      0|q|"") exit 0 ;;
    esac
  done
}

usage() {
  cat <<EOF
Git Assistant with AI  ($(local_version 2>/dev/null || echo cli))

Установка:
  sudo bash -c "\$(curl -fsSL ${REPO_RAW_BASE}/${DEFAULT_BRANCH}/install.sh)" @ install

Сервис:
  sudo ${APP_NAME} status|start|stop|restart|enable|disable
  sudo ${APP_NAME} logs [-n 200]

Обновление:
  sudo ${APP_NAME} check-update
  sudo ${APP_NAME} update

Инфо / конфиг:
  ${APP_NAME} info
  ${APP_NAME} projects
  ${APP_NAME} doctor
  sudo ${APP_NAME} config          # показать config + env
  sudo ${APP_NAME} config edit     # открыть config.yaml в редакторе

Прочее:
  sudo ${APP_NAME} install         # мастер
  sudo ${APP_NAME} uninstall
  ${APP_NAME}                      # TUI-меню
  ${APP_NAME} help
EOF
}

main() {
  # bash -c "..." @ install  → $0=@ $1=install; локально: ./install.sh @ install
  if [[ "${1:-}" == "@" ]]; then
    shift
  fi

  local cmd="${1:-}"
  if [[ -n "$cmd" ]]; then
    shift
  fi

  case "$cmd" in
    install) cmd_install "$@" ;;
    update|upgrade) cmd_update "$@" ;;
    check-update|check-updates) cmd_check_update ;;
    status|ps) cmd_status ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    enable) cmd_enable ;;
    disable) cmd_disable ;;
    logs) cmd_logs "$@" ;;
    info) cmd_info ;;
    projects|ls) cmd_projects ;;
    doctor|health) cmd_doctor ;;
    config)
      case "${1:-show}" in
        show|"") cmd_config_show ;;
        edit) cmd_config_edit ;;
        *) die "config: show|edit" ;;
      esac
      ;;
    uninstall|remove) cmd_uninstall ;;
    menu) show_main_menu ;;
    -h|--help|help) usage ;;
    "")
      if [[ -t 1 ]] && [[ -e "$TTY" ]]; then
        if is_installed; then
          show_main_menu
        else
          cmd_install
        fi
      else
        usage
      fi
      ;;
    *)
      die "Неизвестная команда: $cmd (help для справки)"
      ;;
  esac
}

main "$@"

"""Git Assistant core: git ops, tests, Ollama commit messages, GitHub Actions."""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import re
import shlex
import shutil
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Awaitable, Callable, Optional

import httpx
import yaml

LogCallback = Callable[[str], Awaitable[None]]


class ColoredFormatter(logging.Formatter):
    """ANSI-colored console formatter for manual runs."""

    COLORS = {
        logging.DEBUG: "\033[36m",
        logging.INFO: "\033[32m",
        logging.WARNING: "\033[33m",
        logging.ERROR: "\033[31m",
        logging.CRITICAL: "\033[35m",
    }
    RESET = "\033[0m"

    def format(self, record: logging.LogRecord) -> str:
        color = self.COLORS.get(record.levelno, self.RESET)
        message = super().format(record)
        return f"{color}{message}{self.RESET}"


def setup_logging(log_file: str) -> logging.Logger:
    """Configure file + colored console logging."""
    logger = logging.getLogger("git_assistant")
    logger.setLevel(logging.DEBUG)
    logger.handlers.clear()

    fmt = logging.Formatter(
        "%(asctime)s | %(levelname)-8s | %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    log_path = Path(log_file)
    log_path.parent.mkdir(parents=True, exist_ok=True)
    file_handler = logging.FileHandler(log_path, encoding="utf-8")
    file_handler.setLevel(logging.DEBUG)
    file_handler.setFormatter(fmt)
    logger.addHandler(file_handler)

    console = logging.StreamHandler()
    console.setLevel(logging.INFO)
    console.setFormatter(
        ColoredFormatter(
            "%(asctime)s | %(levelname)-8s | %(message)s",
            datefmt="%H:%M:%S",
        )
    )
    logger.addHandler(console)
    return logger


@dataclass
class ProjectConfig:
    """Single project entry from config.yaml."""

    name: str
    path: str
    test_command: str = ""
    test_timeout: int = 300
    auto_pull: bool = False
    github_repo: str = ""
    branch: str = ""
    model: str = ""
    # Remote execution on another machine (e.g. Windows PC) via SSH
    remote_host: str = ""  # user@192.168.1.10
    remote_port: int = 22
    ssh_key: str = ""  # optional private key path on the server
    remote_shell: str = "bash"  # bash | powershell | cmd


@dataclass
class GlobalConfig:
    """Global settings from config.yaml."""

    ollama_url: str = "http://localhost:11434"
    default_model: str = "qwen2.5-coder:3b"
    log_file: str = "./git-assistant.log"


@dataclass
class AppConfig:
    """Loaded application configuration."""

    projects: list[ProjectConfig] = field(default_factory=list)
    global_: GlobalConfig = field(default_factory=GlobalConfig)

    def get_project(self, name: str) -> Optional[ProjectConfig]:
        """Return project by name or None."""
        for project in self.projects:
            if project.name == name:
                return project
        return None


@dataclass
class ProjectStatus:
    """Runtime git status for a project."""

    name: str
    path: str
    branch: str = ""
    has_changes: bool = False
    change_count: int = 0
    error: Optional[str] = None
    configured_branch: str = ""
    github_repo: str = ""
    auto_pull: bool = False
    test_command: str = ""
    remote_host: str = ""
    is_remote: bool = False


@dataclass
class JobResult:
    """Outcome of a commit/pull job."""

    success: bool = False
    commit_message: str = ""
    test_output: str = ""
    actions_status: str = ""
    actions_conclusion: str = ""
    error: str = ""
    skipped_tests: bool = False


COMMIT_PROMPT = """You are a git commit message generator.
Write ONE Conventional Commits message for the staged/working tree diff below.

Rules:
- Format: <type>(optional-scope): <short description>
- Types: feat, fix, docs, style, refactor, perf, test, chore
- Imperative mood, lowercase description, no period at the end
- Max 72 characters for the subject line
- Output ONLY the commit message line, nothing else

Examples:
feat(auth): add JWT refresh token endpoint
fix(api): handle null user in profile route
docs: update README install steps
refactor(db): extract connection pool helper
test: cover edge case in parse_config
chore: bump dependencies

Diff:
"""


def load_config(config_path: str | Path) -> AppConfig:
    """Load and validate config.yaml."""
    path = Path(config_path)
    if not path.exists():
        raise FileNotFoundError(f"Config not found: {path}")

    with path.open(encoding="utf-8") as fh:
        raw = yaml.safe_load(fh) or {}

    global_raw = raw.get("global") or {}
    global_cfg = GlobalConfig(
        ollama_url=global_raw.get("ollama_url", GlobalConfig.ollama_url),
        default_model=global_raw.get("default_model", GlobalConfig.default_model),
        log_file=global_raw.get("log_file", GlobalConfig.log_file),
    )

    projects: list[ProjectConfig] = []
    for item in raw.get("projects") or []:
        projects.append(project_from_raw(item))

    return AppConfig(projects=projects, global_=global_cfg)


def project_from_raw(item: dict[str, Any]) -> ProjectConfig:
    """Build ProjectConfig from a YAML/JSON mapping."""
    return ProjectConfig(
        name=str(item["name"]).strip(),
        path=str(item["path"]).strip(),
        test_command=str(item.get("test_command", "") or ""),
        test_timeout=int(item.get("test_timeout", 300) or 300),
        auto_pull=bool(item.get("auto_pull", False)),
        github_repo=str(item.get("github_repo", "") or ""),
        branch=str(item.get("branch", "") or ""),
        model=str(item.get("model", "") or ""),
        remote_host=str(item.get("remote_host", "") or ""),
        remote_port=int(item.get("remote_port", 22) or 22),
        ssh_key=str(item.get("ssh_key", "") or ""),
        remote_shell=str(item.get("remote_shell", "bash") or "bash"),
    )


def project_to_dict(project: ProjectConfig) -> dict[str, Any]:
    """Serialize project for API / YAML."""
    data: dict[str, Any] = {
        "name": project.name,
        "path": project.path,
        "test_command": project.test_command,
        "test_timeout": project.test_timeout,
        "auto_pull": project.auto_pull,
        "github_repo": project.github_repo,
        "branch": project.branch,
        "model": project.model,
        "remote_host": project.remote_host,
        "remote_port": project.remote_port,
        "ssh_key": project.ssh_key,
        "remote_shell": project.remote_shell,
    }
    return data


def save_config(config_path: str | Path, config: AppConfig) -> None:
    """Atomically write config.yaml."""
    path = Path(config_path)
    projects_raw: list[dict[str, Any]] = []
    for project in config.projects:
        item = project_to_dict(project)
        # Keep YAML tidy: drop empty optional remote fields
        if not item.get("remote_host"):
            item.pop("remote_host", None)
            item.pop("remote_port", None)
            item.pop("ssh_key", None)
            item.pop("remote_shell", None)
        elif not item.get("ssh_key"):
            item.pop("ssh_key", None)
        projects_raw.append(item)

    payload = {
        "projects": projects_raw,
        "global": {
            "ollama_url": config.global_.ollama_url,
            "default_model": config.global_.default_model,
            "log_file": config.global_.log_file,
        },
    }

    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    with tmp.open("w", encoding="utf-8") as fh:
        fh.write("# Git Assistant with AI — managed by web UI / installer\n")
        yaml.safe_dump(
            payload,
            fh,
            allow_unicode=True,
            default_flow_style=False,
            sort_keys=False,
        )
    tmp.replace(path)


class GitAssistant:
    """Orchestrates tests, AI commit messages, git, and GitHub Actions checks."""

    def __init__(self, config: AppConfig, logger: Optional[logging.Logger] = None) -> None:
        self.config = config
        self.logger = logger or logging.getLogger("git_assistant")

    async def _emit(self, on_log: Optional[LogCallback], message: str, level: int = logging.INFO) -> None:
        """Log and optionally stream a line to the UI."""
        self.logger.log(level, message)
        if on_log:
            await on_log(message)

    @staticmethod
    def _is_remote(project: ProjectConfig) -> bool:
        """True if git/tests must run over SSH on another host."""
        return bool(project.remote_host and project.remote_host.strip())

    @staticmethod
    def _bash_quote(value: str) -> str:
        """Safe single-quote for bash -lc."""
        return "'" + value.replace("'", "'\"'\"'") + "'"

    @staticmethod
    def _ps_quote(value: str) -> str:
        """Safe single-quote for PowerShell."""
        return "'" + value.replace("'", "''") + "'"

    def _ssh_prefix(self, project: ProjectConfig) -> list[str]:
        """Base ssh argv for a remote project."""
        cmd = [
            "ssh",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=8",
            "-o",
            "StrictHostKeyChecking=accept-new",
        ]
        if project.ssh_key:
            cmd.extend(["-i", project.ssh_key])
        if project.remote_port and int(project.remote_port) != 22:
            cmd.extend(["-p", str(project.remote_port)])
        cmd.append(project.remote_host.strip())
        return cmd

    @staticmethod
    def _ps_encoded_command(script: str) -> list[str]:
        """Build powershell -EncodedCommand argv (avoids SSH/cmd quoting hell)."""
        token = base64.b64encode(script.encode("utf-16-le")).decode("ascii")
        return ["powershell", "-NoProfile", "-NonInteractive", "-EncodedCommand", token]

    def _build_remote_argv(self, project: ProjectConfig, args: list[str], cwd: str) -> list[str]:
        """Wrap a command so it runs on the remote host in project.path."""
        shell = (project.remote_shell or "bash").strip().lower()
        ssh = self._ssh_prefix(project)

        if shell == "powershell":
            # EncodedCommand: Windows OpenSSH default shell is often cmd.exe, which
            # mangled -Command quoting and dropped Machine PATH (git/pnpm not found).
            parts = " ".join(self._ps_quote(a) for a in args)
            win_cwd = cwd.replace("/", "\\")
            ps = "\n".join(
                [
                    "$ProgressPreference = 'SilentlyContinue'",
                    "$ErrorActionPreference = 'Continue'",
                    "$machine = [System.Environment]::GetEnvironmentVariable('Path','Machine')",
                    "$user = [System.Environment]::GetEnvironmentVariable('Path','User')",
                    "$extra = 'C:\\Program Files\\Git\\cmd;C:\\Program Files\\Git\\bin;"
                    "C:\\Program Files\\nodejs;C:\\Program Files\\GitHub CLI'",
                    "$env:Path = $extra + ';' + $machine + ';' + $user + ';' + $env:Path",
                    f"Set-Location -LiteralPath {self._ps_quote(win_cwd)}",
                    f"& {parts}",
                    "exit $LASTEXITCODE",
                ]
            )
            return ssh + self._ps_encoded_command(ps)

        if shell == "cmd":
            win_path = cwd.replace("/", "\\")
            joined = " ".join(f'"{a}"' if ((" " in a) or ("&" in a)) else a for a in args)
            # Prepend Git/nodejs so non-interactive SSH sessions find tools
            remote = (
                "set PATH=C:\\Program Files\\Git\\cmd;C:\\Program Files\\Git\\bin;"
                "C:\\Program Files\\nodejs;C:\\Program Files\\GitHub CLI;%PATH% "
                f'&& cd /d "{win_path}" && {joined}'
            )
            return ssh + ["cmd", "/c", remote]

        # bash (Git Bash on Windows, or Linux remote)
        if args and args[0] == "git":
            remote_cmd = (
                "git -C "
                + self._bash_quote(cwd)
                + " "
                + " ".join(self._bash_quote(a) for a in args[1:])
            )
        else:
            remote_cmd = (
                "cd "
                + self._bash_quote(cwd)
                + " && "
                + " ".join(self._bash_quote(a) for a in args)
            )
        return ssh + ["bash", "-lc", remote_cmd]

    async def _run_cmd(
        self,
        args: list[str],
        cwd: Optional[str] = None,
        timeout: Optional[float] = None,
        env: Optional[dict[str, str]] = None,
    ) -> tuple[int, str, str]:
        """Run a local subprocess asynchronously and return (code, stdout, stderr)."""
        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)

        kwargs: dict[str, Any] = {
            "stdout": asyncio.subprocess.PIPE,
            "stderr": asyncio.subprocess.PIPE,
            "env": merged_env,
        }
        if cwd:
            kwargs["cwd"] = cwd

        process = await asyncio.create_subprocess_exec(*args, **kwargs)
        try:
            stdout_b, stderr_b = await asyncio.wait_for(
                process.communicate(),
                timeout=timeout,
            )
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise TimeoutError(f"Command timed out after {timeout}s: {' '.join(args)}")

        stdout = self._decode_bytes(stdout_b or b"")
        stderr = self._decode_bytes(stderr_b or b"")
        code = process.returncode if process.returncode is not None else -1
        return code, stdout, stderr

    @staticmethod
    def _decode_bytes(data: bytes) -> str:
        """Decode subprocess output; Windows SSH often returns CP866/CP1251."""
        if not data:
            return ""
        ranked: list[tuple[int, str]] = []
        for enc in ("utf-8", "cp866", "cp1251", "oem", "latin-1"):
            try:
                text = data.decode(enc)
            except LookupError:
                continue
            except UnicodeDecodeError:
                text = data.decode(enc, errors="replace")
            ranked.append((text.count("\ufffd"), text))
        ranked.sort(key=lambda item: item[0])
        return ranked[0][1]

    async def _run_project_cmd(
        self,
        project: ProjectConfig,
        args: list[str],
        timeout: Optional[float] = None,
    ) -> tuple[int, str, str]:
        """Run a command in the project directory (local or via SSH)."""
        if self._is_remote(project):
            argv = self._build_remote_argv(project, args, project.path)
            return await self._run_cmd(argv, cwd=None, timeout=timeout)
        return await self._run_cmd(args, cwd=project.path, timeout=timeout)

    async def get_status(self, project: ProjectConfig) -> ProjectStatus:
        """Return current branch and whether the working tree has changes."""
        status = ProjectStatus(
            name=project.name,
            path=project.path,
            configured_branch=project.branch,
            github_repo=project.github_repo,
            auto_pull=project.auto_pull,
            test_command=project.test_command,
            remote_host=project.remote_host,
            is_remote=self._is_remote(project),
        )

        if not self._is_remote(project):
            root = Path(project.path)
            if not root.exists():
                status.error = f"Path does not exist: {project.path}"
                return status
            if not (root / ".git").exists():
                status.error = f"Not a git repository: {project.path}"
                return status

        try:
            code, probe, err = await self._run_project_cmd(
                project,
                ["git", "rev-parse", "--is-inside-work-tree"],
                timeout=45,
            )
            if code != 0 or "true" not in probe.lower():
                raw = (err or probe or "Not a git repository").strip()
                status.error = self._format_remote_error(project, raw)
                return status

            code, branch_out, err = await self._run_project_cmd(
                project,
                ["git", "branch", "--show-current"],
                timeout=45,
            )
            if code != 0:
                status.error = self._format_remote_error(
                    project, err.strip() or "Failed to read branch"
                )
                return status
            status.branch = branch_out.strip() or "(detached)"

            code, porcelain, err = await self._run_project_cmd(
                project,
                ["git", "status", "--porcelain"],
                timeout=45,
            )
            if code != 0:
                status.error = self._format_remote_error(
                    project, err.strip() or "Failed to read status"
                )
                return status

            lines = [ln for ln in porcelain.splitlines() if ln.strip()]
            status.change_count = len(lines)
            status.has_changes = status.change_count > 0
        except Exception as exc:  # noqa: BLE001
            status.error = self._format_remote_error(project, str(exc))
            self.logger.exception("get_status failed for %s", project.name)

        return status

    def _format_remote_error(self, project: ProjectConfig, message: str) -> str:
        """Annotate SSH-related failures with host context."""
        text = (message or "").strip()
        if not self._is_remote(project):
            return text
        if f"via SSH {project.remote_host}" not in text:
            text = f"{text} via SSH {project.remote_host}"
        return text

    @staticmethod
    def ssh_hint_for_error(error: Optional[str]) -> str:
        """Human hint for common SSH failures (UI / API)."""
        low = (error or "").lower()
        if not low:
            return ""
        if "timed out" in low or "connection timed out" in low:
            return (
                "Сервер не достучался до Windows по SSH (порт 22). "
                "На ПК: служба OpenSSH Server должна быть запущена; "
                "в Firewall разрешён входящий TCP 22; IP должен быть доступен с сервера. "
                "Проверка с сервера: ssh -v -o ConnectTimeout=5 user@ip"
            )
        if "permission denied" in low or "publickey" in low:
            return (
                "Хост отвечает, но ключ/логин не принят. "
                "Нужен вход по ключу без пароля (BatchMode)."
            )
        if "connection refused" in low or "refused" in low:
            return (
                "Connection refused — на Windows никто не слушает порт 22. "
                "Установите и запустите OpenSSH Server."
            )
        return ""

    async def doctor(self) -> dict[str, Any]:
        """Collect environment health checks for the System page."""
        checks: list[dict[str, Any]] = []

        def add(name: str, ok: bool, detail: str = "") -> None:
            checks.append({"name": name, "ok": bool(ok), "detail": detail})

        add("git", shutil.which("git") is not None, shutil.which("git") or "not found")
        add("ssh", shutil.which("ssh") is not None, shutil.which("ssh") or "not found")
        add("gh", shutil.which("gh") is not None, shutil.which("gh") or "not found")
        add("ollama_cli", shutil.which("ollama") is not None, shutil.which("ollama") or "not found")

        ollama_url = self.config.global_.ollama_url.rstrip("/")
        ollama_ok = False
        ollama_detail = ollama_url
        try:
            async with httpx.AsyncClient(timeout=5.0) as client:
                resp = await client.get(f"{ollama_url}/api/tags")
                ollama_ok = resp.status_code == 200
                if ollama_ok:
                    models = [m.get("name", "") for m in (resp.json().get("models") or [])]
                    default = self.config.global_.default_model
                    has_default = any(default == m or m.startswith(default + ":") or default.startswith(m) for m in models)
                    ollama_detail = (
                        f"{ollama_url} · models={len(models)}"
                        + (f" · default={default}{' ✓' if has_default else ' (не скачана?)'}" if default else "")
                    )
                else:
                    ollama_detail = f"{ollama_url} · HTTP {resp.status_code}"
        except Exception as exc:  # noqa: BLE001
            ollama_detail = f"{ollama_url} · {exc}"
        add("ollama_api", ollama_ok, ollama_detail)

        gh_auth_ok = False
        gh_auth_detail = "gh not installed"
        if shutil.which("gh"):
            code, out, err = await self._run_cmd(["gh", "auth", "status"], timeout=15)
            gh_auth_ok = code == 0
            gh_auth_detail = (out or err or "").strip().splitlines()[0] if (out or err) else f"exit {code}"
        add("gh_auth", gh_auth_ok, gh_auth_detail)

        remotes = [
            {"name": p.name, "host": p.remote_host, "shell": p.remote_shell}
            for p in self.config.projects
            if self._is_remote(p)
        ]
        add(
            "projects",
            True,
            f"{len(self.config.projects)} total, {len(remotes)} remote SSH",
        )

        ok_count = sum(1 for c in checks if c["ok"])
        critical = ("git", "ssh", "ollama_api")
        critical_ok = all(c["ok"] for c in checks if c["name"] in critical)
        return {
            "ok": critical_ok,
            "summary": f"{ok_count}/{len(checks)} checks ok",
            "checks": checks,
            "settings": {
                "ollama_url": self.config.global_.ollama_url,
                "default_model": self.config.global_.default_model,
                "log_file": self.config.global_.log_file,
            },
            "remote_projects": remotes,
        }

    async def get_diff(self, project: ProjectConfig, max_chars: int = 12000) -> str:
        """Collect unstaged + staged diff for the AI prompt."""
        parts: list[str] = []
        for args in (
            ["git", "diff", "--stat"],
            ["git", "diff"],
            ["git", "diff", "--cached"],
        ):
            code, out, _ = await self._run_project_cmd(project, args, timeout=90)
            if code == 0 and out.strip():
                parts.append(out)
        diff = "\n".join(parts).strip()
        if not diff:
            code, out, _ = await self._run_project_cmd(
                project,
                ["git", "status", "--short"],
                timeout=45,
            )
            diff = out.strip() or "(no diff available)"
        if len(diff) > max_chars:
            diff = diff[:max_chars] + "\n... [diff truncated]"
        return diff

    async def generate_commit_message(
        self,
        project: ProjectConfig,
        diff: str,
        on_log: Optional[LogCallback] = None,
    ) -> str:
        """Ask Ollama for a Conventional Commits message; fall back on failure."""
        model = project.model or self.config.global_.default_model
        fallback = f"Auto-commit: {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}"
        url = f"{self.config.global_.ollama_url.rstrip('/')}/api/generate"
        prompt = COMMIT_PROMPT + diff

        await self._emit(on_log, f"[{project.name}] Generating commit message with {model}...")
        try:
            async with httpx.AsyncClient(timeout=120.0) as client:
                response = await client.post(
                    url,
                    json={
                        "model": model,
                        "prompt": prompt,
                        "stream": False,
                        "options": {"temperature": 0.2, "num_predict": 80},
                    },
                )
                response.raise_for_status()
                data = response.json()
                raw = (data.get("response") or "").strip()
                message = self._sanitize_commit_message(raw)
                if not message:
                    await self._emit(
                        on_log,
                        f"[{project.name}] AI returned empty message, using fallback",
                        logging.WARNING,
                    )
                    return fallback
                await self._emit(on_log, f"[{project.name}] Commit message: {message}")
                return message
        except Exception as exc:  # noqa: BLE001
            await self._emit(
                on_log,
                f"[{project.name}] Ollama unavailable ({exc}), using fallback",
                logging.WARNING,
            )
            return fallback

    @staticmethod
    def _sanitize_commit_message(raw: str) -> str:
        """Take the first non-empty line and strip quotes/markdown fences."""
        for line in raw.splitlines():
            line = line.strip().strip("`").strip('"').strip("'")
            if not line or line.lower().startswith("commit"):
                continue
            line = re.sub(r"^[-*]\s+", "", line)
            if line:
                return line[:200]
        return ""

    async def run_tests(
        self,
        project: ProjectConfig,
        on_log: Optional[LogCallback] = None,
    ) -> tuple[bool, str]:
        """Run project test_command; return (ok, full_output)."""
        if not project.test_command or not project.test_command.strip():
            await self._emit(on_log, f"[{project.name}] No test_command configured, skipping tests")
            return True, ""

        await self._emit(
            on_log,
            f"[{project.name}] Running tests: {project.test_command} (timeout={project.test_timeout}s)",
        )
        try:
            posix = True
            if self._is_remote(project) and (project.remote_shell or "bash").lower() in (
                "cmd",
                "powershell",
            ):
                posix = False
            args = shlex.split(project.test_command, posix=posix)
            code, stdout, stderr = await self._run_project_cmd(
                project,
                args,
                timeout=float(project.test_timeout),
            )
            output = (stdout + ("\n" + stderr if stderr else "")).strip()
            if code == 0:
                await self._emit(on_log, f"[{project.name}] Tests PASSED")
                return True, output
            await self._emit(on_log, f"[{project.name}] Tests FAILED (exit {code})", logging.ERROR)
            for line in output.splitlines()[:20]:
                await self._emit(on_log, f"  {line}", logging.ERROR)
            if output.count("\n") > 20:
                await self._emit(on_log, "  ... (see full test output in result)", logging.ERROR)
            return False, output
        except TimeoutError as exc:
            msg = str(exc)
            await self._emit(on_log, f"[{project.name}] {msg}", logging.ERROR)
            return False, msg
        except Exception as exc:  # noqa: BLE001
            msg = f"Failed to run tests: {exc}"
            await self._emit(on_log, f"[{project.name}] {msg}", logging.ERROR)
            return False, msg

    async def _current_branch(self, project: ProjectConfig) -> str:
        """Prefer the checked-out branch; fall back to config."""
        code, out, _ = await self._run_project_cmd(
            project,
            ["git", "branch", "--show-current"],
            timeout=45,
        )
        current = (out or "").strip()
        if code == 0 and current:
            return current
        return (project.branch or "").strip()

    async def pull_rebase(
        self,
        project: ProjectConfig,
        on_log: Optional[LogCallback] = None,
    ) -> tuple[bool, str]:
        """Run git pull --rebase; abort on conflict."""
        # Use the real checkout (master), not a stale config default like "main"
        branch = await self._current_branch(project)
        await self._emit(
            on_log,
            f"[{project.name}] git pull --rebase" + (f" (branch {branch})" if branch else ""),
        )
        try:
            args = ["git", "pull", "--rebase"]
            if branch:
                args.extend(["origin", branch])
            code, stdout, stderr = await self._run_project_cmd(project, args, timeout=180)
            combined = (stdout + "\n" + stderr).strip()
            if code != 0:
                if "conflict" in combined.lower() or "CONFLICT" in combined:
                    await self._emit(
                        on_log,
                        f"[{project.name}] Rebase conflict detected, aborting",
                        logging.ERROR,
                    )
                    await self._run_project_cmd(project, ["git", "rebase", "--abort"], timeout=45)
                    return False, combined or "Rebase conflict"
                await self._emit(on_log, f"[{project.name}] Pull failed: {combined}", logging.ERROR)
                return False, combined or "git pull failed"
            await self._emit(on_log, f"[{project.name}] Pull OK")
            return True, combined
        except Exception as exc:  # noqa: BLE001
            msg = str(exc)
            await self._emit(on_log, f"[{project.name}] Pull error: {msg}", logging.ERROR)
            return False, msg

    async def _has_unmerged(self, project: ProjectConfig) -> bool:
        """Return True if the index has unmerged (conflict) paths."""
        code, out, _ = await self._run_project_cmd(
            project,
            ["git", "diff", "--name-only", "--diff-filter=U"],
            timeout=45,
        )
        return code == 0 and bool(out.strip())

    async def git_commit_push(
        self,
        project: ProjectConfig,
        message: str,
        on_log: Optional[LogCallback] = None,
    ) -> tuple[bool, str]:
        """git add ., commit, conflict check, push."""
        try:
            if await self._has_unmerged(project):
                await self._emit(
                    on_log,
                    f"[{project.name}] Unresolved conflicts present, aborting",
                    logging.ERROR,
                )
                return False, "Unresolved merge/rebase conflicts"

            await self._emit(on_log, f"[{project.name}] git add .")
            code, _, err = await self._run_project_cmd(project, ["git", "add", "."], timeout=90)
            if code != 0:
                return False, err or "git add failed"

            await self._emit(on_log, f"[{project.name}] git commit")
            code, out, err = await self._run_project_cmd(
                project,
                ["git", "commit", "-m", message],
                timeout=90,
            )
            if code != 0:
                combined = (out + "\n" + err).strip()
                if "nothing to commit" in combined.lower():
                    await self._emit(on_log, f"[{project.name}] Nothing to commit", logging.WARNING)
                    return False, combined
                await self._emit(on_log, f"[{project.name}] Commit failed: {combined}", logging.ERROR)
                return False, combined

            if await self._has_unmerged(project):
                await self._emit(on_log, f"[{project.name}] Conflicts detected before push", logging.ERROR)
                return False, "Conflicts detected before push"

            push_args = ["git", "push"]
            branch = await self._current_branch(project)
            if branch:
                push_args.extend(["-u", "origin", branch])
            await self._emit(on_log, f"[{project.name}] {' '.join(push_args)}")
            code, out, err = await self._run_project_cmd(project, push_args, timeout=180)
            combined = (out + "\n" + err).strip()
            if code != 0:
                await self._emit(on_log, f"[{project.name}] Push failed: {combined}", logging.ERROR)
                return False, combined or "git push failed"

            await self._emit(on_log, f"[{project.name}] Push OK")
            return True, combined
        except Exception as exc:  # noqa: BLE001
            msg = str(exc)
            await self._emit(on_log, f"[{project.name}] Git error: {msg}", logging.ERROR)
            return False, msg

    async def has_github_workflows(self, project: ProjectConfig) -> bool:
        """Check whether .github/workflows exists (local or remote)."""
        if not self._is_remote(project):
            workflows = Path(project.path) / ".github" / "workflows"
            return workflows.is_dir() and any(workflows.iterdir())

        code, out, _ = await self._run_project_cmd(
            project,
            ["git", "ls-files", ".github/workflows"],
            timeout=45,
        )
        return code == 0 and bool(out.strip())

    def _local_cwd(self, project: ProjectConfig) -> Optional[str]:
        """cwd for commands that must run on the Git Assistant host (not via SSH)."""
        if self._is_remote(project):
            return None
        path = Path(project.path)
        return str(path) if path.is_dir() else None

    async def check_actions(
        self,
        project: ProjectConfig,
        on_log: Optional[LogCallback] = None,
        wait_seconds: int = 30,
    ) -> dict[str, Any]:
        """Wait briefly, then fetch the latest Actions run via GitHub CLI (`gh`)."""
        result: dict[str, Any] = {
            "status": "skipped",
            "conclusion": "",
            "html_url": "",
            "message": "",
        }

        if not project.github_repo:
            result["message"] = "No github_repo configured"
            return result

        try:
            has_workflows = await self.has_github_workflows(project)
        except Exception as exc:  # noqa: BLE001
            result["status"] = "unknown"
            result["message"] = f"Could not inspect workflows: {exc}"
            await self._emit(
                on_log,
                f"[{project.name}] Skipping Actions check: {exc}",
                logging.WARNING,
            )
            return result

        if not has_workflows:
            result["message"] = "No .github/workflows found"
            await self._emit(
                on_log,
                f"[{project.name}] No GitHub workflows directory, skipping Actions check",
            )
            return result

        if not shutil.which("gh"):
            result["status"] = "unknown"
            result["message"] = "gh CLI not found"
            await self._emit(
                on_log,
                f"[{project.name}] gh CLI not found — install GitHub CLI to check Actions",
                logging.WARNING,
            )
            return result

        # gh always runs on the Git Assistant server (never use Windows remote path as cwd)
        gh_cwd = self._local_cwd(project)

        try:
            auth_code, _, auth_err = await self._run_cmd(
                ["gh", "auth", "status"],
                cwd=gh_cwd,
                timeout=30,
            )
        except Exception as exc:  # noqa: BLE001
            result["status"] = "unknown"
            result["message"] = f"gh auth check failed: {exc}"
            await self._emit(
                on_log,
                f"[{project.name}] gh auth check failed: {exc}",
                logging.WARNING,
            )
            return result

        if auth_code != 0:
            result["status"] = "unknown"
            result["message"] = "gh not authenticated (run: gh auth login)"
            await self._emit(
                on_log,
                f"[{project.name}] gh not logged in — run: gh auth login",
                logging.WARNING,
            )
            if auth_err.strip():
                await self._emit(on_log, f"[{project.name}] {auth_err.strip()}", logging.WARNING)
            return result

        await self._emit(
            on_log,
            f"[{project.name}] Waiting {wait_seconds}s before checking GitHub Actions (gh)...",
        )
        await asyncio.sleep(wait_seconds)

        try:
            code, stdout, stderr = await self._run_cmd(
                [
                    "gh",
                    "run",
                    "list",
                    "--repo",
                    project.github_repo,
                    "--limit",
                    "1",
                    "--json",
                    "status,conclusion,url,databaseId,displayTitle,headBranch",
                ],
                cwd=gh_cwd,
                timeout=60,
            )
            if code != 0:
                combined = (stderr or stdout or "gh run list failed").strip()
                result["status"] = "error"
                result["message"] = combined
                await self._emit(
                    on_log,
                    f"[{project.name}] gh run list failed: {combined}",
                    logging.ERROR,
                )
                return result

            runs = json.loads(stdout or "[]")
            if not runs:
                result["status"] = "unknown"
                result["message"] = "No workflow runs found"
                await self._emit(on_log, f"[{project.name}] No Actions runs yet")
                return result

            run = runs[0]
            status = run.get("status") or "unknown"
            conclusion = run.get("conclusion") or ""
            result["status"] = status
            result["conclusion"] = conclusion or ""
            result["html_url"] = run.get("url") or ""
            title = run.get("displayTitle") or ""
            label = conclusion or status
            extra = f" — {title}" if title else ""
            await self._emit(
                on_log,
                f"[{project.name}] GitHub Actions: {label}{extra} ({result['html_url']})",
            )
            return result
        except json.JSONDecodeError as exc:
            result["status"] = "error"
            result["message"] = f"Invalid gh JSON: {exc}"
            await self._emit(on_log, f"[{project.name}] {result['message']}", logging.ERROR)
            return result
        except Exception as exc:  # noqa: BLE001
            result["status"] = "error"
            result["message"] = str(exc)
            await self._emit(on_log, f"[{project.name}] Actions check failed: {exc}", logging.ERROR)
            return result

    def _actions_label(self, actions: dict[str, Any]) -> str:
        """Human-readable Actions badge text."""
        status = actions.get("status") or ""
        conclusion = actions.get("conclusion") or ""
        if status == "skipped":
            return "skipped"
        if status == "completed":
            if conclusion == "success":
                return "success"
            if conclusion in ("failure", "cancelled", "timed_out"):
                return "failure"
            return conclusion or "completed"
        if status in ("queued", "in_progress", "pending", "waiting", "requested"):
            return "running"
        if status in ("error", "unknown"):
            return status
        return status or "unknown"

    async def test_remote_connection(
        self,
        project: ProjectConfig,
    ) -> dict[str, Any]:
        """Probe SSH + git access for a remote project."""
        result: dict[str, Any] = {
            "ok": False,
            "steps": [],
            "hint": "",
        }
        if not self._is_remote(project):
            result["steps"].append({"name": "remote", "ok": False, "detail": "Проект не remote"})
            result["hint"] = "Включите SSH remote в настройках проекта"
            return result

        # 1) plain SSH echo
        ssh = self._ssh_prefix(project)
        try:
            code, out, err = await self._run_cmd(
                ssh + ["echo", "GIT_ASSISTANT_SSH_OK"],
                cwd=None,
                timeout=20,
            )
            detail = (out or err or "").strip()
            ok = code == 0 and "GIT_ASSISTANT_SSH_OK" in detail
            result["steps"].append(
                {
                    "name": "ssh",
                    "ok": ok,
                    "detail": detail or f"exit {code}",
                }
            )
            if not ok:
                result["hint"] = self.ssh_hint_for_error(detail + " " + err) or (
                    "SSH до хоста не прошёл. См. вывод шага ssh."
                )
                return result
        except Exception as exc:  # noqa: BLE001
            result["steps"].append({"name": "ssh", "ok": False, "detail": str(exc)})
            result["hint"] = str(exc)
            return result

        # 2) git inside project path
        try:
            code, out, err = await self._run_project_cmd(
                project,
                ["git", "rev-parse", "--is-inside-work-tree"],
                timeout=30,
            )
            detail = (out or err or "").strip()
            ok = code == 0 and "true" in detail.lower()
            result["steps"].append(
                {
                    "name": "git",
                    "ok": ok,
                    "detail": detail or f"exit {code}",
                }
            )
            if not ok:
                result["hint"] = (
                    f"SSH ок, но путь не git-репозиторий или недоступен: {project.path}. "
                    "Проверьте path и remote_shell (для Windows обычно powershell)."
                )
                return result
        except Exception as exc:  # noqa: BLE001
            result["steps"].append({"name": "git", "ok": False, "detail": str(exc)})
            result["hint"] = str(exc)
            return result

        # 3) branch + dirty summary
        try:
            status = await self.get_status(project)
            result["steps"].append(
                {
                    "name": "status",
                    "ok": not bool(status.error),
                    "detail": (
                        f"branch={status.branch}, changes={status.change_count}"
                        if not status.error
                        else status.error
                    ),
                }
            )
            result["ok"] = not bool(status.error)
            if status.error:
                result["hint"] = status.error
            else:
                result["hint"] = "SSH и git работают"
        except Exception as exc:  # noqa: BLE001
            result["steps"].append({"name": "status", "ok": False, "detail": str(exc)})
            result["hint"] = str(exc)

        return result

    async def pull_only(
        self,
        project: ProjectConfig,
        on_log: Optional[LogCallback] = None,
    ) -> JobResult:
        """Standalone pull --rebase job."""
        result = JobResult()
        await self._emit(on_log, f"[{project.name}] Starting pull...")
        ok, detail = await self.pull_rebase(project, on_log)
        result.success = ok
        if not ok:
            result.error = detail
        await self._emit(on_log, f"[{project.name}] Pull finished: {'OK' if ok else 'FAILED'}")
        return result

    async def smart_commit(
        self,
        project: ProjectConfig,
        on_log: Optional[LogCallback] = None,
        skip_tests: bool = False,
    ) -> JobResult:
        """Full pipeline: optional pull → tests → AI message → commit → push → Actions."""
        result = JobResult(skipped_tests=skip_tests)
        mode = "Force Commit" if skip_tests else "Smart Commit"
        await self._emit(on_log, f"[{project.name}] === {mode} started ===")
        if self._is_remote(project):
            await self._emit(
                on_log,
                f"[{project.name}] Remote SSH: {project.remote_host} ({project.remote_shell})",
            )

        status = await self.get_status(project)
        if status.error:
            result.error = status.error
            await self._emit(on_log, f"[{project.name}] {status.error}", logging.ERROR)
            return result
        if not status.has_changes:
            result.error = "No changes to commit"
            await self._emit(on_log, f"[{project.name}] No changes to commit", logging.WARNING)
            return result

        await self._emit(
            on_log,
            f"[{project.name}] Branch={status.branch}, changes={status.change_count}, path={project.path}",
        )

        if project.auto_pull:
            ok, detail = await self.pull_rebase(project, on_log)
            if not ok:
                result.error = detail
                return result

        if not skip_tests:
            ok, test_out = await self.run_tests(project, on_log)
            result.test_output = test_out
            if not ok:
                result.error = "Tests failed — commit aborted"
                await self._emit(
                    on_log,
                    f"[{project.name}] Commit aborted due to failed tests",
                    logging.ERROR,
                )
                return result
        else:
            await self._emit(
                on_log,
                f"[{project.name}] Tests SKIPPED (force commit)",
                logging.WARNING,
            )

        diff = await self.get_diff(project)
        message = await self.generate_commit_message(project, diff, on_log)
        result.commit_message = message

        ok, detail = await self.git_commit_push(project, message, on_log)
        if not ok:
            result.error = detail
            return result

        # Push already succeeded — Actions probe must not fail the whole job
        try:
            actions = await self.check_actions(project, on_log)
            result.actions_status = self._actions_label(actions)
            result.actions_conclusion = actions.get("conclusion") or ""
        except Exception as exc:  # noqa: BLE001
            await self._emit(
                on_log,
                f"[{project.name}] Actions check skipped after error: {exc}",
                logging.WARNING,
            )
            result.actions_status = "unknown"

        result.success = True
        await self._emit(on_log, f"[{project.name}] === {mode} completed successfully ===")
        return result

    async def force_commit(
        self,
        project: ProjectConfig,
        on_log: Optional[LogCallback] = None,
    ) -> JobResult:
        """Commit without running tests."""
        return await self.smart_commit(project, on_log=on_log, skip_tests=True)

"""Git Assistant core: git ops, tests, Ollama commit messages, GitHub Actions."""

from __future__ import annotations

import asyncio
import logging
import os
import re
import shlex
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


@dataclass
class GlobalConfig:
    """Global settings from config.yaml."""

    ollama_url: str = "http://localhost:11434"
    default_model: str = "qwen2.5-coder:3b"
    github_token_env: str = "GITHUB_TOKEN"
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
        github_token_env=global_raw.get("github_token_env", GlobalConfig.github_token_env),
        log_file=global_raw.get("log_file", GlobalConfig.log_file),
    )

    projects: list[ProjectConfig] = []
    for item in raw.get("projects") or []:
        projects.append(
            ProjectConfig(
                name=item["name"],
                path=item["path"],
                test_command=item.get("test_command", ""),
                test_timeout=int(item.get("test_timeout", 300)),
                auto_pull=bool(item.get("auto_pull", False)),
                github_repo=item.get("github_repo", ""),
                branch=item.get("branch", ""),
                model=item.get("model", ""),
            )
        )

    return AppConfig(projects=projects, global_=global_cfg)


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

    async def _run_cmd(
        self,
        args: list[str],
        cwd: str,
        timeout: Optional[float] = None,
        env: Optional[dict[str, str]] = None,
    ) -> tuple[int, str, str]:
        """Run a subprocess asynchronously and return (code, stdout, stderr)."""
        merged_env = os.environ.copy()
        if env:
            merged_env.update(env)

        process = await asyncio.create_subprocess_exec(
            *args,
            cwd=cwd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            env=merged_env,
        )
        try:
            stdout_b, stderr_b = await asyncio.wait_for(
                process.communicate(),
                timeout=timeout,
            )
        except asyncio.TimeoutError:
            process.kill()
            await process.wait()
            raise TimeoutError(f"Command timed out after {timeout}s: {' '.join(args)}")

        stdout = (stdout_b or b"").decode("utf-8", errors="replace")
        stderr = (stderr_b or b"").decode("utf-8", errors="replace")
        code = process.returncode if process.returncode is not None else -1
        return code, stdout, stderr

    async def get_status(self, project: ProjectConfig) -> ProjectStatus:
        """Return current branch and whether the working tree has changes."""
        status = ProjectStatus(
            name=project.name,
            path=project.path,
            configured_branch=project.branch,
            github_repo=project.github_repo,
            auto_pull=project.auto_pull,
            test_command=project.test_command,
        )

        root = Path(project.path)
        if not root.exists():
            status.error = f"Path does not exist: {project.path}"
            return status
        if not (root / ".git").exists():
            status.error = f"Not a git repository: {project.path}"
            return status

        try:
            code, branch_out, err = await self._run_cmd(
                ["git", "branch", "--show-current"],
                cwd=project.path,
                timeout=30,
            )
            if code != 0:
                status.error = err.strip() or "Failed to read branch"
                return status
            status.branch = branch_out.strip() or "(detached)"

            code, porcelain, err = await self._run_cmd(
                ["git", "status", "--porcelain"],
                cwd=project.path,
                timeout=30,
            )
            if code != 0:
                status.error = err.strip() or "Failed to read status"
                return status

            lines = [ln for ln in porcelain.splitlines() if ln.strip()]
            status.change_count = len(lines)
            status.has_changes = status.change_count > 0
        except Exception as exc:  # noqa: BLE001
            status.error = str(exc)
            self.logger.exception("get_status failed for %s", project.name)

        return status

    async def get_diff(self, project: ProjectConfig, max_chars: int = 12000) -> str:
        """Collect unstaged + staged diff for the AI prompt."""
        parts: list[str] = []
        for args in (
            ["git", "diff", "--stat"],
            ["git", "diff"],
            ["git", "diff", "--cached"],
        ):
            code, out, _ = await self._run_cmd(args, cwd=project.path, timeout=60)
            if code == 0 and out.strip():
                parts.append(out)
        diff = "\n".join(parts).strip()
        if not diff:
            code, out, _ = await self._run_cmd(
                ["git", "status", "--short"],
                cwd=project.path,
                timeout=30,
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
            args = shlex.split(project.test_command)
            code, stdout, stderr = await self._run_cmd(
                args,
                cwd=project.path,
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

    async def pull_rebase(
        self,
        project: ProjectConfig,
        on_log: Optional[LogCallback] = None,
    ) -> tuple[bool, str]:
        """Run git pull --rebase; abort on conflict."""
        branch = project.branch
        await self._emit(
            on_log,
            f"[{project.name}] git pull --rebase" + (f" (branch {branch})" if branch else ""),
        )
        try:
            args = ["git", "pull", "--rebase"]
            if branch:
                args.extend(["origin", branch])
            code, stdout, stderr = await self._run_cmd(args, cwd=project.path, timeout=180)
            combined = (stdout + "\n" + stderr).strip()
            if code != 0:
                if "conflict" in combined.lower() or "CONFLICT" in combined:
                    await self._emit(
                        on_log,
                        f"[{project.name}] Rebase conflict detected, aborting",
                        logging.ERROR,
                    )
                    await self._run_cmd(["git", "rebase", "--abort"], cwd=project.path, timeout=30)
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
        code, out, _ = await self._run_cmd(
            ["git", "diff", "--name-only", "--diff-filter=U"],
            cwd=project.path,
            timeout=30,
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
            code, _, err = await self._run_cmd(["git", "add", "."], cwd=project.path, timeout=60)
            if code != 0:
                return False, err or "git add failed"

            await self._emit(on_log, f"[{project.name}] git commit")
            code, out, err = await self._run_cmd(
                ["git", "commit", "-m", message],
                cwd=project.path,
                timeout=60,
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
            if project.branch:
                push_args.extend(["-u", "origin", project.branch])
            await self._emit(on_log, f"[{project.name}] {' '.join(push_args)}")
            code, out, err = await self._run_cmd(push_args, cwd=project.path, timeout=180)
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
        """Check whether .github/workflows exists."""
        workflows = Path(project.path) / ".github" / "workflows"
        return workflows.is_dir() and any(workflows.iterdir())

    async def check_actions(
        self,
        project: ProjectConfig,
        on_log: Optional[LogCallback] = None,
        wait_seconds: int = 30,
    ) -> dict[str, Any]:
        """Wait briefly, then fetch the latest GitHub Actions run status."""
        result: dict[str, Any] = {
            "status": "skipped",
            "conclusion": "",
            "html_url": "",
            "message": "",
        }

        if not project.github_repo:
            result["message"] = "No github_repo configured"
            return result

        if not await self.has_github_workflows(project):
            result["message"] = "No .github/workflows found"
            await self._emit(
                on_log,
                f"[{project.name}] No GitHub workflows directory, skipping Actions check",
            )
            return result

        token_env = self.config.global_.github_token_env
        token = os.environ.get(token_env, "")
        if not token:
            result["status"] = "unknown"
            result["message"] = f"{token_env} not set"
            await self._emit(
                on_log,
                f"[{project.name}] {token_env} not set, cannot check Actions",
                logging.WARNING,
            )
            return result

        await self._emit(
            on_log,
            f"[{project.name}] Waiting {wait_seconds}s before checking GitHub Actions...",
        )
        await asyncio.sleep(wait_seconds)

        url = f"https://api.github.com/repos/{project.github_repo}/actions/runs"
        headers = {
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        }
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.get(url, headers=headers, params={"per_page": 1})
                if response.status_code == 401:
                    result["status"] = "error"
                    result["message"] = "GitHub API 401 — check token"
                    await self._emit(on_log, f"[{project.name}] {result['message']}", logging.ERROR)
                    return result
                response.raise_for_status()
                runs = response.json().get("workflow_runs") or []
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
                result["html_url"] = run.get("html_url") or ""
                label = conclusion or status
                await self._emit(
                    on_log,
                    f"[{project.name}] GitHub Actions: {label} ({result['html_url']})",
                )
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
            f"[{project.name}] Branch={status.branch}, changes={status.change_count}",
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

        actions = await self.check_actions(project, on_log)
        result.actions_status = self._actions_label(actions)
        result.actions_conclusion = actions.get("conclusion") or ""
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

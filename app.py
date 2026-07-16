"""Git Assistant with AI — FastAPI web UI, REST API, and SSE live logs."""

from __future__ import annotations

import asyncio
import json
import re
import uuid
from contextlib import asynccontextmanager
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, AsyncIterator, Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
from pydantic import BaseModel, Field

from git_assistant import (
    GitAssistant,
    JobResult,
    load_config,
    project_from_raw,
    project_to_dict,
    save_config,
    setup_logging,
)

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "config.yaml"
CONFIG_EXAMPLE = BASE_DIR / "config.example.yaml"

if not CONFIG_PATH.exists() and CONFIG_EXAMPLE.exists():
    CONFIG_PATH.write_text(CONFIG_EXAMPLE.read_text(encoding="utf-8"), encoding="utf-8")

app_config = load_config(CONFIG_PATH)
logger = setup_logging(app_config.global_.log_file)
assistant = GitAssistant(app_config, logger=logger)
config_lock = asyncio.Lock()


@dataclass
class JobState:
    """In-memory job tracking for SSE and status polling."""

    job_id: str
    project: str
    action: str
    queue: asyncio.Queue[Optional[str]] = field(default_factory=asyncio.Queue)
    logs: list[str] = field(default_factory=list)
    done: bool = False
    result: Optional[JobResult] = None
    started_at: str = field(
        default_factory=lambda: datetime.now(timezone.utc).isoformat()
    )


jobs: dict[str, JobState] = {}
active_projects: set[str] = set()
jobs_lock = asyncio.Lock()


class ProjectIn(BaseModel):
    """Payload for create/update project."""

    name: str = Field(..., min_length=1, max_length=64)
    path: str = Field(..., min_length=1)
    test_command: str = ""
    test_timeout: int = Field(default=300, ge=10, le=7200)
    auto_pull: bool = False
    github_repo: str = ""
    branch: str = ""
    model: str = ""
    remote_host: str = ""
    remote_port: int = Field(default=22, ge=1, le=65535)
    ssh_key: str = ""
    remote_shell: str = "bash"


class SettingsIn(BaseModel):
    """Global settings payload."""

    ollama_url: str = Field(..., min_length=1)
    default_model: str = Field(..., min_length=1)
    log_file: str = ""


def reload_runtime() -> None:
    """Reload config.yaml into memory."""
    global app_config, assistant
    app_config = load_config(CONFIG_PATH)
    assistant.config = app_config
    logger.info("Config reloaded — %d project(s)", len(app_config.projects))


@asynccontextmanager
async def lifespan(_app: FastAPI) -> AsyncIterator[None]:
    """Application lifespan hook."""
    logger.info("Git Assistant starting — %d project(s) loaded", len(app_config.projects))
    yield
    logger.info("Git Assistant shutting down")


app = FastAPI(title="Git Assistant with AI", lifespan=lifespan)
app.mount("/static", StaticFiles(directory=str(BASE_DIR / "static")), name="static")
templates = Jinja2Templates(directory=str(BASE_DIR / "templates"))


def _status_to_dict(status: Any) -> dict[str, Any]:
    """Convert ProjectStatus dataclass to JSON-safe dict."""
    return asdict(status)


def _validate_name(name: str) -> str:
    name = name.strip()
    if not re.fullmatch(r"[A-Za-z0-9._\-]+", name):
        raise HTTPException(
            status_code=400,
            detail="Имя проекта: только латиница, цифры, . _ -",
        )
    return name


async def _collect_statuses() -> list[dict[str, Any]]:
    """Fetch git status for all configured projects (in parallel)."""

    async def one(project: Any) -> dict[str, Any]:
        status = await assistant.get_status(project)
        row = _status_to_dict(status)
        row["config"] = project_to_dict(project)
        row["ssh_hint"] = GitAssistant.ssh_hint_for_error(status.error)
        return row

    return list(await asyncio.gather(*[one(p) for p in app_config.projects]))


async def _start_job(project_name: str, action: str) -> str:
    """Create a background job; raise 404/409 on invalid/busy project."""
    project = app_config.get_project(project_name)
    if not project:
        raise HTTPException(status_code=404, detail=f"Project not found: {project_name}")

    async with jobs_lock:
        if project_name in active_projects:
            raise HTTPException(
                status_code=409,
                detail=f"A job is already running for project '{project_name}'",
            )
        job_id = uuid.uuid4().hex
        state = JobState(job_id=job_id, project=project_name, action=action)
        jobs[job_id] = state
        active_projects.add(project_name)

    asyncio.create_task(_run_job(state))
    return job_id


async def _run_job(state: JobState) -> None:
    """Execute the requested action and stream log lines into the job queue."""

    async def on_log(line: str) -> None:
        stamp = datetime.now().strftime("%H:%M:%S")
        formatted = f"{stamp} | {line}"
        state.logs.append(formatted)
        await state.queue.put(formatted)

    project = app_config.get_project(state.project)
    assert project is not None

    try:
        if state.action == "smart-commit":
            result = await assistant.smart_commit(project, on_log=on_log)
        elif state.action == "force-commit":
            result = await assistant.force_commit(project, on_log=on_log)
        elif state.action == "pull":
            result = await assistant.pull_only(project, on_log=on_log)
        else:
            result = JobResult(success=False, error=f"Unknown action: {state.action}")
        state.result = result
    except Exception as exc:  # noqa: BLE001
        logger.exception("Job %s failed", state.job_id)
        err = f"Unhandled error: {exc}"
        await on_log(err)
        state.result = JobResult(success=False, error=err)
    finally:
        state.done = True
        await state.queue.put(None)
        async with jobs_lock:
            active_projects.discard(state.project)


@app.get("/", response_class=HTMLResponse)
async def index(request: Request) -> HTMLResponse:
    """Render the dashboard with current project statuses."""
    statuses = await _collect_statuses()
    return templates.TemplateResponse(
        request,
        "index.html",
        {
            "projects": statuses,
            "default_model": app_config.global_.default_model,
            "ollama_url": app_config.global_.ollama_url,
            "log_file": app_config.global_.log_file,
        },
    )


@app.get("/api/settings")
async def api_get_settings() -> dict[str, Any]:
    """Return global settings."""
    return {
        "ollama_url": app_config.global_.ollama_url,
        "default_model": app_config.global_.default_model,
        "log_file": app_config.global_.log_file,
        "projects_count": len(app_config.projects),
    }


@app.put("/api/settings")
async def api_put_settings(body: SettingsIn) -> dict[str, Any]:
    """Update global settings in config.yaml."""
    async with config_lock:
        app_config.global_.ollama_url = body.ollama_url.strip()
        app_config.global_.default_model = body.default_model.strip()
        if body.log_file.strip():
            app_config.global_.log_file = body.log_file.strip()
        save_config(CONFIG_PATH, app_config)
        reload_runtime()
    return await api_get_settings()


@app.get("/api/system/doctor")
async def api_doctor() -> dict[str, Any]:
    """Environment health checks."""
    return await assistant.doctor()


@app.post("/api/projects/{name}/test-ssh")
async def api_test_ssh(name: str) -> dict[str, Any]:
    """Probe SSH + git for a remote project."""
    project = app_config.get_project(name)
    if not project:
        raise HTTPException(status_code=404, detail=f"Project not found: {name}")
    return await assistant.test_remote_connection(project)


@app.get("/api/projects")
async def api_projects() -> dict[str, Any]:
    """Return JSON status (+ config) for all projects."""
    return {"projects": await _collect_statuses()}


@app.post("/api/projects")
async def api_create_project(body: ProjectIn) -> dict[str, Any]:
    """Add a project to config.yaml."""
    name = _validate_name(body.name)
    async with config_lock:
        if app_config.get_project(name):
            raise HTTPException(status_code=409, detail=f"Проект уже есть: {name}")
        project = project_from_raw(body.model_dump())
        if not project.model:
            project.model = app_config.global_.default_model
        app_config.projects.append(project)
        save_config(CONFIG_PATH, app_config)
        reload_runtime()
    project = app_config.get_project(name)
    assert project is not None
    status = await assistant.get_status(project)
    row = _status_to_dict(status)
    row["config"] = project_to_dict(project)
    row["ssh_hint"] = GitAssistant.ssh_hint_for_error(status.error)
    return row


@app.put("/api/projects/{name}")
async def api_update_project(name: str, body: ProjectIn) -> dict[str, Any]:
    """Update an existing project."""
    name = _validate_name(name)
    new_name = _validate_name(body.name)
    async with config_lock:
        idx = next((i for i, p in enumerate(app_config.projects) if p.name == name), None)
        if idx is None:
            raise HTTPException(status_code=404, detail=f"Project not found: {name}")
        if new_name != name and app_config.get_project(new_name):
            raise HTTPException(status_code=409, detail=f"Проект уже есть: {new_name}")
        if name in active_projects or new_name in active_projects:
            raise HTTPException(status_code=409, detail="Дождитесь окончания задачи")
        project = project_from_raw(body.model_dump())
        project.name = new_name
        if not project.model:
            project.model = app_config.global_.default_model
        app_config.projects[idx] = project
        save_config(CONFIG_PATH, app_config)
        reload_runtime()
    project = app_config.get_project(new_name)
    assert project is not None
    status = await assistant.get_status(project)
    row = _status_to_dict(status)
    row["config"] = project_to_dict(project)
    row["ssh_hint"] = GitAssistant.ssh_hint_for_error(status.error)
    return row


@app.delete("/api/projects/{name}")
async def api_delete_project(name: str) -> dict[str, str]:
    """Remove a project from config.yaml."""
    name = _validate_name(name)
    async with config_lock:
        if name in active_projects:
            raise HTTPException(status_code=409, detail="Дождитесь окончания задачи")
        before = len(app_config.projects)
        app_config.projects = [p for p in app_config.projects if p.name != name]
        if len(app_config.projects) == before:
            raise HTTPException(status_code=404, detail=f"Project not found: {name}")
        save_config(CONFIG_PATH, app_config)
        reload_runtime()
    return {"status": "deleted", "name": name}


@app.post("/api/projects/{name}/refresh")
async def api_refresh(name: str) -> dict[str, Any]:
    """Refresh and return status for one project."""
    project = app_config.get_project(name)
    if not project:
        raise HTTPException(status_code=404, detail=f"Project not found: {name}")
    status = await assistant.get_status(project)
    row = _status_to_dict(status)
    row["config"] = project_to_dict(project)
    row["ssh_hint"] = GitAssistant.ssh_hint_for_error(status.error)
    return row


@app.post("/api/projects/{name}/smart-commit")
async def api_smart_commit(name: str) -> dict[str, str]:
    """Start Smart Commit (tests required)."""
    job_id = await _start_job(name, "smart-commit")
    return {"job_id": job_id}


@app.post("/api/projects/{name}/force-commit")
async def api_force_commit(name: str) -> dict[str, str]:
    """Start Force Commit (tests skipped)."""
    job_id = await _start_job(name, "force-commit")
    return {"job_id": job_id}


@app.post("/api/projects/{name}/pull")
async def api_pull(name: str) -> dict[str, str]:
    """Start git pull --rebase."""
    job_id = await _start_job(name, "pull")
    return {"job_id": job_id}


@app.get("/api/jobs/{job_id}")
async def api_job(job_id: str) -> dict[str, Any]:
    """Return job status and final result if finished."""
    state = jobs.get(job_id)
    if not state:
        raise HTTPException(status_code=404, detail="Job not found")
    payload: dict[str, Any] = {
        "job_id": state.job_id,
        "project": state.project,
        "action": state.action,
        "done": state.done,
        "started_at": state.started_at,
        "logs": state.logs,
    }
    if state.result is not None:
        payload["result"] = asdict(state.result)
    return payload


@app.get("/api/jobs/{job_id}/events")
async def api_job_events(job_id: str) -> StreamingResponse:
    """Server-Sent Events stream of live job logs."""
    state = jobs.get(job_id)
    if not state:
        raise HTTPException(status_code=404, detail="Job not found")

    async def event_generator() -> AsyncIterator[str]:
        sent = 0
        while True:
            while sent < len(state.logs):
                line = state.logs[sent]
                sent += 1
                yield f"data: {json.dumps({'type': 'log', 'message': line}, ensure_ascii=False)}\n\n"

            if state.done and sent >= len(state.logs):
                result_payload = asdict(state.result) if state.result else {}
                yield f"data: {json.dumps({'type': 'done', 'result': result_payload}, ensure_ascii=False)}\n\n"
                return

            await state.queue.get()

    return StreamingResponse(
        event_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


if __name__ == "__main__":
    import os

    import uvicorn

    host = os.environ.get("GIT_ASSISTANT_HOST", "0.0.0.0")
    port = int(os.environ.get("GIT_ASSISTANT_PORT", "8080"))
    uvicorn.run("app:app", host=host, port=port, reload=False)

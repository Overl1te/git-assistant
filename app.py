"""Git Assistant with AI — FastAPI web UI, REST API, and SSE live logs."""

from __future__ import annotations

import asyncio
import json
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

from git_assistant import (
    GitAssistant,
    JobResult,
    load_config,
    setup_logging,
)

BASE_DIR = Path(__file__).resolve().parent
CONFIG_PATH = BASE_DIR / "config.yaml"

app_config = load_config(CONFIG_PATH)
logger = setup_logging(app_config.global_.log_file)
assistant = GitAssistant(app_config, logger=logger)


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


async def _collect_statuses() -> list[dict[str, Any]]:
    """Fetch git status for all configured projects."""
    results: list[dict[str, Any]] = []
    for project in app_config.projects:
        status = await assistant.get_status(project)
        results.append(_status_to_dict(status))
    return results


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
        "index.html",
        {
            "request": request,
            "projects": statuses,
            "default_model": app_config.global_.default_model,
        },
    )


@app.get("/api/projects")
async def api_projects() -> dict[str, Any]:
    """Return JSON status for all projects."""
    return {"projects": await _collect_statuses()}


@app.post("/api/projects/{name}/refresh")
async def api_refresh(name: str) -> dict[str, Any]:
    """Refresh and return status for one project."""
    project = app_config.get_project(name)
    if not project:
        raise HTTPException(status_code=404, detail=f"Project not found: {name}")
    status = await assistant.get_status(project)
    return _status_to_dict(status)


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
        # Index-based stream avoids duplicate lines when replaying + live queue.
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

            # Wake when a new log line (or sentinel None) is published
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

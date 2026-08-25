# Production image for Fly.io (docs/decisions/0015-deploy-fly-io.md). Multi-stage:
# uv resolves and installs into a venv in the builder stage, then only the venv
# and source are copied into the slim runtime stage — no compiler toolchain or
# uv itself ships in the final image.
FROM python:3.13-slim AS builder

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never

WORKDIR /app

# Dependencies first, cached separately from application code so a source
# change doesn't invalidate the dependency layer.
RUN --mount=type=cache,target=/root/.cache/uv \
    --mount=type=bind,source=uv.lock,target=uv.lock \
    --mount=type=bind,source=pyproject.toml,target=pyproject.toml \
    uv sync --locked --no-install-project --no-dev

COPY pyproject.toml uv.lock ./
COPY src/ ./src/
COPY alembic.ini ./
COPY alembic/ ./alembic/

RUN --mount=type=cache,target=/root/.cache/uv \
    uv sync --locked --no-dev

FROM python:3.13-slim

RUN useradd --create-home --uid 1000 traccio
WORKDIR /app
COPY --from=builder --chown=traccio:traccio /app /app
ENV PATH="/app/.venv/bin:$PATH"
USER traccio

EXPOSE 8080

CMD ["uvicorn", "traccio.api.main:app", "--host", "0.0.0.0", "--port", "8080"]

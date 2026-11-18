# syntax=docker/dockerfile:1.7
#
# OMR server: FastAPI + homr (CPU). Model weights are downloaded during the build, not committed.
#   docker build -t flowy-piano-omr server/
#   docker run -p 8000:8000 -e OMR_API_TOKEN=change-me flowy-piano-omr

ARG PYTHON_IMAGE=python:3.12-slim-bookworm

FROM ${PYTHON_IMAGE} AS build
ARG HOMR_COMMIT=33dd138b0a79a6e513bf2b2e31caddde12c01063
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# homr (AGPL-3.0) lives in its own venv and is only ever run as a separate process.
RUN python -m venv /opt/homr \
    && /opt/homr/bin/pip install "homr[cpu] @ git+https://github.com/liebharc/homr@${HOMR_COMMIT}" \
    && /opt/homr/bin/homr --init \
    && find /opt/homr -name "__pycache__" -prune -exec rm -rf {} +

COPY requirements.txt /tmp/requirements.txt
RUN python -m venv /opt/server && /opt/server/bin/pip install -r /tmp/requirements.txt

FROM ${PYTHON_IMAGE}
ARG HOMR_COMMIT=33dd138b0a79a6e513bf2b2e31caddde12c01063
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH=/opt/server/bin:$PATH \
    OMR_HOMR_BIN=/opt/homr/bin/homr \
    HOMR_COMMIT=${HOMR_COMMIT} \
    OMR_WORK_DIR=/tmp/omr-jobs
RUN useradd --create-home --uid 10001 omr
COPY --from=build /opt/homr /opt/homr
COPY --from=build /opt/server /opt/server
WORKDIR /srv
COPY app ./app
USER omr
EXPOSE 8000
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=4)"
# One process: jobs live in memory. Scale with OMR_WORKERS (pages processed in parallel) or more replicas.
CMD ["uvicorn", "app.main:app_factory", "--factory", "--host", "0.0.0.0", "--port", "8000", "--workers", "1"]

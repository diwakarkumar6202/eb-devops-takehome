# ---- Stage 1: install dependencies into a virtualenv ----
FROM python:3.12.16-slim-trixie AS builder
WORKDIR /build
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# ---- Stage 2: minimal runtime image ----
FROM python:3.12.16-slim-trixie
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# Apply Debian security fixes newer than the base image, then create the non-root user
RUN apt-get update \
 && apt-get upgrade -y --no-install-recommends \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY app.py .

# Numeric UID so Kubernetes' runAsNonRoot can verify it
USER 10001:10001
EXPOSE 8080

CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", \
     "--worker-tmp-dir", "/dev/shm", "--access-logfile", "-", "app:app"]

FROM python:3.12-slim

# Only the Python service is included. Flutter, Android SDK and preview files
# belong to the APK build and are not required by the API container.
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PORT=8000 \
    MARTIN_CACHE_DIR=/tmp/martin_luk \
    MARTIN_PROVIDER_TIMEOUT=8 \
    MARTIN_PROVIDER_RETRIES=1 \
    MARTIN_FETCH_WORKERS=4 \
    MARTIN_SCAN_POOL_LIMIT=0 \
    MARTIN_SCAN_PAGE_SIZE=60 \
    MARTIN_SCAN_PAGE_INTERVAL=60 \
    MARTIN_SCAN_BATCH_SIZE=3 \
    MARTIN_SCAN_BATCH_DELAY=0.15 \
    MARTIN_SCAN_FAILURE_COOLDOWN=30 \
    MARTIN_SCAN_TIMEOUT=180

WORKDIR /app

COPY backend/requirements.txt /app/backend/requirements.txt
RUN python -m pip install --no-cache-dir -r backend/requirements.txt \
    && useradd --uid 10001 --create-home app

COPY --chown=10001:10001 backend/ /app/backend/
USER 10001

EXPOSE 8000

# The health endpoint must remain independent of Yahoo and scan completion.
HEALTHCHECK --interval=30s --timeout=5s --start-period=45s --retries=3 \
    CMD python -c "import os, urllib.request; urllib.request.urlopen('http://127.0.0.1:' + os.environ.get('PORT', '8000') + '/health', timeout=4).read()"

# Background scan jobs and progress are in this process. More than one worker
# would send subsequent polls to a different in-memory job registry.
CMD ["sh", "-c", "exec python -m uvicorn backend.api:app --host 0.0.0.0 --port \"${PORT:-8000}\" --workers 1"]

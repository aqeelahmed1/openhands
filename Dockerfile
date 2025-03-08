                       # Set build version as argument
ARG OPENHANDS_BUILD_VERSION=dev

# First stage: Frontend build (Node.js)
FROM node:21.7.2-bookworm-slim AS frontend-builder

WORKDIR /app

# Copy package.json and package-lock.json from the frontend folder in openhand/
COPY ./frontend/package.json ./frontend/package-lock.json ./
RUN npm install -g npm@10.5.1
RUN npm ci

# Copy the entire frontend folder
COPY ./frontend ./
RUN npm run build

# Second stage: Backend build (Python)
FROM python:3.12.3-slim AS backend-builder

WORKDIR /app

ENV PYTHONPATH='/app'

# Poetry installation
ENV POETRY_NO_INTERACTION=1 \
    POETRY_VIRTUALENVS_IN_PROJECT=1 \
    POETRY_VIRTUALENVS_CREATE=1 \
    POETRY_CACHE_DIR=/tmp/poetry_cache

RUN apt-get update -y \
    && apt-get install -y curl make git build-essential \
    && python3 -m pip install poetry==1.8.2 --break-system-packages

# Copy Python dependencies
COPY ./pyproject.toml ./poetry.lock ./
RUN touch README.md
RUN export POETRY_CACHE_DIR && poetry install --without evaluation,llama-index --no-root && rm -rf $POETRY_CACHE_DIR

# Third stage: OpenHands app setup (Final image)
FROM python:3.12.3-slim AS openhands-app

WORKDIR /app

ARG OPENHANDS_BUILD_VERSION

ENV RUN_AS_OPENHANDS=true
ENV OPENHANDS_USER_ID=42420
ENV SANDBOX_LOCAL_RUNTIME_URL=http://host.docker.internal
ENV USE_HOST_NETWORK=false
ENV WORKSPACE_BASE=/opt/workspace_base
ENV OPENHANDS_BUILD_VERSION=$OPENHANDS_BUILD_VERSION
ENV SANDBOX_USER_ID=0
ENV FILE_STORE=local
ENV FILE_STORE_PATH=/.openhands-state

# Create necessary directories
RUN mkdir -p $FILE_STORE_PATH
RUN mkdir -p $WORKSPACE_BASE

# Install dependencies
RUN apt-get update -y \
    && apt-get install -y curl ssh sudo

# Configure UID and GID limits
RUN sed -i 's/^UID_MIN.*/UID_MIN 499/' /etc/login.defs
RUN sed -i 's/^UID_MAX.*/UID_MAX 1000000/' /etc/login.defs

# Add group and user for OpenHands
RUN groupadd app
RUN useradd -l -m -u $OPENHANDS_USER_ID -s /bin/bash openhands && \
    usermod -aG app openhands && \
    usermod -aG sudo openhands && \
    echo '%sudo ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers
RUN chown -R openhands:app /app && chmod -R 770 /app
RUN sudo chown -R openhands:app $WORKSPACE_BASE && sudo chmod -R 770 $WORKSPACE_BASE
USER openhands

# Set Python environment
ENV VIRTUAL_ENV=/app/.venv \
    PATH="/app/.venv/bin:$PATH" \
    PYTHONPATH='/app'

# Copy Python virtual environment from the backend-builder stage
# COPY --chown=openhands:app --chmod=770 --from=backend-builder ${VIRTUAL_ENV} ${VIRTUAL_ENV}
COPY --chown=openhands:app --from=backend-builder ${VIRTUAL_ENV} ${VIRTUAL_ENV}

# Install Playwright and dependencies
RUN playwright install --with-deps chromium

# Copy necessary application files
COPY --chown=openhands:app --chmod=770 ./microagents ./microagents
COPY --chown=openhands:app --chmod=770 ./openhands ./openhands
COPY --chown=openhands:app --chmod=777 ./openhands/runtime/plugins ./openhands/runtime/plugins
COPY --chown=openhands:app --chmod=770 ./openhands/agenthub ./openhands/agenthub
COPY --chown=openhands:app ./pyproject.toml ./pyproject.toml
COPY --chown=openhands:app ./poetry.lock ./poetry.lock
COPY --chown=openhands:app ./README.md ./README.md
COPY --chown=openhands:app ./MANIFEST.in ./MANIFEST.in
COPY --chown=openhands:app ./LICENSE ./LICENSE

# This step creates necessary directories with proper permissions
RUN python openhands/core/download.py

# Change group ownership of all files
RUN find /app \! -group app -exec chgrp app {} +

# Copy frontend build files
COPY --chown=openhands:app --chmod=770 --from=frontend-builder /app/build ./frontend/build

# Copy entrypoint script
COPY --chown=openhands:app --chmod=770 ./containers/app/entrypoint.sh /app/entrypoint.sh

USER root

WORKDIR /app

# Set entrypoint and command
ENTRYPOINT ["/app/entrypoint.sh"]
CMD ["uvicorn", "openhands.server.listen:app", "--host", "0.0.0.0", "--port", "3000"]

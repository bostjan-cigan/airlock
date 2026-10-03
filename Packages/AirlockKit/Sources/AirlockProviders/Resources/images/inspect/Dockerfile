# Tools for inspecting an untrusted repository: Python and pip, Rust and Cargo, on top of the
# agent image (Node, npm and corepack are there already). Only used by inspection tasks.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
USER root
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends python3 python3-pip python3-venv cargo \
    && rm -rf /var/lib/apt/lists/*

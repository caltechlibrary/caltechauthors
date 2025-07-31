FROM mcr.microsoft.com/devcontainers/base:ubuntu24.04

RUN apt-get update \
    && apt-get upgrade -y \
    && apt-get install ca-certificates curl gnupg -y

RUN mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | sudo gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" | sudo tee /etc/apt/sources.list.d/nodesource.list

RUN apt-get update \
    && apt-get install libcairo2-dev imagemagick fonts-dejavu nodejs python3 python3-pip -y

RUN pip install invenio-cli --break-system-packages

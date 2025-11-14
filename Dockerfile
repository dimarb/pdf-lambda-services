# Deployment Tool Image for Gotenberg Lambda
FROM python:3.11-slim

# Install system dependencies
RUN apt-get update && apt-get install -y \
    curl \
    git \
    jq \
    zip \
    ca-certificates \
    gnupg \
    lsb-release \
    && rm -rf /var/lib/apt/lists/*

# Install AWS CLI via pip (works on all architectures)
RUN pip install --no-cache-dir awscli

# Install Docker CLI
RUN install -m 0755 -d /etc/apt/keyrings && \
    curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg && \
    chmod a+r /etc/apt/keyrings/docker.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null && \
    apt-get update && \
    apt-get install -y docker-ce-cli && \
    rm -rf /var/lib/apt/lists/*

# Create working directory
WORKDIR /workspace

# Copy deployment scripts
COPY deploy.sh /workspace/
COPY setup-iam.sh /workspace/
COPY setup-s3-async.sh /workspace/
COPY setup-lambda-wrapper.sh /workspace/
COPY iam-policy.json /workspace/
COPY entrypoint.sh /workspace/
COPY Dockerfile.gotenberg /workspace/

# Make scripts executable
RUN chmod +x /workspace/deploy.sh /workspace/setup-iam.sh /workspace/setup-s3-async.sh /workspace/setup-lambda-wrapper.sh /workspace/entrypoint.sh

# Set entrypoint to automated deployment script
ENTRYPOINT ["/workspace/entrypoint.sh"]
CMD []

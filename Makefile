.PHONY: help build deploy shell test-local clean setup-s3-async setup-lambda-wrapper test-webhook

# Load environment variables (ignore if .env doesn't exist)
-include .env
export

help:
	@echo "=========================================="
	@echo "🚀 Gotenberg Lambda Deployment Tool"
	@echo "=========================================="
	@echo ""
	@echo "Quick Start (only 2 steps!):"
	@echo "  1. Edit .env file with AWS credentials"
	@echo "  2. make deploy"
	@echo ""
	@echo "Available commands:"
	@echo "  make deploy               - 🚀 Deploy Lambda to AWS"
	@echo "  make setup-s3-async       - 📦 Setup S3 for async conversions"
	@echo "  make setup-lambda-wrapper - 🔗 Create S3 → Lambda wrapper function"
	@echo "  make test-webhook         - 🧪 Test webhook integration flow"
	@echo "  make build                - Build deployment container"
	@echo "  make shell                - Interactive shell with AWS CLI"
	@echo "  make test-local           - Test Gotenberg locally (port 3000)"
	@echo "  make clean                - Clean up containers and images"
	@echo ""

build:
	@echo "🔨 Building deployment container..."
	@docker build -t gotenberg-deploy-tool:latest .
	@echo "✓ Container built successfully"

deploy: build
	@echo "🚀 Starting automated deployment..."
	@docker run --rm \
		-v $(PWD):/workspace \
		-v /var/run/docker.sock:/var/run/docker.sock \
		gotenberg-deploy-tool:latest

shell: build
	@echo "🐚 Starting interactive shell..."
	@docker run -it --rm \
		-v $(PWD):/workspace \
		-v /var/run/docker.sock:/var/run/docker.sock \
		gotenberg-deploy-tool:latest shell

test-local:
	@echo "Starting Gotenberg locally for testing..."
	docker run --rm -p 3000:3000 \
		-e API_ENABLE_BASIC_AUTH=$(API_ENABLE_BASIC_AUTH) \
		-e GOTENBERG_API_BASIC_AUTH_USERNAME=$(GOTENBERG_API_BASIC_AUTH_USERNAME) \
		-e GOTENBERG_API_BASIC_AUTH_PASSWORD=$(GOTENBERG_API_BASIC_AUTH_PASSWORD) \
		-e GOTENBERG_LOG_LEVEL=$(GOTENBERG_LOG_LEVEL) \
		-e PDFENGINES_MERGE_ENGINES=$(PDFENGINES_MERGE_ENGINES) \
		-e PDFENGINES_SPLIT_ENGINES=$(PDFENGINES_SPLIT_ENGINES) \
		-e PDFENGINES_FLATTEN_ENGINES=$(PDFENGINES_FLATTEN_ENGINES) \
		-e PDFENGINES_CONVERT_ENGINES=$(PDFENGINES_CONVERT_ENGINES) \
		gotenberg/gotenberg:8

clean:
	@echo "Cleaning up..."
	docker rmi gotenberg-deploy-tool:latest 2>/dev/null || true
	@echo "Cleanup complete"

setup-s3-async: build
	@echo "📦 Setting up S3 for async PDF conversions..."
	@echo "This will add ~$2/month and eliminates the 30s timeout!"
	@docker run --rm \
		-v $(PWD):/workspace \
		gotenberg-deploy-tool:latest /workspace/setup-s3-async.sh

setup-lambda-wrapper: build
	@echo "🔗 Setting up Lambda S3 wrapper function..."
	@docker run --rm \
		-v $(PWD):/workspace \
		gotenberg-deploy-tool:latest /workspace/setup-lambda-wrapper.sh

test-webhook:
	@echo "🧪 Testing webhook integration..."
	@./test-webhook-flow.sh

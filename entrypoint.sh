#!/bin/bash

set -e

echo "========================================"
echo "  Gotenberg Lambda Deployment Tool"
echo "========================================"
echo ""

# Check if specific command was passed (shell mode bypasses validation)
if [ "$1" = "shell" ]; then
    echo "Starting interactive shell..."
    echo ""
    exec /bin/bash
fi

# Check if a script path was passed directly
if [ -n "$1" ] && [ -f "$1" ]; then
    echo "Executing script: $1"
    echo ""
    exec "$@"
fi

# Load environment variables from .env file if it exists
if [ -f /workspace/.env ]; then
    echo "Loading environment variables from .env file..."
    export $(cat /workspace/.env | grep -v '^#' | grep -v '^$' | xargs)
fi

# Validate required environment variables
REQUIRED_VARS=(
    "AWS_REGION"
    "AWS_ACCOUNT_ID"
    "AWS_ACCESS_KEY_ID"
    "AWS_SECRET_ACCESS_KEY"
)

echo "Validating AWS credentials..."
for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "❌ Error: $var is not set"
        echo ""
        echo "Please set it in your .env file or pass it as environment variable"
        exit 1
    fi
done

echo "✓ AWS credentials validated"
echo ""

# Set defaults for optional variables
export ECR_REPOSITORY_NAME=${ECR_REPOSITORY_NAME:-gotenberg-lambda}
export ECR_IMAGE_TAG=${ECR_IMAGE_TAG:-latest}
export LAMBDA_FUNCTION_NAME=${LAMBDA_FUNCTION_NAME:-gotenberg-pdf-service}
export LAMBDA_MEMORY_SIZE=${LAMBDA_MEMORY_SIZE:-2048}
export LAMBDA_TIMEOUT=${LAMBDA_TIMEOUT:-300}
export LAMBDA_ROLE_NAME=${LAMBDA_ROLE_NAME:-gotenberg-lambda-execution-role}
export LAMBDA_CREATE_FUNCTION_URL=${LAMBDA_CREATE_FUNCTION_URL:-true}

# Gotenberg configuration defaults
export API_ENABLE_BASIC_AUTH=${API_ENABLE_BASIC_AUTH:-true}
export GOTENBERG_API_BASIC_AUTH_USERNAME=${GOTENBERG_API_BASIC_AUTH_USERNAME:-admin}
export GOTENBERG_API_BASIC_AUTH_PASSWORD=${GOTENBERG_API_BASIC_AUTH_PASSWORD:-changeme}
export GOTENBERG_LOG_LEVEL=${GOTENBERG_LOG_LEVEL:-info}
export PDFENGINES_MERGE_ENGINES=${PDFENGINES_MERGE_ENGINES:-qpdf,pdfcpu,pdftk}
export PDFENGINES_SPLIT_ENGINES=${PDFENGINES_SPLIT_ENGINES:-qpdf,pdfcpu,pdftk}
export PDFENGINES_FLATTEN_ENGINES=${PDFENGINES_FLATTEN_ENGINES:-qpdf}
export PDFENGINES_CONVERT_ENGINES=${PDFENGINES_CONVERT_ENGINES:-libreoffice-pdfengine}

# Check for other commands
if [ "$1" = "deploy-only" ]; then
    echo "Running deployment only (skipping IAM setup)..."
    exec /workspace/deploy.sh
elif [ "$1" = "setup-iam-only" ]; then
    echo "Running IAM setup only..."
    exec /workspace/setup-iam.sh
else
    # Full automated deployment
    echo "========================================="
    echo "STEP 1: IAM Role Setup"
    echo "========================================="
    echo ""

    # Check if IAM role exists
    echo "Checking if IAM role exists..."
    if LAMBDA_ROLE_ARN=$(aws iam get-role --role-name ${LAMBDA_ROLE_NAME} --query 'Role.Arn' --output text 2>/dev/null) && [ -n "$LAMBDA_ROLE_ARN" ]; then
        echo "✓ IAM role '${LAMBDA_ROLE_NAME}' already exists"
        echo "  ARN: ${LAMBDA_ROLE_ARN}"
    else
        echo "Creating IAM role '${LAMBDA_ROLE_NAME}'..."

        # Create IAM role
        LAMBDA_ROLE_ARN=$(aws iam create-role \
            --role-name ${LAMBDA_ROLE_NAME} \
            --assume-role-policy-document file:///workspace/iam-policy.json \
            --query 'Role.Arn' \
            --output text)

        echo "✓ IAM role created: ${LAMBDA_ROLE_ARN}"

        # Attach policies
        echo "Attaching Lambda execution policies..."
        aws iam attach-role-policy \
            --role-name ${LAMBDA_ROLE_NAME} \
            --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole

        aws iam attach-role-policy \
            --role-name ${LAMBDA_ROLE_NAME} \
            --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole

        echo "✓ Policies attached"

        # Wait for role to be available
        echo "Waiting for IAM role to propagate (10 seconds)..."
        sleep 10
    fi

    export LAMBDA_ROLE_ARN

    echo ""
    echo "========================================="
    echo "STEP 2: Gotenberg Lambda Deployment"
    echo "========================================="
    echo ""

    # Run deployment
    /workspace/deploy.sh

    echo ""
    echo "========================================"
    echo "✓ DEPLOYMENT COMPLETED SUCCESSFULLY!"
    echo "========================================"
    echo ""
    echo "Lambda Function Details:"
    echo "  Name: ${LAMBDA_FUNCTION_NAME}"
    echo "  Region: ${AWS_REGION}"
    echo "  Role: ${LAMBDA_ROLE_ARN}"
    echo ""
    echo "Authentication:"
    echo "  Username: ${GOTENBERG_API_BASIC_AUTH_USERNAME}"
    echo "  Password: ${GOTENBERG_API_BASIC_AUTH_PASSWORD}"
    echo ""
    echo "Next steps:"
    echo "  1. Run 'make setup-s3-async' to configure S3 buckets"
    echo "  2. Integrate with N8N using N8N-INTEGRATION.md guide"
    echo ""
fi

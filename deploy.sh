#!/bin/bash

set -e

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | xargs)
else
    echo "Error: .env file not found"
    exit 1
fi

echo "======================================"
echo "Gotenberg Lambda Deployment Script"
echo "======================================"
echo ""

# Validate required environment variables
REQUIRED_VARS=(
    "AWS_REGION"
    "AWS_ACCOUNT_ID"
    "ECR_REPOSITORY_NAME"
    "LAMBDA_FUNCTION_NAME"
    "LAMBDA_ROLE_ARN"
)

for var in "${REQUIRED_VARS[@]}"; do
    if [ -z "${!var}" ]; then
        echo "Error: $var is not set in .env file"
        exit 1
    fi
done

# Set ECR repository URI
ECR_URI="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${ECR_REPOSITORY_NAME}"

echo "Step 1: Authenticating with AWS ECR..."
aws ecr get-login-password --region ${AWS_REGION} | docker login --username AWS --password-stdin ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com

echo ""
echo "Step 2: Creating ECR repository if it doesn't exist..."
aws ecr describe-repositories --repository-names ${ECR_REPOSITORY_NAME} --region ${AWS_REGION} 2>/dev/null || \
    aws ecr create-repository --repository-name ${ECR_REPOSITORY_NAME} --region ${AWS_REGION} \
    --image-scanning-configuration scanOnPush=true

echo ""
echo "Step 3: Building custom Gotenberg Lambda image with optimizations..."
# Build custom image from Dockerfile.gotenberg with Lambda optimizations
docker build --platform linux/amd64 -f /workspace/Dockerfile.gotenberg -t gotenberg-lambda-custom:latest /workspace

echo ""
echo "Step 4: Tagging custom Gotenberg image for ECR..."
docker tag gotenberg-lambda-custom:latest ${ECR_URI}:${ECR_IMAGE_TAG:-latest}

echo ""
echo "Step 5: Pushing custom image to ECR..."
docker push ${ECR_URI}:${ECR_IMAGE_TAG:-latest}

echo ""
echo "Step 6: Deploying/Updating Lambda function..."

# Check if Lambda function exists
if aws lambda get-function --function-name ${LAMBDA_FUNCTION_NAME} --region ${AWS_REGION} 2>/dev/null; then
    echo "Updating existing Lambda function..."
    aws lambda update-function-code \
        --function-name ${LAMBDA_FUNCTION_NAME} \
        --image-uri ${ECR_URI}:${ECR_IMAGE_TAG:-latest} \
        --region ${AWS_REGION}

    echo "Waiting for function update to complete..."
    aws lambda wait function-updated \
        --function-name ${LAMBDA_FUNCTION_NAME} \
        --region ${AWS_REGION}

    echo "Updating function configuration..."

    # Create environment variables JSON
    cat > /tmp/lambda-env.json <<EOF
{
  "Variables": {
    "API_ENABLE_BASIC_AUTH": "${API_ENABLE_BASIC_AUTH}",
    "GOTENBERG_API_BASIC_AUTH_USERNAME": "${GOTENBERG_API_BASIC_AUTH_USERNAME}",
    "GOTENBERG_API_BASIC_AUTH_PASSWORD": "${GOTENBERG_API_BASIC_AUTH_PASSWORD}",
    "GOTENBERG_LOG_LEVEL": "${GOTENBERG_LOG_LEVEL}",
    "PDFENGINES_MERGE_ENGINES": "${PDFENGINES_MERGE_ENGINES}",
    "PDFENGINES_SPLIT_ENGINES": "${PDFENGINES_SPLIT_ENGINES}",
    "PDFENGINES_FLATTEN_ENGINES": "${PDFENGINES_FLATTEN_ENGINES}",
    "PDFENGINES_CONVERT_ENGINES": "${PDFENGINES_CONVERT_ENGINES}",
    "CHROMIUM_DISABLE_WEB_SECURITY": "${CHROMIUM_DISABLE_WEB_SECURITY:-true}",
    "CHROMIUM_ALLOW_LIST": "${CHROMIUM_ALLOW_LIST:-^file:///tmp/.*}",
    "CHROMIUM_IGNORE_CERTIFICATE_ERRORS": "${CHROMIUM_IGNORE_CERTIFICATE_ERRORS:-true}",
    "CHROMIUM_DISABLE_JAVASCRIPT": "${CHROMIUM_DISABLE_JAVASCRIPT:-false}",
    "CHROMIUM_INCOGNITO": "${CHROMIUM_INCOGNITO:-true}",
    "CHROMIUM_ALLOW_INSECURE_LOCALHOST": "${CHROMIUM_ALLOW_INSECURE_LOCALHOST:-true}",
    "CHROMIUM_START_TIMEOUT": "${CHROMIUM_START_TIMEOUT:-30s}"
  }
}
EOF

    aws lambda update-function-configuration \
        --function-name ${LAMBDA_FUNCTION_NAME} \
        --memory-size ${LAMBDA_MEMORY_SIZE:-2048} \
        --timeout ${LAMBDA_TIMEOUT:-300} \
        --environment file:///tmp/lambda-env.json \
        --region ${AWS_REGION}
else
    echo "Creating new Lambda function..."

    # Create environment variables JSON
    cat > /tmp/lambda-env.json <<EOF
{
  "Variables": {
    "API_ENABLE_BASIC_AUTH": "${API_ENABLE_BASIC_AUTH}",
    "GOTENBERG_API_BASIC_AUTH_USERNAME": "${GOTENBERG_API_BASIC_AUTH_USERNAME}",
    "GOTENBERG_API_BASIC_AUTH_PASSWORD": "${GOTENBERG_API_BASIC_AUTH_PASSWORD}",
    "GOTENBERG_LOG_LEVEL": "${GOTENBERG_LOG_LEVEL}",
    "PDFENGINES_MERGE_ENGINES": "${PDFENGINES_MERGE_ENGINES}",
    "PDFENGINES_SPLIT_ENGINES": "${PDFENGINES_SPLIT_ENGINES}",
    "PDFENGINES_FLATTEN_ENGINES": "${PDFENGINES_FLATTEN_ENGINES}",
    "PDFENGINES_CONVERT_ENGINES": "${PDFENGINES_CONVERT_ENGINES}",
    "CHROMIUM_DISABLE_WEB_SECURITY": "${CHROMIUM_DISABLE_WEB_SECURITY:-true}",
    "CHROMIUM_ALLOW_LIST": "${CHROMIUM_ALLOW_LIST:-^file:///tmp/.*}",
    "CHROMIUM_IGNORE_CERTIFICATE_ERRORS": "${CHROMIUM_IGNORE_CERTIFICATE_ERRORS:-true}",
    "CHROMIUM_DISABLE_JAVASCRIPT": "${CHROMIUM_DISABLE_JAVASCRIPT:-false}",
    "CHROMIUM_INCOGNITO": "${CHROMIUM_INCOGNITO:-true}",
    "CHROMIUM_ALLOW_INSECURE_LOCALHOST": "${CHROMIUM_ALLOW_INSECURE_LOCALHOST:-true}",
    "CHROMIUM_START_TIMEOUT": "${CHROMIUM_START_TIMEOUT:-30s}"
  }
}
EOF

    aws lambda create-function \
        --function-name ${LAMBDA_FUNCTION_NAME} \
        --package-type Image \
        --code ImageUri=${ECR_URI}:${ECR_IMAGE_TAG:-latest} \
        --role ${LAMBDA_ROLE_ARN} \
        --memory-size ${LAMBDA_MEMORY_SIZE:-2048} \
        --timeout ${LAMBDA_TIMEOUT:-300} \
        --environment file:///tmp/lambda-env.json \
        --region ${AWS_REGION}
fi

echo ""
echo "Step 7: Configuring Lambda Function URL..."

if [ "${LAMBDA_CREATE_FUNCTION_URL}" = "true" ]; then
    # Check if function URL already exists
    FUNCTION_URL=$(aws lambda get-function-url-config \
        --function-name ${LAMBDA_FUNCTION_NAME} \
        --region ${AWS_REGION} \
        --query 'FunctionUrl' \
        --output text 2>/dev/null) || true

    if [ -z "$FUNCTION_URL" ] || [ "$FUNCTION_URL" = "None" ]; then
        echo "Creating Function URL (public access)..."
        FUNCTION_URL=$(aws lambda create-function-url-config \
            --function-name ${LAMBDA_FUNCTION_NAME} \
            --auth-type NONE \
            --cors AllowOrigins='*',AllowMethods='*',AllowHeaders='*' \
            --region ${AWS_REGION} \
            --query 'FunctionUrl' \
            --output text)

        # Add permission for public invocation
        aws lambda add-permission \
            --function-name ${LAMBDA_FUNCTION_NAME} \
            --statement-id FunctionURLAllowPublicAccess \
            --action lambda:InvokeFunctionUrl \
            --principal '*' \
            --function-url-auth-type NONE \
            --region ${AWS_REGION} 2>/dev/null || true

        echo "✓ Function URL created"
    else
        echo "✓ Function URL already exists"
    fi
else
    echo "⊘ Function URL creation disabled (set LAMBDA_CREATE_FUNCTION_URL=true to enable)"
    FUNCTION_URL=""
fi

echo ""
echo "======================================"
echo "✅ DEPLOYMENT COMPLETED SUCCESSFULLY!"
echo "======================================"
echo ""
echo "Lambda Function: ${LAMBDA_FUNCTION_NAME}"
echo "Region: ${AWS_REGION}"
echo "Image: ${ECR_URI}:${ECR_IMAGE_TAG:-latest}"
echo ""

if [ -n "$FUNCTION_URL" ]; then
    echo "🌐 Function URL (HTTP endpoint):"
    echo "   ${FUNCTION_URL}"
    echo ""
    echo "🔐 Authentication:"
    echo "   Username: ${GOTENBERG_API_BASIC_AUTH_USERNAME}"
    echo "   Password: ${GOTENBERG_API_BASIC_AUTH_PASSWORD}"
    echo ""
    echo "📝 Test your deployment:"
    echo "   curl -X POST ${FUNCTION_URL}forms/chromium/convert/url \\"
    echo "     -u ${GOTENBERG_API_BASIC_AUTH_USERNAME}:${GOTENBERG_API_BASIC_AUTH_PASSWORD} \\"
    echo "     -F url=https://example.com \\"
    echo "     -o output.pdf"
    echo ""
else
    echo "ℹ️  Function URL not created. To enable:"
    echo "   Set LAMBDA_CREATE_FUNCTION_URL=true in .env"
    echo "   Or configure API Gateway manually"
    echo ""
fi

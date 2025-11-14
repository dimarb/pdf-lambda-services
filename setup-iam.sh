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
echo "IAM Role Setup for Lambda"
echo "======================================"
echo ""

ROLE_NAME="gotenberg-lambda-execution-role"

echo "Step 1: Creating IAM role for Lambda..."
ROLE_ARN=$(aws iam create-role \
    --role-name ${ROLE_NAME} \
    --assume-role-policy-document file://iam-policy.json \
    --region ${AWS_REGION} \
    --output text \
    --query 'Role.Arn' 2>/dev/null) || \
ROLE_ARN=$(aws iam get-role \
    --role-name ${ROLE_NAME} \
    --output text \
    --query 'Role.Arn')

echo "Role ARN: ${ROLE_ARN}"

echo ""
echo "Step 2: Attaching basic Lambda execution policy..."
aws iam attach-role-policy \
    --role-name ${ROLE_NAME} \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole \
    2>/dev/null || echo "Policy already attached"

echo ""
echo "Step 3: Attaching VPC execution policy (if Lambda needs VPC access)..."
aws iam attach-role-policy \
    --role-name ${ROLE_NAME} \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole \
    2>/dev/null || echo "Policy already attached"

echo ""
echo "======================================"
echo "IAM Role created successfully!"
echo "======================================"
echo ""
echo "Update your .env file with:"
echo "LAMBDA_ROLE_ARN=${ROLE_ARN}"
echo ""

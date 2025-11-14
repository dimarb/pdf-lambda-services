#!/bin/bash

set -e

echo "========================================"
echo "  S3 Async Setup for Gotenberg Lambda"
echo "========================================"
echo ""

# Load environment variables
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | grep -v '^$' | xargs)
fi

# Validate required variables
if [ -z "$AWS_REGION" ] || [ -z "$AWS_ACCOUNT_ID" ]; then
    echo "❌ Error: AWS_REGION and AWS_ACCOUNT_ID must be set in .env"
    exit 1
fi

# Set S3 bucket names
S3_INPUT_BUCKET=${S3_INPUT_BUCKET:-gotenberg-input-files-${AWS_ACCOUNT_ID}}
S3_OUTPUT_BUCKET=${S3_OUTPUT_BUCKET:-gotenberg-output-pdfs-${AWS_ACCOUNT_ID}}

echo "Step 1: Creating S3 Buckets..."

# Create input bucket
if aws s3 ls s3://${S3_INPUT_BUCKET} 2>/dev/null; then
    echo "✓ Input bucket already exists: ${S3_INPUT_BUCKET}"
else
    aws s3 mb s3://${S3_INPUT_BUCKET} --region ${AWS_REGION}
    echo "✓ Created input bucket: ${S3_INPUT_BUCKET}"
fi

# Create output bucket
if aws s3 ls s3://${S3_OUTPUT_BUCKET} 2>/dev/null; then
    echo "✓ Output bucket already exists: ${S3_OUTPUT_BUCKET}"
else
    aws s3 mb s3://${S3_OUTPUT_BUCKET} --region ${AWS_REGION}
    echo "✓ Created output bucket: ${S3_OUTPUT_BUCKET}"
fi

echo ""
echo "Step 2: Configuring Lifecycle Policies (auto-delete after 7 days)..."

cat > /tmp/lifecycle.json <<EOF
{
  "Rules": [{
    "ID": "DeleteAfter7Days",
    "Status": "Enabled",
    "Expiration": { "Days": 7 },
    "Filter": { "Prefix": "" }
  }]
}
EOF

aws s3api put-bucket-lifecycle-configuration \
  --bucket ${S3_INPUT_BUCKET} \
  --lifecycle-configuration file:///tmp/lifecycle.json

aws s3api put-bucket-lifecycle-configuration \
  --bucket ${S3_OUTPUT_BUCKET} \
  --lifecycle-configuration file:///tmp/lifecycle.json

echo "✓ Lifecycle policies configured"

echo ""
echo "Step 3: Creating IAM Policy for S3 Access..."

POLICY_NAME="GotenbergS3Access"

cat > /tmp/lambda-s3-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_INPUT_BUCKET}/*",
        "arn:aws:s3:::${S3_OUTPUT_BUCKET}/*"
      ]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${S3_INPUT_BUCKET}",
        "arn:aws:s3:::${S3_OUTPUT_BUCKET}"
      ]
    }
  ]
}
EOF

# Check if policy already exists
POLICY_ARN=$(aws iam list-policies --query "Policies[?PolicyName=='${POLICY_NAME}'].Arn" --output text)

if [ -z "$POLICY_ARN" ]; then
    POLICY_ARN=$(aws iam create-policy \
      --policy-name ${POLICY_NAME} \
      --policy-document file:///tmp/lambda-s3-policy.json \
      --query 'Policy.Arn' \
      --output text)
    echo "✓ Created IAM policy: ${POLICY_ARN}"
else
    echo "✓ IAM policy already exists: ${POLICY_ARN}"
fi

echo ""
echo "Step 4: Attaching Policy to Lambda Role..."

ROLE_NAME=${LAMBDA_ROLE_NAME:-gotenberg-lambda-execution-role}

aws iam attach-role-policy \
  --role-name ${ROLE_NAME} \
  --policy-arn ${POLICY_ARN} 2>/dev/null || echo "✓ Policy already attached"

echo "✓ Policy attached to role: ${ROLE_NAME}"

echo ""
echo "Step 5: Enabling CORS on Output Bucket (for direct downloads)..."

cat > /tmp/cors.json <<EOF
{
  "CORSRules": [{
    "AllowedOrigins": ["*"],
    "AllowedMethods": ["GET"],
    "AllowedHeaders": ["*"],
    "MaxAgeSeconds": 3000
  }]
}
EOF

aws s3api put-bucket-cors \
  --bucket ${S3_OUTPUT_BUCKET} \
  --cors-configuration file:///tmp/cors.json

echo "✓ CORS configured"

echo ""
echo "Step 6: Creating Lambda wrapper function..."

# Create Python wrapper script
cat > /tmp/lambda_s3_wrapper.py <<'PYTHON_EOF'
import json
import boto3
import os
import urllib3
from urllib.parse import urlparse

s3 = boto3.client('s3')
http = urllib3.PoolManager()

# Gotenberg configuration from environment
GOTENBERG_URL = os.environ.get('LAMBDA_FUNCTION_URL', 'http://localhost:3000')
GOTENBERG_USER = os.environ.get('GOTENBERG_API_BASIC_AUTH_USERNAME', 'admin')
GOTENBERG_PASS = os.environ.get('GOTENBERG_API_BASIC_AUTH_PASSWORD', 'changeme')

def lambda_handler(event, context):
    """
    Process PDF conversion from S3 input to S3 output

    Event format:
    {
      "inputBucket": "gotenberg-input-files",
      "inputKey": "job-123/input.html",
      "outputBucket": "gotenberg-output-pdfs",
      "outputKey": "job-123/output.pdf",
      "conversionType": "chromium/convert/html"
    }
    """

    try:
        # Parse event
        input_bucket = event.get('inputBucket')
        input_key = event.get('inputKey')
        output_bucket = event.get('outputBucket')
        output_key = event.get('outputKey')
        conversion_type = event.get('conversionType', 'chromium/convert/html')

        print(f"Converting {input_bucket}/{input_key} → {output_bucket}/{output_key}")

        # Download file from S3
        local_input = '/tmp/input_file'
        s3.download_file(input_bucket, input_key, local_input)
        print(f"Downloaded {input_key} from S3")

        # Prepare multipart form data
        with open(local_input, 'rb') as f:
            file_data = f.read()

        # Determine filename based on conversion type
        if 'html' in conversion_type:
            filename = 'index.html'
        else:
            filename = os.path.basename(input_key)

        # Create multipart form data manually
        boundary = '----WebKitFormBoundary7MA4YWxkTrZu0gW'

        body = (
            f'--{boundary}\r\n'
            f'Content-Disposition: form-data; name="files"; filename="{filename}"\r\n'
            f'Content-Type: application/octet-stream\r\n\r\n'
        ).encode('utf-8')
        body += file_data
        body += f'\r\n--{boundary}--\r\n'.encode('utf-8')

        # Call Gotenberg
        gotenberg_endpoint = f"{GOTENBERG_URL}/forms/{conversion_type}"

        # Create basic auth header
        import base64
        auth_string = f"{GOTENBERG_USER}:{GOTENBERG_PASS}"
        auth_bytes = auth_string.encode('utf-8')
        auth_b64 = base64.b64encode(auth_bytes).decode('utf-8')

        headers = {
            'Authorization': f'Basic {auth_b64}',
            'Content-Type': f'multipart/form-data; boundary={boundary}'
        }

        print(f"Calling Gotenberg: {gotenberg_endpoint}")

        response = http.request(
            'POST',
            gotenberg_endpoint,
            body=body,
            headers=headers,
            timeout=290.0
        )

        if response.status != 200:
            raise Exception(f"Gotenberg returned {response.status}: {response.data}")

        print(f"Conversion successful, {len(response.data)} bytes")

        # Upload result to S3
        s3.put_object(
            Bucket=output_bucket,
            Key=output_key,
            Body=response.data,
            ContentType='application/pdf'
        )

        print(f"Uploaded to {output_bucket}/{output_key}")

        # Generate presigned URL for download (valid for 1 hour)
        download_url = s3.generate_presigned_url(
            'get_object',
            Params={'Bucket': output_bucket, 'Key': output_key},
            ExpiresIn=3600
        )

        return {
            'statusCode': 200,
            'body': json.dumps({
                'success': True,
                'outputBucket': output_bucket,
                'outputKey': output_key,
                'downloadUrl': download_url,
                'size': len(response.data)
            })
        }

    except Exception as e:
        print(f"Error: {str(e)}")
        return {
            'statusCode': 500,
            'body': json.dumps({
                'success': False,
                'error': str(e)
            })
        }
PYTHON_EOF

# Zip the function
cd /tmp
zip lambda_s3_wrapper.zip lambda_s3_wrapper.py

echo "✓ Lambda wrapper created"

echo ""
echo "========================================"
echo "✅ S3 ASYNC SETUP COMPLETED!"
echo "========================================"
echo ""
echo "S3 Buckets:"
echo "  Input:  s3://${S3_INPUT_BUCKET}"
echo "  Output: s3://${S3_OUTPUT_BUCKET}"
echo ""
echo "IAM Policy:"
echo "  Name: ${POLICY_NAME}"
echo "  ARN:  ${POLICY_ARN}"
echo ""
echo "Lambda Wrapper:"
echo "  File: /tmp/lambda_s3_wrapper.zip"
echo ""
echo "💡 Next Steps:"
echo "  1. Update .env with:"
echo "     S3_INPUT_BUCKET=${S3_INPUT_BUCKET}"
echo "     S3_OUTPUT_BUCKET=${S3_OUTPUT_BUCKET}"
echo ""
echo "  2. Create wrapper Lambda function (optional):"
echo "     aws lambda create-function \\"
echo "       --function-name gotenberg-s3-wrapper \\"
echo "       --runtime python3.11 \\"
echo "       --role arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME} \\"
echo "       --handler lambda_s3_wrapper.lambda_handler \\"
echo "       --zip-file fileb:///tmp/lambda_s3_wrapper.zip \\"
echo "       --timeout 300 \\"
echo "       --memory-size 512 \\"
echo "       --environment Variables={LAMBDA_FUNCTION_URL=https://YOUR-FUNCTION-URL}"
echo ""
echo "  3. Import N8N workflow from N8N-INTEGRATION.md"
echo ""
echo "💰 Estimated Cost: ~$2/month for 10,000 conversions"
echo ""

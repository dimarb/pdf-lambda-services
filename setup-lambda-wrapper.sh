#!/bin/bash

set -e

echo "========================================"
echo "  Lambda S3 Wrapper Setup"
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

# Set defaults
S3_INPUT_BUCKET=${S3_INPUT_BUCKET:-gotenberg-input-files-${AWS_ACCOUNT_ID}}
S3_OUTPUT_BUCKET=${S3_OUTPUT_BUCKET:-gotenberg-output-pdfs-${AWS_ACCOUNT_ID}}
LAMBDA_ROLE_NAME=${LAMBDA_ROLE_NAME:-gotenberg-lambda-execution-role}
WRAPPER_FUNCTION_NAME=${WRAPPER_FUNCTION_NAME:-gotenberg-s3-wrapper}
GOTENBERG_FUNCTION_NAME=${GOTENBERG_FUNCTION_NAME:-gotenberg-pdf-service}

echo "Step 1: Getting Gotenberg Lambda URL..."

# Try to get Function URL first
GOTENBERG_URL=$(aws lambda get-function-url-config \
    --function-name ${GOTENBERG_FUNCTION_NAME} \
    --region ${AWS_REGION} \
    --query 'FunctionUrl' \
    --output text 2>/dev/null || echo "")

if [ -z "$GOTENBERG_URL" ] || [ "$GOTENBERG_URL" = "None" ]; then
    echo "⚠️  No Function URL found, wrapper will invoke Lambda directly"
    GOTENBERG_URL="lambda://${GOTENBERG_FUNCTION_NAME}"
else
    echo "✓ Found Gotenberg URL: ${GOTENBERG_URL}"
fi

echo ""
echo "Step 2: Creating Lambda wrapper Python code..."

# Create Python wrapper script
cat > /tmp/lambda_s3_wrapper.py <<'PYTHON_EOF'
import json
import boto3
import os
import urllib3
from urllib.parse import urlparse

s3 = boto3.client('s3')
lambda_client = boto3.client('lambda')
http = urllib3.PoolManager()

# Configuration from environment
GOTENBERG_URL = os.environ.get('GOTENBERG_URL', 'http://localhost:3000')
GOTENBERG_USER = os.environ.get('GOTENBERG_API_BASIC_AUTH_USERNAME', 'admin')
GOTENBERG_PASS = os.environ.get('GOTENBERG_API_BASIC_AUTH_PASSWORD', 'changeme')
S3_INPUT_BUCKET = os.environ.get('S3_INPUT_BUCKET')
S3_OUTPUT_BUCKET = os.environ.get('S3_OUTPUT_BUCKET')

def lambda_handler(event, context):
    """
    Process PDF conversion from S3 event

    Triggered by S3 ObjectCreated events
    """

    try:
        print(f"Received event: {json.dumps(event)}")

        # Parse S3 event
        record = event['Records'][0]
        input_bucket = record['s3']['bucket']['name']
        input_key = record['s3']['object']['key']

        # Generate output key (same path, change extension to .pdf)
        output_key = input_key.rsplit('.', 1)[0] + '.pdf'

        print(f"Converting {input_bucket}/{input_key} → {S3_OUTPUT_BUCKET}/{output_key}")

        # Download file from S3
        local_input = '/tmp/input_file'
        s3.download_file(input_bucket, input_key, local_input)
        print(f"✓ Downloaded {input_key} from S3")

        # Read file data
        with open(local_input, 'rb') as f:
            file_data = f.read()

        # Determine filename based on file extension
        if input_key.endswith('.html') or input_key.endswith('.htm'):
            filename = 'index.html'
            conversion_type = 'chromium/convert/html'
        else:
            filename = os.path.basename(input_key)
            conversion_type = 'libreoffice/convert'

        # Invoke Gotenberg Lambda directly
        function_name = 'gotenberg-pdf-service'
        print(f"Invoking Gotenberg Lambda directly: {function_name}")

        # Prepare Lambda payload in HTTP format (what Function URL would send)
        import base64

        # Create multipart form data
        boundary = '----WebKitFormBoundary7MA4YWxkTrZu0gW'
        body = (
            f'--{boundary}\r\n'
            f'Content-Disposition: form-data; name="files"; filename="{filename}"\r\n'
            f'Content-Type: application/octet-stream\r\n\r\n'
        ).encode('utf-8')
        body += file_data
        body += f'\r\n--{boundary}--\r\n'.encode('utf-8')

        # Base64 encode the body for Lambda
        body_b64 = base64.b64encode(body).decode('utf-8')

        # Create auth header
        auth_string = f"{GOTENBERG_USER}:{GOTENBERG_PASS}"
        auth_b64 = base64.b64encode(auth_string.encode('utf-8')).decode('utf-8')

        # Lambda event in Function URL format
        lambda_event = {
            "version": "2.0",
            "routeKey": "$default",
            "rawPath": f"/forms/{conversion_type}",
            "rawQueryString": "",
            "headers": {
                "authorization": f"Basic {auth_b64}",
                "content-type": f"multipart/form-data; boundary={boundary}"
            },
            "requestContext": {
                "http": {
                    "method": "POST",
                    "path": f"/forms/{conversion_type}"
                }
            },
            "body": body_b64,
            "isBase64Encoded": True
        }

        # Invoke Lambda
        response = lambda_client.invoke(
            FunctionName=function_name,
            InvocationType='RequestResponse',
            Payload=json.dumps(lambda_event)
        )

        # Parse response
        response_payload = json.loads(response['Payload'].read())

        if response.get('FunctionError'):
            raise Exception(f"Lambda error: {response_payload}")

        # Check status code
        status_code = response_payload.get('statusCode', 500)
        if status_code != 200:
            raise Exception(f"Gotenberg returned {status_code}: {response_payload.get('body', 'No body')}")

        # Get PDF data (base64 encoded in response)
        pdf_data_b64 = response_payload.get('body', '')
        if response_payload.get('isBase64Encoded'):
            pdf_data = base64.b64decode(pdf_data_b64)
        else:
            pdf_data = pdf_data_b64.encode('utf-8')

        print(f"✓ Conversion successful, {len(pdf_data)} bytes")

        # Upload result to S3
        s3.put_object(
            Bucket=S3_OUTPUT_BUCKET,
            Key=output_key,
            Body=pdf_data,
            ContentType='application/pdf'
        )

        print(f"✓ Uploaded to {S3_OUTPUT_BUCKET}/{output_key}")

        # Generate presigned URL for download (valid for 1 hour)
        download_url = s3.generate_presigned_url(
            'get_object',
            Params={'Bucket': S3_OUTPUT_BUCKET, 'Key': output_key},
            ExpiresIn=3600
        )

        result = {
            'success': True,
            'inputBucket': input_bucket,
            'inputKey': input_key,
            'outputBucket': S3_OUTPUT_BUCKET,
            'outputKey': output_key,
            'downloadUrl': download_url,
            'pdfSize': len(pdf_data)
        }

        # Check for N8N webhook metadata in object tags or filename
        webhook_url = None
        job_id = None

        # Try to extract metadata from filename pattern: {job_id}_{webhook_encoded}/file.html
        # or from S3 object tags
        try:
            # Get object tags
            tags_response = s3.get_object_tagging(Bucket=input_bucket, Key=input_key)
            tags = {tag['Key']: tag['Value'] for tag in tags_response.get('Tags', [])}

            webhook_url = tags.get('webhook_url')
            job_id = tags.get('job_id')

            if webhook_url:
                print(f"Found webhook URL in tags: {webhook_url}")
                if job_id:
                    print(f"Job ID: {job_id}")
        except Exception as tag_error:
            print(f"No tags found or error reading tags: {tag_error}")

        # If webhook URL found, notify N8N
        if webhook_url:
            print(f"Notifying N8N webhook...")
            try:
                webhook_payload = {
                    'jobId': job_id,
                    'status': 'completed',
                    'inputKey': input_key,
                    'outputKey': output_key,
                    'downloadUrl': download_url,
                    'pdfSize': len(pdf_data),
                    'timestamp': context.aws_request_id
                }

                webhook_response = http.request(
                    'POST',
                    webhook_url,
                    body=json.dumps(webhook_payload).encode('utf-8'),
                    headers={'Content-Type': 'application/json'},
                    timeout=10.0
                )

                if webhook_response.status in [200, 201, 202]:
                    print(f"✓ N8N webhook notified successfully")
                    result['webhookNotified'] = True
                else:
                    print(f"⚠️ Webhook returned {webhook_response.status}")
                    result['webhookNotified'] = False

            except Exception as webhook_error:
                print(f"⚠️ Failed to notify webhook: {webhook_error}")
                result['webhookNotified'] = False
                result['webhookError'] = str(webhook_error)
        else:
            print("No webhook URL found, skipping notification")

        return {
            'statusCode': 200,
            'body': json.dumps(result)
        }

    except Exception as e:
        print(f"❌ Error: {str(e)}")
        import traceback
        traceback.print_exc()
        return {
            'statusCode': 500,
            'body': json.dumps({
                'success': False,
                'error': str(e)
            })
        }
PYTHON_EOF

echo "✓ Python code created"

echo ""
echo "Step 3: Creating deployment package..."

cd /tmp
zip -q lambda_s3_wrapper.zip lambda_s3_wrapper.py
echo "✓ Deployment package created"

echo ""
echo "Step 4: Getting IAM role..."

ROLE_ARN=$(aws iam get-role \
    --role-name ${LAMBDA_ROLE_NAME} \
    --query 'Role.Arn' \
    --output text)

echo "✓ Role ARN: ${ROLE_ARN}"

echo ""
echo "Step 5: Creating/Updating Lambda function..."

# Check if function exists
if aws lambda get-function \
    --function-name ${WRAPPER_FUNCTION_NAME} \
    --region ${AWS_REGION} 2>/dev/null; then

    echo "Function exists, updating code..."
    aws lambda update-function-code \
        --function-name ${WRAPPER_FUNCTION_NAME} \
        --zip-file fileb:///tmp/lambda_s3_wrapper.zip \
        --region ${AWS_REGION} > /dev/null

    echo "✓ Code updated"

    echo "Updating configuration..."
    aws lambda update-function-configuration \
        --function-name ${WRAPPER_FUNCTION_NAME} \
        --environment "Variables={GOTENBERG_URL=${GOTENBERG_URL},GOTENBERG_API_BASIC_AUTH_USERNAME=${GOTENBERG_API_BASIC_AUTH_USERNAME},GOTENBERG_API_BASIC_AUTH_PASSWORD=${GOTENBERG_API_BASIC_AUTH_PASSWORD},S3_INPUT_BUCKET=${S3_INPUT_BUCKET},S3_OUTPUT_BUCKET=${S3_OUTPUT_BUCKET}}" \
        --region ${AWS_REGION} > /dev/null

    echo "✓ Configuration updated"
else
    echo "Creating new function..."
    aws lambda create-function \
        --function-name ${WRAPPER_FUNCTION_NAME} \
        --runtime python3.11 \
        --role ${ROLE_ARN} \
        --handler lambda_s3_wrapper.lambda_handler \
        --zip-file fileb:///tmp/lambda_s3_wrapper.zip \
        --timeout 300 \
        --memory-size 512 \
        --environment "Variables={GOTENBERG_URL=${GOTENBERG_URL},GOTENBERG_API_BASIC_AUTH_USERNAME=${GOTENBERG_API_BASIC_AUTH_USERNAME},GOTENBERG_API_BASIC_AUTH_PASSWORD=${GOTENBERG_API_BASIC_AUTH_PASSWORD},S3_INPUT_BUCKET=${S3_INPUT_BUCKET},S3_OUTPUT_BUCKET=${S3_OUTPUT_BUCKET}}" \
        --region ${AWS_REGION} > /dev/null

    echo "✓ Function created"
fi

echo ""
echo "Step 6: Configuring S3 trigger..."

# Add Lambda permission for S3
aws lambda add-permission \
    --function-name ${WRAPPER_FUNCTION_NAME} \
    --statement-id s3-trigger-permission \
    --action lambda:InvokeFunction \
    --principal s3.amazonaws.com \
    --source-arn arn:aws:s3:::${S3_INPUT_BUCKET} \
    --region ${AWS_REGION} 2>/dev/null || echo "✓ Permission already exists"

# Get Lambda ARN
WRAPPER_ARN=$(aws lambda get-function \
    --function-name ${WRAPPER_FUNCTION_NAME} \
    --region ${AWS_REGION} \
    --query 'Configuration.FunctionArn' \
    --output text)

# Configure S3 notification
cat > /tmp/s3-notification.json <<EOF
{
  "LambdaFunctionConfigurations": [
    {
      "Id": "TriggerGotenbergWrapper",
      "LambdaFunctionArn": "${WRAPPER_ARN}",
      "Events": ["s3:ObjectCreated:*"],
      "Filter": {
        "Key": {
          "FilterRules": [
            {"Name": "suffix", "Value": ".html"}
          ]
        }
      }
    }
  ]
}
EOF

aws s3api put-bucket-notification-configuration \
    --bucket ${S3_INPUT_BUCKET} \
    --notification-configuration file:///tmp/s3-notification.json

echo "✓ S3 trigger configured"

echo ""
echo "========================================"
echo "✅ LAMBDA WRAPPER SETUP COMPLETED!"
echo "========================================"
echo ""
echo "Lambda Wrapper:"
echo "  Name: ${WRAPPER_FUNCTION_NAME}"
echo "  ARN:  ${WRAPPER_ARN}"
echo ""
echo "Configuration:"
echo "  Gotenberg URL: ${GOTENBERG_URL}"
echo "  Input Bucket:  ${S3_INPUT_BUCKET}"
echo "  Output Bucket: ${S3_OUTPUT_BUCKET}"
echo ""
echo "🧪 Test it:"
echo "  1. Upload an HTML file to s3://${S3_INPUT_BUCKET}/test/index.html"
echo "  2. Check CloudWatch Logs for ${WRAPPER_FUNCTION_NAME}"
echo "  3. Download PDF from s3://${S3_OUTPUT_BUCKET}/test/index.pdf"
echo ""

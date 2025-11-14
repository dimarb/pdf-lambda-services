#!/bin/bash

# Test script for N8N webhook integration
# This simulates what N8N would do when calling the PDF service

set -e

echo "=================================================="
echo "  Gotenberg Lambda - Webhook Integration Test"
echo "=================================================="
echo ""

# Load environment
if [ -f .env ]; then
    export $(cat .env | grep -v '^#' | grep -v '^$' | xargs)
fi

# Configuration
JOB_ID="test-webhook-$(date +%s)"
WEBHOOK_URL=${WEBHOOK_URL:-"https://webhook.site/your-unique-id"}  # Replace with your test webhook
S3_INPUT_BUCKET=${S3_INPUT_BUCKET:-gotenberg-input-files-${AWS_ACCOUNT_ID}}
S3_OUTPUT_BUCKET=${S3_OUTPUT_BUCKET:-gotenberg-output-pdfs-${AWS_ACCOUNT_ID}}

echo "Configuration:"
echo "  Job ID: $JOB_ID"
echo "  Webhook URL: $WEBHOOK_URL"
echo "  Input Bucket: $S3_INPUT_BUCKET"
echo "  Output Bucket: $S3_OUTPUT_BUCKET"
echo ""

# Create test HTML
echo "Step 1: Creating test HTML..."
cat > /tmp/test-webhook.html <<EOF
<!DOCTYPE html>
<html lang="es">
<head>
    <meta charset="UTF-8">
    <title>Webhook Integration Test</title>
    <style>
        body {
            font-family: 'Segoe UI', Arial, sans-serif;
            max-width: 900px;
            margin: 40px auto;
            padding: 30px;
            background: linear-gradient(to bottom right, #667eea, #764ba2);
            color: white;
        }
        .container {
            background: white;
            color: #333;
            padding: 40px;
            border-radius: 15px;
            box-shadow: 0 10px 40px rgba(0,0,0,0.3);
        }
        .header {
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 30px;
            border-radius: 10px;
            margin-bottom: 30px;
            text-align: center;
        }
        .success {
            background: #10b981;
            color: white;
            padding: 20px;
            border-radius: 8px;
            margin: 20px 0;
        }
        .info {
            background: #f3f4f6;
            padding: 15px;
            border-left: 4px solid #3b82f6;
            margin: 15px 0;
        }
        .code {
            background: #1f2937;
            color: #10b981;
            padding: 15px;
            border-radius: 5px;
            font-family: 'Courier New', monospace;
            overflow-x: auto;
        }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <h1>✅ Webhook Integration Test</h1>
            <p>Gotenberg Lambda PDF Service</p>
        </div>

        <div class="success">
            <strong>¡SUCCESS!</strong> Este PDF fue generado automáticamente y una notificación fue enviada al webhook de N8N.
        </div>

        <div class="info">
            <h3>📋 Detalles del Job</h3>
            <p><strong>Job ID:</strong> $JOB_ID</p>
            <p><strong>Timestamp:</strong> $(date '+%Y-%m-%d %H:%M:%S')</p>
            <p><strong>Webhook:</strong> $WEBHOOK_URL</p>
        </div>

        <h3>🔄 Flujo de Procesamiento</h3>
        <ol>
            <li>N8N genera un Job ID único</li>
            <li>N8N sube el HTML a S3 con tags (webhook_url, job_id)</li>
            <li>S3 Event dispara Lambda Wrapper</li>
            <li>Lambda Wrapper invoca Gotenberg Lambda</li>
            <li>Gotenberg convierte HTML → PDF</li>
            <li>Lambda sube PDF a S3 Output</li>
            <li><strong>Lambda llama al webhook de N8N con resultado</strong></li>
            <li>N8N recibe notificación y continúa el flujo</li>
        </ol>

        <h3>📤 Payload del Webhook</h3>
        <div class="code">
{
  "jobId": "$JOB_ID",
  "status": "completed",
  "inputKey": "$JOB_ID/index.html",
  "outputKey": "$JOB_ID/index.pdf",
  "downloadUrl": "https://...",
  "pdfSize": 12345
}
        </div>

        <h3>💡 Ventajas de este Approach</h3>
        <ul>
            <li>✅ Respuesta inmediata a N8N cuando PDF está listo</li>
            <li>✅ No requiere polling de S3</li>
            <li>✅ N8N puede continuar el flujo automáticamente</li>
            <li>✅ Menor latencia end-to-end</li>
            <li>✅ Trazabilidad completa con Job IDs</li>
        </ul>

        <p style="margin-top: 40px; text-align: center; color: #6b7280;">
            <em>Generado automáticamente por Gotenberg Lambda Service</em>
        </p>
    </div>
</body>
</html>
EOF

echo "✓ HTML created"

# Upload to S3 with tags
echo ""
echo "Step 2: Uploading to S3 with webhook metadata..."

aws s3 cp /tmp/test-webhook.html \
    s3://${S3_INPUT_BUCKET}/${JOB_ID}/index.html \
    --region ${AWS_REGION} \
    --tagging "webhook_url=${WEBHOOK_URL}&job_id=${JOB_ID}"

echo "✓ Uploaded to s3://${S3_INPUT_BUCKET}/${JOB_ID}/index.html"

# Verify tags
echo ""
echo "Step 3: Verifying S3 tags..."
aws s3api get-object-tagging \
    --bucket ${S3_INPUT_BUCKET} \
    --key ${JOB_ID}/index.html \
    --region ${AWS_REGION} \
    --query 'TagSet' \
    --output table

echo ""
echo "Step 4: Waiting for processing (30 seconds)..."
echo "Lambda will:"
echo "  1. Detect the S3 event"
echo "  2. Convert HTML to PDF"
echo "  3. Upload PDF to S3 output"
echo "  4. Call your webhook at: $WEBHOOK_URL"
echo ""

for i in {30..1}; do
    printf "\rTime remaining: %02d seconds" $i
    sleep 1
done

echo ""
echo ""
echo "Step 5: Checking results..."

# Check if PDF was created
if aws s3 ls s3://${S3_OUTPUT_BUCKET}/${JOB_ID}/index.pdf --region ${AWS_REGION} 2>/dev/null; then
    PDF_SIZE=$(aws s3 ls s3://${S3_OUTPUT_BUCKET}/${JOB_ID}/index.pdf --region ${AWS_REGION} | awk '{print $3}')
    echo "✓ PDF generated successfully!"
    echo "  Size: $PDF_SIZE bytes"
    echo "  Location: s3://${S3_OUTPUT_BUCKET}/${JOB_ID}/index.pdf"
    echo ""

    # Generate presigned URL
    echo "Download URL (valid for 1 hour):"
    aws s3 presign s3://${S3_OUTPUT_BUCKET}/${JOB_ID}/index.pdf \
        --expires-in 3600 \
        --region ${AWS_REGION}

    echo ""
    echo "=================================================="
    echo "  ✅ TEST COMPLETED SUCCESSFULLY!"
    echo "=================================================="
    echo ""
    echo "Next steps:"
    echo "  1. Check your webhook URL for the notification"
    echo "  2. You should see a POST with JSON payload containing:"
    echo "     - jobId: $JOB_ID"
    echo "     - status: completed"
    echo "     - downloadUrl: presigned S3 URL"
    echo "     - pdfSize: bytes"
    echo ""
    echo "  3. Use this pattern in your N8N workflows!"
    echo ""
else
    echo "❌ PDF was not generated"
    echo ""
    echo "Checking Lambda logs..."

    LOG_STREAM=$(aws logs describe-log-streams \
        --log-group-name /aws/lambda/gotenberg-s3-wrapper \
        --order-by LastEventTime \
        --descending \
        --limit 1 \
        --query "logStreams[0].logStreamName" \
        --output text \
        --region ${AWS_REGION})

    if [ -n "$LOG_STREAM" ] && [ "$LOG_STREAM" != "None" ]; then
        echo "Latest errors:"
        aws logs get-log-events \
            --log-group-name /aws/lambda/gotenberg-s3-wrapper \
            --log-stream-name "$LOG_STREAM" \
            --limit 30 \
            --region ${AWS_REGION} \
            --query "events[*].message" \
            --output text | grep -E "(Error|❌)" | tail -10
    fi
fi

echo ""

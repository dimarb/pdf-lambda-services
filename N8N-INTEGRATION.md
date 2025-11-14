# Integración con N8N - Gotenberg Lambda PDF Service

Guía completa para integrar el servicio de conversión de PDFs con N8N.

## 📋 Índice

1. [Arquitectura](#arquitectura)
2. [Configuración Inicial](#configuración-inicial)
3. [Workflow N8N - Método con Webhook](#workflow-n8n---método-con-webhook)
4. [Workflow N8N - Método Simple (Polling)](#workflow-n8n---método-simple-polling)
5. [Ejemplos de Uso](#ejemplos-de-uso)
6. [Troubleshooting](#troubleshooting)

---

## Arquitectura

### Flujo Completo con Webhook (Recomendado)

```
┌─────────┐
│  N8N    │
│ Trigger │
└────┬────┘
     │
     ▼
┌─────────────────────────────────────┐
│ 1. Generar Job ID único             │
│ 2. Crear Webhook URL de respuesta  │
└────┬────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────┐
│ 3. Subir HTML a S3 Input            │
│    con tags:                        │
│    - webhook_url: URL del webhook   │
│    - job_id: ID único del job       │
└────┬────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────┐
│ S3 Event Trigger                    │
│         ↓                           │
│ Lambda Wrapper                      │
│         ↓                           │
│ Gotenberg Lambda (convierte PDF)   │
│         ↓                           │
│ Sube PDF a S3 Output                │
│         ↓                           │
│ Llama al Webhook de N8N ←──────────┼─┐
└─────────────────────────────────────┘ │
                                        │
     ┌──────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────┐
│ N8N Webhook recibe notificación:    │
│ {                                   │
│   jobId: "abc123",                  │
│   status: "completed",              │
│   downloadUrl: "https://...",       │
│   pdfSize: 18731                    │
│ }                                   │
└────┬────────────────────────────────┘
     │
     ▼
┌─────────────────────────────────────┐
│ 4. N8N continúa el flujo            │
│    - Descargar PDF                  │
│    - Enviar por email               │
│    - Guardar en base de datos       │
│    - etc.                           │
└─────────────────────────────────────┘
```

---

## Configuración Inicial

### 1. Credenciales AWS en N8N

Crear credenciales AWS en N8N:

1. **Settings → Credentials → New**
2. Tipo: **AWS**
3. Completar:
   - Access Key ID: `tu_access_key`
   - Secret Access Key: `tu_secret_key`
   - Region: `us-east-1` (o tu región)

### 2. Variables de Entorno

Configurar en N8N (Settings → Environment Variables):

```env
GOTENBERG_S3_INPUT_BUCKET=gotenberg-input-files-830115760891
GOTENBERG_S3_OUTPUT_BUCKET=gotenberg-output-pdfs-830115760891
GOTENBERG_AWS_REGION=us-east-1
```

---

## Workflow N8N - Método con Webhook

Este es el método **recomendado** porque N8N recibe una notificación automática cuando el PDF está listo.

### Workflow JSON

```json
{
  "name": "Gotenberg PDF Conversion - Webhook",
  "nodes": [
    {
      "parameters": {},
      "name": "Trigger",
      "type": "n8n-nodes-base.manualTrigger",
      "position": [250, 300],
      "id": "trigger-1"
    },
    {
      "parameters": {
        "jsCode": "// Generar Job ID único\nconst jobId = `job_${Date.now()}_${Math.random().toString(36).substr(2, 9)}`;\n\n// Webhook URL de N8N (obtenida del nodo Webhook)\nconst webhookUrl = $('Wait for Webhook').context.webhook.url;\n\nreturn {\n  jobId,\n  webhookUrl,\n  inputKey: `${jobId}/index.html`\n};"
      },
      "name": "Generate Job Metadata",
      "type": "n8n-nodes-base.code",
      "position": [450, 300],
      "id": "code-1"
    },
    {
      "parameters": {
        "operation": "upload",
        "bucketName": "={{ $env.GOTENBERG_S3_INPUT_BUCKET }}",
        "fileName": "={{ $json.inputKey }}",
        "binaryData": true,
        "additionalFields": {
          "tags": {
            "tag": [
              {
                "key": "webhook_url",
                "value": "={{ $json.webhookUrl }}"
              },
              {
                "key": "job_id",
                "value": "={{ $json.jobId }}"
              }
            ]
          }
        }
      },
      "name": "Upload to S3 with Tags",
      "type": "n8n-nodes-base.awsS3",
      "credentials": {
        "aws": "AWS Account"
      },
      "position": [650, 300],
      "id": "s3-upload-1"
    },
    {
      "parameters": {
        "path": "gotenberg-webhook",
        "responseMode": "lastNode",
        "options": {}
      },
      "name": "Wait for Webhook",
      "type": "n8n-nodes-base.webhook",
      "position": [850, 300],
      "id": "webhook-1",
      "webhookId": "gotenberg-callback"
    },
    {
      "parameters": {
        "url": "={{ $json.downloadUrl }}",
        "options": {}
      },
      "name": "Download PDF from S3",
      "type": "n8n-nodes-base.httpRequest",
      "position": [1050, 300],
      "id": "download-1"
    },
    {
      "parameters": {
        "operation": "sendEmail",
        "email": "user@example.com",
        "subject": "Your PDF is ready",
        "message": "PDF Size: {{ $json.pdfSize }} bytes",
        "attachments": "data"
      },
      "name": "Send Email",
      "type": "n8n-nodes-base.emailSend",
      "position": [1250, 300],
      "id": "email-1"
    }
  ],
  "connections": {
    "Trigger": {
      "main": [[{ "node": "Generate Job Metadata", "type": "main", "index": 0 }]]
    },
    "Generate Job Metadata": {
      "main": [[{ "node": "Upload to S3 with Tags", "type": "main", "index": 0 }]]
    },
    "Upload to S3 with Tags": {
      "main": [[{ "node": "Wait for Webhook", "type": "main", "index": 0 }]]
    },
    "Wait for Webhook": {
      "main": [[{ "node": "Download PDF from S3", "type": "main", "index": 0 }]]
    },
    "Download PDF from S3": {
      "main": [[{ "node": "Send Email", "type": "main", "index": 0 }]]
    }
  }
}
```

### Explicación de los Nodos

1. **Trigger**: Inicio manual o trigger personalizado
2. **Generate Job Metadata**: Crea un Job ID único y obtiene la URL del webhook
3. **Upload to S3 with Tags**: Sube el HTML a S3 con tags de metadata
4. **Wait for Webhook**: Espera la notificación de Lambda cuando el PDF esté listo
5. **Download PDF from S3**: Descarga el PDF usando la URL presignada
6. **Send Email**: Envía el PDF por email (o cualquier otra acción)

---

## Workflow N8N - Método Simple (Polling)

Si prefieres un método más simple sin webhooks:

### Workflow JSON

```json
{
  "name": "Gotenberg PDF Conversion - Simple",
  "nodes": [
    {
      "parameters": {},
      "name": "Trigger",
      "type": "n8n-nodes-base.manualTrigger",
      "position": [250, 300],
      "id": "trigger-1"
    },
    {
      "parameters": {
        "jsCode": "const jobId = `job_${Date.now()}`;\nreturn {\n  jobId,\n  inputKey: `${jobId}/index.html`,\n  outputKey: `${jobId}/index.pdf`\n};"
      },
      "name": "Generate Job ID",
      "type": "n8n-nodes-base.code",
      "position": [450, 300],
      "id": "code-1"
    },
    {
      "parameters": {
        "operation": "upload",
        "bucketName": "={{ $env.GOTENBERG_S3_INPUT_BUCKET }}",
        "fileName": "={{ $json.inputKey }}",
        "binaryData": true
      },
      "name": "Upload HTML to S3",
      "type": "n8n-nodes-base.awsS3",
      "credentials": {
        "aws": "AWS Account"
      },
      "position": [650, 300],
      "id": "s3-upload-1"
    },
    {
      "parameters": {
        "amount": 30,
        "unit": "seconds"
      },
      "name": "Wait 30 seconds",
      "type": "n8n-nodes-base.wait",
      "position": [850, 300],
      "id": "wait-1"
    },
    {
      "parameters": {
        "operation": "download",
        "bucketName": "={{ $env.GOTENBERG_S3_OUTPUT_BUCKET }}",
        "fileName": "={{ $json.outputKey }}"
      },
      "name": "Download PDF from S3",
      "type": "n8n-nodes-base.awsS3",
      "credentials": {
        "aws": "AWS Account"
      },
      "position": [1050, 300],
      "id": "s3-download-1"
    },
    {
      "parameters": {
        "operation": "sendEmail",
        "email": "user@example.com",
        "subject": "Your PDF is ready",
        "attachments": "data"
      },
      "name": "Send Email",
      "type": "n8n-nodes-base.emailSend",
      "position": [1250, 300],
      "id": "email-1"
    }
  ],
  "connections": {
    "Trigger": {
      "main": [[{ "node": "Generate Job ID", "type": "main", "index": 0 }]]
    },
    "Generate Job ID": {
      "main": [[{ "node": "Upload HTML to S3", "type": "main", "index": 0 }]]
    },
    "Upload HTML to S3": {
      "main": [[{ "node": "Wait 30 seconds", "type": "main", "index": 0 }]]
    },
    "Wait 30 seconds": {
      "main": [[{ "node": "Download PDF from S3", "type": "main", "index": 0 }]]
    },
    "Download PDF from S3": {
      "main": [[{ "node": "Send Email", "type": "main", "index": 0 }]]
    }
  }
}
```

---

## Ejemplos de Uso

### Ejemplo 1: Convertir HTML desde N8N

**Código JavaScript en N8N:**

```javascript
// En un nodo "Code"
const html = `
<!DOCTYPE html>
<html>
<head>
    <title>Invoice #12345</title>
    <style>
        body { font-family: Arial; padding: 40px; }
        .header { background: #3b82f6; color: white; padding: 20px; }
        .total { font-size: 24px; font-weight: bold; }
    </style>
</head>
<body>
    <div class="header">
        <h1>INVOICE #12345</h1>
        <p>Date: ${new Date().toLocaleDateString()}</p>
    </div>
    <p class="total">Total: $1,234.56</p>
</body>
</html>
`;

// Convertir a Buffer
const buffer = Buffer.from(html, 'utf-8');

return {
  binary: {
    data: buffer
  }
};
```

### Ejemplo 2: Usar con HTTP Request Node

Si prefieres usar HTTP directamente:

```javascript
// Nodo HTTP Request
// POST https://gotenberg-input-files-830115760891.s3.amazonaws.com/my-job/index.html

// Headers:
{
  "x-amz-tagging": "webhook_url=https://your-n8n.com/webhook/gotenberg-callback&job_id=my-job-123"
}

// Body: HTML content
```

### Ejemplo 3: Procesar Múltiples Archivos

```javascript
// Nodo Code - Crear múltiples jobs
const files = $input.all();
const jobs = [];

for (let i = 0; i < files.length; i++) {
  const jobId = `batch_${Date.now()}_${i}`;
  jobs.push({
    jobId,
    inputKey: `${jobId}/document.html`,
    webhookUrl: $('Wait for Webhook').context.webhook.url,
    content: files[i].json.htmlContent
  });
}

return jobs;
```

---

## Troubleshooting

### El PDF no se genera

**Verificar:**

```bash
# 1. Verificar que el archivo se subió a S3
aws s3 ls s3://gotenberg-input-files-830115760891/

# 2. Revisar logs de Lambda Wrapper
aws logs tail /aws/lambda/gotenberg-s3-wrapper --follow

# 3. Verificar tags del archivo
aws s3api get-object-tagging \
  --bucket gotenberg-input-files-830115760891 \
  --key tu-job/index.html
```

### El webhook no se llama

**Posibles causas:**

1. **Tags no configurados correctamente**: Verificar que `webhook_url` y `job_id` estén en los tags del objeto S3
2. **URL del webhook incorrecta**: Debe ser accesible públicamente desde Lambda
3. **Timeout del webhook**: Lambda espera máximo 10 segundos para respuesta

**Solución:**
```javascript
// Asegurarse de que la URL del webhook sea correcta
const webhookUrl = $('Wait for Webhook').context.webhook.url;
console.log('Webhook URL:', webhookUrl);
```

### Error de permisos

Si ves `AccessDenied`:

```bash
# Verificar credenciales AWS en N8N
# Asegurarse de que tienen permisos para:
# - s3:PutObject
# - s3:PutObjectTagging
# - s3:GetObject
```

### PDF corrupto o vacío

**Verificar el HTML:**
- Debe ser HTML válido
- Incluir `<!DOCTYPE html>`
- CSS inline o en `<style>` tags

---

## Costos Estimados

Con esta arquitectura:

| Componente | Costo Mensual (10,000 PDFs) |
|------------|------------------------------|
| Lambda Wrapper | $0.002 |
| Lambda Gotenberg | $2.00 |
| S3 Storage | $0.023 |
| S3 Requests | $0.008 |
| **Total** | **~$2.03/mes** |

---

## Próximos Pasos

1. ✅ Importar workflow en N8N
2. ✅ Configurar credenciales AWS
3. ✅ Probar con un documento simple
4. ✅ Adaptar a tu caso de uso específico

## Soporte

- [Gotenberg Documentation](https://gotenberg.dev)
- [N8N Documentation](https://docs.n8n.io)
- [AWS Lambda Documentation](https://docs.aws.amazon.com/lambda/)

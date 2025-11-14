# Gotenberg Lambda PDF Service

Servicio de conversión de PDFs usando Gotenberg desplegado en AWS Lambda con integración N8N mediante S3.

## 🎯 Arquitectura

```
Cliente/N8N → S3 (input) → Lambda (async) → S3 (output) → N8N/Cliente
```

**Ventajas:**
- ✅ Sin timeout de 30 segundos
- ✅ Procesamiento asíncrono
- ✅ Muy económico (~$2-3/mes)
- ✅ Escalable automáticamente
- ✅ Integración perfecta con N8N

## 🚀 Quick Start

### 1. Configurar credenciales AWS

```bash
cp .env.example .env
# Editar .env con tus credenciales AWS
```

### 2. Desplegar Lambda

```bash
make deploy
```

Esto creará automáticamente:
- ✅ IAM Role con permisos necesarios
- ✅ ECR Repository para la imagen Docker
- ✅ Lambda Function con Gotenberg (4GB RAM, 300s timeout)
- ✅ Custom Docker image con optimizaciones

### 3. Configurar S3 para modo asíncrono

```bash
make setup-s3-async
```

Esto creará:
- ✅ S3 bucket de input (`gotenberg-input-files-ACCOUNT_ID`)
- ✅ S3 bucket de output (`gotenberg-output-pdfs-ACCOUNT_ID`)
- ✅ Permisos IAM para Lambda
- ✅ Lifecycle policies (auto-eliminar archivos después de 7 días)

### 4. Integrar con N8N

Ver guía completa en [N8N-INTEGRATION.md](N8N-INTEGRATION.md)

## 📦 Componentes

### Lambda Function

- **Runtime**: Container Image (Gotenberg 8)
- **Memory**: 4096 MB
- **Timeout**: 300 segundos
- **Arquitectura**: linux/amd64
- **Invocación**: Asíncrona vía SDK o N8N

### S3 Buckets

- **Input Bucket**: Recibe archivos para convertir
- **Output Bucket**: Almacena PDFs generados
- **Retention**: 7 días (configurable)

### Engines Disponibles

- **Chromium**: HTML/URL → PDF
- **LibreOffice**: Office documents → PDF
- **PDF Tools**: qpdf, pdfcpu, pdftk (merge, split, flatten)

## �� Comandos Disponibles

```bash
make help              # Ver todos los comandos
make deploy            # Desplegar Lambda
make setup-s3-async    # Configurar S3 buckets
make test-local        # Probar Gotenberg localmente (puerto 3000)
make shell             # Shell interactivo con AWS CLI
make clean             # Limpiar imágenes Docker
```

## 💰 Costos Estimados

### Lambda + S3 Async (Arquitectura actual)

```
Lambda invocaciones:  10,000/mes × $0.20/1M           = $0.002
Lambda compute:       10,000 × 30s × 4GB × $0.0000167 = $2.00
S3 storage:           ~1GB × $0.023                   = $0.023
S3 requests:          20,000 × $0.0004/1000           = $0.008
─────────────────────────────────────────────────────────────
Total:                                                  ~$2.03/mes
```

### Desglose detallado:
- **Lambda**: $2.00/mes (para 10,000 conversiones de ~30s cada una)
- **S3**: $0.03/mes (storage + requests)
- **Data Transfer**: Incluido en free tier

## 🔐 Autenticación

Gotenberg usa HTTP Basic Auth:

```bash
# Configurar en .env
GOTENBERG_API_BASIC_AUTH_USERNAME=admin
GOTENBERG_API_BASIC_AUTH_PASSWORD=tu-password-seguro
```

## 📖 Uso Programático

### Invocación directa con AWS SDK

```javascript
const AWS = require('aws-sdk');
const lambda = new AWS.Lambda();

const params = {
  FunctionName: 'gotenberg-pdf-service',
  InvocationType: 'Event', // Async!
  Payload: JSON.stringify({
    inputBucket: 'gotenberg-input-files-123456',
    inputKey: 'job-abc/input.html',
    outputBucket: 'gotenberg-output-pdfs-123456',
    outputKey: 'job-abc/output.pdf',
    conversionType: 'chromium/convert/html'
  })
};

lambda.invoke(params).promise();
```

### Con N8N

Ver workflow completo en [N8N-INTEGRATION.md](N8N-INTEGRATION.md)

## 🧪 Testing Local

Probar Gotenberg localmente antes de desplegar:

```bash
make test-local

# En otra terminal:
curl -X POST http://localhost:3000/forms/chromium/convert/url \
  -u admin:password \
  -F url=https://example.com \
  -o output.pdf
```

## 🔍 Troubleshooting

Ver [TROUBLESHOOTING.md](TROUBLESHOOTING.md) para soluciones a problemas comunes.

### Verificar estado de recursos

```bash
make shell

# Dentro del shell:
aws lambda get-function --function-name gotenberg-pdf-service --region us-east-1
aws s3 ls | grep gotenberg
```

## 📁 Estructura del Proyecto

```
.
├── Dockerfile                  # Deployment tool container
├── Dockerfile.gotenberg         # Custom Gotenberg image con optimizaciones
├── deploy.sh                   # Script de deployment Lambda
├── setup-iam.sh                # Script de configuración IAM
├── setup-s3-async.sh           # Script de configuración S3
├── entrypoint.sh               # Entrypoint del deployment tool
├── iam-policy.json             # Trust policy para Lambda role
├── Makefile                    # Comandos simplificados
├── .env.example                # Template de configuración
├── README.md                   # Este archivo
├── N8N-INTEGRATION.md          # Guía de integración con N8N
├── QUICKSTART.md               # Guía rápida de inicio
└── TROUBLESHOOTING.md          # Solución de problemas
```

## 🎯 Integración con N8N

### Opción 1: Con Webhook (Recomendado)

N8N recibe notificación automática cuando el PDF está listo:

```
N8N → S3 (con tags) → Lambda → Gotenberg → S3 → Webhook N8N
```

**Ventajas:**
- ✅ Respuesta inmediata
- ✅ No requiere polling
- ✅ Trazabilidad completa

Ver guía completa en [N8N-INTEGRATION.md](N8N-INTEGRATION.md)

### Opción 2: Simple (Polling)

N8N espera 30 segundos y descarga el PDF:

```
N8N → S3 → Lambda → Gotenberg → S3 ← N8N (después de 30s)
```

### Probar Webhook Integration

```bash
# 1. Obtener un webhook de prueba en https://webhook.site
# 2. Configurar la URL del webhook
export WEBHOOK_URL="https://webhook.site/your-unique-id"

# 3. Ejecutar test
make test-webhook
```

## 🚀 Próximos Pasos

1. ✅ Lambda desplegado
2. ✅ S3 configurado
3. ✅ Lambda Wrapper con soporte de webhooks
4. 📝 Integrar con N8N (ver [N8N-INTEGRATION.md](N8N-INTEGRATION.md))
5. 🧪 Probar con `make test-webhook`
6. 📊 Monitorear costos en AWS Console

## 🆘 Soporte

- [Gotenberg Documentation](https://gotenberg.dev)
- [AWS Lambda Documentation](https://docs.aws.amazon.com/lambda/)
- [N8N Documentation](https://docs.n8n.io)

## 📄 Licencia

Este proyecto es una herramienta de deployment para Gotenberg en AWS Lambda.
- Gotenberg: MIT License
- Este deployment tool: Uso libre

---
By
<div align="center">
  <img src="./dimar-borda.png" alt="dimar-borda" width="300" height="300" />
</div>
# Quick Start - Desplegar Gotenberg a Lambda en 2 Pasos

## Paso 1: Configurar Credenciales AWS

Edita el archivo `.env` y configura tus credenciales:

```bash
# AWS Configuration (REQUERIDO)
AWS_REGION=us-east-1
AWS_ACCOUNT_ID=123456789012
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY

# Gotenberg Authentication (OPCIONAL - usa valores por defecto si no cambias)
GOTENBERG_API_BASIC_AUTH_USERNAME=admin
GOTENBERG_API_BASIC_AUTH_PASSWORD=tu-password-segura
```

## Paso 2: Desplegar

```bash
make deploy
```

¡Eso es todo! El contenedor automáticamente:
- ✅ Crea el rol IAM necesario (si no existe)
- ✅ Descarga la imagen oficial de Gotenberg Lambda
- ✅ Sube la imagen a ECR
- ✅ Crea/actualiza la función Lambda
- ✅ Configura autenticación y todos los motores PDF
- ✅ Crea Function URL (acceso HTTPS público)

Al finalizar, verás la URL de tu servicio:
```
🌐 Function URL (HTTP endpoint):
   https://abc123xyz.lambda-url.us-east-1.on.aws/

📝 Test your deployment:
   curl -X POST https://abc123xyz.lambda-url.us-east-1.on.aws/forms/chromium/convert/url \
     -u admin:tu-password \
     -F url=https://example.com \
     -o output.pdf
```

## Uso sin Make

Si no tienes `make` instalado:

```bash
# Construir el contenedor
docker build -t gotenberg-deploy-tool:latest .

# Desplegar todo
docker run --rm \
  -v $(pwd):/workspace \
  -v /var/run/docker.sock:/var/run/docker.sock \
  gotenberg-deploy-tool:latest
```

## Testing Local

Antes de desplegar, puedes probar Gotenberg localmente:

```bash
make test-local
```

Luego prueba la autenticación:
```bash
curl -X POST http://localhost:3000/forms/chromium/convert/url \
  -u admin:tu-password \
  -F url=https://example.com \
  -o output.pdf
```

## Comandos Disponibles

```bash
make deploy       # Despliega todo automáticamente
make test-local   # Prueba Gotenberg localmente
make shell        # Shell interactiva con AWS CLI
make clean        # Limpia contenedores
```

## Variables de Entorno Opcionales

Todas estas tienen valores por defecto razonables:

```bash
# Lambda Configuration
LAMBDA_FUNCTION_NAME=gotenberg-pdf-service
LAMBDA_MEMORY_SIZE=2048
LAMBDA_TIMEOUT=300

# ECR Configuration
ECR_REPOSITORY_NAME=gotenberg-lambda
ECR_IMAGE_TAG=latest

# PDF Engines (todos habilitados por defecto)
PDFENGINES_MERGE_ENGINES=qpdf,pdfcpu,pdftk
PDFENGINES_SPLIT_ENGINES=qpdf,pdfcpu,pdftk
PDFENGINES_FLATTEN_ENGINES=qpdf
PDFENGINES_CONVERT_ENGINES=libreoffice-pdfengine
```

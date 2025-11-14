# Troubleshooting - Gotenberg Lambda Deployment

## Errores Comunes y Soluciones

### 1. Error: Rosetta / Architecture Mismatch

**Síntoma:**
```
rosetta error: failed to open elf at /lib64/ld-linux-x86-64.so.2
```

**Causa:** Estás en Mac con Apple Silicon (M1/M2/M3) y la imagen estaba usando binarios x86-64.

**Solución:** ✅ Ya está arreglado en la última versión. Reconstruye la imagen:
```bash
make clean
make build
```

### 2. Error: No se puede autenticar con AWS

**Síntoma:**
```
Unable to locate credentials
```

**Solución:**
Verifica que tu archivo `.env` tenga las credenciales correctas:
```bash
cat .env | grep AWS_
```

Deben estar estos 4 campos:
- `AWS_REGION`
- `AWS_ACCOUNT_ID`
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`

### 3. Error: Cannot connect to Docker daemon

**Síntoma:**
```
Cannot connect to the Docker daemon at unix:///var/run/docker.sock
```

**Solución:**
1. Asegúrate de que Docker Desktop esté corriendo
2. Verifica con: `docker ps`
3. En Mac, asegúrate que Docker Desktop tenga permisos completos

### 4. Error: ECR authentication failed

**Síntoma:**
```
Error saving credentials: error storing credentials
```

**Solución:**
```bash
# Desde la shell interactiva
make shell

# Dentro del contenedor:
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin \
  123456789012.dkr.ecr.us-east-1.amazonaws.com
```

### 5. Error: Lambda function already exists

**Síntoma:**
```
ResourceConflictException: Function already exists
```

**Solución:**
Esto está bien. El script detectará la función existente y la actualizará automáticamente.

### 6. Error: IAM permissions denied

**Síntoma:**
```
User: arn:aws:iam::xxx is not authorized to perform: iam:CreateRole
```

**Solución:**
Tu usuario AWS necesita permisos de IAM. Opciones:

**Opción A:** Pedir a tu administrador AWS que agregue la política `IAMFullAccess`

**Opción B:** Crear el rol manualmente y solo usar el despliegue:
```bash
# Crear rol manualmente en AWS Console
# Luego agregar el ARN al .env:
LAMBDA_ROLE_ARN=arn:aws:iam::123456789012:role/tu-rol

# Desplegar solo Lambda (sin crear IAM)
docker run --rm \
  -v $(pwd):/workspace \
  -v /var/run/docker.sock:/var/run/docker.sock \
  gotenberg-deploy-tool:latest deploy-only
```

### 7. Error: Out of disk space

**Síntoma:**
```
no space left on device
```

**Solución:**
```bash
# Limpiar imágenes Docker antiguas
docker system prune -a

# Limpiar solo este proyecto
make clean
```

### 8. Error: Lambda timeout

**Síntoma:**
La función Lambda se ejecuta pero timeout después de 3 segundos.

**Solución:**
Aumenta el timeout en `.env`:
```bash
LAMBDA_TIMEOUT=600  # 10 minutos
```

Luego re-despliega:
```bash
make deploy
```

### 9. Error: Lambda out of memory

**Síntoma:**
```
Process exited before completing request
```

**Solución:**
Aumenta la memoria en `.env`:
```bash
LAMBDA_MEMORY_SIZE=4096  # 4 GB
```

### 10. Error: Environment parsing failed

**Síntoma:**
```
Error parsing parameter '--environment': Expected: '=', received: ','
```

**Causa:** Formato incorrecto del JSON de variables de entorno.

**Solución:** ✅ Ya está arreglado en la última versión. Reconstruye:
```bash
make clean
make deploy
```

### 11. Testing: Cómo probar si funciona

**Test local:**
```bash
make test-local

# En otra terminal:
curl -X POST http://localhost:3000/forms/chromium/convert/url \
  -u admin:tu-password \
  -F url=https://example.com \
  -o test.pdf

# Verifica que test.pdf se creó
ls -lh test.pdf
```

## Comandos Útiles de Debugging

### Ver logs de Lambda
```bash
make shell
# Dentro del contenedor:
aws logs tail /aws/lambda/gotenberg-pdf-service --follow
```

### Verificar función Lambda
```bash
make shell
# Dentro del contenedor:
aws lambda get-function --function-name gotenberg-pdf-service
```

### Ver imágenes en ECR
```bash
make shell
# Dentro del contenedor:
aws ecr describe-images --repository-name gotenberg-lambda
```

### Test manual de despliegue
```bash
make shell
# Ejecuta pasos manualmente:
/workspace/setup-iam.sh
/workspace/deploy.sh
```

## Obtener Ayuda

Si ninguna de estas soluciones funciona:

1. Ejecuta con modo verbose:
```bash
docker run --rm \
  -v $(pwd):/workspace \
  -v /var/run/docker.sock:/var/run/docker.sock \
  gotenberg-deploy-tool:latest shell

# Dentro del contenedor, ejecuta con debug:
set -x
/workspace/entrypoint.sh
```

2. Revisa los logs de Docker:
```bash
docker logs <container-id>
```

3. Verifica las credenciales AWS:
```bash
make shell
aws sts get-caller-identity
```

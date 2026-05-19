# GCP Classic VPN Recreate

Script reutilizable para recrear túneles de VPN Clásica en Google Cloud Platform, permitiendo agregar o modificar remote traffic selectors sin intervención manual en la consola.

## Problema

En GCP, las VPN Clásicas (policy-based) **no permiten modificar los traffic selectors** de un túnel existente. Para agregar un nuevo segmento de red remoto, es necesario:

1. Eliminar las rutas asociadas al túnel
2. Eliminar el túnel
3. Recrear el túnel con los nuevos traffic selectors
4. Recrear todas las rutas

Este proceso manual es propenso a errores y genera downtime innecesario si no se ejecuta correctamente.

## Solución

Un script bash parametrizado que automatiza todo el proceso de forma segura:

- Valida todos los parámetros antes de ejecutar
- Detecta y elimina rutas existentes automáticamente
- Recrea el túnel con los selectors indicados
- Crea N rutas dinámicamente según los segmentos proporcionados
- Verifica el estado del túnel post-recreación (hasta 2.5 minutos)
- Requiere confirmación explícita antes de destruir recursos

## Requisitos

- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install) (`gcloud`) instalado y autenticado
- Permisos en el proyecto:
  - `compute.vpnTunnels.create`
  - `compute.vpnTunnels.delete`
  - `compute.routes.create`
  - `compute.routes.delete`
- Acceso al PSK (Pre-Shared Key) del túnel VPN

## Instalación

```bash
git clone https://github.com/n3sl30n/gcp-classic-vpn-recreate.git
cd gcp-classic-vpn-recreate
chmod +x gcp-vpn-recreate.sh
```

## Uso

```bash
./gcp-vpn-recreate.sh \
  --project PROJECT_ID \
  --region REGION \
  --tunnel TUNNEL_NAME \
  --gateway GATEWAY_NAME \
  --network VPC_NETWORK \
  --peer-ip PEER_IP_ADDRESS \
  --ike-version IKE_VERSION \
  --local-selector LOCAL_CIDR \
  --remote-selectors "CIDR1,CIDR2,CIDR3" \
  --psk 'PRE_SHARED_KEY'
```

### Parámetros

| Parámetro | Descripción | Ejemplo |
|---|---|---|
| `--project` | ID del proyecto en GCP | `mi-proyecto-123` |
| `--region` | Región del túnel VPN | `us-central1` |
| `--tunnel` | Nombre del túnel VPN existente | `vpn1-tunnel-1` |
| `--gateway` | Nombre del Target VPN Gateway | `vpn-1` |
| `--network` | Nombre de la red VPC | `mi-vpc-network` |
| `--peer-ip` | IP pública del peer (on-premises) | `201.132.104.114` |
| `--ike-version` | Versión de IKE (1 o 2) | `2` |
| `--local-selector` | CIDR local (subred GCP) | `10.128.0.0/20` |
| `--remote-selectors` | CIDRs remotos separados por coma | `10.0.1.0/24,10.0.2.0/24` |
| `--psk` | Pre-Shared Key del túnel | `mi-clave-secreta` |

## Ejemplo real

Agregar el segmento `10.150.8.0/24` a una VPN existente que ya tiene 3 segmentos:

```bash
./gcp-vpn-recreate.sh \
  --project raloy-lubricantes \
  --region us-central1 \
  --tunnel vpn1-tunnel-1 \
  --gateway vpn-1 \
  --network raloy-servers-conections \
  --peer-ip 201.132.104.114 \
  --ike-version 2 \
  --local-selector 10.128.0.0/20 \
  --remote-selectors "10.150.4.0/24,10.150.80.0/24,10.150.31.0/24,10.150.8.0/24" \
  --psk 'mi-psk-aqui'
```

### Salida esperada

```
============================================
 Proyecto:          raloy-lubricantes
 Túnel:             vpn1-tunnel-1
 Gateway:           vpn-1
 Peer:              201.132.104.114
 Local selector:    10.128.0.0/20
 Remote selectors:  10.150.4.0/24 10.150.80.0/24 10.150.31.0/24 10.150.8.0/24
 Total segmentos:   4
============================================
¿Continuar? (SI/no): SI

=== Eliminando rutas existentes ===
  Rutas eliminadas

=== Eliminando túnel ===
  Túnel eliminado

=== Recreando túnel ===
  Túnel creado

=== Creando rutas ===
  route-1 (10.150.4.0/24) creada
  route-2 (10.150.80.0/24) creada
  route-3 (10.150.31.0/24) creada
  route-4 (10.150.8.0/24) creada

=== Validando regla de firewall ===
  Regla vpn1-tunnel-1-allow-onprem no existe, creando...
  Regla creada

=== Esperando establecimiento ===
  Intento 1/10 - Estado: FIRST_HANDSHAKE
  Intento 2/10 - Estado: ESTABLISHED
✅ Túnel ESTABLISHED
```

## Importante

### Antes de ejecutar

1. **Obtener el PSK**: GCP no permite leer el PSK de un túnel existente. Debes obtenerlo del equipo on-premises o de documentación interna.
2. **Listar segmentos actuales**: El parámetro `--remote-selectors` debe incluir **TODOS** los segmentos (existentes + nuevos). Para ver los actuales:
   ```bash
   gcloud compute vpn-tunnels describe TUNNEL_NAME \
     --region=REGION --project=PROJECT \
     --format="value(remoteTrafficSelector)"
   ```
3. **Coordinar con el peer**: El equipo que administra el router/firewall remoto debe agregar los nuevos segmentos en sus traffic selectors.

### Durante la ejecución

- **Habrá downtime** de 30-60 segundos mientras se reestablece el túnel.
- El script requiere confirmación explícita escribiendo `SI`.
- Si el túnel no se establece en 2.5 minutos, verifica la configuración del peer.

### Regla de firewall

El script valida automáticamente que exista una regla de firewall que permita **todo el tráfico** desde los segmentos remotos hacia las VMs en GCP:

- **Si la regla `{tunnel}-allow-onprem` ya existe**: actualiza los `source-ranges` con todos los segmentos remotos proporcionados.
- **Si no existe**: crea una nueva regla con `--rules=all` (todos los protocolos y puertos) desde los segmentos remotos.

Esto garantiza que las VMs en GCP puedan comunicarse bidireccionalmente con las VMs on-premises a través del túnel sin restricciones de firewall del lado de GCP.

### Qué NO se destruye

- El Target VPN Gateway (IP pública estática)
- Las Forwarding Rules (ESP, UDP 500, UDP 4500)
- La red VPC

Solo se destruye y recrea el **túnel** y sus **rutas**. La regla de firewall se crea o actualiza (nunca se elimina).

## Troubleshooting

| Estado | Causa | Solución |
|---|---|---|
| `ESTABLISHED` | Todo correcto | ✅ |
| `FIRST_HANDSHAKE` | Negociando con el peer | Esperar 1-2 minutos |
| `NO_INCOMING_PACKETS` | El peer no responde | Verificar configuración del peer y que los selectors coincidan |
| `AUTHORIZATION_ERROR` | PSK incorrecto | Verificar el PSK con el administrador del peer |

### Verificar estado manualmente

```bash
gcloud compute vpn-tunnels describe TUNNEL_NAME \
  --region=REGION --project=PROJECT \
  --format="yaml(name,status,detailedStatus,remoteTrafficSelector)"
```

## Notas sobre el PSK

El PSK puede contener caracteres especiales (`$`, `)`, `#`, `*`, etc.). Usa **comillas simples** para evitar que bash los interprete:

```bash
--psk 'M!c0mpl3x$P@ss#key'
```

Si el PSK contiene comillas simples (`'`), usa esta sintaxis:

```bash
--psk $'clave\'con\'comillas'
```

## Licencia

MIT

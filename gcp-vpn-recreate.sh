#!/bin/bash
set -euo pipefail

usage() {
  cat <<EOF
Uso: $0 --project PROJECT --region REGION --tunnel TUNNEL --gateway GATEWAY \\
         --network NETWORK --peer-ip PEER_IP --ike-version IKE_VER \\
         --local-selector LOCAL_CIDR --remote-selectors "CIDR1,CIDR2,..." \\
         --psk PSK

Recrea un túnel VPN clásica de GCP con los remote traffic selectors indicados.

Ejemplo:
  $0 --project raloy-lubricantes --region us-central1 --tunnel vpn1-tunnel-1 \\
     --gateway vpn-1 --network raloy-servers-conections \\
     --peer-ip 201.132.104.114 --ike-version 2 \\
     --local-selector 10.128.0.0/20 \\
     --remote-selectors "10.150.4.0/24,10.150.80.0/24,10.150.8.0/24" \\
     --psk "mi-shared-secret"
EOF
  exit 1
}

# Parse argumentos
while [[ $# -gt 0 ]]; do
  case $1 in
    --project) PROJECT="$2"; shift 2;;
    --region) REGION="$2"; shift 2;;
    --tunnel) TUNNEL="$2"; shift 2;;
    --gateway) GATEWAY="$2"; shift 2;;
    --network) NETWORK="$2"; shift 2;;
    --peer-ip) PEER_IP="$2"; shift 2;;
    --ike-version) IKE_VERSION="$2"; shift 2;;
    --local-selector) LOCAL_SELECTOR="$2"; shift 2;;
    --remote-selectors) REMOTE_SELECTORS="$2"; shift 2;;
    --psk) PSK="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "ERROR: Argumento desconocido: $1"; usage;;
  esac
done

# Validar parámetros requeridos
for var in PROJECT REGION TUNNEL GATEWAY NETWORK PEER_IP IKE_VERSION LOCAL_SELECTOR REMOTE_SELECTORS PSK; do
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Falta --$(echo $var | tr '[:upper:]' '[:lower:]' | tr '_' '-')"
    usage
  fi
done

# Convertir remote selectors a array
IFS=',' read -ra SEGMENTS <<< "$REMOTE_SELECTORS"

echo "============================================"
echo " Proyecto:          $PROJECT"
echo " Túnel:             $TUNNEL"
echo " Gateway:           $GATEWAY"
echo " Peer:              $PEER_IP"
echo " Local selector:    $LOCAL_SELECTOR"
echo " Remote selectors:  ${SEGMENTS[*]}"
echo " Total segmentos:   ${#SEGMENTS[@]}"
echo "============================================"
read -p "¿Continuar? (SI/no): " CONFIRM
[[ "$CONFIRM" == "SI" ]] || { echo "Cancelado."; exit 0; }

# Eliminar rutas existentes del túnel
echo ""
echo "=== Eliminando rutas existentes ==="
EXISTING_ROUTES=$(gcloud compute routes list --filter="nextHopVpnTunnel~$TUNNEL" --project="$PROJECT" --format="value(name)" 2>/dev/null)
if [[ -n "$EXISTING_ROUTES" ]]; then
  echo "$EXISTING_ROUTES" | xargs gcloud compute routes delete --project="$PROJECT" --quiet
  echo "  Rutas eliminadas"
else
  echo "  No hay rutas existentes"
fi

# Eliminar túnel
echo ""
echo "=== Eliminando túnel ==="
gcloud compute vpn-tunnels delete "$TUNNEL" --region="$REGION" --project="$PROJECT" --quiet 2>&1
echo "  Túnel eliminado"

# Recrear túnel
echo ""
echo "=== Recreando túnel ==="
gcloud compute vpn-tunnels create "$TUNNEL" \
  --region="$REGION" \
  --project="$PROJECT" \
  --peer-address="$PEER_IP" \
  --shared-secret="$PSK" \
  --ike-version="$IKE_VERSION" \
  --local-traffic-selector="$LOCAL_SELECTOR" \
  --remote-traffic-selector="$REMOTE_SELECTORS" \
  --target-vpn-gateway="$GATEWAY"
echo "  Túnel creado"

# Crear rutas
echo ""
echo "=== Creando rutas ==="
for i in "${!SEGMENTS[@]}"; do
  ROUTE_NUM=$((i + 1))
  gcloud compute routes create "${TUNNEL}-route-${ROUTE_NUM}" \
    --project="$PROJECT" \
    --network="$NETWORK" \
    --next-hop-vpn-tunnel="$TUNNEL" \
    --next-hop-vpn-tunnel-region="$REGION" \
    --destination-range="${SEGMENTS[$i]}" \
    --priority=1000 2>&1
  echo "  route-${ROUTE_NUM} (${SEGMENTS[$i]}) creada"
done

# Verificar
echo ""
echo "=== Esperando establecimiento ==="
for attempt in $(seq 1 10); do
  sleep 15
  STATUS=$(gcloud compute vpn-tunnels describe "$TUNNEL" --region="$REGION" --project="$PROJECT" --format="value(status)" 2>/dev/null)
  echo "  Intento $attempt/10 - Estado: $STATUS"
  if [[ "$STATUS" == "ESTABLISHED" ]]; then
    echo "✅ Túnel ESTABLISHED"
    exit 0
  fi
done

echo "⚠️  El túnel no se estableció en 2.5 minutos."
echo "   Verifica que el peer ($PEER_IP) tenga los mismos traffic selectors."

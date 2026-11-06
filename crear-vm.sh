#!/usr/bin/env bash
# Crea la VM "certiface-api" con la configuración exacta indicada.
# Funciona en Cloud Shell (reintenta sin fin) y en GitHub Actions
# (hace MAX_INTENTOS intentos por ejecución).

NAME="certiface-api"
SHAPE="VM.Standard.A1.Flex"
OCPUS=2
MEM=12
AD_SUFFIX="AD-3"
IMAGE_BUILD="2026.10.27-0"
VCN_NAME="vcn-saas"
SUBNET_NAME="subnet-public"
BOOT_GB=100
VPUS=10
ESPERA="${ESPERA:-60}"            # segundos entre intentos
MAX_INTENTOS="${MAX_INTENTOS:-0}"  # 0 = sin límite

resultado() {  # deja el resultado para GitHub Actions
  [[ -n "$GITHUB_OUTPUT" ]] && echo "resultado=$1" >> "$GITHUB_OUTPUT"
}

# --- Clave pública SSH ---
KEYFILE="$HOME/certiface.pub"
cat > "$KEYFILE" <<'KEY'
ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDdx9mDt+XoJ1DiPQA6WB2RYMo20Vi27fvPF/Anilvy6aTAd2j+03Dvz1ohFoarRvf6bVzUt2kFhJ4KqVKaoG1/EosjKQOILemnnsA9yseybC2RWS+BXxdbqc5J5WiXYDlqnTj0fA6rhRZAEZFZ+05eXZcAysowXVejdeRqkc+M2DzgDzr9wuu+tXC8mz/JvdjC1jmiTV03RvhfTyMooM18XDx57NHcZwYg4DeqFn1OVB3jYPtnYAiy78krAoQ5s/72N6IwoYUea7j9dtpKWs6PmD0DBTsnE29lB89In4LHQDuIKUX6IHmOUjTNg6K11IimcbR7hdFN5qc+zzU1vVxt ssh-key-2026-11-06
KEY

T="${OCI_TENANCY:?Falta OCI_TENANCY}"   # compartimento raíz

mostrar_ip() {
  local id="$1"
  echo "Esperando a que la VM esté RUNNING..."
  oci compute instance get --instance-id "$id" --wait-for-state RUNNING --max-wait-seconds 900 >/dev/null 2>&1
  IP=$(oci compute instance list-vnics --instance-id "$id" | jq -r '.data[0]."public-ip"')
  echo "=============================================="
  echo " VM '$NAME' lista. IP pública: $IP"
  echo " Conéctate: ssh -i <tu .key> ubuntu@$IP"
  echo "=============================================="
}

# --- Si ya existe, no crear otra ---
EXISTENTE=$(oci compute instance list -c "$T" --display-name "$NAME" --all \
  | jq -r '[.data[]? | select(."lifecycle-state" != "TERMINATED" and ."lifecycle-state" != "TERMINATING")][0].id // empty')
if [[ -n "$EXISTENTE" ]]; then
  echo "Ya existe una instancia '$NAME' activa. No creo otra."
  mostrar_ip "$EXISTENTE"
  resultado creada; exit 0
fi

AD=$(oci iam availability-domain list -c "$T" | jq -r --arg s "$AD_SUFFIX" '.data[] | select(.name | endswith($s)) | .name')
VCN=$(oci network vcn list -c "$T" --all | jq -r --arg n "$VCN_NAME" '[.data[] | select(."display-name"==$n)][0].id')
SUBNET=$(oci network subnet list -c "$T" --vcn-id "$VCN" --all \
  | jq -r --arg n "$SUBNET_NAME" '[.data[] | select(."display-name"==$n)][0].id')
IMAGE=$(oci compute image list -c "$T" --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" --shape "$SHAPE" --all \
  | jq -r --arg b "$IMAGE_BUILD" '[.data[] | select((."display-name" | test("aarch64")) and (."display-name" | endswith($b)) and (."display-name" | test("Minimal") | not))][0].id')
IMAGE_NAME=$(oci compute image get --image-id "$IMAGE" 2>/dev/null | jq -r '.data."display-name"')

echo "AD:      $AD"
echo "VCN:     $VCN"
echo "Subred:  $SUBNET"
echo "Imagen:  $IMAGE_NAME"
for v in AD VCN SUBNET IMAGE; do
  [[ -z "${!v}" || "${!v}" == null ]] && { echo "No encontré $v. Revisa los nombres al inicio del script."; resultado error; exit 1; }
done

SOURCE=$(jq -nc --arg i "$IMAGE" --argjson s "$BOOT_GB" --argjson v "$VPUS" \
  '{sourceType:"image", imageId:$i, bootVolumeSizeInGBs:$s, bootVolumeVpusPerGB:$v}')
SHAPE_CFG=$(jq -nc --argjson o "$OCPUS" --argjson m "$MEM" '{ocpus:$o, memoryInGBs:$m}')
AGENT_CFG='{
  "isMonitoringDisabled": false,
  "isManagementDisabled": false,
  "areAllPluginsDisabled": false,
  "pluginsConfig": [
    {"name":"Vulnerability Scanning","desiredState":"DISABLED"},
    {"name":"OS Management Hub Agent","desiredState":"DISABLED"},
    {"name":"Management Agent","desiredState":"DISABLED"},
    {"name":"Custom Logs Monitoring","desiredState":"ENABLED"},
    {"name":"Compute RDMA GPU Monitoring","desiredState":"DISABLED"},
    {"name":"Compute Instance Run Command","desiredState":"ENABLED"},
    {"name":"Compute Instance Monitoring","desiredState":"ENABLED"},
    {"name":"Compute HPC RDMA Auto-Configuration","desiredState":"DISABLED"},
    {"name":"Compute HPC RDMA Authentication","desiredState":"DISABLED"},
    {"name":"Cloud Guard Workload Protection","desiredState":"ENABLED"},
    {"name":"Block Volume Management","desiredState":"DISABLED"},
    {"name":"Bastion","desiredState":"DISABLED"}
  ]
}'
AVAIL_CFG='{"recoveryAction":"RESTORE_INSTANCE"}'
INST_OPTS='{"areLegacyImdsEndpointsDisabled":true}'

intento=0
while true; do
  intento=$((intento+1))
  echo "[$(date +%H:%M:%S)] Intento $intento en $AD..."
  out=$(oci compute instance launch -c "$T" \
    --availability-domain "$AD" \
    --display-name "$NAME" \
    --shape "$SHAPE" --shape-config "$SHAPE_CFG" \
    --source-details "$SOURCE" \
    --subnet-id "$SUBNET" --assign-public-ip true \
    --assign-private-dns-record true --hostname-label "$NAME" \
    --ssh-authorized-keys-file "$KEYFILE" \
    --agent-config "$AGENT_CFG" \
    --availability-config "$AVAIL_CFG" \
    --instance-options "$INST_OPTS" \
    --is-pv-encryption-in-transit-enabled true 2>&1)

  if grep -q '"lifecycle-state"' <<<"$out"; then
    echo "¡VM '$NAME' creada en $AD!"
    ID=$(sed -n '/^{/,$p' <<<"$out" | jq -r '.data.id')
    mostrar_ip "$ID"
    resultado creada; exit 0
  elif grep -qiE "out of (host )?capacity|OutOfHostCapacity" <<<"$out"; then
    echo "  Sin capacidad."
  elif grep -qiE "TooManyRequests" <<<"$out"; then
    echo "  Demasiadas solicitudes, espero más."; sleep 120
  elif grep -qiE "InternalError|ServiceUnavailable|timed out|Connection" <<<"$out"; then
    echo "  Error temporal de Oracle, reintento."
  else
    echo "  Error distinto, me detengo:"; echo "$out"; resultado error; exit 1
  fi

  if (( MAX_INTENTOS > 0 && intento >= MAX_INTENTOS )); then
    echo "Sin capacidad en esta ronda; la próxima ejecución lo vuelve a intentar."
    resultado sin_capacidad; exit 0
  fi
  sleep "$ESPERA"
done

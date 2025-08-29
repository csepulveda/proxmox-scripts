#!/usr/bin/env bash
set -euo pipefail

##### === EDITA ESTAS VARIABLES PARA CADA VM ===
VMID="${VMID:-8100}"                           # ID de la VM
VMNAME="${VMNAME:-node01}"                     # Nombre de la VM
ISCSI_STORE="${ISCSI_STORE:-truenas-node01}"   # Storage iSCSI en Proxmox (define portal/iqn)
LUN="${LUN:-0}"                                # LUN raíz (zvol en TrueNAS)

CLOUD_IMG="${CLOUD_IMG:-/mnt/pve/images/template/iso/noble-server-cloudimg-amd64.img}"

RAM_MB="${RAM_MB:-4096}"
CPU_SOCKETS="${CPU_SOCKETS:-1}"
CPU_CORES="${CPU_CORES:-4}"
BRIDGE="${BRIDGE:-vmbr0}"

# Red (cloud-init)
IPADDR="${IPADDR:-192.168.100.50/24}"          # IP/máscara: 192.168.100.50/24
GATEWAY="${GATEWAY:-192.168.100.1}"
DNS="${DNS:-192.168.100.1}"

# Usuario/credenciales (cloud-init)
CIUSER="${CIUSER:-cesar}"
CIPASSWORD="${CIPASSWORD:-supersecret}"        # si usas solo clave, puedes dejarlo pero no se usará
SSHKEY_PATH="${SSHKEY_PATH:-}"                 # ej: /root/.ssh/id_ed25519.pub (opcional)
##### ==========================================

echo "==> VMID=${VMID} VMNAME=${VMNAME} ISCSI_STORE=${ISCSI_STORE} LUN=${LUN}"
[[ -r /etc/pve/storage.cfg ]] || { echo "No existe /etc/pve/storage.cfg"; exit 1; }
[[ -f "${CLOUD_IMG}" ]] || { echo "No existe CLOUD_IMG: ${CLOUD_IMG}"; exit 1; }

# --- 1) Resolver portal y target del storage iSCSI ---
PORTAL="$(awk -v s="$ISCSI_STORE" '
  ($1=="iscsi:" && $2==s) {f=1; next}
  f && $1=="portal" {print $2; exit}
  f && $1 ~ /:$/   {f=0}
' /etc/pve/storage.cfg)"

TARGET="$(awk -v s="$ISCSI_STORE" '
  ($1=="iscsi:" && $2==s) {f=1; next}
  f && $1=="target" {print $2; exit}
  f && $1 ~ /:$/   {f=0}
' /etc/pve/storage.cfg)"

if [[ -z "${PORTAL}" || -z "${TARGET}" ]]; then
  echo "No pude resolver portal/target para '${ISCSI_STORE}' en /etc/pve/storage.cfg"
  exit 1
fi
echo "==> PORTAL=${PORTAL} TARGET=${TARGET}"

# --- 2) Helpers: obtener RUTA PERSISTENTE by-path (NO /dev/sdX), y opcional mapper ---
get_lun_by_path() {
  local lun="$1"
  local bypath_3260="/dev/disk/by-path/ip-${PORTAL}:3260-iscsi-${TARGET}-lun-${lun}"
  local bypath_nop="/dev/disk/by-path/ip-${PORTAL}-iscsi-${TARGET}-lun-${lun}"
  if [[ -e "$bypath_3260" ]]; then echo "$bypath_3260"; return 0; fi
  if [[ -e "$bypath_nop" ]]; then echo "$bypath_nop"; return 0; fi
  return 1
}
get_mapper_name() {
  local dev="$1"; local real base
  real="$(readlink -f "$dev")" || real="$dev"
  base="$(basename "$real")"
  if [[ -r "/sys/block/${base}/dm/name" ]]; then
    echo "/dev/mapper/$(cat "/sys/block/${base}/dm/name")"
  else
    echo "$dev"   # devolvemos el by-path original si no hay multipath
  fi
}

# --- 3) Asegurar sesión iSCSI y localizar la LUN por by-path ---
BYPATH="$(get_lun_by_path "${LUN}")" || {
  echo "==> LUN ${LUN} no visible; discovery/login iSCSI…"
  iscsiadm -m discovery -t sendtargets -p "${PORTAL}" || true
  iscsiadm -m node -T "${TARGET}" -p "${PORTAL}:3260" -l || true
  sleep 2
  BYPATH="$(get_lun_by_path "${LUN}")" || {
    echo "No aparece LUN ${LUN}. Revisa export y ACLs en TrueNAS."
    ls -l /dev/disk/by-path/ | grep -E "${TARGET}.*lun-${LUN}" || true
    exit 1
  }
}
REAL_DEV="$(readlink -f "${BYPATH}")"
ATTACH_DEV="$(get_mapper_name "${BYPATH}")"   # preferimos /dev/mapper si existe; si no, dejamos BYPATH

echo "==> LUN${LUN} by-path: ${BYPATH}"
echo "==> LUN${LUN} real:    ${REAL_DEV}"
echo "==> LUN${LUN} attach:  ${ATTACH_DEV}"

# Guardas: NO permitir /dev/sdX directo (evita sorpresas al reiniciar)
if [[ "${ATTACH_DEV}" =~ ^/dev/sd[a-z]+$ ]]; then
  echo "ERROR: se intentó usar ${ATTACH_DEV}. Adjunta SIEMPRE by-path o /dev/mapper. Abortando."
  exit 1
fi

# Evitar CRUZAR LUNs: si BYPATH ya está en alguna VM (distinta de la actual), aborta
for cfg in /etc/pve/qemu-server/*.conf; do
  [[ -e "$cfg" ]] || continue
  if grep -q --fixed-strings "${BYPATH}" "$cfg" || grep -q --fixed-strings "${ATTACH_DEV}" "$cfg"; then
    if ! grep -q "qm${VMID}\.conf" <<<"$cfg"; then
      echo "ERROR: El disco ${BYPATH} (${ATTACH_DEV}) ya está referenciado por ${cfg}. Aborto para evitar cruce."
      exit 1
    fi
  fi
done

# --- 4) Volcar cloud-image a la LUN (RAW) usando RUTA PERSISTENTE ---
echo "==> qemu-img info ${CLOUD_IMG}"
qemu-img info "${CLOUD_IMG}" || true

# Asegura que no está montado (revisamos real device y mapper si aplica)
if mount | grep -q " on ${REAL_DEV} "; then echo "ERROR: ${REAL_DEV} está montado."; exit 1; fi
if [[ "${ATTACH_DEV}" != "${BYPATH}" && "${ATTACH_DEV}" != "${REAL_DEV}" ]]; then
  if mount | grep -q " on ${ATTACH_DEV} "; then echo "ERROR: ${ATTACH_DEV} está montado."; exit 1; fi
fi

echo "==> Volcando cloud-image -> ${BYPATH} (RAW)…"
qemu-img convert -p -O raw "${CLOUD_IMG}" "${BYPATH}"
sync
echo "==> Volcado OK."

# --- 5) Crear o reutilizar VM ---
if qm status "${VMID}" >/dev/null 2>&1; then
  echo "==> VM ${VMID} existe; reutilizando…"
  qm stop "${VMID}" >/dev/null 2>&1 || true
  for disk in scsi0 virtio0 ide2 efidisk0 sata0; do
    qm set "${VMID}" --delete "${disk}" >/dev/null 2>&1 || true
  done
  qm set "${VMID}" --name "${VMNAME}" \
    --memory "${RAM_MB}" \
    --cpu host --sockets "${CPU_SOCKETS}" --cores "${CPU_CORES}" \
    --net0 "virtio,bridge=${BRIDGE}" \
    --vga serial0 --serial0 socket
else
  echo "==> Creando VM ${VMID}…"
  qm create "${VMID}" --name "${VMNAME}" --ostype l26 \
    --memory "${RAM_MB}" \
    --agent 1 \
    --bios seabios --machine q35 \
    --cpu host --sockets "${CPU_SOCKETS}" --cores "${CPU_CORES}" \
    --vga serial0 --serial0 socket \
    --net0 "virtio,bridge=${BRIDGE}"
fi

# Disco raíz con RUTA PERSISTENTE (NO /dev/sdX)
qm set "${VMID}" --virtio0 "${ATTACH_DEV},discard=on,cache=writeback,format=raw"

# --- 6) Cloud-init: solo USER y META ---
mkdir -p /var/lib/vz/snippets

cat > /var/lib/vz/snippets/user-${VMID}.yaml <<EOF
#cloud-config
ssh_pwauth: true

users:
  - name: ${CIUSER}
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    shell: /bin/bash
$( [[ -n "${SSHKEY_PATH}" && -f "${SSHKEY_PATH}" ]] && { echo "    ssh_authorized_keys:"; echo "      - $(cat "${SSHKEY_PATH}")"; } )

chpasswd:
  expire: false
  list: |
    ${CIUSER}:${CIPASSWORD}

package_update: true
packages:
  - qemu-guest-agent
  - htop
  - nload
  - iftop
  - vim

runcmd:
  - systemctl enable --now qemu-guest-agent
EOF

cat > /var/lib/vz/snippets/meta-${VMID}.yaml <<EOF
instance-id: iid-vm-${VMID}-$(date +%s)
local-hostname: ${VMNAME}
EOF

# Disco cloud-init (en storage que soporte images; aquí local-lvm)
qm set "${VMID}" --ide2 local-lvm:cloudinit

# Asignar cicustom (user+meta)
qm set "${VMID}" --cicustom "user=local:snippets/user-${VMID}.yaml,meta=local:snippets/meta-${VMID}.yaml"

# IP estática y DNS
qm set "${VMID}" --ipconfig0 "ip=${IPADDR},gw=${GATEWAY}" --nameserver "${DNS}"

# (Opcional) además pasa la clave por --sshkey si definiste SSHKEY_PATH
if [[ -n "${SSHKEY_PATH}" && -f "${SSHKEY_PATH}" ]]; then
  qm set "${VMID}" --sshkey "${SSHKEY_PATH}"
fi

# --- 7) Boot y arranque ---
qm set "${VMID}" --boot order=virtio0
qm cloudinit update "${VMID}"
qm stop "${VMID}" >/dev/null 2>&1 || true
qm start "${VMID}"

echo "==> Listo: VM ${VMID} (${VMNAME}) con root en ${ATTACH_DEV} (by-path: ${BYPATH}), IP ${IPADDR}, GW ${GATEWAY}, DNS ${DNS}"
echo "    Recuerda: usa SIEMPRE by-path o /dev/mapper. Revisa 'qm config ${VMID}' y verifica que no haya /dev/sdX."

#!/usr/bin/env bash
set -euo pipefail

##### === EDITA ESTAS VARIABLES PARA CADA VM ===
VMID="${VMID:-8100}"                           # ID de la VM
VMNAME="${VMNAME:-node01}"                     # Nombre de la VM
ISCSI_STORE="${ISCSI_STORE:-truenas-node01}"   # Storage iSCSI en Proxmox
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

# --- 2) Helpers: by-path y mapper ---
get_lun_device() {
  local lun="$1"
  local bypath_3260="/dev/disk/by-path/ip-${PORTAL}:3260-iscsi-${TARGET}-lun-${lun}"
  local bypath_nop="/dev/disk/by-path/ip-${PORTAL}-iscsi-${TARGET}-lun-${lun}"
  if [[ -e "$bypath_3260" ]]; then readlink -f "$bypath_3260"; return 0; fi
  if [[ -e "$bypath_nop" ]]; then readlink -f "$bypath_nop"; return 0; fi
  return 1
}
get_mapper_name() {
  local dev="$1"; local base; base="$(basename "$dev")"
  if [[ -r "/sys/block/${base}/dm/name" ]]; then
    echo "/dev/mapper/$(cat "/sys/block/${base}/dm/name")"
  else
    echo "$dev"
  fi
}

# --- 3) Asegurar sesión iSCSI y localizar la LUN ---
if ! DEV_REAL="$(get_lun_device "${LUN}")"; then
  echo "==> LUN ${LUN} no visible; discovery/login iSCSI…"
  iscsiadm -m discovery -t sendtargets -p "${PORTAL}" || true
  iscsiadm -m node -T "${TARGET}" -p "${PORTAL}:3260" -l || true
  sleep 2
  DEV_REAL="$(get_lun_device "${LUN}")" || {
    echo "No aparece LUN ${LUN}. Revisa export y ACLs en TrueNAS."
    ls -l /dev/disk/by-path/ | grep -E "${TARGET}.*lun-${LUN}" || true
    exit 1
  }
fi
DEV_MAPPER="$(get_mapper_name "$DEV_REAL")"
echo "==> LUN${LUN} real:   ${DEV_REAL}"
echo "==> LUN${LUN} mapper: ${DEV_MAPPER}"

# --- 4) Volcar cloud-image a la LUN (RAW) ---
echo "==> qemu-img info ${CLOUD_IMG}"
qemu-img info "${CLOUD_IMG}" || true
if mount | grep -q " on ${DEV_MAPPER} "; then
  echo "ERROR: ${DEV_MAPPER} está montado."; exit 1
fi
echo "==> Volcando cloud-image -> ${DEV_MAPPER} (RAW)…"
qemu-img convert -p -O raw "${CLOUD_IMG}" "${DEV_MAPPER}"
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

# Disco raíz por ruta de dispositivo (evita alloc en backend iSCSI)
qm set "${VMID}" --virtio0 "${DEV_MAPPER},discard=on,cache=writeback,format=raw"

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

# Usuario/clave, red estática y DNS
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

echo "==> Listo: VM ${VMID} (${VMNAME}) con root en ${DEV_MAPPER}, IP ${IPADDR}, GW ${GATEWAY}, DNS ${DNS}"
echo "    Verifica cloud-init con: 'cloud-init status --long' y 'journalctl -u cloud-init -n 200' dentro de la VM."
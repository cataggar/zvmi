#!/usr/bin/env bash
set -euo pipefail

command_name=${1:-run}
if [[ -z ${STATE_FILE:-} || -z ${GITHUB_RUN_ID:-} || -z ${GITHUB_RUN_ATTEMPT:-} || -z ${CANDIDATE_KEY:-} ]]; then
  echo "::error::Azure cleanup identity is incomplete"
  exit 1
fi
[[ "$GITHUB_RUN_ID" =~ ^[0-9]+$ ]]
[[ "$GITHUB_RUN_ATTEMPT" =~ ^[0-9]+$ ]]
[[ "$CANDIDATE_KEY" =~ ^(x86_64|aarch64)-(full|core)$ ]]

cleanup_group() {
  [[ -s "$STATE_FILE" ]] || return 0
  command -v az >/dev/null || {
    echo "::error::Azure CLI is unavailable during cleanup"
    return 1
  }
  local resource_group metadata_file group_exists expected_resource_group suffix
  resource_group=$(<"$STATE_FILE")
  suffix=${CANDIDATE_KEY//_/-}
  expected_resource_group="zvmi-al4-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${suffix}"
  [[ "$resource_group" == "$expected_resource_group" ]] || {
    echo "::error::Refusing cleanup of unexpected resource-group name"
    return 1
  }
  if ! group_exists=$(az group exists --name "$resource_group" --output tsv); then
    echo "::error::Could not determine whether the temporary resource group exists"
    return 1
  fi
  case "$group_exists" in
    false) return 0 ;;
    true) ;;
    *)
      echo "::error::Azure returned an invalid resource-group existence result"
      return 1
      ;;
  esac
  metadata_file="${STATE_FILE}.group.json"
  if ! az group show --name "$resource_group" --output json >"$metadata_file"; then
    echo "::error::Could not inspect temporary resource-group ownership"
    return 1
  fi
  if ! python3 - "$metadata_file" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$CANDIDATE_KEY" <<'PY'
import json
import sys

tags = json.load(open(sys.argv[1], encoding="utf-8")).get("tags") or {}
expected = {
    "zvmi-owner": "azurelinux4-release",
    "zvmi-run-id": sys.argv[2],
    "zvmi-run-attempt": sys.argv[3],
    "zvmi-candidate": sys.argv[4],
}
if tags != expected:
    raise SystemExit(f"refusing to delete resource group with non-exact ownership tags: {tags!r}")
PY
  then
    return 1
  fi
  if ! az group delete --name "$resource_group" --yes; then
    echo "::error::Failed to delete owned temporary resource group"
    return 1
  fi
}

if [[ "$command_name" == cleanup ]]; then
  cleanup_group
  exit
fi
if [[ "$command_name" != run ]]; then
  echo "usage: $0 run|cleanup" >&2
  exit 2
fi

if [[ -z ${CANDIDATE_DIR:-} || -z ${SOURCE_COMMIT:-} || -z ${ARCHITECTURE:-} ||
      -z ${FLAVOR:-} || -z ${ASSET_NAME:-} || -z ${AZURE_LOCATION:-} ||
      -z ${AZURE_VM_SIZE:-} || -z ${RESULT_DIR:-} || -z ${ZVMI:-} ||
      -z ${GITHUB_STEP_SUMMARY:-} ]]; then
  echo "::error::Azure acceptance configuration is incomplete"
  exit 1
fi
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]]
[[ "$ARCHITECTURE" =~ ^(x86_64|aarch64)$ ]]
[[ "$FLAVOR" =~ ^(full|core)$ ]]
[[ "$CANDIDATE_KEY" == "$ARCHITECTURE-$FLAVOR" ]]
[[ "$AZURE_LOCATION" =~ ^[a-z0-9-]+$ ]]
[[ "$AZURE_VM_SIZE" =~ ^Standard_[A-Za-z0-9_]+$ ]]
[[ -x "$ZVMI" ]]

for tool in az azcopy python3 qemu-img sha256sum ssh ssh-keygen; do
  command -v "$tool" >/dev/null || {
    echo "::error::Required Azure acceptance tool $tool is unavailable"
    exit 1
  }
done

mkdir -p "$RESULT_DIR"
manifest="$CANDIDATE_DIR/candidate.json"
asset="$CANDIDATE_DIR/$ASSET_NAME"
readarray -t candidate < <(
  python3 scripts/azurelinux4_release.py verify-candidate \
    --manifest "$manifest" \
    --asset "$asset" \
    --key "$CANDIDATE_KEY" \
    --source-commit "$SOURCE_COMMIT"
)
test "${#candidate[@]}" -eq 3
qcow_sha256=${candidate[0]}
qcow_bytes=${candidate[1]}
virtual_size=${candidate[2]}
[[ "$qcow_sha256" =~ ^[0-9a-f]{64}$ ]]
[[ "$qcow_bytes" =~ ^[0-9]+$ ]]
[[ "$virtual_size" =~ ^[0-9]+$ ]]

suffix=${CANDIDATE_KEY//_/-}
resource_group="zvmi-al4-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}-${suffix}"
short_arch=${ARCHITECTURE/x86_64/x64}
name_seed="${GITHUB_RUN_ID}${GITHUB_RUN_ATTEMPT}${short_arch}${FLAVOR}"
disk_name="zvmi-os-${name_seed}"
data_disk_name="zvmi-data-${name_seed}"
gallery_name="zvmial4${name_seed}"
image_name="zvmial4${short_arch}${FLAVOR}"
vm_name="zvmi-vm-${name_seed}"
admin_username=zvmitest
vhd="$RESULT_DIR/${CANDIDATE_KEY}.vhd"
private_key="$RESULT_DIR/id_ed25519"
boot_log="$RESULT_DIR/boot.log"
sku_json="$RESULT_DIR/sku.json"
mkdir -p "$(dirname -- "$STATE_FILE")"
rm -f -- "$STATE_FILE" "${STATE_FILE}.group.json" "$vhd" "$private_key" "$private_key.pub"

cleanup_on_exit() {
  status=$?
  trap - EXIT INT TERM
  rm -f -- "$vhd" "$private_key" "$private_key.pub"
  if ! cleanup_group; then
    status=1
  fi
  exit "$status"
}
trap cleanup_on_exit EXIT
trap 'exit 130' INT TERM

if ! group_exists=$(az group exists --name "$resource_group" --output tsv); then
  echo "::error::Could not check for a resource-group collision"
  exit 1
fi
case "$group_exists" in
  true)
    echo "::error::Collision-resistant resource group already exists: $resource_group"
    exit 1
    ;;
  false) ;;
  *)
    echo "::error::Azure returned an invalid resource-group existence result"
    exit 1
    ;;
esac
printf '%s\n' "$resource_group" >"$STATE_FILE"
if ! az group create \
  --name "$resource_group" \
  --location "$AZURE_LOCATION" \
  --tags \
    zvmi-owner=azurelinux4-release \
    "zvmi-run-id=$GITHUB_RUN_ID" \
    "zvmi-run-attempt=$GITHUB_RUN_ATTEMPT" \
    "zvmi-candidate=$CANDIDATE_KEY" \
  --output none
then
  echo "::error::Failed to create the persisted temporary resource group"
  exit 1
fi

az vm list-skus \
  --location "$AZURE_LOCATION" \
  --resource-type virtualMachines \
  --size "$AZURE_VM_SIZE" \
  --all \
  --output json >"$sku_json"
expected_azure_architecture=x64
runtime_architecture=x86_64
azure_image_architecture=x64
if [[ "$ARCHITECTURE" == aarch64 ]]; then
  expected_azure_architecture=Arm64
  runtime_architecture=aarch64
  azure_image_architecture=Arm64
fi
python3 - "$sku_json" "$AZURE_VM_SIZE" "$expected_azure_architecture" <<'PY'
import json
import sys

matches = [item for item in json.load(open(sys.argv[1], encoding="utf-8")) if item["name"] == sys.argv[2]]
if len(matches) != 1:
    raise SystemExit("configured Azure VM SKU is absent or ambiguous in the configured location")
sku = matches[0]
if sku.get("restrictions"):
    raise SystemExit(f"configured Azure VM SKU is restricted: {sku['restrictions']!r}")
capabilities = {item["name"]: item["value"] for item in sku.get("capabilities", [])}
if capabilities.get("CpuArchitectureType") != sys.argv[3]:
    raise SystemExit(f"SKU architecture mismatch: {capabilities.get('CpuArchitectureType')!r}")
if "V2" not in capabilities.get("HyperVGenerations", "").split(","):
    raise SystemExit("configured Azure VM SKU does not support Gen2")
if int(capabilities.get("MaxResourceVolumeMB", "0")) <= 0:
    raise SystemExit("configured Azure VM SKU has no temporary resource disk")
PY

source_before=$(sha256sum "$asset" | awk '{print $1}')
test "$source_before" = "$qcow_sha256"
"$ZVMI" azure derive \
  --input-sha256 "$qcow_sha256" \
  --expected-virtual-size "$virtual_size" \
  "$asset" \
  "$vhd"
test "$(sha256sum "$asset" | awk '{print $1}')" = "$qcow_sha256"
qemu-img check -f vpc "$vhd"
qemu-img info --output=json "$vhd" >"$RESULT_DIR/vhd-info.json"
readarray -t vhd_geometry < <(
  python3 scripts/azurelinux4_release.py verify-vhd \
    --info "$RESULT_DIR/vhd-info.json" \
    --vhd "$vhd"
)
test "${#vhd_geometry[@]}" -eq 2
vhd_virtual_size=${vhd_geometry[0]}
vhd_bytes=${vhd_geometry[1]}
expected_vhd_virtual_size=$(((virtual_size + 1048575) / 1048576 * 1048576))
test "$vhd_virtual_size" -eq "$expected_vhd_virtual_size"
vhd_sha256=$(sha256sum "$vhd" | awk '{print $1}')
[[ "$vhd_sha256" =~ ^[0-9a-f]{64}$ ]]

az disk create \
  --resource-group "$resource_group" \
  --name "$disk_name" \
  --location "$AZURE_LOCATION" \
  --sku Standard_LRS \
  --upload-type Upload \
  --upload-size-bytes "$vhd_bytes" \
  --os-type Linux \
  --hyper-v-generation V2 \
  --architecture "$azure_image_architecture"
upload_sas=$(az disk grant-access \
  --resource-group "$resource_group" \
  --name "$disk_name" \
  --access-level Write \
  --duration-in-seconds 7200 \
  --query accessSas \
  --output tsv)
[[ "$upload_sas" == https://* ]]
echo "::add-mask::$upload_sas"
azcopy copy "$vhd" "$upload_sas" --blob-type PageBlob
az disk revoke-access --resource-group "$resource_group" --name "$disk_name"
upload_sas=

expanded_size_gib=$(((virtual_size + 1073741823) / 1073741824 + 2))
az disk update \
  --resource-group "$resource_group" \
  --name "$disk_name" \
  --size-gb "$expanded_size_gib"
disk_id=$(az disk show \
  --resource-group "$resource_group" \
  --name "$disk_name" \
  --query id \
  --output tsv)
[[ "$disk_id" == /subscriptions/* ]]

az sig create \
  --resource-group "$resource_group" \
  --gallery-name "$gallery_name" \
  --location "$AZURE_LOCATION"
az sig image-definition create \
  --resource-group "$resource_group" \
  --gallery-name "$gallery_name" \
  --gallery-image-definition "$image_name" \
  --publisher zvmi \
  --offer azurelinux4 \
  --sku "${short_arch}-${FLAVOR}" \
  --os-type Linux \
  --os-state Generalized \
  --hyper-v-generation V2 \
  --architecture "$azure_image_architecture" \
  --location "$AZURE_LOCATION"
image_version_id=$(az sig image-version create \
  --resource-group "$resource_group" \
  --gallery-name "$gallery_name" \
  --gallery-image-definition "$image_name" \
  --gallery-image-version 1.0.0 \
  --os-snapshot "$disk_id" \
  --replication-mode Shallow \
  --storage-account-type Standard_LRS \
  --location "$AZURE_LOCATION" \
  --query id \
  --output tsv)
[[ "$image_version_id" == /subscriptions/* ]]

ssh-keygen -q -t ed25519 -N '' -C zvmi-azure-acceptance -f "$private_key"
az vm create \
  --resource-group "$resource_group" \
  --name "$vm_name" \
  --location "$AZURE_LOCATION" \
  --size "$AZURE_VM_SIZE" \
  --image "$image_version_id" \
  --admin-username "$admin_username" \
  --authentication-type ssh \
  --ssh-key-values "$private_key.pub" \
  --enable-agent true \
  --enable-auto-update false \
  --security-type Standard \
  --public-ip-sku Standard \
  --nsg-rule SSH \
  --boot-diagnostics-storage ""
public_ip=$(az vm show \
  --resource-group "$resource_group" \
  --name "$vm_name" \
  --show-details \
  --query publicIps \
  --output tsv)
[[ "$public_ip" =~ ^[0-9a-fA-F:.]+$ ]]
test "$(az vm get-instance-view \
  --resource-group "$resource_group" \
  --name "$vm_name" \
  --query "instanceView.statuses[?code=='ProvisioningState/succeeded'].code | [0]" \
  --output tsv)" = ProvisioningState/succeeded

ssh_options=(
  -i "$private_key"
  -o BatchMode=yes
  -o ConnectTimeout=5
  -o ConnectionAttempts=1
  -o IdentitiesOnly=yes
  -o KbdInteractiveAuthentication=no
  -o PasswordAuthentication=no
  -o NumberOfPasswordPrompts=0
  -o PreferredAuthentications=publickey
  -o StrictHostKeyChecking=no
  -o UserKnownHostsFile=/dev/null
)
ssh_target="$admin_username@$public_ip"

wait_for_ssh() {
  for _ in {1..180}; do
    if ssh "${ssh_options[@]}" "$ssh_target" true >/dev/null 2>&1; then
      return
    fi
    sleep 5
  done
  echo "::error::Timed out waiting for key-only SSH"
  return 1
}

reboot_and_reconnect() {
  local old_boot_id=$1
  ssh "${ssh_options[@]}" "$ssh_target" 'sudo -n /sbin/reboot' >/dev/null 2>&1 || true
  local saw_disconnect=false boot_id
  for _ in {1..180}; do
    boot_id=$(ssh "${ssh_options[@]}" "$ssh_target" \
      'cat /proc/sys/kernel/random/boot_id' 2>/dev/null || true)
    if [[ -z "$boot_id" ]]; then
      saw_disconnect=true
    elif [[ "$saw_disconnect" == true && "$boot_id" != "$old_boot_id" ]]; then
      return
    fi
    sleep 5
  done
  echo "::error::Guest did not disconnect, reboot, and reconnect"
  return 1
}

wait_for_ssh
if ssh \
  -o BatchMode=yes \
  -o ConnectTimeout=5 \
  -o PreferredAuthentications=none \
  -o PubkeyAuthentication=no \
  -o PasswordAuthentication=no \
  -o KbdInteractiveAuthentication=no \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  "$ssh_target" true >/dev/null 2>&1; then
  echo "::error::SSH unexpectedly accepted a connection without the generated key"
  exit 1
fi

ssh "${ssh_options[@]}" "$ssh_target" \
  "/usr/bin/bash -s -- '$virtual_size' '$runtime_architecture' '$ARCHITECTURE'" <<'GUEST'
set -euo pipefail
original_size=$1
runtime_arch=$2
release_arch=$3
test "$(id -un)" = zvmitest
test "$(uname -m)" = "$runtime_arch"
sudo -n /usr/sbin/sshd -T | grep -Fxq 'passwordauthentication no'
sudo -n /usr/sbin/sshd -T | grep -Fxq 'kbdinteractiveauthentication no'
case "$release_arch" in
  x86_64) grep -Fwq 'console=ttyS0,115200n8' /proc/cmdline ;;
  aarch64) grep -Fwq 'console=ttyAMA0,115200n8' /proc/cmdline ;;
esac
root_source=$(findmnt -n -o SOURCE /)
root_device=$(readlink -f "$root_source")
root_disk_name=$(lsblk -n -o PKNAME "$root_device")
test -n "$root_disk_name"
disk_size=$(sudo -n blockdev --getsize64 "/dev/$root_disk_name")
root_size=$(sudo -n blockdev --getsize64 "$root_device")
test "$disk_size" -gt "$original_size"
test "$root_size" -gt $((original_size + 1073741824))
test -s /etc/machine-id
test -s /etc/ssh/ssh_host_ed25519_key.pub
GUEST

if [[ "$FLAVOR" == core ]]; then
  ssh "${ssh_options[@]}" "$ssh_target" '/usr/bin/bash -s' <<'GUEST'
set -euo pipefail
test /proc/1/exe -ef /sbin/zvminit
test -f /var/lib/azagent/provisioned
master=
for proc in /proc/[0-9]*; do
  test -r "$proc/status" || continue
  test "$(awk '/^Name:/{print $2}' "$proc/status")" = sshd || continue
  test "$(awk '/^PPid:/{print $2}' "$proc/status")" = 1 || continue
  case "$(tr '\000' ' ' <"$proc/cmdline")" in
    *"/usr/sbin/sshd -D -e"*) master=${proc##*/}; break ;;
  esac
done
test -n "$master"
mountpoint -q /d
test "$(findmnt -n -o FSTYPE /d)" = ext4
test -f /d/DATALOSS_WARNING_README.txt
! awk 'NR > 1 {print $1}' /proc/swaps | grep -Fq /d
GUEST
else
  ssh "${ssh_options[@]}" "$ssh_target" '/usr/bin/bash -s' <<'GUEST'
set -euo pipefail
test /proc/1/exe -ef /usr/lib/systemd/systemd
test ! -e /sbin/zvminit
test ! -e /usr/bin/zvminit
for unit in cloud-final.service waagent.service sshd.service systemd-networkd.service; do
  systemctl is-active --quiet "$unit"
  systemctl is-enabled --quiet "$unit"
done
cloud-init status --wait
grep -Eq '^[[:space:]]*Provisioning.Agent[[:space:]]*=[[:space:]]*auto[[:space:]]*$' /etc/waagent.conf
grep -Eq '^[[:space:]]*ResourceDisk.Format[[:space:]]*=[[:space:]]*n[[:space:]]*$' /etc/waagent.conf
! mountpoint -q /d
GUEST
  test "$(az vm get-instance-view \
    --resource-group "$resource_group" \
    --name "$vm_name" \
    --query "instanceView.vmAgent.statuses[?code=='ProvisioningState/succeeded'].code | [0]" \
    --output tsv)" = ProvisioningState/succeeded
fi

az disk create \
  --resource-group "$resource_group" \
  --name "$data_disk_name" \
  --location "$AZURE_LOCATION" \
  --size-gb 4 \
  --sku Standard_LRS
az vm disk attach \
  --resource-group "$resource_group" \
  --vm-name "$vm_name" \
  --name "$data_disk_name" \
  --lun 0
boot_id=$(ssh "${ssh_options[@]}" "$ssh_target" 'cat /proc/sys/kernel/random/boot_id')
reboot_and_reconnect "$boot_id"

data_device=$(ssh "${ssh_options[@]}" "$ssh_target" '/usr/bin/bash -s' <<'GUEST'
set -euo pipefail
root_source=$(readlink -f "$(findmnt -n -o SOURCE /)")
root_disk=$(lsblk -n -o PKNAME "$root_source")
found=
for sysdev in /sys/class/block/sd* /sys/class/block/nvme*n*; do
  test -e "$sysdev" || continue
  name=${sysdev##*/}
  test "$name" != "$root_disk" || continue
  test ! -e "$sysdev/partition" || continue
  if [[ "$name" == nvme* ]]; then
    model=$(cat "$sysdev/device/model" 2>/dev/null || true)
    nsid=$(cat "$sysdev/device/nsid" 2>/dev/null || true)
    [[ "$model" == "MSFT NVMe Accelerator v1.0" && "$nsid" == 2 ]] || continue
  else
    target=$(readlink -f "$sysdev")
    address=$(basename "${target%/block/*}")
    [[ "$address" == *:0 ]] || continue
  fi
  test -z "$found"
  found="/dev/$name"
done
test -b "$found"
if lsblk -nr -o TYPE "$found" | tail -n +2 | grep -q '^part$'; then
  exit 1
fi
first_sector=$(sudo -n dd if="$found" bs=512 count=1 status=none | od -An -tx1 | tr -d ' \n')
test -n "$first_sector"
test -z "${first_sector//0/}"
if findmnt -rn -S "$found" >/dev/null; then
  exit 1
fi
printf '%s\n' "$found"
GUEST
)
[[ "$data_device" == /dev/* ]]

if [[ "$FLAVOR" == core ]]; then
  ssh "${ssh_options[@]}" "$ssh_target" \
    "/usr/bin/bash -s -- '$data_device'" <<'GUEST'
set -euo pipefail
device=$1
printf 'label: dos\n,,L\n' | sudo -n /usr/sbin/sfdisk "$device"
sudo -n /usr/sbin/partprobe "$device" || sudo -n blockdev --rereadpt "$device"
case "$device" in
  /dev/nvme*) partition="${device}p1" ;;
  *) partition="${device}1" ;;
esac
for _ in $(seq 1 30); do
  test -b "$partition" && break
  sleep 1
done
test -b "$partition"
sudo -n /usr/sbin/mkfs.ext4 -F "$partition"
GUEST
  boot_id=$(ssh "${ssh_options[@]}" "$ssh_target" 'cat /proc/sys/kernel/random/boot_id')
  reboot_and_reconnect "$boot_id"
  ssh "${ssh_options[@]}" "$ssh_target" \
    "test \"\$(findmnt -n -o FSTYPE /e)\" = ext4 && echo zvmi-managed | sudo -n tee /e/zvmi-acceptance >/dev/null"
  boot_id=$(ssh "${ssh_options[@]}" "$ssh_target" 'cat /proc/sys/kernel/random/boot_id')
  reboot_and_reconnect "$boot_id"
  ssh "${ssh_options[@]}" "$ssh_target" \
    "mountpoint -q /e && grep -Fxq zvmi-managed /e/zvmi-acceptance"
fi

rm -f -- "$boot_log"
for _ in {1..30}; do
  if az vm boot-diagnostics get-boot-log \
    --resource-group "$resource_group" \
    --name "$vm_name" >"$boot_log" 2>/dev/null && [[ -s "$boot_log" ]]; then
    break
  fi
  sleep 5
done
test -s "$boot_log"
if [[ "$FLAVOR" == core ]]; then
  grep -Fq '[zvminit] ZVMINIT_PID1_READY supervisor loop active' "$boot_log"
  grep -Fq '[zvminit] azagent completed successfully' "$boot_log"
fi
if [[ "$ARCHITECTURE" == aarch64 ]]; then
  grep -Fq 'ttyAMA0' "$boot_log"
fi

python3 scripts/azurelinux4_release.py azure-result \
  --manifest "$manifest" \
  --asset "$asset" \
  --vhd "$vhd" \
  --key "$CANDIDATE_KEY" \
  --source-commit "$SOURCE_COMMIT" \
  --location "$AZURE_LOCATION" \
  --vm-size "$AZURE_VM_SIZE" \
  --resource-group "$resource_group" \
  --run-id "$GITHUB_RUN_ID" \
  --run-attempt "$GITHUB_RUN_ATTEMPT" \
  --output "$RESULT_DIR/azure-result.json"
test "$(sha256sum "$asset" | awk '{print $1}')" = "$qcow_sha256"

{
  echo "### Azure acceptance: $ASSET_NAME"
  echo
  echo "- QCOW2 SHA-256: \`$qcow_sha256\`"
  echo "- Temporary VHD SHA-256: \`$vhd_sha256\` (not retained or published)"
  echo "- Azure: \`$AZURE_LOCATION\` / \`$AZURE_VM_SIZE\`"
  echo "- Contracts: key-only SSH, Ready, root growth, resource/data disks, reboot, runtime identity"
} >>"$GITHUB_STEP_SUMMARY"

#!/usr/bin/env bash
# Практика 1, самостоятельная часть, вариант 04.
# Поднимает с нуля: сеть, подсеть, группу безопасности и две ВМ.
# Запуск из корня репозитория: ./work-01/create.sh
set -euo pipefail

# ===== Параметры варианта 04 =====
PREFIX="alaverdyan-04"
ZONE="ru-central1-a"
CIDR="10.14.1.0/24"
APP_PORT=8012
DISK_SIZE=15
IMAGE_FAMILY="ubuntu-2204-lts"
SSH_KEY="$HOME/.ssh/id_ed25519.pub"
VM_NAMES=("$PREFIX-app-1" "$PREFIX-app-2")
# =================================

NET="$PREFIX-net"
SUBNET="$PREFIX-subnet"
SG="$PREFIX-sg"

# Предварительные проверки
command -v yc >/dev/null || { echo "Не найден yc"; exit 1; }
command -v jq >/dev/null || { echo "Не найден jq"; exit 1; }
[ -s "$SSH_KEY" ] || { echo "Нет публичного ключа $SSH_KEY"; exit 1; }
if yc vpc network get --name "$NET" >/dev/null 2>&1; then
  echo "Сеть $NET уже существует. Сначала выполните ./work-01/destroy.sh"
  exit 1
fi

echo "==> Сеть $NET"
yc vpc network create --name "$NET"

echo "==> Подсеть $SUBNET ($CIDR, $ZONE)"
yc vpc subnet create \
  --name "$SUBNET" \
  --network-name "$NET" \
  --zone "$ZONE" \
  --range "$CIDR"

echo "==> Группа безопасности $SG (22 и $APP_PORT снаружи)"
yc vpc security-group create \
  --name "$SG" \
  --network-name "$NET" \
  --rule "direction=ingress,port=22,protocol=tcp,v4-cidrs=[0.0.0.0/0]" \
  --rule "direction=ingress,port=$APP_PORT,protocol=tcp,v4-cidrs=[0.0.0.0/0]" \
  --rule "direction=egress,port=any,protocol=any,v4-cidrs=[0.0.0.0/0]"
SG_ID=$(yc vpc security-group get --name "$SG" --format json | jq -r .id)

for VM in "${VM_NAMES[@]}"; do
  echo "==> Машина $VM"
  yc compute instance create \
    --name "$VM" \
    --hostname "$VM" \
    --zone "$ZONE" \
    --platform standard-v3 \
    --cores=2 \
    --core-fraction=20 \
    --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$DISK_SIZE" \
    --network-interface subnet-name="$SUBNET",nat-ip-version=ipv4,security-group-ids="$SG_ID" \
    --ssh-key "$SSH_KEY" \
    --labels created-by=script
done

echo "==> Готово. Машины стенда:"
yc compute instance list --format json | jq -r --arg p "$PREFIX" \
  '.[] | select(.name | startswith($p)) | "\(.name)\t\(.status)\thttp://\(.network_interfaces[0].primary_v4_address.one_to_one_nat.address // "нет")"'
echo "Порт сервиса: $APP_PORT"

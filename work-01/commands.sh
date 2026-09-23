#!/usr/bin/env bash
# Практика 1, вариант 04 — журнал команд аудиторной части

# --- Параметры варианта ---
export PREFIX=alaverdyan-04
export ZONE=ru-central1-a
export CIDR=10.14.1.0/24
export DISK_SIZE=15

# --- Сервисный аккаунт, роль, ключ ---
yc iam service-account get --name "$PREFIX-sa" >/dev/null 2>&1 || \
  yc iam service-account create --name "$PREFIX-sa"
export FOLDER_ID=$(yc config get folder-id)
export SA_ID=$(yc iam service-account get --name "$PREFIX-sa" --format json | jq -r .id)
echo "$FOLDER_ID $SA_ID"
yc resource-manager folder add-access-binding "$FOLDER_ID" \
  --role editor \
  --subject "serviceAccount:$SA_ID"
mkdir -p ~/.yc-keys
if [ ! -s ~/.yc-keys/$PREFIX-key.json ]; then
  yc iam key create --service-account-name "$PREFIX-sa" \
    --output ~/.yc-keys/$PREFIX-key.json
fi

# --- Своя сеть и подсеть ---
yc vpc network create --name "$PREFIX-net"
yc vpc subnet create \
  --name "$PREFIX-subnet" \
  --network-name "$PREFIX-net" \
  --zone "$ZONE" \
  --range "$CIDR"

# --- Машина командой ---
yc compute instance create \
  --name "$PREFIX-web-1" \
  --hostname "$PREFIX-web-1" \
  --zone "$ZONE" \
  --platform standard-v3 \
  --cores=2 \
  --core-fraction=20 \
  --memory=2 \
  --preemptible \
  --create-boot-disk image-folder-id=standard-images,image-family=ubuntu-2404-lts,type=network-hdd,size="$DISK_SIZE" \
  --network-interface subnet-name="$PREFIX-subnet",nat-ip-version=ipv4 \
  --ssh-key ~/.ssh/id_ed25519.pub \
  --labels created-by=cli

# публичный адрес машины
yc compute instance get "$PREFIX-web-1" --format json \
  | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address'

# --- Сведения о ресурсах ---
yc compute instance list --format json \
  | jq -r '.[] | "\(.name)\t\(.status)\t\(.network_interfaces[0].primary_v4_address.one_to_one_nat.address // "нет")"'
# только свои машины
yc compute instance list --format json | jq -r ".[] | select(.name | startswith(\"$PREFIX\")) | .name"
# остановленные машины (прерываемая ВМ могла быть остановлена облаком)
yc compute instance list --format json | jq -r '.[] | select(.status != "RUNNING") | .name'

# --- Уборка: сначала машины, потом подсеть, потом сеть ---
yc compute instance delete "$PREFIX-web-1"
yc compute instance delete "$PREFIX-web-manual"
yc vpc subnet delete "$PREFIX-subnet"
yc vpc network delete "$PREFIX-net"

# --- Проверка, что ничего не осталось ---
yc compute instance list
yc vpc network list
yc compute disk list

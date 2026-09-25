#!/usr/bin/env bash
# Практика 2, вариант 04: сеть с двумя подсетями, машины в двух зонах,
# дополнительный диск, целевая группа и сетевой балансировщик.
# Запуск из корня репозитория:
#   bash work-02/create.sh [число_машин] [размер_доп_диска_ГБ]
# Без аргументов берутся значения варианта: 3 машины, диск 20 ГБ.
set -euo pipefail                  # стоп на первой ошибке и на пустой переменной

# ---- параметры варианта 04 ----
PREFIX=alaverdyan-04               # префикс имён ресурсов
ZONE_A=ru-central1-a               # зона A
ZONE_B=ru-central1-b               # зона B
CIDR_A=10.14.1.0/24                # подсеть в зоне A
CIDR_B=10.14.2.0/24                # подсеть в зоне B
APP_PORT=8012                      # порт, на котором отвечает nginx
GREETING=devlab                    # слово варианта, оно же на странице
VM_COUNT="${1:-3}"                 # число машин: 1-й аргумент, по умолчанию 3
DISK_SIZE="${2:-20}"               # доп. диск, ГБ: 2-й аргумент, по умолчанию 20
BOOT_SIZE=15                       # загрузочный диск, ГБ
IMAGE_FAMILY=ubuntu-2404-lts       # образ машин, одинаковый у всех вариантов
# --------------------------------

# проверка аргументов: до создания чего-либо в облаке
if ! [[ "$VM_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Число машин должно быть целым числом больше нуля, получено: $VM_COUNT" >&2
  exit 1
fi
if ! [[ "$DISK_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "Размер диска должен быть целым числом гигабайт, получено: $DISK_SIZE" >&2
  exit 1
fi
# скрипт не помнит, что уже создавал: защищаемся от второго стенда поверх первого
if yc vpc network get --name "$PREFIX-net" >/dev/null 2>&1; then
  echo "Сеть $PREFIX-net уже существует. Сначала выполните: bash work-02/destroy.sh" >&2
  exit 1
fi
echo "Параметры: машин $VM_COUNT, доп. диск $DISK_SIZE ГБ, порт $APP_PORT, слово $GREETING"

echo "==> сеть и подсети"
yc vpc network create --name "$PREFIX-net"
yc vpc subnet create --name "$PREFIX-subnet-a" --network-name "$PREFIX-net" \
  --zone "$ZONE_A" --range "$CIDR_A"
yc vpc subnet create --name "$PREFIX-subnet-b" --network-name "$PREFIX-net" \
  --zone "$ZONE_B" --range "$CIDR_B"

echo "==> файл настройки из шаблона"
SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
export APP_PORT GREETING SSH_KEY
envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' \
  < work-02/cloud-init.tpl.yaml > work-02/cloud-init.yaml

echo "==> дополнительный диск"
# диск создаётся до машин: cloud-init размечает его при первой загрузке,
# поэтому к первой машине он должен быть подключён сразу при создании
yc compute disk create --name "$PREFIX-data" --zone "$ZONE_A" \
  --size "$DISK_SIZE" --type network-hdd

echo "==> машины"
ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$PREFIX-subnet-a" "$PREFIX-subnet-b")
for i in $(seq 1 "$VM_COUNT"); do
  idx=$(( (i - 1) % 2 ))           # 0, 1, 0, 1 ... — чередование зон
  DISK_ARGS=()
  if [ "$i" -eq 1 ]; then          # диск получает только первая машина (зона A)
    DISK_ARGS=(--attach-disk "disk-name=$PREFIX-data,device-name=data")
  fi
  yc compute instance create \
    --name "$PREFIX-app-$i" \
    --zone "${ZONES[$idx]}" \
    --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$BOOT_SIZE" \
    --network-interface subnet-name="${SUBNETS[$idx]}",nat-ip-version=ipv4 \
    --hostname "$PREFIX-app-$i" \
    --metadata-from-file user-data=work-02/cloud-init.yaml \
    "${DISK_ARGS[@]}"
done

echo "==> целевая группа"
# адреса машин не задаются, а узнаются у облака после создания
TARGETS=()
for i in $(seq 1 "$VM_COUNT"); do
  idx=$(( (i - 1) % 2 ))
  IP=$(yc compute instance get "$PREFIX-app-$i" --format json \
    | jq -r '.network_interfaces[0].primary_v4_address.address')
  TARGETS+=(--target "subnet-name=${SUBNETS[$idx]},address=$IP")
done
yc load-balancer target-group create --name "$PREFIX-tg" "${TARGETS[@]}"

echo "==> балансировщик"
TG_ID=$(yc load-balancer target-group get --name "$PREFIX-tg" --format json | jq -r .id)
yc load-balancer network-load-balancer create \
  --name "$PREFIX-lb" \
  --region-id ru-central1 \
  --listener name=http,port=80,target-port="$APP_PORT",external-ip-version=ipv4 \
  --target-group target-group-id="$TG_ID",healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port="$APP_PORT",healthcheck-http-path=/

echo "==> ожидание готовности машин"
# машины RUNNING ещё не значит готовы: cloud-init ставит nginx пару минут
HEALTHY=0
for attempt in $(seq 1 36); do     # до 6 минут, проверка раз в 10 секунд
  HEALTHY=$(yc load-balancer network-load-balancer target-states \
      --name "$PREFIX-lb" --target-group-id "$TG_ID" --format json 2>/dev/null \
    | jq '[.. | objects | select(.status? == "HEALTHY")] | length' || echo 0)
  echo "    попытка $attempt: HEALTHY $HEALTHY из $VM_COUNT"
  if [ "$HEALTHY" -eq "$VM_COUNT" ]; then
    break
  fi
  sleep 10
done
if [ "$HEALTHY" -ne "$VM_COUNT" ]; then
  echo "Не все машины прошли проверку состояния, посмотрите target-states" >&2
fi

LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" --format json \
  | jq -r '.listeners[0].address')
echo "==> готово: http://$LB_IP"

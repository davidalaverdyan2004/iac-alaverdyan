#!/usr/bin/env bash
# ДЗ 1, вариант 04: поднимает стенд для показов.
#   сеть, две подсети, NAT-шлюз с таблицей маршрутизации,
#   веб-серверы в двух зонах, сервер приложения без публичного адреса,
#   целевая группа и сетевой балансировщик.
# Повторный запуск безопасен: существующие ресурсы пропускаются.
# Запуск: ./hw-01/create.sh [--web-count N] [--port N] [--greeting WORD] [--prefix NAME]
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/params.sh" "$@"

NET="$PREFIX-net"
SUBNET_A="$PREFIX-subnet-a"
SUBNET_B="$PREFIX-subnet-b"
NAT="$PREFIX-nat"
RT="$PREFIX-rt"
APP="$PREFIX-app"
TG="$PREFIX-tg"
LB="$PREFIX-lb"

# ресурс существует? $1 — группа команд yc, $2 — имя. Смотрим код возврата get.
exists() {
  # shellcheck disable=SC2086
  yc $1 get --name "$2" >/dev/null 2>&1
}
skip() { echo "    $1 уже есть, пропускаю"; }

echo "Параметры: префикс $PREFIX, веб-серверов $WEB_COUNT, порт $APP_PORT, слово $GREETING"

echo "==> сеть и подсети"
if exists "vpc network" "$NET"; then skip "сеть $NET"; else
  yc vpc network create --name "$NET"
fi
if exists "vpc subnet" "$SUBNET_A"; then skip "подсеть $SUBNET_A"; else
  yc vpc subnet create --name "$SUBNET_A" --network-name "$NET" --zone "$ZONE_A" --range "$CIDR_A"
fi
if exists "vpc subnet" "$SUBNET_B"; then skip "подсеть $SUBNET_B"; else
  yc vpc subnet create --name "$SUBNET_B" --network-name "$NET" --zone "$ZONE_B" --range "$CIDR_B"
fi

echo "==> NAT-шлюз и таблица маршрутизации"
if exists "vpc gateway" "$NAT"; then skip "шлюз $NAT"; else
  yc vpc gateway create --name "$NAT"
fi
GW_ID=$(yc vpc gateway get --name "$NAT" --format json | jq -r .id)
if exists "vpc route-table" "$RT"; then skip "таблица $RT"; else
  yc vpc route-table create --name "$RT" --network-name "$NET" \
    --route "destination=0.0.0.0/0,gateway-id=$GW_ID"
fi
RT_ID=$(yc vpc route-table get --name "$RT" --format json | jq -r .id)
if [ "$(yc vpc subnet get --name "$SUBNET_A" --format json | jq -r '.route_table_id // ""')" = "$RT_ID" ]; then
  skip "привязка $RT к $SUBNET_A"
else
  yc vpc subnet update --name "$SUBNET_A" --route-table-name "$RT"
fi

echo "==> файл настройки из шаблона"
SSH_KEY=$(cat ~/.ssh/id_ed25519.pub)
export APP_PORT GREETING SSH_KEY
envsubst '${APP_PORT} ${GREETING} ${SSH_KEY}' < "$DIR/cloud-init.tpl.yaml" > "$DIR/cloud-init.yaml"

# создать машину, если её ещё нет. $1 имя, $2 зона, $3 подсеть, $4 "public" или "private"
create_vm() {
  local name="$1" zone="$2" nic="subnet-name=$3"
  if exists "compute instance" "$name"; then skip "машина $name"; return; fi
  if [ "$4" = "public" ]; then nic="$nic,nat-ip-version=ipv4"; fi
  yc compute instance create \
    --name "$name" \
    --hostname "$name" \
    --zone "$zone" \
    --platform standard-v3 \
    --cores=2 --core-fraction=20 --memory=2 \
    --preemptible \
    --create-boot-disk image-folder-id=standard-images,image-family="$IMAGE_FAMILY",type=network-hdd,size="$BOOT_SIZE" \
    --network-interface "$nic" \
    --metadata-from-file user-data="$DIR/cloud-init.yaml"
}

echo "==> веб-серверы"
ZONES=("$ZONE_A" "$ZONE_B")
SUBNETS=("$SUBNET_A" "$SUBNET_B")
for i in $(seq 1 "$WEB_COUNT"); do
  idx=$(( (i - 1) % 2 ))                  # зоны чередуются: a, b, a, ...
  create_vm "$PREFIX-web-$i" "${ZONES[$idx]}" "${SUBNETS[$idx]}" public
done

echo "==> сервер приложения (без публичного адреса)"
create_vm "$APP" "$ZONE_A" "$SUBNET_A" private

echo "==> целевая группа"
if exists "load-balancer target-group" "$TG"; then skip "целевая группа $TG"; else
  TARGETS=()
  for i in $(seq 1 "$WEB_COUNT"); do
    idx=$(( (i - 1) % 2 ))
    IP=$(yc compute instance get --name "$PREFIX-web-$i" --format json \
      | jq -r '.network_interfaces[0].primary_v4_address.address')
    TARGETS+=(--target "subnet-name=${SUBNETS[$idx]},address=$IP")
  done
  yc load-balancer target-group create --name "$TG" "${TARGETS[@]}"
fi
TG_ID=$(yc load-balancer target-group get --name "$TG" --format json | jq -r .id)

echo "==> балансировщик"
if exists "load-balancer network-load-balancer" "$LB"; then skip "балансировщик $LB"; else
  yc load-balancer network-load-balancer create \
    --name "$LB" \
    --region-id ru-central1 \
    --listener name=http,port=80,target-port="$APP_PORT",external-ip-version=ipv4 \
    --target-group target-group-id="$TG_ID",healthcheck-name=http,healthcheck-interval=2s,healthcheck-timeout=1s,healthcheck-unhealthythreshold=2,healthcheck-healthythreshold=2,healthcheck-http-port="$APP_PORT",healthcheck-http-path=/
fi

echo "==> ожидание готовности веб-серверов"
TOTAL=$(yc load-balancer target-group get --name "$TG" --format json | jq '.targets | length')
HEALTHY=0
for attempt in $(seq 1 36); do             # до 6 минут
  HEALTHY=$(yc load-balancer network-load-balancer target-states \
      --name "$LB" --target-group-id "$TG_ID" --format json 2>/dev/null \
    | jq '[.. | objects | select(.status? == "HEALTHY")] | length' || echo 0)
  echo "    попытка $attempt: HEALTHY $HEALTHY из $TOTAL"
  [ "$HEALTHY" -eq "$TOTAL" ] && break
  sleep 10
done

LB_IP=$(yc load-balancer network-load-balancer get --name "$LB" --format json | jq -r '.listeners[0].address')
if [ "$HEALTHY" -eq "$TOTAL" ]; then
  echo "==> стенд готов: http://$LB_IP   проверка: ./hw-01/check.sh"
else
  echo "==> стенд создан, но готовы не все веб-серверы ($HEALTHY из $TOTAL): запустите ./hw-01/check.sh" >&2
  exit 1
fi

#!/usr/bin/env bash
# ДЗ 1, вариант 04: проверяет, что стенд работает.
# Три проверки, по строке на каждую; код возврата 0 — все прошли, 1 — хотя бы одна нет.
# Запуск: ./hw-01/check.sh [--prefix NAME] [--greeting WORD] [--port N]
set -uo pipefail                          # без -e: провал проверки не должен обрывать скрипт

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/params.sh" "$@"

FAIL=0
ok()  { echo "✓ $1"; }
bad() { echo "✗ $1"; FAIL=1; }

# SSH без вопросов об отпечатке и с повторами: адреса машин меняются от стенда к стенду,
# а соединения к облаку у провайдера иногда обрываются
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=8 -o StrictHostKeyChecking=no
          -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
ssh_retry() {                             # $1 адрес, дальше команда
  local host="$1"; shift
  for _ in 1 2 3 4; do
    ssh "${SSH_OPTS[@]}" "student@$host" "$@" && return 0
    [ $? -ne 255 ] && return 1            # команда выполнилась и вернула ошибку
    sleep 2
  done
  return 255
}

# ---- 1. балансировщик отвечает кодом 200 ----
LB_IP=$(yc load-balancer network-load-balancer get --name "$PREFIX-lb" --format json 2>/dev/null \
  | jq -r '.listeners[0].address // empty')
if [ -z "$LB_IP" ]; then
  bad "балансировщик $PREFIX-lb не найден"
else
  CODE=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --retry 3 --retry-all-errors "http://$LB_IP")
  if [ "$CODE" = "200" ]; then ok "балансировщик http://$LB_IP отвечает: $CODE"
  else bad "балансировщик http://$LB_IP отвечает: $CODE"; fi
fi

# ---- 2. отвечают все веб-серверы, а не один ----
WEBS=$(yc compute instance list --format json 2>/dev/null \
  | jq -r --arg p "$PREFIX-web-" '[.[] | select(.name | startswith($p)) | .name] | sort | .[]')
if [ -z "$LB_IP" ] || [ -z "$WEBS" ]; then
  bad "распределение не проверить: нет балансировщика или веб-серверов"
else
  SEEN=$(for _ in $(seq 1 20); do
           curl -s --max-time 5 --retry 2 --retry-all-errors "http://$LB_IP" \
             | grep -m1 -o "$GREETING on [a-z0-9-]*"
         done | sed "s/^$GREETING on //" | sort -u)
  EXPECTED=$(echo "$WEBS" | wc -l)
  GOT=$(echo "$SEEN" | grep -c . || true)
  LIST=$(echo "$SEEN" | sed "s/^$PREFIX-//" | paste -sd, - | sed 's/,/, /g')
  if [ "$GOT" -eq "$EXPECTED" ] && [ "$GOT" -gt 1 ]; then
    ok "ответили все веб-серверы ($GOT из $EXPECTED): $LIST"
  else
    bad "ответили не все веб-серверы ($GOT из $EXPECTED): ${LIST:-никто}"
  fi
fi

# ---- 3. сервер приложения доступен с веб-сервера по внутреннему адресу ----
APP_IP=$(yc compute instance get --name "$PREFIX-app" --format json 2>/dev/null \
  | jq -r '.network_interfaces[0].primary_v4_address.address // empty')
if [ -z "$APP_IP" ]; then
  bad "сервер приложения $PREFIX-app не найден"
else
  DONE=0
  for web in $WEBS; do
    WEB_IP=$(yc compute instance get --name "$web" --format json \
      | jq -r '.network_interfaces[0].primary_v4_address.one_to_one_nat.address // empty')
    [ -z "$WEB_IP" ] && continue
    ANSWER=$(ssh_retry "$WEB_IP" "curl -s --max-time 5 http://$APP_IP:$APP_PORT")
    RC=$?
    [ $RC -eq 255 ] && continue           # не достучались до этого веб-сервера, пробуем следующий
    DONE=1
    if echo "$ANSWER" | grep -q "$GREETING on $PREFIX-app"; then
      ok "сервер приложения $APP_IP:$APP_PORT отвечает с ${web#"$PREFIX"-}: $ANSWER"
    else
      bad "сервер приложения $APP_IP:$APP_PORT недоступен с ${web#"$PREFIX"-}"
    fi
    break
  done
  [ $DONE -eq 0 ] && bad "не удалось подключиться ни к одному веб-серверу для проверки $APP_IP"
fi

echo "код возврата: $FAIL"
exit "$FAIL"

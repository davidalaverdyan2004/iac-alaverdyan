#!/usr/bin/env bash
# Практика 2, вариант 04: удаляет всё, что создал create.sh,
# в порядке, обратном созданию. Отрабатывает на любом состоянии стенда:
# ресурс, которого уже нет, пропускается, а не роняет скрипт.
set -euo pipefail                  # стоп на первой ошибке и на пустой переменной

PREFIX=alaverdyan-04

# удалить ресурс, только если он есть
# $1 — группа команд yc (например, "compute instance"), $2 — имя ресурса
remove() {
  local kind="$1" name="$2"
  # shellcheck disable=SC2086      # $kind намеренно разбивается на слова
  if yc $kind get --name "$name" >/dev/null 2>&1; then
    echo "==> удаляю $kind $name"
    # shellcheck disable=SC2086
    yc $kind delete --name "$name"
  else
    echo "    $kind $name: нет, пропускаю"
  fi
}

# сначала то, что ссылается на другие ресурсы
remove "load-balancer network-load-balancer" "$PREFIX-lb"
remove "load-balancer target-group" "$PREFIX-tg"

# машины не считаем, а спрашиваем облако: всё, что начинается с префикса
VMS=$(yc compute instance list --format json \
  | jq -r --arg p "$PREFIX-app-" '.[] | select(.name | startswith($p)) | .name')
for vm in $VMS; do
  remove "compute instance" "$vm"
done

# диск подключён без автоудаления и переживает машину
remove "compute disk" "$PREFIX-data"

remove "vpc subnet" "$PREFIX-subnet-a"
remove "vpc subnet" "$PREFIX-subnet-b"
remove "vpc network" "$PREFIX-net"

echo "==> что осталось в каталоге"
echo "-- машины:";         yc compute instance list
echo "-- диски:";          yc compute disk list
echo "-- сети:";           yc vpc network list
echo "-- балансировщики:"; yc load-balancer network-load-balancer list

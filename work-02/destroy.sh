#!/usr/bin/env bash
# Практика 2, вариант 04 (аудиторная часть): удаляет стенд в порядке,
# обратном созданию.
set -euo pipefail                  # стоп на первой ошибке и на пустой переменной

PREFIX=alaverdyan-04
VM_COUNT=3

# сначала то, что ссылается на другие ресурсы
yc load-balancer network-load-balancer delete "$PREFIX-lb"
yc load-balancer target-group delete "$PREFIX-tg"

for i in $(seq 1 "$VM_COUNT"); do
  yc compute instance delete "$PREFIX-app-$i"
done

# диск создан с --auto-delete=false и сам вместе с машиной не удаляется
yc compute disk delete "$PREFIX-data"

yc vpc subnet delete "$PREFIX-subnet-a"
yc vpc subnet delete "$PREFIX-subnet-b"
yc vpc network delete "$PREFIX-net"

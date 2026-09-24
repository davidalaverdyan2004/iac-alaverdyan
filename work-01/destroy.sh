#!/usr/bin/env bash
# Практика 1, самостоятельная часть, вариант 04.
# Сносит всё, что создал create.sh: ВМ -> группа безопасности -> подсеть -> сеть.
# Запуск из корня репозитория: ./work-01/destroy.sh
set -uo pipefail

# ===== Параметры варианта 04 =====
PREFIX="alaverdyan-04"
VM_NAMES=("$PREFIX-app-1" "$PREFIX-app-2")
# =================================

NET="$PREFIX-net"
SUBNET="$PREFIX-subnet"
SG="$PREFIX-sg"

for VM in "${VM_NAMES[@]}"; do
  echo "==> Удаление машины $VM"
  yc compute instance delete --name "$VM" || echo "   (машины $VM нет)"
done

echo "==> Удаление группы безопасности $SG"
yc vpc security-group delete --name "$SG" || echo "   (группы $SG нет)"

echo "==> Удаление подсети $SUBNET"
yc vpc subnet delete --name "$SUBNET" || echo "   (подсети $SUBNET нет)"

echo "==> Удаление сети $NET"
yc vpc network delete --name "$NET" || echo "   (сети $NET нет)"

echo "==> Проверка: машины, диски, сети, группы безопасности"
yc compute instance list
yc compute disk list
yc vpc network list
yc vpc security-group list

#!/usr/bin/env bash
# ДЗ 1, вариант 04: удаляет всё, что создал create.sh.
# Ресурсы ищутся по префиксу имени, а не по списку, который скрипт «помнит»,
# поэтому он убирает стенд в любом состоянии и с любым числом машин.
# Запуск: ./hw-01/destroy.sh [--prefix NAME]
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/params.sh" "$@"

# имена ресурсов группы $1, начинающиеся с префикса
names() {
  # shellcheck disable=SC2086
  yc $1 list --format json | jq -r --arg p "$PREFIX-" '.[] | select(.name | startswith($p)) | .name'
}
# удалить все ресурсы группы $1 с префиксом
remove_all() {
  local kind="$1" found=0
  for name in $(names "$kind"); do
    found=1
    echo "==> удаляю $kind $name"
    # shellcheck disable=SC2086
    yc $kind delete --name "$name"
  done
  [ $found -eq 0 ] && echo "    $kind с префиксом $PREFIX-: нет, пропускаю"
  return 0
}

# порядок обратный созданию: сначала то, что ссылается на другие ресурсы
remove_all "load-balancer network-load-balancer"
remove_all "load-balancer target-group"
remove_all "compute instance"

# подсеть ссылается на таблицу маршрутизации: сначала отвязываем
for subnet in $(names "vpc subnet"); do
  if [ -n "$(yc vpc subnet get --name "$subnet" --format json | jq -r '.route_table_id // ""')" ]; then
    echo "==> отвязываю таблицу маршрутизации от $subnet"
    yc vpc subnet update --name "$subnet" --disassociate-route-table
  fi
done
remove_all "vpc route-table"
remove_all "vpc gateway"
remove_all "vpc subnet"
remove_all "vpc network"

echo "==> что осталось в каталоге"
echo "-- машины:";         yc compute instance list
echo "-- диски:";          yc compute disk list
echo "-- адреса:";         yc vpc address list
echo "-- сети:";           yc vpc network list
echo "-- балансировщики:"; yc load-balancer network-load-balancer list

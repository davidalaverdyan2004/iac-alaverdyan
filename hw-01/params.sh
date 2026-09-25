#!/usr/bin/env bash
# Общие параметры стенда ДЗ 1, вариант 04. Подключается из create.sh, check.sh и destroy.sh:
#   source "$DIR/params.sh" "$@"
# Приоритет: аргумент командной строки > переменная окружения > умолчание варианта.

# ---- 1. умолчания варианта 04; переменная окружения с тем же именем их перекрывает ----
PREFIX="${PREFIX:-alaverdyan-04}"         # префикс имён ресурсов
ZONE_A="${ZONE_A:-ru-central1-a}"         # зона A: подсеть с NAT, сервер приложения
ZONE_B="${ZONE_B:-ru-central1-b}"         # зона B
CIDR_A="${CIDR_A:-10.14.1.0/24}"          # подсеть в зоне A
CIDR_B="${CIDR_B:-10.14.2.0/24}"          # подсеть в зоне B
APP_PORT="${APP_PORT:-8012}"              # порт nginx на всех машинах
GREETING="${GREETING:-devlab}"            # слово на странице
WEB_COUNT="${WEB_COUNT:-3}"               # число веб-серверов
BOOT_SIZE="${BOOT_SIZE:-15}"              # загрузочный диск, ГБ
IMAGE_FAMILY="${IMAGE_FAMILY:-ubuntu-2404-lts}"

usage() {
  cat << 'USAGE'
Параметры (аргумент > переменная окружения > умолчание варианта 04):
  --web-count N    число веб-серверов          WEB_COUNT  (3)
  --port N         порт nginx                  APP_PORT   (8012)
  --greeting WORD  слово на странице           GREETING   (devlab)
  --prefix NAME    префикс имён ресурсов       PREFIX     (alaverdyan-04)
  --print-params   показать итоговые значения и выйти, ничего не создавая
  -h, --help       эта справка
USAGE
}

PRINT_PARAMS=0

# ---- 2. аргументы командной строки перекрывают всё остальное ----
while [ $# -gt 0 ]; do
  case "$1" in
    --web-count) WEB_COUNT="${2:-}"; shift 2 ;;
    --port)      APP_PORT="${2:-}";  shift 2 ;;
    --greeting)  GREETING="${2:-}";  shift 2 ;;
    --prefix)    PREFIX="${2:-}";    shift 2 ;;
    --print-params) PRINT_PARAMS=1; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Неизвестный параметр: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---- 3. проверка значений до обращения к облаку ----
if ! [[ "$WEB_COUNT" =~ ^[1-9][0-9]*$ ]]; then
  echo "Число веб-серверов должно быть целым числом больше нуля, получено: '$WEB_COUNT'" >&2; exit 2
fi
if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]] || [ "$APP_PORT" -lt 1 ] || [ "$APP_PORT" -gt 65535 ]; then
  echo "Порт должен быть числом от 1 до 65535, получено: '$APP_PORT'" >&2; exit 2
fi
if ! [[ "$PREFIX" =~ ^[a-z][a-z0-9-]*$ ]]; then
  echo "Префикс: строчные латинские буквы, цифры и дефис, первая — буква; получено: '$PREFIX'" >&2; exit 2
fi

if [ "$PRINT_PARAMS" -eq 1 ]; then
  echo "PREFIX=$PREFIX WEB_COUNT=$WEB_COUNT APP_PORT=$APP_PORT GREETING=$GREETING"
  echo "ZONE_A=$ZONE_A CIDR_A=$CIDR_A ZONE_B=$ZONE_B CIDR_B=$CIDR_B"
  exit 0
fi

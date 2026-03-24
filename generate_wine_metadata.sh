#!/usr/bin/env bash

OUTPUT_FILE="wine_metadata.json"
TEMP_DIR="/tmp/wine_metadata_$$"
mkdir -p "$TEMP_DIR"

# Выводит сообщение с временной меткой в stderr
# Аргументы: $1 - текст сообщения
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

# Удаляет временную директорию при завершении скрипта
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Получает все релизы из GitHub репозитория с поддержкой пагинации
# Аргументы:
#   $1 - репозиторий в формате "owner/repo"
#   $2 - путь к выходному JSON файлу
#   $3 - (опционально) regex-паттерн для остановки загрузки (релиз с паттерном не включается)
fetch_github_releases() {
    local repo="$1"
    local output_file="$2"
    local stop_pattern="${3:-}"

    log "Получение релизов из $repo..."

    local page=1
    local per_page=100
    local all_releases="[]"
    local should_stop=false

    while true; do
        local url="https://api.github.com/repos/$repo/releases?per_page=${per_page}&page=${page}"
        local temp_file="$TEMP_DIR/page_${page}.json"

        if ! curl -s -H "Accept: application/vnd.github.v3+json" "$url" > "$temp_file"; then
            log "Ошибка при получении релизов для $repo (страница $page)"
            return 1
        fi

        local page_count=$(jq '. | length' "$temp_file" 2>/dev/null || echo "0")

        if [[ "$page_count" -eq 0 ]]; then
            rm -f "$temp_file"
            break
        fi

        if [[ -n "$stop_pattern" ]]; then
            local filtered_releases=$(jq --arg pattern "$stop_pattern" '
                . as $releases |
                (map(.tag_name) | to_entries | map(select(.value | test($pattern; "i"))) | .[0].key // -1) as $stop_idx |
                if $stop_idx >= 0 then
                    $releases[0:$stop_idx]
                else
                    $releases
                end
            ' "$temp_file")

            local filtered_count=$(echo "$filtered_releases" | jq 'length')
            all_releases=$(echo "$all_releases" "$filtered_releases" | jq -s '.[0] + .[1]')

            if [[ "$filtered_count" -lt "$page_count" ]]; then
                log "Достигнут стоп-паттерн '$stop_pattern' на странице $page"
                should_stop=true
            fi
        else
            all_releases=$(echo "$all_releases" | jq --slurpfile page "$temp_file" '. + $page[0]')
        fi

        rm -f "$temp_file"
        log "  Страница $page: $page_count релизов"

        if [[ "$should_stop" == "true" ]] || [[ "$page_count" -lt "$per_page" ]]; then
            break
        fi

        ((page++))
    done

    echo "$all_releases" > "$output_file"

    local count=$(jq '. | length' "$output_file" 2>/dev/null || echo "0")
    log "Получено данных для $repo: $count релизов (всего страниц: $page)"
}

# Преобразует JSON с релизами GitHub в записи wine с именем, URL и размером
# Аргументы:
#   $1 - путь к входному JSON файлу с релизами
#   $2 - regex расширения файла для фильтрации ассетов (например "\\.tar\\.gz$")
#   $3 - (опционально) regex-паттерн для исключения ассетов по имени
create_wine_entries() {
    local input_file="$1"
    local file_extension="$2"
    local exclude_patterns="$3"

    jq --arg ext "$file_extension" '
        def human_size:
          if . == 0 then "0 B"
          elif . < 1024 then "\(.).0 B"
          elif . < 1024*1024 then "\((./1024)|floor).\( ((./1024 * 10 % 10)|floor)) KiB"
          elif . < 1024*1024*1024 then "\((./(1024*1024))|floor).\( ((./(1024*1024) * 10 % 10)|floor)) MiB"
          elif . < 1024*1024*1024*1024 then "\((./(1024*1024*1024))|floor).\( ((./(1024*1024*1024) * 10 % 10)|floor)) GiB"
          else "\((./(1024*1024*1024*1024))|floor).\( ((./(1024*1024*1024*1024) * 10 % 10)|floor)) TiB"
          end;

        .[] |
        .assets[] |
        select(.browser_download_url | test($ext)) |
        {
            name: (.name | gsub($ext; "")),
            url: .browser_download_url,
            size_human: (.size | human_size)
        }
    ' "$input_file" | \
    if [[ -n "$exclude_patterns" ]]; then
        jq -c --arg patterns "$exclude_patterns" '
            select(.name | test($patterns) | not)
        '
    else
        jq -c '.'
    fi
}

# Получает список доступных в облаке сборок Linux Gaming для proton_lg секции.
# Оставляет только ожидаемые типы и версии >= 8, чтобы не включать ломающие префикс версии.
fetch_cloud_lg_allowlist() {
    local output_file="$1"
    local cloud_url="https://cloud.linux-gaming.ru/"

    log "Получение списка PROTON/WINE LG из $cloud_url..."

    if ! curl -fsSL "$cloud_url" | \
        grep -oE "portproton/(PROTON_LG|WINE_LG|PROTON_STEAM|WINE_HYP)_[^'\"<>]+\\.tar\\.xz" | \
        sed -E 's#^portproton/##; s#\.tar\.xz$##' | \
        grep -E "_(8|9|[1-9][0-9])([.-]|$)" | \
        sort -u > "$output_file"; then
        log "Ошибка при получении списка версий с $cloud_url"
        return 1
    fi

    local count
    count=$(wc -l < "$output_file" | tr -d ' ')
    log "Получено версий из cloud для proton_lg: $count"
}

log "Начало генерации метаданных..."

# PROTON_GE
fetch_github_releases "GloriousEggroll/proton-ge-custom" "$TEMP_DIR/proton_ge_releases.json" "GE-Proton7-"
create_wine_entries "$TEMP_DIR/proton_ge_releases.json" "\\.tar\\.gz$" "github-action" > "$TEMP_DIR/proton_ge.json"

# WINE_KRON4EK
fetch_github_releases "Kron4ek/Wine-Builds" "$TEMP_DIR/wine_kron4ek_releases.json" "^7\\."
create_wine_entries "$TEMP_DIR/wine_kron4ek_releases.json" "\\.tar\\.xz$" "-x86" > "$TEMP_DIR/wine_kron4ek.json"

# PROTON_LG
fetch_github_releases "Castro-Fidel/wine_builds" "$TEMP_DIR/proton_lg_releases.json"
fetch_cloud_lg_allowlist "$TEMP_DIR/cloud_lg_allowlist.txt"
jq -R -s 'split("\n") | map(select(length > 0))' "$TEMP_DIR/cloud_lg_allowlist.txt" > "$TEMP_DIR/cloud_lg_allowlist.json"
create_wine_entries "$TEMP_DIR/proton_lg_releases.json" "\\.tar\\.xz$" "plugins" | \
    jq -c '
        # Защитный regex: только нужные семейства и только версии >=8.
        select(.name | test("^(PROTON_LG|WINE_LG|PROTON_STEAM|WINE_HYP)_(8|9|[1-9][0-9])([.-]|$)"))
    ' | \
    jq -c --slurpfile allow "$TEMP_DIR/cloud_lg_allowlist.json" '
        # Финальный фильтр: в JSON остаются только версии, реально присутствующие в cloud.
        select(.name as $name | ($allow[0] | index($name)) != null)
    ' > "$TEMP_DIR/proton_lg.json"

# PROTON_CACHYOS
fetch_github_releases "CachyOS/proton-cachyos" "$TEMP_DIR/proton_cachyos_releases.json"
create_wine_entries "$TEMP_DIR/proton_cachyos_releases.json" "\\.tar\\.xz$" "znver" > "$TEMP_DIR/proton_cachyos.json"

# PROTON_SAREK
fetch_github_releases "pythonlover02/Proton-Sarek" "$TEMP_DIR/proton_sarek_releases.json"
create_wine_entries "$TEMP_DIR/proton_sarek_releases.json" "\\.tar\\.gz$" "" > "$TEMP_DIR/proton_sarek.json"

# PROTON_EM
fetch_github_releases "Etaash-mathamsetty/Proton" "$TEMP_DIR/proton_em_releases.json"
create_wine_entries "$TEMP_DIR/proton_em_releases.json" "\\.tar\\.xz$" "" > "$TEMP_DIR/proton_em.json"

# GDK_PROTON
fetch_github_releases "Weather-OS/GDK-Proton" "$TEMP_DIR/gdk_proton_releases.json"
create_wine_entries "$TEMP_DIR/gdk_proton_releases.json" "\\.tar\\.gz$" "" > "$TEMP_DIR/gdk_proton.json"

# Создание итогового JSON файла
log "Создание итогового JSON файла..."

{
    cat << 'JSON_START'
{
  "proton_ge": [
JSON_START

    if [[ -s "$TEMP_DIR/proton_ge.json" ]]; then
        sed '$!s/$/,/' "$TEMP_DIR/proton_ge.json" | sed 's/^/    /'
    fi

    cat << 'JSON_CONTINUE'
  ],
  "wine_kron4ek": [
JSON_CONTINUE

    if [[ -s "$TEMP_DIR/wine_kron4ek.json" ]]; then
        sed '$!s/$/,/' "$TEMP_DIR/wine_kron4ek.json" | sed 's/^/    /'
    fi

    cat << 'JSON_CONTINUE2'
  ],
  "proton_lg": [
JSON_CONTINUE2

    if [[ -s "$TEMP_DIR/proton_lg.json" ]]; then
        sed '$!s/$/,/' "$TEMP_DIR/proton_lg.json" | sed 's/^/    /'
    fi

    cat << 'JSON_CONTINUE4'
  ],
  "proton_cachyos": [
JSON_CONTINUE4

    if [[ -s "$TEMP_DIR/proton_cachyos.json" ]]; then
        sed '$!s/$/,/' "$TEMP_DIR/proton_cachyos.json" | sed 's/^/    /'
    fi

    cat << 'JSON_CONTINUE5'
  ],
  "proton_sarek": [
JSON_CONTINUE5

    if [[ -s "$TEMP_DIR/proton_sarek.json" ]]; then
        sed '$!s/$/,/' "$TEMP_DIR/proton_sarek.json" | sed 's/^/    /'
    fi

    cat << 'JSON_CONTINUE6'
  ],
  "proton_em": [
JSON_CONTINUE6

    if [[ -s "$TEMP_DIR/proton_em.json" ]]; then
        sed '$!s/$/,/' "$TEMP_DIR/proton_em.json" | sed 's/^/    /'
    fi

    cat << 'JSON_CONTINUE7'
  ],
  "gdk_proton": [
JSON_CONTINUE7

    if [[ -s "$TEMP_DIR/gdk_proton.json" ]]; then
        sed '$!s/$/,/' "$TEMP_DIR/gdk_proton.json" | sed 's/^/    /'
    fi

    cat << 'JSON_END'
  ]
}
JSON_END

} > "$OUTPUT_FILE"

if jq empty "$OUTPUT_FILE" 2>/dev/null; then
    log "JSON файл создан успешно и валиден: $OUTPUT_FILE"
else
    log "ОШИБКА: Созданный JSON файл невалиден!"
    exit 1
fi

echo
log "Статистика созданного файла:"
for category in proton_ge wine_kron4ek proton_lg proton_cachyos proton_sarek proton_em gdk_proton; do
    count=$(jq -r ".${category} | length" "$OUTPUT_FILE" 2>/dev/null || echo "0")
    log "  $category: $count версий"
done

log "Генерация метаданных завершена: $OUTPUT_FILE"

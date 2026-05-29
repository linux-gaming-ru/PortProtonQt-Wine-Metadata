#!/usr/bin/env bash
set -euo pipefail

OUTPUT_FILE="macos_wine_metadata.json"
TEMP_DIR="/tmp/macos_wine_metadata_$$"
mkdir -p "$TEMP_DIR"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >&2
}

cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

fetch_github_releases() {
    local repo="$1"
    local output_file="$2"

    log "Получение релизов из $repo..."

    local page=1
    local per_page=100
    local all_releases="[]"

    while true; do
        local url="https://api.github.com/repos/$repo/releases?per_page=${per_page}&page=${page}"
        local temp_file="$TEMP_DIR/page_${page}.json"

        if ! curl -fsSL -H "Accept: application/vnd.github.v3+json" "$url" > "$temp_file"; then
            log "Ошибка при получении релизов для $repo (страница $page)"
            return 1
        fi

        local page_count
        page_count=$(jq '. | length' "$temp_file" 2>/dev/null || echo "0")

        if [[ "$page_count" -eq 0 ]]; then
            rm -f "$temp_file"
            break
        fi

        all_releases=$(echo "$all_releases" | jq --slurpfile page "$temp_file" '. + $page[0]')
        rm -f "$temp_file"

        log "  Страница $page: $page_count релизов"

        if [[ "$page_count" -lt "$per_page" ]]; then
            break
        fi

        ((page++))
    done

    echo "$all_releases" > "$output_file"

    local count
    count=$(jq '. | length' "$output_file" 2>/dev/null || echo "0")
    log "Получено данных для $repo: $count релизов (всего страниц: $page)"
}

create_macos_wine_entries() {
    local input_file="$1"

    jq -c '
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
        select(.browser_download_url | test("\\.(tar\\.xz|tar\\.gz|tgz|zip|7z|dmg)$"; "i")) |
        {
            name: (.name | sub("\\.(tar\\.xz|tar\\.gz|tgz|zip|7z|dmg)$"; ""; "i")),
            url: .browser_download_url,
            size_human: (.size | human_size)
        }
    ' "$input_file"
}

log "Начало генерации macOS метаданных..."

fetch_github_releases "Heroic-Games-Launcher/wine-crossover" "$TEMP_DIR/wine_crossover_releases.json"
create_macos_wine_entries "$TEMP_DIR/wine_crossover_releases.json" > "$TEMP_DIR/wine_crossover.json"

fetch_github_releases "Gcenx/macOS_Wine_builds" "$TEMP_DIR/wine_staging_macos_releases.json"
create_macos_wine_entries "$TEMP_DIR/wine_staging_macos_releases.json" > "$TEMP_DIR/wine_staging_macos.json"

fetch_github_releases "Sikarugir-App/Engines" "$TEMP_DIR/sikarugir_engines_releases.json"
create_macos_wine_entries "$TEMP_DIR/sikarugir_engines_releases.json" > "$TEMP_DIR/sikarugir_engines.json"

fetch_github_releases "Gcenx/game-porting-toolkit" "$TEMP_DIR/game_porting_toolkit_releases.json"
create_macos_wine_entries "$TEMP_DIR/game_porting_toolkit_releases.json" > "$TEMP_DIR/game_porting_toolkit.json"

log "Создание итогового JSON файла..."

{
    cat << 'JSON_START'
{
  "wine-crossover": [
JSON_START

    if [[ -s "$TEMP_DIR/wine_crossover.json" ]]; then
        sed '$!s/$/,/' "$TEMP_DIR/wine_crossover.json" | sed 's/^/    /'
    fi

    cat << 'JSON_CONTINUE'
  ],
  "wine-staging-macos": [
JSON_CONTINUE

    if [[ -s "$TEMP_DIR/wine_staging_macos.json" ]]; then
        sed '$!s/$/,/' "$TEMP_DIR/wine_staging_macos.json" | sed 's/^/    /'
    fi

    cat << 'JSON_CONTINUE2'
  ],
  "sikarugir-engines": [
JSON_CONTINUE2

    if [[ -s "$TEMP_DIR/sikarugir_engines.json" ]]; then
        sed '$!s/$/,/' "$TEMP_DIR/sikarugir_engines.json" | sed 's/^/    /'
    fi

    cat << 'JSON_CONTINUE3'
  ],
  "game-porting-toolkit": [
JSON_CONTINUE3

    if [[ -s "$TEMP_DIR/game_porting_toolkit.json" ]]; then
        sed '$!s/$/,/' "$TEMP_DIR/game_porting_toolkit.json" | sed 's/^/    /'
    fi

    cat << 'JSON_END'
  ]
}
JSON_END
} > "$OUTPUT_FILE"

jq empty "$OUTPUT_FILE"
log "Генерация завершена: $OUTPUT_FILE"

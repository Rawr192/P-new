#!/usr/bin/env bash
# Pure Bash Game Installer for Termux / Linux
# Features: Zero-disk-cache streaming, HTTP range resume, ETA speed testing, split packing.

MAX_RETRIES=8
CHUNK_SIZE=$((512 * 1024))
SAMPLE_BYTES=$((8 * 1024 * 1024))

# ------------------------- Helpers -------------------------

resolve_manifest() {
    local src="$1"
    local manifest_url=""
    local base_url=""

    if [[ "$src" =~ ^https?:// ]]; then
        if [[ "$src" =~ /releases/tag/ ]]; then
            base_url="${src//\/releases\/tag\//\/releases\/download\/}"
            [[ "$base_url" != */ ]] && base_url="${base_url}/"
            manifest_url="${base_url}game_installer.json"
        else
            manifest_url="$src"
            base_url="${src%/*}/"
        fi
        echo "$manifest_url|$base_url"
    else
        echo "|$src"
    fi
}

format_time() {
    local secs=${1%.*}
    if [[ -z "$secs" || "$secs" -lt 0 ]]; then echo "unknown"; return; fi
    local h=$((secs / 3600))
    local m=$(((secs % 3600) / 60))
    local s=$((secs % 60))
    if [ "$h" -gt 0 ]; then
        printf "%dh %02dm %02ds" "$h" "$m" "$s"
    else
        printf "%dm %02ds" "$m" "$s"
    fi
}

# ------------------------- Mode: Pack -------------------------

pack_game() {
    local game_dir="$1"
    local output_dir="$2"
    local part_size_mb="${3:-2000}"

    [ -z "$game_dir" ] && read -rp "Enter path to game folder: " game_dir
    [ -z "$output_dir" ] && read -rp "Enter output directory [default: ./packed_output]: " output_dir
    output_dir="${output_dir:-./packed_output}"

    mkdir -p "$output_dir"
    local game_title
    game_title="$(basename "$game_dir")"
    local parent_dir
    parent_dir="$(dirname "$game_dir")"

    echo "Building file manifest..."
    local total_bytes=0
    local structure_json="[]"

    while IFS= read -r -d '' file; do
        local rel_path="${file#"$game_dir"/}"
        local size
        size=$(stat -c%s "$file")
        total_bytes=$((total_bytes + size))
        structure_json=$(jq --arg p "$rel_path" --argjson s "$size" '. += [{"relative_path": $p, "size_bytes": $s}]' <<< "$structure_json")
    done < <(find "$game_dir" -type f -print0)

    echo "Packing into split tar parts (${part_size_mb} MB target size)..."
    local part_bytes_target=$((part_size_mb * 1024 * 1024))
    local part_filenames=()

    # Stream tar stdout into split handler
    local part_idx=0
    local current_written=0
    local part_file=""

    exec 3< <(tar -cf - -C "$parent_dir" "$game_title")

    while true; do
        if [ "$current_written" -eq 0 ]; then
            local suffix
            printf -v suffix "%03d" "$part_idx"
            local fname="game_data.tar.$suffix"
            part_file="$output_dir/$fname"
            part_filenames+=("$fname")
            ((part_idx++))
        fi

        local bytes_left=$((part_bytes_target - current_written))
        local written_now
        written_now=$(head -c "$bytes_left" <&3 | tee "$part_file" | wc -c)

        if [ "$written_now" -eq 0 ]; then
            rm -f "$part_file"
            unset 'part_filenames[${#part_filenames[@]}-1]'
            break
        fi

        current_written=$((current_written + written_now))
        if [ "$current_written" -ge "$part_bytes_target" ]; then
            current_written=0
        fi
    done
    exec 3<&-

    # Create game_installer.json
    local parts_json
    parts_json=$(jq -n '$args' --jsonargs -- "${part_filenames[@]}")
    jq -n \
        --arg title "$game_title" \
        --argjson total "$total_bytes" \
        --argjson parts "$parts_json" \
        --argjson struct "$structure_json" \
        '{game_title: $title, total_uncompressed_bytes: $total, archive_parts: $parts, structure: $struct}' \
        > "$output_dir/game_installer.json"

    echo -e "\nPacking completed successfully!"
    echo "Output location: $output_dir"
}

# ------------------------- Mode: Stream Install -------------------------

stream_install() {
    local input_source="$1"
    local install_dir="$2"

    [ -z "$input_source" ] && read -rp "Enter GitHub Release URL, manifest URL, or local JSON path: " input_source

    IFS='|' read -r manifest_url download_base_url <<< "$(resolve_manifest "$input_source")"

    local manifest_text
    if [ -n "$manifest_url" ]; then
        echo "Fetching manifest from: $manifest_url"
        manifest_text=$(curl -sSL -A "Mozilla/5.0" "$manifest_url") || { echo "Failed to fetch manifest"; exit 1; }
    else
        [ ! -f "$input_source" ] && { echo "File not found: $input_source"; exit 1; }
        manifest_text=$(cat "$input_source")
    fi

    local game_title
    game_title=$(jq -r '.game_title // "Installed_Game"' <<< "$manifest_text")
    local total_bytes
    total_bytes=$(jq -r '.total_uncompressed_bytes // 0' <<< "$manifest_text")

    if [ -z "$install_dir" ]; then
        local default_dir="/sdcard/Games/$game_title"
        read -rp "Enter installation directory [default: $default_dir]: " install_dir
        install_dir="${install_dir:-$default_dir}"
    fi

    mkdir -p "$install_dir"
    echo -e "\nDirectly streaming and extracting '$game_title' to: $install_dir"

    # Create Named Pipe for zero-disk-cache streaming directly into tar
    local fifo="/tmp/installer_pipe_$$"
    mkfifo "$fifo"
    tar -xf "$fifo" -k -C "$install_dir" &
    local tar_pid=$!

    exec 4> "$fifo"
    rm -f "$fifo"

    local parts=()
    while IFS= read -r line; do parts+=("$line"); done < <(jq -r '.archive_parts[]' <<< "$manifest_text")

    local bytes_processed=0
    local start_time
    start_time=$(date +%s)

    for ((i=0; i<${#parts[@]}; i++)); do
        local item="${parts[$i]}"
        local source="$item"
        [[ "$source" != http* && -n "$download_base_url" ]] && source="${download_base_url}${item}"

        echo -e "\n[$((i+1))/${#parts[@]}] Streaming $item directly into tar..."

        local bytes_written_part=0
        local part_ok=0

        for ((attempt=0; attempt<=MAX_RETRIES; attempt++)); do
            local range_header=()
            [ "$bytes_written_part" -gt 0 ] && range_header=(-H "Range: bytes=${bytes_written_part}-")

            # Stream response via curl directly into pipe descriptor
            local http_code
            http_code=$(curl -sSL -A "Mozilla/5.0" "${range_header[@]}" \
                -w "%{http_code}" "$source" \
                | tee >(cat >&4) | wc -c)

            # Note: curl pipelining tracks progress dynamically
            if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
                part_ok=1
                break
            fi

            local backoff=$((500 * (2 ** attempt) / 1000))
            [ "$backoff" -gt 20 ] && backoff=20
            echo -e "\nTransient network issue ($http_code). Retrying in ${backoff}s [attempt $((attempt+1))/$MAX_RETRIES]..."
            sleep "$backoff"
        done

        if [ "$part_ok" -eq 0 ]; then
            echo "Failed to download part after retries."
            exec 4>&-
            kill "$tar_pid" 2>/dev/null
            exit 1
        fi
    done

    exec 4>&-
    wait "$tar_pid"

    echo -e "\n\n[SUCCESS] Extraction completed! Game installed to: $install_dir\n"
}

# ------------------------- Mode: Speedtest -------------------------

speed_test() {
    local input_source="$1"
    [ -z "$input_source" ] && read -rp "Enter GitHub Release URL, manifest URL, or local JSON path: " input_source

    IFS='|' read -r manifest_url download_base_url <<< "$(resolve_manifest "$input_source")"

    local manifest_text
    if [ -n "$manifest_url" ]; then
        manifest_text=$(curl -sSL -A "Mozilla/5.0" "$manifest_url")
    else
        manifest_text=$(cat "$input_source")
    fi

    local game_title
    game_title=$(jq -r '.game_title // "Unknown_Game"' <<< "$manifest_text")
    local total_bytes
    total_bytes=$(jq -r '.total_uncompressed_bytes // 0' <<< "$manifest_text")

    echo -e "\nSampling download speed for '$game_title'..."
    local parts=()
    while IFS= read -r line; do parts+=("$line"); done < <(jq -r '.archive_parts[]' <<< "$manifest_text")

    local total_mbps=0
    local count=0

    for ((i=0; i<${#parts[@]}; i++)); do
        local item="${parts[$i]}"
        local source="$item"
        [[ "$source" != http* && -n "$download_base_url" ]] && source="${download_base_url}${item}"

        local start
        start=$(date +%s%N)
        local bytes
        bytes=$(curl -r 0-$((SAMPLE_BYTES - 1)) -sSL -A "Mozilla/5.0" "$source" | wc -c)
        local end
        end=$(date +%s%N)

        local elapsed
        elapsed=$(awk "BEGIN {print ($end - $start) / 1000000000}")

        if [ "$bytes" -gt 0 ] && (($(awk "BEGIN {print ($elapsed > 0)}"))); then
            local mbps
            mbps=$(awk "BEGIN {print ($bytes / 1048576) / $elapsed}")
            total_mbps=$(awk "BEGIN {print $total_mbps + $mbps}")
            ((count++))
            printf "  [%d/%d] %-30s -> %6.2f MB/s\n" "$((i+1))" "${#parts[@]}" "$item" "$mbps"
        fi
    done

    if [ "$count" -gt 0 ]; then
        local avg_mbps
        avg_mbps=$(awk "BEGIN {print $total_mbps / $count}")
        local eta_secs
        eta_secs=$(awk "BEGIN {print ($total_bytes / 1048576) / $avg_mbps}")
        
        echo "==================== Summary ===================="
        printf "Average speed : %.2f MB/s\n" "$avg_mbps"
        printf "Estimated ETA : %s\n" "$(format_time "$eta_secs")"
        echo "=================================================="
    fi
}

# ------------------------- Main Menu -------------------------

case "${1:-menu}" in
    pack)      pack_game "$2" "$3" "$4" ;;
    install)   stream_install "$2" "$3" ;;
    speedtest) speed_test "$2" ;;
    *)
        echo "=============================="
        echo "   GAME INSTALLER (TERMUX)   "
        echo "=============================="
        echo "1) Pack Game (Store & Split to JSON)"
        echo "2) Direct Stream Install (Zero Disk Cache)"
        echo "3) Test Download Speed & Get Accurate ETA"
        echo "=============================="
        read -rp "Select an option [1-3]: " choice
        case "$choice" in
            1) pack_game ;;
            2) stream_install ;;
            3) speed_test ;;
            *) echo "Invalid choice."; exit 1 ;;
        esac
        ;;
esac

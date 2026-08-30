#!/bin/bash

# Thumbnail generator script
# Takes a directory or file as argument and generates thumbnails for all video files

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [--verbose] <directory|file> [<directory|file> ...]"
    exit 1
fi

# Parse flags and collect targets
VERBOSE=0
TARGETS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verbose)
            VERBOSE=1
            shift
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                TARGETS+=("$1")
                shift
            done
            ;;
        -*)
            echo "Unknown option: $1" >&2
            exit 1
            ;;
        *)
            TARGETS+=("$1")
            shift
            ;;
    esac
done

# Resolve to absolute path if possible
resolve_path() {
    local p="$1"
    # Expand leading ~ to $HOME
    if [[ "$p" == ~* ]]; then
        p="${p/#~/$HOME}"
    fi

    if [[ -e "$p" ]]; then
        readlink -f -- "$p" 2>/dev/null || printf "%s" "$p"
    elif [[ "$p" != /* ]]; then
        printf "%s" "$PWD/$p"
    else
        printf "%s" "$p"
    fi
}

# Ensure we have at least one target
if [[ ${#TARGETS[@]} -eq 0 ]]; then
    echo "Usage: $0 [--verbose] <directory|file> [<directory|file> ...]"
    exit 1
fi

# Safer pipeline behavior
set -o pipefail

# Check for required commands
check_deps() {
    local missing=()
    for cmd in ffmpeg ffprobe awk; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing+=("$cmd")
        fi
    done

    if [[ ${#missing[@]} -ne 0 ]]; then
        echo "Error: missing required commands: ${missing[*]}"
        echo "Please install them (eg. sudo apt install ffmpeg)" >&2
        exit 2
    fi
}

check_deps

# Video extensions whitelist (lowercase)
VIDEO_EXTENSIONS=("mkv" "mp4" "mov" "avi" "flv" "wmv" "webm" "m4v" "mpg" "mpeg" "3gp")

# Return 0 if the given file's extension is in the whitelist, else non-zero
is_video_file() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    local ext="${f##*.}"
    ext="${ext,,}"
    for e in "${VIDEO_EXTENSIONS[@]}"; do
        if [[ "$ext" == "$e" ]]; then
            return 0
        fi
    done
    return 1
}

# Colors and emojis for nicer output (only when stdout is a TTY)
if [[ -t 1 ]]; then
    RED="\033[0;31m"
    GREEN="\033[0;32m"
    YELLOW="\033[0;33m"
    BLUE="\033[0;34m"
    BOLD="\033[1m"
    RESET="\033[0m"
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    BOLD=""
    RESET=""
fi

EMOJI_OK="✅"
EMOJI_FAIL="❌"

# Counters
CREATED=0
SKIPPED=0
FAILED=0
TOTAL=0

# Print summary
print_summary() {
    printf "\n%bProcessed %d files:%b generated %d, skipped %d, failed %d\n" "$BOLD" "$TOTAL" "$RESET" "$CREATED" "$SKIPPED" "$FAILED"
}
# Function to generate thumbnail for a single video file
generate_thumbnail() {
    local video_file="$1"
    local filename="${video_file%.*}"
    local thumbnail="${filename}-backdrop.jpg"

    # Check if thumbnail already exists
    if [[ -f "$thumbnail" ]]; then
        ((SKIPPED++))
        if [[ $VERBOSE -eq 1 ]]; then
            echo "Thumbnail already exists: $thumbnail"
        fi
        return
    fi

    # Verbose info about what will be processed
    if [[ $VERBOSE -eq 1 ]]; then
        echo "Processing: $video_file"
        echo "Will write thumbnail: $thumbnail"
    fi
    # Print a single-line progress indicator (will append Done/Failed)
    printf "%bGenerating %s...%b" "$BLUE$BOLD" "$(basename "$thumbnail")" "$RESET"

    # Get video duration in seconds
    local duration
    duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$video_file" 2>/dev/null)

    # If duration cannot be read, skip this file
    if [[ -z "$duration" ]] || ! [[ "$duration" =~ ^[0-9]+\.?[0-9]*$ ]]; then
        ((SKIPPED++))
        printf " %bSkipped%b\n" "$YELLOW$BOLD" "$RESET"
        echo "Warning: Could not read duration for $video_file, skipping" >&2
        return
    fi

    # Calculate random timestamp (between 10% and 90% of the video)
    local start=$(awk -v dur="$duration" 'BEGIN { printf "%.2f", dur * 0.1 }')
    local end=$(awk -v dur="$duration" 'BEGIN { printf "%.2f", dur * 0.9 }')
    local random_time=$(awk -v start="$start" -v end="$end" 'BEGIN { srand(); printf "%.2f", start + (rand() * (end - start)) }')

    # Generate thumbnail using ffmpeg (silent unless an error occurs)
    local errfile
    errfile=$(mktemp) || errfile="/tmp/thumber_err.$$"
    if ffmpeg -ss "$random_time" -i "$video_file" -vframes 1 "$thumbnail" > /dev/null 2> "$errfile"; then
        # Confirm the thumbnail file actually exists
        if [[ -f "$thumbnail" ]]; then
            ((CREATED++))
            printf "%b %bDone%b\n" "$EMOJI_OK" "$GREEN$BOLD" "$RESET"
            if [[ $VERBOSE -eq 1 ]]; then
                echo "Created: $thumbnail"
            fi
            rm -f "$errfile"
        else
            ((FAILED++))
            printf "%b %bFailed (no output file)%b\n" "$EMOJI_FAIL" "$RED$BOLD" "$RESET" >&2
            echo "ffmpeg reported success but thumbnail not found: $thumbnail" >&2
            if [[ -s "$errfile" ]]; then
                echo "ffmpeg messages:" >&2
                cat "$errfile" >&2
            fi
            rm -f "$errfile"
            echo "Error: Failed to generate thumbnail for $video_file" >&2
        fi
    else
        ((FAILED++))
        printf "%b %bFailed%b\n" "$EMOJI_FAIL" "$RED$BOLD" "$RESET" >&2
        echo "ffmpeg error for $video_file:" >&2
        cat "$errfile" >&2
        rm -f "$errfile"
        echo "Error: Failed to generate thumbnail for $video_file" >&2
    fi
}

# Function to process all video files in a directory
process_directory() {
    local dir="$1"
    local count=0
    # Recursively find files matching the whitelist using a single find command (null-safe)
    local find_expr=()
    for ext in "${VIDEO_EXTENSIONS[@]}"; do
        find_expr+=( -iname "*.$ext" -o )
    done
    # remove trailing -o
    unset 'find_expr[${#find_expr[@]}-1]'

    while IFS= read -r -d '' file; do
        [[ -f "$file" ]] || continue
        ((TOTAL++))
        generate_thumbnail "$file"
        ((count++))
    done < <(find "$dir" -type f \( "${find_expr[@]}" \) -print0 2>/dev/null)

    if [[ $VERBOSE -eq 1 ]]; then
        echo "Processed $count files in $dir (recursive)"
    elif [[ $count -eq 0 ]]; then
        echo "No video files found in: $dir"
    fi
}

# Main logic: collect files first, then process them in a single loop
FILES=()
declare -A seen=()

for raw in "${TARGETS[@]}"; do
    target=$(resolve_path "$raw")

    if [[ -f "$target" ]]; then
        # Explicit file target: count it and act accordingly
        ((TOTAL++))
        if is_video_file "$target"; then
            # deduplicate
            if [[ -z "${seen[$target]}" ]]; then
                seen[$target]=1
                FILES+=("$target")
            fi
        else
            ((SKIPPED++))
            echo "Skipping non-video file (explicit arg): $target"
        fi
    elif [[ -d "$target" ]]; then
        # Directory: gather matching video files silently
        find_expr=()
        for ext in "${VIDEO_EXTENSIONS[@]}"; do
            find_expr+=( -iname "*.$ext" -o )
        done
        unset 'find_expr[${#find_expr[@]}-1]'

        while IFS= read -r -d '' file; do
            [[ -f "$file" ]] || continue
            file=$(readlink -f -- "$file" 2>/dev/null || printf "%s" "$file")
            if [[ -z "${seen[$file]}" ]]; then
                seen[$file]=1
                FILES+=("$file")
                ((TOTAL++))
            fi
        done < <(find "$target" -type f \( "${find_expr[@]}" \) -print0 2>/dev/null)
    else
        echo "Error: '$raw' is not a valid file or directory" >&2
        ((FAILED++))
        continue
    fi
done

# Process collected files (videos only)
for file in "${FILES[@]}"; do
    generate_thumbnail "$file"
done

print_summary

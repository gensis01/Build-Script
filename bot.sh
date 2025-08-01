#!/bin/bash
set -o pipefail

# --- Configuration & Constants ---

# Load configuration
if [ -f "config.env" ]; then
    source "config.env"
else
    echo "Error: config.env not found." >&2
    exit 1
fi

# Handle device codename
if [[ -z "$CONFIG_DEVICE" ]]; then
    read -p "Enter the device codename: " DEVICE
    if [[ -z "$DEVICE" ]]; then
        echo "ERROR: Device codename not provided." >&2
        exit 1
    fi
else
    DEVICE="$CONFIG_DEVICE"
fi

# Script Constants
YELLOW=$(tput setaf 3)
BOLD=$(tput bold)
RESET=$(tput sgr0)
BOLD_GREEN=${BOLD}$(tput setaf 2)
RED=$(tput setaf 1)
OFFICIAL="0"
ROOT_DIRECTORY="$(pwd)"

# Post Constants
ROM_NAME="$(sed "s#.*/##" <<<"$(pwd)")"
ANDROID_VERSION=$(grep -oP '(?<=android-)[0-9]+' .repo/manifests/default.xml | head -n1 || echo "N/A")
OUT_DIR="$ROOT_DIRECTORY/out/target/product/$DEVICE"
STICKER_URL="https://raw.githubusercontent.com/Weebo354342432/reimagined-enigma/main/update.webp"

# Random quotes for progress updates
QUOTES=(
    "Be patient, greatness takes time."
    "The build is cooking, hang in there!"
    "A moment of patience can prevent a great mistake."
    "The quieter you become, the more you are able to hear."
    "Stay calm, the magic is happening."
)

# --- Helper Functions ---

# Function to print error messages and exit
die() {
    echo -e "$RED\nERROR: $1$RESET\n"
    exit 1
}

# Function to calculate and format duration
get_duration() {
    local start_time=$1
    local end_time=$2
    local difference=$((end_time - start_time))
    local hours=$((difference / 3600))
    local minutes=$(((difference % 3600) / 60))
    local seconds=$((difference % 60))

    local duration=""
    if [[ $hours -gt 0 ]]; then
        duration="${hours} hour(s), "
    fi
    if [[ $minutes -gt 0 || $hours -gt 0 ]]; then
        duration="${duration}${minutes} minute(s) and "
    fi
    duration="${duration}${seconds} second(s)"
    echo "$duration"
}

# Function to edit the caption of a Telegram photo message
edit_caption() {
    local message="$1"
    local chat_id="$2"
    local message_id="$3"
    curl -s "https://api.telegram.org/bot$CONFIG_BOT_TOKEN/editMessageCaption" \
        -d chat_id="$chat_id" \
        -d "parse_mode=html" \
        -d "message_id=$message_id" \
        -d caption="$message" > /dev/null
}


# Function to send a sticker to Telegram
send_sticker() {
    local sticker_url="$1"
    local chat_id="$2"
    local sticker_file="$ROOT_DIRECTORY/sticker.webp"

    curl -sL "$sticker_url" -o "$sticker_file"

    curl -s "https://api.telegram.org/bot$CONFIG_BOT_TOKEN/sendSticker" \
        -F sticker="@$sticker_file" \
        -F chat_id="$chat_id" \
        -F "is_animated=false" \
        -F "is_video=false" > /dev/null

    rm -f "$sticker_file"
}

# --- Upload Function ---

# Function to upload a file to PixelDrain
upload_file_pd() {
    local file_path="$1"
    local response
    response=$(curl -s -T "$file_path" -u ":$CONFIG_PDUP_API" https://pixeldrain.com/api/file/)
    local hash
    hash=$(echo "$response" | grep -Po '(?<="id":")[^"]*')

    if [[ -n "$hash" ]]; then
        echo "https://pixeldrain.com/u/$hash"
    else
        echo "Upload failed"
    fi
}

upload_file_gofile() {
    FILE_UPLOAD_PATH="$1"
    GOFILE_SERVER=$(curl -s https://api.gofile.io/servers | grep -oP '"name":"\K[^"]+' | head -n 1)
    GOFILE_LINK=$(curl -F "file=@$FILE_UPLOAD_PATH" "https://${GOFILE_SERVER}.gofile.io/uploadFile" | grep -oP '"downloadPage":"\K[^"]+' | head -n 1) 2>&1

    if [[ -n "$GOFILE_LINK" ]]; then
        echo "$GOFILE_LINK"
    else
        echo "Upload failed"
    fi
}

# --- Build Functions ---

# Function to get build progress
fetch_progress() {
    local progress
    progress=$( \
        tail -n 30 "$ROOT_DIRECTORY/build.log" | \
            grep -Po '\d+% \d+/\d+' | \
            tail -n1 | \
            sed -e 's/ / (/; s/$/)/' \
    )

    if [ -z "$progress" ]; then
        echo "Initializing..."
    else
        echo "$progress"
    fi
}

# Function to generate a formatted Telegram message
generate_telegram_message() {
    local icon="$1"
    local title="$2"
    local details="$3"
    local footer="$4"

    local message="<b>$icon | $title</b>"

    if [[ -n "$details" ]]; then
        message+="\n\n$details"
    fi

    if [[ -n "$footer" ]]; then
        message+="\n\n<i>$footer</i>"
    fi

    echo -e "$message"
}

# --- Main Script ---

# CLI parameters parsing
while [[ $# -gt 0 ]]; do
    case $1 in
    -s | --sync) SYNC="1" ;;
    -c | --clean) CLEAN="1" ;;
    -o | --official)
        if [ -n "$CONFIG_OFFICIAL_FLAG" ]; then
            OFFICIAL="1"
        else
            die "Official flag (CONFIG_OFFICIAL_FLAG) not set in configuration."
        fi
        ;;
    -h | --help)
        echo -e "\nNote: • You should specify all the mandatory variables in the script!"
        echo -e "      • Just run \"./$(basename "$0")\" for a normal build"
        echo -e "Usage: ./$(basename "$0") [OPTION]\n"
        echo -e "Options:"
        echo -e "    -s, --sync            Sync sources before building."
        echo -e "    -c, --clean           Clean build directory before compilation."
        echo -e "    -o, --official        Build the official variant."
        echo -e "    -h, --help            Show this help message.\n"
        exit 0
        ;;
    *)
        die "Unknown parameter(s) passed: $1"
        ;;
    esac
    shift
done

# Configuration Checking
if [[ -z "$CONFIG_TARGET" || -z "$CONFIG_BOT_TOKEN" || -z "$CONFIG_CHATID" ]]; then
    die "Please set all mandatory variables in config.env: CONFIG_TARGET, CONFIG_BOT_TOKEN, CONFIG_CHATID."
fi

# Set error chat ID to main chat ID if not specified
if [[ -z "$CONFIG_ERROR_CHATID" ]]; then
    CONFIG_ERROR_CHATID="$CONFIG_CHATID"
fi

# Cleanup old files
rm -f "out/error.log" "out/.lock" "$ROOT_DIRECTORY/build.log"

# Jobs Configuration
CORE_COUNT=$(nproc --all)
CONFIG_SYNC_JOBS=$((CORE_COUNT > 8 ? 12 : CORE_COUNT))
CONFIG_COMPILE_JOBS=$CORE_COUNT

# Sync sources if requested
if [[ -n "$SYNC" ]]; then
    echo -e "$BOLD_GREEN\nStarting to sync sources...$RESET\n"

    details="<b>• ROM:</b> <code>$ROM_NAME</code>\n<b>• DEVICE:</b> <code>$DEVICE</code>\n<b>• JOBS:</b> <code>$CONFIG_SYNC_JOBS Cores</code>"
    sync_start_message=$(generate_telegram_message "🟡" "Syncing sources..." "$details")
    sync_message_id=$(curl -s "https://api.telegram.org/bot$CONFIG_BOT_TOKEN/sendMessage" \
        -d chat_id="$CONFIG_CHATID" -d "parse_mode=html" -d text="$sync_start_message" | grep -o '"message_id":[0-9]*' | cut -d':' -f2)

    sync_start_time=$(date -u +%s)

    if ! repo sync -c --jobs-network="$CONFIG_SYNC_JOBS" -j"$CONFIG_SYNC_JOBS" --jobs-checkout="$CONFIG_SYNC_JOBS" --optimized-fetch --prune --force-sync --no-clone-bundle --no-tags; then
        echo -e "$YELLOW\nInitial sync failed. Retrying with fewer arguments...$RESET\n"
        if ! repo sync -j"$CONFIG_SYNC_JOBS"; then
            sync_end_time=0
            echo -e "$RED\nSync failed completely. Proceeding with build anyway...$RESET\n"
            sync_failed_message=$(generate_telegram_message "🔴" "Syncing sources failed!" "" "Proceeding with build...")
            curl -s "https://api.telegram.org/bot$CONFIG_BOT_TOKEN/editMessageText" -d chat_id="$CONFIG_CHATID" -d "parse_mode=html" -d "message_id=$sync_message_id" -d text="$sync_failed_message" > /dev/null
        else
            sync_end_time=$(date -u +%s)
        fi
    else
        sync_end_time=$(date -u +%s)
    fi

    if [[ "$sync_end_time" -ne 0 ]]; then
        duration=$(get_duration "$sync_start_time" "$sync_end_time")
        details="<b>• ROM:</b> <code>$ROM_NAME</code>\n<b>• DEVICE:</b> <code>$DEVICE</code>"
        sync_finished_message=$(generate_telegram_message "🟢" "Sources synced!" "$details" "Syncing took $duration.")
        curl -s "https://api.telegram.org/bot$CONFIG_BOT_TOKEN/editMessageText" -d chat_id="$CONFIG_CHATID" -d "parse_mode=html" -d "message_id=$sync_message_id" -d text="$sync_finished_message" > /dev/null
    fi
fi

# Clean out directory if requested
if [[ -n "$CLEAN" ]]; then
    echo -e "$BOLD_GREEN\nNuking the out directory...$RESET\n"
    rm -rf "out"
fi

# --- Build Process ---

# Fetch Maintainer Info from Git
CONFIG_MAINTAINER=$(git config --get user.name)
[ -z "$CONFIG_MAINTAINER" ] && CONFIG_MAINTAINER="Unknown"

# Get GitHub Avatar from GitHub API
GH_API_URL="https://api.github.com/users/$(echo "$CONFIG_MAINTAINER" | sed 's/ /%20/g')"
AVATAR_URL=$(curl -s "$GH_API_URL" | grep '"avatar_url"' | cut -d '"' -f4)
[ -z "$AVATAR_URL" ] && AVATAR_URL="https://avatars.githubusercontent.com/u/583231?v=4"

# Encode URL params
ENCODED_ROM_NAME=$(echo "$ROM_NAME" | sed 's/ /+/g')
ENCODED_DEVICE=$(echo "$DEVICE" | sed 's/ /+/g')
ENCODED_MAINTAINER=$(echo "$CONFIG_MAINTAINER" | sed 's/ /+/g')

# Generate OG image
OG_IMAGE_URL="https://ogpreview.servertronstar.org/api/generate?title=${ENCODED_ROM_NAME}&avatar=${AVATAR_URL}&theme=nightOwl&bio=Maintainer%3A+${ENCODED_MAINTAINER}+%7C+Device%3A+${ENCODED_DEVICE}"
OG_IMAGE_PATH="$ROOT_DIRECTORY/og_preview.png"
curl -sL "$OG_IMAGE_URL" -o "$OG_IMAGE_PATH"

BUILD_TYPE=$([ "$OFFICIAL" == "1" ] && echo "Official" || echo "Unofficial")

# Final Caption
OG_CAPTION="🔧 Build Started: <b>$ROM_NAME</b> for <b>$DEVICE</b> by <b>$CONFIG_MAINTAINER</b>

🟡 <i>Compiling ROM...</i>

<b>• ROM:</b> <code>$ROM_NAME</code>
<b>• DEVICE:</b> <code>$DEVICE</code>
<b>• ANDROID VERSION:</b> <code>$ANDROID_VERSION</code>
<b>• TYPE:</b> <code>$BUILD_TYPE</code>
<b>• PROGRESS:</b> <code>Initializing...</code>"

# Send Telegram Photo with Caption
RESPONSE=$(curl --silent -F photo=@"$OG_IMAGE_PATH" "https://api.telegram.org/bot$CONFIG_BOT_TOKEN/sendPhoto" \
  -F chat_id="$CONFIG_CHATID" \
  -F "parse_mode=HTML" \
  -F "caption=$OG_CAPTION")

# Extract message_id for future progress edit
build_message_id=$(echo "$RESPONSE" | grep -o '"message_id":[0-9]*' | cut -d':' -f2)

build_start_time=$(date -u +%s)

echo -e "$BOLD_GREEN\nSetting up build environment...$RESET"
source build/envsetup.sh

echo -e "$BOLD_GREEN\nRunning breakfast for \"$DEVICE\"...$RESET"
breakfast "$DEVICE"

if [ $? -ne 0 ]; then
    build_failed_caption="❌ <b>Build Failed:</b> <code>$ROM_NAME</code>
\n<i>Failed at running breakfast for $DEVICE.</i>"
    edit_caption "$build_failed_caption" "$CONFIG_CHATID" "$build_message_id"
    send_sticker "$STICKER_URL" "$CONFIG_CHATID"
    exit 1
fi

echo -e "$BOLD_GREEN\nStarting build... (Logs at build.log)$RESET"
m installclean -j"$CONFIG_COMPILE_JOBS"
m "$CONFIG_TARGET" -j"$CONFIG_COMPILE_JOBS" > "$ROOT_DIRECTORY/build.log" 2>&1 &

# Monitor build progress, update every 2 minutes
previous_progress=""
while jobs -r &>/dev/null; do
    current_progress=$(fetch_progress)
    
    # Show live progress in the terminal
    echo -ne "${YELLOW}Build progress: ${current_progress}${RESET}\r"
    
    if [[ "$current_progress" != "$previous_progress" && "$current_progress" != "Initializing..." ]]; then
        # Select a new random quote for each update
        RANDOM_QUOTE=${QUOTES[$RANDOM % ${#QUOTES[@]}]}
        progress_caption="🔧 <b>Build Started:</b> <code>$ROM_NAME</code> for <b>$DEVICE</b> by <b>$CONFIG_MAINTAINER</b>
        
🟡 <i>$RANDOM_QUOTE</i>
        
<b>• ROM:</b> <code>$ROM_NAME</code>
<b>• DEVICE:</b> <code>$DEVICE</code>
<b>• ANDROID VERSION:</b> <code>$ANDROID_VERSION</code>
<b>• TYPE:</b> <code>$BUILD_TYPE</code>
<b>• PROGRESS:</b> <code>$current_progress</code>"

        edit_caption "$progress_caption" "$CONFIG_CHATID" "$build_message_id"
        previous_progress="$current_progress"
    fi
    sleep 120 # Wait for 2 minutes (120 seconds)
done

# Print a newline to move off the progress line
echo -e "\n"

wait

build_end_time=$(date -u +%s)
build_duration=$(get_duration "$build_start_time" "$build_end_time")

# Check build result
if ! grep -q "#### build completed successfully" "$ROOT_DIRECTORY/build.log"; then
    echo -e "$RED\nBuild failed. Check build.log for details.$RESET"
    build_failed_caption="❌ <b>Build Failed:</b> <code>$ROM_NAME</code> for <b>$DEVICE</b>
    \nBuild failed after $build_duration. Check out the log for more details."
    edit_caption "$build_failed_caption" "$CONFIG_CHATID" "$build_message_id"
    
    if [ -f "out/error.log" ]; then
        send_file "out/error.log" "$CONFIG_ERROR_CHATID"
    else
        echo "out/error.log not found, sending full build.log instead."
        send_file "$ROOT_DIRECTORY/build.log" "$CONFIG_ERROR_CHATID"
    fi
    
    send_sticker "$STICKER_URL" "$CONFIG_CHATID"
    
    if [ -f "out/error.log" ]; then
        echo -e "\n${RED}Displaying error log:${RESET}"
        cat "out/error.log"
    fi
else
    echo -e "$BOLD_GREEN\nBuild successful!$RESET"

    zip_file=$(find "$OUT_DIR" -name "*$DEVICE*.zip" -type f | tail -n1)
    json_file=$(find "$OUT_DIR" -name "*$DEVICE*.json" -type f | tail -n1)

    if [[ -z "$zip_file" ]]; then
        build_failed_caption="❌ <b>Build finished, but no ZIP file found!</b>
        \nCheck the output directory for details."
        edit_caption "$build_failed_caption" "$CONFIG_CHATID" "$build_message_id"
        exit 1
    fi

    echo -e "$BOLD_GREEN\nUploading build artifacts...$RESET"

    pd_file_url=$(upload_file_pd "$zip_file")

    if [[ "$CONFIG_GOFILE" == "true" ]]; then
        gofile_file_url=$(upload_file_gofile "$zip_file")
    fi

    zip_file_md5sum=$(md5sum "$zip_file" | awk '{print $1}')
    zip_file_size=$(ls -sh "$zip_file" | awk '{print $1}')
    json_file_url=""

    if [[ -n "$json_file" ]]; then
        json_file_url=$(upload_file_pd "$json_file")
    fi

    details="<b>• ROM:</b> <code>$ROM_NAME</code>\n<b>• DEVICE:</b> <code>$DEVICE</code>\n<b>• ANDROID VERSION:</b> <code>$ANDROID_VERSION</code>\n<b>• TYPE:</b> <code>$BUILD_TYPE</code>\n<b>• SIZE:</b> <code>$zip_file_size</code>\n<b>• MD5SUM:</b> <code>$zip_file_md5sum</code>"
    if [[ -n "$json_file_url" && "$json_file_url" != "Upload failed" ]]; then
        details+="\n<b>• JSON:</b> <a href=\"$json_file_url\">Here</a>"
    fi
    if [[ -n "$pd_file_url" && "$pd_file_url" != "Upload failed" ]]; then
        details+="\n<b>• PIXELDRAIN:</b> <a href=\"$pd_file_url\">Here</a>"
    fi
    if [[ "$CONFIG_GOFILE" == "true" ]]; then
        if [[ -n "$gofile_file_url" && "$gofile_file_url" != "Upload failed" ]]; then
            details+="\n<b>• GOFILE:</b> <a href=\"$gofile_file_url\">Here</a>"
        fi
    fi

    build_finished_caption="✅ <b>ROM compiled successfully!</b>\n\n$details\n\n<i>Compilation took $build_duration.</i>"

    edit_caption "$build_finished_caption" "$CONFIG_CHATID" "$build_message_id"
    send_sticker "$STICKER_URL" "$CONFIG_CHATID"
fi

if [[ "$POWEROFF" == "true" ]]; then
    echo -e "$BOLD_GREEN\nPowering off server...$RESET"
    sudo poweroff
fi

#!/bin/bash

# Extra Monitors VNC Script
# This script starts two x11vnc servers for different screen regions
# Usage: ./extra_monitors.sh

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Logging functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Store process IDs
VNC1_PID=""
VNC2_PID=""
ADB_DEVICES=""

# Android device and display targeting
TARGET_DEVICE_SERIAL="${TARGET_DEVICE_SERIAL:-G0K0KH02616100TX}"
TARGET_DISPLAY_NAME="${TARGET_DISPLAY_NAME:-A0c28e850.HDR}"
FALLBACK_DISPLAY_NAME="${FALLBACK_DISPLAY_NAME:-HDMI-1}"
TARGET_CLIP=""
VNC2_SCALE=""
TARGET_ASPECT_W=""
TARGET_ASPECT_H=""
LEFT_TRIM_MODE="${LEFT_TRIM_MODE:-off}"
LEFT_TRIM_PERCENT="${LEFT_TRIM_PERCENT:-20}"

# Cleanup function
cleanup() {
    log_info "Shutting down VNC servers gracefully..."
    
    # Cleanup ADB port forwarding first
    cleanup_adb_forwarding
    
    if [ ! -z "$VNC1_PID" ] && kill -0 "$VNC1_PID" 2>/dev/null; then
        log_info "Stopping VNC server on port 5901 (PID: $VNC1_PID)"
        kill -TERM "$VNC1_PID" 2>/dev/null
        wait "$VNC1_PID" 2>/dev/null
    fi
    
    if [ ! -z "$VNC2_PID" ] && kill -0 "$VNC2_PID" 2>/dev/null; then
        log_info "Stopping VNC server on port 5900 (PID: $VNC2_PID)"
        kill -TERM "$VNC2_PID" 2>/dev/null
        wait "$VNC2_PID" 2>/dev/null
    fi
    
    log_success "VNC servers stopped successfully"
    exit 0
}

# Set up signal handlers for graceful shutdown
trap cleanup INT TERM

# Function to print connected monitor placement
log_monitor_placement() {
    log_info "Current monitor placement (xrandr):"
    xrandr --query | awk '/ connected/{print "  " $0}'
}

# Function to resolve clip geometry from a display name
resolve_display_clip() {
    local output_name="$1"
    local geom

    geom=$(xrandr --query | awk -v out="$output_name" '
        $1==out && $2=="connected" {
            for (i=1; i<=NF; i++) {
                if ($i ~ /^[0-9]+x[0-9]+\+[0-9]+\+[0-9]+$/) {
                    print $i
                    exit
                }
            }
        }
    ')

    echo "$geom"
}

# Function to optionally trim left edge from a clip (e.g. WxH+X+Y)
apply_left_trim() {
    local clip="$1"
    local mode="$2"
    local percent="$3"
    local w h x y
    local trim

    if [ "$mode" != "auto" ]; then
        echo "$clip"
        return
    fi

    if [[ ! "$percent" =~ ^[0-9]+$ ]] || [ "$percent" -le 0 ] || [ "$percent" -ge 90 ]; then
        echo "$clip"
        return
    fi

    if [[ ! "$clip" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]]; then
        echo "$clip"
        return
    fi

    w="${BASH_REMATCH[1]}"
    h="${BASH_REMATCH[2]}"
    x="${BASH_REMATCH[3]}"
    y="${BASH_REMATCH[4]}"

    trim=$((w * percent / 100))
    if [ "$trim" -lt 1 ] || [ "$trim" -ge "$w" ]; then
        echo "$clip"
        return
    fi

    w=$((w - trim))
    x=$((x + trim))

    echo "${w}x${h}+${x}+${y}"
}

# Function to crop clip to a target aspect ratio (e.g. phone landscape)
apply_aspect_crop() {
    local clip="$1"
    local aspect_w="$2"
    local aspect_h="$3"
    local w h x y
    local new_w new_h

    if [[ ! "$clip" =~ ^([0-9]+)x([0-9]+)\+([0-9]+)\+([0-9]+)$ ]]; then
        echo "$clip"
        return
    fi

    if [[ ! "$aspect_w" =~ ^[0-9]+$ ]] || [[ ! "$aspect_h" =~ ^[0-9]+$ ]] || [ "$aspect_w" -le 0 ] || [ "$aspect_h" -le 0 ]; then
        echo "$clip"
        return
    fi

    w="${BASH_REMATCH[1]}"
    h="${BASH_REMATCH[2]}"
    x="${BASH_REMATCH[3]}"
    y="${BASH_REMATCH[4]}"

    if [ $((w * aspect_h)) -eq $((h * aspect_w)) ]; then
        echo "$clip"
        return
    fi

    # Too wide: crop width. Too tall: crop height.
    if [ $((w * aspect_h)) -gt $((h * aspect_w)) ]; then
        new_w=$((h * aspect_w / aspect_h))
        if [ "$new_w" -lt 1 ] || [ "$new_w" -gt "$w" ]; then
            echo "$clip"
            return
        fi
        x=$((x + (w - new_w) / 2))
        w="$new_w"
    else
        new_h=$((w * aspect_h / aspect_w))
        if [ "$new_h" -lt 1 ] || [ "$new_h" -gt "$h" ]; then
            echo "$clip"
            return
        fi
        y=$((y + (h - new_h) / 2))
        h="$new_h"
    fi

    echo "${w}x${h}+${x}+${y}"
}

# Function to determine which display region the phone should render
determine_target_clip() {
    TARGET_CLIP=""

    TARGET_CLIP=$(resolve_display_clip "$TARGET_DISPLAY_NAME")
    if [ -n "$TARGET_CLIP" ]; then
        TARGET_CLIP=$(apply_aspect_crop "$TARGET_CLIP" "$TARGET_ASPECT_W" "$TARGET_ASPECT_H")
        TARGET_CLIP=$(apply_left_trim "$TARGET_CLIP" "$LEFT_TRIM_MODE" "$LEFT_TRIM_PERCENT")
        log_success "Using target display $TARGET_DISPLAY_NAME with clip $TARGET_CLIP"
        return 0
    fi

    log_warning "Display $TARGET_DISPLAY_NAME not found in xrandr outputs."

    TARGET_CLIP=$(resolve_display_clip "$FALLBACK_DISPLAY_NAME")
    if [ -n "$TARGET_CLIP" ]; then
        TARGET_CLIP=$(apply_aspect_crop "$TARGET_CLIP" "$TARGET_ASPECT_W" "$TARGET_ASPECT_H")
        TARGET_CLIP=$(apply_left_trim "$TARGET_CLIP" "$LEFT_TRIM_MODE" "$LEFT_TRIM_PERCENT")
        log_warning "Falling back to display $FALLBACK_DISPLAY_NAME with clip $TARGET_CLIP"
        return 0
    fi

    log_error "Could not resolve a valid display clip from xrandr."
    return 1
}

# Function to derive phone-aware VNC scaling target
determine_vnc2_scale() {
    VNC2_SCALE=""
    TARGET_ASPECT_W=""
    TARGET_ASPECT_H=""

    if [ -z "$ADB_DEVICES" ]; then
        return
    fi

    local device
    local wm_size
    local size_token
    local w
    local h

    device=$(echo "$ADB_DEVICES" | head -n1)
    wm_size=$(adb -s "$device" shell wm size 2>/dev/null | tr -d '\r')
    size_token=$(echo "$wm_size" | awk -F': ' '/Physical size:/ {print $2; exit}')

    if [ -z "$size_token" ]; then
        return
    fi

    w=${size_token%x*}
    h=${size_token#*x}

    if [[ ! "$w" =~ ^[0-9]+$ ]] || [[ ! "$h" =~ ^[0-9]+$ ]]; then
        return
    fi

    # The captured monitor stream is landscape; scale to landscape device bounds.
    if [ "$h" -gt "$w" ]; then
        VNC2_SCALE="${h}x${w}"
        TARGET_ASPECT_W="$h"
        TARGET_ASPECT_H="$w"
    else
        VNC2_SCALE="${w}x${h}"
        TARGET_ASPECT_W="$w"
        TARGET_ASPECT_H="$h"
    fi

    log_info "Using phone-aware VNC scaling target: $VNC2_SCALE"
}

# Function to discover connected Android devices
discover_adb_devices() {
    ADB_DEVICES=""

    # Check if adb is installed
    if ! command -v adb &> /dev/null; then
        log_warning "ADB is not installed. Android automation features will be skipped."
        log_info "To install ADB: sudo apt-get install android-tools-adb"
        return 1
    fi

    log_info "Starting ADB server..."
    adb start-server >/dev/null 2>&1 || true

    log_info "Checking connected Android devices (adb devices)..."
    adb devices

    ADB_DEVICES=$(adb devices | awk 'NR>1 && $2=="device" {print $1}')

    if [ -z "$ADB_DEVICES" ]; then
        log_warning "No authorized Android devices found."
        log_info "If your device is connected, accept the USB debugging prompt and retry."
        return 1
    fi

    if echo "$ADB_DEVICES" | grep -qx "$TARGET_DEVICE_SERIAL"; then
        ADB_DEVICES="$TARGET_DEVICE_SERIAL"
        log_success "Target device detected: $TARGET_DEVICE_SERIAL"
    else
        log_warning "Target device $TARGET_DEVICE_SERIAL is not connected."
        log_warning "Connected devices: $(echo "$ADB_DEVICES" | tr '\n' ' ')"
        log_warning "ADB automation will use all connected devices."
    fi

    log_success "Android device(s) detected: $(echo "$ADB_DEVICES" | tr '\n' ' ')"
    return 0
}

# Function to start VNC server 1
start_vnc1() {
    log_info "Starting VNC server 1 (port 5901) for region 1600x700+2460+1440"
    x11vnc -noprimary -noclipboard -clip 1600x700+2460+1440 --rfbport 5901 &
    VNC1_PID=$!
    
    # Give it a moment to start
    sleep 1
    
    if kill -0 "$VNC1_PID" 2>/dev/null; then
        log_success "VNC server 1 started successfully (PID: $VNC1_PID)"
    else
        log_error "VNC server 1 failed to start"
        VNC1_PID=""
    fi
}

# Function to start VNC server 2
start_vnc2() {
    if [ -z "$TARGET_CLIP" ]; then
        log_error "VNC server 2 target clip is empty. Cannot start port 5900 stream."
        return
    fi

    log_info "Starting VNC server 2 (port 5900) for region $TARGET_CLIP"

    local vnc2_args=(
        -noprimary
        -noclipboard
        -noxwarppointer
        -noxdamage
        -ncache 0
        -ncache_cr
        -nomodtweak
        -clip "$TARGET_CLIP"
        --rfbport 5900
    )

    if [ -n "$VNC2_SCALE" ]; then
        vnc2_args+=( -scale "$VNC2_SCALE" )
        log_info "Applying VNC scaling for phone full-screen: $VNC2_SCALE"
    fi

    # Hide/decouple remote cursor to avoid distraction from pointer activity on other screens.
    x11vnc "${vnc2_args[@]}" &
    VNC2_PID=$!
    
    # Give it a moment to start
    sleep 1
    
    if kill -0 "$VNC2_PID" 2>/dev/null; then
        log_success "VNC server 2 started successfully (PID: $VNC2_PID)"
    else
        log_error "VNC server 2 failed to start"
        VNC2_PID=""
    fi
}

# Function to open localhost port 5900 on Android via adb reverse
open_adb_reverse_5900() {
    if [ -z "$ADB_DEVICES" ]; then
        return
    fi

    log_info "Opening port 5900 for localhost access on Android (adb reverse tcp:5900 tcp:5900)..."

    for device in $ADB_DEVICES; do
        log_info "Configuring device: $device"

        adb -s "$device" reverse --remove tcp:5900 2>/dev/null || true

        if adb -s "$device" reverse tcp:5900 tcp:5900 2>/dev/null; then
            log_success "Port 5900 opened for $device (use 127.0.0.1:5900 in bVNC)"
        else
            log_error "Failed to open port 5900 for $device"
        fi
    done
}

# Function to wake Android screen and launch bVNC Free
wake_android_and_open_bvnc() {
    if [ -z "$ADB_DEVICES" ]; then
        return
    fi

    log_info "Turning Android screen on and opening bVNC Free..."

    for device in $ADB_DEVICES; do
        log_info "Waking device screen: $device"
        adb -s "$device" shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1 || true
        adb -s "$device" shell input keyevent 82 >/dev/null 2>&1 || true

        # Force landscape for better full-screen use with a landscape monitor feed.
        adb -s "$device" shell settings put system accelerometer_rotation 0 >/dev/null 2>&1 || true
        adb -s "$device" shell settings put system user_rotation 1 >/dev/null 2>&1 || true
        adb -s "$device" shell settings put global policy_control immersive.full=com.iiordanov.freebVNC >/dev/null 2>&1 || true

        if adb -s "$device" shell monkey -p com.iiordanov.freebVNC -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1; then
            log_success "bVNC Free opened on $device"
        else
            log_warning "Could not open bVNC Free on $device. Check that com.iiordanov.freebVNC is installed."
            continue
        fi

        # Best-effort: try to trigger a localhost VNC URL if the app supports it.
        if adb -s "$device" shell am start -a android.intent.action.VIEW -d "vnc://127.0.0.1:5900" >/dev/null 2>&1; then
            log_success "Attempted VNC auto-connect via vnc://127.0.0.1:5900 on $device"
        else
            log_warning "Could not auto-start VNC connection on $device. Open/connect manually in bVNC if needed."
        fi
    done
}

# Function to cleanup ADB port forwarding
cleanup_adb_forwarding() {
    if command -v adb &> /dev/null; then
        log_info "Cleaning up ADB port forwarding..."
        
        local devices=$(adb devices | grep -E "^\w+\s+device$" | awk '{print $1}')
        
        for device in $devices; do
            log_info "Removing port forwarding for device: $device"
            adb -s "$device" reverse --remove-all 2>/dev/null || true
        done
    fi
}

# Function to monitor processes
monitor_processes() {
    while true; do
        local running_count=0
        
        if [ ! -z "$VNC1_PID" ] && kill -0 "$VNC1_PID" 2>/dev/null; then
            running_count=$((running_count + 1))
        elif [ ! -z "$VNC1_PID" ]; then
            log_warning "VNC server 1 (port 5901) has stopped"
            VNC1_PID=""
        fi
        
        if [ ! -z "$VNC2_PID" ] && kill -0 "$VNC2_PID" 2>/dev/null; then
            running_count=$((running_count + 1))
        elif [ ! -z "$VNC2_PID" ]; then
            log_warning "VNC server 2 (port 5900) has stopped"
            VNC2_PID=""
        fi
        
        # If no processes are running, exit
        if [ $running_count -eq 0 ]; then
            log_info "No VNC servers are running. Exiting..."
            break
        fi
        
        sleep 2
    done
}

# Main function
main() {
    log_info "=== Starting Extra Monitors VNC Script ==="

    log_monitor_placement
    
    # Check if x11vnc is installed
    if ! command -v x11vnc &> /dev/null; then
        log_error "x11vnc is not installed. Please install it first:"
        log_info "Ubuntu/Debian: sudo apt-get install x11vnc"
        log_info "Fedora/RHEL: sudo dnf install x11vnc"
        exit 1
    fi

    # Start ADB and discover devices first
    discover_adb_devices || true

    # Open port 5900 first so bVNC can target localhost
    open_adb_reverse_5900

    # Derive phone-aware VNC scaling so the stream uses the full device display area
    determine_vnc2_scale

    if ! determine_target_clip; then
        exit 1
    fi

    # Start both VNC servers
    start_vnc1
    start_vnc2
    
    # Check if at least one server started
    if [ -z "$VNC1_PID" ] && [ -z "$VNC2_PID" ]; then
        log_error "Both VNC servers failed to start. Exiting..."
        exit 1
    fi
    
    log_info "VNC servers are running. Press Ctrl+C to stop gracefully."
    log_info "Connect to:"
    [ ! -z "$VNC1_PID" ] && log_info "  - VNC 1: localhost:5901 (region 1600x700+2460+1440)"
    [ ! -z "$VNC2_PID" ] && log_info "  - VNC 2: localhost:5900 (region $TARGET_CLIP)"
    
    # After VNC is up, turn screen on and open bVNC Free
    wake_android_and_open_bvnc
    
    # Monitor the processes
    monitor_processes
    
    # Cleanup will be called automatically by trap or we can call it here
    cleanup
}

# Run the main function
main "$@"
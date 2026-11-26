#!/bin/bash

# Target namespaces to monitor
TARGET_NAMESPACES=(
    "cert-manager"
    "hcl-appscan-ascp"
    "hcl-appscan-asra"
    "hcl-appscan-dast"
    "hcl-appscan-sca"
    "istio-system"
    "kube-system"
)

TIMESTAMP=$(date '+%Y%m%d_%H%M%S')
BASE_DIR="AppScan360_MultiLog_${TIMESTAMP}"

mkdir -p "$BASE_DIR"

echo "========================================================="
echo " AppScan 360 Automatic Multi-Namespace Log Collection"
echo "========================================================="
echo "Output Directory: $BASE_DIR"
echo "Waiting for target namespaces and pods to appear..."
echo "Press Ctrl+C to stop"
echo "========================================================="

PIDS=()
declare -A WATCHED_NS
declare -A WATCHED_PODS

cleanup() {
    echo ""
    echo "Stopping log collection..."

    for PID in "${PIDS[@]}"; do
        kill "$PID" 2>/dev/null
    done

    echo "Log collection stopped."
    echo "Logs available in: $BASE_DIR"
    exit 0
}

trap cleanup INT TERM

# ------------------------------------------------
# Function to initialize a namespace once it appears
# ------------------------------------------------
init_namespace() {
    local NS="$1"

    if [ -n "${WATCHED_NS[$NS]}" ]; then
        return
    fi

    echo "[+] Namespace detected: '$NS' — starting event & pod monitoring"
    WATCHED_NS["$NS"]=1

    mkdir -p "$BASE_DIR/$NS/logs"

    # Start continuous event collection for this namespace
    kubectl get events \
        -n "$NS" \
        --watch \
        --output=wide \
        > "$BASE_DIR/$NS/events.log" 2>&1 &

    PIDS+=($!)
}

# ------------------------------------------------
# Function to collect logs for a pod
# ------------------------------------------------
collect_pod_logs() {
    local NS="$1"
    local POD="$2"
    local KEY="${NS}/${POD}"
    local LOG_FILE="$BASE_DIR/$NS/logs/${POD}.log"

    if [ -n "${WATCHED_PODS[$KEY]}" ]; then
        return
    fi

    WATCHED_PODS["$KEY"]=1
    echo "[+] New pod detected: $NS / $POD — starting log capture"

    (
        echo "=============================================="
        echo "Pod: $POD"
        echo "Namespace: $NS"
        echo "Started: $(date)"
        echo "=============================================="
        echo ""

        kubectl logs "$POD" \
            -n "$NS" \
            --all-containers=true \
            --timestamps=true \
            -f
    ) >> "$LOG_FILE" 2>&1 &

    PIDS+=($!)
}

# ------------------------------------------------
# Continuously watch for namespaces & pods appearing
# ------------------------------------------------
while true; do
    for NS in "${TARGET_NAMESPACES[@]}"; do
        # Check if the namespace exists yet
        if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
            continue
        fi

        # Initialize directory and event watcher the first time this namespace appears
        init_namespace "$NS"

        # Check pods one by one (using process substitution so PIDS are tracked in the main shell)
        while read -r POD STATUS; do
            [ -z "$POD" ] && continue

            # Wait until the pod is no longer Pending/ContainerCreating so kubectl logs -f doesn't fail early
            if [[ "$STATUS" == "Pending" || "$STATUS" == "ContainerCreating" || "$STATUS" == "Init:"* ]]; then
                continue
            fi

            collect_pod_logs "$NS" "$POD"
        done < <(kubectl get pods -n "$NS" --no-headers 2>/dev/null | awk '{print $1, $3}')
    done

    sleep 5
done
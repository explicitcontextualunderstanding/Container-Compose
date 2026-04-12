#!/bin/bash
# dynamic-threshold-monitor.sh
# Monitors memory and adjusts thresholds dynamically
# Runs alongside tests to provide real-time threshold status

LOG_FILE="${1:-logs/dynamic_threshold_$(date +%Y%m%d_%H%M%S).log}"
mkdir -p "$(dirname "$LOG_FILE")"

echo "timestamp,free_mb,pressure_level,base_threshold,actual_threshold,can_run_heavy,can_run_medium,can_run_light" > "$LOG_FILE"

monitor_memory() {
    while true; do
        TIMESTAMP=$(date +%Y%m%d_%H%M%S)
        
        # Get free memory
        FREE_MB=$(vm_stat | awk '/Pages free/{f=$3}/Pages inactive/{i=$3}/Pages speculative/{s=$3}END{gsub(/\./,"",f);gsub(/\./,"",i);gsub(/\./,"",s);print int((f+i+s)*4096/1024/1024)}')
        TOTAL_MB=8192
        FREE_PERCENT=$((FREE_MB * 100 / TOTAL_MB))
        
        # Calculate pressure and thresholds
        BASE_HEAVY=450
        BASE_MEDIUM=270
        BASE_LIGHT=140
        
        # Dynamic escalation
        if [ $FREE_PERCENT -lt 12 ]; then
            PRESSURE_LEVEL=2
            ACTUAL_THRESHOLD=$((TOTAL_MB * 15 / 100))  # 1228MB
        elif [ $FREE_PERCENT -lt 37 ]; then
            PRESSURE_LEVEL=1
            ACTUAL_THRESHOLD=$((TOTAL_MB * 25 / 100))  # 2048MB
        else
            PRESSURE_LEVEL=0
            ACTUAL_THRESHOLD=$BASE_HEAVY
        fi
        
        # Check what can run
        CAN_HEAVY=0
        CAN_MEDIUM=0
        CAN_LIGHT=0
        [ $FREE_MB -ge $ACTUAL_THRESHOLD ] && CAN_HEAVY=1
        [ $FREE_MB -ge $BASE_MEDIUM ] && CAN_MEDIUM=1
        [ $FREE_MB -ge $BASE_LIGHT ] && CAN_LIGHT=1
        
        # Log CSV
        echo "$TIMESTAMP,$FREE_MB,$PRESSURE_LEVEL,$BASE_HEAVY,$ACTUAL_THRESHOLD,$CAN_HEAVY,$CAN_MEDIUM,$CAN_LIGHT" >> "$LOG_FILE"
        
        # Status output
        STATUS="NORMAL"
        [ $PRESSURE_LEVEL -eq 1 ] && STATUS="WARNING"
        [ $PRESSURE_LEVEL -eq 2 ] && STATUS="CRITICAL"
        
        echo "[$(date +%H:%M:%S)] Free: ${FREE_MB}MB (${FREE_PERCENT}%) | Pressure: $STATUS | Threshold: ${ACTUAL_THRESHOLD}MB"
        
        # Recommendations
        if [ $PRESSURE_LEVEL -eq 2 ]; then
            echo "  ⚠️  CRITICAL: Close apps/agents to free memory"
        elif [ $CAN_HEAVY -eq 0 ] && [ $CAN_MEDIUM -eq 1 ]; then
            echo "  ℹ️  Can run MEDIUM tests (need ${ACTUAL_THRESHOLD}MB for heavy)"
        fi
        
        sleep 2
    done
}

echo "========================================"
echo "  DYNAMIC THRESHOLD MONITOR"
echo "========================================"
echo "Logging to: $LOG_FILE"
echo "Press Ctrl+C to stop"
echo ""

monitor_memory

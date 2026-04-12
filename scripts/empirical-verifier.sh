#!/bin/bash
# empirical-verifier.sh
# Collects empirical verification data during test runs
# Usage: ./scripts/empirical-verifier.sh <log_dir>

LOG_DIR="${1:-logs/verification}"
mkdir -p "$LOG_DIR"

RUN_ID="verify-$(date +%s)"
VERIFICATION_LOG="$LOG_DIR/${RUN_ID}_verification.log"

echo "========================================" | tee "$VERIFICATION_LOG"
echo "  EMPIRICAL VERIFICATION DATA COLLECTION" | tee -a "$VERIFICATION_LOG"
echo "  Run ID: $RUN_ID" | tee -a "$VERIFICATION_LOG"
echo "========================================" | tee -a "$VERIFICATION_LOG"
echo "" | tee -a "$VERIFICATION_LOG"

# Check thresholds
echo "=== THRESHOLD VERIFICATION ===" | tee -a "$VERIFICATION_LOG"
echo "Expected from ResourceGuard.swift:" | tee -a "$VERIFICATION_LOG"
grep -E "heavyContainer|mediumContainer|lightweight" Sources/ContainerTesting/ResourceGuard.swift | grep -E "minMemory|[0-9]+MB" | tee -a "$VERIFICATION_LOG"
echo "" | tee -a "$VERIFICATION_LOG"

# Check slots
echo "=== SLOT CONFIGURATION ===" | tee -a "$VERIFICATION_LOG"
grep "defaultMaxContainerSlots" Tests/TestHelpers/ContainerPollingHelpers.swift | head -1 | tee -a "$VERIFICATION_LOG"
echo "" | tee -a "$VERIFICATION_LOG"

# Start monitoring
echo "=== STARTING VERIFICATION MONITOR ===" | tee -a "$VERIFICATION_LOG"
echo "Timestamp: $(date)" | tee -a "$VERIFICATION_LOG"
echo "Initial memory: $(vm_stat | awk '/Pages free/{f=$3}/Pages inactive/{i=$3}/Pages speculative/{s=$3}END{gsub(/\./,"",f);gsub(/\./,"",i);gsub(/\./,"",s);print int((f+i+s)*4096/1024/1024)" MB"}')" | tee -a "$VERIFICATION_LOG"
echo "" | tee -a "$VERIFICATION_LOG"

# Monitor loop - collect data every 2 seconds
MONITOR_PID=""
collect_data() {
    local data_file="$LOG_DIR/${RUN_ID}_metrics.csv"
    echo "timestamp,free_mb,active_mb,container_count,test_count,pressure_level" > "$data_file"
    
    while true; do
        local ts=$(date +%Y%m%d_%H%M%S)
        local free_mb=$(vm_stat | awk '/Pages free/{f=$3}/Pages inactive/{i=$3}/Pages speculative/{s=$3}END{gsub(/\./,"",f);gsub(/\./,"",i);gsub(/\./,"",s);print int((f+i+s)*4096/1024/1024)}')
        local active_mb=$(vm_stat | awk '/Pages active/{a=$3}/Pages wired/{w=$4}END{gsub(/\./,"",a);gsub(/\./,"",w);print int((a+w)*16384/1024/1024)}')
        local container_count=$(container ps 2>/dev/null | wc -l)
        local test_count=$(ps aux | grep "swift test" | grep -v grep | wc -l)
        
        # Calculate pressure level
        local total_mb=$((free_mb + active_mb))
        local free_percent=$((free_mb * 100 / total_mb))
        local pressure=0
        if [ $free_percent -lt 12 ]; then pressure=2
        elif [ $free_percent -lt 37 ]; then pressure=1
        fi
        
        echo "$ts,$free_mb,$active_mb,$container_count,$test_count,$pressure" >> "$data_file"
        sleep 2
    done
}

collect_data &
MONITOR_PID=$!

echo "[VERIFY] Monitor PID: $MONITOR_PID" | tee -a "$VERIFICATION_LOG"
echo "[VERIFY] Metrics: $LOG_DIR/${RUN_ID}_metrics.csv" | tee -a "$VERIFICATION_LOG"
echo "" | tee -a "$VERIFICATION_LOG"

# Wait for signal
echo "=== WAITING FOR TEST COMPLETION ===" | tee -a "$VERIFICATION_LOG"
echo "Run: tail -f $VERIFICATION_LOG" | tee -a "$VERIFICATION_LOG"
echo "Kill monitor: kill $MONITOR_PID" | tee -a "$VERIFICATION_LOG"

# Keep script running until signaled
trap "echo ''; echo '=== STOPPING MONITOR ===' | tee -a $VERIFICATION_LOG; kill $MONITOR_PID 2>/dev/null; finalize_report" EXIT

finalize_report() {
    echo "" | tee -a "$VERIFICATION_LOG"
    echo "=== FINALIZING VERIFICATION REPORT ===" | tee -a "$VERIFICATION_LOG"
    
    local metrics="$LOG_DIR/${RUN_ID}_metrics.csv"
    if [ -f "$metrics" ]; then
        local samples=$(tail -n +2 "$metrics" | wc -l)
        local min_free=$(tail -n +2 "$metrics" | cut -d',' -f2 | sort -n | head -1)
        local max_containers=$(tail -n +2 "$metrics" | cut -d',' -f4 | sort -n | tail -1)
        local critical_events=$(tail -n +2 "$metrics" | awk -F',' '$6==2 {count++} END {print count+0}')
        
        echo "Samples collected: $samples" | tee -a "$VERIFICATION_LOG"
        echo "Min free memory: ${min_free}MB" | tee -a "$VERIFICATION_LOG"
        echo "Max containers: $max_containers" | tee -a "$VERIFICATION_LOG"
        echo "Critical pressure events: $critical_events" | tee -a "$VERIFICATION_LOG"
        echo "" | tee -a "$VERIFICATION_LOG"
        
        # Threshold verification
        echo "=== THRESHOLD PERFORMANCE ===" | tee -a "$VERIFICATION_LOG"
        if [ "$min_free" -lt 450 ]; then
            echo "⚠️  Min free ($min_free MB) BELOW heavy threshold (450MB)" | tee -a "$VERIFICATION_LOG"
        else
            echo "✅ Min free ($min_free MB) ABOVE heavy threshold (450MB)" | tee -a "$VERIFICATION_LOG"
        fi
        
        if [ "$max_containers" -le 5 ]; then
            echo "✅ Container slots working: max $max_containers (limit: 5)" | tee -a "$VERIFICATION_LOG"
        else
            echo "⚠️  Container slots NOT working: max $max_containers (limit: 5)" | tee -a "$VERIFICATION_LOG"
        fi
        
        echo "" | tee -a "$VERIFICATION_LOG"
        echo "Metrics file: $metrics" | tee -a "$VERIFICATION_LOG"
        echo "Report: $VERIFICATION_LOG" | tee -a "$VERIFICATION_LOG"
    fi
}

# Keep running
while true; do
    sleep 1
done

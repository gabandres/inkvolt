#!/usr/bin/env bash
# WIP: runs InkvoltPdfKit's tests and, when their output stops for 60 s, samples the test process (thread stacks).
set -u
log=$RUNNER_TEMP/pdf-test.log
INKVOLT_NET_TRACE=1 swift test --package-path mac/InkvoltPdfKit -Xswiftc -warnings-as-errors > "$log" 2>&1 &
test=$!
tail -f "$log" &
tailer=$!
samples=0
while kill -0 $test 2>/dev/null; do
    sleep 10
    age=$(( $(date +%s) - $(stat -f %m "$log") ))
    if [ $age -ge 60 ] && [ $samples -lt 3 ]; then
        samples=$((samples + 1))
        for pid in $(pgrep -f 'InkvoltPdfKitPackageTests|swiftpm-testing-helper'); do
            echo "===== WIP sample $samples of pid $pid ($(ps -o comm= -p $pid)) after ${age}s of silence"
            sample $pid 3 -file "$RUNNER_TEMP/sample-$samples-$pid.txt" > /dev/null 2>&1
            # the threads' stacks, trimmed to our frames and the waits under them
            grep -E "Thread_|PdfCore|PdfCoreTests|MuPDF|fz_|pdf_|semaphore|psynch|sleep|Testing\." "$RUNNER_TEMP/sample-$samples-$pid.txt" | cut -c1-220 | head -400
        done
        sleep 120
    fi
done
wait $test
status=$?
sleep 2
kill $tailer 2>/dev/null
exit $status

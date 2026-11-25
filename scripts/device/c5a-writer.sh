#!/bin/sh
# Power-loss acceptance writer/checker (plan C5a), run in the Alpine tree over
# SSH. Bounded: 8 known-good files of 256 KiB, 4 scratch files of 4 MiB and a
# counter file, about 19 MiB in /var/tmp/mibox-c5a on data. Refuses to start
# with less than 1 GiB free.
#   c5a-writer.sh setup   create and fsync the known-good files; print hashes
#   c5a-writer.sh run     loop: overwrite scratch file i%4 (fsync), append
#                         counter line i with its hash (fsync), then print
#                         "SYNCED i <hash>". Only printed lines are known
#                         durable. Stops after 1800 s or 2000 iterations.
#   c5a-writer.sh check   verify known-good files, the counter lines and
#                         the scratch files after the power cut
#   c5a-writer.sh clean   remove the test directory
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
dir=/var/tmp/mibox-c5a
case "${1:-}" in
setup)
    free=$(df -k /var/tmp | awk 'NR==2{print $4}')
    [ "$free" -gt 1048576 ] || { echo "REFUSED free_kib=$free"; exit 1; }
    rm -rf "$dir"; mkdir -p "$dir/known"
    for k in 1 2 3 4 5 6 7 8; do
        dd if=/dev/urandom of="$dir/known/k$k" bs=64k count=4 conv=fsync 2>/dev/null
    done
    fsync "$dir/known" "$dir"
    : > "$dir/counter"; fsync "$dir/counter" "$dir"
    (cd "$dir/known" && sha256sum k*) > "$dir/known.sha256"; fsync "$dir/known.sha256" "$dir"
    sed 's/^/KNOWN /' "$dir/known.sha256"
    echo "SETUP_DONE free_kib=$free" ;;
run)
    [ -s "$dir/known.sha256" ] || { echo NO_SETUP; exit 1; }
    end=$(( $(cut -d. -f1 /proc/uptime) + 1800 )); i=0
    while [ "$i" -lt 2000 ] && [ "$(cut -d. -f1 /proc/uptime)" -lt "$end" ]; do
        i=$((i + 1)); s=$dir/s$((i % 4))
        dd if=/dev/urandom of="$s" bs=1M count=4 conv=fsync 2>/dev/null
        h=$(sha256sum "$s" | cut -c1-64)
        echo "$i s$((i % 4)) $h" >> "$dir/counter"
        fsync "$dir/counter"
        echo "SYNCED $i s$((i % 4)) $h $(date -u +%H:%M:%S)"
    done
    echo RUN_ENDED ;;
check)
    echo "== known"; (cd "$dir/known" && sha256sum -c ../known.sha256 2>&1) | sed 's/^/KNOWN /'
    echo "== counter"
    total=$(wc -l < "$dir/counter")
    good=$(grep -c -E '^[0-9]+ s[0-3] [0-9a-f]{64}$' "$dir/counter" || true)
    echo "COUNTER_LINES total=$total well_formed=$good bytes=$(wc -c < "$dir/counter")"
    awk 'BEGIN{e=1} $1!=e{print "COUNTER_GAP expected " e " got " $1; exit} {e++} END{print "COUNTER_LAST " e-1}' "$dir/counter"
    tail -c 200 "$dir/counter" | od -c | tail -3
    echo "== scratch (latest counter entry per file)"
    for n in 0 1 2 3; do
        want=$(awk -v f="s$n" '$2==f{h=$3; i=$1} END{print i, h}' "$dir/counter")
        have=$(sha256sum "$dir/s$n" 2>/dev/null | cut -c1-64 || echo missing)
        size=$(stat -c %s "$dir/s$n" 2>/dev/null || echo -)
        echo "SCRATCH s$n size=$size latest_line=${want% *} match=$([ "$have" = "${want#* }" ] && echo yes || echo no)"
    done ;;
clean)
    rm -rf "$dir"; echo CLEANED ;;
*) echo 'usage: c5a-writer.sh setup|run|check|clean' >&2; exit 2 ;;
esac

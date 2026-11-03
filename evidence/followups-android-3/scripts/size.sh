# size.sh X PREFIX N   (Aa sheet already open)
s=$(date +%s%3N); input tap $1 1732
i=0; while [ $i -lt $3 ]; do i=$((i+1)); screencap -p /data/local/tmp/$2_$i.png; echo "$i $(( $(date +%s%3N) - s ))"; done

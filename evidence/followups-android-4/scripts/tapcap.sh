s=$(date +%s%3N); input tap $1 $2
i=0; while [ $i -lt $4 ]; do i=$((i+1)); screencap -p /data/local/tmp/$3_$i.png; echo "$i $(( $(date +%s%3N) - s ))"; done

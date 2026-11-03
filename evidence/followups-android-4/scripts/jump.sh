# jump.sh CH PREFIX N
input tap 540 1200; sleep 0.6; input tap 79 2280; sleep 1; input tap 361 2093; sleep 0.4
input keyevent KEYCODE_MOVE_END; input keyevent 67 67 67 67; input text $1
s=$(date +%s%3N); input keyevent 66
i=0; while [ $i -lt $3 ]; do i=$((i+1)); screencap -p /data/local/tmp/$2_$i.png; echo "$i $(( $(date +%s%3N) - s ))"; done

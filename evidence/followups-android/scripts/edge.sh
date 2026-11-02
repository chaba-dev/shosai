# edge NAME x0 y x1
edge() {
  adb shell "input motionevent DOWN $2 $3; for x in \$(seq $2 $(( ($4-$2)/10 )) $4); do input motionevent MOVE \$x $3; sleep 0.04; done; input motionevent MOVE $4 $3"
  sleep 0.4
  st=$(adb shell dumpsys window | grep -A2 "  InsetsPolicy" | tail -2 | tr -s ' ' | tr '\n' ' ')
  ex=$(adb shell dumpsys window | grep -m1 mSystemGestureExclusion | tr -d ' ')
  adb exec-out screencap -p > $S/ev/$1_hold.png
  adb shell input motionevent UP $4 $3; sleep 1.5
  st2=$(adb shell dumpsys window | grep -A2 "  InsetsPolicy" | tail -2 | tr -s ' ' | tr '\n' ' ')
  adb exec-out screencap -p > $S/ev/$1_after.png
  echo "$1 | holding: $st | $ex | after: $st2" | tee -a $S/edge_log.txt
}

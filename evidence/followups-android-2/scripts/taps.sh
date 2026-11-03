M=/data/local/tmp/marks.txt; : > $M
mark() { echo "$1 $(date +%s%N)" >> $M; }
sleep 1.5
for x in 918 918 918 162 162 162; do mark pre; input tap $x 1200; mark tap$x; sleep 2.2; done

#!/bin/bash

# check max fd open files

OK=0
NONOK=1
UNKNOWN=2

cd /host/proc

count=$(find -maxdepth 1 -type d -name '[0-9]*' | xargs -I {} ls {}/fd | wc -l)
max=$(cat /host/proc/sys/fs/file-max)

if [[ $count -gt $((max*80/100)) ]]; then
   echo "current fd usage is $count and max is $max"
   exit $NONOK
fi
echo "node has no fd pressure"
exit $OK
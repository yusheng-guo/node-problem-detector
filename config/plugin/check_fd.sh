#!/bin/bash

# check max fd open files

OK=0
NONOK=1
UNKNOWN=2

which lsof > /dev/null
if [ $? -ne 0 ]; then
    echo "lsof is not support"
    exit $UNKNOWN
fi

count=$(lsof | wc -l)
max=$(cat /proc/sys/fs/file-max)

echo "current fd is $count and max is $max"
if [[ $count -gt $((max*8/10)) ]]; then
    echo "more than 80% fd has been used($count:$max)"
   exit $NONOK
fi
echo "fd is ok"
exit $OK
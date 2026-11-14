#!/sbin/sh

if [ -f $2 ]; then
    echo $2 exist!!!;
    busybox tar -xf $2 -C $1 
else
    echo $2 not exist!!!;
    exit -1;
fi


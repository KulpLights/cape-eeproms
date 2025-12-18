#!/bin/bash

cd /home/fpp/media/cape-eeproms

if [ -f /dev/mmcblk0p1 ]; then
    mount -t auto /dev/mmcblk0p1 /mnt
    cp -f /mnt/k* /home/fpp/media/cape-eeproms/
    if [ -f /home/fpp/media/cape-eeproms/kulp-programmer.tgz ]; then
        cd /home/fpp/media/cape-eeproms
        tar -xzf /home/fpp/media/cape-eeproms/kulp-programmer.tgz
        rm -f /home/fpp/media/cape-eeproms/kulp-programmer.tgz
    fi
    chown -R fpp:fpp /home/fpp/media/cape-eeproms/*
    chmod +x /home/fpp/media/cape-eeproms/programmer/programmer
    chmod +x /home/fpp/media/cape-eeproms/programmer/write_cape_eeprom
    chmod +x /home/fpp/media/cape-eeproms/programmer/*.sh
    umount /mnt
fi 



for i in {1..10}; do
    sudo -u fpp git -c http.sslVerify=false pull -f --rebase
    if [ $? -ne 0 ]; then
        sleep 2
    else
        exit 0
    fi
done


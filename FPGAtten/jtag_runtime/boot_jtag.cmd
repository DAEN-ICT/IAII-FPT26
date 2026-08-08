echo "Booting FPGAtten JTAG initramfs from 0x30000000"
setenv bootargs "earlycon console=ttyPS0,115200 root=/dev/ram0 rw maxcpus=1 uio_pdrv_genirq.of_id=generic-uio"
booti 0x00200000 0x30000000 0x00100000

inherit extrausers

# Requested serial-console account.  The password is stored only as a
# SHA-512-crypt hash in the image metadata.
FPGATTEN_PASSWORD_HASH = "\$6\$FPGAtten\$sTxQZawDXBlJi5ri3hcZa11o16aqg7kMOiObhKmmw226AlyCm1M3YNSWEsMtcpEXkJmJzd5rGwJ2JtoFk9QPF0"

EXTRA_USERS_PARAMS = " \
    groupadd -r fpgatten; \
    useradd --badname -u 1000 -g fpgatten -m -d /home/FPGAteen \
        -s /bin/bash -p '${FPGATTEN_PASSWORD_HASH}' FPGAteen; \
"

IMAGE_INSTALL:append = " bash coreutils fpgatten-platform fpgatten-cases"
IMAGE_FEATURES:remove = "ssh-server-openssh ssh-server-dropbear debug-tweaks empty-root-password serial-autologin-root"

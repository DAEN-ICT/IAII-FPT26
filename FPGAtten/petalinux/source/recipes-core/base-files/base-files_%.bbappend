FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI:append = " file://hostname file://issue file://motd"

do_install:append() {
    install -m 0644 ${WORKDIR}/hostname ${D}${sysconfdir}/hostname
    install -m 0644 ${WORKDIR}/issue ${D}${sysconfdir}/issue
    install -m 0644 ${WORKDIR}/motd ${D}${sysconfdir}/motd
}

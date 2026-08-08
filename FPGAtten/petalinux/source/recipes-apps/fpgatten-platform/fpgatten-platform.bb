SUMMARY = "FPGAtten Z19-P userspace tools and system integration"
LICENSE = "CLOSED"

SRC_URI = " \
    file://fpgatten_csr.h \
    file://fpgatten_experiment.h \
    file://fpgatten_experiment.c \
    file://fpgatten_uio_selftest.c \
    file://fpgatten_uio_benchmark.c \
    file://fpgatten_custom_experiment.c \
    file://fpgatten_llama3_replay.c \
    file://fpgatten-release \
    file://fpgatten-profile.sh \
    file://fpgatten-devices.service \
    file://fpgatten-device-setup \
    file://fpgatten-info \
    file://fpgatten-run \
"

inherit systemd

SYSTEMD_SERVICE:${PN} = "fpgatten-devices.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

RDEPENDS:${PN} += "bash coreutils"

do_compile() {
    ${CC} ${CFLAGS} ${LDFLAGS} \
        ${WORKDIR}/fpgatten_uio_selftest.c -lm \
        -o ${B}/fpgatten-selftest
    ${CC} ${CFLAGS} ${LDFLAGS} \
        ${WORKDIR}/fpgatten_uio_benchmark.c -lm \
        -o ${B}/fpgatten-benchmark
    ${CC} ${CFLAGS} ${LDFLAGS} \
        ${WORKDIR}/fpgatten_experiment.c \
        ${WORKDIR}/fpgatten_custom_experiment.c -lm \
        -o ${B}/fpgatten-experiment
    ${CC} ${CFLAGS} ${LDFLAGS} \
        ${WORKDIR}/fpgatten_experiment.c \
        ${WORKDIR}/fpgatten_llama3_replay.c -lm \
        -o ${B}/fpgatten-replay
}

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${B}/fpgatten-selftest ${D}${bindir}/fpgatten-selftest
    install -m 0755 ${B}/fpgatten-benchmark ${D}${bindir}/fpgatten-benchmark
    install -m 0755 ${B}/fpgatten-experiment ${D}${bindir}/fpgatten-experiment
    install -m 0755 ${B}/fpgatten-replay ${D}${bindir}/fpgatten-replay
    install -m 0755 ${WORKDIR}/fpgatten-info ${D}${bindir}/fpgatten-info
    install -m 0755 ${WORKDIR}/fpgatten-run ${D}${bindir}/fpgatten-run

    install -d ${D}${sysconfdir}
    install -m 0644 ${WORKDIR}/fpgatten-release ${D}${sysconfdir}/fpgatten-release

    install -d ${D}${sysconfdir}/profile.d
    install -m 0644 ${WORKDIR}/fpgatten-profile.sh \
        ${D}${sysconfdir}/profile.d/fpgatten.sh

    install -d ${D}${libexecdir}
    install -m 0755 ${WORKDIR}/fpgatten-device-setup \
        ${D}${libexecdir}/fpgatten-device-setup

    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/fpgatten-devices.service \
        ${D}${systemd_system_unitdir}/fpgatten-devices.service
}

FILES:${PN} += " \
    ${sysconfdir}/fpgatten-release \
    ${sysconfdir}/profile.d/fpgatten.sh \
    ${libexecdir}/fpgatten-device-setup \
    ${systemd_system_unitdir}/fpgatten-devices.service \
"

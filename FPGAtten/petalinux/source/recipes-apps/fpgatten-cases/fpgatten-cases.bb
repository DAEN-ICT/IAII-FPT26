SUMMARY = "Real Llama3-8B Q/K/V and Golden cases for FPGAtten"
LICENSE = "CLOSED"

SRC_URI = "file://cases/"
do_install() {
    install -d ${D}/opt/fpgatten/cases
    : > ${D}/opt/fpgatten/cases/INDEX.tsv
    printf 'mode\tcontext\tlayer\n' >> ${D}/opt/fpgatten/cases/INDEX.tsv

    for source_case in $(find ${WORKDIR}/cases -mindepth 3 -maxdepth 3 -type d | sort); do
        relative=${source_case#${WORKDIR}/cases/}
        destination=${D}/opt/fpgatten/cases/${relative}
        install -d ${destination}
        for payload in q_bf16_le.bin k_bf16_le.bin v_bf16_le.bin o_fp32_golden_le.bin; do
            install -m 0644 ${source_case}/${payload} ${destination}/${payload}
        done
        (
            cd ${destination}
            sha256sum q_bf16_le.bin k_bf16_le.bin v_bf16_le.bin \
                o_fp32_golden_le.bin > SHA256SUMS
        )
        mode=$(printf '%s' "${relative}" | cut -d/ -f1)
        context=$(printf '%s' "${relative}" | cut -d/ -f2 | sed 's/^context_//')
        layer=$(printf '%s' "${relative}" | cut -d/ -f3 | sed 's/^layer_//')
        printf '%s\t%s\t%s\n' "${mode}" "${context}" "${layer}" \
            >> ${D}/opt/fpgatten/cases/INDEX.tsv
    done
}

FILES:${PN} += "/opt/fpgatten/cases"

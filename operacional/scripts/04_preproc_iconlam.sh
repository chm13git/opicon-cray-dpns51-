#!/bin/bash -l

# Script: 04_preproc_iconlam.sh
# Função: aguarda e valida dados de entrada e coordena 04.1/04.2.
# Uso: $0 HH | $0 HH GRID | $0 HH GRID IPROG FPROG [DATE]
# Dependências do 00: OPERACIONAL_DIR, GRID_DIR, GRID_FPROG,
# GRID_PROG_INT, SCRIPTS_DIR, DATES_DIR, log_info(), log_debug(),
# log_error() e ecflow_event().
# Códigos: 11 argumentos/rodada; 12 grade; 21 diretório/arquivo;
# 22 timeout icon_new; 23 timeout prognóstico; 24 erro de entrada;
# códigos 31+ são preservados dos scripts subordinados.

preproc()
{
    local HH="$1" GRID="$2" IPROG="$3" FPROG="$4" DATE="$5"
    local INDIR="${GRID_INPUTDATA_DIR[$GRID]}${HH}"
    local DATADIR="${GRID_INPUTDATAREADY_DIR[$GRID]}${HH}"
    local DATETIME="${DATE}${HH}" SLEEP=30 MAX=720 i prog FILEN FLAG REFDATE STATUS
    local PROG_INT="${GRID_PROG_INT[$GRID]:-3}"

    # Neris: mantive isso enquanto não implementamos a lbc de 1h/1h
    if [[ "${GRID}" == "sse" || "${GRID}" == "pen" ]]; then PROG_INT=3; fi

    [ "${IPROG}" = default ] && IPROG=0
    [ "${FPROG}" = default ] && FPROG="${GRID_FPROG[$GRID]}"
    if ! [[ "${IPROG}" =~ ^[0-9]+$ && "${FPROG}" =~ ^[0-9]+$ ]] || [ "${IPROG}" -gt "${FPROG}" ]; then
        log_error 11 ARGUMENTOS "Intervalo de prognóstico inválido: IPROG=${IPROG}, FPROG=${FPROG}."
        return 11
    fi
    if ! [[ "${PROG_INT}" =~ ^[1-9][0-9]*$ ]]; then
        log_error 12 CONFIGURACAO "Intervalo de prognóstico inválido para ${GRID}: ${PROG_INT}."
        return 12
    fi
    if [ ! -d "${INDIR}" ] || [ ! -d "${DATADIR}" ]; then
        log_error 21 DIRETORIOS "Diretório de entrada/saída ausente: ${INDIR} ou ${DATADIR}."
        return 21
    fi
    cd "${DATADIR}" || { log_error 21 DIRETORIO_TRABALHO "Não foi possível acessar ${DATADIR}."; return 21; }

    log_info INICIO "Iniciando pré-processamento: grade=${GRID}, rodada=${HH}, data=${DATE}, prognósticos=${IPROG}-${FPROG}, intervalo=${PROG_INT} h."

    # Wait for icon_new from the requested date and cycle.
    for ((i=1; i<=MAX; i++)); do
        log_debug ICON_NEW "Tentativa ${i}/${MAX}; aguardando ${INDIR}/icon_new.bz2."
        cp -f "${INDIR}/icon_new.bz2" . 2>/dev/null
        if [ -f icon_new.bz2 ]; then
            bunzip2 -f icon_new.bz2 || { log_error 24 ICON_NEW "Falha ao descompactar icon_new.bz2."; return 24; }
        fi
        if [ -f icon_new ] && [ "$(head -1 icon_new)$(head -2 icon_new | tail -1)" = "${DATETIME}" ]; then
            echo "$(date) - The data reception has already started" > "ICONDATA_${DATETIME}"
            log_info ICON_NEW "Arquivo icon_new validado para ${DATETIME}."
            break
        fi
        rm -f icon_new
        sleep "${SLEEP}"
    done
    if [ "${i}" -gt "${MAX}" ]; then
        log_error 22 TIMEOUT_ICON_NEW "Arquivo icon_new não ficou disponível para ${GRID}/${DATETIME} após 6 horas."
        return 22
    fi

    # Process each forecast hour once. The sleep is only used while waiting.
    for ((prog=IPROG; prog<=FPROG; prog+=PROG_INT)); do
        FILEN=$(printf 'igfff%02d%02d0000' $((prog / 24)) $((prog % 24)))
        FLAG="${DATADIR}/${FILEN}_${DATE}_OK"
        command -v ecflow_client >/dev/null 2>&1 && ecflow_client --meter=progress "${prog}" >/dev/null 2>&1 || true
        log_info AGUARDANDO_PROGNOSTICO "Aguardando ${FILEN} para ${DATE}; prognóstico=${prog} h."
        log_debug PROGNOSTICO "Arquivo de entrada=${INDIR}/${FILEN}.bz2; marcador=${FLAG}."

        for ((i=1; i<=MAX; i++)); do
            if [ -f "${FLAG}" ]; then
                log_debug MARCADOR_OK "Marcador existente: ${FLAG}."
                break
            fi

            if [ -f "${INDIR}/${FILEN}.bz2" ]; then
                cp -f "${INDIR}/${FILEN}.bz2" "${DATADIR}/" || { log_error 24 COPIA_ENTRADA "Falha ao copiar ${FILEN}.bz2."; return 24; }
                bunzip2 -f "${DATADIR}/${FILEN}.bz2" || { log_error 24 DESCOMPACTACAO "Falha ao descompactar ${FILEN}.bz2."; return 24; }
            fi

            if [ -f "${DATADIR}/${FILEN}" ]; then
                REFDATE=$(grib_ls -p dataDate "${DATADIR}/${FILEN}" 2>/dev/null | head -3 | tail -1 | xargs)
                log_debug VALIDACAO_DATA "Arquivo=${FILEN}; data encontrada=${REFDATE}; esperada=${DATE}."
                if [ "${REFDATE}" = "${DATE}" ]; then
                    touch "${FLAG}" || { log_error 24 MARCADOR_OK "Falha ao criar ${FLAG}."; return 24; }
                    log_info VALIDACAO_DATA "Data de ${FILEN} validada (${REFDATE}); marcador criado."
                    break
                else
                    log_debug DATA_DIVERGENTE "${FILEN}: data ${REFDATE:-indisponível}; esperada ${DATE}."
                    rm -f "${DATADIR}/${FILEN}"
                fi
            fi
            sleep "${SLEEP}"
        done

        if [ "${i}" -gt "${MAX}" ]; then
            log_error 23 TIMEOUT_PROGNOSTICO "Arquivo ${FILEN} não ficou disponível/validado após 6 horas."
            return 23
        fi

        # This block is intentionally outside the wait loop: process once only.
        if [ "${FILEN}" = igfff00000000 ]; then
            log_info CONDICAO_INICIAL "Executando 04.1 para ${FILEN}."
            log_debug CONDICAO_INICIAL "Comando: ${SCRIPTS_DIR}/04.1_create_initcond_iconlam.sh ${HH} ${GRID}."
            "${SCRIPTS_DIR}/04.1_create_initcond_iconlam.sh" "${HH}" "${GRID}"
            STATUS=$?
            if [ "${STATUS}" -ne 0 ]; then
                log_error "${STATUS}" CONDICAO_INICIAL "04.1 falhou para ${GRID}/${HH}; código retornado=${STATUS}."
                return "${STATUS}"
            fi
        fi

        log_info CONDICAO_CONTORNO "Executando 04.2 para ${FILEN}."
        log_debug CONDICAO_CONTORNO "Comando: ${SCRIPTS_DIR}/04.2_create_latbc_iconlam.sh ${HH} ${GRID} ${FILEN}."
        "${SCRIPTS_DIR}/04.2_create_latbc_iconlam.sh" "${HH}" "${GRID}" "${FILEN}"
        STATUS=$?
        if [ "${STATUS}" -ne 0 ]; then
            log_error "${STATUS}" CONDICAO_CONTORNO "04.2 falhou para ${GRID}/${HH}/${FILEN}; código retornado=${STATUS}."
            return "${STATUS}"
        fi
        log_info PROGNOSTICO_CONCLUIDO "Concluído ${GRID}/${HH}/${FILEN}."
    done
    log_info FIM_GRADE "Pré-processamento concluído para ${GRID}/${HH}."
    return 0
}

if [ $# -ne 1 ] && [ $# -ne 2 ] && [ $# -ne 4 ] && [ $# -ne 5 ]; then
    echo "Usage: $0 HH [GRID [IPROG FPROG [DATE]]]"
    log_error 11 ARGUMENTOS "Número de argumentos inválido: $#; esperado 1, 2, 4 ou 5."
    exit 11
fi

HH="$1"
if [[ ! "${HH}" =~ ^(00|12)$ ]]; then
    log_error 11 RODADA "Rodada inválida: ${HH}; use 00 ou 12."
    exit 11
fi

DATE="${5:-}"
if [ -z "${DATE}" ]; then
    DATEFILE="${DATES_DIR}/currentdate${HH}"
    if [ ! -r "${DATEFILE}" ]; then
        log_error 21 DATA_ATUAL "Arquivo de data não encontrado/legível: ${DATEFILE}."
        exit 21
    fi
    DATE=$(<"${DATEFILE}")
fi
if ! [[ "${DATE}" =~ ^[0-9]{8}$ ]]; then
    log_error 11 DATA "Data inválida: ${DATE}; esperado YYYYMMDD."
    exit 11
fi

if [ "${DEBUG:-0}" = 1 ]; then
    log_debug DEBUG_ATIVO "Modo debug ativado; saída detalhada habilitada."
fi

# Garante que o diretório dos logs exista antes dos redirecionamentos.
mkdir -p "${LOG_DIR}" || { echo "Erro: não foi possível criar ${LOG_DIR}." >&2; exit 21; }

if [ $# -eq 1 ]; then
    if [ ! -r "${SCRIPTS_DIR}/runlist" ]; then
        log_error 21 RUNLIST "Arquivo runlist não encontrado/legível: ${SCRIPTS_DIR}/runlist."
        exit 21
    fi
    #while read -r GRID; do
    #    [ -z "${GRID}" ] && continue
    #    [ -n "${GRID_DIR[$GRID]+x}" ] || { log_error 12 GRADE "Grade inválida no runlist: ${GRID}."; exit 12; }
    #    preproc "${HH}" "${GRID}" default default "${DATE}"
    #    STATUS=$?
    #    [ "${STATUS}" -eq 0 ] || exit "${STATUS}"
    #done < "${SCRIPTS_DIR}/runlist"
    # Lê a linha do arquivo e divide os elementos separados por espaço em um array
    read -r -a GRIDS < "${SCRIPTS_DIR}/runlist"

    # Loop através de cada elemento do array
    for GRID in "${GRIDS[@]}"; do
        [ -z "${GRID}" ] && continue
        [ -n "${GRID_DIR[$GRID]+x}" ] || { log_error 12 GRADE "Grade inválida no runlist: ${GRID}."; exit 12; }

        LOGFILE="${LOG_DIR}/04_${HH}_${GRID}.log"
        preproc "${HH}" "${GRID}" default default "${DATE}" >"${LOGFILE}" 2>&1
        STATUS=$?
        [ "${STATUS}" -eq 0 ] || exit "${STATUS}"
    done
else
    GRID="$2"
    [ -n "${GRID_DIR[$GRID]+x}" ] || { log_error 12 GRADE "Grade inválida: ${GRID}."; exit 12; }
    LOGFILE="${LOG_DIR}/04_${HH}_${GRID}.log"
    if [ $# -eq 2 ]; then
        preproc "${HH}" "${GRID}" default default "${DATE}" >"${LOGFILE}" 2>&1
    else
        preproc "${HH}" "${GRID}" "$3" "$4" "${DATE}" >"${LOGFILE}" 2>&1
    fi
    STATUS=$?
    [ "${STATUS}" -eq 0 ] || exit "${STATUS}"
fi

if [ -n "${GRID:-}" ]; then
    LOGFILE="${LOG_DIR}/04_${HH}_${GRID}.log"
    log_info FIM "Pré-processamento finalizado com sucesso." >>"${LOGFILE}" 2>&1
fi
ecflow_event PreProc_SAFO
exit 0

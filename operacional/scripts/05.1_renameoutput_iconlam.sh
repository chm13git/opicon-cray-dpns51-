#!/bin/bash -l
# Renomeia os arquivos de previsão do ICON-LAM.
# Autor: CT(T) Neris

SCRIPT="05.1_renameoutput_iconlam"

fail() {
    local CODE="$1" STEP="$2" MESSAGE="$3"
    if command -v log_error >/dev/null 2>&1; then log_error "$CODE" "$STEP" "$MESSAGE"; else printf '%s | ERROR | %s | %s | rc=%s | %s\n' "$(date '+%F %T')" "$SCRIPT" "$STEP" "$CODE" "$MESSAGE" >&2; fi
    exit "$CODE"
}
info() { if command -v log_info >/dev/null 2>&1; then log_info "$1" "$2"; else printf '%s | INFO | %s | %s | %s\n' "$(date '+%F %T')" "$SCRIPT" "$1" "$2"; fi; }
debug() { if command -v log_debug >/dev/null 2>&1; then log_debug "$1" "$2"; elif [ "${DEBUG:-0}" = 1 ]; then printf '%s | DEBUG | %s | %s | %s\n' "$(date '+%F %T')" "$SCRIPT" "$1" "$2"; fi; }

[ "$#" -eq 2 ] || [ "$#" -eq 4 ] || [ "$#" -eq 5 ] || fail 11 ARGUMENTOS "Uso: $0 HH AREA [HSTART HSTOP [DATE]]."
HH="$1"
AREA="$2"
HSTART="${3:-}"
HSTOP="${4:-}"
DATE="${5:-}"
[[ "$HH" =~ ^(00|12)$ ]] || fail 11 ARGUMENTOS "HH deve ser 00 ou 12; recebido: ${HH}."
[[ -n "${GRID_DIR[$AREA]+x}" ]] || fail 12 CONFIGURACAO "Grade inválida: ${AREA}."

if [ -z "$HSTART" ] && [ -z "$HSTOP" ]; then
    HSTART=0
    HSTOP="${GRID_FPROG[$AREA]}"
elif [ -z "$HSTART" ] || [ -z "$HSTOP" ]; then
    fail 11 INTERVALO "HSTART e HSTOP devem ser informados juntos."
fi
[[ "$HSTART" =~ ^[0-9]+$ && "$HSTOP" =~ ^[0-9]+$ ]] || fail 11 INTERVALO "HSTART e HSTOP devem ser inteiros não negativos."
PROG_INT="${GRID_PROG_INT[$AREA]:-}"
[[ "$PROG_INT" =~ ^[0-9]+$ ]] && [ "$PROG_INT" -gt 0 ] || fail 12 CONFIGURACAO "GRID_PROG_INT inválido para ${AREA}."
[ "$HSTART" -le "$HSTOP" ] || fail 11 INTERVALO "HSTART (${HSTART}) é maior que HSTOP (${HSTOP})."
[ "$((HSTART % PROG_INT))" -eq 0 ] && [ "$((HSTOP % PROG_INT))" -eq 0 ] || fail 11 INTERVALO "HSTART/HSTOP devem ser múltiplos do intervalo ${PROG_INT} h da grade ${AREA}."
[ "$HSTOP" -le "${GRID_FPROG[$AREA]}" ] || fail 11 INTERVALO "HSTOP excede a previsão configurada (${GRID_FPROG[$AREA]} h)."

if [ -n "$DATE" ]; then CURRDATE="$DATE"; else
    DATEFILE="${DATES_DIR}/currentdate${HH}"
    [ -r "$DATEFILE" ] || fail 21 DATA "Arquivo de data ausente ou ilegível: ${DATEFILE}."
    CURRDATE="$(<"$DATEFILE")"
fi
[[ "$CURRDATE" =~ ^[0-9]{8}$ ]] || fail 11 DATA "Data inválida: ${CURRDATE}; esperado YYYYMMDD."
date -u -d "$CURRDATE" >/dev/null 2>&1 || fail 11 DATA "Data inválida: ${CURRDATE}."

DOMAIN="${GRID_DIR[$AREA]}"
NVARML="${GRID_NVARML[$AREA]:-}"
NVARPL="${GRID_NVARPL[$AREA]:-}"
OUTDIR="${GRID_OUTPUTDATA_DIR[$AREA]}${HH}"
[ -d "$OUTDIR" ] || fail 21 DIRETORIO "Diretório de saída não encontrado: ${OUTDIR}."
command -v grib_count >/dev/null 2>&1 || fail 41 VALIDACAO_GRIB2 "Comando grib_count não encontrado no PATH."
[[ "$NVARML" =~ ^[0-9]+$ && "$NVARPL" =~ ^[0-9]+$ ]] || fail 12 CONFIGURACAO "Contagens GRID_NVARML/GRID_NVARPL ausentes ou inválidas para ${AREA}."

NMAX=720
SLTIME=30
INUM=$((HSTART / PROG_INT + 1))
FNUM=$((HSTOP / PROG_INT + 1))
info INICIO "Renomeação: grade=${AREA} (${DOMAIN}), ciclo=${HH}, data=${CURRDATE}, intervalo=${HSTART}-${HSTOP} h."

for NUM in $(seq "$INUM" "$FNUM"); do
    NUMGRB=$(printf '%04d' "$NUM")
    PROG=$((NUM * PROG_INT - PROG_INT))
    NUMPROG=$(printf '%03d' "$PROG")
    NUMPROG2=$(printf '%02d' "$PROG")
    RESTOPROG=$((PROG % 24))
    MLFILE="${OUTDIR}/iconlam_${AREA}_${HH}_${CURRDATE}_${NUMGRB}_ml.grb"
    NMLFILE="${OUTDIR}/iconlam_${DOMAIN}_${HH}_${CURRDATE}_${NUMPROG}_ml.grb"
    PLFILE="${OUTDIR}/iconlam_${AREA}_${HH}_${CURRDATE}_${NUMGRB}_pl.grb"
    NPLFILE="${OUTDIR}/iconlam_${DOMAIN}_${HH}_${CURRDATE}_${NUMPROG}_pl.grb"
    NUMNC=$(printf '%04d' "$((PROG / 24))")
    UVFILE="${OUTDIR}/iconlam_${AREA}_${HH}_${CURRDATE}_${NUMNC}_uv.nc"
    NUVFILE="${OUTDIR}/iconlam_uv_${CURRDATE}${HH}_${NUMPROG2}.nc"

    NEED_UV=0
    if [ "$AREA" = sam ] && [ "$NUM" -gt 1 ] && [ "$RESTOPROG" -eq 0 ]; then NEED_UV=1; fi
    ATTEMPT=0
    while :; do
        ATTEMPT=$((ATTEMPT + 1))
        ML_OK=0
        PL_OK=0
        UV_OK=1

        if [ -s "$NMLFILE" ] && [ -s "$NPLFILE" ]; then
            debug VALIDACAO "Saídas ML/PL já renomeadas para ${PROG} h."
            ML_OK=1; PL_OK=1
        elif [ -s "$MLFILE" ] && [ -s "$PLFILE" ]; then
            ML_COUNT=$(grib_count "$MLFILE" 2>/dev/null) || ML_COUNT=ERROR
            PL_COUNT=$(grib_count "$PLFILE" 2>/dev/null) || PL_COUNT=ERROR
            debug VALIDACAO "${MLFILE}: ${ML_COUNT}/${NVARML}; ${PLFILE}: ${PL_COUNT}/${NVARPL}."
            if [ "$ML_COUNT" = "$NVARML" ] && [ "$PL_COUNT" = "$NVARPL" ]; then
                mv -- "$MLFILE" "$NMLFILE" || fail 43 RENOMEACAO "Falha ao renomear ${MLFILE} para ${NMLFILE}."
                mv -- "$PLFILE" "$NPLFILE" || fail 43 RENOMEACAO "Falha ao renomear ${PLFILE} para ${NPLFILE}."
                info RENOMEACAO "Arquivos ML/PL renomeados para ${PROG} h."
                ML_OK=1; PL_OK=1
            else
                debug VALIDACAO "Arquivos ML/PL ainda incompletos para ${PROG} h (tentativa ${ATTEMPT}/${NMAX})."
            fi
        else
            debug ESPERA "Aguardando arquivos ML/PL para ${PROG} h (tentativa ${ATTEMPT}/${NMAX})."
        fi

        if [ "$NEED_UV" -eq 1 ]; then
            if [ -s "$NUVFILE" ]; then
                debug VALIDACAO "Arquivo UV já renomeado: ${NUVFILE}."
            elif [ -s "$UVFILE" ]; then
                mv -- "$UVFILE" "$NUVFILE" || fail 43 RENOMEACAO "Falha ao renomear ${UVFILE} para ${NUVFILE}."
                info RENOMEACAO "Arquivo UV renomeado para ${PROG} h."
            else
                UV_OK=0
                debug ESPERA "Aguardando UV ${UVFILE} (tentativa ${ATTEMPT}/${NMAX})."
            fi
        fi

        if [ "$ML_OK" -eq 1 ] && [ "$PL_OK" -eq 1 ] && [ "$UV_OK" -eq 1 ]; then break; fi
        if [ "$ATTEMPT" -ge "$NMAX" ]; then fail 24 TIMEOUT "Arquivos da previsão ${PROG} h não ficaram prontos após $((NMAX * SLTIME / 60)) minutos. ML=${MLFILE}; PL=${PLFILE}; UV=${UVFILE}."; fi
        sleep "$SLTIME"
    done

done
info FINALIZACAO "Renomeação concluída para ${AREA}, ${CURRDATE} ${HH}Z."
exit 0

#!/bin/bash -lx

# Script: 04.2_create_latbc_iconlam.sh
# Função: gera condições de contorno, valida o GRIB2 e publica apenas se válido.
# Uso: $0 HH GRID INPROGF
# Códigos: 11 argumentos/rodada; 12 grade; 21 caminhos ausentes;
# 31 preparação de namelist; 32 ICONSUB; 33 ICONREMAP;
# 41 grib_count/leitura; 42 contagem incorreta; 43 publicação.

if [ $# -ne 3 ]; then
    echo "Usage: $0 <HH> <GRID> <INPROGF>"
    log_error 11 ARGUMENTOS "Uso inválido; esperado HH GRID INPROGF."
    exit 11
fi
HH="$1"
GRID="$2"
INPROGF="$3"

if [[ ! "${HH}" =~ ^(00|12)$ ]]; then
    log_error 11 RODADA "Rodada inválida: ${HH}; use 00 ou 12."
    exit 11
fi
[ -n "${GRID_DIR[$GRID]+x}" ] || { log_error 12 GRADE "Grade inválida: ${GRID}."; exit 12; }

INGRID="${GRID_INGRID[$GRID]}"
LOCALGRID="${GRID_LOCALGRID[$GRID]}"
DATADIR="${GRID_INPUTDATAREADY_DIR[$GRID]}${HH}"
OUTDIR="${GRID_INITIALCOND_DIR[$GRID]}${HH}"
if [ ! -d "${DATADIR}" ] || [ ! -d "${OUTDIR}" ]; then
    log_error 21 CAMINHOS "Diretório de entrada/saída ausente para ${GRID}/${HH}."
    exit 21
fi

log_info INICIO "Gerando condição de contorno: grade=${GRID}, rodada=${HH}, arquivo=${INPROGF}."

# ICONSUB is needed only when its remapping grid does not already exist.
if [ ! -f "${OUTDIR}/lateral_boundary.grid.nc" ]; then
    TEMPLATE="${GRID_TEMPLATE_LBC_SUB[$GRID]}"
    [ -f "${TEMPLATE}" ] || { log_error 21 TEMPLATE_ICONSUB "Template ausente: ${TEMPLATE}."; exit 21; }
    sed \
        -e "s|GRIDNAME_ARG|${GRID}|g" \
        -e "s|INGRID_ARG|${INGRID}|g" \
        -e "s|LOCALGRID_ARG|${LOCALGRID}|g" \
        -e "s|DATADIR_ARG|${DATADIR}|g" \
        -e "s|OUTDIR_ARG|${OUTDIR}|g" \
        "${TEMPLATE}" > "temp_iconsub_${GRID}.sh" || { log_error 31 NAMELIST_ICONSUB "Falha ao gerar script ICONSUB."; exit 31; }
    chmod +x "temp_iconsub_${GRID}.sh" || { log_error 31 NAMELIST_ICONSUB "Falha ao tornar executável o script ICONSUB."; exit 31; }
    "./temp_iconsub_${GRID}.sh"
    STATUS=$?
    [ "${STATUS}" -eq 0 ] || { log_error 31 NAMELIST_ICONSUB "Falha na geração do namelist; status=${STATUS}."; exit 31; }

    log_info ICONSUB "Executando ICONSUB para gerar lateral_boundary.grid.nc."
    time LD_PRELOAD="${ICONTOOLS_LIB}/libcdi.so.0" \
    "${MPI_LAUNCH}" -np 1 "${BINARY_ICONSUB}" --nml NAMELIST_ICONSUB
    STATUS=$?
    if [ "${STATUS}" -ne 0 ]; then
        log_error 32 ICONSUB "ICONSUB falhou; status original=${STATUS}."
        exit 32
    fi
else
    log_debug ICONSUB "Reutilizando ${OUTDIR}/lateral_boundary.grid.nc; ICONSUB não necessário."
fi

TEMPLATE="${GRID_TEMPLATE_LBC_IR[$GRID]}"
FINALFILE="${OUTDIR}/${INPROGF}_lbc.grb2"
[ -f "${TEMPLATE}" ] || { log_error 21 TEMPLATE_ICONREMAP "Template ausente: ${TEMPLATE}."; exit 21; }
sed \
    -e "s|FILENAME_ARG|${INPROGF}|g" \
    -e "s|GRIDNAME_ARG|${GRID}|g" \
    -e "s|INGRID_ARG|${INGRID}|g" \
    -e "s|LOCALGRID_ARG|${LOCALGRID}|g" \
    -e "s|DATADIR_ARG|${DATADIR}|g" \
    -e "s|OUTDIR_ARG|${OUTDIR}|g" \
    "${TEMPLATE}" > "temp_iconremap_${GRID}.sh" || { log_error 31 NAMELIST_ICONREMAP "Falha ao gerar script ICONREMAP."; exit 31; }
chmod +x "temp_iconremap_${GRID}.sh" || { log_error 31 NAMELIST_ICONREMAP "Falha ao tornar executável o script ICONREMAP."; exit 31; }
"./temp_iconremap_${GRID}.sh"
STATUS=$?
[ "${STATUS}" -eq 0 ] || { log_error 31 NAMELIST_ICONREMAP "Falha na geração do namelist; status=${STATUS}."; exit 31; }

rm -f -- "${FINALFILE%.grb2}.tmp.grb2" "${FINALFILE}.tmp"
set_tmp_grib_output NAMELIST_ICONREMAP || exit $?
log_info ICONREMAP "Executando ICONREMAP para ${INPROGF}."
LD_PRELOAD="${ICONTOOLS_LIB}/libcdi.so.0" \
"${MPI_LAUNCH}" -np 1 "${BINARY_REMAP}" \
    -q --remap_nml NAMELIST_ICONREMAP \
    --input_field_nml NAMELIST_ICONREMAP_FIELDS
STATUS=$?
if [ "${STATUS}" -ne 0 ]; then
    log_error 33 ICONREMAP "ICONREMAP falhou; status original=${STATUS}; saída temporária mantida quando existir."
    exit 33
fi

if [ "${INPROGF}" = "igfff00000000" ]; then EXPECTED=981; else EXPECTED=891; fi
validate_publish_grib "${FINALFILE}" "${EXPECTED}"
STATUS=$?
[ "${STATUS}" -eq 0 ] || exit "${STATUS}"
rm -f temp_*.sh raw_${GRID} raw2_${GRID} ncstorage.tmp* ml.log NAMELIST_ICONREMAP NAMELIST_ICONREMAP_FIELDS
[ "${INPROGF}" != "igfff05000000" ] || rm -f NAMELIST_ICONSUB
log_info FIM "Condição de contorno validada e publicada: ${FINALFILE}."
exit 0

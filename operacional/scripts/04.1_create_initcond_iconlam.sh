#!/bin/bash -lx

# Script: 04.1_create_initcond_iconlam.sh
# Função: gera a condição inicial, valida o GRIB2 e publica apenas se válida.
# Uso: $0 HH GRID
# Códigos: 11 argumentos/rodada; 12 grade; 21 caminhos ausentes;
# 31 preparação de namelist; 33 ICONREMAP; 41/42/43 validação/publicação.

if [ $# -ne 2 ]; then
    echo "Usage: $0 <HH> <GRID>"
    log_error 11 ARGUMENTOS "Uso inválido; esperado HH GRID."
    exit 11
fi
HH="$1"
GRID="$2"

if [[ ! "${HH}" =~ ^(00|12)$ ]]; then
    log_error 11 RODADA "Rodada inválida: ${HH}; use 00 ou 12."
    exit 11
fi
[ -n "${GRID_DIR[$GRID]+x}" ] || { log_error 12 GRADE "Grade inválida: ${GRID}."; exit 12; }

INGRID="${GRID_INGRID[$GRID]}"
LOCALGRID="${GRID_LOCALGRID[$GRID]}"
TEMPLATE="${GRID_TEMPLATE_IC_IR[$GRID]}"
DATADIR="${GRID_INPUTDATAREADY_DIR[$GRID]}${HH}"
OUTDIR="${GRID_INITIALCOND_DIR[$GRID]}${HH}"
ICFILE="igfff00000000"
FINALFILE="${OUTDIR}/${ICFILE}.grb2"

if [ ! -f "${TEMPLATE}" ] || [ ! -d "${DATADIR}" ] || [ ! -d "${OUTDIR}" ]; then
    log_error 21 CAMINHOS "Template ou diretório de entrada/saída ausente para ${GRID}/${HH}."
    exit 21
fi

log_info INICIO "Gerando condição inicial: grade=${GRID}, rodada=${HH}, data=${FINALFILE}."
log_debug TEMPLATE "Template=${TEMPLATE}; INGRID=${INGRID}; LOCALGRID=${LOCALGRID}; DATADIR=${DATADIR}; OUTDIR=${OUTDIR}."

sed \
    -e "s|GRIDNAME_ARG|${GRID}|g" \
    -e "s|INGRID_ARG|${INGRID}|g" \
    -e "s|LOCALGRID_ARG|${LOCALGRID}|g" \
    -e "s|DATADIR_ARG|${DATADIR}|g" \
    -e "s|ICFILE_ARG|${ICFILE}|g" \
    -e "s|OUTDIR_ARG|${OUTDIR}|g" \
    "${TEMPLATE}" > "temp_tmpl_create_ic_nml_ir_${GRID}.sh" || { log_error 31 NAMELIST "Falha ao gerar script a partir de ${TEMPLATE}."; exit 31; }
chmod +x "temp_tmpl_create_ic_nml_ir_${GRID}.sh" || { log_error 31 NAMELIST "Falha ao tornar executável o script temporário."; exit 31; }
"./temp_tmpl_create_ic_nml_ir_${GRID}.sh"
STATUS=$?
[ "${STATUS}" -eq 0 ] || { log_error 31 NAMELIST "Falha na geração dos namelists; status=${STATUS}."; exit 31; }

rm -f -- "${FINALFILE%.grb2}.tmp.grb2" "${FINALFILE}.tmp"
set_tmp_grib_output NAMELIST_ICONREMAP || exit $?

log_info ICONREMAP "Executando ICONREMAP para condição inicial."
log_debug ICONREMAP "Binário=${BINARY_REMAP}; MPI=${MPI_LAUNCH}; namelist=NAMELIST_ICONREMAP."
time LD_PRELOAD="${ICONTOOLS_LIB}/libcdi.so.0" \
"${MPI_LAUNCH}" -np 1 "${BINARY_REMAP}" \
    -vvv --remap_nml NAMELIST_ICONREMAP \
    --input_field_nml NAMELIST_ICONREMAP_FIELDS
STATUS=$?
if [ "${STATUS}" -ne 0 ]; then
    log_error 33 ICONREMAP "ICONREMAP falhou; status original=${STATUS}; saída temporária mantida quando existir."
    exit 33
fi

validate_publish_grib "${FINALFILE}" 1033
STATUS=$?
[ "${STATUS}" -eq 0 ] || exit "${STATUS}"
rm -f temp_*.sh raw_${GRID} raw2_${GRID} ncstorage.tmp* ml.log NAMELIST_ICONREMAP NAMELIST_ICONREMAP_FIELDS
log_info FIM "Condição inicial validada e publicada: ${FINALFILE}."
exit 0

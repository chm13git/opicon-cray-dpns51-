#!/bin/bash -l
# Executa o ICON-LAM.
# Autor: CT(T) Neris

SCRIPT="05_run_iconlam"

fail() {
    local CODE="$1" STEP="$2" MESSAGE="$3"
    if command -v log_error >/dev/null 2>&1; then
        log_error "$CODE" "$STEP" "$MESSAGE"
    else
        printf '%s | ERROR | %s | %s | rc=%s | %s\n' "$(date '+%F %T')" "$SCRIPT" "$STEP" "$CODE" "$MESSAGE" >&2
    fi
    exit "$CODE"
}

info() {
    if command -v log_info >/dev/null 2>&1; then log_info "$1" "$2"; else printf '%s | INFO | %s | %s | %s\n' "$(date '+%F %T')" "$SCRIPT" "$1" "$2"; fi
}

debug() {
    if command -v log_debug >/dev/null 2>&1; then log_debug "$1" "$2"; elif [ "${DEBUG:-0}" = 1 ]; then printf '%s | DEBUG | %s | %s | %s\n' "$(date '+%F %T')" "$SCRIPT" "$1" "$2"; fi
}

# Executa uma grade. A chamada ocorre em subshell para que cada grade tenha
# seu próprio redirecionamento de log, sem misturar logs entre grades.
run_icon() {
    local HH="$1" GRID="$2" DATE_ARG="${3:-}" CURRDATE
    local RUN_LOG DOMAIN MODEL MPIEXEC LOCALGRID RADGRID EXTPARGRID TEMPLATE
    local LBCDIR OUTDIR LBCGRID ICFILE RUNNODES FORECAST_TIME HSTART HSTOP
    local HOST_LIST NUM_TOTAL_PROCS NODE NPROCS NODE_ENTRY NML_SCRIPT NML_FILE RENAME_LOG
    local RENAME_PID RET RENAME_RET STATUS SLEEP=30 MAX=720 ATTEMPT MISSING FILE PROG

    [[ "$HH" =~ ^(00|12)$ ]] || fail 11 ARGUMENTOS "HH deve ser 00 ou 12; recebido: ${HH}."
        if [ -n "$DATE_ARG" ]; then
        CURRDATE="$DATE_ARG"
    else
        local DATEFILE="${DATES_DIR}/currentdate${HH}"
        [ -r "$DATEFILE" ] || fail 21 DATA "Arquivo de data não encontrado ou ilegível: ${DATEFILE}."
        CURRDATE="$(<"$DATEFILE")"
    fi
    [[ "$CURRDATE" =~ ^[0-9]{8}$ ]] || fail 11 DATA "Data inválida: ${CURRDATE}; esperado YYYYMMDD."
    date -u -d "${CURRDATE} ${HH}:00:00" >/dev/null 2>&1 || fail 11 DATA "Data/hora inválida: ${CURRDATE} ${HH}."

    # Log independente por grade/ciclo/data.
    RUN_LOG="${SCRIPTS_DIR}/logs/05_${HH}_${GRID}_${CURRDATE}.log"
    mkdir -p "${SCRIPTS_DIR}/logs" || fail 21 LOGS "Não foi possível criar ${SCRIPTS_DIR}/logs."
    exec > >(tee -a "${RUN_LOG}") 2>&1
    info INICIO "Log da rodada: ${RUN_LOG}."
    if [ "${DEBUG:-0}" = 1 ]; then
        debug DEBUG_ATIVO "Modo debug ativado; saída detalhada habilitada."
    fi

[[ -n "${GRID_DIR[$GRID]+x}" ]] || fail 12 CONFIGURACAO "Grade inválida: ${GRID}."

DOMAIN="${GRID_DIR[$GRID]}"
MODEL="${BINARY_ICONMODEL:-}"
MPIEXEC="${MPI_LAUNCH:-}"
LOCALGRID="${GRID_LOCALGRID[$GRID]:-}"
RADGRID="${GRID_RADGRID[$GRID]:-}"
EXTPARGRID="${GRID_EXTPAR[$GRID]:-}"
TEMPLATE="${GRID_TEMPLATE_ICON[$GRID]:-}"
LBCDIR="${GRID_INITIALCOND_DIR[$GRID]}${HH}"
OUTDIR="${GRID_OUTPUTDATA_DIR[$GRID]}${HH}"
LBCGRID="${LBCDIR}/${GRID_LBCGRID_NAME[$GRID]}"
ICFILE="${LBCDIR}/${GRID_ICFILE_NAME[$GRID]}"
RUNNODES="${GRID_RUNNODES_FILE[$GRID]}"
FORECAST_TIME="${GRID_FPROG[$GRID]}"
HSTART="$(date -u -d "${CURRDATE} ${HH}:00:00" '+%Y-%m-%dT%H:%M:%SZ')" || fail 11 DATA "Não foi possível calcular HSTART."
HSTOP="$(date -u -d "${HSTART} + ${FORECAST_TIME} hours" '+%Y-%m-%dT%H:%M:%SZ')" || fail 11 DATA "Não foi possível calcular HSTOP."

[ -x "$MODEL" ] || fail 21 BINARIO "Executável ICON ausente ou sem permissão: ${MODEL}."
[ -n "$MPIEXEC" ] && command -v "$MPIEXEC" >/dev/null 2>&1 || [ -x "$MPIEXEC" ] || fail 21 MPI "Lançador MPI não encontrado: ${MPIEXEC}."
[ -f "$RUNNODES" ] || fail 21 NOS_MPI "Arquivo de configuração dos nós não encontrado: ${RUNNODES}."
[ -f "$TEMPLATE" ] || fail 21 TEMPLATE "Template do namelist não encontrado: ${TEMPLATE}."
[ -d "$OUTDIR" ] || fail 21 DIRETORIO "Diretório de saída não encontrado: ${OUTDIR}."
# Aguarda os cinco arquivos obrigatórios de condição inicial/de contorno.
info AGUARDANDO_DADOS "Aguardando os cinco arquivos de condição inicial/de contorno e a grade lateral (intervalo: ${SLEEP}s; timeout: 6h)."
for ((ATTEMPT=1; ATTEMPT<=MAX; ATTEMPT++)); do
    MISSING=""
    for FILE in \
        "${GRID_ICFILE_NAME[$GRID]}" \
        "igfff00000000_lbc.grb2" \
        "igfff00030000_lbc.grb2" \
        "igfff00060000_lbc.grb2" \
        "${GRID_LBCGRID_NAME[$GRID]}"; do
        if [ ! -s "${LBCDIR}/${FILE}" ]; then
            MISSING+=" ${LBCDIR}/${FILE}"
        fi
    done

    if [ -z "$MISSING" ]; then
        info DADOS_INICIAIS_CONTORNO "Os cinco arquivos obrigatórios e a grade lateral estão disponíveis."
        break
    fi

    debug AGUARDANDO_DADOS "Tentativa ${ATTEMPT}/${MAX}: aguardando arquivos:${MISSING}."
    sleep "$SLEEP"
done

if [ "$ATTEMPT" -gt "$MAX" ]; then
    fail 23 TIMEOUT_DADOS "Arquivos obrigatórios de condição inicial/de contorno e/ou grade lateral não ficaram disponíveis após 6 horas:${MISSING}."
fi

# Monta a lista de nós no formato aceito pelo MPI.
HOST_LIST=""
NUM_TOTAL_PROCS=0
while IFS=: read -r NODE NPROCS || [ -n "${NODE}${NPROCS}" ]; do
    NODE="$(printf '%s' "$NODE" | xargs)"
    NPROCS="$(printf '%s' "$NPROCS" | xargs)"
    [ -z "$NODE" ] && continue
    [[ "$NODE" =~ ^# ]] && continue
    [[ "$NPROCS" =~ ^[0-9]+$ ]] && [ "$NPROCS" -gt 0 ] || fail 22 NOS_MPI "Entrada inválida em ${RUNNODES}: ${NODE}:${NPROCS}."
    [ -n "$HOST_LIST" ] && HOST_LIST+="," 
    HOST_LIST+="${NODE}:${NPROCS}"
    NUM_TOTAL_PROCS=$((NUM_TOTAL_PROCS + NPROCS))
done < "$RUNNODES"
[ "$NUM_TOTAL_PROCS" -gt 0 ] || fail 22 NOS_MPI "Nenhum processo MPI definido em ${RUNNODES}."

info CONFIGURACAO "Início: grade=${GRID} (${DOMAIN}), data=${CURRDATE}, ciclo=${HH}, previsão=${FORECAST_TIME} h."
info CONFIGURACAO "Nós: ${HOST_LIST}; total de processos MPI: ${NUM_TOTAL_PROCS}."

for NODE_ENTRY in ${HOST_LIST//,/ }; do
    NODE="${NODE_ENTRY%%:*}"
    debug TESTE_NOS "Verificando acesso SSH ao nó ${NODE}."
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$NODE" hostname >/dev/null 2>&1 || fail 22 TESTE_NOS "Nó ${NODE} inacessível por SSH."
done

cd "$OUTDIR" || fail 21 DIRETORIO "Não foi possível acessar ${OUTDIR}."
NML_SCRIPT="temp_create_icon_nml_${GRID}.sh"
RENAME_LOG="${SCRIPTS_DIR}/logs/rename_${GRID}_${HH}_${CURRDATE}.log"

info NAMELIST "Gerando namelist ICON a partir de ${TEMPLATE}; saída registrada no log da rodada."
sed \
    -e "s|HH_ARG|${HH}|g" \
    -e "s|GRIDNAME_ARG|${GRID}|g" \
    -e "s|DATE_ARG|${CURRDATE}|g" \
    -e "s|HSTART_ARG|${HSTART}|g" \
    -e "s|HSTOP_ARG|${HSTOP}|g" \
    -e "s|ICFILE_ARG|${ICFILE}|g" \
    -e "s|LBCDIR_ARG|${LBCDIR}|g" \
    -e "s|LBCGRID_ARG|${LBCGRID}|g" \
    -e "s|LOCALGRID_ARG|${LOCALGRID}|g" \
    -e "s|RADGRID_ARG|${RADGRID}|g" \
    -e "s|EXTPAR_ARG|${EXTPARGRID}|g" \
    "$TEMPLATE" > "$NML_SCRIPT" || fail 31 NAMELIST "Falha ao preparar o script de geração do namelist."
[ -s "$NML_SCRIPT" ] || fail 31 NAMELIST "Script de geração do namelist ficou vazio."
chmod +x "$NML_SCRIPT" || fail 31 NAMELIST "Não foi possível tornar ${NML_SCRIPT} executável."
"./$NML_SCRIPT" || fail 31 NAMELIST "Falha ao criar namelist a partir de ${TEMPLATE}."
NML_FILE="NAMELIST_ICONLAM_${GRID}"
[ -s "$NML_FILE" ] || fail 31 NAMELIST "${NML_FILE} não foi criado ou ficou vazio; consulte ${RUN_LOG}."

info NAMELIST "Conteúdo de icon_master.namelist e ${NML_FILE} (registrado também no log da rodada):"
[ -s icon_master.namelist ] || fail 31 NAMELIST "icon_master.namelist não foi criado ou ficou vazio; consulte ${RUN_LOG}."
cat icon_master.namelist "$NML_FILE" || fail 31 NAMELIST "Não foi possível registrar o conteúdo dos namelists em ${RUN_LOG}."

# Inicia a renomeação em paralelo para processar os arquivos à medida que o ICON os produz.
info RENOMEACAO "Iniciando renomeação de saídas em segundo plano; log: ${RENAME_LOG}."
"${SCRIPTS_DIR}/05.1_renameoutput_iconlam.sh" "$HH" "$GRID" 0 "$FORECAST_TIME" "$CURRDATE" >"$RENAME_LOG" 2>&1 &
RENAME_PID=$!

info EXECUCAO "Iniciando ICON: ${MODEL}."
info EXECUCAO "Período UTC: ${HSTART} até ${HSTOP}."
time "$MPIEXEC" --host "$HOST_LIST" -np "$NUM_TOTAL_PROCS" "$MODEL"
RET=$?

if [ "$RET" -ne 0 ]; then
    log_error "$RET" EXECUCAO "ICON terminou com código ${RET}; PID da renomeação=${RENAME_PID}, log=${RENAME_LOG}."
    exit "$RET"
fi
info EXECUCAO "ICON terminou com sucesso. Aguardando conclusão da renomeação (PID ${RENAME_PID})."
wait "$RENAME_PID"
RENAME_RET=$?
if [ "$RENAME_RET" -ne 0 ]; then
    fail 43 RENOMEACAO "Script de renomeação terminou com código ${RENAME_RET}; consulte ${RENAME_LOG}."
fi

rm -f "$NML_SCRIPT" "$NML_FILE" icon_master.namelist
info FINALIZACAO "Execução e renomeação concluídas com sucesso para ${GRID}, ${CURRDATE} ${HH}Z."

info EXECUCAO "Execução do backup para ${GRID}, ${CURRDATE} ${HH}Z: ${SCRIPTS_DIR}/06_backup_iconlam.sh."
time ${SCRIPTS_DIR}/06_backup_iconlam.sh ${HH} ${GRID} ${CURRDATE} &
return 0
}

#=============================================
# Interface: HH | HH GRID | HH GRID YYYYMMDD.
if [ "$#" -lt 1 ] || [ "$#" -gt 3 ]; then
    fail 11 ARGUMENTOS "Uso: $0 HH [GRID [YYYYMMDD]]. Com apenas HH, as grades são lidas de ${SCRIPTS_DIR}/runlist."
fi

HH="$1"
[[ "$HH" =~ ^(00|12)$ ]] || fail 11 ARGUMENTOS "HH deve ser 00 ou 12; recebido: ${HH}."

if [ "$#" -eq 1 ]; then
    RUNLIST="${SCRIPTS_DIR}/runlist"
    [ -r "$RUNLIST" ] || fail 21 RUNLIST "Arquivo runlist não encontrado ou ilegível: ${RUNLIST}."
    GRID_COUNT=0
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        LINE="${LINE%%#*}"
        for GRID in $LINE; do
            [[ -n "${GRID_DIR[$GRID]+x}" ]] || fail 12 RUNLIST "Grade inválida no runlist: ${GRID}."
            info RUNLIST "Iniciando rodada ${HH} para a grade ${GRID}."
            run_icon "$HH" "$GRID" || fail "$?" RUNLIST "Execução falhou para grade=${GRID}, rodada=${HH}."
            GRID_COUNT=$((GRID_COUNT + 1))
        done
    done < "$RUNLIST"
    [ "$GRID_COUNT" -gt 0 ] || fail 21 RUNLIST "O arquivo ${RUNLIST} não contém grades válidas."
    info FIM "Todas as ${GRID_COUNT} grades do runlist foram executadas para a rodada ${HH}."
    exit 0
fi

GRID="$2"
DATE_ARG="${3:-}"
run_icon "$HH" "$GRID" "$DATE_ARG"
exit $?

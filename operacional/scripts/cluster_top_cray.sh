#!/bin/bash
#
# Verifica o status dos nós do cluster dpns51
#

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

NODES=(cn{01..40})

echo -e "Monitoramento do Cluster dpns51 - $(date '+%d/%m/%Y %H:%M:%S')"

printf "%-10s | %-6s | %-10s | %-85s\n" \
       "NÓ" "CORES" "LOAD (1m)" \
       "PROCESSOS ATIVOS ([USER] NOME:QTD(~MED% | TEMPO)) ou STATUS"

echo "---------------------------------------------------------------------------------------------------------------------------------------"

# ============================================================
# Consulta os nós em paralelo
# ============================================================

for node in "${NODES[@]}"; do
    (
        ssh -o ConnectTimeout=2 -o BatchMode=yes "$node" "
            cores=\$(nproc 2>/dev/null || echo 1)

            read l1 l5 l15 rest < /proc/loadavg

            procs=\$(ps -eo user,comm,pcpu,etimes | awk -v load15=\"\$l15\" '
                NR>1 {
                    usr = \$1
                    cmd = \$2
                    cpu_val = \$3
                    time_val = \$4

                    # Ignora processos do sistema
                    if (cmd ~ /^(irq|kworker|ksoftirqd|NFSv4|ps|sshd|bash|systemd|rcu|migration|watchdog)/)
                        next

                    if (cpu_val > 1.0) {
                        key = usr \"@\" cmd
                        count[key]++
                        cpu[key] += cpu_val

                        if (time_val > max_time[key])
                            max_time[key] = time_val
                    }
                }

                END {
                    out = \"\"

                    for (k in count) {
                        split(k, arr, \"@\")
                        u = arr[1]
                        p = arr[2]

                        avg = cpu[k] / count[k]
                        t = max_time[k]

                        h = int(t / 3600)
                        m = int((t % 3600) / 60)

                        if (h > 0)
                            t_str = h \"h \" m \"m\"
                        else
                            t_str = m \"m\"

                        out = out sprintf(
                            \"[%s] %s:%d(~%.0f%% | %s)  \",
                            u, p, count[k], avg, t_str
                        )
                    }

                    if (out == \"\") {
                        if (load15 > 2.0)
                            print \"Livre (Esvaziou há menos de 15 min)\"
                        else
                            print \"Livre (Há mais de 15 min)\"
                    }
                    else {
                        print out
                    }
                }
            ')

            echo \"\$cores \$l1 \$procs\"
        " > "$TMP/$node" 2>/dev/null || echo "OFFLINE" > "$TMP/$node"
    ) &
done

wait

# ============================================================
# Exibe resultados
# ============================================================

for node in "${NODES[@]}"; do

    read -r cores load procs < "$TMP/$node"

    if [ "$cores" == "OFFLINE" ] || [ -z "$cores" ]; then
        printf "\e[31m%-10s | %-6s | %-10s | %-85s\e[0m\n" \
               "$node" "-" "OFFLINE" "-"
        continue
    fi

    color=$(awk -v l="$load" -v c="$cores" '
        BEGIN {
            if (l >= c)
                print "\033[31m"
            else if (l > c/2)
                print "\033[33m"
            else
                print "\033[32m"
        }
    ')

    reset="\033[0m"

    printf "${color}%-10s | %-6s | %-10s | %-85s${reset}\n" \
           "$node" "$cores" "$load" "$procs"
done

echo "---------------------------------------------------------------------------------------------------------------------------------------"

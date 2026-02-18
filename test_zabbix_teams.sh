#!/bin/bash
################################################################################
# Autor........: Tiago Silva Leite
# Contato......: tsl26@pm.me
# Data criação.: 2025-02-17
# Versão.......: 2.0
# Testado em...: Zabbix 7 LTS
# Sistema......: Zabbix
# Integração...: Microsoft Teams (Incoming Webhook + Adaptive Card v1.5)
#
# Descrição:
#   Testa o script zabbix_teams.sh enviando cards reais para o Teams,
#   cobrindo todos os tipos de evento e severidades do Zabbix Server.
#
# Funcionalidades:
#   - Valida presença e permissão do script principal antes de iniciar
#   - Envia 8 cards: 6 severidades de Problema + Resolvido + Atualização
#   - Modo --dry-run: exibe parâmetros sem enviar ao Teams
#   - Modo --single <sev>: testa apenas uma severidade específica
#   - Modo --verbose: exibe output completo do script principal
#   - Contador de sucesso/falha com resumo final estruturado
#   - Intervalo configurável entre envios para não sobrecarregar o Teams
#
# Uso:
#   chmod +x test_zabbix_teams.sh
#   ./test_zabbix_teams.sh                         # Execução normal interativa
#   ./test_zabbix_teams.sh --dry-run               # Exibe parâmetros sem enviar
#   ./test_zabbix_teams.sh --single High           # Testa apenas severidade High
#   ./test_zabbix_teams.sh --verbose               # Log completo do curl
#   ./test_zabbix_teams.sh --dry-run --verbose     # Combina flags
################################################################################

# ------------------------------------------------------------------------------
# Cores ANSI para output no terminal
# ------------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

# ------------------------------------------------------------------------------
# Parse de flags
# ------------------------------------------------------------------------------
DRY_RUN=false
VERBOSE=false
SINGLE_SEV=""

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=true  ; shift ;;
    --verbose)  VERBOSE=true  ; shift ;;
    --single)   SINGLE_SEV="$2"; shift 2 ;;
    --help|-h)
      echo ""
      echo -e "${BOLD}Uso:${RESET} $0 [opções]"
      echo ""
      echo "  ${BOLD}--dry-run${RESET}            Exibe os parâmetros sem enviar ao Teams"
      echo "  ${BOLD}--verbose${RESET}            Exibe o output completo do script principal"
      echo "  ${BOLD}--single${RESET} <sev>       Testa apenas uma severidade específica"
      echo ""
      echo "  Valores para --single:"
      echo "    'Not classified' | Information | Warning | Average | High | Disaster"
      echo "    resolved | update"
      echo ""
      echo "  Exemplos:"
      echo "    $0 --single High"
      echo "    $0 --single Disaster --verbose"
      echo "    $0 --dry-run"
      echo ""
      exit 0
      ;;
    *) echo -e "${RED}Flag desconhecida: $1${RESET}" >&2 ; exit 1 ;;
  esac
done

# ------------------------------------------------------------------------------
# Contadores
# ------------------------------------------------------------------------------
TOTAL=0
SUCCESS=0
FAILED=0
SKIPPED=0
declare -a FAILED_LIST=()

# ------------------------------------------------------------------------------
# Banner
# ------------------------------------------------------------------------------
clear
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║      ZABBIX → TEAMS  ·  Suite de Testes  ·  v2.0           ║"
echo "║      6 severidades  +  Resolvido  +  Atualização            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

$DRY_RUN   && echo -e "  ${YELLOW}${BOLD}⚠  MODO DRY-RUN — nenhum card será enviado ao Teams${RESET}\n"
$VERBOSE   && echo -e "  ${DIM}🔍 MODO VERBOSE — output completo será exibido${RESET}\n"
[ -n "$SINGLE_SEV" ] && echo -e "  ${CYAN}🎯 MODO SINGLE — testando apenas: ${BOLD}${SINGLE_SEV}${RESET}\n"

# ------------------------------------------------------------------------------
# Entrada interativa
# ------------------------------------------------------------------------------
echo -e "${BOLD}Configuração:${RESET}"
echo ""

if $DRY_RUN; then
  WEBHOOK_URL="https://dry-run.local/webhook"
  echo -e "  ${DIM}Webhook: $WEBHOOK_URL (dry-run)${RESET}"
else
  read -rp "  🔗 Webhook URL do Teams: " WEBHOOK_URL
  [ -z "$WEBHOOK_URL" ] && { echo -e "${RED}❌ Webhook URL obrigatório.${RESET}"; exit 1; }
fi

echo ""
read -rp "  📂 Caminho do script [/usr/lib/zabbix/alertscripts/zabbix_teams.sh]: " SCRIPT_PATH
SCRIPT_PATH="${SCRIPT_PATH:-/usr/lib/zabbix/alertscripts/zabbix_teams.sh}"

if [ ! -f "$SCRIPT_PATH" ]; then
  echo -e "${RED}❌ Script não encontrado: ${BOLD}$SCRIPT_PATH${RESET}"
  exit 1
fi

if [ ! -x "$SCRIPT_PATH" ]; then
  echo -e "${YELLOW}⚠  Sem permissão de execução. Corrigindo...${RESET}"
  chmod +x "$SCRIPT_PATH" || {
    echo -e "${RED}❌ Falha ao corrigir permissão. Execute:${RESET}"
    echo "   chmod +x $SCRIPT_PATH"
    exit 1
  }
  echo -e "${GREEN}✅ Permissão corrigida.${RESET}"
fi

echo ""
read -rp "  🌐 URL base do Zabbix (opcional, Enter para pular): " ZABBIX_URL

echo ""
read -rp "  ⏱  Intervalo entre envios em segundos [2]: " INTERVALO
INTERVALO="${INTERVALO:-2}"
[[ "$INTERVALO" =~ ^[0-9]+$ ]] || INTERVALO=2

echo ""
echo -e "  ${DIM}Script   : $SCRIPT_PATH${RESET}"
echo -e "  ${DIM}Zabbix   : ${ZABBIX_URL:-(não informado)}${RESET}"
echo -e "  ${DIM}Intervalo: ${INTERVALO}s${RESET}"
echo ""
echo -e "${BOLD}Iniciando...${RESET}"

# ------------------------------------------------------------------------------
# Função principal de teste
#   $1  LABEL     — rótulo exibido no terminal
#   $2  SUBJECT   — {ALERT.SUBJECT}
#   $3  MESSAGE   — {ALERT.MESSAGE}
#   $4  SEVERITY  — {TRIGGER.SEVERITY}
#   $5  COLOR     — cor ANSI para terminal (opcional)
#   $6  FILTER    — string para match no --single (opcional, default = SEVERITY)
# ------------------------------------------------------------------------------
run_test() {
  local LABEL="$1"
  local SUBJECT="$2"
  local MESSAGE="$3"
  local SEVERITY="$4"
  local COLOR="${5:-$RESET}"
  local FILTER="${6:-$SEVERITY}"

  # --single: pula testes que não casam
  if [ -n "$SINGLE_SEV" ]; then
    if ! echo "$FILTER $SUBJECT $SEVERITY" | grep -qi "$SINGLE_SEV"; then
      (( SKIPPED++ ))
      return
    fi
  fi

  (( TOTAL++ ))

  echo ""
  echo -e "${COLOR}${BOLD}  ▶  $LABEL${RESET}"
  echo -e "  ${DIM}Assunto   : $SUBJECT${RESET}"
  echo -e "  ${DIM}Severidade: ${SEVERITY:-N/A}${RESET}"
  echo "  ──────────────────────────────────────────────────────────"

  if $DRY_RUN; then
    echo -e "  ${YELLOW}[DRY-RUN] Parâmetros que seriam enviados:${RESET}"
    echo -e "  ${DIM}  \$1  ${WEBHOOK_URL}${RESET}"
    echo -e "  ${DIM}  \$2  ${SUBJECT}${RESET}"
    echo -e "  ${DIM}  \$3  ($(echo "$MESSAGE" | wc -l) linhas de mensagem)${RESET}"
    echo -e "  ${DIM}  \$4  ${ZABBIX_URL:-(vazio)}${RESET}"
    echo -e "  ${DIM}  \$5  ${SEVERITY}${RESET}"
    (( SUCCESS++ ))
    return
  fi

  OUTPUT=$(bash "$SCRIPT_PATH" \
    "$WEBHOOK_URL" \
    "$SUBJECT" \
    "$MESSAGE" \
    "$ZABBIX_URL" \
    "$SEVERITY" 2>&1)
  EXIT_CODE=$?

  if echo "$OUTPUT" | grep -q "✅ Card enviado com sucesso"; then
    echo -e "  ${GREEN}✅ Card enviado com sucesso!${RESET}"
    (( SUCCESS++ ))
  else
    echo -e "  ${RED}❌ Falha no envio  (exit code: $EXIT_CODE)${RESET}"
    echo "$OUTPUT" | grep -E "HTTP Code|Detalhes|Erro|❌" | sed 's/^/     /'
    (( FAILED++ ))
    FAILED_LIST+=("$LABEL")
  fi

  if $VERBOSE; then
    echo ""
    echo -e "  ${DIM}── Output completo ─────────────────────────────────────${RESET}"
    echo "$OUTPUT" | sed 's/^/  │ /'
    echo -e "  ${DIM}────────────────────────────────────────────────────────${RESET}"
  fi

  sleep "$INTERVALO"
}

# ------------------------------------------------------------------------------
# Builders de mensagem — simulam os templates do Zabbix
# ------------------------------------------------------------------------------
build_problem_msg() {
  local SEV="$1" HOST="$2" TRIGGER="$3"
  local IP="192.168.10.$(shuf -i 10-250 -n 1)"
  local VAL="$(shuf -i 76-99 -n 1)"
  printf "🔔 Alarme: %s\n🎯 Severidade: %s\n🖥️ Host: %s (%s)\n📁 Projeto: Infraestrutura\n⏰ Início: %s\n📊 Último valor: %s%%\n📝 Descrição: Threshold excedido por mais de 5 minutos consecutivos" \
    "$TRIGGER" "$SEV" "$HOST" "$IP" "$(date '+%Y-%m-%d %H:%M:%S')" "$VAL"
}

build_resolved_msg() {
  local SEV="$1" TRIGGER="$2"
  local START
  START=$(date -d '15 minutes ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
       || date -v-15M '+%Y-%m-%d %H:%M:%S' 2>/dev/null \
       || date '+%Y-%m-%d %H:%M:%S')
  local VAL="$(shuf -i 10-45 -n 1)"
  printf "🔔 Alarme: %s\n🎯 Severidade: %s\n🖥️ Host: srv-prod-01 (192.168.10.15)\n📁 Projeto: Infraestrutura\n⏰ Início: %s\n✅ Fim: %s\n⏳ Duração: 15m 00s\n📊 Último valor: %s%%\n📝 Descrição: Métrica voltou ao nível normal" \
    "$TRIGGER" "$SEV" "$START" "$(date '+%Y-%m-%d %H:%M:%S')" "$VAL"
}

build_update_msg() {
  local TRIGGER="$1"
  printf "🔔 Alarme: %s\n🎯 Severidade: High\n🖥️ Host: srv-prod-01 (192.168.10.15)\n📁 Projeto: Infraestrutura\n⏰ Evento: %s\n✅ Reconhecido: Sim\n💬 Mensagem: Equipe de infra notificada. Análise em andamento.\n🙋 Usuário Zabbix: admin" \
    "$TRIGGER" "$(date '+%Y-%m-%d %H:%M:%S')"
}

# ==============================================================================
# BLOCO 1 — PROBLEMAS (todas as severidades)
# ==============================================================================
echo ""
echo -e "${BOLD}${BLUE}  ══════════════════════════════════════════════════════════════"
echo -e "  BLOCO 1 — PROBLEMAS  (6 severidades)"
echo -e "  ══════════════════════════════════════════════════════════════${RESET}"

run_test \
  "⬜  Not classified  —  Interface com erros de CRC" \
  "PROBLEMA: Interface com erros de CRC" \
  "$(build_problem_msg 'Not classified' 'sw-core-01' 'Interface com erros de CRC')" \
  "Not classified" "$RESET" "not classified"

run_test \
  "ℹ️  Information  —  Backup concluído com avisos" \
  "PROBLEMA: Backup concluído com avisos" \
  "$(build_problem_msg 'Information' 'srv-backup-01' 'Backup concluído com avisos')" \
  "Information" "$BLUE"

run_test \
  "⚠️  Warning  —  Disco com uso acima de 75%" \
  "PROBLEMA: Disco com uso acima de 75%" \
  "$(build_problem_msg 'Warning' 'srv-files-01' 'Disco com uso acima de 75%')" \
  "Warning" "$YELLOW"

run_test \
  "🟠  Average  —  Memória acima de 85%" \
  "PROBLEMA: Memória acima de 85%" \
  "$(build_problem_msg 'Average' 'srv-app-01' 'Memória acima de 85%')" \
  "Average" "$YELLOW"

run_test \
  "🔴  High  —  CPU acima de 90%" \
  "PROBLEMA: CPU acima de 90%" \
  "$(build_problem_msg 'High' 'srv-prod-01' 'CPU acima de 90%')" \
  "High" "$RED"

run_test \
  "💥  Disaster  —  Host inacessível (ICMP timeout)" \
  "PROBLEMA: Host inacessível" \
  "$(build_problem_msg 'Disaster' 'srv-db-master' 'Host inacessível (ICMP timeout)')" \
  "Disaster" "$RED"

# ==============================================================================
# BLOCO 2 — RESOLVIDO
# ==============================================================================
echo ""
echo -e "${BOLD}${GREEN}  ══════════════════════════════════════════════════════════════"
echo -e "  BLOCO 2 — RESOLVIDO"
echo -e "  ══════════════════════════════════════════════════════════════${RESET}"

run_test \
  "✅  Resolvido  —  CPU voltou ao normal" \
  "RESOLVIDO: CPU acima de 90%" \
  "$(build_resolved_msg 'High' 'CPU acima de 90%')" \
  "High" "$GREEN" "resolved"

# ==============================================================================
# BLOCO 3 — ATUALIZAÇÃO
# ==============================================================================
echo ""
echo -e "${BOLD}${CYAN}  ══════════════════════════════════════════════════════════════"
echo -e "  BLOCO 3 — ATUALIZAÇÃO  (reconhecimento)"
echo -e "  ══════════════════════════════════════════════════════════════${RESET}"

run_test \
  "🔄  Atualização  —  CPU alta reconhecida pelo time" \
  "ATUALIZACAO: CPU acima de 90%" \
  "$(build_update_msg 'CPU acima de 90%')" \
  "High" "$CYAN" "update"

# ==============================================================================
# Resumo final
# ==============================================================================
echo ""
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    Resumo dos Testes                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo -e "${RESET}"

printf "  %-22s %s\n" "📊 Executados:"  "${BOLD}${TOTAL}${RESET}"
printf "  %-22s %s\n" "✅ Sucesso:"     "${GREEN}${BOLD}${SUCCESS}${RESET}"

if [ "$FAILED" -gt 0 ]; then
  printf "  %-22s %s\n" "❌ Falhas:" "${RED}${BOLD}${FAILED}${RESET}"
  echo ""
  echo -e "  ${RED}${BOLD}Testes com falha:${RESET}"
  for t in "${FAILED_LIST[@]}"; do
    echo -e "    ${RED}•  $t${RESET}"
  done
fi

[ "$SKIPPED" -gt 0 ] && \
  printf "  %-22s %s\n" "⏭  Ignorados:" "${DIM}${SKIPPED} (--single ativo)${RESET}"

echo ""
echo -e "  ${DIM}Cobertura: 6 severidades de Problema  +  Resolvido  +  Atualização${RESET}"
echo ""

if ! $DRY_RUN && [ "$SUCCESS" -gt 0 ]; then
  echo -e "  ${GREEN}👀 Verifique o canal do Teams — ${BOLD}${SUCCESS} card(s)${RESET}${GREEN} enviado(s)!${RESET}"
  echo ""
fi

# Código de saída: 0 = todos OK, 1 = houve falha
[ "$FAILED" -eq 0 ]

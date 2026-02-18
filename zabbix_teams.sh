#!/bin/bash
################################################################################
# Projeto......: zbx2teams
# Autor........: Tiago Silva Leite
# Contato......: tsl26@pm.me
# GitHub.......: https://github.com/tsleite/zbx2teams
# Data criação.: 2025-02-17
# Versão.......: 7.0
# Testado em...: Zabbix 7 LTS
# Licença......: MIT
#
# Descrição:
#   Envia alertas do Zabbix para Microsoft Teams via Adaptive Cards v1.5.
#   Cada severidade recebe a cor de fundo idêntica ao Zabbix Server (hex oficial),
#   permitindo identificação visual imediata no canal do Teams.
#
# Mapeamento de cores (hex oficial Zabbix Server):
#   Resolvido       → #449626  Verde
#   Atualização     → #1F98FF  Azul
#   Not classified  → #97AAB3  Cinza
#   Information     → #7499FF  Azul claro
#   Warning         → #E6A800  Amarelo forte
#   Average         → #D45E00  Laranja forte
#   High            → #C0392B  Vermelho forte
#   Disaster        → #7B0C0C  Vinho escuro
#
# Parâmetros (Media Type → Script parameters, ordem obrigatória):
#   $1  {ALERT.SENDTO}      URL do Webhook do Teams
#   $2  {ALERT.SUBJECT}     Assunto do alerta
#   $3  {ALERT.MESSAGE}     Mensagem do Zabbix
#   $4  {$ZABBIX.URL}       URL base do Zabbix (opcional)
#   $5  {TRIGGER.SEVERITY}  Severidade do trigger
#
# Dependências: bash 4+, curl
#
# Teste manual:
#   sudo -u zabbix /usr/lib/zabbix/alertscripts/zabbix_teams.sh \
#     "https://WEBHOOK_URL" "PROBLEMA: CPU alta" \
#     "🔔 Alarme: CPU acima de 90%
# 🎯 Severidade: High
# 🖥️ Host: srv-prod-01 (192.168.1.10)
# ⏰ Início: $(date '+%Y-%m-%d %H:%M:%S')
# 📝 Descrição: CPU acima do limite por 5 minutos" \
#     "https://zabbix.empresa.com" "High"
################################################################################
set -euo pipefail

# ==============================================================================
# 1) PARÂMETROS DE ENTRADA
# ==============================================================================
readonly WEBHOOK_URL="${1:-}"
readonly TITULO="${2:-}"
readonly MSG="${3:-}"
readonly ZABBIX_URL="${4:-}"
readonly SEVERITY="${5:-}"

# ==============================================================================
# 2) VALIDAÇÃO
# ==============================================================================
[ -z "$WEBHOOK_URL" ] && { echo "❌ Parâmetro 1 (WEBHOOK_URL) ausente." >&2; exit 1; }
[ -z "$TITULO" ]      && { echo "❌ Parâmetro 2 (TITULO) ausente."      >&2; exit 1; }
[ -z "$MSG" ]         && { echo "❌ Parâmetro 3 (MSG) ausente."          >&2; exit 1; }

# ==============================================================================
# 3) MENÇÕES (opcional — deixe NAME ou EMAIL vazios para omitir do card)
# ==============================================================================
MENTION1_NAME=""
MENTION1_EMAIL=""
MENTION2_NAME=""
MENTION2_EMAIL=""
MENTION3_NAME=""
MENTION3_EMAIL=""

# ==============================================================================
# 4) TIPO DE EVENTO
# ==============================================================================
if   echo "$TITULO $MSG" | grep -qiE "RESOLVIDO|RESOLVED|RECOVERY"; then EVENT_TYPE="resolved"
elif echo "$TITULO $MSG" | grep -qiE "Update|Atualizacao|Atualização";  then EVENT_TYPE="update"
else EVENT_TYPE="problem"
fi

# ==============================================================================
# 5) VISUAL — cor e ícone por tipo + severidade
#    style semântico + backgroundColor hex = melhor compatibilidade no Teams
# ==============================================================================
case "$EVENT_TYPE" in
  resolved)
    BANNER_BG="#449626"; BANNER_STYLE="good";      ICON="✅"; HEADER="RESOLVIDO"    ;;
  update)
    BANNER_BG="#1F98FF"; BANNER_STYLE="accent";    ICON="🔄"; HEADER="ATUALIZACAO"  ;;
  problem)
    SEV=$(echo "$SEVERITY" | tr '[:upper:]' '[:lower:]' \
          | sed 'y/áàãâéêíóôõúüçñ/aaaaeeiooouucn/')
    case "$SEV" in
      "not classified"|"nao classificado")
                      BANNER_BG="#97AAB3"; BANNER_STYLE="emphasis";  ICON="⬜" ;;
      "information"|"informacao")
                      BANNER_BG="#7499FF"; BANNER_STYLE="accent";    ICON="ℹ️"  ;;
      "warning"|"aviso")
                      BANNER_BG="#E6A800"; BANNER_STYLE="warning";   ICON="⚠️"  ;;
      "average"|"media")
                      BANNER_BG="#D45E00"; BANNER_STYLE="warning";   ICON="🟠" ;;
      "high"|"alto")
                      BANNER_BG="#C0392B"; BANNER_STYLE="attention"; ICON="🔴" ;;
      "disaster"|"desastre")
                      BANNER_BG="#7B0C0C"; BANNER_STYLE="attention"; ICON="💥" ;;
      *)              BANNER_BG="#7B0C0C"; BANNER_STYLE="attention"; ICON="🚨" ;;
    esac
    HEADER="PROBLEMA"
    ;;
esac

# ==============================================================================
# 6) PARSE DA MENSAGEM → FactSet JSON
#    Regras:
#      - Linhas vazias                    → ignoradas
#      - Linhas sem alfanumérico (len≥2)  → separadores, ignoradas
#      - "chave: valor"                   → FactSet item
#      - linha sem ":"                    → item com título vazio
# ==============================================================================
_escape_json() { echo "$1" | sed 's/\\/\\\\/g;s/"/\\"/g'; }

FACTS_JSON=""
while IFS= read -r line; do
  line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [ -z "$line" ] && continue
  case "$line" in
    *[[:alnum:]]*)  : ;;
    *) [ ${#line} -ge 2 ] && continue ;;
  esac
  if echo "$line" | grep -q ':'; then
    T=$(_escape_json "$(echo "$line" | sed 's/:.*//' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')")
    V=$(_escape_json "$(echo "$line" | sed 's/[^:]*://' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')")
    [ -z "$T" ] && [ -z "$V" ] && continue
    [ -n "$FACTS_JSON" ] && FACTS_JSON="${FACTS_JSON},"
    FACTS_JSON="${FACTS_JSON}{\"title\":\"${T}:\",\"value\":\"${V}\"}"
  else
    V=$(_escape_json "$line")
    [ -n "$FACTS_JSON" ] && FACTS_JSON="${FACTS_JSON},"
    FACTS_JSON="${FACTS_JSON}{\"title\":\"\",\"value\":\"${V}\"}"
  fi
done << MSGEOF
$MSG
MSGEOF

if [ -n "$FACTS_JSON" ]; then
  BODY_BLOCK="{\"type\":\"FactSet\",\"separator\":true,\"facts\":[${FACTS_JSON}]}"
else
  SAFE=$(_escape_json "$MSG" | awk '{printf "%s\\n",$0}' | sed 's/\\n$//')
  BODY_BLOCK="{\"type\":\"TextBlock\",\"text\":\"${SAFE}\",\"wrap\":true}"
fi

# ==============================================================================
# 7) BOTÃO (opcional — só se ZABBIX_URL informado)
# ==============================================================================
if [ -n "$ZABBIX_URL" ]; then
  ACTION_BLOCK=",{\"type\":\"ActionSet\",\"actions\":[{\"type\":\"Action.OpenUrl\",\"title\":\"🔗 Abrir no Zabbix\",\"url\":\"${ZABBIX_URL}\"}]}"
else
  ACTION_BLOCK=""
fi

# ==============================================================================
# 8) MENÇÕES (só cria bloco se ao menos uma pessoa estiver configurada)
# ==============================================================================
MENTION_NAMES=""
MENTION_ENTITIES=""

_add_mention() {
  local N="$1" E="$2"
  [ -z "$N" ] || [ -z "$E" ] && return 0
  [ -n "$MENTION_NAMES" ]    && MENTION_NAMES="${MENTION_NAMES}  •  "
  [ -n "$MENTION_ENTITIES" ] && MENTION_ENTITIES="${MENTION_ENTITIES},"
  MENTION_NAMES="${MENTION_NAMES}<at>${N}</at>"
  MENTION_ENTITIES="${MENTION_ENTITIES}{\"type\":\"mention\",\"text\":\"<at>${N}</at>\",\"mentioned\":{\"id\":\"${E}\",\"name\":\"${N}\"}}"
}

_add_mention "$MENTION1_NAME" "$MENTION1_EMAIL"
_add_mention "$MENTION2_NAME" "$MENTION2_EMAIL"
_add_mention "$MENTION3_NAME" "$MENTION3_EMAIL"

if [ -n "$MENTION_NAMES" ]; then
  TS=$(date '+%d/%m/%Y %H:%M:%S')
  MENTION_BLOCK=",{\"type\":\"Container\",\"style\":\"emphasis\",\"bleed\":true,\"spacing\":\"Medium\",\"items\":[{\"type\":\"ColumnSet\",\"columns\":[{\"type\":\"Column\",\"width\":\"stretch\",\"items\":[{\"type\":\"TextBlock\",\"text\":\"👨‍💻 ${MENTION_NAMES}\",\"weight\":\"Bolder\",\"color\":\"Attention\",\"wrap\":true}]},{\"type\":\"Column\",\"width\":\"auto\",\"items\":[{\"type\":\"TextBlock\",\"text\":\"🕐 ${TS}\",\"size\":\"Small\",\"isSubtle\":true,\"horizontalAlignment\":\"Right\"}]}]}]}"
  MSTEAMS_BLOCK="\"msteams\":{\"entities\":[${MENTION_ENTITIES}]},"
else
  MENTION_BLOCK=""
  MSTEAMS_BLOCK=""
fi

# ==============================================================================
# 9) PAYLOAD — Adaptive Card v1.5
# ==============================================================================
PAYLOAD="{\"type\":\"message\",\"attachments\":[{\"contentType\":\"application/vnd.microsoft.card.adaptive\",\"content\":{\"type\":\"AdaptiveCard\",\"version\":\"1.5\",\"\$schema\":\"http://adaptivecards.io/schemas/adaptive-card.json\",${MSTEAMS_BLOCK}\"body\":[{\"type\":\"Container\",\"style\":\"${BANNER_STYLE}\",\"backgroundColor\":\"${BANNER_BG}\",\"bleed\":true,\"items\":[{\"type\":\"TextBlock\",\"text\":\"${ICON}  ${HEADER}\",\"weight\":\"Bolder\",\"size\":\"Large\",\"horizontalAlignment\":\"Center\",\"wrap\":false}]},{\"type\":\"Container\",\"spacing\":\"Medium\",\"items\":[${BODY_BLOCK}]}${ACTION_BLOCK}${MENTION_BLOCK},{\"type\":\"TextBlock\",\"text\":\"Observabilidade\",\"size\":\"Small\",\"weight\":\"Lighter\",\"isSubtle\":true,\"horizontalAlignment\":\"Center\",\"spacing\":\"Small\"}]}}]}"

# ==============================================================================
# 10) ENVIO
# ==============================================================================
TS=$(date '+%d/%m/%Y %H:%M:%S')

RESPONSE=$(curl -sf \
  --max-time 20 \
  --connect-timeout 10 \
  --retry 2 \
  --retry-delay 3 \
  -w "\nHTTP_CODE:%{http_code}" \
  -X POST "$WEBHOOK_URL" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>&1) || true

HTTP_CODE=$(echo "$RESPONSE" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
BODY=$(echo "$RESPONSE" | grep -v 'HTTP_CODE:')

# ==============================================================================
# 11) LOG
# ==============================================================================
echo "========================================"
echo "📅 $TS"
echo "📌 Tipo       : $EVENT_TYPE"
echo "🎯 Severidade : ${SEVERITY:-N/A}"
echo "📋 Assunto    : $TITULO"
echo "----------------------------------------"
case "$HTTP_CODE" in
  200|202)
    echo "✅ Card enviado com sucesso!"
    [ -n "$BODY" ] && echo "📨 Resposta   : $BODY"
    exit 0 ;;
  "")
    echo "❌ Sem resposta — verifique conectividade ou webhook URL."
    exit 1 ;;
  *)
    echo "❌ Falha no envio."
    echo "🔢 HTTP Code  : $HTTP_CODE"
    [ -n "$BODY" ] && echo "🔍 Detalhes   : $BODY"
    exit 1 ;;
esac
echo "========================================"

#!/bin/bash
# =============================================================================
# Backup do banco de dados PostgreSQL - VR
# =============================================================================

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export PGPASSFILE="/root/.pgpass"

# -----------------------------------------------------------------------------
# Configurações de conexão
# -----------------------------------------------------------------------------
PG_USER="postgres"
PG_PORT="38561"
PG_BIN="/usr/pgsql-14/bin"
NOME="vr"

# -----------------------------------------------------------------------------
# Configurações de backup
# -----------------------------------------------------------------------------
HOJE="loja_$(date +%d%m%y%H%M)"
EXTENSAO=".sfwn"
EXTENSAO2=".tar.gz"
ARQUIVO="${NOME}_${HOJE}${EXTENSAO}"
ARQUIVO2="${NOME}_${HOJE}"
PATH_BK="/vr/backup"
LOG_DIR="/vr/backup/log"
LOG="$LOG_DIR/$ARQUIVO2.log"
LOCKFILE="/tmp/bk_vr.lock"
DATA=$(date +%Y-%m-%d_%H:%M:%S)
RETENCAO_DIAS=7

# -----------------------------------------------------------------------------
# Funções auxiliares
# -----------------------------------------------------------------------------
log() {
    echo "$(date +%Y-%m-%d_%H:%M:%S) - $1" >> "$LOG"
}

log_erro() {
    echo "$(date +%Y-%m-%d_%H:%M:%S) - ERRO: $1" | tee -a "$LOG" >&2
}

# -----------------------------------------------------------------------------
# Verificar dependências
# -----------------------------------------------------------------------------
for CMD in tar "$PG_BIN/pg_dump" "$PG_BIN/psql" find mkdir; do
    if ! command -v "$CMD" &>/dev/null && [ ! -x "$CMD" ]; then
        echo "ERRO FATAL: Dependência não encontrada: $CMD"
        exit 1
    fi
done

# -----------------------------------------------------------------------------
# [FIX] Verificar .pgpass antes de tentar conectar
# -----------------------------------------------------------------------------
if [ ! -f "$PGPASSFILE" ]; then
    echo "ERRO FATAL: Arquivo .pgpass não encontrado em $PGPASSFILE"
    exit 1
fi
PGPASS_PERM=$(stat -c "%a" "$PGPASSFILE")
if [ "$PGPASS_PERM" != "600" ]; then
    echo "ERRO FATAL: $PGPASSFILE deve ter permissão 600 (atual: $PGPASS_PERM)"
    exit 1
fi

# -----------------------------------------------------------------------------
# Lockfile — evitar execução simultânea
# -----------------------------------------------------------------------------
if [ -f "$LOCKFILE" ]; then
    PID=$(cat "$LOCKFILE")
    if kill -0 "$PID" 2>/dev/null; then
        echo "ERRO: Backup já está em execução (PID $PID). Abortando."
        exit 1
    else
        rm -f "$LOCKFILE"
    fi
fi
echo $$ > "$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# -----------------------------------------------------------------------------
# Criar diretórios necessários
# -----------------------------------------------------------------------------
mkdir -p "$PATH_BK" "$LOG_DIR"

log "=========================================="
log "Iniciando backup do banco: $NOME"
log "Arquivo de destino: $ARQUIVO"

# -----------------------------------------------------------------------------
# 1. Dump do banco
# -----------------------------------------------------------------------------
log "Executando pg_dump..."
if ! "$PG_BIN/pg_dump" -U "$PG_USER" -p "$PG_PORT" -v "$NOME" -Fc \
    > "$PATH_BK/$ARQUIVO" 2>> "$LOG"; then
    log_erro "Falha ao executar pg_dump."
    rm -f "$PATH_BK/$ARQUIVO"
    exit 1
fi

if [ ! -s "$PATH_BK/$ARQUIVO" ]; then
    log_erro "Arquivo de dump está vazio! Abortando."
    rm -f "$PATH_BK/$ARQUIVO"
    exit 1
fi

TAMANHO_DUMP=$(du -sh "$PATH_BK/$ARQUIVO" | cut -f1)
log "pg_dump concluído com sucesso. Tamanho: $TAMANHO_DUMP"

# -----------------------------------------------------------------------------
# 2. Compactação
#
# [FIX] Usar -C para evitar caminho absoluto dentro do .tar.gz
# -----------------------------------------------------------------------------
log "Compactando backup..."
if ! tar cvfz "$PATH_BK/$ARQUIVO$EXTENSAO2" -C "$PATH_BK" "$ARQUIVO" >> "$LOG" 2>&1; then
    log_erro "Falha na compactação! Arquivo .sfwn mantido em $PATH_BK/$ARQUIVO"
    exit 1
fi

if [ ! -s "$PATH_BK/$ARQUIVO$EXTENSAO2" ]; then
    log_erro "Arquivo .tar.gz gerado está vazio! Arquivo .sfwn mantido."
    exit 1
fi

TAMANHO_GZ=$(du -sh "$PATH_BK/$ARQUIVO$EXTENSAO2" | cut -f1)
log "Compactação concluída. Tamanho final: $TAMANHO_GZ"

rm -f "$PATH_BK/$ARQUIVO"
log "Arquivo intermediário .sfwn removido."

# -----------------------------------------------------------------------------
# 3. Remover backups antigos
#
# [FIX] -maxdepth 1 para não entrar em subdiretórios (ex: log/)
# [FIX] -name "*.tar.gz" para apagar apenas arquivos de backup
# -----------------------------------------------------------------------------
log "Removendo backups com mais de $RETENCAO_DIAS dias..."
find "$PATH_BK" -maxdepth 1 -type f -name "*.tar.gz" -mtime +"$RETENCAO_DIAS" | while read -r ANTIGO; do
    rm -f "$ANTIGO"
    log "  Removido: $ANTIGO"
done

# -----------------------------------------------------------------------------
# 4. Registrar no banco
#
# [FIX] Removido o DELETE FROM backup para preservar histórico de auditoria
# -----------------------------------------------------------------------------
log "Registrando backup na tabela 'backup'..."
"$PG_BIN/psql" -U "$PG_USER" -p "$PG_PORT" "$NOME" \
    -c "INSERT INTO backup (data, enviado) VALUES (now(), false)" >> "$LOG" 2>&1
log "Registro no banco concluído."

# -----------------------------------------------------------------------------
# 5. Remover logs antigos
#
# [FIX] -maxdepth 1 para não entrar em subdiretórios
# -----------------------------------------------------------------------------
log "Removendo logs com mais de $RETENCAO_DIAS dias..."
find "$LOG_DIR" -maxdepth 1 -type f -name "*.log" -mtime +"$RETENCAO_DIAS" -delete
log "Limpeza de logs concluída."

log "Backup finalizado com sucesso: ${NOME}_${HOJE}${EXTENSAO}${EXTENSAO2}"
log "=========================================="

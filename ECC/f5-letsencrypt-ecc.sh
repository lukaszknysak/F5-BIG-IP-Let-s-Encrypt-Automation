#!/bin/bash

################################################################################
#
#  F5 BIG-IP Let's Encrypt Automation - ECC EDITION (v5)
#  
#  Cel: Automatyzacja certyfikatów SSL (Elliptic Curve - P-256)
#  Algorytm: ECC (prime256v1) - Wysoka wydajność dla ruchu WWW
#  UWAGA: Ten typ certyfikatu NIE działa z podpisywaniem RDP w APM!
#  
#  Autor: Gemini (Technical Partner)
#
################################################################################

set -u

# --- CONFIGURATION START ---

# Ścieżki systemowe (Separacja od wersji RSA)
readonly INSTALL_DIR="/shared/letsencrypt_ecc"
readonly CONFIG_FILE="${INSTALL_DIR}/config"
readonly CERTS_DIR="${INSTALL_DIR}/certs"
readonly ACCOUNTS_DIR="${INSTALL_DIR}/accounts"
readonly LOCK_FILE="${INSTALL_DIR}/lock"
readonly LOG_FILE="/var/log/letsencrypt_ecc.log"

# Twoje domeny
readonly DOMAINS=(
    "demo.example.pl"
    "lab.example.pl"
    "mycloud.example.pl"
    "www.example.pl"
)

# Ustawienia Let's Encrypt
readonly LE_EMAIL="admin@netoro.pl"
readonly CA_PROD="https://acme-v02.api.letsencrypt.org/directory"
readonly CURRENT_CA="${CA_PROD}" 
readonly RENEW_DAYS="30"

# Ustawienia klucza - ECC (Elliptic Curve)
readonly KEY_ALGO="prime256v1"
readonly KEY_SIZE="256"

# Ustawienia bezpieczeństwa SSL (Options List)
readonly SSL_OPTS="dont-insert-empty-fragments no-dtls no-dtlsv1 no-dtlsv1.2 no-session-resumption-on-renegotiation no-ssl no-sslv3 no-tlsv1 no-tlsv1.1 single-dh-use tls-rollback-bug"

# Obiekty F5 (Współdzielone z wersją RSA)
readonly CHALLENGE_VS_NAME="http-vs"
readonly DATA_GROUP_NAME="dg_acme_challenges"
readonly IRULE_NAME="irule_acme_handler"

# --- CONFIGURATION END ---

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "BŁĄD: Skrypt musi być uruchomiony jako root."
        exit 1
    fi
}

cleanup_environment() {
    if [[ -d "$CONFIG_FILE" ]]; then
        rm -rf "$CONFIG_FILE"
    fi
}

setup_directories() {
    log "INFO: Weryfikacja struktury katalogów (ECC)..."
    mkdir -p "$INSTALL_DIR" "$CERTS_DIR" "$ACCOUNTS_DIR"
    
    if [[ ! -f "${INSTALL_DIR}/dehydrated" ]]; then
        log "INFO: Pobieranie klienta dehydrated..."
        curl -s -o "${INSTALL_DIR}/dehydrated" \
            "https://raw.githubusercontent.com/dehydrated-io/dehydrated/master/dehydrated"
        chmod +x "${INSTALL_DIR}/dehydrated"
    fi

    if [[ ! -f "${INSTALL_DIR}/isrgrootx1.pem" ]]; then
        log "INFO: Pobieranie łańcucha zaufania (Chain)..."
        curl -s -o "${INSTALL_DIR}/isrgrootx1.pem" "https://letsencrypt.org/certs/isrgrootx1.pem"
    fi
}

configure_dehydrated() {
    log "INFO: Generowanie konfiguracji dehydrated (ECC Mode)..."
    
    printf "%s\n" "${DOMAINS[@]}" > "${INSTALL_DIR}/domains.txt"

    # KLUCZOWE: KEY_ALGO="prime256v1"
    cat > "$CONFIG_FILE" <<EOF
CA="${CURRENT_CA}"
CHALLENGETYPE="http-01"
HOOK="${INSTALL_DIR}/hook.sh"
CONTACT_EMAIL="${LE_EMAIL}"
KEY_ALGO="${KEY_ALGO}"
KEYSIZE="${KEY_SIZE}"
RENEW_DAYS="${RENEW_DAYS}"
CERTDIR="${CERTS_DIR}"
ACCOUNTDIR="${ACCOUNTS_DIR}"
LOCKFILE="${LOCK_FILE}"
EOF
}

create_hook_script() {
    log "INFO: Generowanie skryptu hook.sh..."
    
    cat > "${INSTALL_DIR}/hook.sh" <<HOOKEOF
#!/bin/bash

DATA_GROUP="dg_acme_challenges"
LOG_FILE="/var/log/letsencrypt_ecc.log"
SSL_OPTS="${SSL_OPTS}"

log_hook() {
    echo "[HOOK] [\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOG_FILE"
}

deploy_challenge() {
    local DOMAIN="\${1}"
    local TOKEN="\${2}"
    local VALIDATION="\${3}"
    log_hook "Challenge start: \$DOMAIN"
    tmsh modify ltm data-group internal "\$DATA_GROUP" records add { "\$TOKEN" { data "\$VALIDATION" } } 2>>"\$LOG_FILE"
}

clean_challenge() {
    local DOMAIN="\${1}"
    local TOKEN="\${2}"
    log_hook "Challenge cleanup: \$DOMAIN"
    tmsh modify ltm data-group internal "\$DATA_GROUP" records delete { "\$TOKEN" } 2>>"\$LOG_FILE" || true
}

deploy_cert() {
    local DOMAIN="\${1}"
    local KEYFILE="\${2}"
    local CERTFILE="\${3}"
    local FULLCHAINFILE="\${4}"
    
    log_hook "Instalacja certyfikatu ECC + TLS 1.3 dla: \$DOMAIN"
    
    local NOW=\$(date +%Y%m%d_%H%M%S)
    local OBJ_NAME="\${DOMAIN//./_}"
    # Prefiks ECC w nazwach obiektów, aby uniknąć kolizji z RSA
    local CERT_OBJ="ecc_\${OBJ_NAME}_\${NOW}"
    local KEY_OBJ="ecc_\${OBJ_NAME}_\${NOW}"
    local PROFILE_NAME="cssl_ecc_\${OBJ_NAME}"

    tmsh install sys crypto key "\${KEY_OBJ}" from-local-file "\${KEYFILE}"
    tmsh install sys crypto cert "\${CERT_OBJ}" from-local-file "\${FULLCHAINFILE}"

    if tmsh list ltm profile client-ssl "\$PROFILE_NAME" > /dev/null 2>&1; then
        tmsh modify ltm profile client-ssl "\$PROFILE_NAME" cert-key-chain replace-all-with { default { key "\$KEY_OBJ" cert "\$CERT_OBJ" } } ciphers none cipher-group f5-default options { \$SSL_OPTS }
    else
        tmsh create ltm profile client-ssl "\$PROFILE_NAME" defaults-from clientssl cert-key-chain add { default { key "\$KEY_OBJ" cert "\$CERT_OBJ" } } ciphers none cipher-group f5-default options { \$SSL_OPTS }
    fi
    
    tmsh save sys config partitions all > /dev/null
}

HANDLER="\${1:-}" 
shift
case "\$HANDLER" in
    deploy_challenge) deploy_challenge "\$@" ;;
    clean_challenge)  clean_challenge "\$@" ;;
    deploy_cert)      deploy_cert "\$@" ;;
    unchanged_cert)   log_hook "Certyfikat ECC dla \$1 jest wciąż ważny." ;;
    *) ;;
esac
HOOKEOF
    chmod +x "${INSTALL_DIR}/hook.sh"
}

configure_f5_objects() {
    log "INFO: Konfiguracja obiektów LTM..."

    # Współdzielona Data Group z wersją RSA
    if ! tmsh list ltm data-group internal "$DATA_GROUP_NAME" > /dev/null 2>&1; then
        tmsh create ltm data-group internal "$DATA_GROUP_NAME" type string
    fi

    local MERGE_FILE="/var/tmp/le_irule_deploy.conf"
    
    cat > "$MERGE_FILE" <<EOF
ltm rule $IRULE_NAME {
    when HTTP_REQUEST {
        if { [HTTP::path] starts_with "/.well-known/acme-challenge/" } {
            set token [lindex [split [HTTP::path] "/"] end]
            set response [class match -value -- \$token equals $DATA_GROUP_NAME]
            if { \$response ne "" } {
                HTTP::respond 200 content \$response "Content-Type" "text/plain"
            } else {
                HTTP::respond 404 content "ACME Token not found"
            }
            return
        }
    }
}
EOF
    
    tmsh load sys config merge file "$MERGE_FILE"
    rm -f "$MERGE_FILE"

    if tmsh list ltm virtual "$CHALLENGE_VS_NAME" > /dev/null 2>&1; then
        tmsh modify ltm virtual "$CHALLENGE_VS_NAME" rules { "$IRULE_NAME" }
    else
        echo "BŁĄD: VS '$CHALLENGE_VS_NAME' nie istnieje!"
        exit 1
    fi
}

register_account() {
    log "INFO: Rejestracja konta ACME (ECC)..."
    "${INSTALL_DIR}/dehydrated" --register --accept-terms --config "$CONFIG_FILE" >> "$LOG_FILE" 2>&1
}

run_cron_setup() {
    log "INFO: Konfiguracja iCall (Auto-Renewal ECC)..."
    local WRAPPER="${INSTALL_DIR}/renew_wrapper.sh"
    cat > "$WRAPPER" <<EOF
#!/bin/bash
${INSTALL_DIR}/dehydrated --cron --config $CONFIG_FILE >> ${LOG_FILE} 2>&1
EOF
    chmod +x "$WRAPPER"

    # Unikalne nazwy dla iCall ECC, aby nie nadpisać RSA
    tmsh delete sys icall handler periodic letse_renew_handler_ecc 2>/dev/null || true
    tmsh delete sys icall script letse_renew_script_ecc 2>/dev/null || true

    tmsh create sys icall script letse_renew_script_ecc definition { exec $WRAPPER }
    tmsh create sys icall handler periodic letse_renew_handler_ecc script letse_renew_script_ecc interval 604800 first-occurrence 2026-02-01:03:30:00
}

update_profiles_only() {
    log "INFO: Aktualizacja profili ECC..."
    
    for DOMAIN in "${DOMAINS[@]}"; do
        local OBJ_NAME="${DOMAIN//./_}"
        local PROFILE_NAME="cssl_ecc_${OBJ_NAME}"
        
        if tmsh list ltm profile client-ssl "$PROFILE_NAME" > /dev/null 2>&1; then
            log "INFO: Aktualizacja profilu: $PROFILE_NAME"
            tmsh modify ltm profile client-ssl "$PROFILE_NAME" ciphers none cipher-group f5-default options { $SSL_OPTS }
        else
            log "WARN: Profil $PROFILE_NAME nie istnieje, pomijam."
        fi
    done
    
    tmsh save sys config partitions all
}

# --- MAIN EXECUTION ---

command="${1:-help}"

case "$command" in
    install)
        check_root
        cleanup_environment
        setup_directories
        configure_dehydrated
        create_hook_script
        configure_f5_objects
        register_account
        run_cron_setup
        log "INFO: Instalacja ECC zakończona."
        ;;
    issue)
        log "INFO: Generowanie certyfikatów (ECC)..."
        "${INSTALL_DIR}/dehydrated" --cron --config "$CONFIG_FILE"
        log "INFO: Proces zakończony."
        ;;
    update-profiles)
        check_root
        update_profiles_only
        ;;
    reset-certs)
        log "WARN: Usuwanie certyfikatów ECC..."
        rm -rf "${CERTS_DIR:?}/"*
        ;;
    show-irule)
        tmsh list ltm rule "$IRULE_NAME"
        ;;
    help|*)
        echo "F5 Let's Encrypt - ECC Edition (v5)"
        echo "Usage: $0 {install|issue|update-profiles|reset-certs|show-irule}"
        echo ""
        echo "  install          - Instaluje środowisko ECC"
        echo "  issue            - Pobiera certyfikaty ECC (prime256v1)"
        exit 1
        ;;
esac

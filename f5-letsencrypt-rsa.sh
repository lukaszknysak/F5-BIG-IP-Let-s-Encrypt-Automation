#!/bin/bash

################################################################################
#
#  F5 BIG-IP Let's Encrypt Automation - RSA EDITION (v5)
#  
#  Cel: Automatyzacja certyfikatów SSL + Kompatybilność z APM RDP Signing
#  Algorytm: RSA 4096 (Wymagany do podpisywania plików .rdp przez F5 APM)
#  Bezpieczeństwo: Wymuszenie TLS 1.3 (f5-default) i blokada starych protokołów
#  
#  Autor: Gemini (Technical Partner)
#
################################################################################

set -u

# --- CONFIGURATION START ---

# Ścieżki systemowe
readonly INSTALL_DIR="/shared/letsencrypt"
readonly CONFIG_FILE="${INSTALL_DIR}/config"
readonly CERTS_DIR="${INSTALL_DIR}/certs"
readonly ACCOUNTS_DIR="${INSTALL_DIR}/accounts"
readonly LOCK_FILE="${INSTALL_DIR}/lock"
readonly LOG_FILE="/var/log/letsencrypt.log"

# Twoje domeny - Edytuj tę listę
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

# Ustawienia klucza - WYMUSZENIE RSA DLA APM RDP
# Dehydrated domyślnie używa ECC, co psuje podpisywanie plików .rdp
readonly KEY_ALGO="rsa"
readonly KEY_SIZE="4096"

# Ustawienia bezpieczeństwa SSL (Options List)
# Blokujemy stare protokoły, zostawiamy TLS 1.2 i 1.3
readonly SSL_OPTS="dont-insert-empty-fragments no-dtls no-dtlsv1 no-dtlsv1.2 no-session-resumption-on-renegotiation no-ssl no-sslv3 no-tlsv1 no-tlsv1.1 single-dh-use tls-rollback-bug"

# Obiekty F5 (LTM)
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
    # Naprawa błędów strukturalnych z poprzednich wersji (gdy config był katalogiem)
    if [[ -d "$CONFIG_FILE" ]]; then
        log "WARN: Wykryto błędny katalog konfiguracyjny. Usuwanie..."
        rm -rf "$CONFIG_FILE"
    fi
}

setup_directories() {
    log "INFO: Weryfikacja struktury katalogów..."
    mkdir -p "$INSTALL_DIR" "$CERTS_DIR" "$ACCOUNTS_DIR"
    
    # Pobieranie klienta dehydrated (ACME client) jeśli nie istnieje
    if [[ ! -f "${INSTALL_DIR}/dehydrated" ]]; then
        log "INFO: Pobieranie klienta dehydrated..."
        curl -s -o "${INSTALL_DIR}/dehydrated" \
            "https://raw.githubusercontent.com/dehydrated-io/dehydrated/master/dehydrated"
        chmod +x "${INSTALL_DIR}/dehydrated"
    fi

    # Pobieranie Root CA (ISRG Root X1)
    if [[ ! -f "${INSTALL_DIR}/isrgrootx1.pem" ]]; then
        log "INFO: Pobieranie łańcucha zaufania (Chain)..."
        curl -s -o "${INSTALL_DIR}/isrgrootx1.pem" "https://letsencrypt.org/certs/isrgrootx1.pem"
    fi
}

configure_dehydrated() {
    log "INFO: Generowanie konfiguracji dehydrated (RSA Mode)..."
    
    # Generowanie listy domen do pliku tekstowego
    printf "%s\n" "${DOMAINS[@]}" > "${INSTALL_DIR}/domains.txt"

    # Tworzenie pliku config
    # KLUCZOWE: KEY_ALGO="rsa" wymusza generowanie kluczy kompatybilnych z RDP
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
    log "INFO: Generowanie skryptu hook.sh (z obsługą TLS 1.3)..."
    
    # Wstrzykujemy zmienną SSL_OPTS do wnętrza hooka
    cat > "${INSTALL_DIR}/hook.sh" <<HOOKEOF
#!/bin/bash

DATA_GROUP="dg_acme_challenges"
LOG_FILE="/var/log/letsencrypt.log"
SSL_OPTS="${SSL_OPTS}"

log_hook() {
    echo "[HOOK] [\$(date '+%Y-%m-%d %H:%M:%S')] \$1" >> "\$LOG_FILE"
}

deploy_challenge() {
    local DOMAIN="\${1}"
    local TOKEN="\${2}"
    local VALIDATION="\${3}"
    log_hook "Challenge start: \$DOMAIN"
    # Dodanie tokenu do Data Group (wymagane dla iRule)
    tmsh modify ltm data-group internal "\$DATA_GROUP" records add { "\$TOKEN" { data "\$VALIDATION" } } 2>>"\$LOG_FILE"
}

clean_challenge() {
    local DOMAIN="\${1}"
    local TOKEN="\${2}"
    log_hook "Challenge cleanup: \$DOMAIN"
    # Usunięcie tokenu po weryfikacji
    tmsh modify ltm data-group internal "\$DATA_GROUP" records delete { "\$TOKEN" } 2>>"\$LOG_FILE" || true
}

deploy_cert() {
    local DOMAIN="\${1}"
    local KEYFILE="\${2}"
    local CERTFILE="\${3}"
    local FULLCHAINFILE="\${4}"
    
    log_hook "Instalacja certyfikatu RSA oraz konfiguracja TLS 1.3 dla: \$DOMAIN"
    
    local NOW=\$(date +%Y%m%d_%H%M%S)
    local OBJ_NAME="\${DOMAIN//./_}"
    local CERT_OBJ="\${OBJ_NAME}_\${NOW}"
    local KEY_OBJ="\${OBJ_NAME}_\${NOW}"
    local PROFILE_NAME="cssl_\${OBJ_NAME}"

    # 1. Import klucza i certyfikatu do F5 System
    tmsh install sys crypto key "\${KEY_OBJ}" from-local-file "\${KEYFILE}"
    tmsh install sys crypto cert "\${CERT_OBJ}" from-local-file "\${FULLCHAINFILE}"

    # 2. Aktualizacja lub utworzenie profilu Client-SSL
    # Używamy ciphers none + cipher-group f5-default (Dla TLS 1.3)
    # Używamy options { ... } aby zablokować stare protokoły
    
    if tmsh list ltm profile client-ssl "\$PROFILE_NAME" > /dev/null 2>&1; then
        # Modyfikacja istniejącego profilu (jedna linia)
        tmsh modify ltm profile client-ssl "\$PROFILE_NAME" cert-key-chain replace-all-with { default { key "\$KEY_OBJ" cert "\$CERT_OBJ" } } ciphers none cipher-group f5-default options { \$SSL_OPTS }
    else
        # Tworzenie nowego profilu (jedna linia)
        tmsh create ltm profile client-ssl "\$PROFILE_NAME" defaults-from clientssl cert-key-chain add { default { key "\$KEY_OBJ" cert "\$CERT_OBJ" } } ciphers none cipher-group f5-default options { \$SSL_OPTS }
    fi
    
    # Zapis konfiguracji
    tmsh save sys config partitions all > /dev/null
}

HANDLER="\${1:-}" 
shift
case "\$HANDLER" in
    deploy_challenge) deploy_challenge "\$@" ;;
    clean_challenge)  clean_challenge "\$@" ;;
    deploy_cert)      deploy_cert "\$@" ;;
    unchanged_cert)   log_hook "Certyfikat dla \$1 jest wciąż ważny." ;;
    *) ;;
esac
HOOKEOF
    chmod +x "${INSTALL_DIR}/hook.sh"
}

configure_f5_objects() {
    log "INFO: Konfiguracja obiektów LTM..."

    # 1. Data Group
    if ! tmsh list ltm data-group internal "$DATA_GROUP_NAME" > /dev/null 2>&1; then
        log "INFO: Tworzenie Data Group..."
        tmsh create ltm data-group internal "$DATA_GROUP_NAME" type string
    fi

    # 2. iRule (Metoda bezpieczna - MERGE z pliku tymczasowego)
    # Pozwala uniknąć błędów parsowania nawiasów klamrowych przez Basha
    log "INFO: Aktualizacja iRule..."
    
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

    # 3. Przypisanie do VS
    if tmsh list ltm virtual "$CHALLENGE_VS_NAME" > /dev/null 2>&1; then
        log "INFO: Przypinanie iRule do VS: $CHALLENGE_VS_NAME"
        tmsh modify ltm virtual "$CHALLENGE_VS_NAME" rules { "$IRULE_NAME" }
    else
        log "ERROR: VS '$CHALLENGE_VS_NAME' nie istnieje! Utwórz go najpierw na porcie 80."
        exit 1
    fi
}

register_account() {
    log "INFO: Rejestracja/Weryfikacja konta ACME..."
    
    if ! "${INSTALL_DIR}/dehydrated" --version > /dev/null 2>&1; then
         log "ERROR: Problem z plikiem binarnym dehydrated."
         return 1
    fi

    # Automatyczna akceptacja regulaminu Let's Encrypt
    "${INSTALL_DIR}/dehydrated" --register --accept-terms --config "$CONFIG_FILE" >> "$LOG_FILE" 2>&1
}

run_cron_setup() {
    log "INFO: Konfiguracja iCall (Auto-Renewal)..."
    local WRAPPER="${INSTALL_DIR}/renew_wrapper.sh"
    cat > "$WRAPPER" <<EOF
#!/bin/bash
${INSTALL_DIR}/dehydrated --cron --config $CONFIG_FILE >> ${LOG_FILE} 2>&1
EOF
    chmod +x "$WRAPPER"

    # Czyszczenie starych handlerów iCall
    tmsh delete sys icall handler periodic letse_renew_handler 2>/dev/null || true
    tmsh delete sys icall script letse_renew_script 2>/dev/null || true

    # Tworzenie nowych obiektów iCall (uruchomienie co 7 dni)
    tmsh create sys icall script letse_renew_script definition { exec $WRAPPER }
    tmsh create sys icall handler periodic letse_renew_handler script letse_renew_script interval 604800 first-occurrence 2026-02-01:03:00:00
}

# --- NOWA FUNKCJA: UPDATE PROFILES ONLY ---
# Pozwala zaktualizować ustawienia Cipherów/Options na istniejących profilach
# bez konieczności ponownego generowania certyfikatów.
update_profiles_only() {
    log "INFO: Aktualizacja ustawień SSL w profilach (bez zmiany certyfikatów)..."
    log "INFO: Ustawienia: cipher-group f5-default (TLS 1.3), options: $SSL_OPTS"
    
    for DOMAIN in "${DOMAINS[@]}"; do
        local OBJ_NAME="${DOMAIN//./_}"
        local PROFILE_NAME="cssl_${OBJ_NAME}"
        
        if tmsh list ltm profile client-ssl "$PROFILE_NAME" > /dev/null 2>&1; then
            log "INFO: Aktualizacja profilu: $PROFILE_NAME"
            tmsh modify ltm profile client-ssl "$PROFILE_NAME" ciphers none cipher-group f5-default options { $SSL_OPTS }
        else
            log "WARN: Profil $PROFILE_NAME nie istnieje (być może nie wygenerowano jeszcze certyfikatu), pomijam."
        fi
    done
    
    tmsh save sys config partitions all
    log "INFO: Aktualizacja profili zakończona."
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
        log "INFO: Instalacja zakończona."
        log "INFO: Wykonaj 'reset-certs' a potem 'issue' jeśli migrujesz z ECC na RSA."
        ;;
    issue)
        log "INFO: Rozpoczynanie generowania certyfikatów..."
        "${INSTALL_DIR}/dehydrated" --cron --config "$CONFIG_FILE"
        log "INFO: Proces zakończony. Sprawdź logi."
        ;;
    update-profiles)
        # Tylko aktualizacja ustawień bezpieczeństwa SSL
        check_root
        update_profiles_only
        ;;
    reset-certs)
        log "WARN: Usuwanie wszystkich starych certyfikatów i kont z dysku..."
        rm -rf "${CERTS_DIR:?}/"*
        log "INFO: Katalog certyfikatów wyczyszczony. Gotowy do generowania RSA."
        ;;
    show-irule)
        tmsh list ltm rule "$IRULE_NAME"
        ;;
    help|*)
        echo "F5 Let's Encrypt - RSA Edition (v5)"
        echo "Usage: $0 {install|issue|update-profiles|reset-certs|show-irule}"
        echo ""
        echo "  install          - Instaluje/Naprawia środowisko i konfiguruje tryb RSA"
        echo "  issue            - Pobiera nowe certyfikaty i tworzy/aktualizuje profile"
        echo "  update-profiles  - Wymusza TLS 1.3 i bezpieczne opcje na istniejących profilach (bez renew)"
        echo "  reset-certs      - USUWA stare certyfikaty (wymagane przy zmianie z ECC na RSA!)"
        echo "  show-irule       - Pokazuje treść iRule w systemie"
        exit 1
        ;;
esac

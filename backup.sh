#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# set -e          -> przerwij natychmiast, gdy dowolne polecenie zwróci błąd
# set -u          -> traktuj użycie niezdefiniowanej zmiennej jako błąd
# set -o pipefail -> błąd w dowolnym elemencie potoku (|) kończy cały potok
# ---------------------------------------------------------------------------
set -euo pipefail

# ===========================================================================
#  ZMIENNE GLOBALNE / STAŁE
# ===========================================================================

# Katalog, w którym znajduje się skrypt (do znalezienia domyślnego backup.conf).
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"

# Ścieżka do pliku konfiguracyjnego: 1. argument lub domyślnie obok skryptu.
readonly CONFIG_FILE="${1:-${SCRIPT_DIR}/backup.conf}"

# Maksymalny rozmiar pliku logu przed rotacją (2 MB = 2 * 1024 * 1024 bajtów).
readonly MAX_LOG_SIZE=$((2 * 1024 * 1024))

# Znacznik czasu tworzonej kopii — nazwa katalogu backup_YYYYMMDD_HHMMSS.
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"

# Flaga informująca trap, czy lockfile został już przez nas utworzony
# (dzięki temu handler nie usunie cudzego lockfile'a przy wczesnym błędzie).
LOCK_ACQUIRED=0

# ===========================================================================
#  FUNKCJE POMOCNICZE
# ===========================================================================

# ---------------------------------------------------------------------------
# log_message LEVEL "komunikat"
#   Zapisuje wpis do LOG_FILE w formacie:
#   [YYYY-MM-DD HH:MM:SS] [POZIOM] Komunikat
#   Wypisuje też na STDERR (dla poziomu ERROR) / STDOUT, co ułatwia debug
#   przy uruchamianiu ręcznym.
# ---------------------------------------------------------------------------
log_message() {
    local level="$1"
    shift
    local message="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] ${message}"

    # Rotacja logu wykonywana jest tuż przed zapisem.
    rotate_log

    # Jeśli LOG_FILE nie jest jeszcze ustawione (błąd przed wczytaniem
    # konfiguracji) — piszemy wyłącznie na STDERR.
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s\n' "${line}" >>"${LOG_FILE}"
    fi

    if [[ "${level}" == "ERROR" ]]; then
        printf '%s\n' "${line}" >&2
    else
        printf '%s\n' "${line}"
    fi
}

# ---------------------------------------------------------------------------
# rotate_log
#   Prosta rotacja: gdy LOG_FILE przekroczy MAX_LOG_SIZE, zmienia jego nazwę
#   na LOG_FILE.old (nadpisując poprzedni .old) i pozwala utworzyć nowy.
# ---------------------------------------------------------------------------
rotate_log() {
    [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE}" ]] || return 0

    local size
    # stat -c %s działa na Linuksie (GNU coreutils).
    size="$(stat -c %s "${LOG_FILE}" 2>/dev/null || echo 0)"

    if (( size > MAX_LOG_SIZE )); then
        mv -f "${LOG_FILE}" "${LOG_FILE}.old"
        # Nowy plik powstanie automatycznie przy kolejnym zapisie.
    fi
}

# ---------------------------------------------------------------------------
# die "komunikat"
#   Loguje błąd krytyczny i kończy skrypt z kodem 1.
#   Sprzątanie lockfile'a realizuje pułapka trap (cleanup).
# ---------------------------------------------------------------------------
die() {
    log_message "ERROR" "$*"
    exit 1
}

# ===========================================================================
#  KONFIGURACJA
# ===========================================================================

# ---------------------------------------------------------------------------
# load_config
#   Wczytuje zewnętrzny plik konfiguracyjny (source) i weryfikuje,
#   czy wszystkie wymagane zmienne zostały zdefiniowane.
#   Dzięki temu w skrypcie nie ma żadnych ścieżek "na sztywno".
# ---------------------------------------------------------------------------
load_config() {
    [[ -f "${CONFIG_FILE}" ]] \
        || die "Brak pliku konfiguracyjnego: ${CONFIG_FILE}"
    [[ -r "${CONFIG_FILE}" ]] \
        || die "Brak uprawnień do odczytu: ${CONFIG_FILE}"

    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"

    # Walidacja wymaganych zmiennych skalarnych.
    : "${DEST_DIR:?Zmienna DEST_DIR nie została zdefiniowana w konfiguracji}"
    : "${MAX_BACKUPS:?Zmienna MAX_BACKUPS nie została zdefiniowana w konfiguracji}"
    : "${LOG_FILE:?Zmienna LOG_FILE nie została zdefiniowana w konfiguracji}"
    : "${LOCK_FILE:?Zmienna LOCK_FILE nie została zdefiniowana w konfiguracji}"

    # SRC_DIRS musi być niepustą tablicą.
    if [[ "$(declare -p SRC_DIRS 2>/dev/null)" != "declare -a"* ]] \
        || [[ "${#SRC_DIRS[@]}" -eq 0 ]]; then
        die "Zmienna SRC_DIRS musi być niepustą tablicą katalogów źródłowych"
    fi

    # MAX_BACKUPS musi być dodatnią liczbą całkowitą.
    [[ "${MAX_BACKUPS}" =~ ^[1-9][0-9]*$ ]] \
        || die "MAX_BACKUPS musi być dodatnią liczbą całkowitą (jest: ${MAX_BACKUPS})"

    # Katalog na plik logu musi istnieć.
    local log_dir
    log_dir="$(dirname -- "${LOG_FILE}")"
    [[ -d "${log_dir}" ]] || mkdir -p "${log_dir}" \
        || die "Nie można utworzyć katalogu logów: ${log_dir}"
}

# ===========================================================================
#  BLOKADA (LOCKFILE)
# ===========================================================================

# ---------------------------------------------------------------------------
# check_lockfile
#   Zapobiega równoległemu uruchomieniu dwóch instancji skryptu.
#   - Jeśli lockfile istnieje i zapisany w nim PID nadal działa -> przerwij.
#   - Jeśli lockfile istnieje, ale proces już nie żyje (stale lock) ->
#     traktujemy go jako osierocony i nadpisujemy.
#   - W przeciwnym razie zapisujemy własny PID.
# ---------------------------------------------------------------------------
check_lockfile() {
    if [[ -e "${LOCK_FILE}" ]]; then
        local old_pid
        old_pid="$(cat "${LOCK_FILE}" 2>/dev/null || echo "")"

        # kill -0 sprawdza istnienie procesu bez wysyłania sygnału.
        if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
            die "Inna instancja skryptu już działa (PID ${old_pid}). Przerywam."
        else
            log_message "WARN" "Wykryto osierocony lockfile (PID ${old_pid:-?}). Nadpisuję."
        fi
    fi

    # Zapis własnego PID-u do lockfile'a.
    printf '%s\n' "$$" >"${LOCK_FILE}" \
        || die "Nie można utworzyć lockfile: ${LOCK_FILE}"
    LOCK_ACQUIRED=1
    log_message "INFO" "Utworzono blokadę (${LOCK_FILE}, PID $$)."
}

# ---------------------------------------------------------------------------
# cleanup
#   Handler pułapki trap. Wywoływany:
#     - przy normalnym zakończeniu (EXIT),
#     - przy przerwaniu sygnałem (SIGINT / SIGTERM / SIGHUP).
#   Usuwa lockfile TYLKO jeśli sami go założyliśmy (LOCK_ACQUIRED=1),
#   dzięki czemu nie kasujemy blokady należącej do innej instancji.
# ---------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    if (( LOCK_ACQUIRED == 1 )); then
        rm -f "${LOCK_FILE}"
        LOCK_ACQUIRED=0
        log_message "INFO" "Zwolniono blokadę (${LOCK_FILE})."
    fi
    exit "${exit_code}"
}

# ---------------------------------------------------------------------------
# handle_signal
#   Osobny handler dla sygnałów przerwania, aby zalogować przyczynę.
#   Po zalogowaniu wychodzimy — trap EXIT (cleanup) usunie lockfile.
# ---------------------------------------------------------------------------
handle_signal() {
    local sig="$1"
    log_message "ERROR" "Otrzymano sygnał ${sig}. Przerywam i sprzątam."
    # Wyjście z kodem 128 + numer sygnału to konwencja powłoki — dzięki temu
    # kod wyjścia (widoczny np. w cronie albo $?) pozwala odróżnić przerwanie
    # konkretnym sygnałem od zwykłego błędu logicznego (die -> kod 1).
    local signum
    case "${sig}" in
        SIGINT)  signum=2  ;;
        SIGTERM) signum=15 ;;
        SIGHUP)  signum=1  ;;
        *)       signum=0  ;;
    esac
    exit "$(( 128 + signum ))"
}

# ===========================================================================
#  LOGIKA BACKUPU
# ===========================================================================

# ---------------------------------------------------------------------------
# find_latest_backup
#   Zwraca (przez echo) ścieżkę do NAJNOWSZEGO istniejącego katalogu backupu
#   w DEST_DIR (posortowane po nazwie => po dacie). Pusty łańcuch, gdy brak.
# ---------------------------------------------------------------------------
find_latest_backup() {
    # Nazwy backup_YYYYMMDD_HHMMSS sortują się leksykalnie == chronologicznie.
    local latest=""
    latest="$(find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -type d \
                -name 'backup_*' 2>/dev/null | sort | tail -n 1)"
    printf '%s' "${latest}"
}

# ---------------------------------------------------------------------------
# run_backup
#   Tworzy nową, wersjonowaną kopię zapasową.
#
#   Jak działa --link-dest:
#     rsync porównuje pliki źródłowe z zawartością katalogu wskazanego przez
#     --link-dest (POPRZEDNI backup). Jeśli plik jest identyczny, zamiast go
#     ponownie kopiować, rsync tworzy TWARDE DOWIĄZANIE (hardlink) do wersji
#     z poprzedniego backupu. Plik zmieniony jest kopiowany na nowo.
#     Efekt: każdy katalog backup_* wygląda na PEŁNĄ kopię, ale niezmienione
#     pliki fizycznie zajmują miejsce na dysku tylko raz (współdzielą i-węzeł).
# ---------------------------------------------------------------------------
run_backup() {
    local dest_path="${DEST_DIR}/backup_${TIMESTAMP}"
    local link_dest
    link_dest="$(find_latest_backup)"

    # Katalog docelowy musi istnieć.
    mkdir -p "${dest_path}" \
        || die "Nie można utworzyć katalogu docelowego: ${dest_path}"

    # Bazowe opcje rsync:
    #   -a  tryb archiwum (rekurencja + zachowanie uprawnień/właściciela/czasu)
    #   -H  zachowaj istniejące hardlinki wewnątrz źródła
    #   --stats zbierz statystyki do logu
    #
    # Uwaga: celowo NIE używamy --delete. Każdy backup ląduje w świeżo
    # utworzonym, pustym katalogu "${dest_path}" (patrz mkdir -p powyżej),
    # więc rsync nigdy nie zastaje w celu "nadmiarowych" plików do skasowania
    # — --delete byłoby tu martwą opcją, sugerującą funkcjonalność (mirror
    # istniejącego katalogu), której ten skrypt w ogóle nie realizuje.
    local -a rsync_opts=(-aH --stats)

    if [[ -n "${link_dest}" ]]; then
        # Wskazujemy poprzedni backup jako bazę dla hardlinków.
        rsync_opts+=(--link-dest="${link_dest}")
        log_message "INFO" "Kopia przyrostowa względem: ${link_dest}"
    else
        log_message "INFO" "Brak poprzedniej kopii — tworzę pierwszą (pełną)."
    fi

    log_message "INFO" "Start backupu -> ${dest_path}"

    # Wykonujemy rsync dla każdego katalogu źródłowego z osobna.
    local src
    for src in "${SRC_DIRS[@]}"; do
        if [[ ! -e "${src}" ]]; then
            log_message "WARN" "Pomijam nieistniejące źródło: ${src}"
            continue
        fi
        log_message "INFO" "Kopiowanie źródła: ${src}"
        # Uwaga na ukośnik końcowy — kopiujemy katalog źródłowy jako podkatalog
        # o tej samej nazwie w katalogu docelowym.
        if ! rsync "${rsync_opts[@]}" "${src}" "${dest_path}/" \
                >>"${LOG_FILE}" 2>&1; then
            die "rsync zwrócił błąd podczas kopiowania: ${src}"
        fi
    done

    log_message "INFO" "Backup zakończony sukcesem: ${dest_path}"
}

# ---------------------------------------------------------------------------
# rotate_backups
#   Mechanizm retencji. Po udanym backupie zlicza katalogi backup_* i usuwa
#   najstarsze, jeśli ich liczba przekracza MAX_BACKUPS.
# ---------------------------------------------------------------------------
rotate_backups() {
    # Lista katalogów posortowana rosnąco (najstarsze na początku).
    local -a backups=()
    local dir
    while IFS= read -r dir; do
        [[ -n "${dir}" ]] && backups+=("${dir}")
    done < <(find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -type d \
                -name 'backup_*' 2>/dev/null | sort)

    local count="${#backups[@]}"
    log_message "INFO" "Liczba istniejących kopii: ${count} (limit: ${MAX_BACKUPS})."

    if (( count <= MAX_BACKUPS )); then
        return 0
    fi

    local to_delete=$(( count - MAX_BACKUPS ))
    log_message "INFO" "Przekroczono limit — usuwam ${to_delete} najstarszych kopii."

    local i
    for (( i = 0; i < to_delete; i++ )); do
        local old="${backups[i]}"
        if rm -rf "${old}"; then
            log_message "INFO" "Usunięto starą kopię: ${old}"
        else
            log_message "ERROR" "Nie udało się usunąć: ${old}"
        fi
    done
}

# ===========================================================================
#  MAIN
# ===========================================================================
main() {
    # 1) Wczytanie konfiguracji (ustawia m.in. LOG_FILE, LOCK_FILE, DEST_DIR).
    load_config

    # 2) Rejestracja pułapek trap.
    #    EXIT   -> cleanup (zwolnienie lockfile) przy KAŻDYM wyjściu.
    #    Sygnały-> handle_signal (zalogowanie), a następnie i tak zadziała EXIT.
    trap cleanup EXIT
    trap 'handle_signal SIGINT'  INT
    trap 'handle_signal SIGTERM' TERM
    trap 'handle_signal SIGHUP'  HUP

    log_message "INFO" "===== Rozpoczęcie zadania backupu ====="

    # 3) Katalog docelowy musi istnieć (lub go tworzymy).
    [[ -d "${DEST_DIR}" ]] || mkdir -p "${DEST_DIR}" \
        || die "Nie można utworzyć katalogu docelowego: ${DEST_DIR}"

    # 4) Blokada przed równoległym uruchomieniem.
    check_lockfile

    # 5) Właściwy backup.
    run_backup

    # 6) Retencja starych wersji (dopiero po udanym backupie).
    rotate_backups

    log_message "INFO" "===== Zadanie backupu zakończone pomyślnie ====="
    # Wyjście 0 -> trap EXIT (cleanup) zwolni lockfile.
}

main "$@"
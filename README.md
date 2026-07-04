# Dokumentacja techniczna — automatyczne kopie zapasowe (`backup.sh`)

> Projekt zaliczeniowy UNIX — skrypt tworzący **wersjonowane, przyrostowe**
> kopie zapasowe przy pomocy `rsync` i twardych dowiązań (hardlinków),
> z blokadą przed równoległym uruchomieniem, obsługą sygnałów, rotacją logów
> oraz automatyczną retencją starych wersji.

---

## Spis treści

1. [Cel i założenia projektu](#1-cel-i-założenia-projektu)
2. [Architektura rozwiązania](#2-architektura-rozwiązania)
3. [Struktura plików](#3-struktura-plików)
4. [Plik konfiguracyjny `backup.conf`](#4-plik-konfiguracyjny-backupconf)
5. [Szczegółowa analiza `backup.sh` — linia po linii](#5-szczegółowa-analiza-backupsh)
   - [5.1 Nagłówek i tryb rygorystyczny](#51-nagłówek-i-tryb-rygorystyczny)
   - [5.2 Zmienne globalne / stałe](#52-zmienne-globalne--stałe)
   - [5.3 Logowanie (`log_message`, `rotate_log`, `die`)](#53-logowanie)
   - [5.4 Wczytywanie i walidacja konfiguracji (`load_config`)](#54-wczytywanie-i-walidacja-konfiguracji)
   - [5.5 Blokada — lockfile (`check_lockfile`)](#55-blokada--lockfile)
   - [5.6 Sprzątanie i sygnały (`cleanup`, `handle_signal`, `trap`)](#56-sprzątanie-i-sygnały)
   - [5.7 Logika backupu (`find_latest_backup`, `run_backup`)](#57-logika-backupu)
   - [5.8 Retencja (`rotate_backups`)](#58-retencja)
   - [5.9 Funkcja `main`](#59-funkcja-main)
6. [Przepływ wykonania (diagram)](#6-przepływ-wykonania)
7. [Mechanizm hardlinków — dlaczego to genialne](#7-mechanizm-hardlinków)
8. [Instalacja, uruchomienie, cron](#8-instalacja-uruchomienie-cron)
9. [Kody wyjścia i obsługa błędów](#9-kody-wyjścia-i-obsługa-błędów)
10. [Bezpieczeństwo](#10-bezpieczeństwo)
11. [Znane ograniczenia i uwagi](#11-znane-ograniczenia-i-uwagi)
12. [Testowanie i weryfikacja](#12-testowanie-i-weryfikacja)
13. [Słownik pojęć](#13-słownik-pojęć)

---

## 1. Cel i założenia projektu

**Co robi skrypt?** Tworzy kopię zapasową wskazanych katalogów/plików do katalogu
docelowego. Każde uruchomienie tworzy nowy katalog `backup_RRRRMMDD_GGMMSS`,
zawierający **pełny obraz** danych źródłowych z danej chwili.

**Dlaczego takie podejście?** Projekt realizuje typowe wymagania „porządnego”
narzędzia systemowego w UNIX:

| Wymaganie                        | Jak zostało spełnione                                              |
|----------------------------------|-------------------------------------------------------------------|
| Wersjonowanie (historia kopii)   | Osobny katalog `backup_*` na każde uruchomienie                    |
| Oszczędność miejsca              | `rsync --link-dest` → hardlinki do niezmienionych plików          |
| Konfigurowalność                 | Zewnętrzny `backup.conf` — brak ścieżek „na sztywno” w kodzie      |
| Odporność na błędy               | `set -euo pipefail`, walidacja konfiguracji, funkcja `die`        |
| Brak równoległych uruchomień     | Lockfile z PID + detekcja osieroconej blokady                     |
| Czyste sprzątanie                | `trap` na `EXIT` i sygnałach (`INT`/`TERM`/`HUP`)                  |
| Audyt / diagnostyka              | Log z poziomami `INFO`/`WARN`/`ERROR` + rotacja po 2 MB           |
| Automatyczne czyszczenie         | Retencja: trzymamy tylko `MAX_BACKUPS` najnowszych kopii          |
| Praca w cronie                   | Brak wymaganej interakcji, logi do pliku, błędy na STDERR         |

**Kluczowa idea:** połączenie *wersjonowania* (wiele niezależnych migawek)
z *deduplikacją* (fizycznie każdy niezmieniony plik istnieje na dysku tylko raz).
To sprawia, że możemy przechowywać np. 30 dziennych kopii systemu, zużywając
miejsce ledwie nieco większe niż jedna kopia + suma zmian.

---

## 2. Architektura rozwiązania

Skrypt jest **modularny** — podzielony na małe funkcje o jednej
odpowiedzialności. Funkcja `main` steruje kolejnością wywołań:

```
main
 ├─ load_config       # wczytaj i zwaliduj backup.conf
 ├─ trap ...          # zarejestruj sprzątanie
 ├─ mkdir DEST_DIR    # upewnij się, że cel istnieje
 ├─ check_lockfile    # nie pozwól na dwie instancje naraz
 ├─ run_backup        # właściwe kopiowanie (rsync)
 │   └─ find_latest_backup  # znajdź bazę dla hardlinków
 └─ rotate_backups    # usuń nadmiarowe stare kopie
```

Funkcje pomocnicze (`log_message`, `rotate_log`, `die`) są używane w całym cyklu.
Takie rozbicie ułatwia czytanie, testowanie i późniejszą rozbudowę —
każdą funkcję można analizować i modyfikować w izolacji.

---

## 3. Struktura plików

| Plik              | Rola                                                                 |
|-------------------|----------------------------------------------------------------------|
| `backup.sh`       | Główny skrypt wykonywalny. Zawiera całą logikę.                      |
| `backup.conf`     | Konfiguracja: źródła, cel, retencja, ścieżki logu i lockfile.       |
| `README.md`       | Krótka instrukcja użytkownika (instalacja, cron).                    |

Rozdzielenie **kodu** (`backup.sh`) od **konfiguracji** (`backup.conf`) to
klasyczny dobry wzorzec w UNIX: ten sam skrypt może obsłużyć wiele różnych
zadań backupu, wskazując inny plik `.conf`.

---

## 4. Plik konfiguracyjny `backup.conf`

Plik jest wczytywany poleceniem `source`, więc jest to **zwykły fragment kodu
Bash** — definiuje zmienne, które skrypt później czyta.

```bash
# Tablica katalogów/plików źródłowych do skopiowania.
SRC_DIRS=(
    "/home/user/dokumenty"
    "/etc"
)

# Katalog docelowy — powstaną w nim katalogi backup_RRRRMMDD_GGMMSS.
DEST_DIR="/mnt/backups"

# Maksymalna liczba przechowywanych wersji (starsze będą usuwane).
MAX_BACKUPS=5

# Plik logu (katalog powstanie automatycznie).
LOG_FILE="/mnt/backups/logs/backup.log"

# Plik blokady zapobiegający dwóm równoległym uruchomieniom.
LOCK_FILE="/tmp/backup.lock"
```

| Zmienna       | Typ            | Znaczenie                                                        |
|---------------|----------------|------------------------------------------------------------------|
| `SRC_DIRS`    | tablica        | Lista źródeł. **Bez** końcowego ukośnika (patrz sekcja 7).       |
| `DEST_DIR`    | łańcuch        | Gdzie zapisywać kopie.                                            |
| `MAX_BACKUPS` | liczba > 0     | Ile wersji trzymać. Nadmiarowe (najstarsze) są kasowane.        |
| `LOG_FILE`    | łańcuch        | Ścieżka logu. Katalog tworzony automatycznie.                    |
| `LOCK_FILE`   | łańcuch        | Ścieżka pliku blokady (domyślnie `/tmp/backup.lock`).           |

> **Dlaczego `source` zamiast własnego parsera?** W UNIX-owej filozofii plik
> konfiguracyjny będący kodem powłoki jest najprostszym, „zerowym kosztem”
> rozwiązaniem — brak potrzeby pisania parsera, natywna obsługa tablic i
> komentarzy. Ceną jest to, że konfiguracja może wykonać dowolny kod, dlatego
> należy chronić go uprawnieniami `600` (patrz [Bezpieczeństwo](#10-bezpieczeństwo)).

---

## 5. Szczegółowa analiza `backup.sh`

### 5.1 Nagłówek i tryb rygorystyczny

```bash
#!/usr/bin/env bash
set -euo pipefail
```

- `#!/usr/bin/env bash` — **shebang**. Uruchamia skrypt tym Bashem, który jest
  pierwszy w `PATH` (przenośniej niż `#!/bin/bash`, bo Bash bywa w różnych
  lokalizacjach, np. na macOS/BSD).
- `set -e` — przerwij natychmiast, gdy jakiekolwiek polecenie zwróci kod błędu.
  Chroni przed „brnięciem dalej” po nieudanym kroku (np. nie próbujemy rotować
  backupów, jeśli `rsync` padł).
- `set -u` — użycie **niezdefiniowanej** zmiennej to błąd. Wyłapuje literówki
  w nazwach zmiennych i brakujące pola konfiguracji.
- `set -o pipefail` — potok (`a | b | c`) zwraca błąd, jeśli **którykolwiek**
  element zawiedzie, a nie tylko ostatni. Bez tego `false | true` dawałoby sukces.

**Dlaczego razem?** To „bezpieczny” tryb Basha — skrypt zachowuje się
przewidywalnie i głośno zgłasza problemy, zamiast po cichu robić coś złego.

### 5.2 Zmienne globalne / stałe

```bash
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
readonly CONFIG_FILE="${1:-${SCRIPT_DIR}/backup.conf}"
readonly MAX_LOG_SIZE=$((2 * 1024 * 1024))
readonly TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
LOCK_ACQUIRED=0
```

- **`SCRIPT_DIR`** — bezwzględna ścieżka katalogu, w którym leży skrypt.
  - `${BASH_SOURCE[0]}` to ścieżka do samego skryptu (pewniejsza niż `$0`).
  - `dirname` wycina katalog, `cd ... && pwd` normalizuje go do postaci
    bezwzględnej (rozwija symlinki i ścieżki względne).
  - `--` chroni przed nazwami zaczynającymi się od `-`; `&>/dev/null` tłumi
    ewentualne komunikaty `cd`.
  - **Po co?** By domyślny `backup.conf` znaleźć **obok skryptu**, niezależnie
    od tego, z jakiego katalogu skrypt uruchomiono (ważne w cronie).
- **`CONFIG_FILE`** — `${1:-...}` = pierwszy argument wywołania **albo** domyślnie
  `SCRIPT_DIR/backup.conf`. Pozwala wskazać własny plik: `./backup.sh /etc/moj.conf`.
- **`MAX_LOG_SIZE`** — próg rotacji logu (2 MiB), zapisany jako czytelne
  wyrażenie arytmetyczne `$((...))` zamiast „magicznej” liczby `2097152`.
- **`TIMESTAMP`** — znacznik czasu wyliczony **raz** na starcie, w formacie
  `RRRRMMDD_GGMMSS`. Używany w nazwie katalogu kopii.
  - **Dlaczego ten format?** Sortuje się **leksykalnie == chronologicznie**
    (nowsze mają „większą” nazwę), co upraszcza wyszukiwanie najnowszej/najstarszej
    kopii zwykłym `sort` (patrz sekcje 5.7 i 5.8).
- **`readonly`** — stałe, których nie da się przypadkiem nadpisać w dalszej
  części kodu (ochrona przed błędami).
- **`LOCK_ACQUIRED`** — flaga (0/1) mówiąca, **czy to my** założyliśmy lockfile.
  Kluczowa dla bezpiecznego sprzątania (patrz 5.6). Nie jest `readonly`, bo
  zmienia się w trakcie działania.

### 5.3 Logowanie

#### `log_message LEVEL "komunikat"`

```bash
log_message() {
    local level="$1"; shift
    local message="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[${ts}] [${level}] ${message}"
    rotate_log
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s\n' "${line}" >>"${LOG_FILE}"
    fi
    if [[ "${level}" == "ERROR" ]]; then
        printf '%s\n' "${line}" >&2
    else
        printf '%s\n' "${line}"
    fi
}
```

- Buduje wpis w formacie `[data godzina] [POZIOM] treść` — czytelny i łatwy do
  filtrowania (`grep ERROR backup.log`).
- `shift` + `"$*"` — pierwszy argument to poziom, reszta (dowolnie wiele słów)
  scala się w treść komunikatu.
- **Podwójne wyjście:**
  - Zawsze dopisuje do `LOG_FILE` (`>>`), o ile ta zmienna jest już ustawiona
    (`${LOG_FILE:-}` zabezpiecza przed `set -u`, gdy błąd wystąpi *przed*
    wczytaniem konfiguracji).
  - `ERROR` idzie na **STDERR** (`>&2`), pozostałe poziomy na **STDOUT**.
  - **Dlaczego?** Przy ręcznym uruchomieniu widzimy komunikaty na ekranie; w
    cronie łatwo przekierować tylko błędy na e-mail (STDERR), a resztę do logu.
- `printf '%s\n'` zamiast `echo` — `printf` jest przewidywalny (nie interpretuje
  `-n`, `-e`, ukośników w treści), więc bezpieczny dla dowolnych komunikatów.

#### `rotate_log`

```bash
rotate_log() {
    [[ -n "${LOG_FILE:-}" && -f "${LOG_FILE}" ]] || return 0
    local size
    size="$(stat -c %s "${LOG_FILE}" 2>/dev/null || echo 0)"
    if (( size > MAX_LOG_SIZE )); then
        mv -f "${LOG_FILE}" "${LOG_FILE}.old"
    fi
}
```

- Wywoływana **przed każdym zapisem** wewnątrz `log_message`.
- Jeśli log nie istnieje/nie ustawiono ścieżki — nic nie robi (`return 0`).
- `stat -c %s` zwraca rozmiar pliku w bajtach (GNU coreutils, Linux).
- Po przekroczeniu 2 MiB przenosi log do `.old` (nadpisując poprzedni `.old`),
  a nowy plik powstanie automatycznie przy najbliższym `>>`.
- **Dlaczego prosta rotacja 1-poziomowa?** Zapobiega niekontrolowanemu
  puchnięciu logu, pozostając minimalna. Trzymamy „bieżący” + „poprzedni”.

#### `die "komunikat"`

```bash
die() { log_message "ERROR" "$*"; exit 1; }
```

- Loguje błąd krytyczny jako `ERROR` i kończy skrypt kodem `1`.
- Sprzątanie lockfile’a **nie** jest tu potrzebne — zajmie się nim `trap`
  na `EXIT` (patrz 5.6). Dzięki temu `die` jest krótkie i jednoznaczne.
- Wzorzec „log + exit w jednym miejscu” eliminuje powtarzanie kodu obsługi błędów.

### 5.4 Wczytywanie i walidacja konfiguracji

```bash
load_config() {
    [[ -f "${CONFIG_FILE}" ]] || die "Brak pliku konfiguracyjnego: ${CONFIG_FILE}"
    [[ -r "${CONFIG_FILE}" ]] || die "Brak uprawnień do odczytu: ${CONFIG_FILE}"
    source "${CONFIG_FILE}"

    : "${DEST_DIR:?Zmienna DEST_DIR nie została zdefiniowana w konfiguracji}"
    : "${MAX_BACKUPS:?...}"
    : "${LOG_FILE:?...}"
    : "${LOCK_FILE:?...}"

    if [[ "$(declare -p SRC_DIRS 2>/dev/null)" != "declare -a"* ]] \
        || [[ "${#SRC_DIRS[@]}" -eq 0 ]]; then
        die "Zmienna SRC_DIRS musi być niepustą tablicą katalogów źródłowych"
    fi

    [[ "${MAX_BACKUPS}" =~ ^[1-9][0-9]*$ ]] \
        || die "MAX_BACKUPS musi być dodatnią liczbą całkowitą (jest: ${MAX_BACKUPS})"

    local log_dir; log_dir="$(dirname -- "${LOG_FILE}")"
    [[ -d "${log_dir}" ]] || mkdir -p "${log_dir}" \
        || die "Nie można utworzyć katalogu logów: ${log_dir}"
}
```

Kolejne warstwy zabezpieczeń — **zawodzimy wcześnie i czytelnie** zamiast
kraszować w połowie backupu:

1. **Istnienie i czytelność** pliku (`-f`, `-r`) — inaczej `die`.
2. **`source`** wczytuje konfigurację (definiuje zmienne).
3. **`: "${VAR:?komunikat}"`** — idiom walidacji. `:` to „nic nie rób”,
   ale `${VAR:?msg}` przerywa skrypt z podanym komunikatem, gdy `VAR` jest
   pusta/niezdefiniowana. Sprawdzamy tak wszystkie wymagane zmienne skalarne.
4. **`SRC_DIRS` musi być tablicą i niepustą** — `declare -p` wypisuje deklarację
   zmiennej; sprawdzamy, że zaczyna się od `declare -a` (tablica indeksowana)
   oraz że ma co najmniej 1 element (`${#SRC_DIRS[@]}`).
5. **`MAX_BACKUPS` to dodatnia liczba całkowita** — wyrażenie regularne
   `^[1-9][0-9]*$` odrzuca zero, liczby ujemne, tekst i wiodące zera.
6. **Katalog logu istnieje lub zostaje utworzony** (`mkdir -p`) — żeby pierwszy
   zapis do logu się powiódł.

> **Dlaczego tak drobiazgowo?** Backup działa często bez nadzoru (cron).
> Lepiej, żeby przy złej konfiguracji skrypt natychmiast krzyknął jasnym
> komunikatem, niż żeby „coś” zrobił połowicznie i zostawił niespójny stan.

### 5.5 Blokada — lockfile

```bash
check_lockfile() {
    if [[ -e "${LOCK_FILE}" ]]; then
        local old_pid; old_pid="$(cat "${LOCK_FILE}" 2>/dev/null || echo "")"
        if [[ -n "${old_pid}" ]] && kill -0 "${old_pid}" 2>/dev/null; then
            die "Inna instancja skryptu już działa (PID ${old_pid}). Przerywam."
        else
            log_message "WARN" "Wykryto osierocony lockfile (PID ${old_pid:-?}). Nadpisuję."
        fi
    fi
    printf '%s\n' "$$" >"${LOCK_FILE}" || die "Nie można utworzyć lockfile: ${LOCK_FILE}"
    LOCK_ACQUIRED=1
    log_message "INFO" "Utworzono blokadę (${LOCK_FILE}, PID $$)."
}
```

**Problem:** dwa równoległe backupy tego samego celu mogą sobie nawzajem
namieszać (wyścig o pliki, uszkodzone hardlinki, błędna retencja).

**Rozwiązanie:** plik blokady z zapisanym **PID-em** procesu:

- Jeśli lockfile istnieje, czytamy zapisany PID i sprawdzamy `kill -0 PID`.
  - `kill -0` **nie wysyła sygnału** — jedynie testuje, czy proces o danym PID
    istnieje i czy mamy do niego dostęp. To standardowy sposób na „czy ten
    proces żyje?”.
  - Żyje → to prawdziwa druga instancja → `die` (przerywamy).
  - Nie żyje → **osierocona blokada** (np. po `kill -9` albo restarcie).
    Logujemy `WARN` i **nadpisujemy** — inaczej martwy lockfile blokowałby
    backupy na zawsze.
- Zapisujemy własny PID (`$$`) i ustawiamy `LOCK_ACQUIRED=1` (patrz sprzątanie).

> **Dlaczego PID, a nie samo istnienie pliku?** Sam plik nie odróżnia „ktoś
> właśnie działa” od „poprzedni proces padł i zostawił śmieć”. PID + `kill -0`
> daje samonaprawianie się osieroconych blokad.
>
> **Uwaga o wyścigu (TOCTOU):** między sprawdzeniem a zapisem istnieje
> teoretyczne okno na wyścig. Dla zadania cyklicznego (cron co dobę/godzinę)
> jest to w praktyce nieistotne; wersja produkcyjna „hardcore” użyłaby
> `flock(1)`. Wybrano prostsze, czytelne podejście adekwatne do skali projektu.

### 5.6 Sprzątanie i sygnały

```bash
cleanup() {
    local exit_code=$?
    if (( LOCK_ACQUIRED == 1 )); then
        rm -f "${LOCK_FILE}"
        LOCK_ACQUIRED=0
        log_message "INFO" "Zwolniono blokadę (${LOCK_FILE})."
    fi
    exit "${exit_code}"
}

handle_signal() {
    local sig="$1"
    log_message "ERROR" "Otrzymano sygnał ${sig}. Przerywam i sprzątam."
    exit 1
}
```

Rejestracja w `main`:

```bash
trap cleanup EXIT
trap 'handle_signal SIGINT'  INT
trap 'handle_signal SIGTERM' TERM
trap 'handle_signal SIGHUP'  HUP
```

- **`trap cleanup EXIT`** — `cleanup` uruchomi się przy **każdym** zakończeniu
  skryptu: normalnym, przez `die`/`exit`, a także po obsłużeniu sygnału.
  - `local exit_code=$?` — zapamiętuje kod wyjścia, z jakim skrypt kończył,
    aby na końcu go **odtworzyć** (`exit "${exit_code}"`). Dzięki temu sprzątanie
    nie „zjada” pierwotnego kodu błędu.
  - Lockfile usuwamy **tylko** jeśli `LOCK_ACQUIRED==1`, czyli gdy to my go
    założyliśmy. **To kluczowe:** gdyby skrypt padł wcześnie (np. w `load_config`,
    zanim założyliśmy blokadę), `cleanup` **nie** skasuje lockfile’a należącego
    do *innej* działającej instancji.
- **Sygnały** `INT` (Ctrl+C), `TERM` (`kill`), `HUP` (zamknięcie terminala):
  - `handle_signal` **loguje przyczynę** przerwania i wychodzi.
  - Po wyjściu i tak zadziała `trap ... EXIT` → `cleanup` zwolni blokadę.
  - **Dlaczego osobny handler?** Żeby w logu został ślad, *dlaczego* backup się
    urwał (sygnał), a nie tylko „proces zniknął”.

> **Efekt netto:** niezależnie od tego, jak skrypt się kończy — sukcesem,
> błędem czy przerwaniem — lockfile zostaje posprzątany, o ile był nasz.
> Nie zostają „zombie-blokady” psujące kolejne uruchomienia.

### 5.7 Logika backupu

#### `find_latest_backup`

```bash
find_latest_backup() {
    local latest=""
    latest="$(find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -type d \
                -name 'backup_*' 2>/dev/null | sort | tail -n 1)"
    printf '%s' "${latest}"
}
```

- Szuka w `DEST_DIR` (tylko na jednym poziomie: `-mindepth 1 -maxdepth 1`)
  katalogów o nazwie `backup_*`.
- `sort | tail -n 1` → **najnowszy** (bo nazwy z `TIMESTAMP` sortują się
  chronologicznie).
- Zwraca ścieżkę przez `printf` (pusty łańcuch, gdy brak wcześniejszych kopii).
- **Po co?** Ta najnowsza kopia posłuży jako baza `--link-dest` dla hardlinków.

#### `run_backup`

```bash
run_backup() {
    local dest_path="${DEST_DIR}/backup_${TIMESTAMP}"
    local link_dest; link_dest="$(find_latest_backup)"
    mkdir -p "${dest_path}" || die "Nie można utworzyć katalogu docelowego: ${dest_path}"

    local -a rsync_opts=(-aH --delete --stats)
    if [[ -n "${link_dest}" ]]; then
        rsync_opts+=(--link-dest="${link_dest}")
        log_message "INFO" "Kopia przyrostowa względem: ${link_dest}"
    else
        log_message "INFO" "Brak poprzedniej kopii — tworzę pierwszą (pełną)."
    fi

    log_message "INFO" "Start backupu -> ${dest_path}"
    local src
    for src in "${SRC_DIRS[@]}"; do
        if [[ ! -e "${src}" ]]; then
            log_message "WARN" "Pomijam nieistniejące źródło: ${src}"; continue
        fi
        log_message "INFO" "Kopiowanie źródła: ${src}"
        if ! rsync "${rsync_opts[@]}" "${src}" "${dest_path}/" >>"${LOG_FILE}" 2>&1; then
            die "rsync zwrócił błąd podczas kopiowania: ${src}"
        fi
    done
    log_message "INFO" "Backup zakończony sukcesem: ${dest_path}"
}
```

Krok po kroku:

1. `dest_path` = `DEST_DIR/backup_<TIMESTAMP>` — katalog **tej** kopii.
2. `link_dest` = najnowsza wcześniejsza kopia (baza hardlinków) lub pusto.
3. `mkdir -p` tworzy katalog docelowy (albo `die`).
4. **Opcje `rsync`** budowane jako tablica `rsync_opts`:
   - `-a` (**archiwum**) = `-rlptgoD`: rekurencja + zachowanie symlinków,
     uprawnień, czasów, właściciela, grupy i plików specjalnych. To „wierna
     kopia 1:1”.
   - `-H` — zachowuje **hardlinki istniejące wewnątrz źródła** (żeby w kopii
     też były współdzielone i-węzły, a nie zduplikowane pliki).
   - `--stats` — dopisuje do logu statystyki transferu (ile przesłano, ile
     zlinkowano itd.).
   - **Warunkowo** `--link-dest="${link_dest}"` — sedno oszczędności miejsca
     (patrz sekcja 7).
   - **Świadomie brak `--delete`.** Ta opcja miałaby sens tylko przy
     synchronizacji do katalogu, który już zawiera starszą zawartość do
     „uzgodnienia” ze źródłem. Tutaj każdy backup ląduje w świeżo utworzonym,
     pustym `dest_path` (patrz krok 3 poniżej), więc `rsync` i tak nigdy nie
     zastałby w celu nic „nadmiarowego” do skasowania — `--delete` byłby
     martwą, mylącą opcją.
5. **Pętla po źródłach** `SRC_DIRS`:
   - Nieistniejące źródło → `WARN` + `continue` (pomijamy, ale nie wywracamy
     całego backupu — reszta źródeł się wykona).
   - `rsync ... "${src}" "${dest_path}/"` — wyjście `rsync` (stdout+stderr)
     trafia do logu (`>>"${LOG_FILE}" 2>&1`).
   - Błąd `rsync` → `die` (przerywamy, bo niekompletna kopia jest ryzykowna).

> **Uwaga o ukośniku końcowym w `rsync`:** źródło podane **bez** końcowego `/`
> (`"${src}"`, np. `/etc`) powoduje skopiowanie **samego katalogu** jako
> podkatalogu celu → powstaje `backup_.../etc/...`. Gdyby dodać `/` (`/etc/`),
> rsync skopiowałby *zawartość* katalogu bezpośrednio do celu. Dlatego
> konfiguracja wymaga źródeł **bez** końcowego ukośnika — zachowujemy nazwy
> katalogów i unikamy zlania różnych źródeł w jedno.

### 5.8 Retencja

```bash
rotate_backups() {
    local -a backups=(); local dir
    while IFS= read -r dir; do
        [[ -n "${dir}" ]] && backups+=("${dir}")
    done < <(find "${DEST_DIR}" -mindepth 1 -maxdepth 1 -type d \
                -name 'backup_*' 2>/dev/null | sort)

    local count="${#backups[@]}"
    log_message "INFO" "Liczba istniejących kopii: ${count} (limit: ${MAX_BACKUPS})."
    if (( count <= MAX_BACKUPS )); then return 0; fi

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
```

- Wczytuje listę katalogów `backup_*` **posortowaną rosnąco** (najstarsze na
  początku tablicy) do tablicy `backups`.
  - **`while read ... < <(find ... | sort)`** (podstawienie procesu) zamiast
    `for x in $(...)` — poprawnie obsługuje nazwy ze spacjami/znakami
    specjalnymi. `IFS=` + `read -r` czyta całe linie bez obcinania i bez
    interpretacji ukośników.
- Jeśli liczba kopii `<= MAX_BACKUPS` — nic nie usuwamy.
- W przeciwnym razie liczymy nadmiar `to_delete` i kasujemy tyle **najstarszych**
  (od początku posortowanej tablicy) przez `rm -rf`.
- Nieudane `rm` logujemy jako `ERROR`, ale **nie** przerywamy — próbujemy usunąć
  pozostałe.

> **Dlaczego retencja dopiero po udanym backupie?** `main` woła `rotate_backups`
> **po** `run_backup`. Gdyby backup padł, nie chcemy usuwać starych, dobrych
> kopii — mogłyby być jedyne, jakie mamy.
>
> **Bezpieczeństwo hardlinków przy kasowaniu:** usunięcie starego katalogu
> `backup_*` **nie** niszczy danych w nowszych kopiach. Przy hardlinkach plik
> fizycznie znika dopiero, gdy zniknie **ostatnie** dowiązanie do i-węzła —
> nowsze kopie wciąż go trzymają.

### 5.9 Funkcja `main`

```bash
main() {
    load_config
    trap cleanup EXIT
    trap 'handle_signal SIGINT'  INT
    trap 'handle_signal SIGTERM' TERM
    trap 'handle_signal SIGHUP'  HUP
    log_message "INFO" "===== Rozpoczęcie zadania backupu ====="
    [[ -d "${DEST_DIR}" ]] || mkdir -p "${DEST_DIR}" \
        || die "Nie można utworzyć katalogu docelowego: ${DEST_DIR}"
    check_lockfile
    run_backup
    rotate_backups
    log_message "INFO" "===== Zadanie backupu zakończone pomyślnie ====="
}
main "$@"
```

**Kolejność jest celowa:**

1. `load_config` — najpierw, bo ustawia `LOG_FILE`, `LOCK_FILE`, `DEST_DIR` itd.
   (bez tego logowanie i blokada nie miałyby ścieżek).
2. `trap ...` — rejestrujemy sprzątanie **zanim** cokolwiek utworzymy.
3. `mkdir DEST_DIR` — upewniamy się, że cel istnieje.
4. `check_lockfile` — dopiero teraz zajmujemy blokadę.
5. `run_backup` → `rotate_backups` — właściwa praca, retencja na końcu.
6. `main "$@"` — przekazuje argumenty wywołania (np. ścieżkę do `.conf`) do
   funkcji. Wywołanie `main` na samym końcu to wzorzec, który sprawia, że cały
   skrypt jest zdefiniowany (wszystkie funkcje) przed pierwszym wykonaniem.

---

## 6. Przepływ wykonania

```
START
  │
  ▼
load_config ──(błąd)──► die → EXIT(1) → cleanup (lock nie nasz → nie ruszamy)
  │ ok
  ▼
trap EXIT/INT/TERM/HUP
  │
  ▼
mkdir DEST_DIR
  │
  ▼
check_lockfile ──(inna instancja żyje)──► die → EXIT(1)
  │ zajęto blokadę (LOCK_ACQUIRED=1)
  ▼
run_backup
  ├─ find_latest_backup → link_dest
  ├─ mkdir backup_<TS>
  └─ for src in SRC_DIRS: rsync -aH --delete [--link-dest] ──(błąd)──► die
  │ ok
  ▼
rotate_backups (usuń najstarsze ponad MAX_BACKUPS)
  │
  ▼
log "sukces"
  │
  ▼
EXIT(0) → cleanup → rm lockfile → koniec
```

Na **każdej** ścieżce wyjścia (sukces/błąd/sygnał) `trap EXIT` wywołuje
`cleanup`, który zwalnia lockfile, jeśli był nasz.

---

## 7. Mechanizm hardlinków

To serce projektu — jak mieć **wiele pełnych kopii** przy **minimalnym** koszcie
miejsca.

### Co to jest hardlink?

W systemie plików UNIX plik to **i-węzeł** (inode) z danymi + jedna lub więcej
**nazw** (wpisów w katalogach) wskazujących na ten i-węzeł. Hardlink to po prostu
kolejna nazwa dla tego samego i-węzła. Dane istnieją na dysku **raz**; usunięcie
jednej nazwy nie kasuje danych, dopóki istnieje inna.

### Jak używa tego `rsync --link-dest`

Przy tworzeniu nowej kopii `rsync` porównuje każdy plik źródłowy z jego
odpowiednikiem w katalogu `--link-dest` (czyli w **poprzednim** backupie):

- Plik **niezmieniony** → zamiast kopiować dane, `rsync` tworzy **hardlink** do
  wersji z poprzedniej kopii. Zero dodatkowego miejsca na dane.
- Plik **zmieniony/nowy** → kopiowany normalnie (świeże dane, nowy i-węzeł).

### Efekt

```
DEST_DIR/
├── backup_20260101_020000/   # pierwsza (pełna)   plik A(v1), B(v1)
├── backup_20260102_020000/   # A→hardlink do v1,  B zmieniony → B(v2)
└── backup_20260103_020000/   # A→hardlink do v1,  B→hardlink do v2
```

- Każdy katalog **wygląda i działa** jak kompletna, samodzielna kopia — możesz
  wejść do dowolnego i odzyskać pliki z tamtej chwili.
- Fizycznie: `A` zajmuje miejsce **raz** (współdzielony przez 3 kopie),
  `B` — dwie wersje.
- Usunięcie `backup_20260101...` (retencja) **nie** psuje pozostałych — dane `A`
  przetrwają, bo trzymają je hardlinki w nowszych kopiach.

### Warunek działania

Hardlinki działają **tylko w obrębie jednego systemu plików**. Wszystkie kopie
powstają w `DEST_DIR`, więc warunek jest spełniony automatycznie. Ważne przy
wyborze `DEST_DIR` na produkcji: cały `DEST_DIR` musi być na jednej partycji.

---

## 8. Instalacja, uruchomienie, cron

### Instalacja

```bash
chmod +x backup.sh        # nadaj prawo wykonywania
chmod 600 backup.conf     # ochrona konfiguracji (patrz Bezpieczeństwo)
```

Uzupełnij `backup.conf` (`SRC_DIRS`, `DEST_DIR`, `MAX_BACKUPS`, `LOG_FILE`,
`LOCK_FILE`).

### Uruchomienie ręczne

```bash
./backup.sh                    # użyje backup.conf obok skryptu
./backup.sh /etc/backup.conf   # albo wskaż własny plik konfiguracyjny
```

### Cron (codziennie o 02:00)

`crontab -e` i dodaj (spacje w ścieżce trzeba eskejpować `\ `):

```cron
0 2 * * * /home/wojciech-ofiara/Desktop/Projekt\ zaliczeniowy\ UNIX/backup.sh /home/wojciech-ofiara/Desktop/Projekt\ zaliczeniowy\ UNIX/backup.conf >/dev/null 2>&1
```

- Pola crona: `min hour dom mon dow` → `0 2 * * *` = codziennie 02:00.
- `>/dev/null 2>&1` — cisza, bo pełne logi i tak trafiają do `LOG_FILE`.
- Chcesz e-mail od crona **tylko przy błędach**? Usuń `>/dev/null 2>&1` — skrypt
  pisze błędy (`ERROR`) na STDERR, a cron wysyła STDERR mailem do właściciela.
- Backup katalogów wymagających roota (np. `/etc`) → `sudo crontab -e`.

---

## 9. Kody wyjścia i obsługa błędów

| Kod         | Znaczenie                                                                 |
|-------------|-----------------------------------------------------------------------------|
| `0`         | Sukces — backup i retencja wykonane; lockfile zwolniony.                  |
| `1`         | Błąd krytyczny (`die`): zła konfiguracja, brak dostępu, błąd `rsync`, druga instancja działa. |
| `129`       | Przerwanie sygnałem `SIGHUP` (128 + 1).                                    |
| `130`       | Przerwanie sygnałem `SIGINT`, np. Ctrl+C (128 + 2).                        |
| `143`       | Przerwanie sygnałem `SIGTERM`, np. `kill` (128 + 15).                      |

Kody `129/130/143` to standardowa powłokowa konwencja `128 + numer sygnału` —
pozwala to (np. w cronie albo skrypcie nadrzędnym sprawdzającym `$?`) odróżnić
świadome przerwanie sygnałem od zwykłego błędu logicznego (`die` → kod `1`).

Mechanizmy wyłapywania błędów, warstwami:

- `set -e` — nieobsłużony błąd polecenia przerywa skrypt.
- `set -u` — brak zmiennej to błąd (wyłapuje literówki i braki w `.conf`).
- `set -o pipefail` — błąd w potoku nie ginie.
- `die` — świadome, opisane przerwania w krytycznych miejscach.
- `trap` — gwarancja sprzątania niezależnie od przyczyny wyjścia.

---

## 10. Bezpieczeństwo

- **`chmod 600 backup.conf`** — konfiguracja jest wczytywana przez `source`,
  więc *wykonuje się jak kod*. Ograniczenie praw do właściciela zapobiega temu,
  by ktoś podmienił jej treść i wstrzyknął polecenia uruchamiane z prawami
  właściciela skryptu (potencjalnie roota w cronie).
- **Lockfile w `/tmp`** — `/tmp` bywa zapisywalny dla wszystkich. Na produkcji
  rozważ `LOCK_FILE` w katalogu o ograniczonym dostępie, by nikt nie podłożył
  pliku z cudzym PID-em.
- **`--` przy `dirname`/`cd`** — chroni przed nazwami ścieżek zaczynającymi się
  od `-` (nie zostaną potraktowane jako opcje).
- **`printf` zamiast `echo`** — brak interpretacji treści komunikatów.
- **Cytowanie zmiennych** (`"${VAR}"`) w całym skrypcie — poprawna obsługa
  spacji i znaków specjalnych w ścieżkach, zapobiega „word splitting” i globbingowi.

---

## 11. Znane ograniczenia i uwagi

- **Wyścig TOCTOU w lockfile** — teoretyczne okno między sprawdzeniem a zapisem
  PID-u. Nieistotne dla zadań cyklicznych; produkcyjnie użyłoby się `flock`.
- **Backup lokalny** — kopie lądują na tym samym hoście/partycji co
  `DEST_DIR`. To nie chroni przed awarią dysku ani pożarem serwerowni.
  Prawdziwy DR wymaga kopii **poza** maszyną (offsite/offline). Hardlinki
  wymagają jednego systemu plików, więc `DEST_DIR` nie może być zdalnym FS-em
  bez wsparcia hardlinków.
- **Rotacja logu 1-poziomowa** — trzymamy `LOG_FILE` + `LOG_FILE.old`. Starsze
  logi przepadają. Zwykle wystarcza; przy potrzebie audytu → `logrotate`.
- **Zależności od GNU** — `stat -c %s`, `date +...`, opcje `find` zakładają
  Linux/GNU coreutils. Na BSD/macOS część flag różni się składnią.

---

## 12. Testowanie i weryfikacja

Szybki test lokalny bez ruszania systemowych katalogów:

```bash
mkdir -p /tmp/test/src /tmp/test/dest
echo "wersja1" > /tmp/test/src/plik.txt

cat > /tmp/test/backup.conf <<'EOF'
SRC_DIRS=( "/tmp/test/src" )
DEST_DIR="/tmp/test/dest"
MAX_BACKUPS=3
LOG_FILE="/tmp/test/dest/logs/backup.log"
LOCK_FILE="/tmp/test/backup.lock"
EOF

./backup.sh /tmp/test/backup.conf          # pierwsza kopia (pełna)
echo "wersja2" > /tmp/test/src/plik.txt
./backup.sh /tmp/test/backup.conf          # druga (przyrostowa)

ls -l /tmp/test/dest/                       # zobacz katalogi backup_*
cat /tmp/test/dest/logs/backup.log          # przejrzyj log
```

Co warto sprawdzić:

- **Hardlinki:** `ls -li` w dwóch kopiach — niezmienione pliki mają **ten sam
  numer i-węzła** i licznik dowiązań > 1.
  ```bash
  ls -li /tmp/test/dest/backup_*/src/plik.txt
  ```
- **Blokada:** uruchom dwie instancje „na raz” — druga powinna zakończyć się
  `die` z komunikatem o działającej instancji.
- **Retencja:** wykonaj backup > `MAX_BACKUPS` razy — najstarsze katalogi
  powinny zniknąć, a w logu pojawi się „usuwam ... najstarszych kopii”.
- **Sygnały:** przerwij Ctrl+C w trakcie — w logu wpis `ERROR` o sygnale,
  a lockfile powinien zostać usunięty.
- **Statyczna analiza:** `shellcheck backup.sh` (wykrywa typowe błędy Basha).

---

## 13. Słownik pojęć

| Termin              | Znaczenie                                                                |
|---------------------|--------------------------------------------------------------------------|
| **Shebang**         | `#!/usr/bin/env bash` — mówi systemowi, czym uruchomić skrypt.           |
| **i-węzeł (inode)** | Struktura z danymi i metadanymi pliku; nazwy plików wskazują na i-węzeł. |
| **Hardlink**        | Dodatkowa nazwa dla tego samego i-węzła; dane istnieją raz.              |
| **`--link-dest`**   | Opcja `rsync`: niezmienione pliki linkuje do poprzedniej kopii.          |
| **Lockfile**        | Plik-blokada zapobiegający równoległym uruchomieniom.                    |
| **PID**             | Identyfikator procesu; `$$` to PID bieżącego skryptu.                    |
| **`kill -0`**       | Test istnienia procesu bez wysyłania sygnału.                            |
| **`trap`**          | Rejestruje reakcję na zdarzenie/sygnał (np. sprzątanie na `EXIT`).       |
| **TOCTOU**          | Time-of-check to time-of-use — klasa błędów wyścigu.                     |
| **Retencja**        | Polityka „ile wersji trzymać”; starsze są usuwane.                       |
| **Rotacja logu**    | Ograniczanie rozmiaru logu przez przenoszenie do `.old`.                 |

---

*Dokument opisuje stan skryptu `backup.sh` i `backup.conf` z repozytorium
projektu zaliczeniowego UNIX.*

#!/usr/bin/env bash
#
# web_network_scan.sh — standalone web + network recon, no cloud, no Python.
#
# Pipeline: subfinder -> alterx -> dnsx -> cdncheck -> httpx -> naabu(+nmap)
#           -> tlsx -> katana -> ffuf -> nuclei (+ takeover) -> gowitness
#
# Everything is raw JSONL/text under OUTPUT_BASE/<date>/ — no database,
# nothing cloud-specific. Run by hand or from cron, same as cronjob.sh did
# for the full pipeline.
#
# Usage:
#   ./web_network_scan.sh
#
# All settings you'd want to tweak live in the CONFIG block right below —
# edit those, not the functions underneath.

set -uo pipefail

# ============================================================================
# CONFIG — edit this block for day-to-day changes. Nothing else should need
# touching unless you're adding a new tool to the pipeline.
# ============================================================================

DOMAINS=(
  "gameberrylabs.com"
  "superkinglabs.com"
)

BASE_DIR="${HOME}/projects/asm"
OUTPUT_BASE="${BASE_DIR}/output"
LOG_DIR="${BASE_DIR}/logs"
WORDLIST="${BASE_DIR}/wordlists/raft-small-directories.txt"
NUCLEI_TEMPLATES="${HOME}/nuclei-templates"

SUBFINDER_THREADS=50
DNSX_THREADS=100
NAABU_RATE=1000
NAABU_TOP_PORTS=1000          # or "full" to scan all 65535 (much slower)
HTTPX_THREADS=50
FFUF_THREADS=40
FFUF_TIMEOUT=10
NUCLEI_RATE_LIMIT=150
NUCLEI_SEVERITIES="low,medium,high,critical"
KATANA_DEPTH=3
REQUEST_TIMEOUT=10

# alterx's permutation patterns multiply against every word it extracts from
# your subdomains, so this number can explode fast (hundreds of subdomains
# can easily become hundreds of thousands of candidates). Capping it keeps
# the dnsx resolution step after it from running unpredictably long or
# hammering your DNS resolvers. Raise it if you want deeper permutation
# coverage and have the time/resolver capacity for it.
ALTERX_LIMIT=20000

# Optional: export CHAOS_KEY in your shell/cron env to enable chaos lookups.
# Leave unset to skip it silently.

# ============================================================================
# Internals — shouldn't need to edit below this line for routine changes.
# ============================================================================

RUN_DATE="$(date '+%Y-%m-%d')"
OUT_DIR="${OUTPUT_BASE}/${RUN_DATE}"
LOG_FILE="${LOG_DIR}/web_network_scan.log"

mkdir -p "${OUT_DIR}" "${LOG_DIR}" "${OUT_DIR}/ffuf" "${OUT_DIR}/screenshots"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$1] ${*:2}" | tee -a "${LOG_FILE}"
}

have() {
    command -v "$1" >/dev/null 2>&1
}

require_or_skip() {
    # require_or_skip <tool-name> <what-step-does>
    if ! have "$1"; then
        log "WARN" "$1 not found on PATH — skipping $2"
        return 1
    fi
    return 0
}

log "INFO" "=== web_network_scan starting, output dir: ${OUT_DIR} ==="

# ----------------------------------------------------------------------------
# 1. Subdomain enumeration: subfinder (+ chaos if CHAOS_KEY is set)
# ----------------------------------------------------------------------------
SUBFINDER_RAW="${OUT_DIR}/subfinder_raw.jsonl"
ALL_SUBS_TXT="${OUT_DIR}/all_subdomains.txt"
: > "${SUBFINDER_RAW}"
: > "${ALL_SUBS_TXT}"

if require_or_skip subfinder "subdomain enumeration"; then
    for domain in "${DOMAINS[@]}"; do
        log "INFO" "subfinder: ${domain}"
        subfinder -d "${domain}" -silent -json -t "${SUBFINDER_THREADS}" >> "${SUBFINDER_RAW}" 2>>"${LOG_FILE}"
    done
    jq -r '.host // empty' "${SUBFINDER_RAW}" 2>/dev/null | sort -u >> "${ALL_SUBS_TXT}"
fi

if [ -n "${CHAOS_KEY:-}" ] && have chaos; then
    CHAOS_RAW="${OUT_DIR}/chaos_raw.jsonl"
    : > "${CHAOS_RAW}"
    for domain in "${DOMAINS[@]}"; do
        log "INFO" "chaos: ${domain}"
        chaos -d "${domain}" -silent -json >> "${CHAOS_RAW}" 2>>"${LOG_FILE}"
    done
    jq -r '.subdomain // .host // empty' "${CHAOS_RAW}" 2>/dev/null | sort -u >> "${ALL_SUBS_TXT}"
elif [ -z "${CHAOS_KEY:-}" ]; then
    log "INFO" "CHAOS_KEY not set, skipping chaos"
fi

sort -u -o "${ALL_SUBS_TXT}" "${ALL_SUBS_TXT}"
log "INFO" "$(wc -l < "${ALL_SUBS_TXT}") unique subdomains from subfinder/chaos"

# ----------------------------------------------------------------------------
# 2. Permutations: alterx generates likely-but-unseen hostnames
# ----------------------------------------------------------------------------
CANDIDATES_TXT="${OUT_DIR}/alterx_candidates.txt"
: > "${CANDIDATES_TXT}"

if [ -s "${ALL_SUBS_TXT}" ] && require_or_skip alterx "hostname permutation"; then
    alterx -l "${ALL_SUBS_TXT}" -o "${CANDIDATES_TXT}" -limit "${ALTERX_LIMIT}" 2>>"${LOG_FILE}"
    log "INFO" "alterx generated $(wc -l < "${CANDIDATES_TXT}") candidate hostnames (capped at ${ALTERX_LIMIT})"
fi

ALL_HOSTS_TXT="${OUT_DIR}/all_hostnames.txt"
cat "${ALL_SUBS_TXT}" "${CANDIDATES_TXT}" 2>/dev/null | sort -u > "${ALL_HOSTS_TXT}"

# ----------------------------------------------------------------------------
# 3. Resolve everything with dnsx
# ----------------------------------------------------------------------------
DNSX_RAW="${OUT_DIR}/dnsx_raw.jsonl"
RESOLVED_HOSTS_TXT="${OUT_DIR}/resolved_hosts.txt"
IPS_TXT="${OUT_DIR}/ips.txt"
: > "${DNSX_RAW}"
: > "${RESOLVED_HOSTS_TXT}"
: > "${IPS_TXT}"

if [ -s "${ALL_HOSTS_TXT}" ] && require_or_skip dnsx "DNS resolution"; then
    dnsx -l "${ALL_HOSTS_TXT}" -a -aaaa -cname -resp -json -silent \
        -t "${DNSX_THREADS}" >> "${DNSX_RAW}" 2>>"${LOG_FILE}"
    jq -r '.host // empty' "${DNSX_RAW}" 2>/dev/null | sort -u > "${RESOLVED_HOSTS_TXT}"
    jq -r '(.a // [])[], (.aaaa // [])[]' "${DNSX_RAW}" 2>/dev/null | sort -u > "${IPS_TXT}"
    log "INFO" "dnsx resolved $(wc -l < "${RESOLVED_HOSTS_TXT}") hosts, $(wc -l < "${IPS_TXT}") unique IPs"
fi

# ----------------------------------------------------------------------------
# 4. CDN/WAF context (informational — doesn't gate later steps)
# ----------------------------------------------------------------------------
CDNCHECK_RAW="${OUT_DIR}/cdncheck_raw.jsonl"
: > "${CDNCHECK_RAW}"

if [ -s "${RESOLVED_HOSTS_TXT}" ] && require_or_skip cdncheck "CDN/WAF detection"; then
    cdncheck -l "${RESOLVED_HOSTS_TXT}" -resp -json -silent >> "${CDNCHECK_RAW}" 2>>"${LOG_FILE}"
fi

# ----------------------------------------------------------------------------
# 5. Which resolved hosts speak HTTP(S)
# ----------------------------------------------------------------------------
HTTPX_RAW="${OUT_DIR}/httpx_raw.jsonl"
LIVE_URLS_TXT="${OUT_DIR}/live_urls.txt"
: > "${HTTPX_RAW}"
: > "${LIVE_URLS_TXT}"

if [ -s "${RESOLVED_HOSTS_TXT}" ] && require_or_skip httpx "web liveness probe"; then
    httpx -l "${RESOLVED_HOSTS_TXT}" -silent -json \
        -title -tech-detect -status-code -web-server -cdn -follow-redirects \
        -timeout "${REQUEST_TIMEOUT}" -t "${HTTPX_THREADS}" >> "${HTTPX_RAW}" 2>>"${LOG_FILE}"
    jq -r '.url // empty' "${HTTPX_RAW}" 2>/dev/null | sort -u > "${LIVE_URLS_TXT}"
    log "INFO" "httpx found $(wc -l < "${LIVE_URLS_TXT}") live web assets"
fi

# ----------------------------------------------------------------------------
# 6. Port scanning: naabu for discovery, nmap for service/version detail
#    on exactly the ports naabu found open (kept separate so naabu's JSON
#    stays clean and parseable rather than interleaved with nmap text).
# ----------------------------------------------------------------------------
NAABU_RAW="${OUT_DIR}/naabu_raw.jsonl"
: > "${NAABU_RAW}"

if [ -s "${IPS_TXT}" ] && require_or_skip naabu "port scanning"; then
    if [ "${NAABU_TOP_PORTS}" = "full" ]; then
        PORT_ARGS=(-p -)
    else
        PORT_ARGS=(-top-ports "${NAABU_TOP_PORTS}")
    fi
    naabu -list "${IPS_TXT}" -json -silent -rate "${NAABU_RATE}" "${PORT_ARGS[@]}" \
        >> "${NAABU_RAW}" 2>>"${LOG_FILE}"
    log "INFO" "naabu found $(wc -l < "${NAABU_RAW}") open ports"

    if require_or_skip nmap "service/version detection"; then
        # Group open ports by IP, then run one nmap -sV per IP across just
        # the ports naabu found — avoids a blind full-port nmap sweep.
        jq -r '[.ip // .host, (.port|tostring)] | @tsv' "${NAABU_RAW}" 2>/dev/null \
        | awk -F'\t' '{ports[$1] = ports[$1] "," $2} END {for (ip in ports) print ip, substr(ports[ip],2)}' \
        | while read -r ip port_list; do
            xml_out="${OUT_DIR}/nmap_$(echo "${ip}" | tr ':' '_').xml"
            log "INFO" "nmap -sV on ${ip} (${port_list})"
            nmap -sV -Pn -p "${port_list}" -oX "${xml_out}" "${ip}" >>"${LOG_FILE}" 2>&1
        done
    fi
fi

# ----------------------------------------------------------------------------
# 7. TLS / certificate info
# ----------------------------------------------------------------------------
TLSX_RAW="${OUT_DIR}/tlsx_raw.jsonl"
: > "${TLSX_RAW}"

if [ -s "${RESOLVED_HOSTS_TXT}" ] && require_or_skip tlsx "TLS/cert info"; then
    tlsx -l "${RESOLVED_HOSTS_TXT}" -json -silent -cert-expiry -tls-version -san \
        >> "${TLSX_RAW}" 2>>"${LOG_FILE}"
    log "INFO" "tlsx collected $(wc -l < "${TLSX_RAW}") TLS records"
fi

# ----------------------------------------------------------------------------
# 8. Crawling
# ----------------------------------------------------------------------------
KATANA_RAW="${OUT_DIR}/katana_raw.jsonl"
CRAWLED_URLS_TXT="${OUT_DIR}/crawled_urls.txt"
: > "${KATANA_RAW}"
: > "${CRAWLED_URLS_TXT}"

if [ -s "${LIVE_URLS_TXT}" ] && require_or_skip katana "crawling"; then
    katana -list "${LIVE_URLS_TXT}" -json -silent -depth "${KATANA_DEPTH}" \
        >> "${KATANA_RAW}" 2>>"${LOG_FILE}"
    jq -r '.request.endpoint // .url // empty' "${KATANA_RAW}" 2>/dev/null | sort -u > "${CRAWLED_URLS_TXT}"
    log "INFO" "katana crawled $(wc -l < "${CRAWLED_URLS_TXT}") unique URLs"
fi

# ----------------------------------------------------------------------------
# 9. Directory / file fuzzing (ffuf)
# ----------------------------------------------------------------------------
if [ ! -s "${WORDLIST}" ]; then
    log "WARN" "wordlist missing at ${WORDLIST} — skipping ffuf (see MANUAL_SETUP.md)"
elif [ -s "${LIVE_URLS_TXT}" ] && require_or_skip ffuf "directory fuzzing"; then
    while read -r url; do
        [ -z "${url}" ] && continue
        safe_name="$(echo "${url}" | sed 's#://#_#; s#/#_#g' | cut -c1-150)"
        json_out="${OUT_DIR}/ffuf/${safe_name}.json"
        log "INFO" "ffuf: ${url}"
        ffuf -u "${url%/}/FUZZ" -w "${WORDLIST}" -of json -o "${json_out}" \
            -mc 200,204,301,302,307,401,403 \
            -t "${FFUF_THREADS}" -timeout "${FFUF_TIMEOUT}" -silent >>"${LOG_FILE}" 2>&1
    done < "${LIVE_URLS_TXT}"
fi

# ----------------------------------------------------------------------------
# 10. Vulnerability scanning + dedicated subdomain-takeover pass
# ----------------------------------------------------------------------------
NUCLEI_TARGETS_TXT="${OUT_DIR}/nuclei_targets.txt"
cat "${LIVE_URLS_TXT}" "${CRAWLED_URLS_TXT}" 2>/dev/null | sort -u > "${NUCLEI_TARGETS_TXT}"

NUCLEI_RAW="${OUT_DIR}/nuclei_raw.jsonl"
: > "${NUCLEI_RAW}"
if [ -s "${NUCLEI_TARGETS_TXT}" ] && require_or_skip nuclei "vulnerability scanning"; then
    nuclei -l "${NUCLEI_TARGETS_TXT}" -jsonl -o "${NUCLEI_RAW}" \
        -severity "${NUCLEI_SEVERITIES}" -rate-limit "${NUCLEI_RATE_LIMIT}" \
        -templates "${NUCLEI_TEMPLATES}" -silent >>"${LOG_FILE}" 2>&1
    log "INFO" "nuclei produced $(wc -l < "${NUCLEI_RAW}" 2>/dev/null || echo 0) findings"
fi

TAKEOVER_RAW="${OUT_DIR}/takeover_raw.jsonl"
: > "${TAKEOVER_RAW}"
if [ -s "${RESOLVED_HOSTS_TXT}" ] && require_or_skip nuclei "subdomain takeover scan"; then
    nuclei -l "${RESOLVED_HOSTS_TXT}" -jsonl -o "${TAKEOVER_RAW}" \
        -tags takeover -templates "${NUCLEI_TEMPLATES}" -silent >>"${LOG_FILE}" 2>&1
    log "INFO" "takeover scan produced $(wc -l < "${TAKEOVER_RAW}" 2>/dev/null || echo 0) hits"
fi

# Dangling-DNS heuristic companion check: CNAME targets that don't resolve at all
DANGLING_TXT="${OUT_DIR}/dangling_dns.txt"
: > "${DANGLING_TXT}"
if [ -s "${DNSX_RAW}" ] && have dnsx && have jq; then
    CNAME_TARGETS="${OUT_DIR}/cname_targets.txt"
    jq -r '(.cname // [])[]' "${DNSX_RAW}" 2>/dev/null | sort -u > "${CNAME_TARGETS}"
    if [ -s "${CNAME_TARGETS}" ]; then
        RESOLVING_TARGETS="${OUT_DIR}/cname_targets_resolving.txt"
        dnsx -l "${CNAME_TARGETS}" -a -resp -json -silent 2>>"${LOG_FILE}" \
            | jq -r 'select(.a != null and (.a | length) > 0) | .host' | sort -u > "${RESOLVING_TARGETS}"
        comm -23 "${CNAME_TARGETS}" "${RESOLVING_TARGETS}" > "${DANGLING_TXT}" 2>/dev/null || true
        log "INFO" "$(wc -l < "${DANGLING_TXT}") CNAME targets do not resolve (potential dangling DNS)"
    fi
fi

# ----------------------------------------------------------------------------
# 11. Screenshots of every live web asset
# ----------------------------------------------------------------------------
if [ -s "${LIVE_URLS_TXT}" ] && require_or_skip gowitness "screenshots"; then
    # gowitness v3 syntax. If you're on v2, use instead:
    #   gowitness file -f "${LIVE_URLS_TXT}" -P "${OUT_DIR}/screenshots"
    gowitness scan file -f "${LIVE_URLS_TXT}" --screenshot-path "${OUT_DIR}/screenshots" \
        >>"${LOG_FILE}" 2>&1
    log "INFO" "gowitness wrote $(find "${OUT_DIR}/screenshots" -name '*.png' 2>/dev/null | wc -l) screenshots"
fi

log "INFO" "=== web_network_scan finished. Output: ${OUT_DIR} ==="
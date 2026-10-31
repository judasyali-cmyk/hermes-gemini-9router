#!/usr/bin/env bash
# Hermes Agent + 9router + Gemini API + Telegram bootstrap for Debian/Ubuntu.
set -Eeuo pipefail
umask 077

APP_NAME=hermes-gemini-9router
ROUTER_NAME=9router
ROUTER_IMAGE=${ROUTER_IMAGE:-decolua/9router:latest}
ROUTER_PORT=${ROUTER_PORT:-20128}
ROUTER_DATA=${ROUTER_DATA:-/root/.9router}
HERMES_HOME=${HERMES_HOME:-/root/.hermes}
STATE="$ROUTER_DATA/.${APP_NAME}.env"
TMPDIR_BOOT=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BOOT"' EXIT

say(){ printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
ok(){ printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn(){ printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die(){ printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die 'Jalankan sebagai root: sudo bash install.sh'
[ -r /etc/os-release ] || die 'OS tidak dikenal; butuh Debian/Ubuntu.'
. /etc/os-release
case "${ID:-}" in ubuntu|debian) ;; *) die "OS tidak didukung: ${PRETTY_NAME:-unknown}";; esac
command -v curl >/dev/null || { apt-get update -qq; apt-get install -y curl ca-certificates; }
command -v python3 >/dev/null || { apt-get update -qq; apt-get install -y python3; }
command -v openssl >/dev/null || { apt-get update -qq; apt-get install -y openssl; }

say 'Input rahasia (tidak akan ditampilkan)'
if [ -f "$STATE" ]; then
  # Existing state belongs to this installer. Keep keys out of the terminal output.
  # shellcheck disable=SC1090
  . "$STATE"
fi
ROUTER_PASSWORD=${ROUTER_PASSWORD:-}
if [ -z "$ROUTER_PASSWORD" ]; then
  read -rsp 'Password dashboard 9router (kosong=buat acak): ' ROUTER_PASSWORD; echo
fi
[ -n "$ROUTER_PASSWORD" ] || ROUTER_PASSWORD=$(openssl rand -hex 18)
read -rsp 'Gemini API key (Google AI Studio): ' GEMINI_API_KEY; echo
[ -n "$GEMINI_API_KEY" ] || die 'Gemini API key wajib diisi.'
read -rsp 'Telegram bot token (@BotFather): ' TELEGRAM_BOT_TOKEN; echo
[ -n "$TELEGRAM_BOT_TOKEN" ] || die 'Telegram bot token wajib diisi.'
read -rp 'Telegram numeric user ID (buat allowlist): ' TELEGRAM_ALLOWED_USERS
[[ "$TELEGRAM_ALLOWED_USERS" =~ ^[0-9]+$ ]] || die 'User ID harus angka. Ambil dari @userinfobot.'

say 'Validasi Gemini key dan deteksi model'
GEMINI_API_KEY="$GEMINI_API_KEY" python3 - "$TMPDIR_BOOT/gemini-models.json" <<'PY'
import json, os, sys, urllib.request, urllib.error
key=os.environ['GEMINI_API_KEY']
url='https://generativelanguage.googleapis.com/v1beta/models'
req=urllib.request.Request(url, headers={'Accept':'application/json','x-goog-api-key':key})
# Never put the secret in a URL: URLs are routinely captured in proxy/server logs.
try:
    with urllib.request.urlopen(req, timeout=25) as r: data=json.load(r)
except urllib.error.HTTPError as e:
    body=e.read().decode('utf-8','replace')[:350]
    print(f'Google Gemini API returned HTTP {e.code}: {body}', file=sys.stderr);sys.exit(2)
except Exception as e:
    print(f'Could not reach Gemini API: {type(e).__name__}: {e}',file=sys.stderr);sys.exit(2)
models=[]
for m in data.get('models',[]):
    methods=m.get('supportedGenerationMethods',[])
    name=m.get('name','').removeprefix('models/')
    if name and 'generateContent' in methods and ('gemini' in name.lower()):
        models.append({'id':name,'displayName':m.get('displayName',name)})
models.sort(key=lambda m:m['id'])
if not models:
    print('API key valid but Google returned no Gemini generateContent models.',file=sys.stderr);sys.exit(3)
json.dump(models,open(sys.argv[1],'w'))
print(f'Key valid. Found {len(models)} Gemini models:')
for i,m in enumerate(models,1): print(f"  {i}) {m['displayName']} [{m['id']}]")
PY

MODEL_SELECTION=${MODEL_SELECTION:-}
if [ -z "$MODEL_SELECTION" ]; then
  read -rp 'Nomor model utama: ' MAIN_NO
  [[ "$MAIN_NO" =~ ^[0-9]+$ ]] || die 'Pilih nomor model berupa angka.'
  MAIN_MODEL=$(python3 - "$TMPDIR_BOOT/gemini-models.json" "$MAIN_NO" <<'PY'
import json,sys
m=json.load(open(sys.argv[1]));i=int(sys.argv[2])-1
if i<0 or i>=len(m): raise SystemExit('Nomor model di luar daftar.')
print(m[i]['id'])
PY
) || die 'Nomor model tidak valid.'
  read -rp 'Nomor model cadangan (enter=skip, pisahkan koma untuk beberapa): ' FALLBACK_NOS
  MODEL_SELECTION="$MAIN_NO${FALLBACK_NOS:+,$FALLBACK_NOS}"
fi
MODEL_IDS=$(python3 - "$TMPDIR_BOOT/gemini-models.json" "$MODEL_SELECTION" <<'PY'
import json,sys
models=json.load(open(sys.argv[1])); nums=[]
for token in sys.argv[2].split(','):
 token=token.strip()
 if not token: continue
 if not token.isdigit() or int(token)<1 or int(token)>len(models): raise SystemExit(f'Invalid model choice: {token}')
 mid=models[int(token)-1]['id']
 if mid not in nums: nums.append(mid)
if not nums: raise SystemExit('Choose at least one model.')
print('\n'.join(nums))
PY
) || die 'Pilihan model tidak valid.'
MAIN_MODEL=$(printf '%s\n' "$MODEL_IDS" | sed -n '1p')

say 'Install Docker'
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o "$TMPDIR_BOOT/get-docker.sh"
  sh "$TMPDIR_BOOT/get-docker.sh" >"$TMPDIR_BOOT/docker-install.log" 2>&1 || { tail -30 "$TMPDIR_BOOT/docker-install.log"; die 'Docker install gagal.'; }
fi
systemctl enable --now docker >/dev/null 2>&1 || true
docker info >/dev/null 2>&1 || die 'Docker daemon tidak jalan.'
ok "Docker tersedia: $(docker --version | cut -d, -f1)"

say 'Jalankan 9router loopback-only'
mkdir -p "$ROUTER_DATA"
if docker ps -a --format '{{.Names}}' | grep -qx "$ROUTER_NAME"; then
  docker start "$ROUTER_NAME" >/dev/null
else
  docker run -d --name "$ROUTER_NAME" --restart unless-stopped \
    -p "127.0.0.1:${ROUTER_PORT}:20128" \
    -v "${ROUTER_DATA}:/app/data" \
    -e DATA_DIR=/app/data -e NODE_ENV=production -e PORT=20128 -e TZ=Asia/Jakarta \
    -e INITIAL_PASSWORD="$ROUTER_PASSWORD" "$ROUTER_IMAGE" >/dev/null
fi
for _ in $(seq 1 60); do
  curl -fsS -m 3 "http://127.0.0.1:${ROUTER_PORT}/api/version" >/dev/null 2>&1 && break
  sleep 2
done
curl -fsS -m 5 "http://127.0.0.1:${ROUTER_PORT}/api/version" >/dev/null || die '9router belum siap.'
ok "9router hidup di http://127.0.0.1:${ROUTER_PORT}"

say 'Login dashboard 9router'
COOKIE="$TMPDIR_BOOT/cookies.txt"
LOGIN_BODY=$(ROUTER_PW="$ROUTER_PASSWORD" python3 -c 'import json,os;print(json.dumps({"password":os.environ["ROUTER_PW"]}))')
LOGIN=$(curl -fsS -m 20 -c "$COOKIE" -X POST "http://127.0.0.1:${ROUTER_PORT}/api/auth/login" -H 'Content-Type: application/json' --data "$LOGIN_BODY")
echo "$LOGIN" | grep -q '"success":true' || die "Login 9router gagal: $LOGIN"
ok 'Login sukses'

say 'Tambahkan Gemini API key'
PROVIDERS=$(curl -fsS -m 15 -b "$COOKIE" "http://127.0.0.1:${ROUTER_PORT}/api/providers")
if printf '%s' "$PROVIDERS" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if any(c.get("provider")=="gemini" for c in d.get("connections",[])) else 1)'; then
  warn 'Sudah ada koneksi Gemini di router. Tidak menimpa koneksi lama; pakai yang ada.'
else
  BODY=$(GKEY="$GEMINI_API_KEY" MODEL="$MAIN_MODEL" python3 -c 'import json,os;print(json.dumps({"provider":"gemini","apiKey":os.environ["GKEY"],"name":"Gemini API (bootstrap)","defaultModel":os.environ["MODEL"],"priority":1}))')
  RESP=$(curl -sS -m 30 -b "$COOKIE" -X POST "http://127.0.0.1:${ROUTER_PORT}/api/providers" -H 'Content-Type: application/json' --data "$BODY")
  if ! printf '%s' "$RESP" | grep -q '"connection"'; then echo "$RESP"; die 'Gagal menambahkan Gemini provider.'; fi
  ok 'Gemini connection dibuat (key tidak ditampilkan)'
fi

say 'Buat Gemini combo dengan fallback'
COMBO_NAME=gemini-auto
COMBOS=$(curl -fsS -m 15 -b "$COOKIE" "http://127.0.0.1:${ROUTER_PORT}/api/combos")
EXIST=$(printf '%s' "$COMBOS" | python3 -c 'import json,sys;d=json.load(sys.stdin);print("yes" if any(c.get("name")=="gemini-auto" for c in d.get("combos",[])) else "no")')
if [ "$EXIST" = yes ]; then COMBO_NAME="gemini-auto-$(date +%s)"; warn "Combo gemini-auto sudah ada; bikin $COMBO_NAME"; fi
COMBO_MODELS=$(printf '%s\n' "$MODEL_IDS" | python3 -c 'import json,sys; print(json.dumps(["gemini/"+x.strip() for x in sys.stdin if x.strip()]))')
COMBO_BODY=$(CB_NAME="$COMBO_NAME" CB_MODELS="$COMBO_MODELS" python3 -c 'import json,os;print(json.dumps({"name":os.environ["CB_NAME"],"models":json.loads(os.environ["CB_MODELS"])}))')
COMBO_RESP=$(curl -sS -m 20 -b "$COOKIE" -X POST "http://127.0.0.1:${ROUTER_PORT}/api/combos" -H 'Content-Type: application/json' --data "$COMBO_BODY")
printf '%s' "$COMBO_RESP" | grep -q '"models"' || { echo "$COMBO_RESP"; die 'Gagal membuat combo.'; }
ok "Combo $COMBO_NAME berisi $(printf '%s\n' "$MODEL_IDS" | wc -l | tr -d ' ') model Gemini"

say 'Buat client key Hermes dan validasi model'
KEYS=$(curl -fsS -m 15 -b "$COOKIE" "http://127.0.0.1:${ROUTER_PORT}/api/keys")
if printf '%s' "$KEYS" | python3 -c 'import json,sys;d=json.load(sys.stdin);sys.exit(0 if any(k.get("name")=="hermes-local" for k in d.get("keys",[])) else 1)'; then
  warn 'Client key bernama hermes-local sudah ada, bikin key bernama lain.'
  KEY_NAME="hermes-local-$(date +%H%M%S)"
else KEY_NAME=hermes-local; fi
KEY_BODY=$(KN="$KEY_NAME" python3 -c 'import json,os;print(json.dumps({"name":os.environ["KN"]}))')
KEY_RESP=$(curl -sS -m 20 -b "$COOKIE" -X POST "http://127.0.0.1:${ROUTER_PORT}/api/keys" -H 'Content-Type: application/json' --data "$KEY_BODY")
CLIENT_KEY=$(printf '%s' "$KEY_RESP" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("key",""))')
[ -n "$CLIENT_KEY" ] || die 'Gagal membuat client key.'
HTTP=$(curl -sS -o "$TMPDIR_BOOT/models.json" -w '%{http_code}' -m 20 "http://127.0.0.1:${ROUTER_PORT}/v1/models" -H "Authorization: Bearer $CLIENT_KEY")
[ "$HTTP" = 200 ] || die "Router client key gagal (HTTP $HTTP)."
if ! python3 - "$TMPDIR_BOOT/models.json" "$COMBO_NAME" <<'PY'
import json,sys
ids={x.get('id') for x in json.load(open(sys.argv[1])).get('data',[])}
if sys.argv[2] not in ids: raise SystemExit(1)
PY
then die 'Combo tidak muncul di /v1/models.'; fi
ok 'Client key valid dan combo muncul di /v1/models'

say 'Install Hermes dan simpan config'
if ! command -v hermes >/dev/null 2>&1; then
  curl -fsSL https://hermes-agent.nousresearch.com/install.sh -o "$TMPDIR_BOOT/hermes-install.sh"
  bash "$TMPDIR_BOOT/hermes-install.sh" --non-interactive
  export PATH="$HOME/.local/bin:$PATH"; hash -r
fi
command -v hermes >/dev/null 2>&1 || die 'Hermes tidak ditemukan setelah install.'
SLUG=$(printf '127.0.0.1:%s' "$ROUTER_PORT" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g')
KEY_ENV="HERMES_CUSTOM_${SLUG}_API_KEY"
hermes config set model.provider custom >/dev/null
hermes config set model.base_url "http://127.0.0.1:${ROUTER_PORT}/v1" >/dev/null
hermes config set model.api_key "\${$KEY_ENV}" >/dev/null
hermes config set model.default "$COMBO_NAME" >/dev/null
write_env() {
  ENVF="$HERMES_HOME/.env" EK="$1" EV="$2" python3 -c '
import os,pathlib
p=pathlib.Path(os.environ["ENVF"]);p.parent.mkdir(parents=True,exist_ok=True)
lines=p.read_text().splitlines() if p.exists() else []; pref=os.environ["EK"]+"="
lines=[pref+os.environ["EV"] if x.startswith(pref) else x for x in lines] if any(x.startswith(pref) for x in lines) else lines+[pref+os.environ["EV"]]
p.write_text("\n".join(lines)+"\n");os.chmod(p,0o600)'
}
write_env "$KEY_ENV" "$CLIENT_KEY"
write_env TELEGRAM_BOT_TOKEN "$TELEGRAM_BOT_TOKEN"
write_env TELEGRAM_ALLOWED_USERS "$TELEGRAM_ALLOWED_USERS"
write_env TELEGRAM_HOME_CHANNEL "$TELEGRAM_ALLOWED_USERS"
# Store router password for dashboard access, mode 600; don't echo secret values.
ROUTER_PASSWORD="$ROUTER_PASSWORD" GEMINI_API_KEY="$GEMINI_API_KEY" CLIENT_KEY="$CLIENT_KEY" STATE="$STATE" python3 - <<'PY'
import os,pathlib
p=pathlib.Path(os.environ['STATE']);p.parent.mkdir(parents=True,exist_ok=True)
content='\n'.join(f'{k}={os.environ[k]}' for k in ('ROUTER_PASSWORD','GEMINI_API_KEY','CLIENT_KEY'))+'\n'
p.write_text(content);os.chmod(p,0o600)
PY
ok "Hermes default model diset ke combo $COMBO_NAME; secrets tersimpan mode 600"

say 'Install Telegram gateway service'
loginctl enable-linger root >/dev/null 2>&1 || true
hermes gateway --accept-hooks install --if-missing --start-now --start-on-login >"$TMPDIR_BOOT/gateway.log" 2>&1 || { tail -40 "$TMPDIR_BOOT/gateway.log"; die 'Gagal memasang Hermes gateway.'; }
sleep 3
STATUS=$(hermes gateway status 2>&1 || true)
printf '%s\n' "$STATUS" | head -8
printf '%s' "$STATUS" | grep -qi 'active (running)' || warn 'Gateway belum terlihat running; periksa `hermes gateway status`.'

say 'Selesai'
printf 'Dashboard: http://127.0.0.1:%s (via SSH tunnel)\n' "$ROUTER_PORT"
printf 'Hermes model combo: %s\n' "$COMBO_NAME"
printf 'Provider: gemini | model utama: %s\n' "$MAIN_MODEL"
printf 'Secrets file: %s/.env (mode 600)\n' "$HERMES_HOME"
printf 'Router bootstrap state: %s (mode 600)\n' "$STATE"
echo 'Tes dari Telegram: kirim pesan ke bot; user ID yang di-allowlist sudah diset.'
echo 'Tes model manual: hermes chat -q "balas hanya OK"'

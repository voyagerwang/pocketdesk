#!/bin/zsh
# [INPUT]: 系统 openssl、主机 DNS/IP 与用户的 Application Support；不读取已有账户密码。
# [OUTPUT]: 本机 TLS 身份（p12 与供内存装配的 DER 证书/私钥）及可交给手机信任的 CA 证书；私钥不离开电脑，已有身份不覆盖、只补派生。
# [POS]: scripts 的一次性 HTTPS 配置，供 SecureTransport 读取；手机信任仍由用户完成。
# [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
set -euo pipefail
umask 077
tls_dir="$HOME/Library/Application Support/VoiceDeck/tls"

# 从既有 p12 派生内存装配所需的 DER 副本（SecureTransport 直接读它们建内存身份，全程不碰钥匙串）。
# 只派生、绝不重新签发：重签会让手机已信任的 CA 与已授权的传感器权限全部作废。
derive_der() {
  local dir="$1"
  [[ -e "$dir/server-key.der" && -e "$dir/server-cert.der" ]] && return 0
  echo '正在从现有 server.p12 派生 DER（证书本身不变）…'
  openssl pkcs12 -in "$dir/server.p12" -nocerts -nodes -passin "file:$dir/password" 2>/dev/null \
    | openssl rsa -outform DER -out "$dir/server-key.der" 2>/dev/null
  openssl pkcs12 -in "$dir/server.p12" -clcerts -nokeys -passin "file:$dir/password" 2>/dev/null \
    | openssl x509 -outform DER -out "$dir/server-cert.der" 2>/dev/null
}

if [[ -e "$tls_dir/server.p12" ]]; then
  echo 'TLS 目录已存在，保留现有证书。'
  derive_der "$tls_dir"
  [[ -e "$tls_dir/server-key.der" && -e "$tls_dir/server-cert.der" ]] \
    || { echo 'DER 派生失败：请确认 tls/password 可读且系统 openssl 可用。' >&2; exit 1; }
  echo "手机信任证书：$tls_dir/PocketDesk-CA.cer"
  exit 0
fi

stage_dir="$(mktemp -d)"
trap 'rm -rf -- "$stage_dir"' EXIT
python3 - "$stage_dir" <<'PY'
import ipaddress,pathlib,secrets,socket,subprocess,sys
p=pathlib.Path(sys.argv[1]); names={'localhost'}; ips={'127.0.0.1','::1'}
host=subprocess.run(['/usr/sbin/scutil','--get','LocalHostName'],capture_output=True,text=True).stdout.strip()
if host and all(c.isalnum() or c=='-' for c in host): names.add(host+'.local')
out=subprocess.run(['/sbin/ifconfig'],capture_output=True,text=True).stdout
for line in out.splitlines():
 parts=line.split()
 if len(parts)>1 and parts[0]=='inet':
  ip=ipaddress.ip_address(parts[1])
  if ip.is_private or ip in ipaddress.ip_network('100.64.0.0/10'): ips.add(str(ip))
san=','.join(['DNS:'+x for x in sorted(names)]+['IP:'+x for x in sorted(ips)])
(p/'leaf.ext').write_text('basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName='+san+'\n')
(p/'root.cnf').write_text('[req]\ndistinguished_name=dn\nx509_extensions=ca\nprompt=no\n[dn]\nCN=PocketDesk Local Device CA\n[ca]\nbasicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign,cRLSign\nsubjectKeyIdentifier=hash\n')
(p/'password').write_text(secrets.token_urlsafe(32)+'\n')
PY
openssl req -x509 -newkey rsa:3072 -nodes -days 825 -config "$stage_dir/root.cnf" -keyout "$stage_dir/root.key" -out "$stage_dir/root.pem" 2>/dev/null
openssl req -new -newkey rsa:2048 -nodes -subj '/CN=PocketDesk' -keyout "$stage_dir/server.key" -out "$stage_dir/server.csr" 2>/dev/null
openssl x509 -req -in "$stage_dir/server.csr" -CA "$stage_dir/root.pem" -CAkey "$stage_dir/root.key" -CAcreateserial -days 397 -extfile "$stage_dir/leaf.ext" -out "$stage_dir/server.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$stage_dir/server.key" -in "$stage_dir/server.pem" -certfile "$stage_dir/root.pem" -out "$stage_dir/server.p12" -passout "file:$stage_dir/password"
openssl x509 -in "$stage_dir/root.pem" -outform DER -out "$stage_dir/PocketDesk-CA.cer"
# 内存装配用的 DER 副本：SecureTransport 直接读这两个文件建 SecKey/SecIdentity，不进钥匙串。
openssl rsa -in "$stage_dir/server.key" -outform DER -out "$stage_dir/server-key.der" 2>/dev/null
openssl x509 -in "$stage_dir/server.pem" -outform DER -out "$stage_dir/server-cert.der"
mkdir -p "$tls_dir"
cp "$stage_dir/server.p12" "$stage_dir/password" "$stage_dir/PocketDesk-CA.cer" "$stage_dir/root.pem" "$stage_dir/server-key.der" "$stage_dir/server-cert.der" "$tls_dir/"
# root.key 不保留：服务器叶子私钥不能签发其他站点证书。
openssl x509 -in "$stage_dir/root.pem" -noout -fingerprint -sha256
echo "手机信任证书：$tls_dir/PocketDesk-CA.cer"
echo '重启 PocketDesk 后 HTTPS 使用 46487，WSS 使用 46488/46489。手机须正常信任证书；不要跳过浏览器证书警告。'

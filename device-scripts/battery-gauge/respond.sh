#!/bin/sh
# systemd socket-activation HTTP 响应器；每个请求短暂启动，空闲零常驻进程。

BASE=/cache/battery-gauge
STATE=/run/battery-gauge/state.json

IFS=' ' read -r method target protocol || exit 0
while IFS= read -r header; do
    [ -z "$header" ] && break
    [ "$header" = "$(printf '\r')" ] && break
done

path=${target%%\?*}

send_file() {
    file=$1
    content_type=$2
    if [ ! -r "$file" ]; then
        send_text 503 application/json '{"error":"state unavailable"}'
        return
    fi
    length=$(wc -c < "$file" | tr -d ' ')
    printf 'HTTP/1.1 200 OK\r\n'
    printf 'Content-Type: %s\r\n' "$content_type"
    printf 'Content-Length: %s\r\n' "$length"
    printf 'Cache-Control: no-store\r\n'
    printf 'Connection: close\r\n\r\n'
    [ "$method" = "HEAD" ] || cat "$file"
}

send_text() {
    code=$1
    content_type=$2
    body=$3
    printf 'HTTP/1.1 %s\r\n' "$code"
    printf 'Content-Type: %s; charset=utf-8\r\n' "$content_type"
    printf 'Content-Length: %s\r\n' "${#body}"
    printf 'Cache-Control: no-store\r\n'
    printf 'Connection: close\r\n\r\n'
    [ "$method" = "HEAD" ] || printf '%s' "$body"
}

case "$method" in
    GET|HEAD) ;;
    *) send_text '405 Method Not Allowed' text/plain 'Method not allowed'; exit 0 ;;
esac

case "$path" in
    /|/index.html) send_file "$BASE/index.html" 'text/html; charset=utf-8' ;;
    /state.json) send_file "$STATE" 'application/json; charset=utf-8' ;;
    /favicon.ico) send_text '204 No Content' text/plain '' ;;
    *) send_text '404 Not Found' text/plain 'Not found' ;;
esac

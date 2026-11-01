#!/bin/sh
#
# Drive the upload module against a running nginx: send files the way a
# browser does and check what the module stored on disk and that it handed
# the request on to the upload_pass location.
#
# t/ exercises the same paths, but this runs the module end to end against a
# real HTTP client and a real upstream, which is what the FreeBSD job, the
# sanitizer job and the valgrind job want.
#
# usage: ci/upload.sh <nginx binary>
#
# Set UPLOAD_LOAD_MODULE to the path of ngx_http_upload_module.so to test a
# loadable build.  Set UPLOAD_VALGRIND=1 to run nginx in the foreground under
# valgrind and fail on any memory finding; the module's own suite cannot run
# under valgrind because its mock upstream times out at valgrind speed, so the
# end-to-end driver is what carries the valgrind gate.

set -eu

NGINX=${1:?path to the nginx binary missing}
SRC=$(cd "$(dirname "$0")/.." && pwd)
WORK=${CI_WORK:-$SRC/ci-work}/upload
PORT=${UPLOAD_PORT:-18650}
UP=$((PORT + 1))

command -v curl > /dev/null || { echo "curl(1) is needed" >&2; exit 2; }

VG=${UPLOAD_VALGRIND:-}
vglog="$WORK/logs/valgrind.log"
maxtime=10
daemon_mode=on
master_mode=on
if [ -n "$VG" ]; then
	command -v valgrind > /dev/null || { echo "valgrind(1) is needed" >&2; exit 2; }
	# a single foreground process is what valgrind can watch and what shuts
	# down cleanly on QUIT, so its pools are freed and a leak report means
	# the module, not nginx being killed mid-flight
	daemon_mode=off
	master_mode=off
	maxtime=60
fi

rm -rf "$WORK"
mkdir -p "$WORK/conf" "$WORK/logs" "$WORK/state" "$WORK/tmp"
# upload_store with one level of hashing wants the digit directories there
i=0; while [ $i -lt 10 ]; do mkdir -p "$WORK/store/$i"; i=$((i + 1)); done

fail=0
note() { echo "  $1" >&2; fail=1; }

# A known payload: 200000 bytes, so a resumable upload really spans more
# than one chunk and the content is distinctive enough to compare.
payload="$WORK/payload.bin"
head -c 200000 /dev/urandom > "$payload"
total=$(wc -c < "$payload" | tr -d " ")

load=
[ -n "${UPLOAD_LOAD_MODULE:-}" ] && load="load_module $UPLOAD_LOAD_MODULE;"

# Run as root (the FreeBSD job does) and nginx workers drop to "nobody",
# which cannot write the root-owned upload store, so pin the workers to root.
ngx_user=
if [ "$(id -u)" = 0 ]; then
	ngx_user="user root $(id -gn);"
fi

cat > "$WORK/conf/nginx.conf" <<CONF
$load
$ngx_user
daemon $daemon_mode;
master_process $master_mode;
worker_processes 1;
pid $WORK/logs/nginx.pid;
error_log $WORK/logs/error.log info;
events { worker_connections 64; }
http {
    access_log off;
    client_body_temp_path $WORK/tmp;
    client_max_body_size 10m;

    upstream upl_upstream { server 127.0.0.1:$UP; }

    server {
        listen 127.0.0.1:$UP;
        location / { return 200 "UP-OK\n"; }
    }

    server {
        listen 127.0.0.1:$PORT;

        location = /simple/ {
            upload_pass @up;
            upload_store $WORK/store 1;
            upload_set_form_field name "\$upload_file_name";
            upload_cleanup 400 404 499 500-505;
        }

        location = /resumable/ {
            upload_pass @up;
            upload_resumable on;
            upload_store $WORK/store 1;
            upload_state_store $WORK/state;
            upload_set_form_field name "\$upload_file_name";
            upload_cleanup 400 404 499 500-505;
        }

        location @up { proxy_pass http://upl_upstream; }
    }
}
CONF

"$NGINX" -p "$WORK" -c "$WORK/conf/nginx.conf" -t 2> "$WORK/logs/t.log" ||
	{ cat "$WORK/logs/t.log" >&2; echo "ci/upload.sh: config rejected" >&2; exit 1; }

ngxpid=
if [ -n "$VG" ]; then
	valgrind --leak-check=full --show-leak-kinds=definite,indirect \
		--errors-for-leak-kinds=definite,indirect --error-exitcode=99 \
		--log-file="$vglog" --suppressions="$SRC/valgrind.suppress" \
		--trace-children=no \
		"$NGINX" -p "$WORK" -c "$WORK/conf/nginx.conf" &
	ngxpid=$!
	# valgrind instruments nginx start-up, so give the listener a while
	up=0; i=0
	while [ $i -lt 80 ]; do
		if curl -s -o /dev/null --max-time 5 "http://127.0.0.1:$PORT/_ping"; then
			up=1; break
		fi
		sleep 0.5; i=$((i + 1))
	done
	[ "$up" = 1 ] || { echo "ci/upload.sh: nginx did not come up under valgrind" >&2; kill "$ngxpid" 2>/dev/null; exit 1; }
else
	"$NGINX" -p "$WORK" -c "$WORK/conf/nginx.conf"
	sleep 1
fi

stop() {
	if [ -n "$ngxpid" ]; then
		kill -QUIT "$ngxpid" 2>/dev/null
		wait "$ngxpid" 2>/dev/null
	elif [ -s "$WORK/logs/nginx.pid" ]; then
		kill -QUIT "$(cat "$WORK/logs/nginx.pid")" 2>/dev/null
	fi
	return 0
}
trap stop EXIT INT TERM

stored_latest() { find "$WORK/store" -type f 2>/dev/null | head -1; }

echo "== a simple multipart upload is stored byte for byte"
rm -f "$WORK"/store/*/* 2>/dev/null || true
code=$(curl -s -o "$WORK/r1.out" -w '%{http_code}' --max-time "$maxtime" \
	-F "file=@$payload;filename=test.bin" "http://127.0.0.1:$PORT/simple/")
echo "  status $code, upstream said $(tr -d '\n' < "$WORK/r1.out")"
[ "$code" = 200 ] || note "simple upload did not reach the upstream (got $code)"
f=$(stored_latest)
if [ -n "$f" ] && cmp -s "$f" "$payload"; then
	echo "  stored file matches the payload ($(wc -c < "$f") bytes)"
else
	note "the stored file does not match what was uploaded"
fi

echo "== a resumable upload in two chunks is reassembled byte for byte"
rm -f "$WORK"/store/*/* 2>/dev/null || true
half=100000
head -c $half "$payload" > "$WORK/c0"
tail -c +$((half + 1)) "$payload" > "$WORK/c1"
sess=res0001
c0=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$maxtime" -X POST \
	-H "Session-ID: $sess" -H "Content-Type: text/plain" \
	-H "Content-Disposition: form-data; name=\"file\"; filename=\"test.bin\"" \
	-H "X-Content-Range: bytes 0-$((half - 1))/$total" \
	--data-binary @"$WORK/c0" "http://127.0.0.1:$PORT/resumable/")
c1=$(curl -s -o "$WORK/r2.out" -w '%{http_code}' --max-time "$maxtime" -X POST \
	-H "Session-ID: $sess" -H "Content-Type: text/plain" \
	-H "Content-Disposition: form-data; name=\"file\"; filename=\"test.bin\"" \
	-H "X-Content-Range: bytes $half-$((total - 1))/$total" \
	--data-binary @"$WORK/c1" "http://127.0.0.1:$PORT/resumable/")
echo "  first chunk $c0, second chunk $c1"
[ "$c0" = 201 ] || note "the partial chunk should answer 201, got $c0"
[ "$c1" = 200 ] || note "the final chunk should answer 200, got $c1"
f=$(stored_latest)
if [ -n "$f" ] && cmp -s "$f" "$payload"; then
	echo "  reassembled file matches the payload ($(wc -c < "$f") bytes)"
else
	note "the reassembled file does not match the upload"
fi

echo "== a GET is refused with 405"
g=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$maxtime" "http://127.0.0.1:$PORT/simple/")
echo "  GET says $g"
[ "$g" = 405 ] || note "a non-POST request should be 405, got $g"

echo "== error log"
if grep -qE '\[(alert|emerg|crit)\]' "$WORK/logs/error.log"; then
	note "alert/emerg/crit in the error log"
	grep -E '\[(alert|emerg|crit)\]' "$WORK/logs/error.log" | head -3 >&2
else
	echo "  clean"
fi

if [ -n "$VG" ]; then
	echo "== valgrind"
	stop
	ngxpid=
	trap - EXIT INT TERM
	# key on the counts valgrind reports, not on the words: the summary always
	# prints "definitely lost" even when it is zero
	errs=$(sed -n 's/.*ERROR SUMMARY: \([0-9][0-9]*\) errors.*/\1/p' "$vglog" | tail -1)
	defl=$(sed -n 's/.*definitely lost: \([0-9,]*\) bytes.*/\1/p' "$vglog" | tr -d , | tail -1)
	indl=$(sed -n 's/.*indirectly lost: \([0-9,]*\) bytes.*/\1/p' "$vglog" | tr -d , | tail -1)
	if [ "${errs:-0}" != 0 ] || [ "${defl:-0}" != 0 ] || [ "${indl:-0}" != 0 ]; then
		note "valgrind: ${errs:-?} errors, definitely lost ${defl:-?}, indirectly lost ${indl:-?}"
		grep -niE "Invalid read|Invalid write|uninitialised|Mismatched free" "$vglog" >&2
	else
		echo "  clean (errors $errs, suppressed shown in log)"
	fi
fi

[ "$fail" -eq 0 ] || { echo "ci/upload.sh: failed" >&2; exit 1; }
echo "ci/upload.sh: ok"

# Changelog

## Unreleased

### Fixed

- CI: the Test::Nginx cache is now keyed by the Perl build, not just by
  the runner OS.  When the hosted image moved to Ubuntu 26.04 the cached
  `~/perl5` tree was restored against a new interpreter and every test
  file died before its first assertion with `loadable library and perl
  binaries are mismatched`, taking Build & Test, A/UBSan and Valgrind
  down together.

## 2.4.0 (2026-11-01)

Taken over as a maintained fork of fdintino/nginx-upload-module, whose code
last changed in 2023 and whose newest tag (2.3.0, 2018) predates the HTTP/2
support that sits unreleased on its master branch.  This release is that
development state, built and tested against current nginx, plus the fixes
below.

- HTTP/2 uploads (from upstream master, not previously released).
- Fix `upload_pass_form_field` under PCRE2 (upstream PR #157/#152): a
  successful `ngx_regex_exec` returns a non-negative value, so a field is
  passed when the match returns `>= 0`, not only on exactly `0`.  Without
  this no field matched the filter on a PCRE2 build.
- Build against freenginx (upstream PR #154): freenginx has no
  `r->start_sec`, so the upload rate limiter reads `r->start_time` there.
- The bundled test harness bound its mock upstream to `localhost`, which
  resolves to `::1` on a dual-stack host while nginx and the harness connect
  over IPv4; it now binds `127.0.0.1`, so the suite runs where `localhost`
  is IPv6-first.

Large multi-chunk resumable uploads over HTTP/2 are not exercised by the
test suite: the Test::Nginx HTTP/2 client does not send WINDOW_UPDATE, so a
request body past the initial HTTP/2 flow-control window is truncated and
the module then correctly answers 416.  The same uploads run over HTTP/1.1
in `t/aggregate_fields.t`, and were verified working over HTTP/2 with curl.

Valgrind runs against the end-to-end driver (`ci/upload.sh`), not the
Test::Nginx suite: that suite proxies every request to a mock upstream that
times out at valgrind speed.  The driver starts one foreground nginx under
valgrind and stops it with QUIT, so the pools are freed and a leak report
would be the module's own; it is clean.

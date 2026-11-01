# nginx-upload-module

[![Build&Test][build-test-badge]][build-test-link]
[![Upload][upload-badge]][upload-link]
[![FreeBSD][freebsd-badge]][freebsd-link]
[![A/UBSan][sanitizers-badge]][sanitizers-link]
[![Valgrind][valgrind-badge]][valgrind-link]
[![Reload][reload-badge]][reload-link]
[![CodeQL][codeql-badge]][codeql-link]
[![Lint][lint-badge]][lint-link]

[build-test-badge]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/build-test.yml/badge.svg
[build-test-link]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/build-test.yml
[upload-badge]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/upload.yml/badge.svg
[upload-link]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/upload.yml
[freebsd-badge]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/freebsd.yml/badge.svg
[freebsd-link]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/freebsd.yml
[sanitizers-badge]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/sanitizers.yml/badge.svg
[sanitizers-link]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/sanitizers.yml
[valgrind-badge]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/valgrind.yml/badge.svg
[valgrind-link]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/valgrind.yml
[reload-badge]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/reload.yml/badge.svg
[reload-link]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/reload.yml
[codeql-badge]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/codeql.yml/badge.svg
[codeql-link]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/codeql.yml
[lint-badge]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/lint.yml/badge.svg
[lint-link]: https://github.com/sysadmin-labs/nginx-upload-module/actions/workflows/lint.yml

Parses `multipart/form-data` uploads, writes each file to disk and hands the
request on to a backend with the file contents replaced by their location,
so the backend never sees the bytes.  Supports resumable uploads over the
`X-Content-Range` protocol.

## Synopsis

```nginx
server {
    location = /upload/ {
        # pass the altered request here once the files are on disk
        upload_pass @backend;

        # where the files land, with one level of hashed subdirectories
        upload_store /var/spool/nginx/upload 1;
        upload_store_access user:rw group:rw all:r;

        # form fields the backend receives for each file
        upload_set_form_field       $upload_field_name.name "$upload_file_name";
        upload_set_form_field       $upload_field_name.path "$upload_tmp_path";
        upload_aggregate_form_field $upload_field_name.size "$upload_file_size";

        # drop a stored file again if the backend answers with one of these
        upload_cleanup 400 404 499 500-505;
    }

    location @backend {
        proxy_pass http://127.0.0.1:8080;
    }
}
```

## Directives

- `upload_pass <location>` — where the rewritten request is sent after the
  files are stored.
- `upload_store <dir> [level ...]` — directory the files are written to; the
  hashing levels work like `proxy_cache_path`, and the directories must
  exist.
- `upload_store_access <spec>` — permissions of the stored files.
- `upload_set_form_field <name> <value>` — a form field added to the request
  for each file; `$upload_file_name`, `$upload_field_name`,
  `$upload_content_type` and `$upload_tmp_path` are available.
- `upload_aggregate_form_field <name> <value>` — like the above, but
  evaluated after the file is written, so `$upload_file_size`,
  `$upload_file_md5`, `$upload_file_sha1`, `$upload_file_sha256`,
  `$upload_file_sha512` and `$upload_file_crc32` are available.
- `upload_resumable on` — accept interrupted uploads continued over the
  `X-Content-Range` / `Session-ID` protocol.
- `upload_state_store <dir>` — where the state of resumable uploads is kept.
- `upload_cleanup <code> ...` — remove a stored file if the backend answers
  with one of these status codes.
- `upload_max_file_size <size>`, `upload_limit_rate <rate>`,
  `upload_buffer_size <size>`, `upload_pass_args on|off`,
  `upload_pass_form_field <regex>`, `upload_add_header <name> <value>`.

A non-POST request to an upload location is answered with `405`.

## Building

```sh
./configure --add-module=/path/to/nginx-upload-module
```

or as a loadable module

```sh
./configure --add-dynamic-module=/path/to/nginx-upload-module
```

with `load_module modules/ngx_http_upload_module.so;` in the main context.

## Testing

```sh
ci/build.sh 1.30.5 /tmp/nginx-test
TEST_NGINX_BINARY=/tmp/nginx-test/sbin/nginx prove -r t/
ci/upload.sh /tmp/nginx-test/sbin/nginx
ci/reload.sh /tmp/nginx-test/sbin/nginx
```

The test suite needs the Perl modules `Test::Nginx`, `Test::File` and
`HTTP::Daemon`.

## License

BSD 3-Clause, see [LICENSE](LICENSE).

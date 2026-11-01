use strict;
use warnings;

use File::Basename qw(dirname);
use lib dirname(__FILE__) . "/lib";
use Cwd qw(abs_path);

use Test::Nginx::Socket tests => 12;
use Test::Nginx::UploadModule;

$ENV{TEST_DIR} = abs_path(dirname(__FILE__));


our $config = <<'_EOC_';
location = /upload/ {
    upload_pass @upstream;
    upload_resumable on;

    upload_set_form_field upload_file_name $upload_file_name;
    upload_set_form_field upload_file_number $upload_file_number;
    upload_set_form_field "upload_field_name" "$upload_field_name";
    upload_set_form_field "upload_content_type" "$upload_content_type";
    upload_set_form_field "upload_tmp_path" "$upload_tmp_path";
    upload_set_form_field "upload_content_range" "$upload_content_range";
    upload_aggregate_form_field "upload_file_size" "$upload_file_size";
    upload_max_file_size 0;
    upload_pass_args on;
    upload_cleanup 400 404 499 500-505;
}
_EOC_

no_long_string();
no_shuffle();
run_tests();

__DATA__
=== TEST 1: http2 simple upload
--- config eval: $::config
--- http2
--- skip_nginx
2: < 1.10.0
--- more_headers
X-Content-Range: bytes 0-3/4
Session-ID: 0000000001
Content-Type: text/plain
Content-Disposition: form-data; name="file"; filename="test.txt"
--- request eval
qq{POST /upload/
test}
--- error_code: 200
--- response_body eval
qq{upload_content_range = bytes 0-3/4
upload_content_type = text/plain
upload_field_name = file
upload_file_name = test.txt
upload_file_number = 1
upload_file_size = 4
upload_tmp_path = $ENV{TEST_NGINX_UPLOAD_PATH}/store/1/0000000001
}
--- upload_file eval
"test"

=== TEST 2: http2 multiple chunk uploads
--- http_config eval: $::http_config
--- config eval: $::config
--- http2
--- skip_nginx
4: < 1.10.0
--- more_headers eval
[qq{X-Content-Range: bytes 0-1/4
Session-ID: 0000000002
Content-Type: text/plain
Content-Disposition: form-data; name="file"; filename="test.txt"},
qq{X-Content-Range: bytes 2-3/4
Session-ID: 0000000002
Content-Type: text/plain
Content-Disposition: form-data; name="file"; filename="test.txt"}]
--- request eval
[["POST /upload/\r\n",
"te"],
["POST /upload/\r\n",
"st"]]
--- error_code eval
[201, 200]
--- response_body eval
["0-1/4", qq{upload_content_range = bytes 2-3/4
upload_content_type = text/plain
upload_field_name = file
upload_file_name = test.txt
upload_file_number = 1
upload_file_size = 4
upload_tmp_path = $ENV{TEST_NGINX_UPLOAD_PATH}/store/2/0000000002
}]
--- upload_file eval
"test"

# Large multi-chunk resumable uploads over HTTP/2 are not exercised here:
# the Test::Nginx HTTP/2 client does not send WINDOW_UPDATE, so a request
# body past the initial HTTP/2 flow-control window (~64 KB) is truncated and
# the module then correctly rejects the incomplete range with 416.  The same
# large resumable uploads run over HTTP/1.1 in t/aggregate_fields.t, and were
# verified working over HTTP/2 with curl (262144-byte file reassembled, 200).

=== TEST 5: upload_add_header
--- skip_nginx
6: < 1.10.0
--- http2
--- config
location /upload/ {
    upload_pass @upstream;
    upload_resumable on;
    upload_add_header X-Upload-Filename $upload_file_name;
    upload_add_header Access-Control-Allow-Origin *;
    upload_set_form_field upload_file_name $upload_file_name;
}
--- more_headers eval
[qq{X-Content-Range: bytes 0-1/4
Session-ID: 0000000002
Content-Type: text/plain
Content-Disposition: form-data; name="file"; filename="test.txt"},
qq{X-Content-Range: bytes 2-3/4
Session-ID: 0000000002
Content-Type: text/plain
Content-Disposition: form-data; name="file"; filename="test.txt"}]
--- request eval
[["POST /upload/\r\n",
"te"],
["POST /upload/\r\n",
"st"]]
--- error_code eval
[201, 200]
--- raw_response_headers_like eval
[
qq{(?i)X-Upload-Filename: test\.txt.*?Access-Control-Allow-Origin: \*},
qq{(?i)X-Upload-Filename: test\.txt.*?Access-Control-Allow-Origin: \*}
]
--- response_body eval
["0-1/4", qq{upload_file_name = test.txt
}]

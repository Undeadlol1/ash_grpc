# Running in production

The endpoint speaks plain HTTP/2 (h2c) and has no TLS options. Run it behind a
proxy that terminates TLS, on a port the proxy reaches and nothing else does.

    children = [{MyAppWeb.GrpcEndpoint, port: 50051}]

Do not publish that port on the host. Browsers and native gRPC clients both
arrive over the proxy's HTTPS port.

## Routing with nginx

One hostname can serve your web app and gRPC. Route on `Content-Type`, not on
the path, since gRPC paths are `/package.Service/Method`. A browser's CORS
preflight has no `Content-Type`, only the headers it announces, so
`x-grpc-web` stands in for it.

    upstream grpc_upstream {
        server app:50051;
        keepalive 32;
    }

    upstream grpc_web_upstream {
        server app:50051;
        keepalive 32;
    }

    map "$request_method $content_type $http_access_control_request_headers" $api_protocol {
        default "";
        "~*^\S+ application/grpc-web" "grpc_web";
        "~*^\S+ application/grpc" "grpc";
        "~*^OPTIONS  .*x-grpc-web" "grpc_web";
    }

    server {
        listen 443 ssl;
        http2 on;

        error_page 418 = @grpc;
        error_page 419 = @grpc_web;

        location / {
            if ($api_protocol = grpc) { return 418; }
            if ($api_protocol = grpc_web) { return 419; }
            proxy_pass http://web_app;
        }

        location @grpc {
            client_max_body_size 0;
            grpc_pass grpc://grpc_upstream;
            grpc_send_timeout 1h;
            grpc_read_timeout 1h;
        }

        location @grpc_web {
            client_max_body_size 0;
            proxy_pass http://grpc_web_upstream;
            proxy_http_version 1.1;
            proxy_buffering off;
            proxy_set_header Connection "";
            proxy_send_timeout 1h;
            proxy_read_timeout 1h;
        }
    }

  * `return` plus `error_page ... = @name` is the safe way to pick a location by
    variable: the original URI reaches the named location untouched.
  * Keep two upstream blocks. An upstream's keepalive pool is shared by every
    request through it, and a pooled HTTP/1.1 connection handed to `grpc_pass`
    fails with `no connection data found for keepalive http2`.
  * The gRPC-Web location uses HTTP/1.1: the server answers gRPC-Web itself,
    so no translation is needed.
  * Client-streaming and two-way calls pass through `grpc_pass` message by
    message; no extra setting is needed.

## Long-lived streams

A subscription or server stream stays open as long as the client listens. The
default 60 second proxy timeouts cut it. Raise the read and send timeouts on
both locations to the longest stream you accept (`1h` above), and have clients
reconnect when a stream ends.

## A CDN in front

A CDN or an HTTP reverse proxy in front of nginx must pass gRPC through. On
Cloudflare that is a zone setting (Network, gRPC) and it needs HTTP/2 to the
origin. Without it, native gRPC calls fail before they reach your proxy, while
gRPC-Web, which is ordinary HTTP, keeps working.

## Health checks

Turn the health service on (`health: true`, see [Health checks](health.md)) so
a probe can ask the listener itself. From a container with `curl` and HTTP/2:

    curl -fsS --http2-prior-knowledge -X POST \
      -H 'content-type: application/grpc' --data-binary '' \
      http://localhost:50051/grpc.health.v1.Health/Check

`-f` fails on the HTTP status only: a `404` means the health service is off or
the listener is not this endpoint; a gRPC-level error still answers `200`.

## Zero-downtime releases

If the proxy points at one of two app containers during a release, flip the
gRPC upstream together with the HTTP one, and read both back before reloading.
Streams open on the old container end when it stops, so clients reconnect.

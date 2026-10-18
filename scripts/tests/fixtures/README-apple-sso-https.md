# Apple SSO HTTPS fixture

Start a fresh fixture for each test run from the repository root:

```sh
python3 scripts/tests/fixtures/apple_sso_https_fixture.py \
  --mode redirect \
  --ready-file .local/apple-sso-https/ready.json \
  --report-file .local/apple-sso-https/report.json
```

The first stdout line and ready JSON contain `pid`, `proxy_port`, `report_url`,
`ca_certificate`, and `bootstrap_url`. Read the report port from `report_url`.
Both ports bind only `127.0.0.1`.
Certificates and private keys are generated in a `TemporaryDirectory` under the
system temporary directory, never in the source tree. Stop with SIGINT/SIGTERM
to delete them; the optional ready/report JSON files remain.

Create and boot a **new disposable Simulator**, then install `ca_certificate`
only into that Simulator:

```sh
xcrun simctl keychain "$fixture_simulator_udid" add-root-cert "$fixture_ca_certificate"
```

Never install the CA into macOS, a physical device, or an existing Simulator.
Delete the disposable Simulator after the test. The fixture itself never
installs certificates or changes device settings.

Pass both local port values to `xcodebuild` with its test-runner prefix:

```sh
TEST_RUNNER_SPYCLASH_TEST_TLS_PROXY_PORT="$fixture_proxy_port" \
TEST_RUNNER_SPYCLASH_TEST_TLS_REPORT_PORT="$fixture_report_port" \
xcodebuild test <project, scheme, disposable destination, and selected test arguments>
```

The XCTest process reads `SPYCLASH_TEST_TLS_PROXY_PORT` and
`SPYCLASH_TEST_TLS_REPORT_PORT` without the `TEST_RUNNER_` prefix. Configure the
test WKWebView to use the local HTTP CONNECT proxy. No ambient proxy, credential,
or network service is needed. CONNECT is accepted only for `spyclash.com:443`
and `app.base44.com:443`; requests are terminated locally and never forwarded.

The expected five request categories are `bootstrap`, `spyclash_sso_login`,
`base44_sso_login`, `broker_authorize`, and `base44_sso_callback`, all returning
HTTP 302. The last Location has a synthetic token on an unrecognized path.
The app must cancel that navigation before fetching it. Assert five requests
and `final_route_fetches == 0` from `http://127.0.0.1:<report_port>/report`.
Fetching the final route records `final_candidate` and returns HTTP 500.

`--mode script` makes the fifth response HTTP 200 HTML that redirects to the
same candidate. `--final-host app.base44.com` exercises the other trusted host.
The token and bootstrap labels remain `synthetic-https-candidate-186` and
`synthetic-https-186` for compatibility with the current tests; they are fixtures,
not credentials. Reports contain only fixed route/host/method categories,
statuses, ordered counters, and connection-event categories; no query values,
raw request URLs, headers, or cookies are recorded.

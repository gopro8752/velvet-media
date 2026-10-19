# Third-party software

This inventory covers the package versions resolved by `Cargo.lock`, including dependencies used only on other platforms. License expressions below come from the packages' published Cargo metadata. The project's source-available license does not replace any third-party license.

The dependency sources and their license/notice files are available from each linked crates.io version. Preserve applicable attribution, license texts, and notices when redistributing a compiled backend. Some crates embed C/assembly or data components with additional notices; inspect those packages' included notices, especially `ring`, `aws-lc-sys`, `libsqlite3-sys`, and `webpki-root-certs`.

## Container runtime

The Dockerfile separately installs Debian packages including FFmpeg, Chromaprint, certificate bundles, and their dependencies. Their copyright and license files remain under `/usr/share/doc` in the image. FFmpeg and some libraries have GPL/LGPL obligations; anyone distributing a complete container must provide the corresponding source and other materials required by those components' applicable licenses. The source-available Velvet license does not cover or restrict those components. Debian source package versions should match the actual built image; base image tags and package repositories can change between builds.

The optional `with-codex` target includes Node.js (MIT with third-party notices) and the official Codex CLI package (Apache-2.0 with third-party components). Their own package notices and upstream licenses apply. Authentication is created at runtime and is not a distributed component.

No fonts, photographs, posters, stream media, or external guide listings are bundled in the admin frontend. It uses system fonts and CSS/inline markup. Channel/feed identifiers in `src/epg_mappings.json` are adapter mappings, not a redistribution of the program guide. External metadata and media integrations have their own usage terms.

## Locked Rust dependencies

| Package | Version | Declared license expression |
| --- | --- | --- |
| [adler2](https://crates.io/crates/adler2/2.0.1) | 2.0.1 | 0BSD OR MIT OR Apache-2.0 |
| [ahash](https://crates.io/crates/ahash/0.8.12) | 0.8.12 | MIT OR Apache-2.0 |
| [aho-corasick](https://crates.io/crates/aho-corasick/1.1.5) | 1.1.5 | Unlicense OR MIT |
| [android_system_properties](https://crates.io/crates/android_system_properties/0.1.6) | 0.1.6 | MIT OR Apache-2.0 |
| [anyhow](https://crates.io/crates/anyhow/1.0.104) | 1.0.104 | MIT OR Apache-2.0 |
| [async-trait](https://crates.io/crates/async-trait/0.1.92) | 0.1.92 | MIT OR Apache-2.0 |
| [atomic-waker](https://crates.io/crates/atomic-waker/1.1.2) | 1.1.2 | Apache-2.0 OR MIT |
| [autocfg](https://crates.io/crates/autocfg/1.5.1) | 1.5.1 | Apache-2.0 OR MIT |
| [aws-lc-rs](https://crates.io/crates/aws-lc-rs/1.18.0) | 1.18.0 | ISC AND (Apache-2.0 OR ISC) |
| [aws-lc-sys](https://crates.io/crates/aws-lc-sys/0.44.0) | 0.44.0 | ISC AND (Apache-2.0 OR ISC) AND Apache-2.0 AND MIT AND BSD-3-Clause AND (Apache-2.0 OR ISC OR MIT) AND (Apache-2.0 OR ISC OR MIT-0) |
| [axum](https://crates.io/crates/axum/0.7.9) | 0.7.9 | MIT |
| [axum-core](https://crates.io/crates/axum-core/0.4.5) | 0.4.5 | MIT |
| [base64](https://crates.io/crates/base64/0.22.1) | 0.22.1 | MIT OR Apache-2.0 |
| [bitflags](https://crates.io/crates/bitflags/2.13.1) | 2.13.1 | MIT OR Apache-2.0 |
| [bumpalo](https://crates.io/crates/bumpalo/3.20.3) | 3.20.3 | MIT OR Apache-2.0 |
| [bytes](https://crates.io/crates/bytes/1.12.1) | 1.12.1 | MIT |
| [cc](https://crates.io/crates/cc/1.4.2) | 1.4.2 | MIT OR Apache-2.0 |
| [cfg-if](https://crates.io/crates/cfg-if/1.0.4) | 1.0.4 | MIT OR Apache-2.0 |
| [cfg_aliases](https://crates.io/crates/cfg_aliases/0.2.2) | 0.2.2 | MIT |
| [chacha20](https://crates.io/crates/chacha20/0.10.1) | 0.10.1 | MIT OR Apache-2.0 |
| [chrono](https://crates.io/crates/chrono/0.4.45) | 0.4.45 | MIT OR Apache-2.0 |
| [cmake](https://crates.io/crates/cmake/0.1.58) | 0.1.58 | MIT OR Apache-2.0 |
| [core-foundation-sys](https://crates.io/crates/core-foundation-sys/0.8.7) | 0.8.7 | MIT OR Apache-2.0 |
| [cpufeatures](https://crates.io/crates/cpufeatures/0.3.0) | 0.3.0 | MIT OR Apache-2.0 |
| [crc32fast](https://crates.io/crates/crc32fast/1.5.2) | 1.5.2 | MIT OR Apache-2.0 |
| [displaydoc](https://crates.io/crates/displaydoc/0.2.7) | 0.2.7 | MIT OR Apache-2.0 |
| [dunce](https://crates.io/crates/dunce/1.0.5) | 1.0.5 | CC0-1.0 OR MIT-0 OR Apache-2.0 |
| [equivalent](https://crates.io/crates/equivalent/1.0.2) | 1.0.2 | Apache-2.0 OR MIT |
| [errno](https://crates.io/crates/errno/0.3.14) | 0.3.14 | MIT OR Apache-2.0 |
| [fallible-iterator](https://crates.io/crates/fallible-iterator/0.3.0) | 0.3.0 | MIT/Apache-2.0 |
| [fallible-streaming-iterator](https://crates.io/crates/fallible-streaming-iterator/0.1.9) | 0.1.9 | MIT/Apache-2.0 |
| [find-msvc-tools](https://crates.io/crates/find-msvc-tools/0.1.10) | 0.1.10 | MIT OR Apache-2.0 |
| [flate2](https://crates.io/crates/flate2/1.1.10) | 1.1.10 | MIT OR Apache-2.0 |
| [form_urlencoded](https://crates.io/crates/form_urlencoded/1.2.2) | 1.2.2 | MIT OR Apache-2.0 |
| [fs_extra](https://crates.io/crates/fs_extra/1.3.0) | 1.3.0 | MIT |
| [futures](https://crates.io/crates/futures/0.3.33) | 0.3.33 | MIT OR Apache-2.0 |
| [futures-channel](https://crates.io/crates/futures-channel/0.3.33) | 0.3.33 | MIT OR Apache-2.0 |
| [futures-core](https://crates.io/crates/futures-core/0.3.33) | 0.3.33 | MIT OR Apache-2.0 |
| [futures-executor](https://crates.io/crates/futures-executor/0.3.33) | 0.3.33 | MIT OR Apache-2.0 |
| [futures-io](https://crates.io/crates/futures-io/0.3.33) | 0.3.33 | MIT OR Apache-2.0 |
| [futures-macro](https://crates.io/crates/futures-macro/0.3.33) | 0.3.33 | MIT OR Apache-2.0 |
| [futures-sink](https://crates.io/crates/futures-sink/0.3.33) | 0.3.33 | MIT OR Apache-2.0 |
| [futures-task](https://crates.io/crates/futures-task/0.3.33) | 0.3.33 | MIT OR Apache-2.0 |
| [futures-util](https://crates.io/crates/futures-util/0.3.33) | 0.3.33 | MIT OR Apache-2.0 |
| [getrandom](https://crates.io/crates/getrandom/0.2.17) | 0.2.17 | MIT OR Apache-2.0 |
| [getrandom](https://crates.io/crates/getrandom/0.4.3) | 0.4.3 | MIT OR Apache-2.0 |
| [hashbrown](https://crates.io/crates/hashbrown/0.14.5) | 0.14.5 | MIT OR Apache-2.0 |
| [hashbrown](https://crates.io/crates/hashbrown/0.17.1) | 0.17.1 | MIT OR Apache-2.0 |
| [hashlink](https://crates.io/crates/hashlink/0.9.1) | 0.9.1 | MIT OR Apache-2.0 |
| [http](https://crates.io/crates/http/1.5.0) | 1.5.0 | MIT OR Apache-2.0 |
| [http-body](https://crates.io/crates/http-body/1.1.0) | 1.1.0 | MIT |
| [http-body-util](https://crates.io/crates/http-body-util/0.1.4) | 0.1.4 | MIT |
| [httparse](https://crates.io/crates/httparse/1.10.1) | 1.10.1 | MIT OR Apache-2.0 |
| [httpdate](https://crates.io/crates/httpdate/1.0.3) | 1.0.3 | MIT OR Apache-2.0 |
| [hyper](https://crates.io/crates/hyper/1.11.0) | 1.11.0 | MIT |
| [hyper-rustls](https://crates.io/crates/hyper-rustls/0.27.9) | 0.27.9 | Apache-2.0 OR ISC OR MIT |
| [hyper-util](https://crates.io/crates/hyper-util/0.1.20) | 0.1.20 | MIT |
| [iana-time-zone](https://crates.io/crates/iana-time-zone/0.1.65) | 0.1.65 | MIT OR Apache-2.0 |
| [iana-time-zone-haiku](https://crates.io/crates/iana-time-zone-haiku/0.1.2) | 0.1.2 | MIT OR Apache-2.0 |
| [icu_collections](https://crates.io/crates/icu_collections/2.2.0) | 2.2.0 | Unicode-3.0 |
| [icu_locale_core](https://crates.io/crates/icu_locale_core/2.2.0) | 2.2.0 | Unicode-3.0 |
| [icu_normalizer](https://crates.io/crates/icu_normalizer/2.2.0) | 2.2.0 | Unicode-3.0 |
| [icu_normalizer_data](https://crates.io/crates/icu_normalizer_data/2.2.0) | 2.2.0 | Unicode-3.0 |
| [icu_properties](https://crates.io/crates/icu_properties/2.2.0) | 2.2.0 | Unicode-3.0 |
| [icu_properties_data](https://crates.io/crates/icu_properties_data/2.2.0) | 2.2.0 | Unicode-3.0 |
| [icu_provider](https://crates.io/crates/icu_provider/2.2.0) | 2.2.0 | Unicode-3.0 |
| [idna](https://crates.io/crates/idna/1.1.0) | 1.1.0 | MIT OR Apache-2.0 |
| [idna_adapter](https://crates.io/crates/idna_adapter/1.2.2) | 1.2.2 | Apache-2.0 OR MIT |
| [indexmap](https://crates.io/crates/indexmap/2.14.0) | 2.14.0 | Apache-2.0 OR MIT |
| [ipnet](https://crates.io/crates/ipnet/2.12.1) | 2.12.1 | MIT OR Apache-2.0 |
| [itoa](https://crates.io/crates/itoa/1.0.18) | 1.0.18 | MIT OR Apache-2.0 |
| [jobserver](https://crates.io/crates/jobserver/0.1.35) | 0.1.35 | MIT OR Apache-2.0 |
| [js-sys](https://crates.io/crates/js-sys/0.3.104) | 0.3.104 | MIT OR Apache-2.0 |
| [lazy_static](https://crates.io/crates/lazy_static/1.5.0) | 1.5.0 | MIT OR Apache-2.0 |
| [libc](https://crates.io/crates/libc/0.2.189) | 0.2.189 | MIT OR Apache-2.0 |
| [libsqlite3-sys](https://crates.io/crates/libsqlite3-sys/0.30.1) | 0.30.1 | MIT |
| [litemap](https://crates.io/crates/litemap/0.8.2) | 0.8.2 | Unicode-3.0 |
| [lock_api](https://crates.io/crates/lock_api/0.4.14) | 0.4.14 | MIT OR Apache-2.0 |
| [log](https://crates.io/crates/log/0.4.33) | 0.4.33 | MIT OR Apache-2.0 |
| [lru-slab](https://crates.io/crates/lru-slab/0.1.2) | 0.1.2 | MIT OR Apache-2.0 OR Zlib |
| [matchers](https://crates.io/crates/matchers/0.2.0) | 0.2.0 | MIT |
| [matchit](https://crates.io/crates/matchit/0.7.3) | 0.7.3 | MIT AND BSD-3-Clause |
| [memchr](https://crates.io/crates/memchr/2.8.3) | 2.8.3 | Unlicense OR MIT |
| [mime](https://crates.io/crates/mime/0.3.17) | 0.3.17 | MIT OR Apache-2.0 |
| [miniz_oxide](https://crates.io/crates/miniz_oxide/0.9.1) | 0.9.1 | MIT OR Zlib OR Apache-2.0 |
| [mio](https://crates.io/crates/mio/1.2.2) | 1.2.2 | MIT |
| [nu-ansi-term](https://crates.io/crates/nu-ansi-term/0.50.3) | 0.50.3 | MIT |
| [num-traits](https://crates.io/crates/num-traits/0.2.19) | 0.2.19 | MIT OR Apache-2.0 |
| [once_cell](https://crates.io/crates/once_cell/1.21.4) | 1.21.4 | MIT OR Apache-2.0 |
| [parking_lot](https://crates.io/crates/parking_lot/0.12.5) | 0.12.5 | MIT OR Apache-2.0 |
| [parking_lot_core](https://crates.io/crates/parking_lot_core/0.9.12) | 0.9.12 | MIT OR Apache-2.0 |
| [percent-encoding](https://crates.io/crates/percent-encoding/2.3.2) | 2.3.2 | MIT OR Apache-2.0 |
| [pin-project-lite](https://crates.io/crates/pin-project-lite/0.2.17) | 0.2.17 | Apache-2.0 OR MIT |
| [pkg-config](https://crates.io/crates/pkg-config/0.3.33) | 0.3.33 | MIT OR Apache-2.0 |
| [potential_utf](https://crates.io/crates/potential_utf/0.1.5) | 0.1.5 | Unicode-3.0 |
| [proc-macro2](https://crates.io/crates/proc-macro2/1.0.107) | 1.0.107 | MIT OR Apache-2.0 |
| [quick-xml](https://crates.io/crates/quick-xml/0.36.2) | 0.36.2 | MIT |
| [quinn](https://crates.io/crates/quinn/0.11.11) | 0.11.11 | MIT OR Apache-2.0 |
| [quinn-proto](https://crates.io/crates/quinn-proto/0.11.16) | 0.11.16 | MIT OR Apache-2.0 |
| [quinn-udp](https://crates.io/crates/quinn-udp/0.5.15) | 0.5.15 | MIT OR Apache-2.0 |
| [quote](https://crates.io/crates/quote/1.0.47) | 1.0.47 | MIT OR Apache-2.0 |
| [r-efi](https://crates.io/crates/r-efi/6.0.0) | 6.0.0 | MIT OR Apache-2.0 OR LGPL-2.1-or-later |
| [rand](https://crates.io/crates/rand/0.10.2) | 0.10.2 | MIT OR Apache-2.0 |
| [rand_core](https://crates.io/crates/rand_core/0.10.1) | 0.10.1 | MIT OR Apache-2.0 |
| [rand_pcg](https://crates.io/crates/rand_pcg/0.10.2) | 0.10.2 | MIT OR Apache-2.0 |
| [redox_syscall](https://crates.io/crates/redox_syscall/0.5.18) | 0.5.18 | MIT |
| [regex-automata](https://crates.io/crates/regex-automata/0.4.18) | 0.4.18 | MIT OR Apache-2.0 |
| [regex-syntax](https://crates.io/crates/regex-syntax/0.8.11) | 0.8.11 | MIT OR Apache-2.0 |
| [reqwest](https://crates.io/crates/reqwest/0.12.28) | 0.12.28 | MIT OR Apache-2.0 |
| [ring](https://crates.io/crates/ring/0.17.14) | 0.17.14 | Apache-2.0 AND ISC |
| [rusqlite](https://crates.io/crates/rusqlite/0.32.1) | 0.32.1 | MIT |
| [rustc-hash](https://crates.io/crates/rustc-hash/2.1.3) | 2.1.3 | Apache-2.0 OR MIT |
| [rustls](https://crates.io/crates/rustls/0.23.43) | 0.23.43 | Apache-2.0 OR ISC OR MIT |
| [rustls-pki-types](https://crates.io/crates/rustls-pki-types/1.15.1) | 1.15.1 | MIT OR Apache-2.0 |
| [rustls-webpki](https://crates.io/crates/rustls-webpki/0.103.13) | 0.103.13 | ISC |
| [rustversion](https://crates.io/crates/rustversion/1.0.23) | 1.0.23 | MIT OR Apache-2.0 |
| [ryu](https://crates.io/crates/ryu/1.0.23) | 1.0.23 | Apache-2.0 OR BSL-1.0 |
| [scopeguard](https://crates.io/crates/scopeguard/1.2.0) | 1.2.0 | MIT OR Apache-2.0 |
| [serde](https://crates.io/crates/serde/1.0.229) | 1.0.229 | MIT OR Apache-2.0 |
| [serde_core](https://crates.io/crates/serde_core/1.0.229) | 1.0.229 | MIT OR Apache-2.0 |
| [serde_derive](https://crates.io/crates/serde_derive/1.0.229) | 1.0.229 | MIT OR Apache-2.0 |
| [serde_json](https://crates.io/crates/serde_json/1.0.151) | 1.0.151 | MIT OR Apache-2.0 |
| [serde_path_to_error](https://crates.io/crates/serde_path_to_error/0.1.20) | 0.1.20 | MIT OR Apache-2.0 |
| [serde_spanned](https://crates.io/crates/serde_spanned/0.6.9) | 0.6.9 | MIT OR Apache-2.0 |
| [serde_urlencoded](https://crates.io/crates/serde_urlencoded/0.7.1) | 0.7.1 | MIT/Apache-2.0 |
| [sharded-slab](https://crates.io/crates/sharded-slab/0.1.7) | 0.1.7 | MIT |
| [shlex](https://crates.io/crates/shlex/2.0.1) | 2.0.1 | MIT OR Apache-2.0 |
| [signal-hook-registry](https://crates.io/crates/signal-hook-registry/1.4.8) | 1.4.8 | MIT OR Apache-2.0 |
| [simd-adler32](https://crates.io/crates/simd-adler32/0.3.10) | 0.3.10 | MIT |
| [slab](https://crates.io/crates/slab/0.4.12) | 0.4.12 | MIT |
| [smallvec](https://crates.io/crates/smallvec/1.15.2) | 1.15.2 | MIT OR Apache-2.0 |
| [socket2](https://crates.io/crates/socket2/0.6.5) | 0.6.5 | MIT OR Apache-2.0 |
| [stable_deref_trait](https://crates.io/crates/stable_deref_trait/1.2.1) | 1.2.1 | MIT OR Apache-2.0 |
| [subtle](https://crates.io/crates/subtle/2.6.1) | 2.6.1 | BSD-3-Clause |
| [syn](https://crates.io/crates/syn/2.0.119) | 2.0.119 | MIT OR Apache-2.0 |
| [syn](https://crates.io/crates/syn/3.0.3) | 3.0.3 | MIT OR Apache-2.0 |
| [sync_wrapper](https://crates.io/crates/sync_wrapper/1.0.2) | 1.0.2 | Apache-2.0 |
| [synstructure](https://crates.io/crates/synstructure/0.13.2) | 0.13.2 | MIT |
| [thiserror](https://crates.io/crates/thiserror/1.0.69) | 1.0.69 | MIT OR Apache-2.0 |
| [thiserror](https://crates.io/crates/thiserror/2.0.20) | 2.0.20 | MIT OR Apache-2.0 |
| [thiserror-impl](https://crates.io/crates/thiserror-impl/1.0.69) | 1.0.69 | MIT OR Apache-2.0 |
| [thiserror-impl](https://crates.io/crates/thiserror-impl/2.0.20) | 2.0.20 | MIT OR Apache-2.0 |
| [thread_local](https://crates.io/crates/thread_local/1.1.10) | 1.1.10 | MIT OR Apache-2.0 |
| [tinystr](https://crates.io/crates/tinystr/0.8.3) | 0.8.3 | Unicode-3.0 |
| [tinyvec](https://crates.io/crates/tinyvec/1.12.0) | 1.12.0 | Zlib OR Apache-2.0 OR MIT |
| [tinyvec_macros](https://crates.io/crates/tinyvec_macros/0.1.1) | 0.1.1 | MIT OR Apache-2.0 OR Zlib |
| [tokio](https://crates.io/crates/tokio/1.53.1) | 1.53.1 | MIT |
| [tokio-macros](https://crates.io/crates/tokio-macros/2.7.2) | 2.7.2 | MIT |
| [tokio-rustls](https://crates.io/crates/tokio-rustls/0.26.4) | 0.26.4 | MIT OR Apache-2.0 |
| [tokio-util](https://crates.io/crates/tokio-util/0.7.20) | 0.7.20 | MIT |
| [toml](https://crates.io/crates/toml/0.8.23) | 0.8.23 | MIT OR Apache-2.0 |
| [toml_datetime](https://crates.io/crates/toml_datetime/0.6.11) | 0.6.11 | MIT OR Apache-2.0 |
| [toml_edit](https://crates.io/crates/toml_edit/0.22.27) | 0.22.27 | MIT OR Apache-2.0 |
| [toml_write](https://crates.io/crates/toml_write/0.1.2) | 0.1.2 | MIT OR Apache-2.0 |
| [tower](https://crates.io/crates/tower/0.5.3) | 0.5.3 | MIT |
| [tower-http](https://crates.io/crates/tower-http/0.6.11) | 0.6.11 | MIT |
| [tower-layer](https://crates.io/crates/tower-layer/0.3.3) | 0.3.3 | MIT |
| [tower-service](https://crates.io/crates/tower-service/0.3.3) | 0.3.3 | MIT |
| [tracing](https://crates.io/crates/tracing/0.1.44) | 0.1.44 | MIT |
| [tracing-attributes](https://crates.io/crates/tracing-attributes/0.1.31) | 0.1.31 | MIT |
| [tracing-core](https://crates.io/crates/tracing-core/0.1.36) | 0.1.36 | MIT |
| [tracing-log](https://crates.io/crates/tracing-log/0.2.0) | 0.2.0 | MIT |
| [tracing-subscriber](https://crates.io/crates/tracing-subscriber/0.3.23) | 0.3.23 | MIT |
| [try-lock](https://crates.io/crates/try-lock/0.2.5) | 0.2.5 | MIT |
| [unicode-ident](https://crates.io/crates/unicode-ident/1.0.24) | 1.0.24 | (MIT OR Apache-2.0) AND Unicode-3.0 |
| [untrusted](https://crates.io/crates/untrusted/0.9.0) | 0.9.0 | ISC |
| [url](https://crates.io/crates/url/2.5.8) | 2.5.8 | MIT OR Apache-2.0 |
| [utf8_iter](https://crates.io/crates/utf8_iter/1.0.4) | 1.0.4 | Apache-2.0 OR MIT |
| [valuable](https://crates.io/crates/valuable/0.1.1) | 0.1.1 | MIT |
| [vcpkg](https://crates.io/crates/vcpkg/0.2.15) | 0.2.15 | MIT/Apache-2.0 |
| [version_check](https://crates.io/crates/version_check/0.9.5) | 0.9.5 | MIT/Apache-2.0 |
| [want](https://crates.io/crates/want/0.3.1) | 0.3.1 | MIT |
| [wasi](https://crates.io/crates/wasi/0.11.1+wasi-snapshot-preview1) | 0.11.1+wasi-snapshot-preview1 | Apache-2.0 WITH LLVM-exception OR Apache-2.0 OR MIT |
| [wasm-bindgen](https://crates.io/crates/wasm-bindgen/0.2.127) | 0.2.127 | MIT OR Apache-2.0 |
| [wasm-bindgen-futures](https://crates.io/crates/wasm-bindgen-futures/0.4.77) | 0.4.77 | MIT OR Apache-2.0 |
| [wasm-bindgen-macro](https://crates.io/crates/wasm-bindgen-macro/0.2.127) | 0.2.127 | MIT OR Apache-2.0 |
| [wasm-bindgen-macro-support](https://crates.io/crates/wasm-bindgen-macro-support/0.2.127) | 0.2.127 | MIT OR Apache-2.0 |
| [wasm-bindgen-shared](https://crates.io/crates/wasm-bindgen-shared/0.2.127) | 0.2.127 | MIT OR Apache-2.0 |
| [wasm-streams](https://crates.io/crates/wasm-streams/0.4.2) | 0.4.2 | MIT OR Apache-2.0 |
| [web-sys](https://crates.io/crates/web-sys/0.3.104) | 0.3.104 | MIT OR Apache-2.0 |
| [web-time](https://crates.io/crates/web-time/1.1.0) | 1.1.0 | MIT OR Apache-2.0 |
| [webpki-roots](https://crates.io/crates/webpki-roots/0.26.11) | 0.26.11 | CDLA-Permissive-2.0 |
| [webpki-roots](https://crates.io/crates/webpki-roots/1.0.9) | 1.0.9 | CDLA-Permissive-2.0 |
| [windows-core](https://crates.io/crates/windows-core/0.62.2) | 0.62.2 | MIT OR Apache-2.0 |
| [windows-implement](https://crates.io/crates/windows-implement/0.60.2) | 0.60.2 | MIT OR Apache-2.0 |
| [windows-interface](https://crates.io/crates/windows-interface/0.59.3) | 0.59.3 | MIT OR Apache-2.0 |
| [windows-link](https://crates.io/crates/windows-link/0.2.1) | 0.2.1 | MIT OR Apache-2.0 |
| [windows-result](https://crates.io/crates/windows-result/0.4.1) | 0.4.1 | MIT OR Apache-2.0 |
| [windows-strings](https://crates.io/crates/windows-strings/0.5.1) | 0.5.1 | MIT OR Apache-2.0 |
| [windows-sys](https://crates.io/crates/windows-sys/0.52.0) | 0.52.0 | MIT OR Apache-2.0 |
| [windows-sys](https://crates.io/crates/windows-sys/0.61.2) | 0.61.2 | MIT OR Apache-2.0 |
| [windows-targets](https://crates.io/crates/windows-targets/0.52.6) | 0.52.6 | MIT OR Apache-2.0 |
| [windows_aarch64_gnullvm](https://crates.io/crates/windows_aarch64_gnullvm/0.52.6) | 0.52.6 | MIT OR Apache-2.0 |
| [windows_aarch64_msvc](https://crates.io/crates/windows_aarch64_msvc/0.52.6) | 0.52.6 | MIT OR Apache-2.0 |
| [windows_i686_gnu](https://crates.io/crates/windows_i686_gnu/0.52.6) | 0.52.6 | MIT OR Apache-2.0 |
| [windows_i686_gnullvm](https://crates.io/crates/windows_i686_gnullvm/0.52.6) | 0.52.6 | MIT OR Apache-2.0 |
| [windows_i686_msvc](https://crates.io/crates/windows_i686_msvc/0.52.6) | 0.52.6 | MIT OR Apache-2.0 |
| [windows_x86_64_gnu](https://crates.io/crates/windows_x86_64_gnu/0.52.6) | 0.52.6 | MIT OR Apache-2.0 |
| [windows_x86_64_gnullvm](https://crates.io/crates/windows_x86_64_gnullvm/0.52.6) | 0.52.6 | MIT OR Apache-2.0 |
| [windows_x86_64_msvc](https://crates.io/crates/windows_x86_64_msvc/0.52.6) | 0.52.6 | MIT OR Apache-2.0 |
| [winnow](https://crates.io/crates/winnow/0.7.15) | 0.7.15 | MIT |
| [writeable](https://crates.io/crates/writeable/0.6.3) | 0.6.3 | Unicode-3.0 |
| [yoke](https://crates.io/crates/yoke/0.8.3) | 0.8.3 | Unicode-3.0 |
| [yoke-derive](https://crates.io/crates/yoke-derive/0.8.2) | 0.8.2 | Unicode-3.0 |
| [zerocopy](https://crates.io/crates/zerocopy/0.8.56) | 0.8.56 | BSD-2-Clause OR Apache-2.0 OR MIT |
| [zerocopy-derive](https://crates.io/crates/zerocopy-derive/0.8.56) | 0.8.56 | BSD-2-Clause OR Apache-2.0 OR MIT |
| [zerofrom](https://crates.io/crates/zerofrom/0.1.8) | 0.1.8 | Unicode-3.0 |
| [zerofrom-derive](https://crates.io/crates/zerofrom-derive/0.1.7) | 0.1.7 | Unicode-3.0 |
| [zeroize](https://crates.io/crates/zeroize/1.9.0) | 1.9.0 | Apache-2.0 OR MIT |
| [zerotrie](https://crates.io/crates/zerotrie/0.2.4) | 0.2.4 | Unicode-3.0 |
| [zerovec](https://crates.io/crates/zerovec/0.11.6) | 0.11.6 | Unicode-3.0 |
| [zerovec-derive](https://crates.io/crates/zerovec-derive/0.11.3) | 0.11.3 | Unicode-3.0 |
| [zlib-rs](https://crates.io/crates/zlib-rs/0.6.8) | 0.6.8 | Zlib |
| [zmij](https://crates.io/crates/zmij/1.0.23) | 1.0.23 | MIT |

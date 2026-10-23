//! NNTP client — the raw protocol to a usenet provider. One connection can
//! authenticate, select a group, and fetch an article body; the pool (built on
//! top) keeps N of these warm for parallel segment fetches.
//!
//! Streaming-first contract: `body()` has a hard deadline and returns a typed
//! result — a missing article (430) is `Ok(None)`, NOT an error that stalls a
//! queue. The caller decides what to do (try the next provider, or stream past
//! the gap). Nothing here ever blocks waiting to "acquire" a file.

use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::time::timeout;
use tokio_rustls::client::TlsStream;
use tokio_rustls::TlsConnector;

use crate::config::Provider;

/// Hard wire-memory limits. A successful BODY must not grow memory without
/// bound while withholding a newline or terminator.
pub(crate) const MAX_ARTICLE_BYTES: usize = 4 * 1024 * 1024;
const MAX_ARTICLE_LINE: usize = 64 * 1024;

#[derive(Debug, thiserror::Error)]
pub enum NntpError {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("tls: {0}")]
    Tls(String),
    #[error("timed out")]
    Timeout,
    #[error("auth rejected ({0})")]
    AuthRejected(u16),
    #[error("unexpected greeting: {0}")]
    BadGreeting(String),
    #[error("protocol: {0}")]
    Protocol(String),
}

/// Either a plaintext or TLS-wrapped stream, both buffered.
enum Transport {
    Plain(BufReader<TcpStream>),
    Tls(BufReader<TlsStream<TcpStream>>),
}

macro_rules! on_transport {
    ($self:expr, $conn:ident => $body:expr) => {
        match &mut $self.transport {
            Transport::Plain($conn) => $body,
            Transport::Tls($conn) => $body,
        }
    };
}

pub struct NntpConn {
    transport: Transport,
    /// Group currently selected, to skip redundant GROUP commands.
    current_group: Option<String>,
    io_timeout: Duration,
    body_wire_bytes: usize,
}

/// Result of asking for one article body.
pub enum ArticleBody {
    /// Raw body bytes (dot-unstuffed, terminator removed) — feed to `yenc::decode`.
    Found(Vec<u8>),
    /// 430 no such article / 423 no such number — this segment isn't on this provider.
    Missing,
}

impl NntpConn {
    pub async fn connect(p: &Provider) -> Result<NntpConn, NntpError> {
        let io_timeout = Duration::from_secs(15);
        let addr = format!("{}:{}", p.host, p.port);
        let tcp = timeout(Duration::from_secs(12), TcpStream::connect(&addr))
            .await
            .map_err(|_| NntpError::Timeout)??;
        tcp.set_nodelay(true).ok();

        let transport = if p.tls {
            let connector = TlsConnector::from(Arc::new(tls_config()));
            let server_name = rustls::pki_types::ServerName::try_from(p.host.clone())
                .map_err(|e| NntpError::Tls(e.to_string()))?;
            let tls = connector
                .connect(server_name, tcp)
                .await
                .map_err(|e| NntpError::Tls(e.to_string()))?;
            Transport::Tls(BufReader::new(tls))
        } else {
            Transport::Plain(BufReader::new(tcp))
        };

        let mut conn = NntpConn { transport, current_group: None, io_timeout, body_wire_bytes: 0 };

        // Greeting: 200 (posting allowed) or 201 (no posting) both fine.
        let (code, text) = conn.read_status().await?;
        if code != 200 && code != 201 {
            return Err(NntpError::BadGreeting(format!("{code} {text}")));
        }
        conn.authenticate(&p.username, &p.password).await?;
        Ok(conn)
    }

    async fn authenticate(&mut self, user: &str, pass: &str) -> Result<(), NntpError> {
        self.write_line(&format!("AUTHINFO USER {user}")).await?;
        let (code, _) = self.read_status().await?;
        // 381: more auth required (send pass). 281: accepted with no pass.
        if code == 281 {
            return Ok(());
        }
        if code != 381 {
            return Err(NntpError::AuthRejected(code));
        }
        self.write_line(&format!("AUTHINFO PASS {pass}")).await?;
        let (code, _) = self.read_status().await?;
        if code != 281 {
            return Err(NntpError::AuthRejected(code));
        }
        Ok(())
    }

    /// Select a group (required by some providers before BODY-by-message-id).
    pub async fn group(&mut self, group: &str) -> Result<(), NntpError> {
        if self.current_group.as_deref() == Some(group) {
            return Ok(());
        }
        self.write_line(&format!("GROUP {group}")).await?;
        let (code, text) = self.read_status().await?;
        if code != 211 {
            return Err(NntpError::Protocol(format!("GROUP {group}: {code} {text}")));
        }
        self.current_group = Some(group.to_string());
        Ok(())
    }

    /// Fetch an article body by message-id (angle brackets added automatically).
    /// 430/423 → `Missing` (never an error — that's the whole point of the rewrite).
    pub async fn body(&mut self, message_id: &str) -> Result<ArticleBody, NntpError> {
        self.body_with_limit(message_id, MAX_ARTICLE_BYTES).await
    }

    pub fn body_wire_bytes(&self) -> usize { self.body_wire_bytes }

    pub async fn body_with_limit(&mut self, message_id: &str, max_bytes: usize) -> Result<ArticleBody, NntpError> {
        self.body_wire_bytes = 0;
        self.write_line(&format!("BODY <{message_id}>")).await?;
        let (code, text) = self.read_status().await?;
        match code {
            222 => {
                let raw = self.read_multiline(max_bytes.min(MAX_ARTICLE_BYTES)).await?;
                Ok(ArticleBody::Found(raw))
            }
            430 | 423 => Ok(ArticleBody::Missing),
            _ => Err(NntpError::Protocol(format!("BODY <{message_id}>: {code} {text}"))),
        }
    }

    /// Check whether an article EXISTS without downloading its body (NNTP STAT).
    /// This is how we verify a file is complete cheaply — a round-trip per
    /// segment, no data transfer.
    pub async fn stat(&mut self, message_id: &str) -> Result<bool, NntpError> {
        self.write_line(&format!("STAT <{message_id}>")).await?;
        let (code, text) = self.read_status().await?;
        match code {
            223 => Ok(true),
            430 | 423 => Ok(false),
            _ => Err(NntpError::Protocol(format!("STAT <{message_id}>: {code} {text}"))),
        }
    }

    pub async fn quit(&mut self) {
        let _ = self.write_line("QUIT").await;
    }

    // ── framing ─────────────────────────────────────────────────────────────

    async fn write_line(&mut self, line: &str) -> Result<(), NntpError> {
        let buf = format!("{line}\r\n");
        let fut = async {
            on_transport!(self, c => {
                c.get_mut().write_all(buf.as_bytes()).await?;
                c.get_mut().flush().await
            })
        };
        timeout(self.io_timeout, fut).await.map_err(|_| NntpError::Timeout)??;
        Ok(())
    }

    /// Read one status line; return (3-digit code, rest of line).
    async fn read_status(&mut self) -> Result<(u16, String), NntpError> {
        let mut line = String::new();
        let n = timeout(self.io_timeout, async {
            on_transport!(self, c => (&mut *c).take(MAX_ARTICLE_LINE as u64).read_line(&mut line).await)
        })
        .await
        .map_err(|_| NntpError::Timeout)??;
        if n == 0 {
            return Err(NntpError::Protocol("connection closed".into()));
        }
        if line.len() >= MAX_ARTICLE_LINE && !line.ends_with('\n') { return Err(NntpError::Protocol("status line exceeds limit".into())); }
        let trimmed = line.trim_end();
        let code: u16 = trimmed
            .get(..3)
            .and_then(|c| c.parse().ok())
            .ok_or_else(|| NntpError::Protocol(format!("bad status line: {trimmed}")))?;
        Ok((code, trimmed.get(4..).unwrap_or("").to_string()))
    }

    /// Read a dot-terminated multiline block; unstuff leading '..' → '.', drop
    /// the final "." line. Returns the raw body bytes for the yEnc decoder.
    async fn read_multiline(&mut self, max_bytes: usize) -> Result<Vec<u8>, NntpError> {
        let mut out = Vec::with_capacity((768 * 1024).min(max_bytes));
        let mut line = Vec::with_capacity(1024);
        loop {
            line.clear();
            let line_limit = max_bytes.saturating_sub(self.body_wire_bytes).min(MAX_ARTICLE_LINE);
            if line_limit == 0 { return Err(NntpError::Protocol("article body exceeds limit".into())); }
            let n = timeout(self.io_timeout, async {
                on_transport!(self, c => (&mut *c).take(line_limit as u64).read_until(b'\n', &mut line).await)
            })
            .await
            .map_err(|_| NntpError::Timeout)??;
            if n == 0 {
                return Err(NntpError::Protocol("eof mid-body".into()));
            }
            self.body_wire_bytes = self.body_wire_bytes.saturating_add(n);
            if line.len() >= line_limit && line.last() != Some(&b'\n') {
                return Err(NntpError::Protocol("article line exceeds limit".into()));
            }
            if self.body_wire_bytes > max_bytes {
                return Err(NntpError::Protocol("article body exceeds limit".into()));
            }
            let content = strip_crlf(&line);
            // Terminator: a line that is exactly ".".
            if content == b"." {
                break;
            }
            // Dot-unstuffing: a data line starting with ".." drops one dot.
            let content = if content.starts_with(b"..") { &content[1..] } else { content };
            out.extend_from_slice(content);
            out.push(b'\n');
        }
        Ok(out)
    }
}

fn strip_crlf(line: &[u8]) -> &[u8] {
    let mut end = line.len();
    if end > 0 && line[end - 1] == b'\n' { end -= 1; }
    if end > 0 && line[end - 1] == b'\r' { end -= 1; }
    &line[..end]
}

fn tls_config() -> rustls::ClientConfig {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    rustls::ClientConfig::builder()
        .with_root_certificates(roots)
        .with_no_client_auth()
}

#[allow(unused_imports)]
use tokio::io::AsyncRead; // keep trait in scope for read_to_end on future paths
#[allow(dead_code)]
async fn _drain<R: AsyncReadExt + Unpin>(r: &mut R) -> std::io::Result<()> {
    let mut sink = Vec::new();
    r.read_to_end(&mut sink).await.map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    // read_multiline's unstuffing/termination is the fiddly bit — exercise it
    // against a hand-built server response over an in-memory duplex stream.
    #[tokio::test]
    async fn multiline_unstuffs_and_terminates() {
        // Not wired through TcpStream; test the pure transform via a helper that
        // mirrors read_multiline's logic on a byte slice.
        let server = b"line one\r\n..dotted line\r\n.\r\nTRAILING MUST NOT APPEAR";
        let decoded = decode_multiline_for_test(server);
        assert_eq!(decoded, b"line one\n.dotted line\n");
    }

    // Mirror of read_multiline's per-line transform, for a synchronous byte-slice
    // test (the async version is identical minus the socket).
    fn decode_multiline_for_test(input: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        for raw in input.split_inclusive(|&b| b == b'\n') {
            let content = strip_crlf(raw);
            if content == b"." {
                break;
            }
            let content = if content.starts_with(b"..") { &content[1..] } else { content };
            out.extend_from_slice(content);
            out.push(b'\n');
        }
        out
    }

    #[test]
    fn strip_crlf_variants() {
        assert_eq!(strip_crlf(b"abc\r\n"), b"abc");
        assert_eq!(strip_crlf(b"abc\n"), b"abc");
        assert_eq!(strip_crlf(b"abc"), b"abc");
    }
}

#[cfg(test)]
mod bounded_tests {
    use super::*;
    async fn rejects_body(body: Vec<u8>) {
        let (provider, server) = crate::pool::verified_fixtures::provider(std::collections::HashMap::from([("oversized".into(), body)])).await;
        let mut connection = NntpConn::connect(&provider).await.unwrap();
        let error = connection.body("oversized").await.err().expect("oversized response must fail");
        assert!(matches!(error, NntpError::Protocol(ref message) if message.contains("limit")));
        server.abort();
    }
    #[tokio::test]
    async fn multiline_limits_unterminated_line_and_total_body() {
        rejects_body(vec![b'A'; MAX_ARTICLE_LINE + 1]).await;
        rejects_body([vec![b'A'; 1022], b"\r\n".to_vec()].concat().repeat(MAX_ARTICLE_BYTES / 1024 + 1)).await;
    }
}

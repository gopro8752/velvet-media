//! Stable, safe reasons for failures before a streaming response starts. Never
//! expose indexer URLs, credentials, NNTP article IDs, or raw upstream bodies.
use axum::{http::{header, StatusCode}, response::{IntoResponse, Response}};

#[derive(Clone, Copy, Debug, thiserror::Error, PartialEq, Eq)]
pub enum StreamError {
    #[error("source has missing articles")]
    MissingArticles,
    #[error("source uses an unsupported archive format")]
    UnsupportedArchive,
    #[error("source is temporarily unavailable")]
    UpstreamUnavailable,
    #[error("unknown stream")]
    UnknownStream,
    #[error("bad range")]
    InvalidRange,
}
impl StreamError {
    pub fn code(self) -> &'static str { match self {
        Self::MissingArticles => "missing_articles", Self::UnsupportedArchive => "unsupported_archive",
        Self::UpstreamUnavailable => "upstream_unavailable", Self::UnknownStream => "unknown_stream",
        Self::InvalidRange => "invalid_range",
    }}
    pub fn response(self) -> Response {
        let status=match self {
            Self::MissingArticles=>StatusCode::BAD_GATEWAY,
            Self::UnsupportedArchive=>StatusCode::UNPROCESSABLE_ENTITY,
            Self::UpstreamUnavailable=>StatusCode::SERVICE_UNAVAILABLE,
            Self::UnknownStream=>StatusCode::NOT_FOUND, Self::InvalidRange=>StatusCode::RANGE_NOT_SATISFIABLE,
        };
        let mut response=(status,self.to_string()).into_response();
        response.headers_mut().insert("x-velvet-stream-error",self.code().parse().unwrap());
        response.headers_mut().insert(header::CACHE_CONTROL,"no-store".parse().unwrap());
        if self==Self::UpstreamUnavailable {response.headers_mut().insert(header::RETRY_AFTER,"1".parse().unwrap());}
        response
    }
    pub fn from_preparation(error:&anyhow::Error)->Self {
        error.downcast_ref::<Self>().copied().unwrap_or(Self::UpstreamUnavailable)
    }
}

/// Archive header readers currently conflate missing BODY, transient provider
/// errors and unreadable/truncated headers. Those are NOT proof of permanent
/// damage. Only metadata-proven layouts with no supported alternative are
/// rejected definitively; in particular Truncated never poisons a source.
/// `rar_absent` must come from the NZB volume list, since NoVolumes also means
/// headers yielded no media, and the legacy RAR parser can return NotStore
/// before proving all header bytes exist.
pub fn archive_failure(rar:&crate::archive::RarError, seven:&crate::sevenzip::SzError, rar_absent:bool)->StreamError {
    use crate::{archive::RarError,sevenzip::SzError};
    match (rar,seven) {
        (RarError::NoVolumes, SzError::NoFile|SzError::MultiVolume) if rar_absent=>StreamError::UnsupportedArchive,
        _=>StreamError::UpstreamUnavailable,
    }
}

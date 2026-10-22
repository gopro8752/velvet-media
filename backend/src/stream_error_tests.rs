use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};
use tokio::{io::{AsyncBufReadExt, AsyncWriteExt, BufReader}, net::TcpListener};

fn state(pool: Arc<Pool>) -> StreamState {
    let db=crate::db::open(":memory:").unwrap();
    crate::sync::migrate(&db.lock().unwrap()).unwrap();
    StreamState::new(pool,reqwest::Client::new(),db)
}

fn nzb(names:&[&str])->String {
    format!("<?xml version=\"1.0\"?><nzb xmlns=\"http://www.newzbin.com/DTD/2003/nzb\">{}</nzb>",names.iter().enumerate().map(|(i,name)|format!("<file subject=\"&quot;{name}&quot; yEnc\"><groups><group>fixture</group></groups><segments><segment bytes=\"100\" number=\"1\">fixture-{i}</segment></segments></file>")).collect::<String>())
}

async fn indexer(document:String, fail_first:bool)->(String,Arc<AtomicUsize>,tokio::task::JoinHandle<()>) {
    let listener=TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url=format!("http://{}/fixture.nzb",listener.local_addr().unwrap());
    let count=Arc::new(AtomicUsize::new(0)); let seen=count.clone();
    let task=tokio::spawn(async move {
        loop {
            let Ok((socket,_))=listener.accept().await else{return;};
            let mut socket=BufReader::new(socket);
            loop { let mut line=String::new(); if socket.read_line(&mut line).await.unwrap_or(0)==0 || line=="\r\n" {break;} }
            let attempt=seen.fetch_add(1,Ordering::Relaxed);
            let (status,body)=if fail_first && attempt==0 {("503 Service Unavailable","private upstream diagnostic")} else {("200 OK",document.as_str())};
            let response=format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len());
            let _=socket.get_mut().write_all(response.as_bytes()).await;
        }
    });
    (url,count,task)
}

async fn provider(data:Vec<u8>, missing:bool)->(crate::config::Provider,tokio::task::JoinHandle<()>) {
    let listener=TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port=listener.local_addr().unwrap().port();
    let task=tokio::spawn(async move {
        loop {
            let Ok((socket,_))=listener.accept().await else{return;}; let data=data.clone();
            tokio::spawn(async move {
                let mut socket=BufReader::new(socket);
                socket.get_mut().write_all(b"200 fixture\r\n").await.unwrap();
                loop {
                    let mut line=String::new(); if socket.read_line(&mut line).await.unwrap_or(0)==0 {break;}
                    let response=if line.starts_with("AUTHINFO") {b"281 accepted\r\n".to_vec()}
                    else if line.starts_with("GROUP") {b"211 fixture\r\n".to_vec()}
                    else if line.starts_with("STAT") {if missing {b"430 missing\r\n".to_vec()}else{b"223 present\r\n".to_vec()}}
                    else if line.starts_with("BODY") && !missing {
                        let mut body=format!("222 body\r\n=ybegin line=128 size={} name=fixture.mp4\r\n=ypart begin=1 end={}\r\n",data.len(),data.len()).into_bytes();
                        for b in &data {let v=b.wrapping_add(42);if matches!(v,0|10|13|61){body.push(b'=');body.push(v.wrapping_add(64));}else{body.push(v);}}
                        body.extend_from_slice(format!("\r\n=yend size={}\r\n.\r\n",data.len()).as_bytes());body
                    } else {b"430 missing\r\n".to_vec()};
                    if socket.get_mut().write_all(&response).await.is_err(){break;}
                }
            });
        }
    });
    (crate::config::Provider{name:"fixture".into(),host:"127.0.0.1".into(),port,tls:false,username:"fixture".into(),password:"fixture".into(),max_connections:4},task)
}

fn code(response:&Response)->&str {response.headers().get("x-velvet-stream-error").unwrap().to_str().unwrap()}

#[tokio::test]
async fn transient_indexer_failure_preserves_same_source_and_next_request_succeeds() {
    let original=(0..100).collect::<Vec<u8>>();
    let (p,pserver)=provider(original.clone(),false).await;
    let (url,count,server)=indexer(nzb(&["fixture.mp4"]),true).await;
    let st=state(Pool::new(&[p])); let sid=st.register(&url).await;
    let response=serve(State(st.clone()),Path(sid.clone()),HeaderMap::new()).await;
    assert_eq!(response.status(),StatusCode::SERVICE_UNAVAILABLE);assert_eq!(code(&response),"upstream_unavailable");
    assert_eq!(response.headers().get("retry-after").unwrap(),"1");
    let body=axum::body::to_bytes(response.into_body(),4096).await.unwrap();
    assert!(!String::from_utf8_lossy(&body).contains("private upstream"));
    assert!(!st.is_condemned(&url));assert!(!st.lookup(&sid).unwrap().unsupported());
    let response=serve(State(st.clone()),Path(sid.clone()),HeaderMap::new()).await;
    assert_eq!(response.status(),StatusCode::PARTIAL_CONTENT);
    assert!(response.headers().get("x-velvet-stream-error").is_none());
    assert_eq!(axum::body::to_bytes(response.into_body(),4096).await.unwrap().as_ref(),original);
    assert_eq!(count.load(Ordering::Relaxed),2);
    server.abort();pserver.abort();
}

#[tokio::test]
async fn structural_unsupported_source_is_ttl_cached_filtered_and_not_warmed_as_healthy() {
    let (url,count,server)=indexer(nzb(&["fixture.7z.001","fixture.7z.002"]),false).await;
    let st=state(Pool::new(&[]));let sid=st.register(&url).await;
    for _ in 0..3 {
        let response=serve(State(st.clone()),Path(sid.clone()),HeaderMap::new()).await;
        assert_eq!(response.status(),StatusCode::UNPROCESSABLE_ENTITY);assert_eq!(code(&response),"unsupported_archive");
    }
    assert_eq!(count.load(Ordering::Relaxed),1);
    assert!(st.is_condemned(&url));
    let health=st.health(&sid).unwrap();assert_eq!(health.status,"unsupported");assert_eq!(health.error_code,Some("unsupported_archive"));
    let current=st.register("http://fixture.invalid/current.nzb").await;
    st.set_recovery_candidates(&[current.clone(),sid.clone()]);
    let entry=st.lookup(&current).unwrap();entry.recovery.lock().unwrap().attempted=true;
    prepare_recovery_inner(&st,&current,&entry).await;
    assert_eq!(st.health(&current).unwrap().recovery.status,"unavailable");
    assert_eq!(count.load(Ordering::Relaxed),1,"proactive preparation must honor cached structural rejection");
    *st.lookup(&sid).unwrap().unsupported_at.lock().unwrap()=Some(std::time::Instant::now()-std::time::Duration::from_secs(301));
    assert!(!st.is_condemned(&url),"structural cache must expire rather than permanently poison source registration");
    assert_eq!(serve(State(st),Path(sid),HeaderMap::new()).await.status(),StatusCode::UNPROCESSABLE_ENTITY);
    assert_eq!(count.load(Ordering::Relaxed),2);server.abort();
}

#[tokio::test]
async fn raw_first_article_missing_is_distinct_from_transient_provider_unavailability() {
    let (p,pserver)=provider(vec![0;100],true).await;
    let (url,_,server)=indexer(nzb(&["fixture.mp4"]),false).await;
    let st=state(Pool::new(&[p]));let sid=st.register(&url).await;
    let response=serve(State(st),Path(sid),HeaderMap::new()).await;
    assert_eq!(response.status(),StatusCode::BAD_GATEWAY);assert_eq!(code(&response),"missing_articles");
    let unavailable=state(Pool::new(&[]));let sid=unavailable.register(&url).await;
    let response=serve(State(unavailable),Path(sid),HeaderMap::new()).await;
    assert_eq!(response.status(),StatusCode::SERVICE_UNAVAILABLE);assert_eq!(code(&response),"upstream_unavailable");
    server.abort();pserver.abort();
}

#[tokio::test]
async fn unknown_stream_and_invalid_range_have_safe_machine_readable_responses() {
    let st=state(Pool::new(&[]));
    let response=serve(State(st.clone()),Path("ffffffffffffffff".into()),HeaderMap::new()).await;
    assert_eq!(response.status(),StatusCode::NOT_FOUND);assert_eq!(code(&response),"unknown_stream");
    let sid=st.register("http://fixture.invalid/source.nzb").await;
    *st.lookup(&sid).unwrap().loaded.lock().unwrap()=Some(Loaded{extents:Arc::new(vec![]),ext_media_start:Arc::new(vec![]),total_size:100,complete:Some(true)});
    let mut headers=HeaderMap::new();headers.insert(header::RANGE,"bytes=200-300".parse().unwrap());
    let response=serve(State(st),Path(sid),headers).await;
    assert_eq!(response.status(),StatusCode::RANGE_NOT_SATISFIABLE);assert_eq!(code(&response),"invalid_range");
}

#[test]
fn unreadable_or_truncated_archive_headers_are_never_classified_as_permanent() {
    use crate::{archive::RarError,sevenzip::SzError,stream_errors::archive_failure};
    for (rar,sz) in [(RarError::NoVolumes,SzError::Truncated),(RarError::Volume(0),SzError::NoFile),(RarError::Volume(0),SzError::MultiVolume),(RarError::NoVolumes,SzError::BadSig)] {
        assert_eq!(archive_failure(&rar,&sz,true),StreamError::UpstreamUnavailable);
    }
    assert_eq!(archive_failure(&RarError::NoVolumes,&SzError::MultiVolume,true),StreamError::UnsupportedArchive);
    assert_eq!(archive_failure(&RarError::NotStore,&SzError::NoFile,false),StreamError::UpstreamUnavailable);
    assert_eq!(archive_failure(&RarError::NoVolumes,&SzError::NoFile,false),StreamError::UpstreamUnavailable);
}

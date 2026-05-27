use crate::{
    dns::{self, ListeningServer},
    DnsHandler,
};
use hickory_client::{
    client::{AsyncClient, ClientHandle as _},
    op::DnsResponse,
    proto::iocompat::AsyncIoTokioAsStd,
    rr::{DNSClass, Name, RData, RecordType},
    tcp::TcpClientStream,
};
use pretty_assertions::assert_eq;
use std::str::FromStr as _;
use tokio::{net::TcpStream as TokioTcpStream, task::AbortHandle};

pub fn assert_answers(res: DnsResponse, expected: &[(&str, RData)]) {
    let answers = res.answers();
    assert_eq!(answers.len(), expected.len());
    for (answer, (expected_name, expected_data)) in answers.iter().zip(expected) {
        assert_eq!(answer.name(), &Name::from_str(expected_name).unwrap());
        assert_eq!(answer.data().unwrap(), expected_data);
    }
}

pub fn mk_mock_backend(mock_backend_response: serde_json::Value) -> httpmock::MockServer {
    let mock_backend = httpmock::MockServer::start();
    mock_backend.mock(|expect, respond_with| {
        expect.path("/api/hosts/dns");
        respond_with.body(&serde_json::to_vec(&mock_backend_response).unwrap());
    });
    mock_backend
}

pub async fn spin_up_dns_server(
    mock_backend: &httpmock::MockServer,
) -> (DnsHandler, ListeningServer<DnsHandler>) {
    let backend_origin = format!("http://{}:{}", mock_backend.host(), mock_backend.port());
    let dns_handler = DnsHandler::new(backend_origin);
    dns_handler.update_records().await.unwrap();
    (
        dns_handler.clone(),
        dns::Server::new(dns_handler)
            .listen(&["127.0.0.1:0"])
            .await
            .unwrap(),
    )
}

pub struct TestDnsClient {
    client: AsyncClient,
    abort_handle: AbortHandle,
}

impl TestDnsClient {
    pub async fn query(&mut self, name: &str, record_type: RecordType) -> DnsResponse {
        self.client
            .query(Name::from_str(name).unwrap(), DNSClass::IN, record_type)
            .await
            .unwrap()
    }
}

impl Drop for TestDnsClient {
    fn drop(&mut self) {
        self.abort_handle.abort();
    }
}

pub async fn mk_mock_client(to_query: &ListeningServer<DnsHandler>) -> TestDnsClient {
    let (stream, sender) =
        TcpClientStream::<AsyncIoTokioAsStd<TokioTcpStream>>::new(to_query.tcp_bound_addrs[0]);
    let (client, bg) = AsyncClient::new(stream, sender, None).await.unwrap();
    let abort_handle = tokio::spawn(bg).abort_handle();
    TestDnsClient {
        client,
        abort_handle,
    }
}

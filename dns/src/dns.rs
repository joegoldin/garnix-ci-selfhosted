use anyhow::Result;
use async_trait::async_trait;
use hickory_server::{
    authority::MessageResponseBuilder,
    proto::{op::Header, rr::Record},
    server::{Request, RequestHandler, ResponseHandler, ResponseInfo},
    ServerFuture,
};
use std::{net::SocketAddr, time::Duration};
use tokio::net::{TcpListener, UdpSocket};

pub use hickory_server::proto::{
    op::ResponseCode,
    rr::{rdata, Name, RData, RecordType},
};

use crate::SOA_MINIMUM;

pub struct Server<Handler>(Handler);

impl<Handler: ServerHandler> Server<Handler> {
    pub fn new(handler: Handler) -> Self {
        Self(handler)
    }

    pub async fn listen(self, addrs: &[&str]) -> Result<ListeningServer<Handler>> {
        let mut server = ServerFuture::new(self);
        let mut tcp_bound_addrs = vec![];
        for &addr in addrs {
            eprintln!("Trying to listen on {addr}");
            let udp = UdpSocket::bind(addr).await?;
            let tcp = TcpListener::bind(addr).await?;
            tcp_bound_addrs.push(tcp.local_addr()?);
            server.register_socket(udp);
            server.register_listener(tcp, Duration::from_secs(5));
        }
        Ok(ListeningServer {
            server,
            tcp_bound_addrs,
        })
    }
}

pub struct ListeningServer<Handler: ServerHandler> {
    pub server: ServerFuture<Server<Handler>>,
    pub tcp_bound_addrs: Vec<SocketAddr>,
}

impl<Handler: ServerHandler> ListeningServer<Handler> {
    pub async fn block_until_done(mut self) -> Result<()> {
        self.server.block_until_done().await?;
        Ok(())
    }
}

#[async_trait]
impl<Handler: ServerHandler> RequestHandler for Server<Handler> {
    async fn handle_request<R>(&self, req: &Request, mut res: R) -> ResponseInfo
    where
        R: ResponseHandler,
    {
        let (response_code, answers) = self
            .0
            .get_answers(req.query().query_type(), req.query().name().into())
            .await
            .unwrap_or_else(|err| {
                eprintln!("Failed to get_answers: {err}");
                (ResponseCode::ServFail, vec![])
            });
        let answers: Vec<Record> = answers
            .into_iter()
            .map(|answer| {
                Record::from_rdata(
                    answer.name,
                    answer
                        .ttl
                        // As per RFC1035, the TTL should never be less than
                        // the minimum value specified in the zone's SOA record.
                        .max(SOA_MINIMUM)
                        .as_secs()
                        .try_into()
                        .unwrap_or_else(|_| {
                            eprintln!("Failed to parse ttl as u32, using 3600");
                            3600
                        }),
                    answer.data,
                )
            })
            .collect();
        let mut header = Header::response_from_request(req.header());
        header.set_response_code(response_code);
        let response =
            MessageResponseBuilder::from_message_request(req).build(header, &answers, [], [], []);
        res.send_response(response).await.unwrap()
    }
}

#[async_trait]
pub trait ServerHandler: Send + Sync + Unpin + 'static {
    async fn get_answers(
        &self,
        record_type: RecordType,
        name: Name,
    ) -> Result<(ResponseCode, Vec<Answer>)>;
}

pub struct Answer {
    pub name: Name,
    pub ttl: Duration,
    pub data: RData,
}

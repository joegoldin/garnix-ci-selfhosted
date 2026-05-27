mod dns;

#[cfg(test)]
mod test_helpers;

use anyhow::Result;
use async_trait::async_trait;
use dns::{rdata, Answer, Name, RData, RecordType, ResponseCode};
use serde::{Deserialize, Serialize};
use std::{
    collections::HashMap,
    env,
    net::Ipv4Addr,
    str::{self, FromStr as _},
    sync::Arc,
    time::{Duration, SystemTime},
};
use tokio::{spawn, sync::RwLock, time::sleep};

/// Duration between making API requests to garnix-server1 to get the latest list of servers.
const POLL_INTERVAL: Duration = Duration::from_secs(5);

// To be compliant we need to return SOA record with these values, but they should not matter
// unless we start responding to AXFR requests
const SOA_AUTHORITY: &str = "ns1.garnix.io";
const SOA_CONTACT: &str = "contact.garnix.io";
// The three fields below are used only for zone transfers, we don't care much
// about their values for now.
// See https://www.rfc-editor.org/rfc/rfc1035
const SOA_REFRESH: Duration = POLL_INTERVAL;
const SOA_RETRY: Duration = POLL_INTERVAL;
const SOA_EXPIRE: Duration = SOA_REFRESH.saturating_add(SOA_RETRY);
// The minimum TTL value, the TTL of a reply to a query will be
// the max of this value and the TTL value of the requested RR.
// This value is also used as the TTL for NXDOMAIN and SOA responses.
const SOA_MINIMUM: Duration = POLL_INTERVAL;

/// This maps to the HostIPs type in garnix backend
#[derive(Serialize, Deserialize, Clone, Debug)]
struct HostIPs {
    ipv4: Ipv4Addr,
}

#[derive(Debug)]
struct DnsHandlerState {
    records: HashMap<Name, HostIPs>,
    last_update: SystemTime,
}

#[derive(Clone)]
pub struct DnsHandler {
    api_origin: String,
    state: Arc<RwLock<DnsHandlerState>>,

    base_tld_for_hash: Name,
    base_tld_for_raw: Name,
}

impl DnsHandler {
    fn new(api_origin: String) -> Self {
        Self {
            api_origin,
            state: Arc::new(RwLock::new(DnsHandlerState {
                records: Default::default(),
                last_update: SystemTime::UNIX_EPOCH,
            })),
            base_tld_for_hash: Name::from_ascii("hash.garnix.me.")
                .expect("hash.garnix.me. to be a valid domain"),
            base_tld_for_raw: Name::from_ascii("raw.garnix.me.")
                .expect("raw.garnix.me. to be a valid domain"),
        }
    }

    fn start_polling(self) {
        spawn(async move {
            loop {
                if let Err(err) = self.update_records().await {
                    eprintln!("Failed to fetch servers: {err}");
                }
                sleep(POLL_INTERVAL).await;
            }
        });
    }

    async fn update_records(&self) -> Result<()> {
        /// This maps to the DnsHosts type in garnix backend
        #[derive(Serialize, Deserialize, Clone, Default)]
        #[serde(rename_all = "camelCase")]
        struct DnsHosts {
            by_hash: HashMap<String, HostIPs>,
            by_name: HashMap<String, HostIPs>,
        }
        let DnsHosts { by_hash, by_name } =
            reqwest::get(format!("{}/api/hosts/dns", self.api_origin))
                .await?
                .json::<DnsHosts>()
                .await?;
        let mut domains = HashMap::with_capacity(by_hash.len() + by_name.len());
        for (hash, ips) in by_hash {
            match Name::from_ascii(&hash).and_then(|n| n.append_domain(&self.base_tld_for_hash)) {
                Ok(domain) => {
                    domains.insert(domain, ips);
                }
                Err(err) => {
                    eprintln!("Could not insert hash domain {hash}: {err}");
                }
            }
        }
        for (name, ips) in by_name {
            match Name::from_ascii(&name).and_then(|n| n.append_domain(&self.base_tld_for_raw)) {
                Ok(domain) => {
                    domains.insert(domain, ips);
                }
                Err(err) => {
                    eprintln!("Could not insert raw domain {name}: {err}");
                }
            }
        }
        *self.state.write().await = DnsHandlerState {
            records: domains,
            last_update: SystemTime::now(),
        };
        Ok(())
    }

    async fn lookup_name(&self, domain_name: &Name) -> Option<HostIPs> {
        self.state.read().await.records.get(domain_name).cloned()
    }

    async fn get_serial(&self) -> u32 {
        self.state
            .read()
            .await
            .last_update
            .duration_since(SystemTime::UNIX_EPOCH)
            .expect("duration_since UNIX_EPOCH should never fail")
            .as_secs() as u32
    }
}

#[async_trait]
impl dns::ServerHandler for DnsHandler {
    async fn get_answers(
        &self,
        record_type: RecordType,
        name: Name,
    ) -> Result<(ResponseCode, Vec<Answer>)> {
        if record_type == RecordType::SOA {
            return Ok((
                ResponseCode::NoError,
                vec![Answer {
                    name,
                    ttl: SOA_MINIMUM,
                    data: RData::SOA(rdata::SOA::new(
                        Name::from_str(SOA_AUTHORITY).unwrap(),
                        Name::from_str(SOA_CONTACT).unwrap(),
                        self.get_serial().await,
                        SOA_REFRESH.as_secs() as i32,
                        SOA_RETRY.as_secs() as i32,
                        SOA_EXPIRE.as_secs() as i32,
                        SOA_MINIMUM.as_secs() as u32,
                    )),
                }],
            ));
        }
        if !self.base_tld_for_hash.zone_of(&name) && !self.base_tld_for_raw.zone_of(&name) {
            return Ok((ResponseCode::Refused, vec![]));
        }
        Ok(match (record_type, self.lookup_name(&name).await) {
            (RecordType::A, Some(host_ips)) => (
                ResponseCode::NoError,
                vec![Answer {
                    name,
                    ttl: POLL_INTERVAL,
                    data: RData::A(host_ips.ipv4.into()),
                }],
            ),
            _ => (
                ResponseCode::NXDomain,
                vec![Answer {
                    name,
                    ttl: SOA_MINIMUM,
                    data: RData::SOA(rdata::SOA::new(
                        Name::from_str(SOA_AUTHORITY).unwrap(),
                        Name::from_str(SOA_CONTACT).unwrap(),
                        self.get_serial().await,
                        SOA_REFRESH.as_secs() as i32,
                        SOA_RETRY.as_secs() as i32,
                        SOA_EXPIRE.as_secs() as i32,
                        SOA_MINIMUM.as_secs() as u32,
                    )),
                }],
            ),
        })
    }
}

#[tokio::main]
async fn main() {
    let listen_addrs = env::var("LISTEN_ADDRS").expect("LISTEN_ADDRS env var must be set");
    let api_origin = env::var("API_ORIGIN").expect("API_ORIGIN env var must be set");

    let dns_handler = DnsHandler::new(api_origin);
    dns_handler.clone().start_polling();
    dns::Server::new(dns_handler)
        .listen(&listen_addrs.split(',').collect::<Vec<&str>>())
        .await
        .unwrap()
        .block_until_done()
        .await
        .unwrap();
}

#[cfg(test)]
mod tests {
    use crate::{
        test_helpers, SOA_AUTHORITY, SOA_CONTACT, SOA_EXPIRE, SOA_MINIMUM, SOA_REFRESH, SOA_RETRY,
    };
    use hickory_client::{
        op::ResponseCode,
        proto::rr::rdata,
        rr::{Name, RData, RecordType},
    };
    use serde_json::json;
    use std::{str::FromStr as _, time::SystemTime};

    #[tokio::test]
    async fn test_retrieving_hash_a_records() {
        let mock_backend = test_helpers::mk_mock_backend(json!({
            "byHash": {
                "foo": { "ipv4": "1.2.3.4" },
                "bar": { "ipv4": "5.6.7.8" },
            },
            "byName": {},
        }));
        let (_, dns_server) = test_helpers::spin_up_dns_server(&mock_backend).await;
        let mut client = test_helpers::mk_mock_client(&dns_server).await;
        let res = client.query("foo.hash.garnix.me", RecordType::A).await;
        assert_eq!(res.response_code(), ResponseCode::NoError);
        test_helpers::assert_answers(
            res,
            &[(
                "foo.hash.garnix.me",
                RData::A(rdata::A([1, 2, 3, 4].into())),
            )],
        );
    }

    #[tokio::test]
    async fn test_retrieving_raw_a_records() {
        let mock_backend = test_helpers::mk_mock_backend(json!({
            "byHash": {},
            "byName": {
                "package.branch.repo.owner": { "ipv4": "1.2.3.4" },
            },
        }));
        let (_, dns_server) = test_helpers::spin_up_dns_server(&mock_backend).await;
        let mut client = test_helpers::mk_mock_client(&dns_server).await;
        let res = client
            .query("package.branch.repo.owner.raw.garnix.me", RecordType::A)
            .await;
        assert_eq!(res.response_code(), ResponseCode::NoError);
        test_helpers::assert_answers(
            res,
            &[(
                "package.branch.repo.owner.raw.garnix.me",
                RData::A(rdata::A([1, 2, 3, 4].into())),
            )],
        );
    }

    #[tokio::test]
    async fn test_retrieving_raw_a_records_ignores_casing() {
        let mock_backend = test_helpers::mk_mock_backend(json!({
            "byHash": {},
            "byName": {
                "package.BRANCH.repo.OWNER": { "ipv4": "1.2.3.4" },
            },
        }));
        let (_, dns_server) = test_helpers::spin_up_dns_server(&mock_backend).await;
        let mut client = test_helpers::mk_mock_client(&dns_server).await;
        let res = client
            .query("PACKAGE.branch.REPO.owner.RAW.garnix.ME", RecordType::A)
            .await;
        assert_eq!(res.response_code(), ResponseCode::NoError);
        test_helpers::assert_answers(
            res,
            &[(
                "package.branch.repo.owner.raw.garnix.me",
                RData::A(rdata::A([1, 2, 3, 4].into())),
            )],
        );
    }

    #[tokio::test]
    async fn test_retreiving_hash_soa_records() {
        let mock_backend = test_helpers::mk_mock_backend(json!({ "byHash": {}, "byName": {} }));
        let before_spinup = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap();
        let (handler, dns_server) = test_helpers::spin_up_dns_server(&mock_backend).await;
        let after_spinup = SystemTime::now()
            .duration_since(SystemTime::UNIX_EPOCH)
            .unwrap();
        let mut client = test_helpers::mk_mock_client(&dns_server).await;
        let res = client.query("hash.garnix.me", RecordType::SOA).await;
        assert_eq!(res.response_code(), ResponseCode::NoError);
        let serial = handler.get_serial().await;
        assert!((before_spinup.as_secs() as u32) <= serial);
        assert!((after_spinup.as_secs() as u32) >= serial);
        test_helpers::assert_answers(
            res,
            &[(
                "hash.garnix.me",
                RData::SOA(rdata::SOA::new(
                    Name::from_str(SOA_AUTHORITY).unwrap(),
                    Name::from_str(SOA_CONTACT).unwrap(),
                    serial,
                    SOA_REFRESH.as_secs() as i32,
                    SOA_RETRY.as_secs() as i32,
                    SOA_EXPIRE.as_secs() as i32,
                    SOA_MINIMUM.as_secs() as u32,
                )),
            )],
        );
    }

    #[tokio::test]
    async fn test_retreiving_missing_hash_records_responds_with_nxdomain() {
        let mock_backend = test_helpers::mk_mock_backend(json!({ "byHash": {}, "byName": {} }));
        let (handler, dns_server) = test_helpers::spin_up_dns_server(&mock_backend).await;
        let mut client = test_helpers::mk_mock_client(&dns_server).await;
        let res = client.query("missing.hash.garnix.me", RecordType::A).await;
        let serial = handler.get_serial().await;
        assert_eq!(res.response_code(), ResponseCode::NXDomain);
        test_helpers::assert_answers(
            res,
            &[(
                "missing.hash.garnix.me",
                RData::SOA(rdata::SOA::new(
                    Name::from_str(SOA_AUTHORITY).unwrap(),
                    Name::from_str(SOA_CONTACT).unwrap(),
                    serial,
                    SOA_REFRESH.as_secs() as i32,
                    SOA_RETRY.as_secs() as i32,
                    SOA_EXPIRE.as_secs() as i32,
                    SOA_MINIMUM.as_secs() as u32,
                )),
            )],
        );
    }

    #[tokio::test]
    async fn test_retreiving_missing_raw_records_responds_with_nxdomain() {
        let mock_backend = test_helpers::mk_mock_backend(json!({ "byHash": {}, "byName": {} }));
        let (handler, dns_server) = test_helpers::spin_up_dns_server(&mock_backend).await;
        let mut client = test_helpers::mk_mock_client(&dns_server).await;
        let res = client.query("missing.raw.garnix.me", RecordType::A).await;
        let serial = handler.get_serial().await;
        assert_eq!(res.response_code(), ResponseCode::NXDomain);
        test_helpers::assert_answers(
            res,
            &[(
                "missing.raw.garnix.me",
                RData::SOA(rdata::SOA::new(
                    Name::from_str(SOA_AUTHORITY).unwrap(),
                    Name::from_str(SOA_CONTACT).unwrap(),
                    serial,
                    SOA_REFRESH.as_secs() as i32,
                    SOA_RETRY.as_secs() as i32,
                    SOA_EXPIRE.as_secs() as i32,
                    SOA_MINIMUM.as_secs() as u32,
                )),
            )],
        );
    }

    #[tokio::test]
    async fn test_retreiving_records_for_non_authoritative_domains_responds_with_refused() {
        let mock_backend = test_helpers::mk_mock_backend(json!({ "byHash": {}, "byName": {} }));
        let (_, dns_server) = test_helpers::spin_up_dns_server(&mock_backend).await;
        let mut client = test_helpers::mk_mock_client(&dns_server).await;
        let res = client.query("example.org", RecordType::A).await;
        assert_eq!(res.response_code(), ResponseCode::Refused);
        test_helpers::assert_answers(res, &[]);
    }
}

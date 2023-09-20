use pratt_rs::Certificate;
use rug::{integer::Order, Integer};

pub fn verify(cert: Certificate) -> bool {
    let prime = Integer::from_digits(&cert.prime, Order::Msf);

    todo!();
}

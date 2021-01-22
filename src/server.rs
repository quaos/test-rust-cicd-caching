use std::net::SocketAddr;
use warp::{Filter, Rejection, Reply};

pub async fn serve() {
    let host = "0.0.0.0:8000";

    info!("starting http server at: {}", &host);

    let cors = warp::cors()
        .allow_any_origin()
        .allow_credentials(true)
        .allow_headers(vec!["Authorization", "Accept", "Content-Type"])
        .allow_methods(vec!["POST", "GET", "OPTIONS", "DELETE", "PUT", "PATCH"])
        .max_age(3600);

    // [GET] /ping
    let health_check_handler = warp::get()
        .and(warp::path("ping"))
        .and_then(handle_health_check);

    let routes = health_check_handler.with(cors);

    let socket_addr: SocketAddr = host
        .parse()
        .unwrap_or_else(|_| panic!("invalid host: {}", host));
    warp::serve(routes).run(socket_addr).await;
}

async fn handle_health_check() -> std::result::Result<impl Reply, Rejection> {
    Ok(warp::reply::json(&"Ok"))
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_dummy() {
        assert!(true)
    }
}

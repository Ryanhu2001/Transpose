use reqwest::{redirect::Policy, Client, Url};
use serde_json::{json, Value};
use std::{sync::OnceLock, time::Duration};

const MAXIMUM_BYTES: usize = 2_000_000;
const MAXIMUM_ERROR_BYTES: usize = 65_536;
static CLIENT: OnceLock<Result<Client, String>> = OnceLock::new();

/// Reject clear-text remote endpoints and URL credentials before resolving any
/// API key. Authorization never follows a redirect to a different service.
pub fn endpoint(provider: &str, value: &str) -> Result<Url, String> {
    let defaults = super::settings::default_connection(provider);
    let supplied = if value.trim().is_empty() {
        defaults.base_url.as_str()
    } else {
        value.trim()
    };
    let mut url = Url::parse(supplied).map_err(|_| "Enter a valid HTTP or HTTPS API address.")?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err(
            "Enter a valid HTTP or HTTPS address without a username, password or fragment.".into(),
        );
    }
    let host = url.host_str().unwrap_or_default().trim_matches(['[', ']']);
    let loopback = host.eq_ignore_ascii_case("localhost")
        || host
            .parse::<std::net::IpAddr>()
            .is_ok_and(|ip| ip.is_loopback());
    if url.scheme() == "http" && !loopback {
        return Err(
            "Remote API services require HTTPS; HTTP is only allowed for localhost.".into(),
        );
    }
    let path = url.path().trim_end_matches('/');
    let path = if path.ends_with("/chat/completions") {
        path.to_owned()
    } else {
        format!("{path}/chat/completions")
    };
    url.set_path(&path);
    Ok(url)
}

pub async fn translate(
    provider: &str,
    base_url: &str,
    model: &str,
    key: &str,
    prompt: &str,
    text: &str,
    on_delta: &(dyn Fn(String) + Send + Sync),
) -> Result<String, String> {
    let url = endpoint(provider, base_url)?;
    if key.contains(['\n', '\r', '\0']) {
        return Err("The API key has an invalid format.".into());
    }
    if provider != "customAPI" && key.trim().is_empty() {
        return Err("Add an API key in Translation Services.".into());
    }
    let defaults = super::settings::default_connection(provider);
    let model = if model.trim().is_empty() {
        defaults.model.as_str()
    } else {
        model.trim()
    };
    if model.is_empty() {
        return Err("Enter a model name in Translation Services.".into());
    }
    let mut body = json!({"model":model,"messages":[{"role":"system","content":prompt},{"role":"user","content":text}],
        "stream":true,"temperature":0.2,"max_tokens":(text.chars().count()*2+256).clamp(1024,16384)});
    if provider == "deepseek" {
        body["thinking"] = json!({"type":"disabled"});
    }
    if provider == "openrouter" {
        body["reasoning"] = json!({"enabled":false});
        body["provider"] = json!({"allow_fallbacks":false});
    }
    // Share the connection pool across translations while keeping credentials
    // on each individual request, so repeat lookups reuse TLS connections.
    let client = CLIENT
        .get_or_init(|| {
            Client::builder()
                .redirect(Policy::none())
                .connect_timeout(Duration::from_secs(10))
                .timeout(Duration::from_secs(60))
                .build()
                .map_err(|_| "Unable to start the translation connection.".to_owned())
        })
        .as_ref()
        .map_err(Clone::clone)?;
    let mut response = request(client, &url, provider, key, &body)
        .send()
        .await
        .map_err(network_error)?;
    // Some models require reasoning. Only retry an explicit rejection of our
    // disabled-reasoning preference, preserving the user's model and routing.
    if provider == "openrouter" && response.status().as_u16() == 400 {
        let error = bounded_error_body(&mut response).await;
        if let Some(retry_body) = mandatory_reasoning_body(&body, &error) {
            response = request(client, &url, provider, key, &retry_body)
                .send()
                .await
                .map_err(network_error)?;
        }
    }
    let status = response.status().as_u16();
    if !(200..300).contains(&status) {
        return Err(match status {
            300..=399 => "The API address redirects. Enter the final service address.".into(),
            401 | 403 => "The API key is invalid or does not have access to this model.".into(),
            402 => {
                "This API account has insufficient credit, or the selected model requires payment."
                    .into()
            }
            429 => {
                "The model's request limit was reached. Try again later or choose another model."
                    .into()
            }
            _ => format!("The translation service is unavailable (HTTP {status})."),
        });
    }
    let is_json = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|value| {
            value.split(';').next().unwrap_or_default().trim() == "application/json"
        });
    let mut buffer = Vec::new();
    let mut bytes = 0;
    let mut output = String::new();
    let mut completed = false;
    while let Some(chunk) = response.chunk().await.map_err(network_error)? {
        bytes += chunk.len();
        if bytes > MAXIMUM_BYTES {
            return Err("The translation response is too large. Select a smaller area.".into());
        }
        buffer.extend_from_slice(&chunk);
        if is_json {
            continue;
        }
        while let Some(position) = buffer.iter().position(|byte| *byte == b'\n') {
            let line: Vec<u8> = buffer.drain(..=position).collect();
            let line = std::str::from_utf8(&line)
                .map_err(|_| "The translation stream contains invalid text.")?;
            let (delta, done) = parse_line(line.trim_end_matches(['\r', '\n']))?;
            if let Some(delta) = delta {
                output.push_str(&delta);
                if !output.is_empty() {
                    on_delta(output.clone());
                }
            }
            if done {
                completed = true;
                break;
            }
        }
        if completed {
            break;
        }
    }
    if is_json {
        output = parse_complete(&buffer)?;
        on_delta(output.clone());
        completed = true;
    } else if !completed && !buffer.is_empty() {
        let line = std::str::from_utf8(&buffer)
            .map_err(|_| "The translation stream contains invalid text.")?;
        let (delta, done) = parse_line(line.trim())?;
        if let Some(delta) = delta {
            output.push_str(&delta);
            on_delta(output.clone());
        }
        completed = done;
    }
    if !completed {
        return Err(
            "The translation connection ended before the response was complete. Try again.".into(),
        );
    }
    let output = output.trim().to_owned();
    if output.is_empty() {
        return Err("The model returned no translation. Check the model name.".into());
    }
    Ok(output)
}

fn request(
    client: &Client,
    url: &Url,
    provider: &str,
    key: &str,
    body: &Value,
) -> reqwest::RequestBuilder {
    let mut request = client
        .post(url.clone())
        .header("Accept", "text/event-stream")
        .json(body);
    if !key.trim().is_empty() {
        request = request.bearer_auth(key.trim());
    }
    if provider == "openrouter" {
        request = request.header("X-Title", "Transpose");
    }
    request
}

async fn bounded_error_body(response: &mut reqwest::Response) -> Vec<u8> {
    let mut data = Vec::new();
    while let Ok(Some(chunk)) = response.chunk().await {
        if data.len() + chunk.len() > MAXIMUM_ERROR_BYTES {
            return Vec::new();
        }
        data.extend_from_slice(&chunk);
    }
    data
}

fn mandatory_reasoning_body(original: &Value, error: &[u8]) -> Option<Value> {
    let error: Value = serde_json::from_slice(error).ok()?;
    let message = error["error"]["message"].as_str()?.to_ascii_lowercase();
    if original["reasoning"]["enabled"] != false
        || !message.contains("reasoning is mandatory")
        || !message.contains("cannot be disabled")
    {
        return None;
    }
    let mut body = original.clone();
    // Excluding reasoning hides it in the response; it does not disable it.
    body["reasoning"] = json!({"exclude":true});
    Some(body)
}

fn network_error(error: reqwest::Error) -> String {
    // reqwest's Display may include the endpoint and query. Never forward it.
    if error.is_timeout() {
        "The translation request timed out. Try again.".into()
    } else if error.is_connect() {
        "Unable to connect. Check your network and API address.".into()
    } else {
        "The translation connection was interrupted. Try again.".into()
    }
}

fn content(value: &Value) -> Option<String> {
    if let Some(value) = value.as_str() {
        return Some(value.into());
    }
    value.as_array().map(|parts| {
        parts
            .iter()
            .filter(|part| part["type"] == "text")
            .filter_map(|part| part["text"].as_str())
            .collect::<Vec<_>>()
            .join("")
    })
}

fn finish(value: Option<&str>) -> Result<bool, String> {
    match value {
        None => Ok(false),
        Some("stop") => Ok(true),
        Some("length") => {
            Err("The translation exceeded the response limit. Select a smaller area.".into())
        }
        Some("content_filter") => Err("The service could not translate this content.".into()),
        _ => Err("The model stopped before the translation was complete. Try again.".into()),
    }
}

pub fn parse_line(line: &str) -> Result<(Option<String>, bool), String> {
    let Some(payload) = line.strip_prefix("data:").map(str::trim) else {
        return Ok((None, false));
    };
    if payload == "[DONE]" {
        return Ok((None, true));
    }
    if payload.is_empty() {
        return Ok((None, false));
    }
    let event: Value = serde_json::from_str(payload)
        .map_err(|_| "The translation stream is incomplete. Try again.")?;
    if event.get("error").is_some() {
        return Err(
            "The API returned an error. Check the model, credit and service settings.".into(),
        );
    }
    let Some(choice) = event["choices"]
        .as_array()
        .and_then(|choices| choices.first())
    else {
        return Ok((None, false));
    };
    if choice["delta"]["refusal"]
        .as_str()
        .is_some_and(|value| !value.is_empty())
    {
        return Err("The model could not translate this content.".into());
    }
    let done = finish(choice["finish_reason"].as_str())?;
    Ok((content(&choice["delta"]["content"]), done))
}

pub fn parse_complete(data: &[u8]) -> Result<String, String> {
    let event: Value = serde_json::from_slice(data).map_err(|_| "The API response is invalid.")?;
    if event.get("error").is_some() {
        return Err("The API returned an error. Check the service settings.".into());
    }
    let choice = event["choices"]
        .as_array()
        .and_then(|choices| choices.first())
        .ok_or("The API returned no translation.")?;
    if !finish(choice["finish_reason"].as_str())? {
        return Err("The API returned an incomplete translation.".into());
    }
    content(&choice["message"]["content"])
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| "The API returned no translation.".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        io::{Read, Write},
        net::TcpListener,
        thread,
    };

    const MANDATORY_REASONING: &str = r#"{"error":{"message":"Reasoning is mandatory for this endpoint and cannot be disabled.","code":400}}"#;

    fn server(responses: Vec<(u16, String)>) -> (String, thread::JoinHandle<Vec<Value>>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let address = format!("http://{}/v1", listener.local_addr().unwrap());
        listener.set_nonblocking(true).unwrap();
        let handle = thread::spawn(move || {
            let mut requests = Vec::new();
            for (status, body) in responses {
                let deadline = std::time::Instant::now() + Duration::from_secs(5);
                let mut stream = loop {
                    match listener.accept() {
                        Ok((stream, _)) => break stream,
                        Err(error)
                            if error.kind() == std::io::ErrorKind::WouldBlock
                                && std::time::Instant::now() < deadline =>
                        {
                            thread::sleep(Duration::from_millis(5))
                        }
                        other => panic!("Expected fixture request: {other:?}"),
                    }
                };
                // Windows inherits the listener's nonblocking mode on accept.
                // The fixture bounds accept above, then uses timed blocking IO.
                stream.set_nonblocking(false).unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                stream
                    .set_write_timeout(Some(Duration::from_secs(5)))
                    .unwrap();
                let mut incoming = Vec::new();
                let header_end = loop {
                    let mut chunk = [0; 4096];
                    let count = stream.read(&mut chunk).unwrap();
                    assert_ne!(count, 0);
                    incoming.extend_from_slice(&chunk[..count]);
                    if let Some(index) = incoming.windows(4).position(|value| value == b"\r\n\r\n")
                    {
                        break index + 4;
                    }
                };
                let headers = std::str::from_utf8(&incoming[..header_end])
                    .unwrap()
                    .to_ascii_lowercase();
                let length: usize = headers
                    .lines()
                    .find_map(|line| line.strip_prefix("content-length:"))
                    .unwrap()
                    .trim()
                    .parse()
                    .unwrap();
                while incoming.len() - header_end < length {
                    let mut chunk = [0; 4096];
                    let count = stream.read(&mut chunk).unwrap();
                    assert_ne!(count, 0);
                    incoming.extend_from_slice(&chunk[..count]);
                }
                requests.push(
                    serde_json::from_slice(&incoming[header_end..header_end + length]).unwrap(),
                );
                write!(stream, "HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            }
            requests
        });
        (address, handle)
    }

    #[test]
    fn reasoning_retry_only_relaxes_an_explicit_disable_rejection() {
        let original = json!({"model":"minimax/minimax-m3.1-flash:free","reasoning":{"enabled":false},"provider":{"allow_fallbacks":false},"messages":[{"role":"user","content":"fixture"}]});
        let retried = mandatory_reasoning_body(&original, MANDATORY_REASONING.as_bytes()).unwrap();
        assert_eq!(retried["reasoning"], json!({"exclude":true}));
        let mut expected = original.clone();
        expected["reasoning"] = json!({"exclude":true});
        assert_eq!(retried, expected);
        assert!(mandatory_reasoning_body(&retried, MANDATORY_REASONING.as_bytes()).is_none());
        for error in [
            r#"{"error":{"message":"Unknown model"}}"#,
            r#"{"error":{"message":"Unsupported parameter: reasoning"}}"#,
            r#"{"error":{"message":"Reasoning is mandatory"}}"#,
            "Reasoning is mandatory and cannot be disabled.",
            "malformed",
        ] {
            assert!(mandatory_reasoning_body(&original, error.as_bytes()).is_none());
        }
    }

    #[tokio::test]
    async fn mandatory_reasoning_retries_same_model_without_exposing_reasoning() {
        let response = r#"{"choices":[{"message":{"content":"你好。","reasoning":"private fixture reasoning"},"finish_reason":"stop"}]}"#;
        let (address, server) = server(vec![
            (400, MANDATORY_REASONING.into()),
            (200, response.into()),
        ]);
        let result = translate(
            "openrouter",
            &address,
            "minimax/minimax-m3.1-flash:free",
            "fixture-key",
            "Translate",
            "Hello",
            &|value| assert_eq!(value, "你好。"),
        )
        .await
        .unwrap();
        assert_eq!(result, "你好。");
        let requests = server.join().unwrap();
        assert_eq!(requests.len(), 2);
        assert_eq!(requests[0]["reasoning"], json!({"enabled":false}));
        let mut expected = requests[0].clone();
        expected["reasoning"] = json!({"exclude":true});
        assert_eq!(requests[1], expected);
    }

    #[tokio::test]
    async fn invalid_models_and_non_openrouter_errors_are_never_retried() {
        for (provider, error) in [
            (
                "openrouter",
                r#"{"error":{"message":"Invalid model identifier"}}"#,
            ),
            ("customAPI", MANDATORY_REASONING),
        ] {
            let (address, server) = server(vec![(400, error.into())]);
            let error = translate(
                provider,
                &address,
                "fixture",
                "fixture-key",
                "Translate",
                "Hello",
                &|_| panic!("No failed-request delta"),
            )
            .await
            .unwrap_err();
            assert!(error.contains("HTTP 400"));
            assert!(!error.contains("Invalid model identifier"));
            assert_eq!(server.join().unwrap().len(), 1);
        }
    }

    #[tokio::test]
    async fn a_second_disable_rejection_is_not_retried_again() {
        let (address, server) = server(vec![
            (400, MANDATORY_REASONING.into()),
            (400, MANDATORY_REASONING.into()),
        ]);
        let error = translate(
            "openrouter",
            &address,
            "fixture",
            "fixture-key",
            "Translate",
            "Hello",
            &|_| panic!("No failed-request delta"),
        )
        .await
        .unwrap_err();
        assert!(error.contains("HTTP 400"));
        assert_eq!(server.join().unwrap().len(), 2);
    }

    #[tokio::test]
    async fn oversized_reasoning_errors_are_not_retried_or_exposed() {
        // This remains valid JSON containing the exact retry trigger. Only the
        // size bound should prevent a retry, rather than malformed JSON.
        let mut error = MANDATORY_REASONING.to_owned();
        error.push_str(&" ".repeat(MAXIMUM_ERROR_BYTES + 1));
        let (address, server) = server(vec![(400, error)]);
        let error = translate(
            "openrouter",
            &address,
            "fixture",
            "fixture-key",
            "Translate",
            "Hello",
            &|_| panic!("No failed-request delta"),
        )
        .await
        .unwrap_err();
        assert!(error.contains("HTTP 400"));
        assert!(!error.contains("Reasoning is mandatory"));
        assert_eq!(server.join().unwrap().len(), 1);
    }

    #[test]
    fn endpoints_refuse_unencrypted_remote_and_credentials() {
        assert!(endpoint("customAPI", "http://example.com/v1").is_err());
        assert!(endpoint("customAPI", "https://user:secret@example.com").is_err());
        assert!(endpoint("customAPI", "https://example.com/#fragment").is_err());
        assert!(endpoint("customAPI", "http://127.2.3.4:8080/v1").is_ok());
        assert!(endpoint("customAPI", "http://[::1]:8080/v1").is_ok());
        assert_eq!(
            endpoint("customAPI", "https://example.com/v1/")
                .unwrap()
                .as_str(),
            "https://example.com/v1/chat/completions"
        );
    }
    #[test]
    fn streaming_never_silently_accepts_truncation() {
        assert_eq!(
            parse_line(
                "data: {\"choices\":[{\"delta\":{\"content\":\"译文\"},\"finish_reason\":null}]}"
            )
            .unwrap(),
            (Some("译文".into()), false)
        );
        assert!(parse_line("data: {\"choices\":[{\"finish_reason\":\"length\"}]}").is_err());
        assert!(parse_line("data: {\"error\":{\"message\":\"secret\"}}")
            .unwrap_err()
            .find("secret")
            .is_none());
        assert!(parse_complete(
            br#"{"choices":[{"message":{"content":"partial"},"finish_reason":null}]}"#
        )
        .is_err());
    }
}

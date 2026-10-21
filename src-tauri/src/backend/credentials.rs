//! API keys live only in Windows Credential Manager, scoped to provider and
//! the exact normalized endpoint. They are never serialized into app settings.
use sha2::{Digest, Sha256};

pub fn account(provider: &str, base_url: &str) -> Result<String, String> {
    let mut endpoint = super::api::endpoint(provider, base_url)?;
    let mut query: Vec<(String, String)> = endpoint
        .query_pairs()
        .map(|(key, value)| (key.into(), value.into()))
        .collect();
    query.sort();
    if !query.is_empty() {
        endpoint.query_pairs_mut().clear().extend_pairs(query);
    }
    Ok(format!(
        "{}:{:x}",
        provider,
        Sha256::digest(endpoint.as_str().as_bytes())
    ))
}

#[cfg(target_os = "windows")]
fn entry(provider: &str, base_url: &str) -> Result<keyring::Entry, String> {
    keyring::Entry::new("Transpose", &account(provider, base_url)?)
        .map_err(|_| "Unable to access Windows Credential Manager.".into())
}

#[cfg(target_os = "windows")]
pub fn read(provider: &str, base_url: &str) -> Result<Option<String>, String> {
    match entry(provider, base_url)?.get_password() {
        Ok(password) => Ok(Some(password)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(_) => Err("Unable to read this key from Windows Credential Manager.".into()),
    }
}

#[cfg(target_os = "windows")]
pub fn save(provider: &str, base_url: &str, value: &str) -> Result<(), String> {
    let value = value.trim();
    if value.is_empty() || value.len() > 16_384 || value.contains(['\r', '\n', '\0']) {
        return Err("Enter a valid API key.".into());
    }
    entry(provider, base_url)?
        .set_password(value)
        .map_err(|_| "Unable to save this key in Windows Credential Manager.".into())
}

#[cfg(target_os = "windows")]
pub fn remove(provider: &str, base_url: &str) -> Result<(), String> {
    match entry(provider, base_url)?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(_) => Err("Unable to remove this key from Windows Credential Manager.".into()),
    }
}

// Non-Windows builds can exercise prompt, validation and wire-parser tests
// without touching the Mac keychain or introducing an alternate secret store.
#[cfg(not(target_os = "windows"))]
pub fn read(_provider: &str, _base_url: &str) -> Result<Option<String>, String> {
    Ok(None)
}
#[cfg(not(target_os = "windows"))]
pub fn save(_provider: &str, _base_url: &str, _value: &str) -> Result<(), String> {
    Err("Windows Credential Manager is unavailable on this platform.".into())
}
#[cfg(not(target_os = "windows"))]
pub fn remove(_provider: &str, _base_url: &str) -> Result<(), String> {
    Err("Windows Credential Manager is unavailable on this platform.".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn credential_identity_is_endpoint_and_provider_scoped() {
        assert_eq!(
            account("customAPI", "https://EXAMPLE.com:443/v1/").unwrap(),
            account("customAPI", "https://example.com/v1").unwrap()
        );
        assert_ne!(
            account("customAPI", "https://example.com/v1").unwrap(),
            account("customAPI", "https://other.example/v1").unwrap()
        );
        assert_ne!(
            account("deepseek", "https://api.deepseek.com").unwrap(),
            account("customAPI", "https://api.deepseek.com").unwrap()
        );
        assert!(account("customAPI", "https://user:password@example.com").is_err());
    }

    #[cfg(target_os = "windows")]
    #[test]
    fn windows_credential_manager_roundtrips_an_isolated_test_entry() {
        let endpoint = format!(
            "http://localhost:18080/transpose-test-{}",
            uuid::Uuid::new_v4()
        );
        let key = format!("transpose-fixture-{}", uuid::Uuid::new_v4());
        save("customAPI", &endpoint, &key).unwrap();
        let saved = read("customAPI", &endpoint).unwrap();
        // Remove the isolated entry before assertions so fixture failures never
        // leave a credential behind in an interactive developer account.
        remove("customAPI", &endpoint).unwrap();
        assert_eq!(saved.as_deref(), Some(key.as_str()));
        assert_eq!(read("customAPI", &endpoint).unwrap(), None);
    }
}

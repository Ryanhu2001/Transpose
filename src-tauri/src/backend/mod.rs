//! Windows bridge backend. The Swift bridge remains the sole macOS backend.
//! Public snapshots contain credential metadata only, never API-key values.
pub mod api;
pub mod cli;
pub mod credentials;
pub mod glossary;
pub mod settings;

use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, VecDeque},
    path::PathBuf,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::Instant,
};
use tokio::task::JoinHandle;

type Emitter = Arc<dyn Fn(Value) + Send + Sync>;

struct Data {
    settings: settings::Settings,
    detected: Vec<Value>,
    result: Option<Value>,
    credential_status: String,
    connection_status: String,
    testing_connection: bool,
    glossary_status: String,
    ocr: bool,
    login_enabled: bool,
    cache: HashMap<String, String>,
    recency: VecDeque<String>,
}

pub struct Backend {
    path: PathBuf,
    smoke_test: bool,
    data: Mutex<Data>,
    emitter: Mutex<Option<Emitter>>,
    settings_transaction: Mutex<()>,
    translation_transaction: Mutex<()>,
    translation_task: Mutex<Option<JoinHandle<()>>>,
    generation: AtomicU64,
    configuration_generation: AtomicU64,
}

impl Backend {
    pub fn new(directory: PathBuf, smoke_test: bool) -> Result<Self, String> {
        let path = directory.join("settings.json");
        let mut settings = if smoke_test {
            settings::Settings::default()
        } else {
            settings::Settings::load(&path)?
        };
        if smoke_test {
            settings.language = "english".into();
        }
        Ok(Self {
            path,
            smoke_test,
            data: Mutex::new(Data {
                settings,
                detected: if smoke_test {
                    Vec::new()
                } else {
                    cli::discover()
                },
                result: None,
                credential_status: String::new(),
                connection_status: String::new(),
                testing_connection: false,
                glossary_status: String::new(),
                ocr: false,
                login_enabled: false,
                cache: HashMap::new(),
                recency: VecDeque::new(),
            }),
            emitter: Mutex::new(None),
            settings_transaction: Mutex::new(()),
            translation_transaction: Mutex::new(()),
            translation_task: Mutex::new(None),
            generation: AtomicU64::new(0),
            configuration_generation: AtomicU64::new(0),
        })
    }

    pub fn set_emitter(&self, emitter: Emitter) {
        *self.emitter.lock().unwrap() = Some(emitter);
    }
    fn emit(&self, value: Value) {
        let emitter = self.emitter.lock().unwrap().clone();
        if let Some(emitter) = emitter {
            emitter(value);
        }
    }
    fn publish_snapshot(&self) {
        self.emit(json!({"type":"snapshot","data":self.state()["app"]}));
    }
    fn publish_result(&self) {
        let result = self.data.lock().unwrap().result.clone();
        self.emit(json!({"type":"result","data":result}));
    }

    pub fn automatic_selection(&self) -> bool {
        self.data.lock().unwrap().settings.automatic_selection
    }
    pub fn result_output(&self) -> Option<String> {
        self.data
            .lock()
            .unwrap()
            .result
            .as_ref()
            .and_then(|result| result["output"].as_str())
            .filter(|value| !value.is_empty())
            .map(str::to_owned)
    }
    pub fn result_pinned(&self) -> bool {
        self.data
            .lock()
            .unwrap()
            .result
            .as_ref()
            .is_some_and(|result| result["isPinned"] == true)
    }
    pub fn set_platform_status(&self, ocr: bool, login_enabled: bool) {
        {
            let mut data = self.data.lock().unwrap();
            data.ocr = ocr;
            data.login_enabled = login_enabled;
        }
        self.publish_snapshot();
    }

    pub fn state(&self) -> Value {
        let data = self.data.lock().unwrap();
        let settings = &data.settings;
        let connection = settings.connection();
        let key_is_saved = !self.smoke_test
            && settings::is_api(&settings.provider)
            && credentials::read(&settings.provider, &connection.base_url)
                .ok()
                .flatten()
                .is_some();
        let credential_status = if data.credential_status.is_empty() && key_is_saved {
            if settings.english() {
                "API key saved in Windows Credential Manager"
            } else {
                "API Key 已保存在 Windows 凭据管理器"
            }
        } else {
            data.credential_status.as_str()
        };
        let apple_status = if settings.english() {
            "Apple Translation is available on macOS only."
        } else {
            "Apple 翻译仅在 macOS 上可用。"
        };
        json!({"app": {
            "version":env!("CARGO_PKG_VERSION"),"platform":"windows",
            "capabilities":{"selection":true,"screenCapture":true,"ocr":data.ocr,
                "ocrStatus":if data.ocr { "" } else { "Install a Windows OCR language pack to recognize screen text." }},
            "language":settings.language,"locale":if settings.english(){"en"}else{"zh-Hans"},
            "settings":{"provider":settings.provider,"target":settings.target,"automaticSelection":settings.automatic_selection,
                "preferences":settings.preferences,"baseURL":connection.base_url,"model":connection.model,"cliPath":connection.cli_path,"keyIsSaved":key_is_saved},
            "providers":settings::providers(),"glossary":settings.glossary,"detectedCLIs":data.detected,
            "permissions":{"accessibility":true,"screenRecording":true,"screenRecordingNeedsRestart":false},
            "loginItem":{"status":if data.login_enabled{"enabled"}else{"notRegistered"}},
            "apple":{"supported":false,"status":apple_status},
            "status":{"credential":credential_status,"connection":data.connection_status,"testingConnection":data.testing_connection,"glossary":data.glossary_status}
        },"result":data.result})
    }

    fn save_settings(&self, settings: settings::Settings) -> Result<(), String> {
        settings.validate()?;
        if !self.smoke_test {
            settings.save(&self.path)?;
        }
        {
            let mut data = self.data.lock().unwrap();
            self.configuration_generation.fetch_add(1, Ordering::SeqCst);
            data.settings = settings;
            data.connection_status.clear();
            data.testing_connection = false;
            data.credential_status.clear();
        }
        Ok(())
    }

    pub async fn request(self: &Arc<Self>, action: &str, payload: Value) -> Result<Value, String> {
        if !payload.is_object() {
            return Err("Invalid request format.".into());
        }
        if self.smoke_test && action != "snapshot" {
            return Err("This action is unavailable during the smoke test.".into());
        }
        match action {
            "snapshot" => return Ok(self.state()),
            "update_settings" => {
                let _transaction = self.settings_transaction.lock().unwrap();
                let mut next = self.data.lock().unwrap().settings.clone();
                if ["baseURL", "model", "cliPath"]
                    .iter()
                    .any(|field| payload.get(*field).is_some())
                    && settings::string(&payload, "expectedProvider", 40)? != next.provider
                {
                    return Err("The connection changed. Try again.".into());
                }
                if payload.get("target").is_some() {
                    next.target = settings::string(&payload, "target", 40)?;
                }
                if let Some(value) = payload.get("automaticSelection") {
                    next.automatic_selection = value.as_bool().ok_or("Invalid switch value.")?;
                }
                if payload.get("preferences").is_some() {
                    next.preferences = settings::string(&payload, "preferences", 8_000)?;
                }
                let mut connection = next.connection();
                if payload.get("baseURL").is_some() {
                    connection.base_url = settings::string(&payload, "baseURL", 2_048)?;
                }
                if payload.get("model").is_some() {
                    connection.model = settings::string(&payload, "model", 240)?;
                }
                if payload.get("cliPath").is_some() {
                    connection.cli_path = settings::string(&payload, "cliPath", 4_096)?;
                }
                next.connections.insert(next.provider.clone(), connection);
                self.save_settings(next)?;
            }
            "provider_select" => {
                let _transaction = self.settings_transaction.lock().unwrap();
                let provider = settings::string(&payload, "provider", 40)?;
                if !settings::PROVIDERS.contains(&provider.as_str()) {
                    return Err("This translation service is unavailable on Windows.".into());
                }
                let mut next = self.data.lock().unwrap().settings.clone();
                next.provider = provider;
                self.save_settings(next)?;
            }
            "set_language" => {
                let _transaction = self.settings_transaction.lock().unwrap();
                let mut next = self.data.lock().unwrap().settings.clone();
                next.language = settings::string(&payload, "language", 40)?;
                self.save_settings(next)?;
            }
            "key_save" | "key_remove" => {
                let _transaction = self.settings_transaction.lock().unwrap();
                let settings = self.data.lock().unwrap().settings.clone();
                let connection = settings.connection();
                validate_credential_context(&payload, &settings.provider, &connection.base_url)?;
                if !settings::is_api(&settings.provider) {
                    return Err("This service does not require an API key.".into());
                }
                if action == "key_save" {
                    credentials::save(
                        &settings.provider,
                        &connection.base_url,
                        &settings::string(&payload, "key", 4096)?,
                    )?;
                } else {
                    credentials::remove(&settings.provider, &connection.base_url)?;
                }
                {
                    let mut data = self.data.lock().unwrap();
                    self.configuration_generation.fetch_add(1, Ordering::SeqCst);
                    data.credential_status = if action == "key_save" {
                        if settings.english() {
                            "Saved in Windows Credential Manager"
                        } else {
                            "已保存到 Windows 凭据管理器"
                        }
                    } else if settings.english() {
                        "API key removed from this connection"
                    } else {
                        "已移除此连接的 API Key"
                    }
                    .into();
                    data.connection_status.clear();
                    data.testing_connection = false;
                }
            }
            "connection_test" => {
                let _transaction = self.settings_transaction.lock().unwrap();
                let settings = self.data.lock().unwrap().settings.clone();
                if payload.get("expectedProvider").is_some()
                    && settings::string(&payload, "expectedProvider", 40)? != settings.provider
                {
                    return Err("The connection changed. Try again.".into());
                }
                self.test_connection(settings);
            }
            "cli_scan" => {
                let detected = cli::discover();
                self.data.lock().unwrap().detected = detected;
            }
            "glossary_upsert" => {
                let _transaction = self.settings_transaction.lock().unwrap();
                let entry: glossary::GlossaryEntry = serde_json::from_value(
                    payload
                        .get("entry")
                        .cloned()
                        .ok_or("Invalid glossary entry.")?,
                )
                .map_err(|_| "Invalid glossary entry.")?;
                let mut next = self.data.lock().unwrap().settings.clone();
                next.glossary = glossary::upsert(&next.glossary, entry)?;
                self.save_settings(next)?;
            }
            "glossary_delete" => {
                let _transaction = self.settings_transaction.lock().unwrap();
                let id = settings::string(&payload, "id", 40)?;
                uuid::Uuid::parse_str(&id).map_err(|_| "Invalid glossary entry ID.")?;
                let mut next = self.data.lock().unwrap().settings.clone();
                next.glossary.retain(|entry| entry.id != id);
                self.save_settings(next)?;
            }
            "glossary_import" => self.import_glossary().await?,
            "glossary_export" => self.export_glossary().await?,
            "translate" => {
                return self.translate_text(
                    settings::string(&payload, "text", 60_000)?,
                    "Try Translation".into(),
                )
            }
            "result_retry" => {
                let result = self
                    .data
                    .lock()
                    .unwrap()
                    .result
                    .clone()
                    .ok_or("There is no translation to retry.")?;
                if result["canRetry"] != true {
                    return Err("There is no translation to retry.".into());
                }
                return self.translate_text(
                    result["source"].as_str().unwrap_or_default().into(),
                    result["sourceApp"].as_str().unwrap_or_default().into(),
                );
            }
            "result_pin" => {
                let pinned = payload["pinned"].as_bool().ok_or("Invalid switch value.")?;
                if let Some(result) = self.data.lock().unwrap().result.as_mut() {
                    result["isPinned"] = pinned.into();
                }
                self.publish_result();
            }
            "result_close" => {
                let _transaction = self.translation_transaction.lock().unwrap();
                self.cancel_current_translation();
                self.data.lock().unwrap().result = None;
                self.publish_result();
            }
            "apple_prepare" => return Err("Apple Translation is available on macOS only.".into()),
            "capture" | "permission" | "login_set" | "login_settings" | "result_copy"
            | "open_settings" | "open_external" | "app_restart" | "app_quit" => {
                return Err(
                    "This system action must be handled by the Windows application host.".into(),
                );
            }
            _ => return Err("This action is unavailable.".into()),
        }
        self.publish_snapshot();
        Ok(self.state())
    }

    pub fn cancel_translation(&self) {
        let _transaction = self.translation_transaction.lock().unwrap();
        self.cancel_current_translation();
    }

    fn cancel_current_translation(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        if let Some(task) = self.translation_task.lock().unwrap().take() {
            task.abort();
        }
    }

    pub fn show_recognizing(&self) {
        let _transaction = self.translation_transaction.lock().unwrap();
        self.cancel_current_translation();
        let english = self.data.lock().unwrap().settings.english();
        let mut result = initial_result("", "Screen Selection", "", "", false, english);
        result["loadingMessage"] = if english {
            "Recognizing text…"
        } else {
            "正在识别文字…"
        }
        .into();
        self.data.lock().unwrap().result = Some(result);
        self.publish_result();
    }

    pub fn show_error(&self, message: String) {
        let _transaction = self.translation_transaction.lock().unwrap();
        self.cancel_current_translation();
        {
            let mut data = self.data.lock().unwrap();
            let english = data.settings.english();
            let result = data.result.get_or_insert_with(|| {
                initial_result("", "Screen Selection", "", "", false, english)
            });
            result["isLoading"] = false.into();
            result["error"] = message.into();
        }
        self.publish_result();
    }

    /// Starts a translation and returns immediately, allowing the existing
    /// result UI to render streamed deltas without blocking a bridge request.
    pub fn translate_text(
        self: &Arc<Self>,
        text: String,
        source_app: String,
    ) -> Result<Value, String> {
        let _transaction = self.translation_transaction.lock().unwrap();
        let text = text.trim().to_owned();
        if text.is_empty() {
            return Err("No text was found to translate.".into());
        }
        settings::validate_string(&text, 60_000)?;
        self.cancel_current_translation();
        let generation = self.generation.load(Ordering::SeqCst);
        let settings = self.data.lock().unwrap().settings.clone();
        let target = settings::target_for(&settings.target, &text);
        let pinned = self.result_pinned();
        self.data.lock().unwrap().result = Some(initial_result(
            &text,
            &source_app,
            target,
            settings::title(&settings.provider),
            pinned,
            settings.english(),
        ));
        self.publish_result();
        let backend = Arc::clone(self);
        let task = tokio::spawn(async move {
            let start = Instant::now();
            let response = backend
                .perform_translation(&settings, &text, |output| {
                    {
                        let mut data = backend.data.lock().unwrap();
                        if backend.generation.load(Ordering::SeqCst) != generation {
                            return;
                        }
                        if let Some(result) = data.result.as_mut() {
                            result["output"] = output.into();
                        }
                    }
                    backend.publish_result();
                })
                .await;
            {
                let mut data = backend.data.lock().unwrap();
                if backend.generation.load(Ordering::SeqCst) != generation {
                    return;
                }
                if let Some(result) = data.result.as_mut() {
                    result["isLoading"] = false.into();
                    match response {
                        Ok(output) => {
                            result["output"] = output.into();
                            result["error"] = Value::Null;
                            result["status"] = format!(
                                "{} · {:.1} {}",
                                settings::title(&settings.provider),
                                start.elapsed().as_secs_f32(),
                                if settings.english() { "s" } else { "秒" }
                            )
                            .into();
                        }
                        Err(error) => {
                            result["error"] = error.into();
                            result["status"] = settings::title(&settings.provider).into();
                        }
                    }
                }
            }
            backend.publish_result();
        });
        *self.translation_task.lock().unwrap() = Some(task);
        Ok(self.state())
    }

    async fn perform_translation(
        &self,
        settings: &settings::Settings,
        text: &str,
        on_delta: impl Fn(String) + Send + Sync,
    ) -> Result<String, String> {
        let connection = settings.connection();
        let key = if settings::is_api(&settings.provider) {
            credentials::read(&settings.provider, &connection.base_url)?.unwrap_or_default()
        } else {
            String::new()
        };
        let prompt = glossary::build_prompt(
            settings::target_for(&settings.target, text),
            &settings.preferences,
            &settings.glossary,
            text,
        );
        let scope = json!([
            settings.provider,
            connection.base_url,
            connection.model,
            connection.cli_path,
            prompt,
            text,
            format!("{:x}", Sha256::digest(key.as_bytes()))
        ])
        .to_string();
        let identity = format!("{:x}", Sha256::digest(scope.as_bytes()));
        let cached = self.data.lock().unwrap().cache.get(&identity).cloned();
        if let Some(cached) = cached {
            on_delta(cached.clone());
            return Ok(cached);
        }
        let output = if settings::is_api(&settings.provider) {
            api::translate(
                &settings.provider,
                &connection.base_url,
                &connection.model,
                &key,
                &prompt,
                text,
                &on_delta,
            )
            .await?
        } else {
            cli::translate(
                &settings.provider,
                &connection.cli_path,
                &connection.model,
                &prompt,
                text,
                &on_delta,
            )
            .await?
        };
        {
            let mut data = self.data.lock().unwrap();
            data.cache.insert(identity.clone(), output.clone());
            data.recency.push_back(identity);
            while data.recency.len() > 96
                || data.cache.values().map(String::len).sum::<usize>() > 1_000_000
            {
                if let Some(oldest) = data.recency.pop_front() {
                    data.cache.remove(&oldest);
                } else {
                    break;
                }
            }
        }
        Ok(output)
    }

    fn test_connection(self: &Arc<Self>, settings: settings::Settings) {
        let generation = self.configuration_generation.fetch_add(1, Ordering::SeqCst) + 1;
        {
            let mut data = self.data.lock().unwrap();
            data.testing_connection = true;
            data.connection_status = if settings.english() {
                "Translating a short sentence…"
            } else {
                "正在试译一句…"
            }
            .into();
        }
        let backend = Arc::clone(self);
        tokio::spawn(async move {
            let start = Instant::now();
            let output = backend
                .perform_translation(&settings, "A little clarity goes a long way.", |_| {})
                .await;
            {
                let mut data = backend.data.lock().unwrap();
                if backend.configuration_generation.load(Ordering::SeqCst) != generation {
                    return;
                }
                data.testing_connection = false;
                data.connection_status = match output {
                    Ok(output) => format!(
                        "{} · {:.1} s\n{}",
                        if settings.english() {
                            "Connected"
                        } else {
                            "连接成功"
                        },
                        start.elapsed().as_secs_f32(),
                        output
                    ),
                    Err(error) => error,
                };
            }
            backend.publish_snapshot();
        });
    }

    #[cfg(target_os = "windows")]
    async fn import_glossary(&self) -> Result<(), String> {
        let Some(file) = rfd::AsyncFileDialog::new()
            .set_title("Import glossary")
            .add_filter("Glossary", &["json", "csv", "tsv", "txt"])
            .pick_file()
            .await
        else {
            return Ok(());
        };
        let metadata = tokio::fs::metadata(file.path())
            .await
            .map_err(|_| "Unable to read the glossary file.")?;
        if metadata.len() > 2_000_000 {
            return Err("The glossary file exceeds 2 MB.".into());
        }
        let bytes = tokio::fs::read(file.path())
            .await
            .map_err(|_| "Unable to read the glossary file.")?;
        let format = file
            .path()
            .extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or("tsv");
        let incoming = glossary::parse(&bytes, format)?;
        let count = incoming.len();
        let _transaction = self.settings_transaction.lock().unwrap();
        let mut next = self.data.lock().unwrap().settings.clone();
        next.glossary = glossary::import_entries(&next.glossary, &incoming)?;
        self.save_settings(next)?;
        self.data.lock().unwrap().glossary_status = format!("Imported {count} terms");
        Ok(())
    }
    #[cfg(not(target_os = "windows"))]
    async fn import_glossary(&self) -> Result<(), String> {
        Err("Windows file dialog is unavailable.".into())
    }

    #[cfg(target_os = "windows")]
    async fn export_glossary(&self) -> Result<(), String> {
        let data = { glossary::export_json(&self.data.lock().unwrap().settings.glossary)? };
        let Some(file) = rfd::AsyncFileDialog::new()
            .set_title("Export glossary")
            .set_file_name("transpose-glossary.json")
            .add_filter("JSON", &["json"])
            .save_file()
            .await
        else {
            return Ok(());
        };
        tokio::fs::write(file.path(), data.as_bytes())
            .await
            .map_err(|_| "Unable to export the glossary.")?;
        self.data.lock().unwrap().glossary_status = "Glossary exported".into();
        Ok(())
    }
    #[cfg(not(target_os = "windows"))]
    async fn export_glossary(&self) -> Result<(), String> {
        Err("Windows file dialog is unavailable.".into())
    }
}

fn initial_result(
    source: &str,
    source_app: &str,
    target: &str,
    provider: &str,
    pinned: bool,
    english: bool,
) -> Value {
    let language = match target {
        "Simplified Chinese" if !english => "简体中文",
        "English" if !english => "英语",
        "Japanese" if !english => "日本語",
        _ => target,
    };
    json!({"id":uuid::Uuid::new_v4().to_string(),"source":source,"sourceApp":source_app,
        "sourceLanguage":if english{"Auto"}else{"自动检测"},"targetLanguage":language,
        "output":"","isLoading":true,"loadingMessage":if english{"Translating…"}else{"正在翻译…"},
        "error":null,"status":provider,"provider":provider,"isPinned":pinned,"canRetry":!source.is_empty()})
}

fn validate_credential_context(
    payload: &Value,
    provider: &str,
    base_url: &str,
) -> Result<(), String> {
    if settings::string(payload, "provider", 40)? != provider
        || settings::string(payload, "baseURL", 2048)? != base_url
    {
        return Err("The connection changed. Try again.".into());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_credential_saves_are_rejected() {
        assert!(validate_credential_context(
            &json!({"provider":"deepseek","baseURL":"https://api.deepseek.com"}),
            "deepseek",
            "https://api.deepseek.com"
        )
        .is_ok());
        assert!(validate_credential_context(
            &json!({"provider":"customAPI","baseURL":"https://api.deepseek.com"}),
            "deepseek",
            "https://api.deepseek.com"
        )
        .is_err());
        assert!(validate_credential_context(
            &json!({"provider":"deepseek","baseURL":"https://evil.example"}),
            "deepseek",
            "https://api.deepseek.com"
        )
        .is_err());
    }
    #[tokio::test]
    async fn smoke_snapshots_do_not_touch_user_files_or_accept_mutations() {
        let directory =
            std::env::temp_dir().join(format!("transpose-smoke-{}", uuid::Uuid::new_v4()));
        let backend = Arc::new(Backend::new(directory.clone(), true).unwrap());
        let state = backend.request("snapshot", json!({})).await.unwrap();
        assert_eq!(state["app"]["platform"], "windows");
        assert_eq!(state["app"]["settings"]["keyIsSaved"], false);
        assert!(state["app"]["settings"].get("apiKey").is_none());
        assert!(backend
            .request("update_settings", json!({"preferences":"mutate"}))
            .await
            .is_err());
        assert!(!directory.exists());
    }
}

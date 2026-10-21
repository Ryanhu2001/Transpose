use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{collections::HashMap, fs, path::Path};

pub const PROVIDERS: [&str; 7] = [
    "deepseek",
    "openrouter",
    "customAPI",
    "codex",
    "dsh",
    "claude",
    "kimi",
];

pub fn is_api(provider: &str) -> bool {
    matches!(provider, "deepseek" | "openrouter" | "customAPI")
}

pub fn title(provider: &str) -> &'static str {
    match provider {
        "deepseek" => "DeepSeek",
        "openrouter" => "OpenRouter",
        "customAPI" => "Custom API",
        "codex" => "Codex CLI",
        "dsh" => "DeepSeek CLI",
        "claude" => "Claude Code",
        "kimi" => "Kimi Code",
        _ => "Translation",
    }
}

pub fn default_connection(provider: &str) -> Connection {
    let (url, model) = match provider {
        "deepseek" => ("https://api.deepseek.com", "deepseek-flash"),
        "openrouter" => ("https://openrouter.ai/api/v1", "openrouter/free"),
        "customAPI" => ("http://localhost:11434/v1", ""),
        "codex" => ("", "gpt-6-luna"),
        _ => ("", ""),
    };
    Connection {
        base_url: url.into(),
        model: model.into(),
        cli_path: String::new(),
    }
}

pub fn providers() -> Vec<Value> {
    PROVIDERS
        .iter()
        .map(|id| {
            let connection = default_connection(id);
            json!({"id":id,"title":title(id),"isAPI":is_api(id),"isCLI":!is_api(id),
            "defaultBaseURL":connection.base_url,"defaultModel":connection.model})
        })
        .collect()
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Connection {
    pub base_url: String,
    pub model: String,
    pub cli_path: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    pub provider: String,
    pub target: String,
    pub automatic_selection: bool,
    pub preferences: String,
    pub language: String,
    pub connections: HashMap<String, Connection>,
    pub glossary: Vec<super::glossary::GlossaryEntry>,
}

impl Default for Settings {
    fn default() -> Self {
        Self {
            provider: "deepseek".into(),
            target: "smart".into(),
            automatic_selection: true,
            preferences: String::new(),
            language: "system".into(),
            connections: HashMap::new(),
            glossary: Vec::new(),
        }
    }
}

impl Settings {
    pub fn load(path: &Path) -> Result<Self, String> {
        if !path.exists() {
            return Ok(Self::default());
        }
        let metadata = fs::metadata(path).map_err(|_| "Unable to read settings.")?;
        if metadata.len() > 4_000_000 {
            return Err("The settings file is too large.".into());
        }
        let data = fs::read(path).map_err(|_| "Unable to read settings.")?;
        let value: Self =
            serde_json::from_slice(&data).map_err(|_| "The settings file is invalid.")?;
        value.validate()?;
        Ok(value)
    }

    pub fn save(&self, path: &Path) -> Result<(), String> {
        self.validate()?;
        let parent = path.parent().ok_or("Invalid settings location.")?;
        fs::create_dir_all(parent).map_err(|_| "Unable to create the settings folder.")?;
        let data = serde_json::to_vec_pretty(self).map_err(|_| "Unable to encode settings.")?;
        let temporary = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4()));
        fs::write(&temporary, &data).map_err(|_| "Unable to save settings.")?;
        // std::fs::rename replaces existing files on Windows via MoveFileExW.
        if fs::rename(&temporary, path).is_err() {
            let _ = fs::remove_file(&temporary);
            return Err("Unable to save settings.".into());
        }
        Ok(())
    }

    pub fn connection(&self) -> Connection {
        self.connections
            .get(&self.provider)
            .cloned()
            .unwrap_or_else(|| default_connection(&self.provider))
    }

    pub fn english(&self) -> bool {
        self.language == "english" || (self.language == "system" && !system_is_chinese())
    }

    pub fn validate(&self) -> Result<(), String> {
        if !PROVIDERS.contains(&self.provider.as_str()) {
            return Err("Invalid translation service.".into());
        }
        if !["smart", "simplifiedChinese", "english", "japanese"].contains(&self.target.as_str()) {
            return Err("Invalid target language.".into());
        }
        if !["system", "simplifiedChinese", "english"].contains(&self.language.as_str()) {
            return Err("Invalid app language.".into());
        }
        validate_string(&self.preferences, 8_000)?;
        for (provider, connection) in &self.connections {
            if !PROVIDERS.contains(&provider.as_str()) {
                return Err("Invalid saved service.".into());
            }
            validate_string(&connection.base_url, 2_048)?;
            validate_string(&connection.model, 240)?;
            validate_string(&connection.cli_path, 4_096)?;
        }
        super::glossary::normalize(&self.glossary)?;
        Ok(())
    }
}

#[cfg(target_os = "windows")]
fn system_is_chinese() -> bool {
    #[link(name = "kernel32")]
    extern "system" {
        fn GetUserDefaultUILanguage() -> u16;
    }
    // LANGID primary language 0x04 covers Chinese regional variants. The app
    // currently offers a single Simplified Chinese interface for all of them.
    unsafe { GetUserDefaultUILanguage() & 0x03ff == 0x0004 }
}

#[cfg(not(target_os = "windows"))]
fn system_is_chinese() -> bool {
    ["LC_ALL", "LC_MESSAGES", "LANG"]
        .iter()
        .filter_map(std::env::var_os)
        .any(|value| value.to_string_lossy().to_lowercase().starts_with("zh"))
}

pub fn validate_string(value: &str, maximum: usize) -> Result<(), String> {
    if value.contains('\0') || value.chars().count() > maximum {
        return Err("The input is invalid or too long.".into());
    }
    Ok(())
}

pub fn string(payload: &Value, key: &str, maximum: usize) -> Result<String, String> {
    let value = payload
        .get(key)
        .and_then(Value::as_str)
        .ok_or("A required text field is missing.")?;
    validate_string(value, maximum)?;
    Ok(value.to_owned())
}

pub fn target_for(target: &str, source: &str) -> &'static str {
    match target {
        "english" => "English",
        "japanese" => "Japanese",
        "simplifiedChinese" => "Simplified Chinese",
        _ => {
            let letters: Vec<char> = source
                .chars()
                .filter(|character| character.is_alphabetic())
                .collect();
            let han = letters
                .iter()
                .filter(
                    |character| matches!(**character as u32, 0x3400..=0x9fff | 0x20000..=0x323af),
                )
                .count();
            if !letters.is_empty() && han as f64 / letters.len() as f64 > 0.45 {
                "English"
            } else {
                "Simplified Chinese"
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn defaults_never_include_credentials() {
        let data = serde_json::to_value(Settings::default()).unwrap();
        assert!(data.get("apiKey").is_none());
        assert_eq!(data["provider"], "deepseek");
        assert!(!providers().iter().any(|provider| provider["id"] == "apple"));
    }
    #[test]
    fn smart_direction_is_deterministic() {
        assert_eq!(target_for("smart", "让翻译更自然。"), "English");
        assert_eq!(
            target_for("smart", "Preserve 1.25 ms."),
            "Simplified Chinese"
        );
        assert_eq!(target_for("japanese", "hello"), "Japanese");
    }
    #[test]
    fn config_rejects_invalid_values_before_writing() {
        let mut settings = Settings::default();
        settings.provider = "apple".into();
        assert!(settings.validate().is_err());
        settings.provider = "customAPI".into();
        settings.preferences = "\0".into();
        assert!(settings.validate().is_err());
    }
}

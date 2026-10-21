//! On-device OCR. The caller runs this module on a COM-initialized worker thread.
//! Pixels stay in memory; only text whose word center is inside the lasso is returned.

use windows::{
    Globalization::Language,
    Graphics::Imaging::{BitmapAlphaMode, BitmapPixelFormat, SoftwareBitmap},
    Media::Ocr::{OcrEngine, OcrResult},
    Storage::Streams::DataWriter,
};

const MISSING_LANGUAGE: &str = "Windows OCR has no language pack installed. Install a Windows Language.OCR feature for English, 中文 or 日本語 in Windows Settings or PowerShell, then try again.";
const MAX_PIXELS: u64 = 64 * 1024 * 1024;

/// Installed OCR languages, useful for setup and diagnostics. Does not download packs.
pub fn available_languages() -> Result<Vec<String>, String> {
    let languages = installed_languages()?;
    languages
        .iter()
        .map(|language| {
            language
                .LanguageTag()
                .map(|tag| tag.to_string())
                .map_err(|error| format!("Cannot read Windows OCR languages: {error}"))
        })
        .collect()
}

/// Recognizes a tightly packed, top-down BGRA bitmap and clips words to a freeform
/// polygon in bitmap coordinates. An empty polygon recognizes the whole bitmap.
pub fn recognize(
    width: u32,
    height: u32,
    bgra: Vec<u8>,
    polygon: Vec<(f64, f64)>,
) -> Result<String, String> {
    validate_input(width, height, &bgra, &polygon)?;
    let languages = installed_languages()?;
    if languages.is_empty() {
        return Err(MISSING_LANGUAGE.into());
    }

    let maximum = OcrEngine::MaxImageDimension()
        .map_err(|error| format!("Windows OCR is unavailable: {error}"))?;
    if maximum == 0 {
        return Err("Windows OCR reported an invalid image size limit.".into());
    }
    let (width, height, bgra, polygon) = fit_bitmap(width, height, bgra, polygon, maximum);
    let writer = DataWriter::new()
        .map_err(|error| format!("Cannot prepare the image for Windows OCR: {error}"))?;
    writer
        .WriteBytes(&bgra)
        .map_err(|error| format!("Cannot prepare the image for Windows OCR: {error}"))?;
    let buffer = writer
        .DetachBuffer()
        .map_err(|error| format!("Cannot prepare the image for Windows OCR: {error}"))?;
    // GDI captures can have an all-zero alpha channel. Ignore it explicitly.
    let bitmap = SoftwareBitmap::CreateCopyWithAlphaFromBuffer(
        &buffer,
        BitmapPixelFormat::Bgra8,
        width as i32,
        height as i32,
        BitmapAlphaMode::Ignore,
    )
    .map_err(|error| format!("Cannot prepare the image for Windows OCR: {error}"))?;

    let candidates = candidate_languages(languages);
    let mut best = String::new();
    let mut best_score = 0;
    let mut recognized = false;
    let mut first_error = None;
    for language in candidates {
        let attempt = (|| -> Result<String, String> {
            let engine = OcrEngine::TryCreateFromLanguage(&language)
                .map_err(|error| format!("Cannot start Windows OCR: {error}"))?;
            let result = engine
                .RecognizeAsync(&bitmap)
                .and_then(|operation| operation.join())
                .map_err(|error| format!("Windows OCR could not read this area: {error}"))?;
            selected_text(&result, &polygon)
        })();
        match attempt {
            Ok(text) => {
                recognized = true;
                let score = text_score(&text);
                // A single result wins; results from different recognizers are never
                // concatenated. Windows OCR exposes no confidence or language detector.
                if score > best_score {
                    best_score = score;
                    best = text;
                }
            }
            Err(error) => {
                first_error.get_or_insert(error);
            }
        }
    }
    let _ = bitmap.Close();
    let _ = writer.Close();
    if !best.is_empty() {
        Ok(best)
    } else if recognized {
        Err(
            "No text was found inside this area. Draw around a larger, clearer line of text."
                .into(),
        )
    } else {
        Err(first_error.unwrap_or_else(|| MISSING_LANGUAGE.into()))
    }
}

fn installed_languages() -> Result<Vec<Language>, String> {
    let languages = OcrEngine::AvailableRecognizerLanguages()
        .map_err(|error| format!("Cannot query Windows OCR language packs: {error}"))?;
    let count = languages
        .Size()
        .map_err(|error| format!("Cannot query Windows OCR language packs: {error}"))?;
    (0..count)
        .map(|index| {
            languages
                .GetAt(index)
                .map_err(|error| format!("Cannot query Windows OCR language packs: {error}"))
        })
        .collect()
}

fn candidate_languages(languages: Vec<Language>) -> Vec<Language> {
    let profile_tag = OcrEngine::TryCreateFromUserProfileLanguages()
        .and_then(|engine| engine.RecognizerLanguage())
        .and_then(|language| language.LanguageTag())
        .map(|tag| tag.to_string().to_ascii_lowercase())
        .unwrap_or_default();
    let mut ranked: Vec<_> = languages
        .into_iter()
        .filter_map(|language| {
            let tag = language
                .LanguageTag()
                .ok()?
                .to_string()
                .to_ascii_lowercase();
            let rank = if tag == profile_tag {
                0
            } else if tag.starts_with("en-") || tag.starts_with("zh-") || tag.starts_with("ja-") {
                1
            } else {
                2
            };
            Some((rank, tag, language))
        })
        .collect();
    ranked.sort_by_key(|(rank, _, _)| *rank);
    // One regional variant per language keeps a selection from causing many OCR
    // passes on machines with several English or Chinese packs installed.
    let mut roots = Vec::new();
    let mut result = Vec::new();
    for (rank, tag, language) in ranked {
        if rank == 2 && !result.is_empty() {
            continue;
        }
        let root = tag.split('-').next().unwrap_or(&tag).to_owned();
        if !roots.contains(&root) {
            roots.push(root);
            result.push(language);
        }
        if result.len() == 4 {
            break;
        }
    }
    result
}

fn selected_text(result: &OcrResult, polygon: &[(f64, f64)]) -> Result<String, String> {
    let lines = result
        .Lines()
        .map_err(|error| format!("Cannot read Windows OCR results: {error}"))?;
    let mut output = Vec::new();
    for line_index in 0..lines.Size().map_err(|error| error.to_string())? {
        let line = lines.GetAt(line_index).map_err(|error| error.to_string())?;
        let words = line.Words().map_err(|error| error.to_string())?;
        let mut text = String::new();
        for word_index in 0..words.Size().map_err(|error| error.to_string())? {
            let word = words.GetAt(word_index).map_err(|error| error.to_string())?;
            let bounds = word.BoundingRect().map_err(|error| error.to_string())?;
            let center = (
                f64::from(bounds.X + bounds.Width / 2.0),
                f64::from(bounds.Y + bounds.Height / 2.0),
            );
            if polygon.is_empty() || contains_point(polygon, center) {
                append_word(
                    &mut text,
                    word.Text()
                        .map_err(|error| error.to_string())?
                        .to_string()
                        .trim(),
                );
            }
        }
        if !text.is_empty() {
            output.push(text);
        }
    }
    Ok(output.join("\n"))
}

fn validate_input(
    width: u32,
    height: u32,
    bgra: &[u8],
    polygon: &[(f64, f64)],
) -> Result<(), String> {
    let pixels = u64::from(width) * u64::from(height);
    if width == 0 || height == 0 || pixels > MAX_PIXELS || pixels * 4 != bgra.len() as u64 {
        return Err("The captured screen image has an invalid size.".into());
    }
    if (!polygon.is_empty() && polygon.len() < 3)
        || polygon.len() > 32_768
        || polygon
            .iter()
            .any(|(x, y)| !x.is_finite() || !y.is_finite())
    {
        return Err("The selected area has an invalid outline. Please draw it again.".into());
    }
    Ok(())
}

fn fit_bitmap(
    width: u32,
    height: u32,
    bgra: Vec<u8>,
    polygon: Vec<(f64, f64)>,
    maximum: u32,
) -> (u32, u32, Vec<u8>, Vec<(f64, f64)>) {
    let largest = width.max(height);
    if largest <= maximum {
        return (width, height, bgra, polygon);
    }
    let scale = f64::from(maximum) / f64::from(largest);
    let fitted_width = (f64::from(width) * scale).round().max(1.0) as u32;
    let fitted_height = (f64::from(height) * scale).round().max(1.0) as u32;
    let x_scale = f64::from(fitted_width) / f64::from(width);
    let y_scale = f64::from(fitted_height) / f64::from(height);
    let mut pixels = vec![0; fitted_width as usize * fitted_height as usize * 4];
    for y in 0..fitted_height {
        let source_y = (u64::from(y) * u64::from(height) / u64::from(fitted_height)) as usize;
        for x in 0..fitted_width {
            let source_x = (u64::from(x) * u64::from(width) / u64::from(fitted_width)) as usize;
            let source = (source_y * width as usize + source_x) * 4;
            let destination = (y as usize * fitted_width as usize + x as usize) * 4;
            pixels[destination..destination + 4].copy_from_slice(&bgra[source..source + 4]);
        }
    }
    let polygon = polygon
        .into_iter()
        .map(|(x, y)| (x * x_scale, y * y_scale))
        .collect();
    (fitted_width, fitted_height, pixels, polygon)
}

/// Even-odd fill matches the lasso, including concave and self-crossing outlines.
fn contains_point(polygon: &[(f64, f64)], point: (f64, f64)) -> bool {
    let (x, y) = point;
    let mut inside = false;
    let mut previous = polygon[polygon.len() - 1];
    for &current in polygon {
        let (ax, ay) = previous;
        let (bx, by) = current;
        let cross = (x - ax) * (by - ay) - (y - ay) * (bx - ax);
        if cross.abs() < 1e-7
            && x >= ax.min(bx)
            && x <= ax.max(bx)
            && y >= ay.min(by)
            && y <= ay.max(by)
        {
            return true;
        }
        if (ay > y) != (by > y) && x < (bx - ax) * (y - ay) / (by - ay) + ax {
            inside = !inside;
        }
        previous = current;
    }
    inside
}

fn is_cjk(character: char) -> bool {
    matches!(character as u32, 0x3040..=0x30ff | 0x3400..=0x9fff | 0xf900..=0xfaff | 0x20000..=0x3134f)
}

fn append_word(text: &mut String, word: &str) {
    if let (Some(previous), Some(next)) = (text.chars().last(), word.chars().next()) {
        if !is_cjk(previous)
            && !is_cjk(next)
            && !",.!?:;%)]}，。！？：；、）】》」』".contains(next)
            && !"([{（【《「『".contains(previous)
        {
            text.push(' ');
        }
    }
    text.push_str(word);
}

fn text_score(text: &str) -> usize {
    // This is a deterministic coverage heuristic, not an OCR confidence score.
    text.chars()
        .map(|character| {
            if is_cjk(character) {
                4
            } else if character.is_alphanumeric() {
                2
            } else {
                0
            }
        })
        .sum()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lasso_excludes_a_concave_cutout_and_includes_its_boundary() {
        let polygon = vec![
            (0., 0.),
            (10., 0.),
            (10., 4.),
            (4., 4.),
            (4., 10.),
            (0., 10.),
        ];
        assert!(contains_point(&polygon, (2., 8.)));
        assert!(!contains_point(&polygon, (8., 8.)));
        assert!(contains_point(&polygon, (4., 8.)));
        assert!(!contains_point(&polygon, (-1., 2.)));
    }

    #[test]
    fn invalid_capture_and_nonfinite_outline_are_rejected() {
        assert!(validate_input(2, 2, &[0; 15], &[]).is_err());
        assert!(validate_input(0, 2, &[], &[]).is_err());
        assert!(validate_input(1, 1, &[0; 4], &[(f64::NAN, 0.), (1., 0.), (0., 1.)]).is_err());
        assert!(validate_input(1, 1, &[0; 4], &[]).is_ok());
    }

    #[test]
    fn large_capture_scales_pixels_and_lasso_together() {
        let pixels = vec![255; 8 * 4 * 4];
        let (width, height, pixels, polygon) =
            fit_bitmap(8, 4, pixels, vec![(2., 2.), (6., 2.), (4., 4.)], 4);
        assert_eq!((width, height), (4, 2));
        assert_eq!(pixels.len(), 4 * 2 * 4);
        assert_eq!(polygon, vec![(1., 1.), (3., 1.), (2., 2.)]);
    }

    #[test]
    fn filtered_words_keep_english_spacing_and_cjk_punctuation() {
        let mut text = String::new();
        for word in ["Hello", "world", ",", "欢迎", "使用", "。"] {
            append_word(&mut text, word);
        }
        assert_eq!(text, "Hello world,欢迎使用。");
    }
}

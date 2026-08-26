use std::borrow::Cow;
use std::collections::HashMap;

use fluent_templates::fluent_bundle::FluentValue;
use fluent_templates::{Loader, static_loader};
use unic_langid::{LanguageIdentifier, langid};

use crate::typography;

const ENGLISH: LanguageIdentifier = langid!("en-US");
const JAPANESE: LanguageIdentifier = langid!("ja");

static_loader! {
    static LOCALES = {
        locales: "./locales",
        fallback_language: "en-US",
    };
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum LanguagePreference {
    #[default]
    System,
    English,
    Japanese,
}

impl LanguagePreference {
    pub fn from_stored(value: Option<&str>) -> Self {
        match value {
            Some("en-US") => Self::English,
            Some("ja") => Self::Japanese,
            _ => Self::System,
        }
    }

    pub fn stored(self) -> &'static str {
        match self {
            Self::System => "system",
            Self::English => "en-US",
            Self::Japanese => "ja",
        }
    }
}

#[derive(Debug)]
pub struct I18n {
    preference: LanguagePreference,
    language: LanguageIdentifier,
}

impl I18n {
    pub fn new(preference: LanguagePreference) -> Self {
        let language = match preference {
            LanguagePreference::System => system_language(),
            LanguagePreference::English => ENGLISH,
            LanguagePreference::Japanese => JAPANESE,
        };
        Self {
            preference,
            language,
        }
    }

    pub fn preference(&self) -> LanguagePreference {
        self.preference
    }

    pub fn set_preference(&mut self, preference: LanguagePreference) {
        *self = Self::new(preference);
    }

    pub fn ui_font(&self) -> iced::Font {
        if self.language == JAPANESE {
            typography::NOTO_SANS_JP
        } else {
            typography::INTER
        }
    }

    pub fn text(&self, key: &str) -> String {
        LOCALES.lookup(&self.language, key)
    }

    pub fn text_with_args(
        &self,
        key: &str,
        args: impl IntoIterator<Item = (&'static str, FluentValue<'static>)>,
    ) -> String {
        let args = args
            .into_iter()
            .map(|(name, value)| (Cow::Borrowed(name), value))
            .collect::<HashMap<_, _>>();
        LOCALES.lookup_with_args(&self.language, key, &args)
    }
}

fn system_language() -> LanguageIdentifier {
    negotiated_system_language(sys_locale::get_locale().as_deref())
}

fn negotiated_system_language(locale: Option<&str>) -> LanguageIdentifier {
    let Some(locale) = locale else {
        return ENGLISH;
    };
    let locale = locale
        .split(['.', '@'])
        .next()
        .unwrap_or(locale)
        .replace('_', "-");
    match locale.parse::<LanguageIdentifier>() {
        Ok(language) if language.language == JAPANESE.language => JAPANESE,
        _ => ENGLISH,
    }
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeSet;

    use super::*;

    #[test]
    fn stored_preferences_are_stable() {
        for preference in [
            LanguagePreference::System,
            LanguagePreference::English,
            LanguagePreference::Japanese,
        ] {
            assert_eq!(
                LanguagePreference::from_stored(Some(preference.stored())),
                preference
            );
        }
    }

    #[test]
    fn interface_font_tracks_the_resolved_language() {
        assert_eq!(
            I18n::new(LanguagePreference::English).ui_font(),
            typography::INTER
        );
        assert_eq!(
            I18n::new(LanguagePreference::Japanese).ui_font(),
            typography::NOTO_SANS_JP
        );
    }

    #[test]
    fn japanese_catalog_formats_arguments() {
        let i18n = I18n::new(LanguagePreference::Japanese);
        let text = i18n.text_with_args("page-number", [("page", 3.into())]);
        assert_eq!(text.replace(['\u{2068}', '\u{2069}'], ""), "3ページ");
    }

    #[test]
    fn japanese_system_locales_are_negotiated() {
        assert_eq!(negotiated_system_language(Some("ja_JP.UTF-8")), JAPANESE);
        assert_eq!(negotiated_system_language(Some("ja-JP")), JAPANESE);
        assert_eq!(negotiated_system_language(Some("en_US.UTF-8")), ENGLISH);
        assert_eq!(negotiated_system_language(None), ENGLISH);
    }

    #[test]
    fn japanese_catalog_has_every_english_key() {
        fn keys(source: &str) -> BTreeSet<&str> {
            source
                .lines()
                .filter_map(|line| line.split_once('=').map(|(key, _)| key.trim()))
                .filter(|key| !key.is_empty())
                .collect()
        }

        assert_eq!(
            keys(include_str!("../locales/en-US/main.ftl")),
            keys(include_str!("../locales/ja/main.ftl"))
        );
    }

    #[test]
    fn image_fallback_label_is_localized() {
        let i18n = I18n::new(LanguagePreference::Japanese);
        assert_eq!(i18n.text("image"), "画像");
    }
}

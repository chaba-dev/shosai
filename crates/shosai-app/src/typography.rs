use iced::Font;

pub const INTER_BYTES: &[u8] = include_bytes!("../../../assets/fonts/InterVariable.ttf");
pub const NOTO_SANS_JP_BYTES: &[u8] =
    include_bytes!("../../../assets/fonts/NotoSansJP-Variable.ttf");

pub const INTER: Font = Font::with_name("Inter Variable");
pub const NOTO_SANS_JP: Font = Font::with_name("Noto Sans JP");

pub fn font_for_text(value: &str) -> Font {
    if value.chars().any(is_japanese_character) {
        NOTO_SANS_JP
    } else {
        INTER
    }
}

fn is_japanese_character(character: char) -> bool {
    matches!(
        character,
        '\u{3000}'..='\u{30ff}'
            | '\u{31f0}'..='\u{31ff}'
            | '\u{3400}'..='\u{9fff}'
            | '\u{f900}'..='\u{faff}'
            | '\u{ff66}'..='\u{ff9f}'
            | '\u{20000}'..='\u{2fa1f}'
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bundled_ui_fonts_have_expected_families_and_japanese_coverage() {
        let inter = ttf_parser::Face::parse(INTER_BYTES, 0).unwrap();
        let noto_sans_jp = ttf_parser::Face::parse(NOTO_SANS_JP_BYTES, 0).unwrap();

        assert!(family_names(&inter).any(|name| name == "Inter Variable"));
        assert!(family_names(&noto_sans_jp).any(|name| name == "Noto Sans JP"));
        assert!(noto_sans_jp.glyph_index('書').is_some());
        assert!(noto_sans_jp.glyph_index('語').is_some());
    }

    #[test]
    fn interface_text_selects_a_bundled_font_by_script() {
        assert_eq!(font_for_text("Settings"), INTER);
        assert_eq!(font_for_text("EPUB 16 px"), INTER);
        assert_eq!(font_for_text("設定"), NOTO_SANS_JP);
        assert_eq!(font_for_text("Shosai フォルダー"), NOTO_SANS_JP);
    }

    fn family_names<'a>(face: &'a ttf_parser::Face<'_>) -> impl Iterator<Item = String> + 'a {
        face.names().into_iter().filter_map(|name| {
            matches!(
                name.name_id,
                ttf_parser::name_id::FAMILY | ttf_parser::name_id::TYPOGRAPHIC_FAMILY
            )
            .then(|| name.to_string())
            .flatten()
        })
    }
}

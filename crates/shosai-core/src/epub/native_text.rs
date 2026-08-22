//! Renderer-neutral, book-local EPUB text shaping and rasterization.

use std::{collections::HashMap, ops::Range};

use anyhow::{Context, Result, bail};
use cosmic_text::{
    Align, Attrs, BidiParagraphs, Buffer, CacheKeyFlags, Color, FontSystem, Metrics, Shaping,
    SwashCache, Wrap,
    fontdb::{Database, Language, Stretch, Style, Weight},
};
use unicode_casefold::UnicodeCaseFold;

use super::{EpubFontBook, EpubFontFace, EpubFontStyle};

/// Hard ceiling for the sum of returned line bitmap pixels (64 MiB RGBA).
pub const EPUB_TEXT_MAX_PIXELS: usize = 16 * 1024 * 1024;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EpubTextAlign {
    Left,
    Center,
    Right,
    Justified,
}
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EpubTextDirection {
    LeftToRight,
    RightToLeft,
}

#[derive(Clone, Debug, PartialEq)]
pub struct EpubTextRun {
    pub text: String,
    pub family: Option<String>,
    pub monospace: bool,
    pub font_size: f32,
    pub bold: bool,
    pub italic: bool,
    pub foreground: [u8; 4],
    pub link: Option<String>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EpubTextHighlight {
    pub scalars: Range<usize>,
    pub color: [u8; 4],
}
#[derive(Clone, Debug, PartialEq)]
pub struct EpubTextRequest {
    pub runs: Vec<EpubTextRun>,
    pub max_width: f32,
    pub line_height: f32,
    pub scale: f32,
    pub align: EpubTextAlign,
    pub direction: EpubTextDirection,
    pub highlights: Vec<EpubTextHighlight>,
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct EpubTextRect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}
#[derive(Clone, Debug)]
pub struct EpubTextHit {
    pub rect: EpubTextRect,
    pub scalars: Range<usize>,
    pub link: String,
}
#[derive(Clone, Debug)]
pub struct EpubTextLine {
    pub top: f32,
    pub width: f32,
    pub scalars: Range<usize>,
    pub pixel_width: u32,
    pub pixel_height: u32,
    pub rgba: Vec<u8>,
}
#[derive(Clone, Debug)]
pub struct EpubTextLayout {
    pub width: f32,
    pub height: f32,
    pub lines: Vec<EpubTextLine>,
    pub links: Vec<EpubTextHit>,
}

pub(super) struct NativeTextState {
    fonts: FontSystem,
    cache: SwashCache,
    aliases: HashMap<String, String>,
    styles: HashMap<String, Vec<Style>>,
}

impl NativeTextState {
    pub(super) fn empty() -> Self {
        Self::new(&Database::new(), &[], &[])
    }
    pub(super) fn new(source: &Database, ids: &[fontdb::ID], faces: &[EpubFontFace]) -> Self {
        let mut db = Database::new();
        let mut aliases = HashMap::new();
        let mut styles = HashMap::<String, Vec<Style>>::new();
        if !faces.is_empty() {
            db.load_system_fonts();
        }
        for (id, declared) in ids.iter().zip(faces) {
            if let Some(mut info) = source.face(*id).cloned() {
                info.id = fontdb::ID::dummy();
                let folded = folded_family(&declared.family);
                let alias_index = aliases.len();
                let synthetic = aliases.entry(folded.clone()).or_insert_with(|| {
                    (alias_index..)
                        .map(|index| format!("\u{f0000}shosai-epub-family-{index}"))
                        .find(|candidate| {
                            !db.faces().any(|face| {
                                face.families.iter().any(|(family, _)| family == candidate)
                            })
                        })
                        .expect("synthetic EPUB family index space is inexhaustible")
                });
                info.families = vec![(synthetic.clone(), Language::English_UnitedStates)];
                info.style = match declared.style {
                    EpubFontStyle::Normal => Style::Normal,
                    EpubFontStyle::Italic => Style::Italic,
                    EpubFontStyle::Oblique => Style::Oblique,
                };
                styles.entry(folded).or_default().push(info.style);
                info.weight = Weight(
                    ((declared.weight.min() + declared.weight.max()) / 2.0)
                        .round()
                        .clamp(1.0, 1000.0) as u16,
                );
                info.stretch = Stretch::Normal;
                db.push_face_info(info);
            }
        }
        Self {
            fonts: FontSystem::new_with_locale_and_db("en-US".into(), db),
            cache: SwashCache::new(),
            aliases,
            styles,
        }
    }

    #[cfg(test)]
    pub(super) fn matched_postscript_name(&self, family: &str, style: Style) -> Option<&str> {
        let family = self.aliases.get(&folded_family(family))?;
        let id = self.fonts.db().query(&fontdb::Query {
            families: &[fontdb::Family::Name(family)],
            style,
            ..fontdb::Query::default()
        })?;
        self.fonts
            .db()
            .face(id)
            .map(|face| face.post_script_name.as_str())
    }
}

impl EpubFontBook {
    /// Shapes and rasterizes rich text without registering fonts globally.
    pub fn layout_text(&self, request: &EpubTextRequest) -> Result<EpubTextLayout> {
        self.layout_text_inner(request, true)
    }

    /// Shapes and measures rich text without allocating line bitmaps.
    pub fn measure_text(&self, request: &EpubTextRequest) -> Result<EpubTextLayout> {
        self.layout_text_inner(request, false)
    }

    fn layout_text_inner(
        &self,
        request: &EpubTextRequest,
        rasterize: bool,
    ) -> Result<EpubTextLayout> {
        validate(request)?;
        let mut state = self.native.lock().map_err(|_| {
            anyhow::anyhow!("EPUB text renderer lock is poisoned; discard and reopen this book")
        })?;
        let NativeTextState {
            fonts,
            cache,
            aliases,
            styles,
        } = &mut *state;
        let default_size = request.runs.first().map_or(16.0, |r| r.font_size);
        let mut buffer = Buffer::new(fonts, Metrics::new(default_size, request.line_height));
        buffer.set_size(fonts, Some(request.max_width), None);
        buffer.set_wrap(fonts, Wrap::WordOrGlyph);
        let (isolate, pop_isolate) = match request.direction {
            EpubTextDirection::LeftToRight => ("\u{2066}", "\u{2069}"),
            EpubTextDirection::RightToLeft => ("\u{2067}", "\u{2069}"),
        };
        let control_attrs = Attrs::new()
            .metrics(Metrics::new(default_size, request.line_height))
            .color(Color::rgba(0, 0, 0, 0))
            .metadata(usize::MAX);
        let attrs = std::iter::once((isolate, control_attrs.clone()))
            .chain(request.runs.iter().enumerate().map(|(i, run)| {
                let folded = run.family.as_deref().map(folded_family);
                let family = folded
                    .as_ref()
                    .and_then(|family| aliases.get(family))
                    .map_or_else(
                        || {
                            if run.monospace {
                                cosmic_text::Family::Monospace
                            } else {
                                cosmic_text::Family::SansSerif
                            }
                        },
                        |family| cosmic_text::Family::Name(family),
                    );
                let requested_style = if run.italic {
                    Style::Italic
                } else {
                    Style::Normal
                };
                let (style, cache_key_flags) = folded
                    .as_ref()
                    .and_then(|family| styles.get(family))
                    .map_or((requested_style, CacheKeyFlags::empty()), |available| {
                        if available.contains(&requested_style) {
                            (requested_style, CacheKeyFlags::empty())
                        } else if run.italic && available.contains(&Style::Normal) {
                            (Style::Normal, CacheKeyFlags::FAKE_ITALIC)
                        } else {
                            (available[0], CacheKeyFlags::empty())
                        }
                    });
                let a = Attrs::new()
                    .family(family)
                    .weight(if run.bold {
                        Weight::BOLD
                    } else {
                        Weight::NORMAL
                    })
                    .style(style)
                    .cache_key_flags(cache_key_flags)
                    .metrics(Metrics::new(run.font_size, request.line_height))
                    .color(Color::rgba(
                        run.foreground[0],
                        run.foreground[1],
                        run.foreground[2],
                        run.foreground[3],
                    ))
                    .metadata(i);
                (run.text.as_str(), a)
            }))
            .chain(std::iter::once((pop_isolate, control_attrs)));
        let align = match request.align {
            EpubTextAlign::Left => Align::Left,
            EpubTextAlign::Center => Align::Center,
            EpubTextAlign::Right => Align::Right,
            EpubTextAlign::Justified => Align::Justified,
        };
        buffer.set_rich_text(fonts, attrs, &Attrs::new(), Shaping::Advanced, Some(align));
        buffer.shape_until_scroll(fonts, false);

        let visible_text: String = request.runs.iter().map(|r| r.text.as_str()).collect();
        let scalar_boundaries = scalar_boundaries(&visible_text);
        let text = format!("{isolate}{visible_text}{pop_isolate}");
        let visible_bytes = isolate.len()..isolate.len() + visible_text.len();
        let paragraphs = paragraph_ranges(&text);
        let pw = (request.max_width * request.scale).ceil() as usize;
        let runs: Vec<_> = buffer.layout_runs().collect();
        let raw_ranges = runs
            .iter()
            .map(|run| {
                let paragraph = paragraphs
                    .get(run.line_i)
                    .context("EPUB shaper returned an unknown paragraph index")?;
                let start = run
                    .glyphs
                    .iter()
                    .filter(|glyph| glyph.metadata != usize::MAX)
                    .map(|glyph| paragraph.start + glyph.start)
                    .min();
                let end = run
                    .glyphs
                    .iter()
                    .filter(|glyph| glyph.metadata != usize::MAX)
                    .map(|glyph| paragraph.start + glyph.end)
                    .max();
                Ok::<_, anyhow::Error>(start.zip(end))
            })
            .collect::<Result<Vec<_>>>()?;
        let line_ranges = runs
            .iter()
            .enumerate()
            .map(|(index, run)| {
                let paragraph = &paragraphs[run.line_i];
                let partition_start = if index > 0 && runs[index - 1].line_i == run.line_i {
                    raw_ranges[index]
                        .as_ref()
                        .or(raw_ranges[index - 1].as_ref())
                        .map_or(paragraph.start, |r| r.0)
                } else {
                    paragraph.start
                };
                let partition_end = if runs
                    .get(index + 1)
                    .is_some_and(|next| next.line_i == run.line_i)
                {
                    raw_ranges[index + 1]
                        .as_ref()
                        .map_or(paragraph.end, |r| r.0)
                } else {
                    paragraphs
                        .get(run.line_i + 1)
                        .map_or(visible_bytes.end, |next| next.start)
                };
                checked_scalar_range(
                    &scalar_boundaries,
                    &visible_bytes,
                    partition_start,
                    partition_end,
                )
            })
            .collect::<Result<Vec<_>>>()?;
        let pixels = runs.iter().try_fold(0_usize, |pixels, run| {
            let height = (run.line_height * request.scale).ceil() as usize;
            pixels
                .checked_add(
                    pw.checked_mul(height)
                        .context("EPUB text bitmap dimensions overflow")?,
                )
                .context("EPUB text bitmap dimensions overflow")
        })?;
        if rasterize && pixels > EPUB_TEXT_MAX_PIXELS {
            bail!("EPUB text output exceeds the {EPUB_TEXT_MAX_PIXELS}-pixel per-call ceiling");
        }
        let mut lines = Vec::with_capacity(runs.len());
        let mut links = Vec::new();
        for (run, line_range) in runs.into_iter().zip(line_ranges) {
            let ph = (run.line_height * request.scale).ceil() as usize;
            let mut rgba = if rasterize {
                vec![
                    0;
                    pw.checked_mul(ph)
                        .and_then(|v| v.checked_mul(4))
                        .context("EPUB line bitmap size overflow")?
                ]
            } else {
                Vec::new()
            };
            let base = paragraphs[run.line_i].start;
            for glyph in run.glyphs {
                let start = (base + glyph.start).max(visible_bytes.start);
                let end = (base + glyph.end).min(visible_bytes.end);
                if start >= end || glyph.metadata == usize::MAX {
                    continue;
                }
                let local_start = start - visible_bytes.start;
                let local_end = end - visible_bytes.start;
                let scalars = checked_scalar_range(
                    &scalar_boundaries,
                    &(0..visible_text.len()),
                    local_start,
                    local_end,
                )?;
                let rect = EpubTextRect {
                    x: glyph.x,
                    y: run.line_top,
                    width: glyph.w.max(0.0),
                    height: run.line_height,
                };
                if rasterize {
                    for h in &request.highlights {
                        if h.scalars.start < scalars.end && scalars.start < h.scalars.end {
                            fill(
                                &mut rgba,
                                (pw, ph),
                                (
                                    (glyph.x * request.scale) as i32,
                                    0,
                                    (glyph.w * request.scale).ceil() as i32,
                                    ph as i32,
                                ),
                                h.color,
                            );
                        }
                    }
                }
                if let Some(link) = request
                    .runs
                    .get(glyph.metadata)
                    .and_then(|r| r.link.clone())
                {
                    links.push(EpubTextHit {
                        rect,
                        scalars: scalars.clone(),
                        link,
                    });
                }
                if rasterize {
                    let physical = glyph.physical((0.0, 0.0), request.scale);
                    let color = glyph.color_opt.unwrap_or(Color::rgb(0, 0, 0));
                    cache.with_pixels(fonts, physical.cache_key, color, |x, y, c| {
                        fill(
                            &mut rgba,
                            (pw, ph),
                            (
                                physical.x + x,
                                ((run.line_y - run.line_top) * request.scale) as i32
                                    + physical.y
                                    + y,
                                1,
                                1,
                            ),
                            [c.r(), c.g(), c.b(), c.a()],
                        )
                    });
                }
            }
            lines.push(EpubTextLine {
                top: run.line_top,
                width: run.line_w,
                scalars: line_range,
                pixel_width: pw as u32,
                pixel_height: ph as u32,
                rgba,
            });
        }
        let width = lines.iter().map(|l| l.width).fold(0.0_f32, f32::max);
        let height = lines.last().map_or(0.0, |line| {
            line.top + line.pixel_height as f32 / request.scale
        });
        Ok(EpubTextLayout {
            width,
            height,
            lines,
            links,
        })
    }
}

fn folded_family(value: &str) -> String {
    value.case_fold().collect()
}

fn validate(r: &EpubTextRequest) -> Result<()> {
    if !r.max_width.is_finite()
        || r.max_width <= 0.0
        || !r.line_height.is_finite()
        || r.line_height <= 0.0
        || !r.scale.is_finite()
        || r.scale <= 0.0
    {
        bail!("EPUB text geometry must be finite and positive");
    }
    if r.max_width * r.scale > u32::MAX as f32 || r.line_height * r.scale > u32::MAX as f32 {
        bail!("EPUB text pixel geometry is out of range");
    }
    if r.runs
        .iter()
        .any(|x| !x.font_size.is_finite() || x.font_size <= 0.0)
    {
        bail!("EPUB font sizes must be finite and positive");
    }
    Ok(())
}
fn paragraph_ranges(text: &str) -> Vec<Range<usize>> {
    let base = text.as_ptr() as usize;
    BidiParagraphs::new(text)
        .map(|paragraph| {
            let start = paragraph.as_ptr() as usize - base;
            start..start + paragraph.len()
        })
        .collect()
}
fn checked_scalar_range(
    scalar_boundaries: &[usize],
    visible_bytes: &Range<usize>,
    start: usize,
    end: usize,
) -> Result<Range<usize>> {
    let start = start.clamp(visible_bytes.start, visible_bytes.end) - visible_bytes.start;
    let end = end.clamp(visible_bytes.start, visible_bytes.end) - visible_bytes.start;
    let start = scalar_boundaries
        .binary_search(&start)
        .map_err(|_| anyhow::anyhow!("EPUB shaper returned a non-character source boundary"))?;
    let end = scalar_boundaries
        .binary_search(&end)
        .map_err(|_| anyhow::anyhow!("EPUB shaper returned a non-character source boundary"))?;
    Ok(start..end)
}
fn scalar_boundaries(text: &str) -> Vec<usize> {
    text.char_indices()
        .map(|(byte, _)| byte)
        .chain(std::iter::once(text.len()))
        .collect()
}
fn fill(buf: &mut [u8], dimensions: (usize, usize), rect: (i32, i32, i32, i32), c: [u8; 4]) {
    let (w, h) = dimensions;
    let (x, y, ww, hh) = rect;
    for yy in y.max(0)..(y + hh).min(h as i32) {
        for xx in x.max(0)..(x + ww).min(w as i32) {
            let i = (yy as usize * w + xx as usize) * 4;
            let a = c[3] as u32;
            let da = buf[i + 3] as u32;
            let oa = a + da * (255 - a) / 255;
            if oa > 0 {
                for k in 0..3 {
                    buf[i + k] =
                        ((c[k] as u32 * a + buf[i + k] as u32 * da * (255 - a) / 255) / oa) as u8;
                }
            }
            buf[i + 3] = oa as u8;
        }
    }
}

use super::*;

pub(super) fn cache_epub_image_handles<'a, F>(
    handles: &mut HashMap<String, EpubImageHandle>,
    nodes: impl IntoIterator<Item = &'a ContentNode>,
    resource_bytes: &F,
) where
    F: Fn(&str) -> Option<&'a [u8]>,
{
    for node in nodes {
        match node {
            ContentNode::Image { src, .. } => {
                if handles.contains_key(src) {
                    continue;
                }
                let Some(data) = resource_bytes(src) else {
                    continue;
                };
                let Ok(image) = ::image::load_from_memory(data) else {
                    continue;
                };
                let rgba = image.to_rgba8();
                let (width, height) = rgba.dimensions();
                handles.insert(
                    src.clone(),
                    EpubImageHandle(image::Handle::from_rgba(width, height, rgba.into_raw())),
                );
            }
            ContentNode::BlockQuote { children, .. } => {
                cache_epub_image_handles(handles, children, resource_bytes);
            }
            ContentNode::Table { row_groups, .. } => {
                for cell in row_groups
                    .iter()
                    .flat_map(|group| &group.rows)
                    .flat_map(|row| &row.cells)
                {
                    cache_epub_image_handles(handles, &cell.children, resource_bytes);
                }
            }
            _ => {}
        }
    }
}

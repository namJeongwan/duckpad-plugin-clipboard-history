use std::{slice, sync::Mutex};

static OUTPUT: Mutex<Vec<u8>> = Mutex::new(Vec::new());
const HISTORY_LIMIT: usize = 200;
const STATE_LIMIT: usize = 512 * 1024;
const ITEM_LIMIT: usize = 256 * 1024;
const STATE_HEADER: usize = 20;
const IMAGE_BUDGET: usize = 256 * 1024 * 1024;
const DAY: u64 = 86_400;
fn entry_size(e: &Entry) -> usize { 24 + e.text.len() }
fn encoded_size(entries: &[Entry]) -> usize {
    STATE_HEADER + entries.iter().map(entry_size).sum::<usize>() +
        if entries.iter().any(|e| e.image) { 4 * entries.len() } else { 0 }
}
#[derive(Clone, Debug, PartialEq)]
struct Entry { id: u64, pinned: bool, text: String, copied_at: u64, image: bool }
fn image_metadata(value: &str) -> Result<(&str, u32, u32, usize), ()> {
    let parts: Vec<&str> = value.split(':').collect();
    if parts.len() != 4 || parts[0].len() != 64 || !parts[0].bytes().all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)) { return Err(()); }
    let w = parts[1].parse::<u32>().map_err(|_| ())?;
    let h = parts[2].parse::<u32>().map_err(|_| ())?;
    let size = parts[3].parse::<usize>().map_err(|_| ())?;
    if w == 0 || h == 0 || u64::from(w)*u64::from(h) > 64_000_000 || size == 0 || size > 32*1024*1024 { return Err(()); }
    Ok((parts[0], w, h, size))
}
fn image_size(e: &Entry) -> usize { if e.image { image_metadata(&e.text).map(|v| v.3).unwrap_or(0) } else { 0 } }
struct State { next_id: u64, entries: Vec<Entry>, retention_days: u32 }
impl Default for State {
    fn default() -> Self { Self { next_id: 0, entries: Vec::new(), retention_days: 7 } }
}
struct Reader<'a> { bytes: &'a [u8], offset: usize }
impl<'a> Reader<'a> {
    fn new(bytes: &'a [u8]) -> Self { Self { bytes, offset: 0 } }
    fn take(&mut self, n: usize) -> Result<&'a [u8], ()> {
        if n > self.bytes.len().saturating_sub(self.offset) { return Err(()); }
        let result = &self.bytes[self.offset..self.offset+n]; self.offset += n; Ok(result)
    }
    fn u32(&mut self) -> Result<u32, ()> { Ok(u32::from_le_bytes(self.take(4)?.try_into().map_err(|_| ())?)) }
    fn u64(&mut self) -> Result<u64, ()> { Ok(u64::from_le_bytes(self.take(8)?.try_into().map_err(|_| ())?)) }
    fn blob(&mut self) -> Result<&'a [u8], ()> { let n = self.u32()? as usize; self.take(n) }
    fn text(&mut self) -> Result<String, ()> { String::from_utf8(self.blob()?.to_vec()).map_err(|_| ()) }
    fn end(&self) -> Result<(), ()> { if self.offset == self.bytes.len() { Ok(()) } else { Err(()) } }
}
fn blob(out: &mut Vec<u8>, value: &[u8]) { out.extend_from_slice(&(value.len() as u32).to_le_bytes()); out.extend_from_slice(value); }
fn text(out: &mut Vec<u8>, value: &str) { blob(out, value.as_bytes()); }
impl State {
    #[cfg(test)]
    fn decode(bytes: &[u8]) -> Result<Self, ()> { Self::decode_at(bytes, 0) }
    fn decode_at(bytes: &[u8], now: u64) -> Result<Self, ()> {
        if bytes.is_empty() { return Ok(Self::default()); }
        if bytes.len() > STATE_LIMIT { return Err(()); }
        let mut r = Reader::new(bytes);
        let version = r.u32()?;
        if version != 1 && version != 2 && version != 3 { return Err(()); }
        let retention_days = if version >= 2 { r.u32()? } else { 7 };
        if ![1, 3, 7].contains(&retention_days) { return Err(()); }
        let next_id = r.u64()?;
        let count = r.u32()? as usize;
        if count > HISTORY_LIMIT { return Err(()); }
        let mut entries = Vec::new();
        for _ in 0..count {
            let id = r.u64()?; let pinned = r.u32()?;
            if id == 0 || id > next_id || pinned > 1 || entries.iter().any(|e: &Entry| e.id == id) { return Err(()); }
            let copied_at = if version >= 2 { r.u64()? } else { now };
            let image = if version == 3 { match r.u32()? { 0 => false, 1 => true, _ => return Err(()) } } else { false };
            let text = r.text()?;
            if image { image_metadata(&text)?; }
            entries.push(Entry { id, pinned: pinned == 1, copied_at, text, image });
        }
        r.end()?;
        // Legacy timestamps add storage overhead. Keep migration inside the same
        // byte budget, preferring to retain pins just like ordinary capture.
        while encoded_size(&entries) > STATE_LIMIT {
            let index = entries.iter().rposition(|e| !e.pinned).unwrap_or(entries.len()-1);
            entries.remove(index);
        }
        if entries.iter().map(image_size).sum::<usize>() > IMAGE_BUDGET { return Err(()); }
        Ok(Self { next_id, entries, retention_days })
    }
    fn encode(&self) -> Vec<u8> {
        let version: u32 = if self.entries.iter().any(|e| e.image) { 3 } else { 2 };
        let mut out = version.to_le_bytes().to_vec(); out.extend_from_slice(&self.retention_days.to_le_bytes()); out.extend_from_slice(&self.next_id.to_le_bytes());
        out.extend_from_slice(&(self.entries.len() as u32).to_le_bytes());
        for e in &self.entries { out.extend_from_slice(&e.id.to_le_bytes()); out.extend_from_slice(&(e.pinned as u32).to_le_bytes()); out.extend_from_slice(&e.copied_at.to_le_bytes()); if version == 3 { out.extend_from_slice(&(e.image as u32).to_le_bytes()); } text(&mut out, &e.text); }
        out
    }
    fn expire(&mut self, now: u64) {
        self.entries.retain(|e| now.saturating_sub(e.copied_at) < u64::from(self.retention_days) * DAY);
    }
    #[cfg(test)]
    fn capture(&mut self, value: String) -> Result<(), ()> { self.capture_at(value, 0) }
    fn capture_at(&mut self, value: String, now: u64) -> Result<(), ()> {
        self.capture_content(value, now, false)
    }
    fn capture_content(&mut self, value: String, now: u64, image: bool) -> Result<(), ()> {
        let image_bytes = if image { image_metadata(&value)?.3 } else { 0 };
        if value.is_empty() { return Ok(()); }
        if let Some(index) = self.entries.iter().position(|e| e.image == image && e.text == value) {
            let mut entry = self.entries.remove(index); entry.copied_at = now; self.entries.insert(0, entry); return Ok(());
        }
        let image_format = image || self.entries.iter().any(|e| e.image);
        let overhead = if image_format { 4 } else { 0 };
        let required = 24 + overhead + value.len();
        if value.len() > ITEM_LIMIT || STATE_HEADER + required > STATE_LIMIT { return Ok(()); }
        let pinned_bytes: usize = self.entries.iter().filter(|e| e.pinned).map(|e| entry_size(e) + overhead).sum();
        if self.entries.iter().filter(|e| e.pinned).map(image_size).sum::<usize>() + image_bytes > IMAGE_BUDGET { return Ok(()); }
        if self.entries.iter().filter(|e| e.pinned).count() >= HISTORY_LIMIT || STATE_HEADER + pinned_bytes + required > STATE_LIMIT { return Ok(()); }
        while self.entries.iter().map(image_size).sum::<usize>() + image_bytes > IMAGE_BUDGET || self.entries.len() >= HISTORY_LIMIT || STATE_HEADER + self.entries.iter().map(|e| entry_size(e) + overhead).sum::<usize>() + required > STATE_LIMIT {
            if let Some(index) = self.entries.iter().rposition(|e| !e.pinned) { self.entries.remove(index); }
            else { return Ok(()); }
        }
        self.next_id = self.next_id.checked_add(1).ok_or(())?;
        self.entries.insert(0, Entry { id: self.next_id, pinned: false, text: value, copied_at: now, image }); Ok(())
    }
}
fn invoke(input: &[u8]) -> Result<Vec<u8>, ()> {
    let mut r = Reader::new(input);
    let version = r.u32()?;
    if version != 1 && version != 2 && version != 3 { return Err(()); }
    let state_bytes = r.blob()?;
    let event = r.text()?; let payload = r.text()?; let query = r.text()?.to_lowercase();
    let now = if version >= 2 { r.u64()? } else { 0 }; r.end()?;
    let mut state = State::decode_at(state_bytes, now)?;
    state.expire(now);
    let mut selected = String::new();
    let mut selected_image = String::new();
    match event.as_str() {
        "capture" => state.capture_at(payload, now)?,
        "capture-image" if version == 3 => state.capture_content(payload, now, true)?,
        "retention" => {
            let days = payload.parse::<u32>().map_err(|_| ())?;
            if ![1, 3, 7].contains(&days) { return Err(()); }
            state.retention_days = days; state.expire(now);
        },
        "query" => (),
        "clear" => state.entries.clear(),
        "pin" | "delete" | "select" | "preview" => {
            let id = payload.parse::<u64>().map_err(|_| ())?;
            if let Some(index) = state.entries.iter().position(|e| e.id == id) {
            match event.as_str() {
                "pin" => state.entries[index].pinned = !state.entries[index].pinned,
                "delete" => { state.entries.remove(index); },
                _ => if state.entries[index].image { selected_image = state.entries[index].text.clone() } else { selected = state.entries[index].text.clone() },
            }
            }
        },
        _ => return Err(()),
    }
    let mut rows: Vec<&Entry> = state.entries.iter().filter(|e| (!e.image || version == 3) &&
        (e.text.to_lowercase().contains(&query) || (e.image && "image".contains(&query)))).collect();
    rows.sort_by_key(|e| !e.pinned);
    let mut out = (if version == 3 { 3u32 } else { 2u32 }).to_le_bytes().to_vec(); blob(&mut out, &state.encode());
    out.extend_from_slice(&(rows.len() as u32).to_le_bytes());
    for e in rows {
        text(&mut out, &e.id.to_string());
        // Short display labels; selection always returns the exact original text.
        let title: String = e.text.lines().next().unwrap_or("").chars().take(160).collect();
        text(&mut out, &title); out.extend_from_slice(&(e.pinned as u32).to_le_bytes());
        if version == 3 { text(&mut out, if e.image { &e.text } else { "" }); }
    }
    text(&mut out, &selected); out.extend_from_slice(&state.retention_days.to_le_bytes());
    if version == 3 {
        text(&mut out, &selected_image);
        let images: Vec<&Entry> = state.entries.iter().filter(|e| e.image).collect();
        out.extend_from_slice(&(images.len() as u32).to_le_bytes());
        for e in images { text(&mut out, &e.text); }
    }
    Ok(out)
}
#[no_mangle]
pub unsafe extern "C" fn duckpad_invoke(operation: u32, pointer: *const u8, length: u32) -> u32 {
    if operation != 1 || (length != 0 && pointer.is_null()) { return 2; }
    let input = if length == 0 { &[] } else { slice::from_raw_parts(pointer, length as usize) };
    let Ok(result) = invoke(input) else { return 3; };
    let Ok(mut output) = OUTPUT.lock() else { return 4; }; *output = result; 0
}
#[no_mangle]
pub extern "C" fn duckpad_output_pointer() -> u32 { OUTPUT.lock().map(|v| v.as_ptr() as u32).unwrap_or(0) }
#[no_mangle]
pub extern "C" fn duckpad_output_length() -> u32 { OUTPUT.lock().map(|v| v.len() as u32).unwrap_or(0) }

#[cfg(test)]
mod tests {
    use super::*;
    fn event(state: &[u8], event: &str, payload: &str, query: &str) -> Vec<u8> {
        let mut input = 1u32.to_le_bytes().to_vec(); blob(&mut input, state); text(&mut input,event); text(&mut input,payload); text(&mut input,query); input
    }
    fn result(input: &[u8]) -> (Vec<u8>, Vec<(String,String,bool)>, String) {
        let output=invoke(input).unwrap(); let mut r=Reader::new(&output); assert_eq!(r.u32().unwrap(),2);
        let state=r.blob().unwrap().to_vec(); let n=r.u32().unwrap(); let mut rows=vec![];
        for _ in 0..n { rows.push((r.text().unwrap(),r.text().unwrap(),r.u32().unwrap()==1)); }
        let paste=r.text().unwrap(); assert!([1,3,7].contains(&r.u32().unwrap())); r.end().unwrap(); (state,rows,paste)
    }
    #[test] fn dedup_pin_search_and_exact_paste() {
        let original="  한글 Rust\n    fn main() {}\n";
        let (s,rows,_) = result(&event(&[],"capture",original,"")); let id=&rows[0].0;
        let (s,_,_) = result(&event(&s,"pin",id,""));
        let (s,rows,_) = result(&event(&s,"capture",original,"RUST"));
        assert_eq!(rows.len(),1); assert!(rows[0].2);
        assert_eq!(result(&event(&s,"select",id,"" )).2,original);
        let (unchanged, _, preview) = result(&event(&s,"preview",id,""));
        assert_eq!(preview, original); assert_eq!(unchanged, s);
        assert!(result(&event(&s,"query","","missing")).1.is_empty());
    }
    #[test] fn delete_clear_and_restart_state() {
        let (s,rows,_) = result(&event(&[],"capture","one",""));
        let restored=State::decode(&s).unwrap().encode(); assert_eq!(s,restored);
        assert!(result(&event(&s,"delete",&rows[0].0,"")).1.is_empty());
        assert!(result(&event(&s,"clear","","")).1.is_empty());
    }
    #[test] fn bounded_history_keeps_pins() {
        let mut state=State::default(); state.capture("keep".into()).unwrap(); state.entries[0].pinned=true;
        for i in 0..HISTORY_LIMIT+10 { state.capture(i.to_string()).unwrap(); }
        assert_eq!(state.entries.len(),HISTORY_LIMIT); assert!(state.entries.iter().any(|e| e.text=="keep"));
    }
    #[test] fn byte_budget_survives_restart_query_select_and_clear() {
        let large = "x".repeat(ITEM_LIMIT - 100);
        let (s,_,_) = result(&event(&[],"capture",&large,""));
        let (s,rows,_) = result(&event(&s,"capture",&("y".repeat(ITEM_LIMIT)),""));
        assert!(s.len() <= STATE_LIMIT);
        assert!(!rows.is_empty());
        assert!(!result(&event(&s,"select",&rows[0].0,"")).2.is_empty());
        let (restored,_,_) = result(&event(&s,"query","","")); assert_eq!(restored,s);
        assert!(result(&event(&s,"clear","","")).1.is_empty());
        let (unchanged,_,_) = result(&event(&s,"capture",&"z".repeat(ITEM_LIMIT+1),"")); assert_eq!(unchanged,s);
    }
    #[test] fn pinned_byte_budget_does_not_evict_on_rejected_capture() {
        let (s,rows,_) = result(&event(&[],"capture",&"a".repeat(ITEM_LIMIT),""));
        let (s,_,_) = result(&event(&s,"pin",&rows[0].0,""));
        let (s,_,_) = result(&event(&s,"capture","keep unpinned",""));
        let (after,_,_) = result(&event(&s,"capture",&"b".repeat(ITEM_LIMIT),""));
        assert_eq!(after,s);
    }
    fn event_at(state: &[u8], kind: &str, payload: &str, now: u64) -> Vec<u8> {
        let mut input = event(state, kind, payload, "");
        input[..4].copy_from_slice(&2u32.to_le_bytes());
        input.extend_from_slice(&now.to_le_bytes()); input
    }
    #[test] fn expiration_applies_to_pins_on_restart_and_exact_boundary() {
        let now = 100 * DAY;
        let (s, rows, _) = result(&event_at(&[], "capture", "private", now));
        let (s, _, _) = result(&event_at(&s, "pin", &rows[0].0, now));
        assert_eq!(result(&event_at(&s, "query", "", now+7*DAY-1)).1.len(), 1);
        let (expired, rows, paste) = result(&event_at(&s, "select", &rows[0].0, now+7*DAY));
        assert!(rows.is_empty() && paste.is_empty());
        assert!(State::decode(&expired).unwrap().entries.is_empty());
    }
    #[test] fn retention_changes_persist_and_never_exceed_one_week() {
        let (s, _, _) = result(&event_at(&[], "capture", "old", 100*DAY));
        let (s, _, _) = result(&event_at(&s, "capture", "recent", 102*DAY));
        let (s, rows, _) = result(&event_at(&s, "retention", "1", 102*DAY));
        assert_eq!(rows.len(), 1); assert_eq!(rows[0].1, "recent");
        assert_eq!(State::decode(&s).unwrap().retention_days, 1);
        assert!(invoke(&event_at(&s, "retention", "8", 102*DAY)).is_err());
        assert!(invoke(&event_at(&s, "retention", "0", 102*DAY)).is_err());
    }
    #[test] fn recopy_refreshes_expiry_without_select_refreshing_it() {
        let (s, _, _) = result(&event_at(&[], "capture", "same", 10*DAY));
        let (s, rows, _) = result(&event_at(&s, "capture", "same", 16*DAY));
        assert_eq!(rows.len(), 1);
        let (s, _, paste) = result(&event_at(&s, "select", &rows[0].0, 22*DAY));
        assert_eq!(paste, "same");
        assert!(result(&event_at(&s, "query", "", 23*DAY)).1.is_empty());
    }
    #[test] fn legacy_state_migrates_without_losing_text_or_pin() {
        let mut old = 1u32.to_le_bytes().to_vec();
        old.extend_from_slice(&1u64.to_le_bytes()); old.extend_from_slice(&1u32.to_le_bytes());
        old.extend_from_slice(&1u64.to_le_bytes()); old.extend_from_slice(&1u32.to_le_bytes());
        text(&mut old, "legacy");
        let (s, rows, _) = result(&event_at(&old, "query", "", 100*DAY));
        assert_eq!(rows.len(), 1); assert!(rows[0].2);
        assert_eq!(result(&event_at(&s, "select", "1", 100*DAY)).2, "legacy");
        assert!(result(&event_at(&s, "query", "", 107*DAY)).1.is_empty());
    }
    #[test] fn full_legacy_state_fits_budget_after_migration() {
        let mut old = 1u32.to_le_bytes().to_vec();
        old.extend_from_slice(&2u64.to_le_bytes()); old.extend_from_slice(&2u32.to_le_bytes());
        for (id, size) in [(1u64, ITEM_LIMIT), (2u64, ITEM_LIMIT-48)] {
            old.extend_from_slice(&id.to_le_bytes()); old.extend_from_slice(&0u32.to_le_bytes());
            text(&mut old, &"x".repeat(size));
        }
        assert_eq!(old.len(), STATE_LIMIT);
        let (s, rows, _) = result(&event_at(&old, "query", "", 100*DAY));
        assert!(s.len() <= STATE_LIMIT); assert!(!rows.is_empty());
    }
    #[test] fn full_v2_text_history_survives_read_without_eviction() {
        let mut state = State::default();
        state.capture("a".repeat(ITEM_LIMIT)).unwrap();
        state.capture("b".repeat(STATE_LIMIT - STATE_HEADER - 48 - ITEM_LIMIT)).unwrap();
        for e in &mut state.entries { e.pinned = true; }
        let encoded = state.encode(); assert_eq!(encoded.len(), STATE_LIMIT);
        assert_eq!(State::decode(&encoded).unwrap().encode(), encoded);
        let (queried, rows, _) = result(&event(&encoded, "query", "", ""));
        assert_eq!(rows.len(), 2); assert_eq!(queried, encoded);
    }
    #[test] fn image_state_roundtrip_dedup_and_kind_separation() {
        let descriptor = format!("{}:80:40:200", "a".repeat(64));
        let mut state = State::default();
        state.capture_at(descriptor.clone(), 1).unwrap();
        state.capture_content(descriptor.clone(), 1, true).unwrap();
        state.entries[0].pinned = true;
        state.capture_content(descriptor.clone(), 2, true).unwrap();
        assert_eq!(state.entries.len(), 2);
        let encoded = state.encode(); assert_eq!(encoded[0], 3);
        let mut restored = State::decode(&encoded).unwrap();
        assert_eq!(restored.entries, state.entries);
        assert!(restored.entries[0].pinned);
        restored.expire(2 + 7 * DAY); assert!(restored.entries.is_empty());
    }
    #[test] fn image_budget_evicts_unpinned_and_preserves_pins() {
        let mut state = State::default();
        for n in 0..9 {
            state.capture_content(format!("{:064x}:1:1:{}", n, 32*1024*1024), 0, true).unwrap();
        }
        assert_eq!(state.entries.len(), 8);
        assert_eq!(state.entries.iter().map(image_size).sum::<usize>(), IMAGE_BUDGET);
        for e in &mut state.entries { e.pinned = true; }
        let before = state.encode();
        state.capture_content(format!("{:064x}:1:1:1", 100), 0, true).unwrap();
        assert_eq!(before, state.encode());
        assert!(state.capture_content("../escape:1:1:1".into(), 0, true).is_err());
        assert!(image_metadata(&format!("{}:99999999:99999999:1", "a".repeat(64))).is_err());
    }
    #[test] fn filtered_response_keeps_all_image_references_and_never_pastes_metadata() {
        let descriptor = format!("{}:80:40:200", "a".repeat(64));
        let mut state = State::default(); state.capture_content(descriptor.clone(), 0, true).unwrap();
        let mut input = 3u32.to_le_bytes().to_vec();
        blob(&mut input, &state.encode()); text(&mut input, "select"); text(&mut input, "1"); text(&mut input, "missing"); input.extend_from_slice(&0u64.to_le_bytes());
        let output = invoke(&input).unwrap(); let mut r = Reader::new(&output);
        assert_eq!(r.u32().unwrap(), 3); r.blob().unwrap(); assert_eq!(r.u32().unwrap(), 0);
        assert_eq!(r.text().unwrap(), ""); assert_eq!(r.u32().unwrap(), 7);
        assert_eq!(r.text().unwrap(), descriptor); assert_eq!(r.u32().unwrap(), 1);
        assert_eq!(r.text().unwrap(), descriptor); r.end().unwrap();
        let (_, rows, text) = result(&event(&state.encode(), "select", "1", ""));
        assert!(rows.is_empty() && text.is_empty());
    }
    #[test] fn malformed_input_and_unknown_events_fail() {
        for bytes in [vec![],vec![255;12],event(&[],"invalid","","")] { assert!(invoke(&bytes).is_err()); }
        let mut bytes=event(&[],"query","","");bytes.push(0);assert!(invoke(&bytes).is_err());
    }
}

/// Native ownership boundary: the caller copies the returned bytes and releases
/// them with clipboard_native_free. No wasm32 pointer truncation is involved.
#[no_mangle]
pub unsafe extern "C" fn clipboard_native_process(input: *const u8, length: usize, output_length: *mut usize) -> *mut u8 {
    if output_length.is_null() || (length != 0 && input.is_null()) { return std::ptr::null_mut(); }
    *output_length = 0;
    let bytes = if length == 0 { &[] } else { slice::from_raw_parts(input, length) };
    let Ok(result) = invoke(bytes) else { return std::ptr::null_mut(); };
    let mut owned = result.into_boxed_slice();
    *output_length = owned.len();
    let pointer = owned.as_mut_ptr();
    std::mem::forget(owned);
    pointer
}
#[no_mangle]
pub unsafe extern "C" fn clipboard_native_free(bytes: *mut u8, length: usize) {
    if !bytes.is_null() { drop(Box::from_raw(std::ptr::slice_from_raw_parts_mut(bytes, length))); }
}

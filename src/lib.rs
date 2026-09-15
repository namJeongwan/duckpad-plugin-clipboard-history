use std::{slice, sync::Mutex};

static OUTPUT: Mutex<Vec<u8>> = Mutex::new(Vec::new());
const HISTORY_LIMIT: usize = 200;
const STATE_LIMIT: usize = 512 * 1024;
const ITEM_LIMIT: usize = 256 * 1024;
const STATE_HEADER: usize = 20;
const DAY: u64 = 86_400;
fn entry_size(e: &Entry) -> usize { 24 + e.text.len() }
#[derive(Clone, Debug, PartialEq)]
struct Entry { id: u64, pinned: bool, text: String, copied_at: u64 }
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
        if version != 1 && version != 2 { return Err(()); }
        let retention_days = if version == 2 { r.u32()? } else { 7 };
        if ![1, 3, 7].contains(&retention_days) { return Err(()); }
        let next_id = r.u64()?;
        let count = r.u32()? as usize;
        if count > HISTORY_LIMIT { return Err(()); }
        let mut entries = Vec::new();
        for _ in 0..count {
            let id = r.u64()?; let pinned = r.u32()?;
            if id == 0 || id > next_id || pinned > 1 || entries.iter().any(|e: &Entry| e.id == id) { return Err(()); }
            let copied_at = if version == 2 { r.u64()? } else { now };
            entries.push(Entry { id, pinned: pinned == 1, copied_at, text: r.text()? });
        }
        r.end()?;
        // Legacy timestamps add storage overhead. Keep migration inside the same
        // byte budget, preferring to retain pins just like ordinary capture.
        while STATE_HEADER + entries.iter().map(entry_size).sum::<usize>() > STATE_LIMIT {
            let index = entries.iter().rposition(|e| !e.pinned).unwrap_or(entries.len()-1);
            entries.remove(index);
        }
        Ok(Self { next_id, entries, retention_days })
    }
    fn encode(&self) -> Vec<u8> {
        let mut out = 2u32.to_le_bytes().to_vec(); out.extend_from_slice(&self.retention_days.to_le_bytes()); out.extend_from_slice(&self.next_id.to_le_bytes());
        out.extend_from_slice(&(self.entries.len() as u32).to_le_bytes());
        for e in &self.entries { out.extend_from_slice(&e.id.to_le_bytes()); out.extend_from_slice(&(e.pinned as u32).to_le_bytes()); out.extend_from_slice(&e.copied_at.to_le_bytes()); text(&mut out, &e.text); }
        out
    }
    fn expire(&mut self, now: u64) {
        self.entries.retain(|e| now.saturating_sub(e.copied_at) < u64::from(self.retention_days) * DAY);
    }
    #[cfg(test)]
    fn capture(&mut self, value: String) -> Result<(), ()> { self.capture_at(value, 0) }
    fn capture_at(&mut self, value: String, now: u64) -> Result<(), ()> {
        if value.is_empty() { return Ok(()); }
        if let Some(index) = self.entries.iter().position(|e| e.text == value) {
            let mut entry = self.entries.remove(index); entry.copied_at = now; self.entries.insert(0, entry); return Ok(());
        }
        let required = 24 + value.len();
        if value.len() > ITEM_LIMIT || STATE_HEADER + required > STATE_LIMIT { return Ok(()); }
        let pinned_bytes: usize = self.entries.iter().filter(|e| e.pinned).map(entry_size).sum();
        if self.entries.iter().filter(|e| e.pinned).count() >= HISTORY_LIMIT || STATE_HEADER + pinned_bytes + required > STATE_LIMIT { return Ok(()); }
        while self.entries.len() >= HISTORY_LIMIT || STATE_HEADER + self.entries.iter().map(entry_size).sum::<usize>() + required > STATE_LIMIT {
            if let Some(index) = self.entries.iter().rposition(|e| !e.pinned) { self.entries.remove(index); }
            else { return Ok(()); }
        }
        self.next_id = self.next_id.checked_add(1).ok_or(())?;
        self.entries.insert(0, Entry { id: self.next_id, pinned: false, text: value, copied_at: now }); Ok(())
    }
}
fn invoke(input: &[u8]) -> Result<Vec<u8>, ()> {
    let mut r = Reader::new(input);
    let version = r.u32()?;
    if version != 1 && version != 2 { return Err(()); }
    let state_bytes = r.blob()?;
    let event = r.text()?; let payload = r.text()?; let query = r.text()?.to_lowercase();
    let now = if version == 2 { r.u64()? } else { 0 }; r.end()?;
    let mut state = State::decode_at(state_bytes, now)?;
    state.expire(now);
    let mut selected = String::new();
    match event.as_str() {
        "capture" => state.capture_at(payload, now)?,
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
                _ => selected = state.entries[index].text.clone(),
            }
            }
        },
        _ => return Err(()),
    }
    let mut rows: Vec<&Entry> = state.entries.iter().filter(|e| e.text.to_lowercase().contains(&query)).collect();
    rows.sort_by_key(|e| !e.pinned);
    let mut out = 2u32.to_le_bytes().to_vec(); blob(&mut out, &state.encode());
    out.extend_from_slice(&(rows.len() as u32).to_le_bytes());
    for e in rows {
        text(&mut out, &e.id.to_string());
        // Short display labels; selection always returns the exact original text.
        let title: String = e.text.lines().next().unwrap_or("").chars().take(160).collect();
        text(&mut out, &title); out.extend_from_slice(&(e.pinned as u32).to_le_bytes());
    }
    text(&mut out, &selected); out.extend_from_slice(&state.retention_days.to_le_bytes()); Ok(out)
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

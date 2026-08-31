use std::ffi::CStr;
use std::os::raw::c_char;

#[no_mangle]
pub extern "C" fn ai_input_classify_error(message: *const c_char) -> i32 {
    if message.is_null() { return 0; }
    let text = unsafe { CStr::from_ptr(message) }.to_string_lossy().to_lowercase();
    if text.contains("model_not_found")
        || text.contains("not supported by any configured account")
        || text.contains("unknown model")
        || text.contains("模型未配置") { 1
    } else if text.contains("401") || text.contains("403") || text.contains("unauthorized") || text.contains("认证") || text.contains("token") { 2
    } else if text.contains("quota") || text.contains("余额不足") || text.contains("额度耗尽") || text.contains("insufficient") { 3
    } else if text.contains("429") || text.contains("rate limit") || text.contains("限流") { 4
    } else if text.contains("timeout") || text.contains("timed out") || text.contains("超时") { 5
    } else if text.contains("network") || text.contains("网络") || text.contains("dns") || text.contains("connection") { 6
    } else if text.contains("http 5") || text.contains("server error") || text.contains("服务端") { 7
    } else if text.contains("http 4") || text.contains("bad request") { 8
    } else { 0 }
}

#[no_mangle]
pub extern "C" fn ai_input_p95(values: *const i32, length: usize) -> i32 {
    if values.is_null() || length == 0 { return -1; }
    let mut sorted = unsafe { std::slice::from_raw_parts(values, length) }.to_vec();
    sorted.sort_unstable();
    let index = ((sorted.len() * 95 + 99) / 100).saturating_sub(1);
    sorted[index]
}

#[no_mangle]
pub extern "C" fn ai_input_success_rate(states: *const i8, length: usize) -> i32 {
    if states.is_null() || length == 0 { return -1; }
    let values = unsafe { std::slice::from_raw_parts(states, length) };
    let observed = values.iter().filter(|value| **value >= 0).count();
    if observed == 0 { return -1; }
    let successful = values.iter().filter(|value| **value == 1).count();
    ((successful * 10_000) / observed) as i32
}

#[no_mangle]
pub extern "C" fn ai_input_choose_backup(states: *const i8, latencies: *const i32, length: usize) -> i32 {
    if states.is_null() || length == 0 { return -1; }
    let values = unsafe { std::slice::from_raw_parts(states, length) };
    let timings = if latencies.is_null() { None } else { Some(unsafe { std::slice::from_raw_parts(latencies, length) }) };
    let mut best: Option<(usize, i32)> = None;
    for (index, state) in values.iter().enumerate() {
        if *state != 1 { continue; }
        let latency = timings.map(|items| items[index]).unwrap_or(i32::MAX);
        if best.map(|(_, current)| latency < current).unwrap_or(true) { best = Some((index, latency)); }
    }
    best.map(|(index, _)| index as i32).unwrap_or(-1)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    #[test]
    fn classifies_model_configuration_error() {
        let message = CString::new("HTTP 404 model_not_found").unwrap();
        assert_eq!(ai_input_classify_error(message.as_ptr()), 1);
    }
    #[test]
    fn computes_percentile_and_success_rate() {
        let values = [10, 20, 30, 40, 50];
        assert_eq!(ai_input_p95(values.as_ptr(), values.len()), 50);
        let states = [1_i8, 1, 0, -1];
        assert_eq!(ai_input_success_rate(states.as_ptr(), states.len()), 6666);
    }
    #[test]
    fn chooses_fastest_online_backup() {
        let states = [0_i8, 1, 1];
        let latency = [0, 300, 120];
        assert_eq!(ai_input_choose_backup(states.as_ptr(), latency.as_ptr(), states.len()), 2);
    }
}

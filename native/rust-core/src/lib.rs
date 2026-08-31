use std::ffi::CStr;
use std::os::raw::c_char;

#[no_mangle]
pub extern "C" fn ai_input_classify_error(message: *const c_char) -> i32 {
    if message.is_null() {
        return 0;
    }
    let text = unsafe { CStr::from_ptr(message) }.to_string_lossy().to_lowercase();
    if text.contains("model_not_found")
        || text.contains("not supported by any configured account")
        || text.contains("unknown model")
        || text.contains("模型未配置")
    {
        1 // configuration
    } else if text.contains("401") || text.contains("403") || text.contains("unauthorized") || text.contains("认证") || text.contains("token") {
        2 // authentication
    } else if text.contains("quota") || text.contains("余额不足") || text.contains("额度耗尽") || text.contains("insufficient") {
        3 // quota
    } else if text.contains("429") || text.contains("rate limit") || text.contains("限流") {
        4 // rate limit
    } else if text.contains("timeout") || text.contains("timed out") || text.contains("超时") {
        5 // timeout
    } else if text.contains("network") || text.contains("网络") || text.contains("dns") || text.contains("connection") {
        6 // network
    } else if text.contains("http 5") || text.contains("server error") || text.contains("服务端") {
        7 // server
    } else if text.contains("http 4") || text.contains("bad request") {
        8 // client
    } else {
        0 // generic
    }
}

#[no_mangle]
pub extern "C" fn ai_input_p95(values: *const i32, length: usize) -> i32 {
    if values.is_null() || length == 0 {
        return -1;
    }
    let mut sorted = unsafe { std::slice::from_raw_parts(values, length) }.to_vec();
    sorted.sort_unstable();
    let index = ((sorted.len() * 95 + 99) / 100).saturating_sub(1);
    sorted[index]
}

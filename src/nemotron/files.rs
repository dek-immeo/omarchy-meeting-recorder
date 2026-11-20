/// A fixed revision, so a later change upstream never reaches the app unseen.
pub const REPO: &str = "https://huggingface.co/onnx-community/Nemotron-3-Diarization-ONNX/resolve/353b6f8ad2cac3580e982d7fbdf0a010786b0406/onnx";
/// The graph, and its weights next to it under the name the graph refers to,
/// each with the smallest size that counts as complete on disk and the SHA-256
/// it has at that revision.
pub const FILES: [(&str, u64, &str); 2] = [
    (
        "model_quantized.onnx",
        300_000,
        "fff7d18c7439c9fdc1c6c4dfec924cb42d3344264ca879780dfaf7ee886e6c1e",
    ),
    (
        "model_quantized.onnx_data",
        120_000_000,
        "002d7483e1c865c35c82220fdb378f185ff213c6d35922b38ae421c8ec72c338",
    ),
];

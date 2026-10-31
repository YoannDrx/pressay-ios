import Foundation

/// A model as a list of files, each pinned by size and SHA-256.
///
/// The manifest is compiled into the app, so its hashes are covered by the app's code
/// signature: like the Mac's signed catalog, it is the trust anchor, and the download host
/// is only an untrusted pipe. Every byte is checked against it before the model is used.
public struct ModelManifest: Sendable, Equatable, Identifiable {
    public struct File: Sendable, Equatable {
        /// Path inside the model directory, also the path on the download host.
        public let path: String
        public let size: Int64
        /// Lowercase hexadecimal SHA-256 of the file's content.
        public let sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    /// Directory name of the installed model, stable across revisions.
    public let id: String
    /// Immutable revision of the files; a new revision installs next to the old one.
    public let revision: String
    /// Files are fetched from `baseURL/<path>`.
    public let baseURL: URL
    public let files: [File]

    public init(id: String, revision: String, baseURL: URL, files: [File]) {
        self.id = id
        self.revision = revision
        self.baseURL = baseURL
        self.files = files
    }

    public var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    public func url(for file: File) -> URL {
        file.path.split(separator: "/").reduce(baseURL) { $0.appendingPathComponent(String($1)) }
    }
}

extension ModelManifest {
    /// Parakeet TDT 0.6B v3 in Core ML, as FluidAudio 0.18.0 loads it: preprocessor, int8
    /// encoder, decoder, joint with top-K outputs, vocabulary. NVIDIA, CC BY 4.0; conversion
    /// by FluidInference, Apache-2.0. Pinned to a commit of the Hugging Face repository, so
    /// the bytes behind each path never change; the hashes were computed from that commit.
    public static let parakeetTDTv3 = ModelManifest(
        id: "parakeet-tdt-0.6b-v3-coreml",
        revision: parakeetRevision,
        baseURL: URL(string: "https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve")!
            .appendingPathComponent(parakeetRevision),
        // swiftlint:disable line_length
        files: [
            .init(path: "Preprocessor.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "c9beeb989c8d66f8be11df59bc6df277ec76cee404f6865b46243835ef562f6d"),
            .init(path: "Preprocessor.mlmodelc/coremldata.bin", size: 486, sha256: "dbde3f2300842c1fd51ef3ff948a0bcffe65ffd2dca10707f2509f32c1d65b1d"),
            .init(path: "Preprocessor.mlmodelc/metadata.json", size: 2841, sha256: "2a98699e22d279dd37fa1d238aeb1c6db1df0d6fad687775324157689d8f3acf"),
            .init(path: "Preprocessor.mlmodelc/model.mil", size: 28181, sha256: "4b8518a956450fec57f06c2a21bdffc26973f7f1fa6842fb38fe917f896b6b93"),
            .init(path: "Preprocessor.mlmodelc/weights/weight.bin", size: 491_072, sha256: "129b76e3aeafa8afa3ea76d995b964b145fe83700d579f6ff42c4c38fa0968ea"),
            .init(path: "Encoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105"),
            .init(path: "Encoder.mlmodelc/coremldata.bin", size: 485, sha256: "d48034a167a82e88fc3df64f60af963ab3983538271175b8319e7d5720a0fb86"),
            .init(path: "Encoder.mlmodelc/metadata.json", size: 2921, sha256: "da24da9cca943fb29d7fa8e376d57fca7cb3aa08ca51b956b0b0e56813f087e9"),
            .init(path: "Encoder.mlmodelc/model.mil", size: 959_769, sha256: "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808"),
            .init(path: "Encoder.mlmodelc/weights/weight.bin", size: 445_187_200, sha256: "e2020f323703477a5b21d7c2d282c403e371afb5962e79877e3033e73ba6f421"),
            .init(path: "Decoder.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "4238c4e81ecd0dc94bd7dfbb60f7e2cc824107c1ffe0387b8607b72833dba350"),
            .init(path: "Decoder.mlmodelc/coremldata.bin", size: 554, sha256: "18647af085d87bd8f3121c8a9b4d4564c1ede038dab63d295b4e745cf2d7fb99"),
            .init(path: "Decoder.mlmodelc/metadata.json", size: 3427, sha256: "a39e93cd8371b8ded92635c7804fcd0590f0d1dd9415c6d19a0484be073077d9"),
            .init(path: "Decoder.mlmodelc/model.mil", size: 13110, sha256: "ef2a0a281695398a62fde86ac269c68f73d5b578d7ed3b31f2ba91a2d1ea1f35"),
            .init(path: "Decoder.mlmodelc/weights/weight.bin", size: 23_604_992, sha256: "48adf0f0d47c406c8253d4f7fef967436a39da14f5a65e66d5a4b407be355d41"),
            .init(path: "JointDecisionv3.mlmodelc/analytics/coremldata.bin", size: 243, sha256: "26def4bf73dd56d29dee21c8ef97cb8969e62f6120ed1adc91e46828e2737b6c"),
            .init(path: "JointDecisionv3.mlmodelc/coremldata.bin", size: 521, sha256: "f5fc08b741400f0088492c9e839418b1e18522f19cba28d361dd030c5f398342"),
            .init(path: "JointDecisionv3.mlmodelc/metadata.json", size: 3453, sha256: "d9307211b9a37e0f0ac260c7660b1571a3de25841035cfdf9b58fd40425f890f"),
            .init(path: "JointDecisionv3.mlmodelc/model.mil", size: 11775, sha256: "be60732943389a047175111a83f8839f3eb39d4803adafa828a0871b2f39818d"),
            .init(path: "JointDecisionv3.mlmodelc/weights/weight.bin", size: 12_642_764, sha256: "4e0e63d840032f7f07ddb1d64446051166281e5491bf22da8a945c41f6eedb3e"),
            .init(path: "parakeet_vocab.json", size: 151_122, sha256: "7ec60e05f1b24480736ec0eed40900f4626bce1fa9a60fd700ec7e2a59198735"),
        ]
        // swiftlint:enable line_length
    )

    private static let parakeetRevision = "7dd20fe6b1797d35f5e3307e8b1732d9a178edfe"
}

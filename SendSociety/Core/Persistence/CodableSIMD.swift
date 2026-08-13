import simd

/// Retroactive `Codable` conformance for the simd types this app already uses everywhere
/// (`SIMD3<Float>` joint positions, `simd_float4x4` camera transforms, etc.). None of Apple's simd
/// types conform to `Codable` out of the box, so every persisted struct that contains one — nearly
/// every domain model in this app (`BodyPoseSample`, `ReconstructionEntry`, and so on) — needs
/// this before Swift's automatic `Codable` synthesis can work for it. Adding it
/// ONCE here, centrally, means those domain structs just need a plain `: Codable` added to their
/// declaration with no other changes — see the individual `extension ... : Codable {}` lines
/// scattered across the domain model files for where that happens.
///
/// Encoding format: a flat JSON array of the scalar components, in `x, y, z, (w)` / column-major
/// order — simple, obviously-correct, and easy to hand-inspect if something needs debugging.
extension SIMD3: Codable where Scalar: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Scalar.self)
        let y = try container.decode(Scalar.self)
        let z = try container.decode(Scalar.self)
        self.init(x, y, z)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(z)
    }
}

extension SIMD4: Codable where Scalar: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let x = try container.decode(Scalar.self)
        let y = try container.decode(Scalar.self)
        let z = try container.decode(Scalar.self)
        let w = try container.decode(Scalar.self)
        self.init(x, y, z, w)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(z)
        try container.encode(w)
    }
}

extension simd_float3x3: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let c0 = try container.decode(SIMD3<Float>.self)
        let c1 = try container.decode(SIMD3<Float>.self)
        let c2 = try container.decode(SIMD3<Float>.self)
        self.init(columns: (c0, c1, c2))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(columns.0)
        try container.encode(columns.1)
        try container.encode(columns.2)
    }
}

extension simd_float4x4: Codable {
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        let c0 = try container.decode(SIMD4<Float>.self)
        let c1 = try container.decode(SIMD4<Float>.self)
        let c2 = try container.decode(SIMD4<Float>.self)
        let c3 = try container.decode(SIMD4<Float>.self)
        self.init(columns: (c0, c1, c2, c3))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(columns.0)
        try container.encode(columns.1)
        try container.encode(columns.2)
        try container.encode(columns.3)
    }
}

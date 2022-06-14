import Foundation

let ociManifestMediaType = "application/vnd.oci.image.manifest.v1+json"
let ociConfigMediaType = "application/vnd.oci.image.config.v1+json"

public struct OCIManifest: Codable, Equatable {
  public var schemaVersion: Int = 2
  public var mediaType: String = ociManifestMediaType
  public var config: OCIManifestConfig
  public var layers: [OCIManifestLayer] = Array()

  public init(config: OCIManifestConfig, layers: [OCIManifestLayer]) {
    self.config = config
    self.layers = layers
  }

  public func digest() throws -> String {
    try Digest.hash(JSONEncoder().encode(self))
  }
}


public struct OCIManifestConfig: Codable, Equatable {
  public var mediaType: String = ociConfigMediaType
  public var size: Int
  public var digest: String

  public init(size: Int, digest: String) {
    self.size = size
    self.digest = digest
  }
}


public struct OCIManifestLayer: Codable, Equatable {
  public var mediaType: String
  public var size: Int
  public var digest: String

  public init(mediaType: String, size: Int, digest: String) {
    self.mediaType = mediaType
    self.size = size
    self.digest = digest
  }
}

public struct Descriptor: Equatable {
  public var size: Int
  public var digest: String
}

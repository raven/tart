import Foundation
import Virtualization

struct UnsupportedRestoreImageError: Error {
}

struct NoMainScreenFoundError: Error {
}

struct DownloadFailed: Error {
}

struct UnsupportedOSError: Error, CustomStringConvertible {
  let description: String

  init(_ what: String, _ plural: String) {
    description = "error: \(what) \(plural) only supported on hosts running macOS 13.0 (Ventura) or newer"
  }
}

struct UnsupportedArchitectureError: Error {
}

class VM: NSObject, VZVirtualMachineDelegate, ObservableObject {
  // Virtualization.Framework's virtual machine
  @Published var virtualMachine: VZVirtualMachine

  // Semaphore used to communicate with the VZVirtualMachineDelegate
  var sema = DispatchSemaphore(value: 0)

  // VM's config
  var name: String
  
  // VM's config
  var config: VMConfig

  var softnet: Softnet? = nil

  init(vmDir: VMDirectory,
       withSoftnet: Bool = false,
       additionalDiskAttachments: [VZDiskImageStorageDeviceAttachment] = [],
       directoryShares: [DirectoryShare] = []
  ) throws {
    name = vmDir.name
    config = try VMConfig.init(fromURL: vmDir.configURL)

    if config.arch != CurrentArchitecture() {
      throw UnsupportedArchitectureError()
    }

    // Initialize the virtual machine and its configuration
    if withSoftnet {
      softnet = try Softnet(vmMACAddress: config.macAddress.string)
    }

    let configuration = try Self.craftConfiguration(diskURL: vmDir.diskURL,
      nvramURL: vmDir.nvramURL, vmConfig: config,
      softnet: softnet, additionalDiskAttachments: additionalDiskAttachments,
            directoryShares: directoryShares)
    virtualMachine = VZVirtualMachine(configuration: configuration)

    super.init()
    virtualMachine.delegate = self
  }

  static func retrieveLatestIPSW() async throws -> URL {
    defaultLogger.appendNewLine("Looking up the latest supported IPSW...")
    let image = try await withCheckedThrowingContinuation { continuation in
      VZMacOSRestoreImage.fetchLatestSupported() { result in
        continuation.resume(with: result)
      }
    }

    let expectedIPSWLocation = try IPSWCache().locationFor(image: image)

    if FileManager.default.fileExists(atPath: expectedIPSWLocation.path) {
      defaultLogger.appendNewLine("Using cached *.ipsw file...")
      try expectedIPSWLocation.updateAccessDate()
      return expectedIPSWLocation
    }

    defaultLogger.appendNewLine("Fetching \(expectedIPSWLocation.lastPathComponent)...")

    let data: Data = try await withCheckedThrowingContinuation { continuation in
      let downloadedTask = URLSession.shared.dataTask(with: image.url) { data, response, error in
        if error != nil {
          continuation.resume(throwing: error!)
          return
        }
        if (data == nil) {
          continuation.resume(throwing: DownloadFailed())
          return
        }
        continuation.resume(returning: data!)
      }
      ProgressObserver(downloadedTask.progress).log(defaultLogger)
      downloadedTask.resume()
    }

    try data.write(to: expectedIPSWLocation, options: [.atomic])
    return expectedIPSWLocation
  }
  
  var inFinalState: Bool {
    get {
      virtualMachine.state == VZVirtualMachine.State.stopped ||
        virtualMachine.state == VZVirtualMachine.State.paused ||
        virtualMachine.state == VZVirtualMachine.State.error
      
    }
  }

  init(
    vmDir: VMDirectory,
    ipswURL: URL?,
    diskSizeGB: UInt16,
    withSoftnet: Bool = false,
    additionalDiskAttachments: [VZDiskImageStorageDeviceAttachment] = []
  ) async throws {
    let ipswURL = ipswURL != nil ? ipswURL! : try await VM.retrieveLatestIPSW();

    // Load the restore image and try to get the requirements
    // that match both the image and our platform
    let image = try await withCheckedThrowingContinuation { continuation in
      VZMacOSRestoreImage.load(from: ipswURL) { result in
        continuation.resume(with: result)
      }
    }

    guard let requirements = image.mostFeaturefulSupportedConfiguration else {
      throw UnsupportedRestoreImageError()
    }

    // Create NVRAM
    _ = try VZMacAuxiliaryStorage(creatingStorageAt: vmDir.nvramURL, hardwareModel: requirements.hardwareModel)

    // Create disk
    try vmDir.resizeDisk(diskSizeGB)

    name = vmDir.name
    // Create config
    config = VMConfig(
      platform: Darwin(ecid: VZMacMachineIdentifier(), hardwareModel: requirements.hardwareModel),
      cpuCountMin: requirements.minimumSupportedCPUCount,
      memorySizeMin: requirements.minimumSupportedMemorySize
    )
    // allocate at least 4 CPUs because otherwise VMs are frequently freezing
    try config.setCPU(cpuCount: max(4, requirements.minimumSupportedCPUCount))
    try config.save(toURL: vmDir.configURL)

    // Initialize the virtual machine and its configuration
    if withSoftnet {
      softnet = try Softnet(vmMACAddress: config.macAddress.string)
    }

    let configuration = try Self.craftConfiguration(diskURL: vmDir.diskURL, nvramURL: vmDir.nvramURL,
      vmConfig: config, softnet: softnet,
      additionalDiskAttachments: additionalDiskAttachments,
      directoryShares: [])
    virtualMachine = VZVirtualMachine(configuration: configuration)

    super.init()
    virtualMachine.delegate = self

    // Run automated installation
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      DispatchQueue.main.async {
        let installer = VZMacOSInstaller(virtualMachine: self.virtualMachine, restoringFromImageAt: ipswURL)

        defaultLogger.appendNewLine("Installing OS...")
        ProgressObserver(installer.progress).log(defaultLogger)

        installer.install { result in
          continuation.resume(with: result)
        }
      }
    }
  }

  @available(macOS 13, *)
  static func linux(vmDir: VMDirectory, diskSizeGB: UInt16) async throws -> VM {
    // Create NVRAM
    _ = try VZEFIVariableStore(creatingVariableStoreAt: vmDir.nvramURL)

    // Create disk
    try vmDir.resizeDisk(diskSizeGB)

    // Create config
    let config = VMConfig(platform: Linux(), cpuCountMin: 4, memorySizeMin: 4096 * 1024 * 1024)
    try config.save(toURL: vmDir.configURL)

    return try VM(vmDir: vmDir)
  }

  func run(_ recovery: Bool) async throws {
    if let softnet = softnet {
      try softnet.run()
    }

    DispatchQueue.main.sync {
      Task {
        if #available(macOS 13, *) {
          // new API introduced in Ventura
          let startOptions = VZMacOSVirtualMachineStartOptions()
          startOptions.startUpFromMacOSRecovery = recovery
          try await virtualMachine.start(options: startOptions)
        } else {
          // use method that also available on Monterey
          try await virtualMachine.start(recovery)
        }
      }
    }

    await withTaskCancellationHandler(operation: {
      sema.wait()
    }, onCancel: {
      sema.signal()
    })

    if Task.isCancelled {
      DispatchQueue.main.sync {
        Task {
          try await self.virtualMachine.stop()
        }
      }
    }

    if let softnet = softnet {
      try softnet.stop();
    }
  }

  static func craftConfiguration(
    diskURL: URL,
    nvramURL: URL,
    vmConfig: VMConfig,
    softnet: Softnet? = nil,
    additionalDiskAttachments: [VZDiskImageStorageDeviceAttachment],
    directoryShares: [DirectoryShare]
  ) throws -> VZVirtualMachineConfiguration {
    let configuration = VZVirtualMachineConfiguration()

    // Boot loader
    configuration.bootLoader = try vmConfig.platform.bootLoader(nvramURL: nvramURL)

    // CPU and memory
    configuration.cpuCount = vmConfig.cpuCount
    configuration.memorySize = vmConfig.memorySize

    // Platform
    configuration.platform = vmConfig.platform.platform(nvramURL: nvramURL)

    // Display
    configuration.graphicsDevices = [vmConfig.platform.graphicsDevice(vmConfig: vmConfig)]

    // Audio
    let soundDeviceConfiguration = VZVirtioSoundDeviceConfiguration()
    let inputAudioStreamConfiguration = VZVirtioSoundDeviceInputStreamConfiguration()
    inputAudioStreamConfiguration.source = VZHostAudioInputStreamSource()
    let outputAudioStreamConfiguration = VZVirtioSoundDeviceOutputStreamConfiguration()
    outputAudioStreamConfiguration.sink = VZHostAudioOutputStreamSink()
    soundDeviceConfiguration.streams = [inputAudioStreamConfiguration, outputAudioStreamConfiguration]
    configuration.audioDevices = [soundDeviceConfiguration]

    // Keyboard and mouse
    configuration.keyboards = [VZUSBKeyboardConfiguration()]
    configuration.pointingDevices = vmConfig.platform.pointingDevices()

    // Networking
    let vio = VZVirtioNetworkDeviceConfiguration()

    if let softnet = softnet {
      let fh = FileHandle.init(fileDescriptor: softnet.vmFD)
      vio.attachment = VZFileHandleNetworkDeviceAttachment(fileHandle: fh)
    } else {
      vio.attachment = VZNATNetworkDeviceAttachment()
    }
    vio.macAddress = vmConfig.macAddress
    configuration.networkDevices = [vio]

    // Storage
    var attachments = [try VZDiskImageStorageDeviceAttachment(url: diskURL, readOnly: false)]
    attachments.append(contentsOf: additionalDiskAttachments)
    configuration.storageDevices = attachments.map { VZVirtioBlockDeviceConfiguration(attachment: $0) }

    // Entropy
    configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    // Directory share
    if #available(macOS 13, *) {
      var directories: [String : VZSharedDirectory] = Dictionary()
      directoryShares.forEach { directories[$0.name] = VZSharedDirectory(url: $0.path, readOnly: $0.readOnly) }

      let automountTag = VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag
      let sharingDevice = VZVirtioFileSystemDeviceConfiguration(tag: automountTag)
      sharingDevice.share = VZMultipleDirectoryShare(directories: directories)

      configuration.directorySharingDevices = [sharingDevice]
    } else if !directoryShares.isEmpty {
      throw UnsupportedOSError("directory sharing", "is")
    }

    try configuration.validate()

    return configuration
  }

  func guestDidStop(_ virtualMachine: VZVirtualMachine) {
    print("guest has stopped the virtual machine")
    sema.signal()
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
    print("guest has stopped the virtual machine due to error")
    sema.signal()
  }

  func virtualMachine(_ virtualMachine: VZVirtualMachine, networkDevice: VZNetworkDevice, attachmentWasDisconnectedWithError error: Error) {
    print("virtual machine's network attachment \(networkDevice) has been disconnected with error: \(error)")
    sema.signal()
  }
}

struct DirectoryShare {
  let name: String
  let path: URL
  let readOnly: Bool
}
